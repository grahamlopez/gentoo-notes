# QEMU NBD disk test

## Host tools

```bash
sudo pacman -S --needed qemu-base
```

## Set up this test shell

Paste this once into the terminal that will run the test commands:

```bash
TEST_DIR=/home/graham/VMs/agentic-gentoo
IMAGE=$TEST_DIR/target.qcow2
NBD_DEVICE=/dev/nbd0
PID_FILE=$TEST_DIR/target.nbd.pid

detach_target() {
  local nbd_pid_file=/sys/block/${NBD_DEVICE##*/}/pid
  local nbd_pid

  if mountpoint -q /mnt/gentoo/boot; then sudo umount /mnt/gentoo/boot; fi
  if mountpoint -q /mnt/gentoo/home; then sudo umount /mnt/gentoo/home; fi
  if mountpoint -q /mnt/gentoo; then sudo umount /mnt/gentoo; fi
  if sudo cryptsetup status cryptroot >/dev/null 2>&1; then sudo cryptsetup close cryptroot; fi
  if [[ -r $nbd_pid_file ]]; then
    nbd_pid=$(<"$nbd_pid_file")
    if [[ -n $nbd_pid && $nbd_pid != 0 ]]; then
      sudo qemu-nbd --disconnect "$NBD_DEVICE"
    fi
  fi
  rm -f "$PID_FILE"
}

attach_target() {
  sudo qemu-nbd --fork --pid-file="$PID_FILE" --format=qcow2 --connect="$NBD_DEVICE" "$IMAGE"
  lsblk --paths --output NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS "$NBD_DEVICE"
}
```

## First setup: create and attach a fresh target

```bash
mkdir -p "$TEST_DIR"
qemu-img create -f qcow2 "$IMAGE" 32G
sudo modprobe nbd nbds_max=8 max_part=16
attach_target
```

## Run the current installer against the attached target

```bash
cd /home/graham/Projects/gentoo-notes
./installer/gentoo-install.sh --disk "$NBD_DEVICE" --dry-run --verbose
./installer/gentoo-install.sh --disk "$NBD_DEVICE" --verbose
```

## Detach and preserve the target for later testing

```bash
detach_target
```

## Reset to a clean target and attach it

```bash
detach_target
rm -f "$IMAGE"
qemu-img create -f qcow2 "$IMAGE" 32G
attach_target
```

## Boot after the UKI phase exists

```bash
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd "$TEST_DIR/OVMF_VARS.4m.fd"
qemu-system-x86_64 \
  -enable-kvm \
  -machine q35 \
  -cpu host \
  -m 4096 \
  -smp 4 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file="$TEST_DIR/OVMF_VARS.4m.fd" \
  -drive if=virtio,format=qcow2,file="$IMAGE"
```
