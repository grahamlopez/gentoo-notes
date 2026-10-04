# QEMU NBD disk test

## Host tools

```bash
sudo pacman -S --needed qemu-base
```

## Create and attach the disposable target disk

```bash
mkdir -p /home/graham/VMs/agentic-gentoo
qemu-img create -f qcow2 /home/graham/VMs/agentic-gentoo/target.qcow2 32G
sudo modprobe nbd nbds_max=8 max_part=16
sudo qemu-nbd --fork --pid-file=/home/graham/VMs/agentic-gentoo/target.nbd.pid --format=qcow2 --connect=/dev/nbd0 /home/graham/VMs/agentic-gentoo/target.qcow2
lsblk --paths --output NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS /dev/nbd0
```

## Exercise disk setup

```bash
cd /home/graham/Projects/gentoo-notes
./installer/gentoo-install.sh --disk /dev/nbd0 --dry-run --verbose
./installer/gentoo-install.sh --disk /dev/nbd0 --verbose
```

## Detach the target disk

```bash
sudo umount /mnt/gentoo/efi
sudo umount /mnt/gentoo/home
sudo umount /mnt/gentoo
sudo cryptsetup close cryptroot
sudo qemu-nbd --disconnect /dev/nbd0
rm -f /home/graham/VMs/agentic-gentoo/target.nbd.pid
```

## Reset the target disk

```bash
rm -f /home/graham/VMs/agentic-gentoo/target.qcow2
qemu-img create -f qcow2 /home/graham/VMs/agentic-gentoo/target.qcow2 32G
```

## Boot after the UKI phase exists

```bash
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd /home/graham/VMs/agentic-gentoo/OVMF_VARS.4m.fd
qemu-system-x86_64 \
  -enable-kvm \
  -machine q35 \
  -cpu host \
  -m 4096 \
  -smp 4 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file=/home/graham/VMs/agentic-gentoo/OVMF_VARS.4m.fd \
  -drive if=virtio,format=qcow2,file=/home/graham/VMs/agentic-gentoo/target.qcow2
```
