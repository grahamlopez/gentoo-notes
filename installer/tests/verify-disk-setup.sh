#!/usr/bin/env bash

# Focused regression test: the production verifier is sourceable for future
# integration tests and rejects a disk before later layout checks when GPT is
# absent.  It uses command shims only; no block devices are touched.
set -Eeuo pipefail

test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin"

cat >"$test_dir/bin/lsblk" <<'EOF'
#!/usr/bin/env bash
printf 'dos\n'
EOF
chmod +x "$test_dir/bin/lsblk"

for command in cryptsetup blkid btrfs findmnt mountpoint; do
  cat >"$test_dir/bin/$command" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$test_dir/bin/$command"
done

PATH="$test_dir/bin:$PATH"
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../gentoo-install.sh
source "$script_dir/gentoo-install.sh"

TARGET_DISK=/dev/testdisk
EFI_PARTITION=/dev/testdisk1
CRYPT_PARTITION=/dev/testdisk2
LUKS_NAME=cryptroot
BTRFS_LABEL=GENTOO
ROOT_SUBVOL=@
HOME_SUBVOL=@home
MOUNT_ROOT=/mnt/gentoo

if verify_disk_setup >"$test_dir/output" 2>&1; then
  printf 'expected verification to reject a non-GPT disk\n' >&2
  exit 1
fi
rg -Fq 'target does not have a GPT partition table: /dev/testdisk' "$test_dir/output"
