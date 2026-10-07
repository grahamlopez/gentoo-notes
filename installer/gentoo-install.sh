#!/usr/bin/env bash
#
# Repeatable Gentoo installer — first milestone
#
# This file is both the executable installer and its canonical design record.
# Each phase begins with its own readable explanation immediately beside the
# code that implements it.  Run with `--verbose` to print the technical notes
# for each selected phase, or read the source directly.
#
# This installer currently owns seven phases:
#   disk-setup: validate the target, then create GPT → EFI → LUKS2 → Btrfs →
#   @ + @home.
#   stage3-bootstrap: obtain and verify the current official AMD64 desktop-
#   systemd stage3, extract it, and prepare a chroot environment.
#   portage-foundation: install the live configuration work tree, configure
#   Portage for Git synchronization, and establish locale and timezone.
#   system-update: establish CPU policy, update @world, and review configuration.
#   kernel-foundation: install the binary distribution kernel, firmware, and
#   broad initramfs, then validate EFI files and register QEMU firmware offline.
#   first-boot-foundation: configure mounts, identity, root login, minimal
#   networking, persistent journal, time synchronization and Btrfs scrubbing.
#   handoff: verify and unmount the target, close LUKS, and print boot guidance.
#
# It executes selected phases by default.  Use --dry-run to print plans without
# making changes.  Disk setup also requires confirmation of the exact target.
# kernel-foundation prepares the distribution fallback and QEMU EFI entry.
# Physical EFI registration and actual boot verification remain manual; custom kernels
# are built after installation.

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
SELECTED_PHASES=(disk-setup stage3-bootstrap portage-foundation system-update kernel-foundation first-boot-foundation handoff)
VERBOSE=0
INTERNAL_PORTAGE_CHROOT=0
INTERNAL_UPDATE_CHROOT=0
INTERNAL_KERNEL_CHROOT=0
TARGET_MICROCODE=${TARGET_MICROCODE:-auto}
TARGET_SOF_FIRMWARE=
QEMU_VARS=${QEMU_VARS:-}
QEMU_VARS_TEMPLATE=${QEMU_VARS_TEMPLATE:-/usr/share/edk2/x64/OVMF_VARS.4m.fd}
TARGET_HOSTNAME=${TARGET_HOSTNAME:-}
INTERNAL_FIRSTBOOT_OFFLINE=0
TARGET_CPU_FLAGS=${TARGET_CPU_FLAGS:-}

EFI_PARTITION=
CRYPT_PARTITION=
MOUNTED_ROOT=0
MOUNTED_HOME=0
MOUNTED_EFI=0
LUKS_OPENED=0

PHASE_ORDER=(disk-setup stage3-bootstrap portage-foundation system-update kernel-foundation first-boot-foundation handoff)

usage() {
  cat <<EOF
Usage: $PROGRAM --disk DEVICE [options]

Install the selected Gentoo phases.  The current milestone prepares an
encrypted Btrfs disk, bootstraps the verified stage3, and establishes the
target's Portage configuration, then updates the base system and prepares
the distribution kernel for direct EFI boot, then configures first boot.

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
                              stage3-bootstrap, portage-foundation, system-update,
                              kernel-foundation, first-boot-foundation, handoff). May be
                              repeated; phases run in installer order.
  --config-source SOURCE     Public Git URL or local repository path
                              (default: $CONFIG_SOURCE).
  --config-branch BRANCH     Configuration branch to install
                              (default: $CONFIG_BRANCH).
  --target-host NAME         Configuration target: generic, qemu, thinktop, or startop
                              (default: $TARGET_HOST).
  --hostname NAME            Target hostname; defaults to named target-host, prompts
                              for generic/qemu (or preserves existing hostname).
  --cpu-flags FLAGS          Explicit CPU_FLAGS_X86 flags for another target;
                              otherwise detect the running CPU.
  --microcode KIND           auto, intel, amd, or none (default: $TARGET_MICROCODE).
                              auto detects the installation host CPU vendor.
  --qemu-vars FILE           Persistent raw OVMF variable store for target qemu;
                              required for its kernel-foundation phase.
  --qemu-vars-template FILE  Matching OVMF template used only for a new store
                              (default: $QEMU_VARS_TEMPLATE).
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
CONFIG_BRANCH, TARGET_HOST, TARGET_TIMEZONE, TARGET_LOCALE, TARGET_CPU_FLAGS,
TARGET_MICROCODE, TARGET_HOSTNAME, QEMU_VARS, and QEMU_VARS_TEMPLATE.
SOF audio firmware is selected by the target's gentoo-config fragments.

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
    sudo -p "Host administrator password for %p (authorizes this installer; does not set a Gentoo password): " -- "$@"
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
      --disk|--phase|--luks-name|--btrfs-label|--root-subvol|--home-subvol|--efi-size|--mount-root|--config-source|--config-branch|--target-host|--timezone|--locale|--cpu-flags|--microcode|--qemu-vars|--qemu-vars-template|--hostname)
        (($# >= 2)) && [[ $2 != --* ]] \
          || die "$1 requires a value; use $PROGRAM --help for examples"
        ;;
    esac
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
      --cpu-flags)
        (($# >= 2)) || die '--cpu-flags requires a flag list'
        TARGET_CPU_FLAGS=$2
        shift
        ;;
      --cpu-flags=*) TARGET_CPU_FLAGS=${1#*=} ;;
      --microcode)
        (($# >= 2)) || die '--microcode requires auto, intel, amd, or none'
        TARGET_MICROCODE=$2
        shift
        ;;
      --microcode=*) TARGET_MICROCODE=${1#*=} ;;
      --qemu-vars)
        (($# >= 2)) || die '--qemu-vars requires a file path'
        QEMU_VARS=$2
        shift
        ;;
      --qemu-vars=*) QEMU_VARS=${1#*=} ;;
      --qemu-vars-template)
        QEMU_TEMPLATE_EXPLICIT=1
        (($# >= 2)) || die '--qemu-vars-template requires a file path'
        QEMU_VARS_TEMPLATE=$2
        shift
        ;;
      --qemu-vars-template=*) QEMU_TEMPLATE_EXPLICIT=1; QEMU_VARS_TEMPLATE=${1#*=} ;;
      --hostname)
        (($# >= 2)) || die '--hostname requires a value'
        TARGET_HOSTNAME=$2
        shift
        ;;
      --hostname=*) TARGET_HOSTNAME=${1#*=} ;;
      --internal-firstboot-offline) INTERNAL_FIRSTBOOT_OFFLINE=1 ;;
      --internal-kernel-chroot) INTERNAL_KERNEL_CHROOT=1 ;;
      --internal-update-chroot) INTERNAL_UPDATE_CHROOT=1 ;;
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

# Validate user inputs before any phase can modify the disk. Target-side state
# and execution prerequisites remain checked where the phases use them.
validate_arguments() {
  local -a errors=()
  local option value normalized
  valid_target_host "$TARGET_HOST" || errors+=("--target-host '$TARGET_HOST' is unknown; choose generic, qemu, thinktop, or startop. Use --hostname for a custom machine name.")
  case $TARGET_MICROCODE in
    auto|intel|amd|none) ;;
    *) errors+=("--microcode must be auto, intel, amd, or none.") ;;
  esac
  [[ $EFI_SIZE =~ ^[1-9][0-9]*[MmGg]$ ]] || errors+=("--efi-size must be a positive size such as 1G or 512M.")
  normalized=$(readlink -m -- "$MOUNT_ROOT")
  [[ $MOUNT_ROOT == /* && $normalized != / && $MOUNT_ROOT != *$'\n'* ]] \
    || errors+=("--mount-root must be an absolute directory other than /, such as /mnt/gentoo.")
  for option in LUKS_NAME BTRFS_LABEL ROOT_SUBVOL HOME_SUBVOL; do
    value=${!option}
    [[ $value =~ ^[A-Za-z0-9._@+-]+$ && $value != . && $value != .. ]] \
      || errors+=("$option must be a nonempty name using letters, numbers, dots, underscores, @, +, or hyphens; '.' and '..' are not allowed.")
  done
  [[ $ROOT_SUBVOL != "$HOME_SUBVOL" ]] || errors+=("--root-subvol and --home-subvol must differ.")
  [[ -z $TARGET_HOSTNAME || ( ${#TARGET_HOSTNAME} -le 63 && $TARGET_HOSTNAME =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ) ]] \
    || errors+=("--hostname must be one DNS label of at most 63 characters, with letters, numbers, and internal hyphens.")
  [[ $TARGET_LOCALE =~ ^[A-Za-z][A-Za-z_]*\.(UTF-8|utf8)$ ]] \
    || errors+=("--locale must be a UTF-8 locale such as en_US.UTF-8.")
  [[ $TARGET_TIMEZONE =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ && -f /usr/share/zoneinfo/$TARGET_TIMEZONE ]] \
    || errors+=("--timezone must name an installed timezone, such as America/New_York; see /usr/share/zoneinfo.")
  [[ -z $TARGET_CPU_FLAGS || $TARGET_CPU_FLAGS =~ ^[a-z0-9_]+([[:blank:]][a-z0-9_]+)*$ ]] \
    || errors+=("--cpu-flags must be a space-separated list of lowercase CPU flag names.")
  [[ -n $CONFIG_SOURCE && $CONFIG_SOURCE != -* && $CONFIG_SOURCE != *$'\n'* && $CONFIG_SOURCE != *$'\r'* ]] \
    || errors+=("--config-source must be a nonempty Git URL or local repository path.")
  if command -v git >/dev/null 2>&1; then
    git check-ref-format --branch "$CONFIG_BRANCH" >/dev/null 2>&1 \
      || errors+=("--config-branch must be a valid Git branch name, such as main.")
  else
    errors+=("Install git so --config-branch can be validated before installation.")
  fi
  if [[ -z $TARGET_DISK ]]; then
    errors+=("--disk is required; use lsblk to identify the separate whole target disk.")
  elif [[ ! -b $TARGET_DISK ]]; then
    errors+=("--disk '$TARGET_DISK' is not an available block device; check lsblk.")
  elif [[ $(lsblk -dn -o TYPE "$TARGET_DISK") != disk ]]; then
    errors+=("--disk must identify a whole disk, not a partition or encrypted mapping; check lsblk.")
  fi
  if [[ $TARGET_HOST != qemu && ( -n $QEMU_VARS || ${QEMU_TEMPLATE_EXPLICIT:-0} == 1 ) ]]; then
    errors+=("--qemu-vars and --qemu-vars-template apply only to --target-host qemu; omit them for a physical target.")
  fi
  if [[ $TARGET_HOST == qemu ]]; then
    if is_selected kernel-foundation && [[ -z $QEMU_VARS ]]; then
      errors+=("--target-host qemu needs --qemu-vars FILE for kernel-foundation. Choose a new path in your VM directory, such as /path/to/VM/OVMF_VARS.4m.fd; the installer creates it from the OVMF template. See installer/QEMU-NBD-INSTALL.md.")
    fi
    if [[ -n $QEMU_VARS ]]; then
      [[ $QEMU_VARS != *$'\n'* && $QEMU_VARS != *$'\r'* && ! -L $QEMU_VARS && ( ! -e $QEMU_VARS || -f $QEMU_VARS ) ]] \
        || errors+=("--qemu-vars must be a regular file path, not a symlink or directory.")
      [[ -d $(dirname -- "$QEMU_VARS") ]] || errors+=("Create the parent directory for --qemu-vars before running the installer.")
      if is_selected kernel-foundation && [[ ! -e $QEMU_VARS ]]; then
        [[ -f $QEMU_VARS_TEMPLATE && -r $QEMU_VARS_TEMPLATE ]] \
          || errors+=("--qemu-vars-template is unavailable; install OVMF or supply a readable template matching your VM's OVMF CODE file.")
      fi
    fi
  fi
  if ((${#errors[@]})); then
    printf 'Please correct these arguments before continuing:\n' >&2
    printf '  * %s\n' "${errors[@]}" >&2
    exit 1
  fi
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
  printf 'New target disk LUKS passphrase: ' >/dev/tty
  IFS= read -r -s first </dev/tty || die 'could not read LUKS passphrase'
  printf '\nConfirm target LUKS passphrase: ' >/dev/tty
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

  cat <<EOF

Stage3 bootstrap plan
  * verify the mounted disk-setup layout below $MOUNT_ROOT;
  * validate Gentoo's signed latest-stage manifest;
  * download the current AMD64 desktop-systemd stage3 and validate its signed
    SHA-256 manifest;
  * extract the archive into $MOUNT_ROOT; and
  * prepare DNS and the chroot mounts (/proc, /sys, /dev, /run).
EOF
  if [[ $MODE == dry-run ]]; then
    printf '\nDry run: no network access or filesystem changes made.\n'
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
    generic|qemu|thinktop|startop) return 0 ;;
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
  local command source config_git_dir config_revision signature_status planned_profile

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
    planned_profile='existing AMD64 desktop/systemd profile (verified during execution)'
  else
    require_command chroot
    (( EUID == 0 )) || require_command sudo
    [[ -x $MOUNT_ROOT/bin/bash && -r $MOUNT_ROOT/etc/gentoo-release ]] \
      || die 'portage-foundation requires an extracted Gentoo stage3'
    # The stage3 profile symlink exists before its repository is populated.
    # Read its target without resolving the not-yet-installed profiles tree.
    planned_profile=$(run_privileged readlink "$MOUNT_ROOT/etc/portage/make.profile")
    planned_profile=${planned_profile##*/profiles/}
    [[ -n $planned_profile ]] || die 'stage3 profile link is missing'
  fi
  cat <<EOF

Portage foundation plan
Configuration target: $TARGET_HOST
Gentoo profile:       $planned_profile
Timezone:             $TARGET_TIMEZONE
Locale:               $TARGET_LOCALE

  * install configuration branch $CONFIG_BRANCH from $CONFIG_SOURCE;
  * select the common plus $TARGET_HOST Portage layers;
  * clone and authenticate the Gentoo Git repository;
  * verify the existing profile and configure timezone and locale; and
  * stop before the initial @world update.
EOF
  if [[ $MODE == dry-run ]]; then
    printf '\nDry run: no repository, chroot, or target configuration changes made.\n'
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


# System update: reconcile the stage3 with the configured target policy.
# Upstream references:
# https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Base
# https://wiki.gentoo.org/wiki/CPU_FLAGS_*
# https://wiki.gentoo.org/wiki/Dispatch-conf
# https://wiki.gentoo.org/wiki/Upgrading_Gentoo

pending_config_updates() {
  local protect path
  local -a paths
  protect=$(portageq envvar CONFIG_PROTECT)
  IFS=' ' read -r -a paths <<<"$protect"
  for path in "${paths[@]}"; do
    [[ -d $path ]] || continue
    find "$path" -type f -name '._cfg????_*' -print
  done
}

system_update_chroot() {
  local flags pending archive_dir
  (( EUID == 0 )) || die 'the internal system update must run as root'
  [[ -r /etc/gentoo-release && -d /var/lib/gentoo-config/repository.git ]] \
    || die 'system-update requires the Gentoo target and configuration repository'
  [[ -r /etc/portage/make.conf.d/90-$TARGET_HOST ]] \
    || die 'the selected target configuration is missing'
  valid_target_host "$TARGET_HOST" || die 'unsupported system-update target'
  grep -Fxq "GENTOO_TARGET_HOST=\"$TARGET_HOST\"" /etc/gentoo-config/target-host \
    || die 'system-update target differs from the installed Portage foundation'
  require_command emerge
  require_command portageq
  require_command eselect
  require_command dispatch-conf
  require_command emaint
  if [[ -n $TARGET_CPU_FLAGS ]]; then
    [[ $TARGET_CPU_FLAGS =~ ^[a-z0-9_]+([[:blank:]][a-z0-9_]+)*$ ]] || die 'invalid CPU flag list'
  fi
  portageq envvar COMMON_FLAGS >/dev/null
  # Explicitly disable binary consumption even if inherited configuration enables it.
  emerge --oneshot --noreplace --usepkg=n --getbinpkg=n dev-vcs/git app-portage/cpuid2cpuflags
  emaint --auto sync
  # news list can return 1 after successfully listing items; read displays titles too.
  eselect news read
  emerge --oneshot --usepkg=n --getbinpkg=n sys-apps/portage

  flags=$TARGET_CPU_FLAGS
  if [[ -z $flags ]]; then
    flags=$(cpuid2cpuflags)
    [[ $flags == 'CPU_FLAGS_X86: '* ]] || die 'CPU detection did not return CPU_FLAGS_X86'
    flags=${flags#CPU_FLAGS_X86: }
  fi
  [[ $flags =~ ^[a-z0-9_]+([[:blank:]][a-z0-9_]+)*$ ]] || die 'invalid CPU flag list'
  install -d /etc/portage/package.use
  printf '*/* cpu_flags_x86: %s\n' "$flags" >/etc/portage/package.use/00cpu-flags
  printf 'Target CPU flags: %s\n' "$flags"
  emerge --pretend --verbose --update --deep --newuse --usepkg=n --getbinpkg=n @world
  confirm_phase 'initial world update (review relevant news above)'
  emerge --verbose --update --deep --newuse --usepkg=n --getbinpkg=n @world

  pending=$(pending_config_updates)
  if [[ -n $pending ]]; then
    printf '\nConfiguration updates awaiting review:\n%s\n' "$pending"
    [[ -r /dev/tty && -w /dev/tty ]] \
      || die 'configuration review requires a terminal; rerun system-update interactively'
    # Read the archive setting as data, never source the configuration as shell code.
    archive_dir=$(sed -n 's/^[[:space:]]*archive-dir[[:space:]]*=[[:space:]]*//p' /etc/dispatch-conf.conf | tail -n 1)
    archive_dir=${archive_dir:-/etc/config-archive}
    [[ $archive_dir == /* ]] || die 'dispatch-conf archive-dir must be absolute'
    install -d -m 700 "$archive_dir"
    dispatch-conf </dev/tty >/dev/tty 2>&1
    pending=$(pending_config_updates)
    [[ -z $pending ]] || die "configuration updates remain unresolved: $pending"
  fi
  emerge --verbose --usepkg=n --getbinpkg=n @preserved-rebuild
  pending=$(pending_config_updates)
  [[ -z $pending ]] || die "rebuilds left configuration updates requiring review: $pending"
  git --git-dir=/var/lib/gentoo-config/repository.git --work-tree=/ --no-pager diff --stat
  printf '\nReview configuration changes with: gentoo-config diff\n'
  printf 'CPU policy is stored in /etc/portage/package.use/00cpu-flags.\n'
  printf 'No dependency cleanup is performed in this phase.\n'
}

install_system_update() {
  local source status=0
  log 'Phase: system-update'
  if (( VERBOSE )); then
    cat <<'EOF'
System update: reconcile the base system with target policy
==========================================================

Install tools and synchronize repositories
------------------------------------------

Install target-side Git and CPU detection tools from source, synchronize
repositories, and read Gentoo news before approving the initial world update.

emerge --oneshot --noreplace --usepkg=n --getbinpkg=n dev-vcs/git app-portage/cpuid2cpuflags
emaint --auto sync
eselect news read
emerge --oneshot --usepkg=n --getbinpkg=n sys-apps/portage

Update Portage first so the world update uses the current package manager.

Establish target CPU policy
---------------------------

CPU flags default to the running machine. When preparing another machine,
provide --cpu-flags with that machine's supported flags. QEMU must expose the
same features (the runbook uses -cpu host). The detected or supplied flags are
written to /etc/portage/package.use/00cpu-flags before updating @world.
Compilation settings are inherited unchanged from the configuration files.

cpuid2cpuflags
printf '*/* cpu_flags_x86: %s\n' "$flags" >/etc/portage/package.use/00cpu-flags

Review and update the base system
---------------------------------

Show the proposed package changes and ask before proceeding with the update.

emerge --pretend --verbose --update --deep --newuse --usepkg=n --getbinpkg=n @world
emerge --verbose --update --deep --newuse --usepkg=n --getbinpkg=n @world

Review configuration and rebuild consumers
------------------------------------------

When protected configuration updates exist, prepare the archive directory
specified in /etc/dispatch-conf.conf and review updates with dispatch-conf.
Unresolved updates stop the phase. --yes does not answer merge choices.
Then rebuild preserved-library consumers and show tracked configuration changes.

install -d -m 700 "$archive_dir"
dispatch-conf
emerge --verbose --usepkg=n --getbinpkg=n @preserved-rebuild
git --git-dir=/var/lib/gentoo-config/repository.git --work-tree=/ --no-pager diff --stat
gentoo-config diff

This phase stops before kernel installation and does not clean dependencies.
A failed update leaves the target mounted so this phase can be resumed.
EOF
  fi
  cat <<EOF

System update plan
Target root:          $MOUNT_ROOT
Configuration target: $TARGET_HOST
CPU flags:            ${TARGET_CPU_FLAGS:-detect from the running machine}

  * install Git and CPU detection tools, synchronize repositories, and read news;
  * save target CPU flags and review the proposed @world update;
  * ask before updating packages with the existing compilation settings;
  * review pending configuration updates interactively with dispatch-conf; and
  * rebuild preserved-library consumers and show configuration changes.
EOF
  if [[ $MODE == dry-run ]]; then
    printf '\nDry run: no packages, CPU policy, or configuration files changed.\n'
    return
  fi
  require_command chroot
  require_command mountpoint
  (( EUID == 0 )) || require_command sudo
  [[ -n $TARGET_DISK ]] || die 'system-update requires --disk DEVICE'
  TARGET_DISK=$(readlink -f -- "$TARGET_DISK")
  [[ -b $TARGET_DISK ]] || die "target is not a block device: $TARGET_DISK"
  case ${TARGET_DISK##*/} in
    *[0-9]) EFI_PARTITION=${TARGET_DISK}p1; CRYPT_PARTITION=${TARGET_DISK}p2 ;;
    *) EFI_PARTITION=${TARGET_DISK}1; CRYPT_PARTITION=${TARGET_DISK}2 ;;
  esac
  verify_disk_setup || die 'system-update requires a verified disk layout'
  [[ -r $MOUNT_ROOT/etc/gentoo-release ]] || die 'the Gentoo target is missing'
  for source in proc sys dev run; do
    mountpoint -q "$MOUNT_ROOT/$source" || die "required chroot mount is missing: $source"
  done
  confirm_phase 'system update'
  # Preserve the mounted target on failure so builds and merges can be resumed.
  local internal_script=/run/$PROGRAM.update.$$
  local -a update_options=()
  (( ASSUME_YES == 0 )) || update_options+=(--yes)
  run_privileged install -m 700 "$0" "$MOUNT_ROOT$internal_script"
  # Keep cleanup in the same root process: sudo credentials may expire during
  # the build. Cleanup warnings must not replace the update's exit status.
  run_privileged /bin/bash -c '
    target_root=$1
    helper=$2
    shift 2
    cleanup_update_helper() {
      local update_status=$?
      trap - EXIT
      if ! rm -f -- "$target_root$helper"; then
        printf "Warning: could not remove temporary update helper: %s\n" \
          "$target_root$helper" >&2
      fi
      exit "$update_status"
    }
    trap cleanup_update_helper EXIT
    chroot "$target_root" /usr/bin/env -i \
      HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      TERM="${TERM:-dumb}" /bin/bash "$helper" "$@"
  ' "$PROGRAM-update" "$MOUNT_ROOT" "$internal_script" \
    --internal-update-chroot --target-host "$TARGET_HOST" \
    --cpu-flags "$TARGET_CPU_FLAGS" "${update_options[@]}" || status=$?
  (( status == 0 )) || die 'system-update did not complete; target remains mounted for review and retry'
  log 'System update complete: ready for kernel installation'
}

# Distribution kernel foundation: independent from the later custom EFI image.
# Upstream references:
# https://wiki.gentoo.org/wiki/Distribution_Kernel
# https://wiki.gentoo.org/wiki/Installkernel
# https://wiki.gentoo.org/wiki/Dracut
# https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Kernel

# Resolve the vendor-level microcode choice without pruning firmware files.
# Auto microcode reads the running installation host, not the destination CPU;
# cross-vendor installations must provide an explicit --microcode selection.
resolve_kernel_firmware_policy() {
  case $TARGET_MICROCODE in
    auto)
      local vendor
      vendor=$(awk -F: '/vendor_id/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' /proc/cpuinfo)
      case $vendor in
        GenuineIntel) TARGET_MICROCODE=intel ;;
        AuthenticAMD) TARGET_MICROCODE=amd ;;
        *) die 'CPU vendor is unknown; specify --microcode intel, amd, or none' ;;
      esac
      ;;
    intel|amd|none) ;;
    *) die 'microcode must be auto, intel, amd, or none' ;;
  esac
}

# Read firmware requirements from the installed configuration's common and host
# shell fragments. Validate the resolved SOF value rather than duplicating target
# hardware choices in command-line switches or installer defaults.
read_kernel_firmware_policy() {
  local root=$1 directory SOF_FIRMWARE=
  directory=${root%/}/etc/gentoo-config/kernel-firmware.d
  valid_target_host "$TARGET_HOST" || die "unsupported kernel target: $TARGET_HOST"
  [[ -f $directory/00-common && ! -L $directory/00-common ]] \
    || die "missing firmware policy: $directory/00-common; update the target gentoo-config checkout"
  source "$directory/00-common"
  if [[ -e $directory/90-$TARGET_HOST || -L $directory/90-$TARGET_HOST ]]; then
    [[ -f $directory/90-$TARGET_HOST && ! -L $directory/90-$TARGET_HOST ]] \
      || die "firmware policy is not a regular file: $directory/90-$TARGET_HOST"
    source "$directory/90-$TARGET_HOST"
  fi
  case $SOF_FIRMWARE in
    yes|no) TARGET_SOF_FIRMWARE=$SOF_FIRMWARE ;;
    *) die "SOF_FIRMWARE must be yes or no in $directory" ;;
  esac
}

# Write policy supplied on stdin, replacing only regular installer-marked files.
# Unmarked files and symlinks stop the phase for the user to inspect and reconcile;
# the marker permits full replacement, including any edits that retained it.
kernel_policy_file() {
  local path=$1 content
  content=$(cat)
  if [[ -e $path || -L $path ]]; then
    [[ -f $path && ! -L $path ]] || die "kernel policy is not a regular file: $path"
    grep -Fxq '# Managed by gentoo-install kernel-foundation.' "$path" \
      || die "existing kernel policy requires manual review: $path"
  fi
  printf '%s\n' "$content" >"$path"
}

# Record target boot parameters or ESP identity, allowing retries with the same value.
# An existing file must be regular, not a symlink, and contain matching text;
# a conflict stops the phase rather than silently changing the boot target.
kernel_target_data() {
  local path=$1 value=$2
  if [[ -e $path || -L $path ]]; then
    [[ -f $path && ! -L $path && $(cat "$path") == "$value" ]] \
      || die "existing target boot data requires manual review: $path"
  fi
  printf '%s\n' "$value" >"$path"
}

# Check host-side offline firmware prerequisites before installing packages.
# Require an explicit VM store and a stopped VM; a new store needs a matching
# raw OVMF template, while existing stores retain their firmware state.
check_qemu_firmware() {
  [[ $TARGET_HOST == qemu ]] || {
    [[ -z $QEMU_VARS ]] || die '--qemu-vars is only valid for target qemu'
    return
  }
  [[ -n $QEMU_VARS ]] || die 'target qemu requires --qemu-vars FILE for offline EFI registration'
  [[ $QEMU_VARS != *$'\n'* ]] || die 'QEMU variable-store path must be a single line'
  [[ ! -L $QEMU_VARS ]] || die 'QEMU variable store must not be a symlink'
  QEMU_VARS=$(readlink -m -- "$QEMU_VARS")
  [[ -d ${QEMU_VARS%/*} ]] || die 'create the QEMU variable-store parent directory first'
  require_command virt-fw-vars
  require_command jq
  require_command fuser
  if [[ -e $QEMU_VARS ]]; then
    [[ -f $QEMU_VARS ]] || die 'QEMU variable store must be a regular raw OVMF file'
    if run_privileged fuser -s "$QEMU_VARS"; then
      die 'QEMU variable store is in use; stop the VM before offline registration'
    fi
  else
    [[ -f $QEMU_VARS_TEMPLATE && -r $QEMU_VARS_TEMPLATE ]] \
      || die "matching OVMF template is unavailable: $QEMU_VARS_TEMPLATE"
  fi
  local source=$QEMU_VARS_TEMPLATE
  [[ ! -e $QEMU_VARS ]] || source=$QEMU_VARS
  run_privileged virt-fw-vars --input "$source" --print >/dev/null \
    || die 'cannot read the raw OVMF variable store'
}

# QEMU ONLY: edit the VM's offline OVMF file with the host virt-fw-vars CLI.
# Physical targets never call this function or write firmware here; their manual
# efibootmgr instructions are printed separately for the destination machine.
# The CLI accepts "EFI-path kernel-arguments" as one --append-boot-filepath value.
# Its file-only device path suits our single-disk VM, but does not bind to an ESP
# GUID. Keep using this store with that VM; do not share it between installations.
# A function subshell scopes temporary-file cleanup; operations remain in the
# main installer and use its existing privilege helper where needed.
register_qemu_distribution_kernel() (
  [[ $TARGET_HOST == qemu ]] || return 0
  check_qemu_firmware
  log 'Registering the distribution kernel in QEMU firmware offline'
  set -Eeuo pipefail
  trap "die 'offline QEMU registration failed; target remains mounted for review and retry'" ERR
  umask 077
  vars=$QEMU_VARS template=$QEMU_VARS_TEMPLATE root=$MOUNT_ROOT
  source=$template
  [[ ! -e $vars ]] || source=$vars
  work=$(mktemp -d)
  publish=
  trap 'rm -rf -- "$work"; if [[ -n $publish ]]; then run_privileged rm -f -- "$publish"; fi' EXIT
  version=$(run_privileged sed -n '2p' "$root/etc/kernel/gentoo-dist.version")
  [[ $(run_privileged head -n 1 "$root/etc/kernel/gentoo-dist.version") == '# Managed by gentoo-install kernel-foundation.'
     && $version =~ ^[A-Za-z0-9._+-]+-gentoo-dist(-bin)?$ ]]
  kernel="\\EFI\\Gentoo\\kernel-$version.efi"
  initrd="\\EFI\\Gentoo\\initramfs-$version.img"
  run_privileged test -s "$root/boot/EFI/Gentoo/kernel-$version.efi"
  run_privileged test -s "$root/boot/EFI/Gentoo/initramfs-$version.img"
  cmdline=$(run_privileged cat "$root/etc/kernel/gentoo-dist.cmdline")
  [[ -n $cmdline && $cmdline != *$'\n'* && $cmdline != *$'\r'* ]]
  run_privileged virt-fw-vars --input "$source" --output-json /dev/stdout >"$work/before.json"
  # Only the QEMU VM store is passed to the CLI, never the host's live EFI variables.
  run_privileged virt-fw-vars --input "$source" --output "$work/appended.fd" \
    --append-boot-filepath "$kernel $cmdline console=tty0 console=ttyS0,115200n8 initrd=$initrd"
  run_privileged virt-fw-vars --input "$work/appended.fd" --output-json /dev/stdout >"$work/appended.json"
  # Identify the CLI-created entry and reuse an identical entry on ordinary retries.
  new=$(jq -er --slurpfile before "$work/before.json" '
    [$before[0].variables[].name] as $names |
    [.variables[] | select(.name | test("^Boot[0-9A-Fa-f]{4}$")) |
     select(.name as $n | $names | index($n) | not)] |
    if length == 1 then .[0].name else error("expected one new boot entry") end
  ' "$work/appended.json")
  entry=$(jq -er --arg name "$new" '.variables[] | select(.name == $name) | .data' "$work/appended.json")
  matching=$(jq -er --arg data "$entry" --arg new "$new" '
    [.variables[] | select(.name | test("^Boot[0-9A-Fa-f]{4}$")) |
     select(.name != $new and .data == $data) | .name] |
    if length > 1 then error("duplicate matching boot entries require review")
    else .[0] // $new end
  ' "$work/appended.json")
  # BootOrder is a sequence of little-endian 16-bit entry numbers. Move the selected
  # entry first while retaining all other entries; jq edits only this JSON variable.
  number="${matching:6:2}${matching:4:2}"
  appended_number="${new:6:2}${new:4:2}"
  jq --arg number "${number,,}" --arg appended "${appended_number,,}" '
    [.variables[] | select(.name == "BootOrder") |
     .data = ($number + ([.data | scan("....") | select(ascii_downcase != $number and ascii_downcase != $appended)] | join("")))] |
    {version: 2, variables: .}
  ' "$work/appended.json" >"$work/order.json"
  options=()
  [[ $matching == "$new" ]] || options+=(--delete "$new")
  run_privileged virt-fw-vars --input "$work/appended.fd" --output "$work/final.fd" \
    "${options[@]}" --set-json "$work/order.json"
  run_privileged virt-fw-vars --input "$work/final.fd" --output-json /dev/stdout >"$work/final.json"
  # Verify the selected entry/order and preservation of all previous other variables.
  jq -e --arg selected "$matching" --arg data "$entry" --arg number "${number,,}" \
    --slurpfile before "$work/before.json" '
    any(.variables[]; .name == $selected and .data == $data) and
    any(.variables[]; .name == "BootOrder" and (.data | startswith($number))) and
    (.variables as $after | all($before[0].variables[] | select(.name != "BootOrder");
      . as $old | any($after[]; . == $old)))
  ' "$work/final.json" >/dev/null
  if [[ -e $vars ]]; then
    if cmp -s "$work/before.json" "$work/final.json"; then
      printf 'QEMU firmware already contains %s: %s\n' "$matching" "$kernel"
      exit 0
    fi
    # Recheck immediately before publishing; the VM must stay stopped throughout.
    ! run_privileged fuser -s "$vars" || { printf 'Stop QEMU before updating its firmware store.\n' >&2; exit 1; }
    backup=$(run_privileged mktemp "${vars}.backup-XXXXXX")
    run_privileged cp --preserve=all -- "$vars" "$backup"
    printf 'Previous QEMU firmware store: %s\n' "$backup"
  fi
  # Publish on the destination filesystem so the final rename is atomic.
  publish=$(run_privileged mktemp "${vars}.new-XXXXXX")
  run_privileged cp -- "$work/final.fd" "$publish"
  if [[ -e $vars ]]; then
    run_privileged chown --reference="$vars" "$publish"
    run_privileged chmod --reference="$vars" "$publish"
  else
    run_privileged chown --reference="${vars%/*}" "$publish"
    run_privileged chmod 600 "$publish"
  fi
  run_privileged mv -f -- "$publish" "$vars"
  publish=
  printf 'Registered QEMU %s: %s\nVM firmware store: %s\n' "$matching" "$kernel" "$vars"
)

# Inspect the installed release and initramfs for matching EFI/kernel artifacts,
# encrypted-root tools, boot drivers, microcode, and any installed NVIDIA modules.
# These checks validate boot ingredients; successful boot still needs a VM or hardware.
verify_distribution_kernel() {
  local version=$1 image=/boot/EFI/Gentoo/kernel-$1.efi
  local initrd=/boot/EFI/Gentoo/initramfs-$1.img listing modules driver filename
  [[ -s $image && -s $initrd && -s /lib/modules/$version/modules.dep ]] \
    || die "kernel, initramfs, or module dependency index is missing for $version"
  [[ $(head -c 2 "$image") == MZ ]] || die 'distribution kernel is not an EFI executable'
  grep -Fxq 'CONFIG_EFI_STUB=y' "/lib/modules/$version/build/.config" \
    || die 'distribution kernel does not provide EFI stub support'
  cmp -s "$image" "/lib/modules/$version/vmlinuz" \
    || die 'EFI image differs from the installed distribution kernel'
  modules=$(lsinitrd -m "$initrd")
  for driver in crypt btrfs; do
    grep -Eq "^[[:space:]]*$driver[[:space:]]*$" <<<"$modules" \
      || die "initramfs lacks the Dracut $driver module"
  done
  listing=$(lsinitrd "$initrd")
  grep -Eq '[ /](systemd-)?cryptsetup([[:space:]]|$)' <<<"$listing" \
    || die 'initramfs lacks a LUKS unlock executable'
  # Check the installed kernel's drivers, never the currently running host's.
  for driver in btrfs dm_crypt nvme ahci virtio_pci virtio_blk usbhid hid_generic xhci_pci atkbd; do
    filename=$(modinfo -k "$version" -F filename "$driver")
    if [[ $filename != '(builtin)' ]]; then
      filename=${filename##*/}
      grep -Fq "$filename" <<<"$listing" || die "initramfs lacks $driver ($filename)"
    fi
  done
  if [[ $TARGET_MICROCODE != none ]]; then
    local microcode_blob=AuthenticAMD.bin
    [[ $TARGET_MICROCODE != intel ]] || microcode_blob=GenuineIntel.bin
    grep -Fq "$microcode_blob" <<<"$listing" \
      || die 'initramfs lacks early CPU microcode'
  fi
  if portageq has_version / x11-drivers/nvidia-drivers; then
    for driver in nvidia nvidia_modeset nvidia_drm nvidia_uvm; do
      [[ $(modinfo -k "$version" -F vermagic "$driver") == "$version "* ]] \
        || die "NVIDIA module does not match $version: $driver"
    done
  fi
  printf '\nValidated distribution kernel: %s\nEFI kernel: %s\nInitramfs: %s\n' "$version" "$image" "$initrd"
}

# Print manual physical-firmware commands for the release just validated.
# Use the target disk and saved boot parameters; create-only preserves BootOrder,
# and an optional BootNext command selects one boot without changing defaults.
print_physical_kernel_boot_commands() {
  local version=$1 cmdline=$2 esp_uuid=$3
  local image="\\EFI\\Gentoo\\kernel-$version.efi"
  local initrd="\\EFI\\Gentoo\\initramfs-$version.img"
  local label="Gentoo distribution $version"
  cat <<INSTRUCTIONS

Manual EFI registration for this physical target
------------------------------------------------
Run these commands yourself from a UEFI-booted Linux environment on the
motherboard that will boot this disk. The installer only prints them.
Target disk: $TARGET_DISK
ESP: partition 1, filesystem UUID $esp_uuid
If you move the disk to another machine, confirm its device name there before
running the registration command.

# Inspect existing entries and boot order before making a manual change.
sudo efibootmgr --verbose

# Create this kernel's entry without adding it to the persistent BootOrder.
INSTRUCTIONS
  local device_path_option=
  [[ $TARGET_HOST != startop ]] || device_path_option=' --full-dev-path'
  printf 'sudo efibootmgr --create-only%s --disk %q --part 1 \\\n' "$device_path_option" "$TARGET_DISK"
  printf '  --label %q --loader %q \\\n' "$label" "$image"
  printf '  --unicode %q\n' "$cmdline initrd=$initrd"
  cat <<'INSTRUCTIONS'

# Find the newly created entry by its label and note its four-digit Boot number.
sudo efibootmgr --verbose

# Optional: replace XXXX below with that number, then select it for ONE boot.
# For example, Boot0007 means use 0007. BootOrder is unchanged.
sudo efibootmgr --bootnext XXXX

BootNext is cleared by firmware after use; it does not arrange a permanent
default. Keep existing entries and images while validating this installation.
INSTRUCTIONS
}

# Configure and install the binary fallback kernel inside the mounted Gentoo target.
# Establish update policy, install tools/firmware, rebuild modules and initramfs,
# then validate the selected release without writing firmware boot entries.
kernel_foundation_chroot() {
  local root_uuid luks_uuid efi_uuid cmdline atom version pending
  require_command emerge
  require_command portageq
  local -a tools=(sys-kernel/installkernel sys-kernel/dracut sys-fs/btrfs-progs sys-fs/cryptsetup sys-boot/efibootmgr)
  local -a packages=(sys-kernel/linux-firmware)
  (( EUID == 0 )) || die 'the internal kernel phase must run as root'
  [[ -r /etc/gentoo-release && -d /var/lib/gentoo-config/repository.git ]] \
    || die 'kernel-foundation requires the Gentoo target and configuration repository'
  valid_target_host "$TARGET_HOST" || die 'unsupported kernel target'
  grep -Fxq "GENTOO_TARGET_HOST=\"$TARGET_HOST\"" /etc/gentoo-config/target-host \
    || die 'kernel target differs from the installed Portage foundation'
  read_kernel_firmware_policy /
  [[ -s /etc/portage/package.use/00cpu-flags ]] || die 'run system-update before kernel-foundation'
  pending=$(pending_config_updates)
  [[ -z $pending ]] || die "resolve protected configuration updates first: $pending"
  mountpoint -q /boot && [[ $(findmnt -n -o FSTYPE --target /boot) == vfat ]] \
    || die 'the target EFI partition must be mounted at /boot'
  case ${TARGET_DISK##*/} in
    *[0-9]) CRYPT_PARTITION=${TARGET_DISK}p2 ;;
    *) CRYPT_PARTITION=${TARGET_DISK}2 ;;
  esac
  root_uuid=$(blkid -s UUID -o value "/dev/mapper/$LUKS_NAME")
  luks_uuid=$(cryptsetup luksUUID "$CRYPT_PARTITION")
  [[ $root_uuid =~ ^[[:xdigit:]-]+$ && $luks_uuid =~ ^[[:xdigit:]-]+$ ]] || die 'invalid target UUIDs'
  [[ $ROOT_SUBVOL =~ ^[A-Za-z0-9_@.-]+$ && $LUKS_NAME =~ ^[A-Za-z0-9_-]+$ ]] \
    || die 'kernel root subvolume or mapper name contains unsupported characters'
  efi_uuid=$(findmnt -n -o UUID --target /boot)
  [[ $efi_uuid =~ ^[[:xdigit:]-]+$ ]] || die 'could not identify the mounted ESP UUID'
  cmdline="root=UUID=$root_uuid rootfstype=btrfs rootflags=subvol=$ROOT_SUBVOL rd.luks.uuid=luks-$luks_uuid rd.luks.name=$luks_uuid=$LUKS_NAME ro"

  install -d /etc/portage/package.use /etc/portage/package.accept_keywords /etc/kernel/install.d /etc/dracut.conf.d
  # Retire only earlier installer-owned policy names; never delete user files.
  local old_policy
  for old_policy in /etc/portage/package.use/99-kernel-foundation /etc/portage/package.accept_keywords/99-kernel-foundation; do
    if [[ -f $old_policy && ! -L $old_policy ]] &&
      grep -Fxq '# Managed by gentoo-install kernel-foundation.' "$old_policy"; then
      rm -- "$old_policy"
    fi
  done
  kernel_policy_file /etc/portage/package.use/zz-kernel-foundation <<'POLICY'
# Managed by gentoo-install kernel-foundation.
*/* dist-kernel
sys-apps/systemd kernel-install
sys-kernel/installkernel systemd dracut -efistub -grub -systemd-boot -refind -uki -ukify -ugrd
sys-kernel/dracut systemd
sys-kernel/gentoo-kernel-bin initramfs -generic-uki
# Broad fallback firmware; target-specific pruning belongs to the custom path.
sys-kernel/linux-firmware -savedconfig
sys-firmware/intel-microcode -hostonly
POLICY
  # The inherited configuration keywords virtual/dist-kernel for testing.
  # Keep its provider aligned with the stable binary fallback, so future world
  # updates cannot satisfy a newer testing virtual by compiling gentoo-kernel.
  kernel_policy_file /etc/portage/package.accept_keywords/zz-kernel-foundation <<'POLICY'
# Managed by gentoo-install kernel-foundation.
sys-kernel/gentoo-kernel-bin -~amd64
virtual/dist-kernel -~amd64
POLICY
  kernel_policy_file /etc/kernel/install.conf <<'POLICY'
# Managed by gentoo-install kernel-foundation.
# efistub layout copies files; USE=-efistub disables EFI registration plugins.
layout=efistub
initrd_generator=dracut
uki_generator=none
BOOT_ROOT=/boot
POLICY
  kernel_policy_file /etc/dracut.conf.d/99-gentoo-dist.conf <<'POLICY'
# Managed by gentoo-install kernel-foundation.
# The chroot sees the installation host, not the destination machine.
hostonly="no"
hostonly_cmdline="no"
uefi="no"
early_microcode="yes"
add_dracutmodules+=" crypt btrfs "
add_drivers+=" nvme ahci virtio_pci virtio_blk virtio_scsi usbhid hid_generic xhci_pci atkbd i8042 "
POLICY
  kernel_target_data /etc/kernel/gentoo-dist.cmdline "$cmdline"
  kernel_target_data /etc/kernel/gentoo-dist-esp.uuid "$efi_uuid"
  kernel_policy_file /etc/kernel/install.d/04-gentoo-dist-esp.install <<'POLICY'
#!/usr/bin/env bash
# Managed by gentoo-install kernel-foundation.
set -euo pipefail
[[ ${1:-} == add ]] || exit 0
case ${2:-} in *-gentoo-dist|*-gentoo-dist-bin) ;; *) exit 0 ;; esac
# Fail before generation/copy if the ESP is missing during a later update.
expected=$(cat /etc/kernel/gentoo-dist-esp.uuid)
mountpoint -q /boot && [[ $(findmnt -n -o FSTYPE --target /boot) == vfat ]] &&
  [[ $(findmnt -n -o UUID --target /boot) == "$expected" ]] || {
  printf 'Distribution kernel update requires the target ESP mounted at /boot.\n' >&2
  exit 1
}
POLICY
  chmod 755 /etc/kernel/install.d/04-gentoo-dist-esp.install
  [[ $TARGET_MICROCODE != intel ]] || packages+=(sys-firmware/intel-microcode)
  [[ $TARGET_SOF_FIRMWARE != yes ]] || packages+=(sys-firmware/sof-firmware)
  # Use a filename after common in lexical order: 99-* sorts before common.
  # Keep the binary provider in every transaction to prevent an OR dependency
  # (firmware -> virtual/dist-kernel) from selecting the source provider.
  # Explicit packages, rather than @early_install (which also contains sources
  # and Genkernel). kernel-bin is an ebuild containing a prebuilt kernel; this
  # works even with the installer's policy of disabling Portage binpkg use.
  emerge --pretend --verbose --update --newuse --usepkg=n --getbinpkg=n "${tools[@]}" "${packages[@]}" sys-kernel/gentoo-kernel-bin
  confirm_phase 'distribution kernel packages (review the plan above)'
  # Dracut modules require target-side tools before the kernel postinst runs.
  # This transaction has no firmware -> virtual/dist-kernel dependency.
  emerge --verbose --update --newuse --usepkg=n --getbinpkg=n "${tools[@]}"
  # Fail closed if local overrides re-enable firmware-writing plugins.
  local hook
  for hook in /usr/lib/kernel/install.d/*efistub* /etc/kernel/install.d/*efistub*; do
    [[ ! -e $hook ]] || die "unexpected firmware registration hook: $hook"
  done
  emerge --verbose --update --newuse --usepkg=n --getbinpkg=n "${packages[@]}" sys-kernel/gentoo-kernel-bin
  emerge --oneshot --verbose --usepkg=n --getbinpkg=n @module-rebuild
  atom=$(portageq best_version / sys-kernel/gentoo-kernel-bin)
  [[ -n $atom ]] || die 'binary distribution kernel was not installed'
  # pkg_config regenerates the initramfs after external modules are ready,
  # using the installed package's release rather than uname -r.
  emerge --config "=$atom"
  # Resolve the version from this package's recorded installed kernel tree.
  local -a release_files=()
  local contents_path
  while IFS= read -r contents_path; do
    [[ -r $contents_path ]] && release_files+=("$contents_path")
  done < <(awk '$1 == "obj" && $2 ~ /\/include\/config\/kernel.release$/ { print $2 }' "/var/db/pkg/$atom/CONTENTS")
  ((${#release_files[@]} == 1)) || die "could not identify the installed kernel release for $atom"
  version=$(<"${release_files[0]}")
  [[ $version =~ ^[A-Za-z0-9._+-]+-gentoo-dist(-bin)?$ ]] || die "unexpected distribution kernel release: $version"
  verify_distribution_kernel "$version"
  kernel_policy_file /etc/kernel/gentoo-dist.version <<VERSION
# Managed by gentoo-install kernel-foundation.
$version
VERSION
  pending=$(pending_config_updates)
  [[ -z $pending ]] || die "kernel packages left protected configuration updates: $pending"
  printf '\nKernel command line:\n%s\n' "$cmdline"
  printf 'EFI initrd argument: initrd=\\EFI\\Gentoo\\initramfs-%s.img\n' "$version"
  if [[ $TARGET_HOST == qemu ]]; then
    printf 'The host-side phase will now register this kernel in the offline VM firmware store.\n'
  else
    printf 'No firmware entry was registered. Register on the destination motherboard.\n'
    print_physical_kernel_boot_commands "$version" "$cmdline" "$efi_uuid"
  fi
  printf 'After kernel updates, register the new version; retain a tested previous entry.\n'
  printf 'Custom EFI images use their own build/copy workflow, without make install.\n'
  gentoo-config diff --stat
}

# Present the kernel phase plan and verify the mounted target before installation.
# Run this same standalone script inside the chroot with resolved target options,
# removing its temporary copy afterward and leaving mounts available on failure.
install_kernel_foundation() {
  local source status=0
  log 'Phase: kernel-foundation'
  resolve_kernel_firmware_policy
  if [[ $MODE == dry-run && ! -e $MOUNT_ROOT/etc/gentoo-config/kernel-firmware.d/00-common ]]; then
    TARGET_SOF_FIRMWARE='from target configuration (available after Portage foundation)'
  else
    read_kernel_firmware_policy "$MOUNT_ROOT"
  fi
  [[ $TARGET_HOST == qemu || -z $QEMU_VARS ]] || die '--qemu-vars is only valid for target qemu'
  if (( VERBOSE )); then
    cat <<'NOTES'
Distribution kernel: a reliable installation and recovery foundation
====================================================================

Install the prebuilt, unmodified Gentoo distribution kernel. This avoids
kernel compilation during installation and future world updates. A broad
Dracut initramfs supports encrypted Btrfs, physical storage, QEMU VirtIO,
and keyboard input. No host-only pruning or custom kernel configuration is
used. The binary kernel and its virtual dependency stay on stable AMD64
keywords to avoid pulling a testing source kernel during later world updates.
auto microcode follows the installation host; override it when preparing
another CPU vendor. SOF audio firmware follows the installed configuration:
/etc/gentoo-config/kernel-firmware.d/00-common and optional 90-TARGET fragments.
Microcode selection is vendor-level: Intel adds intel-microcode, AMD uses
linux-firmware. Firmware remains broad, with CPU matching performed at boot.
The none option skips vendor-specific selection and verification; it does not
remove microcode that the generic initramfs includes from installed firmware.

Establish package and image-generation policy
--------------------------------------------
The phase writes /etc/portage/package.use/zz-kernel-foundation with dist-kernel,
installkernel[systemd,dracut] and kernel-bin[initramfs,-generic-uki]. It disables
boot-manager and EFI registration flags. /etc/kernel/install.conf selects:

layout=efistub
initrd_generator=dracut
uki_generator=none
BOOT_ROOT=/boot

The layout copies an EFI kernel and separate initramfs onto the mounted ESP;
it does not require USE=efistub (which would add firmware-registration hooks).
An ESP guard stops distribution updates if the expected FAT partition is not
mounted at /boot. Final system configuration must arrange this mount in fstab.
The Dracut configuration keeps hostonly=no, early_microcode=yes, crypt/btrfs
modules, and storage/keyboard drivers. These settings persist across updates.
An existing policy file without the installer marker stops the phase so the
user can inspect and reconcile it before retrying. Marked files are replaced
in full, including edits retaining that marker. Conflicting saved boot parameters
or ESP identity also stop the phase. These checks do not open a merge dialog
or roll back earlier changes in the phase.

Install prerequisites, then firmware and the kernel together
-----------------------------------------------------------------
Example commands inside the target chroot (Intel system with SOF audio):

emerge --pretend --verbose --update --newuse sys-kernel/installkernel sys-kernel/dracut sys-fs/btrfs-progs sys-kernel/linux-firmware sys-firmware/intel-microcode sys-firmware/sof-firmware sys-fs/cryptsetup sys-boot/efibootmgr sys-kernel/gentoo-kernel-bin
emerge --verbose --update --newuse sys-kernel/installkernel sys-kernel/dracut sys-fs/btrfs-progs sys-fs/cryptsetup sys-boot/efibootmgr
emerge --verbose --update --newuse sys-kernel/linux-firmware sys-firmware/intel-microcode sys-firmware/sof-firmware sys-kernel/gentoo-kernel-bin
emerge --oneshot @module-rebuild
emerge --config =sys-kernel/gentoo-kernel-bin-6.18.54

The first install command provides tools needed by Dracut inside the target.
Keep kernel-bin explicitly selected in the firmware transaction so its virtual
dependency cannot choose a source-built provider. The last command regenerates
the selected installed kernel's initramfs after external modules are built.
dist-kernel provides ongoing package integration,
including NVIDIA when installed; no GPU driver is selected automatically.

Read the target's firmware requirements
--------------------------------------
The common fragment sets SOF_FIRMWARE=no; 90-thinktop sets SOF_FIRMWARE=yes.
The selected host fragment overrides common policy, independent of the CPU or
audio hardware visible on the installation host. Missing common policy or an
invalid value stops the phase before package installation.

cat /etc/gentoo-config/kernel-firmware.d/00-common
cat /etc/gentoo-config/kernel-firmware.d/90-thinktop

Inspect actual target boot ingredients
-------------------------------------
Derive UUIDs from the target devices, never the host's running command line:

blkid -s UUID -o value /dev/mapper/cryptroot
cryptsetup luksUUID /dev/nbd0p2
cat /etc/kernel/gentoo-dist.cmdline
lsinitrd -m /boot/EFI/Gentoo/initramfs-6.18.54-gentoo-dist-bin.img
lsinitrd /boot/EFI/Gentoo/initramfs-6.18.54-gentoo-dist-bin.img
modinfo -k 6.18.54-gentoo-dist-bin btrfs
modinfo -k 6.18.54-gentoo-dist-bin nvidia

Only inspect NVIDIA if installed. The phase verifies the EFI executable,
matching kernel/modules, cryptsetup or systemd-cryptsetup, crypt/btrfs modules,
boot drivers and early microcode. It does not prove hardware behavior or
successful boot.

Maintenance and the boundary to first boot
-----------------------------------------
emerge --update --deep --newuse @world

Distribution package hooks install versioned kernel/initramfs files beneath
/boot/EFI/Gentoo. For later physical-system kernel updates, the user registers
each new version manually with efibootmgr from the running target. Retaining a
previous kernel and EFI entry known to boot is user maintenance advice, not an
installer-managed recovery policy. A fresh installation has no previous Gentoo
kernel to retain. QEMU registration preserves entries already in its variable
store, but cannot determine whether any entry has been successfully boot-tested.
Firmware variables belong to the running machine, even inside a chroot. Registration
from a UEFI live system on the destination physical machine is valid. For a VM,
use the offline registration below. Do not register VM entries from
the host-side NBD chroot, which exposes the physical host's firmware variables.
First-boot configuration follows in first-boot-foundation. Physical
registration and actual boot tests remain outside this kernel phase. This phase
does not write physical firmware or prune old EFI files.
For physical targets, the phase ends by printing copy-ready efibootmgr commands
for the validated disk, release, initramfs, and root/LUKS parameters. The commands
use --create-only to leave the persistent BootOrder untouched. After reviewing
the new Boot number, optionally use --bootnext NUMBER for a single boot test;
firmware clears BootNext after use. No physical firmware command is executed
by the installer, including when --yes is used.

Example manual commands on the destination motherboard (replace the UUIDs):
sudo efibootmgr --verbose
sudo efibootmgr --create-only --disk /dev/nvme0n1 --part 1 \
  --label 'Gentoo distribution 6.18.54-gentoo-dist-bin' \
  --loader '\EFI\Gentoo\kernel-6.18.54-gentoo-dist-bin.efi' \
  --unicode 'root=UUID=ROOT_UUID rootfstype=btrfs rootflags=subvol=@ rd.luks.uuid=luks-LUKS_UUID rd.luks.name=LUKS_UUID=cryptroot ro initrd=\EFI\Gentoo\initramfs-6.18.54-gentoo-dist-bin.img'
sudo efibootmgr --verbose
sudo efibootmgr --bootnext 0007 # Only if the new entry was Boot0007.

The future optimized kernel is independently built and copied to a distinct
EFI path and explicit versioned source tree: distribution updates may change
/usr/src/linux. Do not invoke make install for that path, which would run these
hooks.

Register QEMU firmware offline (target qemu only)
------------------------------------------------
Supply --qemu-vars with the VM's persistent raw OVMF variable-store file. For
a new store, --qemu-vars-template selects the template matching the VM's OVMF
CODE image. Existing stores are preserved, not reset from the template.
The VM must be stopped. The host needs virt-fw-vars and jq.

sudo pacman -S --needed virt-firmware jq
virt-fw-vars --input /path/to/VM/OVMF_VARS.4m.fd --print
./installer/gentoo-install.sh --disk /dev/nbd0 --target-host qemu \
  --phase kernel-foundation --qemu-vars /path/to/VM/OVMF_VARS.4m.fd --verbose

The QEMU-only registration uses virt-fw-vars --append-boot-filepath with the
EFI path, saved root/LUKS arguments, serial-console arguments and initrd path.
The CLI constructs the EFI entry; the installer reuses an identical entry on
retries, puts it first in BootOrder, preserves other variables, validates a
temporary store, and backs up a changed existing store before replacing it.
The file-only device path is intended for this single-disk VM, not physical
firmware or a shared variable store. Physical targets print efibootmgr commands
for manual execution on the destination machine instead.
Keep using this same variable-store file in QEMU on every subsequent boot.
Successful offline registration prepares the VM entry; it does not prove boot.
NOTES
  fi
  cat <<PLAN

Distribution kernel plan
Target root:          $MOUNT_ROOT
Configuration target: $TARGET_HOST
Kernel:               sys-kernel/gentoo-kernel-bin (stable AMD64 fallback)
CPU microcode:        $TARGET_MICROCODE
SOF audio firmware:   $TARGET_SOF_FIRMWARE
EFI files:            /boot/EFI/Gentoo/kernel-VERSION.efi and initramfs-VERSION.img
QEMU firmware store:  ${QEMU_VARS:-not specified; used only for target qemu}

  * establish distribution-only package and Dracut policy;
  * install broad firmware, microcode, and the binary distribution kernel;
  * rebuild external modules and regenerate the matching initramfs;
  * validate the direct EFI boot ingredients and print target boot parameters.
PLAN
  if [[ $TARGET_HOST == qemu ]]; then
    printf '  * register the selected kernel in the offline VM firmware store, retaining older entries.\n'
  fi
  if [[ $MODE == dry-run ]]; then
    printf '\nDry run: no packages, kernel policy, EFI files, or firmware stores changed.\n'
    return
  fi
  [[ -n $TARGET_DISK ]] || die 'kernel-foundation requires --disk DEVICE'
  TARGET_DISK=$(readlink -f -- "$TARGET_DISK")
  [[ -b $TARGET_DISK ]] || die "target is not a block device: $TARGET_DISK"
  case ${TARGET_DISK##*/} in
    *[0-9]) EFI_PARTITION=${TARGET_DISK}p1; CRYPT_PARTITION=${TARGET_DISK}p2 ;;
    *) EFI_PARTITION=${TARGET_DISK}1; CRYPT_PARTITION=${TARGET_DISK}2 ;;
  esac
  verify_disk_setup || die 'kernel-foundation requires a verified disk layout'
  for source in proc sys dev run; do
    mountpoint -q "$MOUNT_ROOT/$source" || die "required chroot mount is missing: $source"
  done
  [[ -r $MOUNT_ROOT/etc/gentoo-release ]] || die 'the Gentoo target is missing'
  check_qemu_firmware
  confirm_phase 'distribution kernel foundation'
  local helper=/run/$PROGRAM.kernel.$$
  local -a options=()
  (( ASSUME_YES == 0 )) || options+=(--yes)
  run_privileged install -m 700 "$0" "$MOUNT_ROOT$helper"
  run_privileged /bin/bash -c '
    target_root=$1
    helper=$2
    shift 2
    # Remove the temporary installer copy on success or failure.
    # Preserve the chroot exit status so a failed phase remains visible to the caller.
    cleanup_kernel_helper() {
      local status=$?
      trap - EXIT
      rm -f -- "$target_root$helper" || printf "Warning: temporary kernel helper remains: %s\n" "$helper" >&2
      exit "$status"
    }
    trap cleanup_kernel_helper EXIT
    chroot "$target_root" /usr/bin/env -i \
      HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      TERM="${TERM:-dumb}" /bin/bash "$helper" "$@"
  ' "$PROGRAM-kernel" "$MOUNT_ROOT" "$helper" \
    --internal-kernel-chroot --target-host "$TARGET_HOST" \
    --disk "$TARGET_DISK" --luks-name "$LUKS_NAME" --root-subvol "$ROOT_SUBVOL" \
    --microcode "$TARGET_MICROCODE" "${options[@]}" || status=$?
  (( status == 0 )) || die 'kernel-foundation did not complete; target remains mounted for review and retry'
  # Offline firmware editing is exclusively for the QEMU target.
  if [[ $TARGET_HOST == qemu ]]; then
    register_qemu_distribution_kernel
  fi
  log 'Distribution kernel foundation complete: boot ingredients validated; actual boot remains untested'
}

# First boot foundation: configure the mounted target without contacting its bus.
# References: Gentoo Handbook Installation/System and Installation/Tools;
# systemd-firstboot(1), systemctl(1), and dhcpcd's 20-resolv.conf hook.
# Runtime initialization is automatic at boot. This phase establishes persistent
# identity, mounts, credentials and explicit service policy before that boot.
firstboot_offline() {
  (( EUID == 0 )) || die 'offline first-boot setup requires root'
  local root=$MOUNT_ROOT root_uuid esp_uuid hostname=$TARGET_HOSTNAME command unit
  [[ -r $root/etc/gentoo-release && -d $root/var/lib/gentoo-config/repository.git ]] \
    || die 'first-boot-foundation requires the configured Gentoo target'
  grep -Fxq "GENTOO_TARGET_HOST=\"$TARGET_HOST\"" "$root/etc/gentoo-config/target-host" \
    || die 'target-host differs from the installed configuration'
  for command in systemd-firstboot systemctl python3; do require_command "$command"; done
  [[ -x $root/usr/lib/systemd/systemd-timesyncd ]] || die 'target systemd lacks timesyncd'
  [[ -s $root/etc/kernel/gentoo-dist.cmdline ]] || die 'run kernel-foundation first'
  [[ $ROOT_SUBVOL =~ ^[A-Za-z0-9_@.-]+$ && $HOME_SUBVOL =~ ^[A-Za-z0-9_@.-]+$ ]] \
    || die 'unsupported Btrfs subvolume name'
  if [[ -z $hostname && $TARGET_HOST != generic && $TARGET_HOST != qemu ]]; then hostname=$TARGET_HOST; fi
  if [[ -z $hostname && -s $root/etc/hostname ]]; then hostname=$(cat "$root/etc/hostname"); fi
  if [[ -z $hostname ]]; then
    [[ -r /dev/tty ]] || die 'supply --hostname when no terminal is available'
    printf 'Target hostname: ' >/dev/tty
    IFS= read -r hostname </dev/tty || die 'could not read hostname'
  fi
  [[ ${#hostname} -le 63 && $hostname =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] \
    || die 'hostname must be one DNS label, at most 63 characters'
  [[ ! -s $root/etc/hostname || $(cat "$root/etc/hostname") == "$hostname" ]] \
    || die 'existing hostname conflicts with requested hostname'
  root_uuid=$(blkid -s UUID -o value "/dev/mapper/$LUKS_NAME")
  esp_uuid=$(blkid -s UUID -o value "$EFI_PARTITION")
  [[ $root_uuid =~ ^[[:xdigit:]-]+$ && $esp_uuid =~ ^[[:xdigit:]-]+$ ]] || die 'invalid filesystem UUIDs'
  [[ $(cat "$root/etc/kernel/gentoo-dist-esp.uuid") == "$esp_uuid" ]] || die 'kernel ESP identity differs'
  grep -Fq "rootflags=subvol=$ROOT_SUBVOL " "$root/etc/kernel/gentoo-dist.cmdline" || die 'kernel root subvolume differs'
  grep -Fq "root=UUID=$root_uuid " "$root/etc/kernel/gentoo-dist.cmdline" || die 'kernel root UUID differs'

  # Run package operations inside the target, but never start services there.
  local -a packages=(net-misc/dhcpcd)
  [[ $TARGET_HOST == qemu ]] || packages+=(net-wireless/wpa_supplicant)
  chroot "$root" /usr/bin/emerge --pretend --verbose --update --newuse --usepkg=n --getbinpkg=n "${packages[@]}"
  confirm_phase 'first-boot networking packages (review the plan above)'
  chroot "$root" /usr/bin/emerge --verbose --update --newuse --usepkg=n --getbinpkg=n "${packages[@]}"

  # Python writes persistent files atomically and rejects unowned conflicts.
  # Imported credentials are never printed, passed in argv, or tracked in Git.
  python3 - "$root" "$TARGET_HOST" "$root_uuid" "$esp_uuid" "$ROOT_SUBVOL" "$HOME_SUBVOL" <<'PYTHON'
import configparser, getpass, hashlib, os, pathlib, re, tempfile
import sys
root, target, uuid, esp, subvol, home = sys.argv[1:]
base = pathlib.Path(root)
marker = '# Managed by gentoo-install first-boot-foundation.\n'
def write(name, content, mode=0o644, allow_comments=False, marked=True):
    desired = (marker if marked else "") + content
    path = base / name.lstrip('/')
    if path.is_symlink():
        raise SystemExit(f'Refusing symlink at {name}')
    if path.exists():
        old = path.read_text()
        if old == desired:
            os.chmod(path, mode)
            return
        harmless = allow_comments and all(not x.strip() or x.lstrip().startswith('#') for x in old.splitlines())
        if not old.startswith(marker) and not harmless:
            raise SystemExit(f'Existing {name} requires manual review')
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(desired)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
write('/etc/fstab', f'UUID={uuid} / btrfs noatime,compress=zstd:1,subvol={subvol} 0 0\n'
      f'UUID={uuid} /home btrfs noatime,compress=zstd:1,subvol={home} 0 0\n'
      f'UUID={esp} /boot vfat umask=0077 0 2\n', allow_comments=True)
write('/etc/adjtime', '0.0 0 0.0\n0\nUTC\n', marked=False)
write('/etc/systemd/journald.conf.d/90-first-boot.conf', '[Journal]\nStorage=persistent\nSystemMaxUse=256M\nSystemKeepFree=512M\n')
# An invalid command prevents dhcpcd from selecting systemd's resolvconf shim.
write('/etc/dhcpcd/gentoo-install.conf', 'hostname\nclientid\noption domain_name_servers, domain_name, domain_search\n'
      'option classless_static_routes\noption interface_mtu\nrequire dhcp_server_identifier\n'
      'slaac private\nnohook wpa_supplicant, hostname\nenv resolvconf=/nonexistent/gentoo-install-resolvconf\n', allow_comments=True)
write('/etc/systemd/system/dhcpcd.service.d/90-first-boot.conf', '[Service]\nExecStart=\n'
      'ExecStart=/sbin/dhcpcd -q -f /etc/dhcpcd/gentoo-install.conf\n')
write('/etc/systemd/system/gentoo-btrfs-scrub.service', '[Unit]\nDescription=Scrub the Gentoo Btrfs filesystem\n'
      'RequiresMountsFor=/\n[Service]\nType=oneshot\nExecStart=/usr/bin/btrfs scrub start -B /\n'
      'TimeoutStartSec=infinity\nNice=19\nIOSchedulingClass=idle\n')
write('/etc/systemd/system/gentoo-btrfs-scrub.timer', '[Unit]\nDescription=Monthly Btrfs integrity check\n'
      '[Timer]\nOnCalendar=monthly\nPersistent=true\nRandomizedDelaySec=1d\n'
      '[Install]\nWantedBy=timers.target\n')
# Only scrub: no automatic balance, defragmentation, or encrypted discard policy.
if target == 'qemu':
    print('QEMU: DHCP on virtual Ethernet; no Wi-Fi credentials imported.')
else:
    destination = base / 'etc/wpa_supplicant/gentoo-install.conf'
    if not destination.exists() and not destination.is_symlink():
        networks = []
        def supplicant_blocks(data):
            # Match braces only outside quoted strings and comments.
            blocks, start, depth, quoted, escaped, comment = [], None, 0, False, False, False
            for i, c in enumerate(data):
                if comment:
                    if c == '\n': comment = False
                    continue
                if escaped: escaped = False; continue
                if quoted and c == '\\': escaped = True; continue
                if c == '"': quoted = not quoted; continue
                if quoted: continue
                if c == '#': comment = True; continue
                if c == '{':
                    if depth == 0:
                        match = re.search(r'network\s*=\s*$', data[:i])
                        start = match.start() if match else None
                    depth += 1
                elif c == '}':
                    depth -= 1
                    if depth < 0: return []
                    if depth == 0 and start is not None: blocks.append(data[start:i+1])
            return blocks if depth == 0 and not quoted else []
        # Reuse a self-contained supplicant configuration; certificate paths need
        # explicit provisioning and must not silently refer to files on the host.
        candidates = list(pathlib.Path('/etc/wpa_supplicant').glob('*.conf'))
        candidates += [pathlib.Path('/etc/wpa_supplicant.conf')]
        for candidate in candidates:
            if not candidate.is_file(): continue
            data = candidate.read_text()
            if re.search(r'^\s*(ca_cert\w*|client_cert\w*|private_key\w*|include|eap)\s*=', data, re.M):
                continue
            blocks = supplicant_blocks(data)
            networks.extend(blocks)
        # NetworkManager keyfiles: support saved personal WPA-PSK/SAE and open
        # networks. Do not guess enterprise, WEP, or externally stored secrets.
        def network(ssid, key='', method='WPA-PSK'):
            encoded = ssid.encode('utf-8')
            if not 1 <= len(encoded) <= 32: return None
            if method == 'NONE': return f'network={{\n ssid={encoded.hex()}\n key_mgmt=NONE\n}}'
            if method == 'SAE':
                if not key or any(ord(c) < 32 for c in key): return None
                escaped = key.replace('\\', '\\\\').replace('"', '\\"')
                return f'network={{\n ssid={encoded.hex()}\n key_mgmt=SAE\n ieee80211w=2\n sae_password="{escaped}"\n}}'
            if re.fullmatch(r'[0-9a-fA-F]{64}', key): psk = key
            elif 8 <= len(key) <= 63:
                psk = hashlib.pbkdf2_hmac('sha1', key.encode(), encoded, 4096, 32).hex()
            else: return None
            return f'network={{\n ssid={encoded.hex()}\n key_mgmt=WPA-PSK\n psk={psk}\n}}'
        for candidate in pathlib.Path('/etc/NetworkManager/system-connections').glob('*'):
            if not candidate.is_file(): continue
            config = configparser.ConfigParser(interpolation=None, strict=False)
            try: config.read_string(candidate.read_text())
            except (configparser.Error, UnicodeError): continue
            section = 'wifi' if config.has_section('wifi') else '802-11-wireless'
            if not config.has_section(section): continue
            ssid = config.get(section, 'ssid', fallback='')
            # Keyfile escaping and byte-array SSIDs need a dedicated converter.
            if '\\' in ssid or re.fullmatch(r'(\d+;)+', ssid): continue
            security = 'wifi-security' if config.has_section('wifi-security') else '802-11-wireless-security'
            if config.get(section, 'security', fallback='') and not config.has_section(security): continue
            method = config.get(security, 'key-mgmt', fallback='none')
            if method not in ('none', 'wpa-psk', 'sae'): continue
            block = network(ssid, config.get(security, 'psk', fallback=''),
                            {'none':'NONE','wpa-psk':'WPA-PSK','sae':'SAE'}[method])
            if block: networks.append(block)
        if not networks:
            print('Enterprise profiles, external certificate paths and unavailable secrets are not imported.')
            with open('/dev/tty', 'r+') as tty:
                tty.write('No supported saved Wi-Fi credentials. SSID (blank to defer Wi-Fi): '); tty.flush()
                ssid = tty.readline().rstrip('\n')
                if ssid:
                    password = getpass.getpass('Wi-Fi password (blank for an open network): ', stream=tty)
                    block = network(ssid, password, 'WPA-PSK' if password else 'NONE')
                    if not block: raise SystemExit('Invalid SSID or WPA password')
                    networks.append(block)
        if networks:
            write('/etc/wpa_supplicant/gentoo-install.conf', 'ctrl_interface=/run/wpa_supplicant\n'
                  'update_config=0\n' + '\n'.join(dict.fromkeys(networks)) + '\n', 0o600)
            print('Saved supported Wi-Fi profiles in a root-only target file.')
        else: print('Wi-Fi deferred; Ethernet DHCP is configured.')
    if destination.exists() or destination.is_symlink():
        if destination.is_symlink() or not destination.read_text().startswith(marker):
            raise SystemExit('Existing Wi-Fi configuration requires manual review')
        os.chmod(destination, 0o600)
        write('/etc/systemd/system/gentoo-wifi@.service', '[Unit]\nDescription=Wi-Fi authentication on %I\n'
              'BindsTo=sys-subsystem-net-devices-%i.device\nAfter=sys-subsystem-net-devices-%i.device\n'
              '[Service]\nType=simple\nExecStart=/usr/sbin/wpa_supplicant -i %I -c /etc/wpa_supplicant/gentoo-install.conf\n'
              'Restart=on-failure\nRestartSec=5\n')
        write('/etc/udev/rules.d/80-gentoo-wifi.rules', 'ACTION=="add", SUBSYSTEM=="net", TEST=="phy80211", '
              'TAG+="systemd", ENV{SYSTEMD_WANTS}+="gentoo-wifi@%k.service"\n')
    exclude = base / 'var/lib/gentoo-config/repository.git/info/exclude'
    exclude.parent.mkdir(parents=True, exist_ok=True)
    existing = exclude.read_text() if exclude.exists() else ''
    if '/etc/wpa_supplicant/gentoo-install.conf' not in existing.splitlines():
        with exclude.open('a') as stream: stream.write('\n/etc/wpa_supplicant/gentoo-install.conf\n')
PYTHON
  # Fresh identity is random, not inherited from the shared host /run or D-Bus.
  # firstboot preserves already initialized values; never use --reset/--force.
  systemd-firstboot --root="$root" --hostname="$hostname" --setup-machine-id
  # Some stage3 shadow files already have a locked entry. passwd deliberately
  # initializes it; firstboot may regard an existing entry as already configured.
  if ! awk -F: '$1 == "root" { if ($2 == "" || $2 ~ /^[!*]/) exit 1; found=1 } END { if (!found) exit 1 }' "$root/etc/shadow"; then
    printf '\nSet the Gentoo root login password for %s.\n' "$hostname"
    printf 'The next "Enter new password" prompts create this target login password.\n'
    printf 'Enter the same new password twice; it is used to log in as root after boot.\n'
    printf 'This does not change the disk encryption passphrase or any host password.\n\n'
    chroot "$root" /usr/bin/passwd root
  else
    printf 'Gentoo root login password is already set; preserving it.\n'
  fi
  [[ $(cat "$root/etc/machine-id") =~ ^[[:xdigit:]]{32}$ ]] || die 'target machine ID is invalid'
  local version
  version=$(tail -n 1 "$root/etc/kernel/gentoo-dist.version")
  [[ $version =~ ^[A-Za-z0-9._+-]+-gentoo-dist(-bin)?$ ]] || die 'invalid recorded kernel version'
  [[ -s $root/boot/EFI/Gentoo/kernel-$version.efi && -s $root/boot/EFI/Gentoo/initramfs-$version.img && -d $root/lib/modules/$version ]] \
    || die 'distribution kernel, initramfs or modules are missing'
  # The bootstrap resolver is a regular copy, not a link to the host's resolver.
  [[ -f $root/etc/resolv.conf && ! -L $root/etc/resolv.conf ]] || die 'target resolv.conf must be a regular file for dhcpcd'
  systemctl --root="$root" preset-all --preset-mode=enable-only
  for unit in NetworkManager.service systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service systemd-resolved.service wpa_supplicant.service iwd.service syslog-ng.service rsyslog.service syslog.service sysklogd.service metalog.service chronyd.service ntpd.service; do
    if [[ -e $root/usr/lib/systemd/system/$unit || -e $root/etc/systemd/system/$unit ]]; then
      systemctl --root="$root" disable "$unit"
    fi
  done
  # Disable packaged per-interface supplicants to avoid racing our udev-started
  # instance. Do not remove unrelated units or edit host service state.
  local link
  for link in "$root"/etc/systemd/system/*.wants/wpa_supplicant@*.service; do
    [[ -L $link ]] || continue
    systemctl --root="$root" disable "${link##*/}"
  done
  systemctl --root="$root" enable dhcpcd.service systemd-timesyncd.service gentoo-btrfs-scrub.timer
  for unit in dhcpcd.service systemd-timesyncd.service gentoo-btrfs-scrub.timer; do
    systemctl --root="$root" is-enabled "$unit" >/dev/null || die "service not enabled: $unit"
  done
  chroot "$root" findmnt --verify --tab-file /etc/fstab
  awk -F: '$1 == "root" { if ($2 == "" || $2 ~ /^[!*]/) exit 1; found=1 } END { if (!found) exit 1 }' "$root/etc/shadow" \
    || die 'root has no usable password; set it in the target and retry'
  printf '\nFirst-boot foundation complete for %s. Runtime services have not been started.\n' "$hostname"
  printf 'Boot the target and verify DHCP/DNS, timedatectl timesync-status, journalctl --list-boots, and the scrub timer.\n'
  printf 'Physical targets still require their EFI entry registered on the destination motherboard.\n'
}

install_firstboot_foundation() {
  log 'Phase: first-boot-foundation'
  cat <<PLAN
Target root: $MOUNT_ROOT
Hostname: ${TARGET_HOSTNAME:-$([[ $TARGET_HOST == generic || $TARGET_HOST == qemu ]] && printf 'prompt (or preserve existing)' || printf '%s' "$TARGET_HOST")}
Clock: UTC
Networking: dhcpcd; $([[ $TARGET_HOST == qemu ]] && printf 'virtual Ethernet only' || printf 'import supported host Wi-Fi profiles, otherwise prompt')
Logging: persistent journald, 256 MiB cap, 512 MiB kept free
Time: enable existing systemd-timesyncd (no added time-service packages)
Storage: UUID mounts and monthly Btrfs scrub (no automatic balance/defrag)
PLAN
  if (( VERBOSE )); then
    cat <<'NOTES'
--hostname selects the target hostname. Without it, a named physical target
uses --target-host; generic/qemu preserves an existing hostname or prompts.
An existing root password is preserved; a missing or locked password prompts
for a new Gentoo root login password, including with --yes.

Configure identity and credentials with systemd-firstboot --root, then apply
Gentoo's enable-only presets before explicit offline service selection. UTC
is written to the target adjtime file; the host hardware clock is untouched.
No live systemctl, timedatectl, hostnamectl, or daemon-reload is used.

Wi-Fi credentials remain local root-only state, excluded from gentoo-config.
Physical targets import self-contained wpa_supplicant network blocks and saved
NetworkManager personal WPA-PSK/SAE/open profiles. Enterprise profiles, external
certificates and unavailable secrets require separate provisioning. If no
supported profile exists, prompt for SSID/password or defer Wi-Fi. Existing
installer Wi-Fi credentials are preserved on retries. A udev rule starts one
supplicant per target wireless interface without importing host device names.
QEMU uses virtual Ethernet and receives DHCP/DNS from its host-side backend.

dhcpcd owns routes and resolv.conf directly; competing network services are
disabled. Its built-in supplicant hook is disabled to avoid duplicate instances.
The scrub runs once monthly for the shared root/home filesystem. No extra
logging daemon, cron daemon, NTP package, or Btrfs maintenance package is needed.
Policy files reject unmarked conflicts, including active existing fstab or
installer policy configuration; reconcile these before retrying. The phase is resumable
but does not roll back earlier writes or package installation on failure.
NOTES
  fi
  [[ $MODE != dry-run ]] || { printf '\nDry run: no configuration, credentials, packages, or services changed.\n'; return; }
  [[ -n $TARGET_DISK ]] || die 'first-boot-foundation requires --disk'
  TARGET_DISK=$(readlink -f -- "$TARGET_DISK")
  case ${TARGET_DISK##*/} in
    *[0-9]) EFI_PARTITION=${TARGET_DISK}p1; CRYPT_PARTITION=${TARGET_DISK}p2 ;;
    *) EFI_PARTITION=${TARGET_DISK}1; CRYPT_PARTITION=${TARGET_DISK}2 ;;
  esac
  verify_disk_setup || die 'first-boot-foundation requires verified target mounts'
  local source
  for source in proc sys dev run; do mountpoint -q "$MOUNT_ROOT/$source" || die "missing chroot mount: $source"; done
  confirm_phase 'first-boot foundation'
  local -a options=()
  (( ASSUME_YES == 0 )) || options+=(--yes)
  run_privileged /bin/bash "$0" --internal-firstboot-offline --disk "$TARGET_DISK" \
    --mount-root "$MOUNT_ROOT" --target-host "$TARGET_HOST" --hostname "$TARGET_HOSTNAME" \
    --luks-name "$LUKS_NAME" --root-subvol "$ROOT_SUBVOL" --home-subvol "$HOME_SUBVOL" "${options[@]}"
}

handoff() {
  log 'Phase: handoff'
  cat <<PLAN
Handoff plan
Target root: $MOUNT_ROOT
  * verify the target disk layout and first-boot configuration;
  * unmount chroot filesystems, the ESP, home, and root;
  * close /dev/mapper/$LUKS_NAME; and
  * leave the target powered off and print the remaining boot steps.
PLAN
  if (( VERBOSE )); then
    printf '\nOrdinary unmounts stop on busy filesystems. No forced or lazy unmounts are used.\n'
    printf 'NBD attachment and destination firmware selection remain manual.\n'
  fi
  [[ $MODE != dry-run ]] || { printf '\nDry run: no mounts or encrypted mappings changed.\n'; return; }
  [[ -n $TARGET_DISK ]] || die 'handoff requires --disk'
  TARGET_DISK=$(readlink -f -- "$TARGET_DISK")
  case ${TARGET_DISK##*/} in
    *[0-9]) EFI_PARTITION=${TARGET_DISK}p1; CRYPT_PARTITION=${TARGET_DISK}p2 ;;
    *) EFI_PARTITION=${TARGET_DISK}1; CRYPT_PARTITION=${TARGET_DISK}2 ;;
  esac
  verify_disk_setup || die 'handoff requires verified target mounts'
  run_privileged test -s "$MOUNT_ROOT/etc/fstab" || die 'first-boot fstab is missing'
  local version cmdline esp_uuid source
  version=$(run_privileged tail -n 1 "$MOUNT_ROOT/etc/kernel/gentoo-dist.version")
  [[ $version =~ ^[A-Za-z0-9._+-]+-gentoo-dist(-bin)?$ ]] || die 'invalid recorded kernel version'
  cmdline=$(run_privileged cat "$MOUNT_ROOT/etc/kernel/gentoo-dist.cmdline")
  esp_uuid=$(run_privileged cat "$MOUNT_ROOT/etc/kernel/gentoo-dist-esp.uuid")
  confirm_phase 'handoff'
  for source in run dev sys proc; do
    if mountpoint -q "$MOUNT_ROOT/$source"; then
      run_privileged umount --recursive "$MOUNT_ROOT/$source" || die "could not unmount $source; stop processes using the target and retry"
    fi
  done
  for source in "$MOUNT_ROOT/boot" "$MOUNT_ROOT/home" "$MOUNT_ROOT"; do
    run_privileged umount "$source" || die "could not unmount $source; remaining mounts and LUKS mapping are preserved"
  done
  run_privileged cryptsetup close "$LUKS_NAME"
  log 'Handoff complete: target unmounted and LUKS closed'
  if [[ $TARGET_HOST == qemu ]]; then
    printf 'Disconnect the NBD attachment before starting QEMU. Use the prepared OVMF store: %s\n' "$QEMU_VARS"
    printf 'Follow installer/QEMU-NBD-INSTALL.md for the VM boot command.\n'
  else
    print_physical_kernel_boot_commands "$version" "$cmdline" "$esp_uuid"
  fi
  printf 'Unlock LUKS, log in with the target root password, and verify mounts, networking and failed services.\n'
}

main() {
  parse_args "$@"
  if (( INTERNAL_FIRSTBOOT_OFFLINE )); then
    case ${TARGET_DISK##*/} in *[0-9]) EFI_PARTITION=${TARGET_DISK}p1 ;; *) EFI_PARTITION=${TARGET_DISK}1 ;; esac
    firstboot_offline
    return
  fi
  if (( INTERNAL_KERNEL_CHROOT )); then
    kernel_foundation_chroot
    return
  fi
  if (( INTERNAL_UPDATE_CHROOT )); then
    system_update_chroot
    return
  fi
  if (( INTERNAL_PORTAGE_CHROOT )); then
    portage_foundation_chroot
    return
  fi
  validate_arguments
  # Resolve host firmware prerequisites before any earlier destructive phase.
  if is_selected kernel-foundation && [[ $MODE != dry-run ]]; then
    check_qemu_firmware
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
  if is_selected system-update; then
    install_system_update
  fi
  if is_selected kernel-foundation; then
    install_kernel_foundation
  fi
  if is_selected first-boot-foundation; then
    install_firstboot_foundation
  fi
  if is_selected handoff; then
    handoff
  fi
}

main "$@"
