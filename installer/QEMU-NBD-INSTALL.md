<!--
This is a production-install runbook for installing Gentoo into a QEMU qcow2
target through NBD.  It must invoke installer/gentoo-install.sh exactly as a
real installation from the current Linux host would invoke it.  Do not add
alternate modes, trust inputs, mocks, or special installer settings here:
running these instructions is the production path.
-->

# QEMU NBD Gentoo install

## Host tools

```bash
sudo pacman -S --needed qemu-base btrfs-progs cryptsetup curl dosfstools git gnupg
```

## Set up this install shell

Paste this once into the terminal that will run the install commands:

```bash
INSTALL_DIR=/home/graham/VMs/agentic-gentoo
IMAGE=$INSTALL_DIR/target.qcow2
NBD_DEVICE=/dev/nbd0
CONFIG_SOURCE=/home/graham/Projects/gentoo-configs
CONFIG_BRANCH=agentic-gentoo

detach_target() {
  local nbd_pid_file=/sys/block/${NBD_DEVICE##*/}/pid
  local nbd_pid
  local attempt

  if mountpoint -q /mnt/gentoo/run; then sudo umount --recursive /mnt/gentoo/run; fi
  if mountpoint -q /mnt/gentoo/dev; then sudo umount --recursive /mnt/gentoo/dev; fi
  if mountpoint -q /mnt/gentoo/sys; then sudo umount --recursive /mnt/gentoo/sys; fi
  if mountpoint -q /mnt/gentoo/proc; then sudo umount --recursive /mnt/gentoo/proc; fi
  if mountpoint -q /mnt/gentoo/boot; then sudo umount /mnt/gentoo/boot; fi
  if mountpoint -q /mnt/gentoo/home; then sudo umount /mnt/gentoo/home; fi
  if mountpoint -q /mnt/gentoo; then sudo umount /mnt/gentoo; fi
  if sudo cryptsetup status cryptroot >/dev/null 2>&1; then sudo cryptsetup close cryptroot; fi
  if [[ -r $nbd_pid_file ]]; then
    nbd_pid=$(<"$nbd_pid_file")
    if [[ -n $nbd_pid && $nbd_pid != 0 ]]; then
      sudo qemu-nbd --disconnect "$NBD_DEVICE"
      for attempt in {1..50}; do
        [[ ! -r $nbd_pid_file ]] && break
        nbd_pid=$(<"$nbd_pid_file")
        [[ -z $nbd_pid || $nbd_pid == 0 ]] && break
        sleep 0.1
      done
      [[ ! -r $nbd_pid_file || -z $nbd_pid || $nbd_pid == 0 ]] || {
        printf 'NBD device did not finish disconnecting: %s\n' "$NBD_DEVICE" >&2
        return 1
      }
      for attempt in {1..50}; do
        qemu-img info "$IMAGE" >/dev/null 2>&1 && break
        sleep 0.1
      done
      qemu-img info "$IMAGE" >/dev/null 2>&1 || {
        printf 'Image write lock was not released: %s\n' "$IMAGE" >&2
        return 1
      }
    fi
  fi
}

attach_target() {
  local size_file=/sys/block/${NBD_DEVICE##*/}/size
  local attempt

  sudo qemu-nbd --format=qcow2 --connect="$NBD_DEVICE" "$IMAGE"
  for attempt in {1..50}; do
    [[ $(<"$size_file") != 0 ]] && break
    sleep 0.1
  done
  [[ $(<"$size_file") != 0 ]] || {
    printf 'NBD device did not report a capacity: %s\n' "$NBD_DEVICE" >&2
    return 1
  }
  sudo udevadm settle
  lsblk --paths --output NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS "$NBD_DEVICE"
}
```

## First setup: create and attach a fresh target

```bash
mkdir -p "$INSTALL_DIR"
qemu-img create -f qcow2 "$IMAGE" 32G
sudo modprobe nbd nbds_max=8 max_part=16
attach_target
```

## Run the installer against the attached target

```bash
cd /home/graham/Projects/gentoo-notes
./installer/gentoo-install.sh --disk "$NBD_DEVICE" \
  --config-source "$CONFIG_SOURCE" --config-branch "$CONFIG_BRANCH" \
  --target-host qemu --dry-run --verbose
./installer/gentoo-install.sh --disk "$NBD_DEVICE" \
  --config-source "$CONFIG_SOURCE" --config-branch "$CONFIG_BRANCH" \
  --target-host qemu --verbose

sudo findmnt -R /mnt/gentoo
sudo bash -c '[[ -r /mnt/gentoo/etc/gentoo-release ]]'
sudo chroot /mnt/gentoo /bin/bash -c \
  '[[ -r /proc/cpuinfo && -c /dev/null && -d /sys && -r /etc/resolv.conf ]]'
sudo chroot /mnt/gentoo /bin/bash -c \
  'grep -Fxq '\''GENTOO_TARGET_HOST="qemu"'\'' /etc/gentoo-config/target-host && [[ -d /var/db/repos/gentoo/.git ]]'
```

## Detach and preserve the target for later work

```bash
detach_target
```

## Start over with a fresh target, if needed

```bash
detach_target
rm -f "$IMAGE"
qemu-img create -f qcow2 "$IMAGE" 32G
attach_target
```

## Boot after the UKI phase exists

```bash
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd "$INSTALL_DIR/OVMF_VARS.4m.fd"
qemu-system-x86_64 \
  -enable-kvm \
  -machine q35 \
  -cpu host \
  -m 4096 \
  -smp 4 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file="$INSTALL_DIR/OVMF_VARS.4m.fd" \
  -drive if=virtio,format=qcow2,file="$IMAGE"
```
