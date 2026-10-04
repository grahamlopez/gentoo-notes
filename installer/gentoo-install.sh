#!/usr/bin/env bash
#
# Repeatable Gentoo installer — first milestone
#
# This file is both the executable installer and its canonical design record.
# Each phase begins with its own readable explanation immediately beside the
# code that implements it.  Run with `--verbose` to print the technical notes
# for each selected phase, or read the source directly.
#
# This installer currently owns one phase:
#   disk-setup: validate the target, then create GPT → EFI → LUKS2 → Btrfs →
#   @ + @home.
#
# It executes selected phases by default.  Use --dry-run to print plans without
# making changes.  Disk setup also requires confirmation of the exact target.
# Later phases will install the stage3,
# configure Portage, build the kernel, and install the UKI.

if [[ -z ${BASH_VERSION:-} ]]; then
  printf 'error: this installer requires Bash.\n' >&2
  exit 1
fi

set -Eeuo pipefail
IFS=$'\n\t'

readonly PROGRAM=${0##*/}
readonly DEFAULT_EFI_SIZE='1G'

TARGET_DISK=${TARGET_DISK:-}
LUKS_NAME=${LUKS_NAME:-cryptroot}
BTRFS_LABEL=${BTRFS_LABEL:-GENTOO}
ROOT_SUBVOL=${ROOT_SUBVOL:-@}
HOME_SUBVOL=${HOME_SUBVOL:-@home}
EFI_SIZE=${EFI_SIZE:-$DEFAULT_EFI_SIZE}
MOUNT_ROOT=${MOUNT_ROOT:-/mnt/gentoo}
MODE=apply
ASSUME_YES=0
SELECTED_PHASES=(disk-setup)
VERBOSE=0

EFI_PARTITION=
CRYPT_PARTITION=
MOUNTED_ROOT=0
MOUNTED_HOME=0
MOUNTED_EFI=0
LUKS_OPENED=0

PHASE_ORDER=(disk-setup)

usage() {
  cat <<EOF
Usage: $PROGRAM --disk DEVICE [options]

Install the selected Gentoo phases.  The current milestone prepares an
encrypted Btrfs disk layout; later milestones will add the remaining install.

Required:
  --disk DEVICE              Whole block device to erase, for example /dev/nvme0n1

Options:
  --dry-run                  Print plans and perform no changes.
  --yes                      Automatically continue through ordinary phase and
                              destructive-action confirmations.  This never
                              supplies, skips, or infers secret input.
  --verbose                  Print technical notes and detailed phase output.
                              It does not affect execution or confirmations.
  --phase NAME               Run a named phase (currently: disk-setup).
                              May be repeated as later phases are added.
  --luks-name NAME           Mapper name after opening LUKS (default: $LUKS_NAME).
  --btrfs-label LABEL        Btrfs volume label (default: $BTRFS_LABEL).
  --root-subvol NAME         Root Btrfs subvolume (default: $ROOT_SUBVOL).
  --home-subvol NAME         Home Btrfs subvolume (default: $HOME_SUBVOL).
  --efi-size SIZE            EFI partition size, e.g. 1G (default: $EFI_SIZE).
  --mount-root PATH          Where prepared filesystems remain mounted
                              (default: $MOUNT_ROOT).
  -h, --help                 Show this help.

Environment overrides mirror these options: TARGET_DISK, LUKS_NAME,
BTRFS_LABEL, ROOT_SUBVOL, HOME_SUBVOL, EFI_SIZE, and MOUNT_ROOT.

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
  for mountpoint in "$MOUNT_ROOT" "$MOUNT_ROOT/home" "$MOUNT_ROOT/efi"; do
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
  mount_source=$(run_privileged findmnt --noheadings --output SOURCE --target "$MOUNT_ROOT/efi")
  mount_fstype=$(run_privileged findmnt --noheadings --output FSTYPE --target "$MOUNT_ROOT/efi")
  [[ $(readlink -f -- "$mount_source") == $(readlink -f -- "$EFI_PARTITION") && $mount_fstype == vfat ]] \
    || verification_error "EFI mount has the wrong source or type: $MOUNT_ROOT/efi" || return 1
}

# Disk setup presentation, input, and recovery

print_plan() {
  cat <<EOF

Installation disk plan
  $TARGET_DISK
  ├─ $EFI_PARTITION: EFI System Partition, FAT32, $EFI_SIZE → $MOUNT_ROOT/efi
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
  if (( MOUNTED_EFI )); then run_privileged umount "$MOUNT_ROOT/efi"; fi
  if (( MOUNTED_HOME )); then run_privileged umount "$MOUNT_ROOT/home"; fi
  if (( MOUNTED_ROOT )); then run_privileged umount "$MOUNT_ROOT"; fi
  if (( LUKS_OPENED )); then run_privileged cryptsetup close "$LUKS_NAME"; fi
  unset LUKS_PASSPHRASE 2>/dev/null || true
  printf 'error: disk setup did not complete; mounts created by this run were cleaned up.\n' >&2
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
sgdisk --zap-all /dev/nvme0n1
sgdisk --clear \
  --new=1:0:+1G --typecode=1:ef00 --change-name=1:EFI \
  --new=2:0:0 --typecode=2:8309 --change-name=2:cryptroot \
  /dev/nvme0n1

partprobe /dev/nvme0n1
udevadm settle

Create the EFI, LUKS, and Btrfs layers
---------------------------------------

The LUKS partition opens as /dev/mapper/<luks-name>.  Btrfs is formatted there,
not on the raw partition, so the filesystem, subvolume metadata, and later
Gentoo files are encrypted.  `--data single` is appropriate for one device;
`--metadata dup` retains two metadata copies on that device and is standard
practice as recommended by upstream.

mkfs.fat --fat 32 --name EFI /dev/nvme0n1p1
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

mount -o subvol=@,noatime,compress=zstd:1 /dev/mapper/cryptroot /mnt/gentoo
mkdir -p /mnt/gentoo/home /mnt/gentoo/efi
mount -o subvol=@home,noatime,compress=zstd:1 /dev/mapper/cryptroot /mnt/gentoo/home
mount /dev/nvme0n1p1 /mnt/gentoo/efi

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
    for command in sgdisk wipefs partprobe udevadm mkfs.fat cryptsetup mkfs.btrfs btrfs mount umount mountpoint blkid; do
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

  # Erase old signatures and both GPT copies, then create a fresh GPT.  Ask the
  # kernel to reread it and wait for the new partition devices before formatting.
  log "Erasing partition and filesystem signatures on $TARGET_DISK"
  run_privileged wipefs --all --force "$TARGET_DISK"
  run_privileged sgdisk --zap-all "$TARGET_DISK"
  run_privileged sgdisk --clear \
    --new=1:0:+"$EFI_SIZE" --typecode=1:ef00 --change-name=1:EFI \
    --new=2:0:0 --typecode=2:8309 --change-name=2:cryptroot \
    "$TARGET_DISK"
  run_privileged partprobe "$TARGET_DISK"
  run_privileged udevadm settle

  [[ -b $EFI_PARTITION && -b $CRYPT_PARTITION ]] || die 'partition devices did not appear after partitioning'
  # The ESP is FAT32 because firmware consumes it before Linux is running.
  # Its label is informational and does not participate in root mounting.
  run_privileged mkfs.fat --fat 32 --name EFI "$EFI_PARTITION"

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
  run_privileged mkdir -p "$MOUNT_ROOT/home" "$MOUNT_ROOT/efi"
  run_privileged mount -o "subvol=$HOME_SUBVOL,noatime,compress=zstd:1" "/dev/mapper/$LUKS_NAME" "$MOUNT_ROOT/home"
  MOUNTED_HOME=1
  run_privileged mount "$EFI_PARTITION" "$MOUNT_ROOT/efi"
  MOUNTED_EFI=1

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

main() {
  parse_args "$@"
  if is_selected disk-setup; then
    disk_setup
  fi
}

main "$@"
