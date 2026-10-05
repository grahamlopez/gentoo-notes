#!/usr/bin/env bash
#
# Repeatable Gentoo installer — first milestone
#
# This file is both the executable installer and its canonical design record.
# Each phase begins with its own readable explanation immediately beside the
# code that implements it.  Run with `--verbose` to print the technical notes
# for each selected phase, or read the source directly.
#
# This installer currently owns three phases:
#   disk-setup: validate the target, then create GPT → EFI → LUKS2 → Btrfs →
#   @ + @home.
#   stage3-bootstrap: obtain and verify the current official AMD64 desktop-
#   systemd stage3, extract it, and prepare a chroot environment.
#   portage-foundation: install the live configuration work tree, configure
#   Portage for Git synchronization, and establish locale and timezone.
#
# It executes selected phases by default.  Use --dry-run to print plans without
# making changes.  Disk setup also requires confirmation of the exact target.
# Later phases will update the system, build the kernel, and install the UKI.

if [[ -z ${BASH_VERSION:-} ]]; then
  printf 'error: this installer requires Bash.\n' >&2
  exit 1
fi

set -Eeuo pipefail
IFS=$'\n\t'

readonly PROGRAM=${0##*/}
readonly DEFAULT_EFI_SIZE='1G'
readonly STAGE3_BASE_URL='https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-desktop-systemd'
readonly STAGE3_LATEST_MANIFEST='latest-stage3-amd64-desktop-systemd.txt'
readonly GENTOO_RELEASE_KEYS_URL='https://dev.gentoo.org/~sam/dist/sec-keys/openpgp-keys-gentoo-release/gentoo-release.asc.20260125.gz'
readonly GENTOO_AUTOMATED_RELEASE_FINGERPRINT='13EBBDBEDE7A12775DFDB1BABB572E0E2D182910'
readonly GENTOO_REPOSITORY_URL='https://github.com/gentoo-mirror/gentoo.git'
readonly GENTOO_REPOSITORY_SIGNING_FINGERPRINT='EF9538C9E8E64311A52CDEDFA13D0EF1914E7A72'
readonly DEFAULT_CONFIG_SOURCE='https://github.com/grahamlopez/gentoo-configs.git'
readonly DEFAULT_CONFIG_BRANCH='main'
readonly DEFAULT_TARGET_HOST='generic'
readonly DEFAULT_TIMEZONE='America/New_York'
readonly DEFAULT_LOCALE='en_US.UTF-8'

TARGET_DISK=${TARGET_DISK:-}
LUKS_NAME=${LUKS_NAME:-cryptroot}
BTRFS_LABEL=${BTRFS_LABEL:-GENTOO}
ROOT_SUBVOL=${ROOT_SUBVOL:-@}
HOME_SUBVOL=${HOME_SUBVOL:-@home}
EFI_SIZE=${EFI_SIZE:-$DEFAULT_EFI_SIZE}
MOUNT_ROOT=${MOUNT_ROOT:-/mnt/gentoo}
CONFIG_SOURCE=${CONFIG_SOURCE:-$DEFAULT_CONFIG_SOURCE}
CONFIG_BRANCH=${CONFIG_BRANCH:-$DEFAULT_CONFIG_BRANCH}
TARGET_HOST=${TARGET_HOST:-$DEFAULT_TARGET_HOST}
TARGET_TIMEZONE=${TARGET_TIMEZONE:-$DEFAULT_TIMEZONE}
TARGET_LOCALE=${TARGET_LOCALE:-$DEFAULT_LOCALE}
MODE=apply
ASSUME_YES=0
SELECTED_PHASES=(disk-setup stage3-bootstrap portage-foundation)
VERBOSE=0
INTERNAL_PORTAGE_CHROOT=0

EFI_PARTITION=
CRYPT_PARTITION=
MOUNTED_ROOT=0
MOUNTED_HOME=0
MOUNTED_EFI=0
LUKS_OPENED=0

PHASE_ORDER=(disk-setup stage3-bootstrap portage-foundation)

usage() {
  cat <<EOF
Usage: $PROGRAM --disk DEVICE [options]

Install the selected Gentoo phases.  The current milestone prepares an
encrypted Btrfs disk, bootstraps the verified stage3, and establishes the
target's Portage configuration.

Required:
  --disk DEVICE              Whole block device to erase, for example /dev/nvme0n1

Options:
  --dry-run                  Print plans and perform no changes.
  --yes                      Automatically continue through ordinary phase and
                              destructive-action confirmations.  This never
                              supplies, skips, or infers secret input.
  --verbose                  Print technical notes and detailed phase output.
                              It does not affect execution or confirmations.
  --phase NAME               Run a named phase (currently: disk-setup,
                              stage3-bootstrap, portage-foundation). May be
                              repeated; phases run in installer order.
  --config-source SOURCE     Public Git URL or local repository path
                              (default: $CONFIG_SOURCE).
  --config-branch BRANCH     Configuration branch to install
                              (default: $CONFIG_BRANCH).
  --target-host NAME         Configuration target: generic, qemu, or thinktop
                              (default: $TARGET_HOST).
  --timezone ZONE            Target timezone (default: $TARGET_TIMEZONE).
  --locale LOCALE            Target UTF-8 locale (default: $TARGET_LOCALE).
  --luks-name NAME           Mapper name after opening LUKS (default: $LUKS_NAME).
  --btrfs-label LABEL        Btrfs volume label (default: $BTRFS_LABEL).
  --root-subvol NAME         Root Btrfs subvolume (default: $ROOT_SUBVOL).
  --home-subvol NAME         Home Btrfs subvolume (default: $HOME_SUBVOL).
  --efi-size SIZE            EFI partition size, e.g. 1G (default: $EFI_SIZE).
  --mount-root PATH          Where prepared filesystems remain mounted
                              (default: $MOUNT_ROOT).
  -h, --help                 Show this help.

Environment overrides mirror these options: TARGET_DISK, LUKS_NAME,
BTRFS_LABEL, ROOT_SUBVOL, HOME_SUBVOL, EFI_SIZE, MOUNT_ROOT, CONFIG_SOURCE,
CONFIG_BRANCH, TARGET_HOST, TARGET_TIMEZONE, and TARGET_LOCALE.

Safety model:
  * Selected phases run by default; --dry-run is the non-destructive mode.
  * Mutating phases show their plan and ask before continuing.  --yes is the
    global opt-in to automatic continuation.
  * Disk setup refuses partitions, disks with mounted descendants, and disks
    that back the running root, boot, or EFI filesystems.
  * The LUKS passphrase is prompted only during real disk setup; it is never
    accepted in an argument, printed, or written to a file by this script.
EOF
}

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

run_privileged() {
  if (( EUID == 0 )); then
    "$@"
  else
    sudo -- "$@"
  fi
}

# Command-line selection and configuration

is_selected() {
  local wanted=$1 phase
  for phase in "${SELECTED_PHASES[@]}"; do
    [[ $phase == "$wanted" ]] && return 0
  done
  return 1
}

valid_phase() {
  local wanted=$1 phase
  for phase in "${PHASE_ORDER[@]}"; do
    [[ $phase == "$wanted" ]] && return 0
  done
  return 1
}

set_phase_selection() {
  local phase=$1
  valid_phase "$phase" || die "unknown phase: $phase"
  if [[ ${PHASES_EXPLICIT:-0} == 0 ]]; then
    SELECTED_PHASES=()
    PHASES_EXPLICIT=1
  fi
  SELECTED_PHASES+=("$phase")
}

parse_args() {
  while (($#)); do
    case $1 in
      --disk)
        (($# >= 2)) || die '--disk requires a device path'
        TARGET_DISK=$2
        shift
        ;;
      --disk=*) TARGET_DISK=${1#*=} ;;
      --dry-run) MODE=dry-run ;;
      --yes) ASSUME_YES=1 ;;
      --verbose) VERBOSE=1 ;;
      --phase)
        (($# >= 2)) || die '--phase requires a phase name'
        set_phase_selection "$2"
        shift
        ;;
      --phase=*) set_phase_selection "${1#*=}" ;;
      --luks-name)
        (($# >= 2)) || die '--luks-name requires a value'
        LUKS_NAME=$2
        shift
        ;;
      --luks-name=*) LUKS_NAME=${1#*=} ;;
      --btrfs-label)
        (($# >= 2)) || die '--btrfs-label requires a value'
        BTRFS_LABEL=$2
        shift
        ;;
      --btrfs-label=*) BTRFS_LABEL=${1#*=} ;;
      --root-subvol)
        (($# >= 2)) || die '--root-subvol requires a value'
        ROOT_SUBVOL=$2
        shift
        ;;
      --root-subvol=*) ROOT_SUBVOL=${1#*=} ;;
      --home-subvol)
        (($# >= 2)) || die '--home-subvol requires a value'
        HOME_SUBVOL=$2
        shift
        ;;
      --home-subvol=*) HOME_SUBVOL=${1#*=} ;;
      --efi-size)
        (($# >= 2)) || die '--efi-size requires a value'
        EFI_SIZE=$2
        shift
        ;;
      --efi-size=*) EFI_SIZE=${1#*=} ;;
      --mount-root)
        (($# >= 2)) || die '--mount-root requires a path'
        MOUNT_ROOT=$2
        shift
        ;;
      --mount-root=*) MOUNT_ROOT=${1#*=} ;;
      --config-source)
        (($# >= 2)) || die '--config-source requires a URL or path'
        CONFIG_SOURCE=$2
        shift
        ;;
      --config-source=*) CONFIG_SOURCE=${1#*=} ;;
      --config-branch)
        (($# >= 2)) || die '--config-branch requires a branch name'
        CONFIG_BRANCH=$2
        shift
        ;;
      --config-branch=*) CONFIG_BRANCH=${1#*=} ;;
      --target-host)
        (($# >= 2)) || die '--target-host requires a name'
        TARGET_HOST=$2
        shift
        ;;
      --target-host=*) TARGET_HOST=${1#*=} ;;
      --timezone)
        (($# >= 2)) || die '--timezone requires a zone name'
        TARGET_TIMEZONE=$2
        shift
        ;;
      --timezone=*) TARGET_TIMEZONE=${1#*=} ;;
      --locale)
        (($# >= 2)) || die '--locale requires a locale name'
        TARGET_LOCALE=$2
        shift
        ;;
      --locale=*) TARGET_LOCALE=${1#*=} ;;
      --internal-portage-chroot) INTERNAL_PORTAGE_CHROOT=1 ;;
      -h|--help)
        usage
        exit 0
        ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
}

# Runtime interaction

confirm_phase() {
  local phase=$1 answer

  (( ASSUME_YES )) && return 0
  [[ -r /dev/tty && -w /dev/tty ]] || die "a terminal is required to confirm $phase; use --yes only when appropriate"
  printf '\nContinue with %s? [y/N] ' "$phase" >/dev/tty
  IFS= read -r answer </dev/tty || die "could not read confirmation for $phase"
  case $answer in
    y|Y|yes|YES|Yes) return 0 ;;
    *)
      printf 'Stopped before %s.\n' "$phase"
      exit 0
      ;;
  esac
}

# Disk setup verification

verification_error() {
  printf 'error: disk setup verification failed: %s\n' "$*" >&2
  return 1
}

mount_has_option() {
  local mountpoint=$1 expected_option=$2 options option

  options=$(run_privileged findmnt --noheadings --output OPTIONS --target "$mountpoint") || return 1
  IFS=, read -r -a options <<<"$options"
  for option in "${options[@]}"; do
    [[ $option == "$expected_option" ]] && return 0
  done
  return 1
}

mount_uses_subvolume() {
  local mountpoint=$1 expected_subvolume=$2

  mount_has_option "$mountpoint" "subvol=$expected_subvolume" \
    || mount_has_option "$mountpoint" "subvol=/$expected_subvolume"
}

verify_disk_setup() {
  # This is a production gate: disk setup calls it before allowing later
  # installer phases to use the prepared filesystem.
  local efi_type crypt_type mapper_device luks_version filesystem_type label
  local mount_source mount_fstype target_disk_name subvolume

  # 1. Check the inspection tools first so a missing tool is reported as a
  # verification failure, rather than being mistaken for a malformed layout.
  for command in lsblk readlink awk cryptsetup blkid btrfs findmnt mountpoint; do
    command -v "$command" >/dev/null 2>&1 \
      || verification_error "required command is unavailable: $command" || return 1
  done

  # 2. Confirm that the chosen disk has the intended GPT and that both
  # partition paths resolve to direct children of that exact disk.
  [[ $(run_privileged lsblk --noheadings --output PTTYPE "$TARGET_DISK" | awk 'NR == 1 { print tolower($1) }') == gpt ]] \
    || verification_error "target does not have a GPT partition table: $TARGET_DISK" || return 1
  target_disk_name=${TARGET_DISK##*/}
  [[ $(run_privileged lsblk --noheadings --output PKNAME "$EFI_PARTITION" | awk 'NR == 1 { print $1 }') == "$target_disk_name" ]] \
    || verification_error "EFI partition is not on the target disk: $EFI_PARTITION" || return 1
  [[ $(run_privileged lsblk --noheadings --output PKNAME "$CRYPT_PARTITION" | awk 'NR == 1 { print $1 }') == "$target_disk_name" ]] \
    || verification_error "LUKS partition is not on the target disk: $CRYPT_PARTITION" || return 1

  # 3. Confirm the EFI and encrypted partition types, plus the FAT filesystem
  # firmware needs on the unencrypted EFI System Partition.
  efi_type=$(run_privileged lsblk --noheadings --output PARTTYPE "$EFI_PARTITION" | awk 'NR == 1 { print tolower($1) }')
  crypt_type=$(run_privileged lsblk --noheadings --output PARTTYPE "$CRYPT_PARTITION" | awk 'NR == 1 { print tolower($1) }')
  [[ $efi_type == c12a7328-f81f-11d2-ba4b-00a0c93ec93b ]] \
    || verification_error "EFI partition has the wrong GPT type: $EFI_PARTITION" || return 1
  [[ $crypt_type == ca7d7ccb-63ed-4c53-861c-1742536059cc ]] \
    || verification_error "LUKS partition has the wrong GPT type: $CRYPT_PARTITION" || return 1
  [[ $(run_privileged blkid --output value --match-tag TYPE "$EFI_PARTITION") == vfat ]] \
    || verification_error "EFI partition is not FAT: $EFI_PARTITION" || return 1

  # 4. Confirm the partition is LUKS2 and the open mapper points back to it.
  run_privileged cryptsetup isLuks "$CRYPT_PARTITION" >/dev/null 2>&1 \
    || verification_error "partition is not a LUKS container: $CRYPT_PARTITION" || return 1
  luks_version=$(run_privileged cryptsetup luksDump "$CRYPT_PARTITION" 2>/dev/null | awk -F: '$1 ~ /^[[:space:]]*Version$/ { gsub(/[[:space:]]/, "", $2); print $2; exit }')
  [[ $luks_version == 2 ]] \
    || verification_error "LUKS container is not LUKS2: $CRYPT_PARTITION" || return 1
  [[ -b /dev/mapper/$LUKS_NAME ]] \
    || verification_error "LUKS mapper is missing: /dev/mapper/$LUKS_NAME" || return 1
  mapper_device=$(run_privileged cryptsetup status "$LUKS_NAME" 2>/dev/null | awk 'tolower($1) == "device:" { print $2; exit }')
  [[ -n $mapper_device && $(readlink -f -- "$mapper_device") == $(readlink -f -- "$CRYPT_PARTITION") ]] \
    || verification_error "LUKS mapper does not use the intended partition: /dev/mapper/$LUKS_NAME" || return 1

  # 5. Confirm the mapper contains the labeled Btrfs filesystem and the two
  # named subvolumes used by the following installation phases.
  filesystem_type=$(run_privileged blkid --output value --match-tag TYPE "/dev/mapper/$LUKS_NAME" || true)
  label=$(run_privileged blkid --output value --match-tag LABEL "/dev/mapper/$LUKS_NAME" || true)
  [[ $filesystem_type == btrfs ]] \
    || verification_error "mapper does not contain Btrfs: /dev/mapper/$LUKS_NAME" || return 1
  [[ $label == "$BTRFS_LABEL" ]] \
    || verification_error "Btrfs label is not $BTRFS_LABEL" || return 1
  for subvolume in "$ROOT_SUBVOL" "$HOME_SUBVOL"; do
    run_privileged btrfs subvolume list "$MOUNT_ROOT" | awk -v expected="$subvolume" '
      / path / { sub(/^.* path /, ""); if ($0 == expected) found = 1 }
      END { exit !found }
    ' || verification_error "Btrfs subvolume is missing: $subvolume" || return 1
  done

  # 6. Confirm all three mounts exist before checking their sources, types,
  # subvolumes, and mount options individually.
  for mountpoint in "$MOUNT_ROOT" "$MOUNT_ROOT/home" "$MOUNT_ROOT/boot"; do
    run_privileged mountpoint -q "$mountpoint" \
      || verification_error "expected mount is missing: $mountpoint" || return 1
  done
  for mountpoint in "$MOUNT_ROOT" "$MOUNT_ROOT/home"; do
    mount_source=$(run_privileged findmnt --noheadings --output SOURCE --target "$mountpoint")
    mount_fstype=$(run_privileged findmnt --noheadings --output FSTYPE --target "$mountpoint")
    # Btrfs reports a mounted subvolume as /device[/subvolume].  The suffix is
    # mount metadata, not part of the backing mapper path.
    mount_source=${mount_source%%\[*}
    [[ $(readlink -f -- "$mount_source") == $(readlink -f -- "/dev/mapper/$LUKS_NAME") && $mount_fstype == btrfs ]] \
      || verification_error "Btrfs mount has the wrong source or type: $mountpoint" || return 1
  done
  mount_uses_subvolume "$MOUNT_ROOT" "$ROOT_SUBVOL" \
    || verification_error "root mount does not use subvolume $ROOT_SUBVOL: $MOUNT_ROOT" || return 1
  mount_uses_subvolume "$MOUNT_ROOT/home" "$HOME_SUBVOL" \
    || verification_error "home mount does not use subvolume $HOME_SUBVOL: $MOUNT_ROOT/home" || return 1
  for mountpoint in "$MOUNT_ROOT" "$MOUNT_ROOT/home"; do
    mount_has_option "$mountpoint" noatime \
      || verification_error "Btrfs mount is missing noatime: $mountpoint" || return 1
    mount_has_option "$mountpoint" compress=zstd:1 \
      || verification_error "Btrfs mount is missing compress=zstd:1: $mountpoint" || return 1
  done
  # 7. Finally, ensure the firmware-visible mount still comes from the EFI
  # partition, rather than from the encrypted Btrfs filesystem.
  mount_source=$(run_privileged findmnt --noheadings --output SOURCE --target "$MOUNT_ROOT/boot")
  mount_fstype=$(run_privileged findmnt --noheadings --output FSTYPE --target "$MOUNT_ROOT/boot")
  [[ $(readlink -f -- "$mount_source") == $(readlink -f -- "$EFI_PARTITION") && $mount_fstype == vfat ]] \
    || verification_error "EFI mount has the wrong source or type: $MOUNT_ROOT/boot" || return 1
}

# Disk setup presentation, input, and recovery

print_plan() {
  cat <<EOF

Installation disk plan
  $TARGET_DISK
  ├─ $EFI_PARTITION: EFI System Partition, FAT32, $EFI_SIZE → $MOUNT_ROOT/boot
  └─ $CRYPT_PARTITION: LUKS2 → /dev/mapper/$LUKS_NAME
     └─ Btrfs ($BTRFS_LABEL)
        ├─ $ROOT_SUBVOL → $MOUNT_ROOT
        └─ $HOME_SUBVOL → $MOUNT_ROOT/home

This will irreversibly erase every existing partition and filesystem on
$TARGET_DISK.  Dry-run mode changes nothing.
EOF
}

confirm_target() {
  # Read /dev/tty rather than stdin so this still works when the installer
  # arrived through `curl ... | bash`; stdin is the script body in that case.
  [[ $ASSUME_YES == 1 ]] && return 0
  local answer
  printf '\nType the exact target disk to erase (%s): ' "$TARGET_DISK" >/dev/tty
  IFS= read -r answer </dev/tty || die 'could not read destructive-action confirmation from the terminal'
  [[ $answer == "$TARGET_DISK" ]] || die 'target confirmation did not match; no changes made'
}

prompt_luks_passphrase() {
  # Keep the passphrase out of argv, exports, shell history, and files.  It is
  # piped directly to cryptsetup below and then removed from shell state.
  local first second
  [[ -r /dev/tty && -w /dev/tty ]] || die 'cannot securely prompt for a LUKS passphrase without a terminal'
  printf 'New LUKS passphrase: ' >/dev/tty
  IFS= read -r -s first </dev/tty || die 'could not read LUKS passphrase'
  printf '\nConfirm LUKS passphrase: ' >/dev/tty
  IFS= read -r -s second </dev/tty || die 'could not read LUKS passphrase confirmation'
  printf '\n' >/dev/tty
  [[ -n $first ]] || die 'empty LUKS passphrases are not accepted'
  [[ $first == "$second" ]] || die 'LUKS passphrases did not match'
  LUKS_PASSPHRASE=$first
  unset first second
}

cleanup_after_failure() {
  # Reverse only mounts and the mapper created by this run.  A partition table
  # or LUKS header cannot be safely "undone" after disk setup is confirmed.
  local exit_code=${1:-$?}
  (( exit_code == 0 )) && return
  set +e
  if (( MOUNTED_EFI )); then run_privileged umount "$MOUNT_ROOT/boot"; fi
  if (( MOUNTED_HOME )); then run_privileged umount "$MOUNT_ROOT/home"; fi
  if (( MOUNTED_ROOT )); then run_privileged umount "$MOUNT_ROOT"; fi
  if (( LUKS_OPENED )); then run_privileged cryptsetup close "$LUKS_NAME"; fi
  unset LUKS_PASSPHRASE 2>/dev/null || true
  printf 'error: disk setup did not complete; any mounts created by this run were cleaned up.\n' >&2
  exit "$exit_code"
}

# Disk setup phase

disk_setup() {
  local command value mountpoint source backing_disk

  if (( VERBOSE )); then
    cat <<'EOF'
Disk setup: target protection, layout, and mount mechanics
==========================================================

The installer accepts one whole block device and derives its partitions.  For
example, /dev/nvme0n1 becomes /dev/nvme0n1p1 and /dev/nvme0n1p2.

Optional manual safety checks
-----------------------------

The target must have lsblk type `disk`; partitions, /dev/mapper entries, and
ordinary paths are rejected.  The script then protects disks backing /, /boot,
/efi, or /boot/efi, as well as mounted or active-swap descendants.

lsblk --paths --output NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS /dev/nvme0n1
findmnt --target /
findmnt --target /boot
findmnt --target /efi
findmnt --target /boot/efi
swapon --show
test ! -e /dev/mapper/cryptroot

Erase and partition the disk
----------------------------

The target receives a GPT containing two partitions: a FAT32 EFI System
Partition (default 1 GiB, GPT type EF00) and a LUKS2 container using the
remainder (type 8309).  The ESP stays outside LUKS because UEFI firmware must
read the later boot image before Linux can decrypt the root filesystem.

wipefs --all --force /dev/nvme0n1
sfdisk --wipe always --wipe-partitions always /dev/nvme0n1 <<'SFDISK_LAYOUT'
label: gpt
size=1G, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI"
type=CA7D7CCB-63ED-4C53-861C-1742536059CC, name="cryptroot"
SFDISK_LAYOUT

partprobe /dev/nvme0n1
udevadm settle

Create the EFI, LUKS, and Btrfs layers
---------------------------------------

The LUKS partition opens as /dev/mapper/<luks-name>.  Btrfs is formatted there,
not on the raw partition, so the filesystem, subvolume metadata, and later
Gentoo files are encrypted.  `--data single` is appropriate for one device;
`--metadata dup` retains two metadata copies on that device and is standard
practice as recommended by upstream.

mkfs.fat -F 32 -n EFI /dev/nvme0n1p1
cryptsetup luksFormat --type luks2 /dev/nvme0n1p2
cryptsetup open /dev/nvme0n1p2 cryptroot
mkfs.btrfs --force --label GENTOO --data single --metadata dup /dev/mapper/cryptroot

Create the root and home subvolumes
-----------------------------------

The fresh Btrfs top level, normally subvolume ID 5, is mounted temporarily only
to create @ and @home.  The stage3 must later be unpacked after @ is remounted
as <mount-root>.  @home is mounted separately at <mount-root>/home so system
snapshots can exclude home by default.  Named `subvol=@` paths are simpler to
inspect in fstab and recovery commands than numeric IDs.

mkdir -p /mnt/gentoo
mount -o subvolid=5 /dev/mapper/cryptroot /mnt/gentoo
btrfs subvolume create /mnt/gentoo/@
btrfs subvolume create /mnt/gentoo/@home
umount /mnt/gentoo

Mount the layout for the next phase
-----------------------------------

`noatime,compress=zstd:1` is a conservative initial root/home mount policy
to start.  Do not add `ssd` or `space_cache=v2`: modern Btrfs handles those
automatically.  Do not globally enable autodefrag, nodatacow, nodatasum, or
compress-force without a workload-specific reason; they can harm snapshot or
integrity behavior.

The ESP mounts at <mount-root>/boot, where its EFI directory becomes /boot/EFI
inside the installed system.  Later UKIs will live there for direct firmware
booting.

mount -o subvol=@,noatime,compress=zstd:1 /dev/mapper/cryptroot /mnt/gentoo
mkdir -p /mnt/gentoo/home /mnt/gentoo/boot
mount -o subvol=@home,noatime,compress=zstd:1 /dev/mapper/cryptroot /mnt/gentoo/home
mount /dev/nvme0n1p1 /mnt/gentoo/boot
mkdir -p /mnt/gentoo/boot/EFI

Optional manual verification
----------------------------

The printed lsblk table and layout plan are the checks to read before applying
the plan.

cryptsetup isLuks /dev/nvme0n1p2
btrfs subvolume list /mnt/gentoo
findmnt -R /mnt/gentoo
EOF
  fi

  log 'Phase: disk-setup'

  # Commands used by every disk-setup branch.  The longer apply-only tool list
  # stays below its condition so dry-run remains usable in a minimal live ISO.
  for command in lsblk findmnt readlink awk sort; do
    require_command "$command"
  done

  [[ -n $TARGET_DISK ]] || die 'pass a target with --disk DEVICE'
  TARGET_DISK=$(readlink -f -- "$TARGET_DISK")
  [[ -b $TARGET_DISK ]] || die "target is not a block device: $TARGET_DISK"
  [[ $(lsblk -dn -o TYPE "$TARGET_DISK") == disk ]] || die "target must be a whole disk, not a partition or mapper: $TARGET_DISK"
  [[ $EFI_SIZE =~ ^[1-9][0-9]*[MmGg]$ ]] || die "EFI size must look like 1G or 512M: $EFI_SIZE"
  [[ $MOUNT_ROOT == /* && $MOUNT_ROOT != / ]] || die "mount root must be a non-root absolute path: $MOUNT_ROOT"
  for value in "$LUKS_NAME" "$BTRFS_LABEL" "$ROOT_SUBVOL" "$HOME_SUBVOL"; do
    [[ $value =~ ^[A-Za-z0-9._@+-]+$ ]] || die "unsupported characters in layout name: $value"
  done
  [[ $ROOT_SUBVOL != "$HOME_SUBVOL" ]] || die 'root and home subvolume names must differ'

  # NVMe, eMMC, and loop device names already end in a digit, so their
  # partitions are /dev/nvme0n1p1 rather than /dev/nvme0n11.  SATA-style names
  # remain /dev/sda1.  Both names come from the one accepted target disk.
  case ${TARGET_DISK##*/} in
    *[0-9])
      EFI_PARTITION=${TARGET_DISK}p1
      CRYPT_PARTITION=${TARGET_DISK}p2
      ;;
    *)
      EFI_PARTITION=${TARGET_DISK}1
      CRYPT_PARTITION=${TARGET_DISK}2
      ;;
  esac

  # findmnt can identify a plain partition, a /dev/mapper LUKS device, or an
  # LVM logical volume.  lsblk --inverse walks that source back to physical
  # disks, which catches a live root hidden below a device-mapper layer.
  for mountpoint in / /boot /efi /boot/efi; do
    source=$(findmnt --noheadings --output SOURCE --target "$mountpoint" 2>/dev/null || true)
    [[ -b $source ]] || continue
    while IFS= read -r backing_disk; do
      [[ $backing_disk != "$TARGET_DISK" ]] || die "refusing target that backs the running root, boot, or EFI filesystem: $TARGET_DISK"
    done < <(lsblk --inverse --noheadings --paths --output PATH,TYPE "$source" 2>/dev/null \
      | awk '$2 == "disk" { print $1 }' | sort -u)
  done

  # A parent disk usually has no mountpoint even when a child partition does.
  # Swap is not mounted at all, so it needs its own reverse-dependency check.
  if lsblk --raw --noheadings --output MOUNTPOINTS "$TARGET_DISK" 2>/dev/null \
    | awk 'NF { found = 1 } END { exit !found }'; then
    die "refusing target with mounted filesystems: $TARGET_DISK"
  fi
  if command -v swapon >/dev/null 2>&1; then
    while IFS= read -r source; do
      [[ -n $source ]] || continue
      [[ $source != "$TARGET_DISK" ]] || die "refusing target that backs active swap: $TARGET_DISK"
      [[ -b $source ]] || continue
      while IFS= read -r backing_disk; do
        [[ $backing_disk != "$TARGET_DISK" ]] || die "refusing target that backs active swap: $TARGET_DISK"
      done < <(lsblk --inverse --noheadings --paths --output PATH,TYPE "$source" 2>/dev/null \
        | awk '$2 == "disk" { print $1 }' | sort -u)
    done < <(swapon --noheadings --raw --output NAME 2>/dev/null || true)
  fi

  [[ ! -e /dev/mapper/$LUKS_NAME ]] || die "LUKS mapper already exists: /dev/mapper/$LUKS_NAME"
  if [[ $MODE == apply ]]; then
    for command in sfdisk wipefs partprobe udevadm mkfs.fat cryptsetup mkfs.btrfs btrfs mount umount mountpoint blkid; do
      require_command "$command"
    done
    (( EUID == 0 )) || require_command sudo
    ! mountpoint -q "$MOUNT_ROOT" || die "mount root is already mounted: $MOUNT_ROOT"
  fi

  log 'Disk inventory'
  lsblk --paths --output NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS "$TARGET_DISK"

  print_plan
  if [[ $MODE == dry-run ]]; then
    printf '\nDry run: no changes made. Re-run without --dry-run only after reviewing this plan.\n'
    return 0
  fi

  confirm_phase 'disk setup'
  confirm_target
  if (( EUID != 0 )); then
    [[ -r /dev/tty && -w /dev/tty ]] || die 'a terminal is required to authorize disk setup with sudo'
    cat <<EOF

Disk setup will now use sudo to:
  * erase and repartition $TARGET_DISK;
  * create and open the LUKS2 container as /dev/mapper/$LUKS_NAME;
  * create the Btrfs filesystem and subvolumes; and
  * mount the prepared root, home, and EFI filesystems below $MOUNT_ROOT.
EOF
    sudo -v || die 'sudo authorization failed; no disk changes made'
  fi
  prompt_luks_passphrase
  trap cleanup_after_failure ERR

  # Clear visible old signatures, then pass an explicit GPT layout to sfdisk.
  # sfdisk also wipes signatures that fall within the new partitions.  Ask the
  # kernel to reread the new table before formatting its partition devices.
  log "Erasing partition and filesystem signatures on $TARGET_DISK"
  run_privileged wipefs --all --force "$TARGET_DISK"
  run_privileged sfdisk --wipe always --wipe-partitions always "$TARGET_DISK" <<EOF
label: gpt
size=$EFI_SIZE, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI"
type=CA7D7CCB-63ED-4C53-861C-1742536059CC, name="cryptroot"
EOF
  run_privileged partprobe "$TARGET_DISK"
  run_privileged udevadm settle

  [[ -b $EFI_PARTITION && -b $CRYPT_PARTITION ]] || die 'partition devices did not appear after partitioning'
  # The ESP is FAT32 because firmware consumes it before Linux is running.
  # Its label is informational and does not participate in root mounting.
  run_privileged mkfs.fat -F 32 -n EFI "$EFI_PARTITION"

  log "Creating and opening LUKS2 container as $LUKS_NAME"
  printf '%s' "$LUKS_PASSPHRASE" | run_privileged cryptsetup luksFormat --type luks2 --batch-mode --key-file=- "$CRYPT_PARTITION"
  printf '%s' "$LUKS_PASSPHRASE" | run_privileged cryptsetup open --key-file=- "$CRYPT_PARTITION" "$LUKS_NAME"
  unset LUKS_PASSPHRASE
  LUKS_OPENED=1

  # Mount Btrfs top-level ID 5 only long enough to create the intended install
  # subvolumes.  Never extract the stage3 while this staging mount is active.
  run_privileged mkfs.btrfs --force --label "$BTRFS_LABEL" --data single --metadata dup "/dev/mapper/$LUKS_NAME"
  run_privileged mkdir -p "$MOUNT_ROOT"
  run_privileged mount -o subvolid=5 "/dev/mapper/$LUKS_NAME" "$MOUNT_ROOT"
  MOUNTED_ROOT=1
  run_privileged btrfs subvolume create "$MOUNT_ROOT/$ROOT_SUBVOL"
  run_privileged btrfs subvolume create "$MOUNT_ROOT/$HOME_SUBVOL"
  run_privileged umount "$MOUNT_ROOT"
  MOUNTED_ROOT=0

  # These are the root/home options later expected in fstab.  Named subvolumes,
  # rather than numeric IDs, keep recovery commands and fstab auditable.
  run_privileged mount -o "subvol=$ROOT_SUBVOL,noatime,compress=zstd:1" "/dev/mapper/$LUKS_NAME" "$MOUNT_ROOT"
  MOUNTED_ROOT=1
  run_privileged mkdir -p "$MOUNT_ROOT/home" "$MOUNT_ROOT/boot"
  run_privileged mount -o "subvol=$HOME_SUBVOL,noatime,compress=zstd:1" "/dev/mapper/$LUKS_NAME" "$MOUNT_ROOT/home"
  MOUNTED_HOME=1
  run_privileged mount "$EFI_PARTITION" "$MOUNT_ROOT/boot"
  MOUNTED_EFI=1
  run_privileged mkdir -p "$MOUNT_ROOT/boot/EFI"

  if ! verify_disk_setup; then
    printf 'error: disk setup verification failed; stopping before later phases.\n' >&2
    cleanup_after_failure 1
  fi
  trap - ERR

  log 'Disk setup complete'
  run_privileged findmnt -R "$MOUNT_ROOT"
  cat <<EOF

The encrypted filesystem remains open at /dev/mapper/$LUKS_NAME and mounted at
$MOUNT_ROOT for the next installer phase.  The passphrase has been discarded
from this script's shell state.
EOF
}

# Stage3 bootstrap support

download_file() {
  local url=$1 destination=$2

  if command -v curl >/dev/null 2>&1; then
    run_privileged curl --fail --location --proto '=https' --tlsv1.2 --output "$destination" "$url"
  else
    run_privileged wget --https-only --secure-protocol=TLSv1_2 --output-document="$destination" "$url"
  fi
}

verify_pinned_release_signature() {
  local signed_file=$1 verified_file=$2 status_output

  # GnuPG reports the signing subkey and its primary key through VALIDSIG.
  # A good signature alone is insufficient because the downloaded key bundle
  # contains more than one public key; require Gentoo's pinned primary key.
  # --decrypt handles a clear-signed file: it verifies its signature and
  # writes only its authenticated plaintext to verified_file.  --verify alone
  # checks the signature but deliberately does not extract that plaintext.
  status_output=$(run_privileged gpg --batch --homedir "$STAGE_GPG_HOME" \
    --status-fd=1 --output "$verified_file" --decrypt "$signed_file")
  printf '%s\n' "$status_output" | awk -v expected="$GENTOO_AUTOMATED_RELEASE_FINGERPRINT" '
    $1 == "[GNUPG:]" && $2 == "VALIDSIG" && toupper($12) == expected { found = 1 }
    END { exit !found }
  ' || die "signature is not made by Gentoo's pinned automated-release key: ${signed_file##*/}"
}

cleanup_stage3_bootstrap_failure() {
  local exit_code=${1:-$?}

  (( exit_code == 0 )) && return
  trap - ERR EXIT
  set +e
  # These locations are made by mktemp in this invocation.  Leave the mounted
  # install layout intact; a failed download or verification must not undo it.
  [[ -n ${STAGE_WORKDIR:-} ]] && run_privileged rm -rf -- "$STAGE_WORKDIR"
  for mountpoint in "$MOUNT_ROOT/run" "$MOUNT_ROOT/dev" "$MOUNT_ROOT/sys" "$MOUNT_ROOT/proc"; do
    run_privileged umount --recursive "$mountpoint" 2>/dev/null || true
  done
  run_privileged umount "$MOUNT_ROOT/boot" 2>/dev/null || true
  run_privileged umount "$MOUNT_ROOT/home" 2>/dev/null || true
  run_privileged umount "$MOUNT_ROOT" 2>/dev/null || true
  if run_privileged cryptsetup status "$LUKS_NAME" >/dev/null 2>&1; then
    run_privileged cryptsetup close "$LUKS_NAME" || true
  fi
  printf 'error: stage3 bootstrap did not complete; temporary files, mounts, and the LUKS mapper were cleaned up.\n' >&2
  exit "$exit_code"
}

confirm_expected_bootstrap_target_state() {
  local entry
  local -a unexpected=()

  # disk-setup leaves only the empty @home mount and the ESP's empty EFI
  # directory below the root mount.  A normal full rerun recreates this state.
  while IFS= read -r entry; do
    case ${entry##*/} in
      home|boot) ;;
      *) unexpected+=("$entry") ;;
    esac
  done < <(find "$MOUNT_ROOT" -mindepth 1 -maxdepth 1 -print)
  while IFS= read -r entry; do unexpected+=("$entry"); done \
    < <(find "$MOUNT_ROOT/home" -mindepth 1 -maxdepth 1 -print)
  while IFS= read -r entry; do
    [[ ${entry##*/} == EFI ]] || unexpected+=("$entry")
  done < <(find "$MOUNT_ROOT/boot" -mindepth 1 -maxdepth 1 -print)
  if [[ ! -d $MOUNT_ROOT/boot/EFI ]]; then
    unexpected+=("missing directory: $MOUNT_ROOT/boot/EFI")
  else
    while IFS= read -r entry; do unexpected+=("$entry"); done \
      < <(find "$MOUNT_ROOT/boot/EFI" -mindepth 1 -maxdepth 1 -print)
  fi

  ((${#unexpected[@]})) || return 0
  printf '\nUnexpected stage3-bootstrap target state:\n' >&2
  printf '  %s\n' "${unexpected[@]}" >&2
  printf 'The normal full installer rerun recreates an empty target before this phase.\n' >&2
  confirm_phase 'stage3 bootstrap with this unexpected target state'
}

stage3_bootstrap() {
  local command source stage3_filename stage3_size stage3_url
  local latest_manifest latest_verified archive sha256 sha256_verified release_keys
  local manifest_archive manifest_size manifest_extra

  if (( VERBOSE )); then
    cat <<EOF
Stage3 bootstrap: verified desktop-systemd base system
======================================================

The selected stage is Gentoo Release Engineering's AMD64 desktop-systemd
archive.  The signed latest-stage manifest names the current archive; its
example filename below is only a concrete follow-along value and will change
as Gentoo publishes new stage3 releases.

Discover, download, and verify the stage3
-----------------------------------------

The installer obtains Gentoo's release-key bundle, then accepts each signed
manifest only when its signer is Gentoo's pinned automated-release key. Verify
the latest-stage manifest first, then verify the detached checksum manifest
before extracting the archive. Do not accept an archive whose signed checksum
fails.

cd /mnt/gentoo
curl --fail --location --output gentoo-release.asc.20260125.gz https://dev.gentoo.org/~sam/dist/sec-keys/openpgp-keys-gentoo-release/gentoo-release.asc.20260125.gz
gzip --decompress --stdout gentoo-release.asc.20260125.gz | gpg --import
gpg --with-fingerprint --list-keys 13EBBDBEDE7A12775DFDB1BABB572E0E2D182910
wget https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-desktop-systemd/latest-stage3-amd64-desktop-systemd.txt
gpg --output latest-stage3-amd64-desktop-systemd.txt.verified --decrypt latest-stage3-amd64-desktop-systemd.txt

wget https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-desktop-systemd/stage3-amd64-desktop-systemd-20260913T163055Z.tar.xz
wget https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-desktop-systemd/stage3-amd64-desktop-systemd-20260913T163055Z.tar.xz.sha256
gpg --output stage3-amd64-desktop-systemd-20260913T163055Z.tar.xz.sha256.verified --decrypt stage3-amd64-desktop-systemd-20260913T163055Z.tar.xz.sha256
sha256sum --check stage3-amd64-desktop-systemd-20260913T163055Z.tar.xz.sha256.verified

Extract the stage and prepare the chroot
----------------------------------------

Extraction preserves extended attributes and the numeric owners assigned by
Release Engineering.  The resolver copy and slave bind mounts make the new
system usable for the next chroot-based configuration phase without allowing
mount events to propagate back into the live environment.

tar xpf stage3-amd64-desktop-systemd-20260913T163055Z.tar.xz --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/resolv.conf
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-rslave /mnt/gentoo/run

The bootstrap phase intentionally stops before entering the chroot or changing
Portage configuration; those belong to the next semantic phase.
EOF
  fi

  log 'Phase: stage3-bootstrap'

  for command in readlink lsblk; do
    require_command "$command"
  done
  [[ -n $TARGET_DISK ]] || die 'stage3-bootstrap requires --disk DEVICE to verify the prepared layout'
  TARGET_DISK=$(readlink -f -- "$TARGET_DISK")
  [[ -b $TARGET_DISK ]] || die "target is not a block device: $TARGET_DISK"
  [[ $MOUNT_ROOT == /* && $MOUNT_ROOT != / ]] || die "mount root must be a non-root absolute path: $MOUNT_ROOT"
  for command in "$LUKS_NAME" "$BTRFS_LABEL" "$ROOT_SUBVOL" "$HOME_SUBVOL"; do
    [[ $command =~ ^[A-Za-z0-9._@+-]+$ ]] || die "unsupported characters in layout name: $command"
  done
  [[ $ROOT_SUBVOL != "$HOME_SUBVOL" ]] || die 'root and home subvolume names must differ'
  case ${TARGET_DISK##*/} in
    *[0-9]) EFI_PARTITION=${TARGET_DISK}p1; CRYPT_PARTITION=${TARGET_DISK}p2 ;;
    *) EFI_PARTITION=${TARGET_DISK}1; CRYPT_PARTITION=${TARGET_DISK}2 ;;
  esac

  if [[ $MODE == dry-run ]]; then
    cat <<EOF

Stage3 bootstrap plan
  * verify the mounted disk-setup layout below $MOUNT_ROOT;
  * validate Gentoo's signed latest-stage manifest;
  * download the current AMD64 desktop-systemd stage3 and validate its signed
    SHA-256 manifest;
  * extract the archive into $MOUNT_ROOT; and
  * prepare DNS and the chroot mounts (/proc, /sys, /dev, /run).

Dry run: no network access or filesystem changes made.
EOF
    return 0
  fi

  for command in awk find grep tar gzip gpg sha256sum stat mount mountpoint cp mktemp; do
    require_command "$command"
  done
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    die 'stage3 bootstrap requires curl or wget to download Gentoo release files'
  fi
  (( EUID == 0 )) || require_command sudo
  for source in /etc/resolv.conf /proc /sys /dev /run; do
    [[ -e $source ]] || die "live environment prerequisite is unavailable: $source"
  done
  for source in "$MOUNT_ROOT/proc" "$MOUNT_ROOT/sys" "$MOUNT_ROOT/dev" "$MOUNT_ROOT/run"; do
    ! mountpoint -q "$source" || die "chroot mount already exists: $source"
  done

  confirm_phase 'stage3 bootstrap'
  if (( EUID != 0 )); then
    sudo -v || die 'sudo authorization failed; no stage3 files were downloaded'
  fi
  verify_disk_setup || die 'stage3-bootstrap requires a verified disk-setup layout'
  confirm_expected_bootstrap_target_state

  STAGE_WORKDIR=$(run_privileged mktemp -d "$MOUNT_ROOT/.stage3-bootstrap.XXXXXX")
  # The downloads are public release material.  Keep the workspace traversable
  # so the non-privileged parser can read GnuPG's verified output; the GnuPG
  # home itself remains root-only inside this directory.
  run_privileged chmod 755 "$STAGE_WORKDIR"
  # EXIT covers deliberate safety stops via die(); ERR covers failed commands
  # under errexit.  Both leave the validated disk layout itself untouched.
  trap 'cleanup_stage3_bootstrap_failure $?' ERR EXIT
  STAGE_GPG_HOME=$(run_privileged mktemp -d "$STAGE_WORKDIR/.gnupg.XXXXXX")

  latest_manifest=$STAGE_WORKDIR/$STAGE3_LATEST_MANIFEST
  latest_verified=$latest_manifest.verified
  release_keys=$STAGE_WORKDIR/gentoo-release.asc.20260125.gz
  download_file "$GENTOO_RELEASE_KEYS_URL" "$release_keys"
  run_privileged gzip --decompress --stdout "$release_keys" \
    | run_privileged gpg --batch --homedir "$STAGE_GPG_HOME" --import >/dev/null
  download_file "$STAGE3_BASE_URL/$STAGE3_LATEST_MANIFEST" "$latest_manifest"
  verify_pinned_release_signature "$latest_manifest" "$latest_verified"

  # Accept exactly one release entry from the authenticated manifest.  This
  # forbids URLs, path traversal, other architectures, and other init systems.
  stage3_filename=
  stage3_size=
  # Gentoo's generated manifest may omit a trailing newline, so preserve its
  # final record when read reports EOF after assigning that record.
  while IFS=$' \t' read -r manifest_archive manifest_size manifest_extra || [[ -n ${manifest_archive:-} ]]; do
    [[ -z ${manifest_extra:-} ]] || continue
    [[ $manifest_archive =~ ^stage3-amd64-desktop-systemd-[0-9]{8}T[0-9]{6}Z\.tar\.xz$ ]] || continue
    [[ $manifest_size =~ ^[1-9][0-9]*$ ]] || continue
    [[ -z $stage3_filename ]] || die 'signed latest-stage manifest contains multiple matching stage3 archives'
    stage3_filename=$manifest_archive
    stage3_size=$manifest_size
  done <"$latest_verified"
  [[ -n $stage3_filename ]] || die 'signed latest-stage manifest does not name an AMD64 desktop-systemd stage3 archive'

  stage3_url=$STAGE3_BASE_URL/$stage3_filename
  archive=$STAGE_WORKDIR/$stage3_filename
  sha256=$archive.sha256
  sha256_verified=$sha256.verified
  log "Downloading verified $stage3_filename"
  download_file "$stage3_url" "$archive"
  [[ $(stat --format=%s "$archive") == "$stage3_size" ]] \
    || die "downloaded stage3 size does not match the signed latest-stage manifest"
  download_file "$stage3_url.sha256" "$sha256"
  verify_pinned_release_signature "$sha256" "$sha256_verified"
  grep -Eq "^[[:xdigit:]]{64}[[:space:]]+\\*?$stage3_filename$" "$sha256_verified" \
    || die 'signed SHA-256 manifest does not contain the selected stage3 archive'
  (
    cd "$STAGE_WORKDIR"
    sha256sum --check --status "${sha256_verified##*/}"
  ) || die 'stage3 SHA-256 verification failed'

  log 'Extracting verified stage3 archive'
  run_privileged tar xpf "$archive" --xattrs-include='*.*' --numeric-owner -C "$MOUNT_ROOT"
  run_privileged cp --dereference /etc/resolv.conf "$MOUNT_ROOT/etc/resolv.conf"
  run_privileged mount --types proc /proc "$MOUNT_ROOT/proc"
  run_privileged mount --rbind /sys "$MOUNT_ROOT/sys"
  run_privileged mount --make-rslave "$MOUNT_ROOT/sys"
  run_privileged mount --rbind /dev "$MOUNT_ROOT/dev"
  run_privileged mount --make-rslave "$MOUNT_ROOT/dev"
  run_privileged mount --bind /run "$MOUNT_ROOT/run"
  run_privileged mount --make-rslave "$MOUNT_ROOT/run"

  [[ -x $MOUNT_ROOT/bin/bash && -r $MOUNT_ROOT/etc/resolv.conf ]] \
    || die 'extracted stage3 is missing its shell or resolver configuration'
  for source in "$MOUNT_ROOT/proc" "$MOUNT_ROOT/sys" "$MOUNT_ROOT/dev" "$MOUNT_ROOT/run"; do
    mountpoint -q "$source" || die "required chroot mount is missing: $source"
  done
  run_privileged rm -rf -- "$STAGE_WORKDIR"
  unset STAGE_WORKDIR STAGE_GPG_HOME
  trap - ERR EXIT

  log 'Stage3 bootstrap complete'
  cat <<EOF

The verified AMD64 desktop-systemd stage3 is installed at $MOUNT_ROOT.
DNS and /proc, /sys, /dev, and /run are mounted there for the next phase.
EOF
}

# Portage foundation support

valid_target_host() {
  case $1 in
    generic|qemu|thinktop) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup_portage_foundation_failure() {
  local exit_code=${1:-$?}
  local mountpoint

  (( exit_code == 0 )) && return
  trap - ERR EXIT
  set +e
  [[ -n ${PORTAGE_INTERNAL_SCRIPT:-} ]] \
    && run_privileged rm -f -- "$MOUNT_ROOT/run/$PORTAGE_INTERNAL_SCRIPT"
  [[ -n ${PORTAGE_REPOSITORY_GPG_HOME:-} ]] \
    && run_privileged rm -rf -- "$PORTAGE_REPOSITORY_GPG_HOME"
  for mountpoint in "$MOUNT_ROOT/run" "$MOUNT_ROOT/dev" "$MOUNT_ROOT/sys" "$MOUNT_ROOT/proc"; do
    run_privileged umount --recursive "$mountpoint" 2>/dev/null || true
  done
  run_privileged umount "$MOUNT_ROOT/boot" 2>/dev/null || true
  run_privileged umount "$MOUNT_ROOT/home" 2>/dev/null || true
  run_privileged umount "$MOUNT_ROOT" 2>/dev/null || true
  if run_privileged cryptsetup status "$LUKS_NAME" >/dev/null 2>&1; then
    run_privileged cryptsetup close "$LUKS_NAME" || true
  fi
  printf 'error: Portage foundation did not complete; chroot mounts and the LUKS mapper were cleaned up.\n' >&2
  exit "$exit_code"
}

portage_foundation_chroot() {
  local profile locale_choice normalized_locale available_locale

  (( EUID == 0 )) || die 'the internal Portage phase must run as root'
  [[ -r /etc/gentoo-release ]] || die 'the internal Portage phase is not running in a Gentoo target'
  valid_target_host "$TARGET_HOST" || die "unsupported target host: $TARGET_HOST"
  [[ -r /etc/portage/make.conf.d/90-$TARGET_HOST ]] \
    || die "configuration repository does not provide target host: $TARGET_HOST"
  [[ -r /usr/share/zoneinfo/$TARGET_TIMEZONE ]] \
    || die "timezone is unavailable in the target: $TARGET_TIMEZONE"
  [[ $TARGET_LOCALE =~ ^[A-Za-z][A-Za-z_]*\.(UTF-8|utf8)$ ]] \
    || die "locale must be a UTF-8 locale such as en_US.UTF-8: $TARGET_LOCALE"

  for command in eselect locale-gen portageq; do
    require_command "$command"
  done

  # Verify that Portage can parse the common and selected native fragments
  # before repository or locale state is changed.
  portageq envvar COMMON_FLAGS >/dev/null \
    || die 'Portage could not evaluate the installed make.conf layers'

  [[ -d /var/db/repos/gentoo/.git ]] \
    || die 'the installation host did not provide the Gentoo Git work tree'
  portageq repos_config / | grep -Fq 'sync-type = git' \
    || die 'Portage does not report Git synchronization for the Gentoo repository'
  portageq repos_config / | grep -Fq 'sync-uri = https://github.com/gentoo-mirror/gentoo.git' \
    || die 'Portage does not report the expected Gentoo Git synchronization endpoint'

  profile=$(eselect profile show)
  [[ $profile == *desktop/systemd* ]] \
    || die "stage3 profile is not an AMD64 desktop/systemd profile: $profile"

  ln -snf "../usr/share/zoneinfo/$TARGET_TIMEZONE" /etc/localtime
  printf '%s\n' "$TARGET_TIMEZONE" >/etc/timezone
  printf '%s UTF-8\n' "$TARGET_LOCALE" >/etc/locale.gen
  locale-gen
  locale_choice=${TARGET_LOCALE/UTF-8/utf8}
  eselect locale set "$locale_choice"
  env-update

  normalized_locale=${TARGET_LOCALE,,}
  normalized_locale=${normalized_locale//-/}
  available_locale=0
  while IFS= read -r locale_choice; do
    locale_choice=${locale_choice,,}
    locale_choice=${locale_choice//-/}
    if [[ $locale_choice == "$normalized_locale" ]]; then
      available_locale=1
      break
    fi
  done < <(locale -a)
  (( available_locale )) || die "generated locale is unavailable: $TARGET_LOCALE"
  [[ $(readlink -f /etc/localtime) == "/usr/share/zoneinfo/$TARGET_TIMEZONE" ]] \
    || die "timezone link does not resolve to $TARGET_TIMEZONE"

  log 'Portage foundation complete'
  cat <<EOF

Configuration target: $TARGET_HOST
Gentoo profile:       ${profile##*$'\n'}
Timezone:             $TARGET_TIMEZONE
Locale:               $TARGET_LOCALE

The Gentoo ebuild repository now synchronizes through the official Git mirror.
Target-side Git installation and the initial @world update remain intentionally
deferred to the system-update phase.
EOF
}

install_portage_foundation() {
  local command source config_git_dir config_revision signature_status

  if (( VERBOSE )); then
    cat <<'EOF'
Portage foundation: live configuration and Git synchronization
================================================================

The configuration repository is a bare Git database whose work tree is the
installed system itself. Files below /etc and /usr/local are therefore both
operational configuration and tracked files; no deployment copy or symlink
farm separates edits from version control. Common Portage policy is loaded
before the explicitly selected host fragment.

Install the configuration work tree
-----------------------------------

mkdir -p /var/lib/gentoo-config
git clone --bare --single-branch --branch main https://github.com/grahamlopez/gentoo-configs.git /var/lib/gentoo-config/repository.git
git --git-dir=/var/lib/gentoo-config/repository.git config core.bare false
git --git-dir=/var/lib/gentoo-config/repository.git config core.worktree /
git --git-dir=/var/lib/gentoo-config/repository.git config status.showUntrackedFiles no
git --git-dir=/var/lib/gentoo-config/repository.git --work-tree=/ checkout --force main
printf '%s\n' 'GENTOO_TARGET_HOST="qemu"' >/etc/gentoo-config/target-host

mkdir -p /mnt/gentoo/var/db/repos
git clone --depth 1 https://github.com/gentoo-mirror/gentoo.git /mnt/gentoo/var/db/repos/gentoo
GNUPGHOME=/tmp/gentoo-repository-keys
mkdir -m 700 "$GNUPGHOME"
gpg --homedir "$GNUPGHOME" --import /mnt/gentoo/usr/share/openpgp-keys/gentoo-release.asc
GNUPGHOME="$GNUPGHOME" git -C /mnt/gentoo/var/db/repos/gentoo verify-commit HEAD
rm -rf "$GNUPGHOME"

Configure the target from inside the chroot
-------------------------------------------

chroot /mnt/gentoo /bin/bash
portageq repos_config /
eselect profile show
ln -snf ../usr/share/zoneinfo/America/New_York /etc/localtime
printf '%s\n' America/New_York >/etc/timezone
printf '%s UTF-8\n' en_US.UTF-8 >/etc/locale.gen
locale-gen
eselect locale set en_US.utf8
env-update

This phase validates the effective Portage configuration and repository but
does not update @world. That update belongs after all common and host-specific
policy is established.
EOF
  fi

  log 'Phase: portage-foundation'

  valid_target_host "$TARGET_HOST" || die "unsupported target host: $TARGET_HOST"
  [[ -n $CONFIG_SOURCE && $CONFIG_SOURCE != *$'\n'* ]] || die 'configuration source must be a non-empty single line'
  [[ -n $CONFIG_BRANCH && $CONFIG_BRANCH != -* && $CONFIG_BRANCH != *$'\n'* ]] \
    || die 'configuration branch must be a non-empty branch name'
  [[ $TARGET_TIMEZONE =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)+$ && $TARGET_TIMEZONE != *..* ]] \
    || die "unsupported timezone syntax: $TARGET_TIMEZONE"
  [[ $TARGET_LOCALE =~ ^[A-Za-z][A-Za-z_]*\.(UTF-8|utf8)$ ]] \
    || die "locale must be a UTF-8 locale such as en_US.UTF-8: $TARGET_LOCALE"
  [[ -n $TARGET_DISK ]] || die 'portage-foundation requires --disk DEVICE to verify the prepared layout'
  TARGET_DISK=$(readlink -f -- "$TARGET_DISK")
  [[ -b $TARGET_DISK ]] || die "target is not a block device: $TARGET_DISK"
  case ${TARGET_DISK##*/} in
    *[0-9]) EFI_PARTITION=${TARGET_DISK}p1; CRYPT_PARTITION=${TARGET_DISK}p2 ;;
    *) EFI_PARTITION=${TARGET_DISK}1; CRYPT_PARTITION=${TARGET_DISK}2 ;;
  esac

  if [[ $MODE == dry-run ]]; then
    cat <<EOF

Portage foundation plan
  * install configuration branch $CONFIG_BRANCH from $CONFIG_SOURCE;
  * select the common plus $TARGET_HOST Portage layers;
  * clone and authenticate the Gentoo Git repository from the installation host;
  * verify the existing AMD64 desktop/systemd profile;
  * configure timezone $TARGET_TIMEZONE and locale $TARGET_LOCALE; and
  * stop before the initial @world update.

Dry run: no repository, chroot, or target configuration changes made.
EOF
    return 0
  fi

  for command in chroot git gpg install mktemp mountpoint readlink tee; do
    require_command "$command"
  done
  git check-ref-format --branch "$CONFIG_BRANCH" >/dev/null \
    || die "invalid configuration branch name: $CONFIG_BRANCH"
  (( EUID == 0 )) || require_command sudo
  if (( EUID != 0 )); then
    sudo -v || die 'sudo authorization failed; no Portage configuration changes made'
  fi
  verify_disk_setup || die 'portage-foundation requires a verified disk-setup layout'
  [[ -x $MOUNT_ROOT/bin/bash && -r $MOUNT_ROOT/etc/gentoo-release ]] \
    || die 'portage-foundation requires an extracted Gentoo stage3'
  for source in "$MOUNT_ROOT/proc" "$MOUNT_ROOT/sys" "$MOUNT_ROOT/dev" "$MOUNT_ROOT/run"; do
    mountpoint -q "$source" || die "required chroot mount is missing: $source"
  done
  [[ ! -e $MOUNT_ROOT/var/lib/gentoo-config/repository.git ]] \
    || die 'configuration repository already exists in the target; perform the normal full installer rerun'

  confirm_phase 'Portage foundation'
  trap 'cleanup_portage_foundation_failure $?' ERR EXIT

  run_privileged install -d -m 755 "$MOUNT_ROOT/var/lib/gentoo-config"
  run_privileged git clone --bare --single-branch --branch "$CONFIG_BRANCH" \
    "$CONFIG_SOURCE" "$MOUNT_ROOT/var/lib/gentoo-config/repository.git"
  config_git_dir=$MOUNT_ROOT/var/lib/gentoo-config/repository.git
  run_privileged git --git-dir="$config_git_dir" config core.bare false
  run_privileged git --git-dir="$config_git_dir" config core.worktree /
  run_privileged git --git-dir="$config_git_dir" config status.showUntrackedFiles no
  run_privileged git --git-dir="$config_git_dir" --work-tree="$MOUNT_ROOT" checkout --force "$CONFIG_BRANCH"
  config_revision=$(run_privileged git --git-dir="$config_git_dir" rev-parse "$CONFIG_BRANCH^{commit}")

  run_privileged install -d -m 755 "$MOUNT_ROOT/etc/gentoo-config"
  printf 'GENTOO_TARGET_HOST="%s"\n' "$TARGET_HOST" \
    | run_privileged tee "$MOUNT_ROOT/etc/gentoo-config/target-host" >/dev/null
  printf '%s\n' "$CONFIG_SOURCE" | run_privileged tee "$MOUNT_ROOT/etc/gentoo-config/source" >/dev/null
  printf '%s\n' "$CONFIG_BRANCH" | run_privileged tee "$MOUNT_ROOT/etc/gentoo-config/branch" >/dev/null
  printf '%s\n' "$config_revision" | run_privileged tee "$MOUNT_ROOT/etc/gentoo-config/revision" >/dev/null

  [[ -r $MOUNT_ROOT/usr/share/openpgp-keys/gentoo-release.asc ]] \
    || die 'the stage3 does not provide the Gentoo release-key bundle'
  run_privileged install -d -m 755 "$MOUNT_ROOT/var/db/repos"
  run_privileged git clone --depth 1 "$GENTOO_REPOSITORY_URL" "$MOUNT_ROOT/var/db/repos/gentoo"
  PORTAGE_REPOSITORY_GPG_HOME=$(run_privileged mktemp -d "$MOUNT_ROOT/.gentoo-repository-keys.XXXXXX")
  run_privileged gpg --batch --homedir "$PORTAGE_REPOSITORY_GPG_HOME" --import \
    "$MOUNT_ROOT/usr/share/openpgp-keys/gentoo-release.asc" >/dev/null
  signature_status=$(run_privileged env GNUPGHOME="$PORTAGE_REPOSITORY_GPG_HOME" \
    git -C "$MOUNT_ROOT/var/db/repos/gentoo" verify-commit --raw HEAD 2>&1) \
    || die 'the Gentoo repository tip does not have a valid signature'
  grep -Fq "$GENTOO_REPOSITORY_SIGNING_FINGERPRINT" <<<"$signature_status" \
    || die 'the Gentoo repository tip was not signed by the pinned repository key'
  run_privileged rm -rf -- "$PORTAGE_REPOSITORY_GPG_HOME"
  unset PORTAGE_REPOSITORY_GPG_HOME

  PORTAGE_INTERNAL_SCRIPT=$PROGRAM.portage.$$
  run_privileged install -m 700 "$0" "$MOUNT_ROOT/run/$PORTAGE_INTERNAL_SCRIPT"
  run_privileged chroot "$MOUNT_ROOT" /usr/bin/env -i \
    HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    TERM="${TERM:-dumb}" /bin/bash "/run/$PORTAGE_INTERNAL_SCRIPT" \
    --internal-portage-chroot --target-host "$TARGET_HOST" \
    --timezone "$TARGET_TIMEZONE" --locale "$TARGET_LOCALE"
  run_privileged rm -f -- "$MOUNT_ROOT/run/$PORTAGE_INTERNAL_SCRIPT"
  unset PORTAGE_INTERNAL_SCRIPT
  trap - ERR EXIT

  log 'Portage foundation installed'
  cat <<EOF

Configuration source:   $CONFIG_SOURCE
Configuration branch:   $CONFIG_BRANCH
Configuration revision: $config_revision
Configuration target:   $TARGET_HOST

The bare configuration repository is stored at
/var/lib/gentoo-config/repository.git with / as its live work tree.
EOF
}

main() {
  parse_args "$@"
  if (( INTERNAL_PORTAGE_CHROOT )); then
    portage_foundation_chroot
    return
  fi
  if is_selected disk-setup; then
    disk_setup
  fi
  if is_selected stage3-bootstrap; then
    stage3_bootstrap
  fi
  if is_selected portage-foundation; then
    install_portage_foundation
  fi
}

main "$@"
