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

verification_error() {
  printf 'error: disk setup verification failed: %s\n' "$*" >&2
  return 1
}

mount_uses_subvolume() {
  local mountpoint=$1 expected_subvolume=$2 options option

  options=$(findmnt --noheadings --output OPTIONS --target "$mountpoint") || return 1
  IFS=, read -r -a options <<<"$options"
  for option in "${options[@]}"; do
    [[ $option == "subvol=$expected_subvolume" || $option == "subvol=/$expected_subvolume" ]] && return 0
  done
  return 1
}

verify_disk_setup() {
  # This is deliberately a production check rather than an assertion embedded
  # in the setup commands.  QEMU integration tests can source this script and
  # call it against a real prepared disk without duplicating the checks.
  local efi_type crypt_type mapper_device luks_version filesystem_type label
  local mount_source mount_fstype target_disk_name subvolume

  for command in lsblk readlink awk cryptsetup blkid btrfs findmnt mountpoint; do
    command -v "$command" >/dev/null 2>&1 \
      || verification_error "required command is unavailable: $command" || return 1
  done

  [[ $(lsblk --noheadings --output PTTYPE "$TARGET_DISK" | awk 'NR == 1 { print tolower($1) }') == gpt ]] \
    || verification_error "target does not have a GPT partition table: $TARGET_DISK" || return 1
  target_disk_name=${TARGET_DISK##*/}
  [[ $(lsblk --noheadings --output PKNAME "$EFI_PARTITION" | awk 'NR == 1 { print $1 }') == "$target_disk_name" ]] \
    || verification_error "EFI partition is not on the target disk: $EFI_PARTITION" || return 1
  [[ $(lsblk --noheadings --output PKNAME "$CRYPT_PARTITION" | awk 'NR == 1 { print $1 }') == "$target_disk_name" ]] \
    || verification_error "LUKS partition is not on the target disk: $CRYPT_PARTITION" || return 1

  efi_type=$(lsblk --noheadings --output PARTTYPE "$EFI_PARTITION" | awk 'NR == 1 { print tolower($1) }')
  crypt_type=$(lsblk --noheadings --output PARTTYPE "$CRYPT_PARTITION" | awk 'NR == 1 { print tolower($1) }')
  [[ $efi_type == c12a7328-f81f-11d2-ba4b-00a0c93ec93b ]] \
    || verification_error "EFI partition has the wrong GPT type: $EFI_PARTITION" || return 1
  [[ $crypt_type == ca7d7ccb-63ed-4c53-861c-1742536059cc ]] \
    || verification_error "LUKS partition has the wrong GPT type: $CRYPT_PARTITION" || return 1
  [[ $(blkid --output value --match-tag TYPE "$EFI_PARTITION") == vfat ]] \
    || verification_error "EFI partition is not FAT: $EFI_PARTITION" || return 1

  cryptsetup isLuks "$CRYPT_PARTITION" >/dev/null 2>&1 \
    || verification_error "partition is not a LUKS container: $CRYPT_PARTITION" || return 1
  luks_version=$(cryptsetup luksDump "$CRYPT_PARTITION" 2>/dev/null | awk -F: '$1 ~ /^[[:space:]]*Version$/ { gsub(/[[:space:]]/, "", $2); print $2; exit }')
  [[ $luks_version == 2 ]] \
    || verification_error "LUKS container is not LUKS2: $CRYPT_PARTITION" || return 1
  [[ -b /dev/mapper/$LUKS_NAME ]] \
    || verification_error "LUKS mapper is missing: /dev/mapper/$LUKS_NAME" || return 1
  mapper_device=$(cryptsetup status "$LUKS_NAME" 2>/dev/null | awk 'tolower($1) == "device:" { print $2; exit }')
  [[ -n $mapper_device && $(readlink -f -- "$mapper_device") == $(readlink -f -- "$CRYPT_PARTITION") ]] \
    || verification_error "LUKS mapper does not use the intended partition: /dev/mapper/$LUKS_NAME" || return 1

  filesystem_type=$(blkid --output value --match-tag TYPE "/dev/mapper/$LUKS_NAME")
  label=$(blkid --output value --match-tag LABEL "/dev/mapper/$LUKS_NAME")
  [[ $filesystem_type == btrfs ]] \
    || verification_error "mapper does not contain Btrfs: /dev/mapper/$LUKS_NAME" || return 1
  [[ $label == "$BTRFS_LABEL" ]] \
    || verification_error "Btrfs label is not $BTRFS_LABEL" || return 1
  for subvolume in "$ROOT_SUBVOL" "$HOME_SUBVOL"; do
    btrfs subvolume list "$MOUNT_ROOT" | awk -v expected="$subvolume" '
      / path / { sub(/^.* path /, ""); if ($0 == expected) found = 1 }
      END { exit !found }
    ' || verification_error "Btrfs subvolume is missing: $subvolume" || return 1
  done

  for mountpoint in "$MOUNT_ROOT" "$MOUNT_ROOT/home" "$MOUNT_ROOT/efi"; do
    mountpoint -q "$mountpoint" \
      || verification_error "expected mount is missing: $mountpoint" || return 1
  done
  for mountpoint in "$MOUNT_ROOT" "$MOUNT_ROOT/home"; do
    mount_source=$(findmnt --noheadings --output SOURCE --target "$mountpoint")
    mount_fstype=$(findmnt --noheadings --output FSTYPE --target "$mountpoint")
    [[ $(readlink -f -- "$mount_source") == $(readlink -f -- "/dev/mapper/$LUKS_NAME") && $mount_fstype == btrfs ]] \
      || verification_error "Btrfs mount has the wrong source or type: $mountpoint" || return 1
  done
  mount_uses_subvolume "$MOUNT_ROOT" "$ROOT_SUBVOL" \
    || verification_error "root mount does not use subvolume $ROOT_SUBVOL: $MOUNT_ROOT" || return 1
  mount_uses_subvolume "$MOUNT_ROOT/home" "$HOME_SUBVOL" \
    || verification_error "home mount does not use subvolume $HOME_SUBVOL: $MOUNT_ROOT/home" || return 1
  mount_source=$(findmnt --noheadings --output SOURCE --target "$MOUNT_ROOT/efi")
  mount_fstype=$(findmnt --noheadings --output FSTYPE --target "$MOUNT_ROOT/efi")
  [[ $(readlink -f -- "$mount_source") == $(readlink -f -- "$EFI_PARTITION") && $mount_fstype == vfat ]] \
    || verification_error "EFI mount has the wrong source or type: $MOUNT_ROOT/efi" || return 1
}

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

disk_setup() {
  local command value mountpoint source backing_disk

  if (( VERBOSE )); then
    cat <<'EOF'
Disk setup: target protection, layout, and mount mechanics
==========================================================

The installer accepts one whole block device and derives its partitions.  For
example, /dev/nvme0n1 becomes /dev/nvme0n1p1 and /dev/nvme0n1p2.

The target must have lsblk type `disk`; partitions, /dev/mapper entries, and
ordinary paths are rejected.  The script then protects disks backing /, /boot,
/efi, or /boot/efi, as well as mounted or active-swap descendants.

The target receives a GPT containing two partitions: a FAT32 EFI System
Partition (default 1 GiB, GPT type EF00) and a LUKS2 container using the
remainder (type 8309).  The ESP stays outside LUKS because UEFI firmware must
read the later boot image before Linux can decrypt the root filesystem.

The LUKS partition opens as /dev/mapper/<luks-name>.  Btrfs is formatted there,
not on the raw partition, so the filesystem, subvolume metadata, and later
Gentoo files are encrypted.  `--data single` is appropriate for one device;
`--metadata dup` retains two metadata copies on that device and is standard
practice as recommended by upstream.

The fresh Btrfs top level, normally subvolume ID 5, is mounted temporarily only
to create @ and @home.  The stage3 must later be unpacked after @ is remounted
as <mount-root>.  @home is mounted separately at <mount-root>/home so system
snapshots can exclude home by default.  Named `subvol=@` paths are simpler to
inspect in fstab and recovery commands than numeric IDs.

`noatime,compress=zstd:1` is a conservative initial root/home mount policy
to start.  Do not add `ssd` or `space_cache=v2`: modern Btrfs handles those
automatically.  Do not globally enable autodefrag, nodatacow, nodatasum, or
compress-force without a workload-specific reason; they can harm snapshot or
integrity behavior.

The printed lsblk table and layout plan are the checks to read before applying
the plan.
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
    [[ $EUID -eq 0 ]] || die 'disk setup must run as root'
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
  prompt_luks_passphrase
  trap cleanup_after_failure ERR

  # Erase old signatures and both GPT copies, then create a fresh GPT.  Ask the
  # kernel to reread it and wait for the new partition devices before formatting.
  log "Erasing partition and filesystem signatures on $TARGET_DISK"
  wipefs --all --force "$TARGET_DISK"
  sgdisk --zap-all "$TARGET_DISK"
  sgdisk --clear \
    --new=1:0:+"$EFI_SIZE" --typecode=1:ef00 --change-name=1:EFI \
    --new=2:0:0 --typecode=2:8309 --change-name=2:cryptroot \
    "$TARGET_DISK"
  partprobe "$TARGET_DISK"
  udevadm settle

  [[ -b $EFI_PARTITION && -b $CRYPT_PARTITION ]] || die 'partition devices did not appear after partitioning'
  # The ESP is FAT32 because firmware consumes it before Linux is running.
  # Its label is informational and does not participate in root mounting.
  mkfs.fat --fat 32 --name EFI "$EFI_PARTITION"

  log "Creating and opening LUKS2 container as $LUKS_NAME"
  printf '%s' "$LUKS_PASSPHRASE" | cryptsetup luksFormat --type luks2 --batch-mode --key-file=- "$CRYPT_PARTITION"
  printf '%s' "$LUKS_PASSPHRASE" | cryptsetup open --key-file=- "$CRYPT_PARTITION" "$LUKS_NAME"
  unset LUKS_PASSPHRASE
  LUKS_OPENED=1

  # Mount Btrfs top-level ID 5 only long enough to create the intended install
  # subvolumes.  Never extract the stage3 while this staging mount is active.
  mkfs.btrfs --force --label "$BTRFS_LABEL" --data single --metadata dup "/dev/mapper/$LUKS_NAME"
  mkdir -p "$MOUNT_ROOT"
  mount -o subvolid=5 "/dev/mapper/$LUKS_NAME" "$MOUNT_ROOT"
  MOUNTED_ROOT=1
  btrfs subvolume create "$MOUNT_ROOT/$ROOT_SUBVOL"
  btrfs subvolume create "$MOUNT_ROOT/$HOME_SUBVOL"
  umount "$MOUNT_ROOT"
  MOUNTED_ROOT=0

  # These are the root/home options later expected in fstab.  Named subvolumes,
  # rather than numeric IDs, keep recovery commands and fstab auditable.
  mount -o "subvol=$ROOT_SUBVOL,noatime,compress=zstd:1" "/dev/mapper/$LUKS_NAME" "$MOUNT_ROOT"
  MOUNTED_ROOT=1
  mkdir -p "$MOUNT_ROOT/home" "$MOUNT_ROOT/efi"
  mount -o "subvol=$HOME_SUBVOL,noatime,compress=zstd:1" "/dev/mapper/$LUKS_NAME" "$MOUNT_ROOT/home"
  MOUNTED_HOME=1
  mount "$EFI_PARTITION" "$MOUNT_ROOT/efi"
  MOUNTED_EFI=1

  if ! verify_disk_setup; then
    printf 'error: disk setup verification failed; stopping before later phases.\n' >&2
    cleanup_after_failure 1
  fi
  trap - ERR

  log 'Disk setup complete'
  findmnt -R "$MOUNT_ROOT"
  cat <<EOF

The encrypted filesystem remains open at /dev/mapper/$LUKS_NAME and mounted at
$MOUNT_ROOT for the next installer phase.  The passphrase has been discarded
from this script's shell state.
EOF
}

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
  if (( MOUNTED_EFI )); then umount "$MOUNT_ROOT/efi"; fi
  if (( MOUNTED_HOME )); then umount "$MOUNT_ROOT/home"; fi
  if (( MOUNTED_ROOT )); then umount "$MOUNT_ROOT"; fi
  if (( LUKS_OPENED )); then cryptsetup close "$LUKS_NAME"; fi
  unset LUKS_PASSPHRASE 2>/dev/null || true
  printf 'error: disk setup did not complete; mounts created by this run were cleaned up.\n' >&2
  exit "$exit_code"
}

main() {
  parse_args "$@"
  if is_selected disk-setup; then
    disk_setup
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
