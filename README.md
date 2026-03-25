Thes are my scratch notes from installing Gentoo + Hyprland as minimally as
possible and setting things up from scratch.

using

- default/linux/amd64/23.0/desktop/systemd (stable)
- pipewire+wireplumber (no pulseaudio)
- dhcpcd+wpa_supplicant (no networkmanager)

Hopefully this repo mostly goes away in the future and is replaced by an overlay
that will do a lot more automatically.

# Get to first boot

## prepare disks

- partition with fdisk
  - 1-2 GB type EFI System
  - remainder type Linux filesystem
- set up encryption
  - cryptsetup luksFormat
- make and mount filesystems
  - vfat for boot, ext4 for /dev/mapper/root

## install base system

- install stage3 tarball
  - download desktop-systemd variant
  - `tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo`
- configure make.conf, package.uses
- chroot
  - copy DNS info
  - mount/bind filesystems
- sync portage
  - emerge-webrsync
  - set up portage to use git (<https://wiki.gentoo.org/wiki/Portage_with_Git>)
    - umount /dev/shm
    - mount --types tmpfs --options nosuid,nodev shm /dev/shm
    - emerge eselect-repository dev-vcs/git
    - do onetime stuff from that page to convert from rsync if needed
      - eselect repository remove -f gentoo
      - rm -rf /var/db/repos/gentoo
      - eselect repository add gentoo git https://github.com/gentoo-mirror/gentoo.git
    - `emaint sync` to synchronize all enabled repos (simialr to emerge --sync)
- set the profile (desktop/systemd)
- set the timezone (defer if dual booting)
- configure locales
  - edit /etc/locale.gen
  - `locale-gen`
  - eselect locale list

## install firmware and kernel

- emerge linux-firmware, gentoo-kernel
  - savedconfig
- `genkernel --luks initramfs`
- set up efibootmgr
  - `efibootmgr --create --index 5 --disk /dev/nvme0n1 --part 1 --label "gentoo-alt" --loader /EFI/boot/bootx64-alt.efi --unicode 'crypt_root=UUID=63fdec71-9236-43d1-8d4a-2f3afba7d59a root=UUID=f81baa5e-121b-4983-ab30-020d89fbe1f1 ro initrd=/EFI/boot/initrd-alt root_trim=yes'`
  - for coreboot, it is a bit more picky. This ended up working on startop
    - `efibootmgr --create --disk /dev/nvme0n1 --part 1 --index 5 --label 'gentoo-dist' --loader '\EFI\boot\boot64x-dist.efi' --full-dev-path --unicode ' crypt_root=UUID=820728fa-649e-4042-8548-f510109ac165 root=UUID=02ab8289-956a-47cb-a3e0-569309ef66d5 ro root_trim=yes initrd=\EFI\boot\initrd-dist'`
    - note some differences (I haven't isolated which of these changes is actually needed)
      - `--full-dev-path` (definitely needed)
      - `initrd=` arg is last
      - switch to backslashes in path names
- re-emerge systemd with USE=cryptsetup (or just update world)

## final configuration

- set root password
- emerge utilities
- fstab

  - simply add entries for boot and root partitions. something like

    ```
    UUID=AB80-30E8          /boot           vfat            noauto,noatime  0 2
    UUID=5560cc59-93b2-423f-8ae5-a2b31fd14284 /   ext4      defaults,noatime  0 1
    ```

- systemd (from <https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/System#systemd_2>)
  - `systemctl preset-all --preset-mode=enable-only`
  - `systemctl preset-all`

### set up wireless networking

Mutually exclusive choices for network management include:

- dhcpcd <https://wiki.gentoo.org/wiki/Network_management_using_DHCPCD>
- systemd-networkd <https://wiki.gentoo.org/wiki/Systemd/systemd-networkd>
- NetworkManager

wpa_supplicant is used for network authentication, not management

Using just dhcpcd and wpa_supplicant, this method with systemd worked well:
<https://wiki.gentoo.org/wiki/Network_management_using_DHCPCD#Using_Systemd>
essentially, just

```
cp /etc/wpa_supplicant/wpa_supplicant.conf /etc/wpa_supplicant/wpa_supplicant-DEVNAME.conf
cd /etc/systemd/system/multi-user.target.wants
ln -s /lib/systemd/system/wpa_supplicant@.service wpa_supplicant@DEVNAME.service

<<kill any wpa_supplicant instances already running>>

systemctl daemon-reload
```

Enable dhcpcd.

## boot into new install

- systemd-machine-id-setup
- systemd-firstboot --reset
- systemd-firstboot --prompt
- timedatectl set-local-rtc 1

# Install user environment

## set up user account

- `useradd -m -G users,wheel,audio,video,portage -s /usr/bin/zsh graham`
- probably later: `usermod -aG pipewire,locate graham`

## install compositor, terminal, browser

If no session gets created (i.e. Hyprland complains about no XDG_RUNTIME_DIR) I
traced this back to an "Input/Output error" with pam_systemd.so (seen via
`systemctl status systemd-logind.service` or `journalctl -b | grep pam` etc).

After much debugging, hardware tests, etc, I discovered that disabling
`systemd-userdbd` was the only workaround, and though maybe not recommended(?),
it is the case on flattop, so going with it for now.

```
systemctl disable systemd-userdbd
```

- `blacklist nouveau` in `/etc/modprobe.d/blacklist.conf` 
    - bake that blacklist into the initrd `genkernel --luks initramfs`
    - confirm with lsinitrd | grep blacklist
-`echo auto > /sys/bus/pci/devices/0000\:01\:00.0/power/control`
- to automate, write

  ```
  w /sys/bus/pci/devices/0000:01:00.0/power/control - - - - auto
  ```
  to `/etc/tmpfiles.d/nvidia-power.conf`

- can also completely remove the card from the PCI bus. Write to `/etc/udev/rules.d/00-remove-nvidia.rules`:
    ```
    # Remove NVIDIA USB xHCI Host Controller devices, if present
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x0c0330", ATTR{power/control}="auto", ATTR{remove}="1"
    
    # Remove NVIDIA USB Type-C UCSI devices, if present
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x0c8000", ATTR{power/control}="auto", ATTR{remove}="1"
    
    # Remove NVIDIA Audio devices, if present
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x040300", ATTR{power/control}="auto", ATTR{remove}="1"
    
    # Remove NVIDIA VGA/3D controller devices
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x03[0-9]*", ATTR{power/control}="auto", ATTR{remove}="1"
    ```

Opacity wasn't working in hyprland on thinktop. I blacklisted `xe` module, and now there's a race condition at hyprland start so that opacity shows up if I open hyprland.conf and save it (without changing anything). If I put my wallpaper where hyprland expects to find it, everything works fine.

    if hyprpaper failed to load a wallpaper, the compositor’s early rendering path was slightly different, and your decoration opacity only took effect once the config was re-parsed.

    Now that hyprpaper finds the wallpaper and starts cleanly, Hyprland’s render state is stable from the beginning, so the decoration opacities apply correctly on first launch without needing a manual or scripted reload

## configure pcloud via rclone

- need a browser
- rclone config
- rclone mount pcloud: /home/graham/pcloud

## setup light/dark theme switching

- install xdg-desktop-portal-gtk
- reboot
- `gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'`
- set up keyd
  - `capslock = overload(control, esc)`
- use caps as control in the console (systemd):
  - edit keymap file
  - point `/etc/vconsole.conf` to the edited keymap file
  - `systemctl restart systemd-vconsole-setup.service`

## streamline boot/login

While working on boot optimizations, I decided to streamline the boot,
authentication, general startup process. For now, I am enabling autologin, as
these are single-user systems with full disk encryption anyway.

- sudo for passwordless root: `visudo` and add `graham ALL=NOPASSWD: /bin/su -`
- terminal login: edit `/etc/systemd/system/getty@tty1.service.d/override.conf`

  ```
  [Service]
  ExecStart=
  ExecStart=-/sbin/agetty --autologin <username> --noclear %I linux
  ```

  then `systemctl daemon-reload` and `systemctl restart getty@tty1`
  Can always start debugging issues with `journalctl -u getty@tty1.service`

- automatic Hyprland start: edit `.zprofile` and add

  ```
  if [ "$(tty)" = "/dev/tty1" ]; then
      start-hyprland
  fi
  ```

## enable sound

- use `lspci -k | grep -A3 Audio` to see if kernel is loading audio drivers
- enable pipewire-alsa and sound-server USE flags for pipewire
- `usermod -aG pipewire graham`
- `systemctl --user enable --now pipewire.service pipewire-pulse.service wireplumber.service`
- install `sys-firmware/sof-firmware` on nvgen
- then `wpctl status` to show info

sometimes, `wpctl status` shows only "Dummy Output" as a sink, where it should
be showing "Built-in Audio Analog Stereo [vol: 0.50]" for both "Sinks:"
and "Sources:", and "Built-in Audio [alsa]" for "Devices:".

I haven't yet figured out

1. what causes these to drop out, or
2. how to get them back without a reboot

For example, on nvgen after a distribution gentoo-kernel upgrade, sound worked
with the dist kernel, but no longer with my (unchanged) gentoo-sources kernel. I
booted into the dist kernel and used `make localmodconfig` and rebuilt. This
didn't work. So I took the .config from the dist kernel and manually copied
everything sound related over to the .config for my kernel. This worked. The
defconfig is saved in the repo for now.

## install and configure fonts

ghostty has a zero configuration philosophy, so maybe start there. kitty also
comes with nerd fonts pre-installed.

despite passing my font smoke test scripts, the arrow icon in the default
whichkey interface was still missing, as well as the fonts in the telescope
picker.

- emerge noto-cjk, noto-emoji, dejavu, fira-mono, fira-code
- eselect fontconfig enalbe <target>
- reboot
- download nerdfonts.com zip file(s): all Ubuntu variants
- unzip into `~/.local/share/fonts`
- `fc-cache -fv`

Test some icons and emoji here in the browser:

```
    FIX = icon = " ",
    TODO = icon = " ",
    HACK = icon = " ",
    WARN = icon = " ",
    PERF = icon = " ",
    NOTE = icon = " ",
    TEST = icon = "⏲ ",

(╯°□°）╯︵ ┻━┻
¯\_(ツ)_/¯
```

I like the horizontal compactness of the Ubuntu\* nerd fonts, but their symbols
are very small compared to the Fira and Liberation system fonts (that I assume
are both taking symbols from the media-fonts/symbols-nerd-font package. Those
symbols are much nicer to read, but there are more missing compared to those
downloaded directly from nerdfonts.com.

update: I downloaded and tried (via `kitten choose-fonts`) a whole bunch of
fonts from nerdfonts.com, and discovered the large icons come from the
difference between there being a "Mono" at the and of the font package name
itself.

## set up bluetooth

- enable bluetooth USE flag
- emerge bluez
- systemct bluetooth start
- make sure no firmware issues
- bluetoothctl
  - list
  - discoverable on
  - pairable on
  - scan on
  - devices
  - pair <device_mac>
  - trust <device_mac>
  - connect <device_mac>
  - info <device_mac>
- used mictests.com to test microphone

Sometimes the '5tgb' column of the Lily58 drops out and doesn't work. Some
combination of restarting the bluetooth service, reconnecting the keyboard, and
connecting it via usb brings it back. Haven't root caused this or gotten a
consistent fix. But now I'm getting inconsistent bounce bounce behavior, both
too slow and too fast. Note: this affects so far bequiet and nvgen right after
updates. Other hosts tbd.

Just some more testing notes: I couldn't reproduce in Windows, and I removed the
bluetooth connection from Windows before rebooting. Now back in nvgen, I can't
reproduct the bad debounce behavior again. On bequiet, I haven't been able to
reproduce it again yet, but historically it only shows up intermittently anyway.

This is starting to show up a little more often, both with the repeated keys
issue, and the dead column issue. It happens most often on bequiet, and I've
never seen it yet in Windows. It has also started to happen on the right half
'6yhn' column. Most of the time, I can mostly work around it by plugging in the
affected half, but it isn't perfect (still getting debounce/dropped chars).

# minimal UKI

## Custom kernel

DO NOT CUSTOMIZE the gentoo-kernel distribution kernel. With my current level of
knowledge, it isn't worth it. Disadvantages

- no reuse of incremental builds
- difficult to get a working boot with even only minimal changes to savedconfig

configuring a custom kernel:

- start with `make localmodconfig` if no defconfig available

  - `diff defconfig-flattop /usr/src/linux/defconfig | grep '^<'` on nvgen:

  ```
  < CONFIG_LOCALVERSION="-lopez64"
  < CONFIG_DEFAULT_HOSTNAME=""
  < CONFIG_INITRAMFS_SOURCE="/boot/initrd-lopez64.cpio.xz"
  < CONFIG_CMDLINE_BOOL=y
  < CONFIG_CMDLINE="root=UUID=5560cc59-93b2-423f-8ae5-a2b31fd14284 crypt_root=UUID=655caefd-7e35-4d53-a252-ca92ff7e1bdc ro root_trim=yes panic=10"
  < CONFIG_CMDLINE_OVERRIDE=y
  < CONFIG_BT_RFCOMM=m
  < CONFIG_BT_RFCOMM_TTY=y
  < CONFIG_BT_BNEP=m
  < CONFIG_BT_BNEP_MC_FILTER=y
  < CONFIG_BT_BNEP_PROTO_FILTER=y
  < CONFIG_RAPIDIO=m
  < CONFIG_BLK_DEV_NVME=y
  < CONFIG_DM_CRYPT=y
  < CONFIG_INPUT_UINPUT=y
  < CONFIG_GPIO_CROS_EC=m
  < CONFIG_CHARGER_CROS_USBPD=m
  < # CONFIG_CHARGER_CROS_PCHG is not set
  < CONFIG_VIDEO_OV13858=m
  < CONFIG_SND_HDA_CODEC_SIGMATEL=m
  < CONFIG_SND_USB_AUDIO=m
  < CONFIG_SND_USB_AUDIO_MIDI_V2=y
  < # CONFIG_SND_SOC_SOF_INTEL_SOUNDWIRE is not set
  < CONFIG_UHID=m
  < CONFIG_USB_STORAGE=y
  < CONFIG_LEDS_CLASS_MULTICOLOR=m
  < CONFIG_CROS_EC=m
  < CONFIG_CROS_EC_LPC=m
  < CONFIG_CROS_KBD_LED_BACKLIGHT=m
  < # CONFIG_CROS_EC_LIGHTBAR is not set
  < # CONFIG_CROS_EC_DEBUGFS is not set
  < # CONFIG_CROS_EC_SENSORHUB is not set
  < # CONFIG_CROS_EC_TYPEC is not set
  < # CONFIG_CROS_TYPEC_SWITCH is not set
  < # CONFIG_DCDBAS is not set
  < # CONFIG_DELL_RBTN is not set
  < # CONFIG_DELL_SMBIOS is not set
  < # CONFIG_DELL_WMI_DDV is not set
  < # CONFIG_DELL_WMI_SYSMAN is not set
  < CONFIG_SOUNDWIRE_INTEL=m
  < CONFIG_VFAT_FS=m
  < CONFIG_FAT_DEFAULT_IOCHARSET="ascii"
  < CONFIG_CRYPTO_CHACHA20_X86_64=y
  < CONFIG_CRYPTO_POLY1305_X86_64=y
  < # CONFIG_UBSAN_SIGNED_WRAP is not set
  ```

so I copied most of these over.

## Commandline + initrd

<https://wiki.gentoo.org/wiki/Kernel/Command-line_parameters>

`cat /proc/cmdline` to see the command line of the currently running kernel

Three ways to pass parameters to the kernel

1. Kconfig (build them into the kernel)
2. UEFI (using efibootmgr --unicode)
3. various bootloaders e.g. grub, lilo, systemd-boot

building in the command line `CONFIG_CMDLINE` by itself results in the root
device not being found and kernel panic at boot (no decrypt prompt) so build in
the initrd as well. Some online sources (don't remember where) said that an
embedded command line doesn't work well without a built-in initrd.

learned that CONFIG_CMDLINE_OVERRIDE is likely needed, especially for stub
booting

Here is the recipe:

- if savedefconfig is available
  - cp defconfig to /usr/src/linux/.config
  - `make olddefconfig`
- populate CONFIG_CMDLINE="root=UUID=<uuid of /dev/mapper/root> crypt_root=UUID=<uuid of /dev/nvme0n1p2> ro root_trim=yes panic=10"
- enable CONFIG_CMDLINE_OVERRIDE
- make necessary things built-in and not modules (see .config progression)
  - so far I know DM_CRYPT can be either built-in or a module (in the initrd)
- build the kernel with `KCFLAGS="-march=native -O2 -pipe" make -j12`
- install modules with `make modules_install INSTALL_MOD_STRIP=1`
  - this noticeably affects boot speed
- generate an initrd with `genkernel --luks --no-compress-initramfs initramfs`
- copy the generated initrd to `/root/initrd-<whatever>.cpio.xz` (or whatever compression)
- uncompress the initrd image with `unxz`
- add the path to the initrd to CONFIG_INITRAMFS_SOURCE
- rebuild the kernel
- `cp arch/x86/boot/bzImage /boot/EFI/boot/boot64x.efi`
- `efibootmgr --create --disk /dev/nvme0n1 --part 1 --label "gentoo" --loader /EFI/boot/bootx64.efi`
  - or currently on startop: `efibootmgr --create --index 6 --full-dev-path --disk /dev/nvme1n1 --part 1 --label "gentoo" --loader /EFI/boot/boot64x.efi`

Note: recently I like to disable the initramfs compression in the kernel so that decompression isn't needed at boot. This also means that `unxz` is needed between `genkernel --luks initramfs` and building it into the kernel

## Firmware

<https://wiki.gentoo.org/wiki/Linux_firmware>

FIXED:
`dmesg | grep -i firmware` to see what was loaded

enable savedconfig USE flag, edit in /etc/portage/savedconfig, and reemerge

don't need /boot/amd_uc.img on Intel processors

The firmware will provide a (possibly outdated) microcode blob for the processor.
To get the newest, emerge intel-microcode (with `ACCEPT_KEYWORDS=~amd64`) and install (following https://wiki.gentoo.org/wiki/Intel_microcode for Intel microcode)

Get the processory signature fromm `iucode_tool -S` (installed as a dependency of
intel-microcode) and find the appropriate filenames with `iucode_tool -S -l /lib/firmware/intel-ucode*`

add the output to `/etc/portage/make.conf`. This is the equivalent of savedconfig

```
MICROCODE_SIGNATURES="-s 0x000c0652"
```

Then build all the firmware blobs into the kernel at

```
Device Drivers  --->
  Generic Driver Options  --->
    Firmware Loader  --->
      -*-   Firmware loading facility 
      (intel-ucode/06-c5-02) Build named firmware blobs into the kernel binary 
      (/lib/firmware) Firmware blobs root directory
```

Might as well build in the blobs from `/etc/portage/savedconfig/sys-kernel/linux-firmware` as well

On startop, the relevant part of `.config` looks like:

```
CONFIG_EXTRA_FIRMWARE="intel-ucode/06-c5-02 regulatory.db regulatory.db.p7s intel/iwlwifi/iwlwifi-ty-a0-gf-a0.pnvm intel/iwlwifi/iwlwifi-ty-a0-gf-a0-89.ucode iwlwifi-ty-a0-gf-a0-89.ucode iwlwifi-ty-a0-gf-a0.pnvm intel/ibt-0041-0041.ddc intel/ibt-0041-0041.sfi i915/mtl_gsc_1.bin i915/mtl_huc_gsc.bin i915/mtl_guc_70.bin i915/mtl_dmc.bin"
CONFIG_EXTRA_FIRMWARE_DIR="/lib/firmware"
```

## custom initrd

The kernel configured for the `genkernel` produced initramfs is ready for our custom initrd. By the end, one could remove the `root=` argument from `CONFIG_CMDLINE`.

### building static binaries

The next requirement is a fully static build of `cryptsetup` and `busybox`. We'll use portage for this, but it is going to want to build static dependencies as well. So the overview procedure is:

1. Ask portage to build/install to a different path, using `--oneshot` to keep it out of the world file
2. accept the changes to `/etc/portage/package.use` required for the build
3. do the build
4. back out the changes to `/etc/portage/package.use`. Can confirm this with a `emerge -puvDN @world` afterwords

This is a bit more complicated than it seems at first. In Sakaki's guide back in the day, she simply set `USE="static"` etc. for cryptsetup, but nowadays udev must be disabled (due to upstream issues) for a static cryptsetup build. While this *should* be okay for the system cryptsetup, I'm not going to go that route for now.

So we have to play games with either building it by hand, including all of its dependencies' static versions, or else use an alternate root for portage which pulls in 200+ dependencies to get the job done.

For now, I am going with the former option of building static `cryptsetup` and `busybox` by hand. The script `build_static_utils.sh` is in the repo.

### assemble the initramfs

Create the working directory that will become the initramfs root:

```bash
mkdir -p /usr/src/initramfs/{bin,dev,etc,lib,lib64,mnt/root,proc,root,sbin,sys,run}
```

Copy essential device nodes. These must exist before `/dev` is populated dynamically:

```bash
cp -a /dev/{null,console,tty,random,urandom} /usr/src/initramfs/dev/
```

For the LUKS partition, either copy the specific block device node (e.g., `/dev/nvme0n1p2` or `/dev/sda2`) or use `devtmpfs`/`mdev` to populate devices dynamically at boot. The `devtmpfs` approach is strongly recommended because it eliminates hardcoded device paths:

```bash
# In /init, mount devtmpfs instead of copying block device nodes:
mount -t devtmpfs devtmpfs /dev
```

Copy the static binaries and create busybox symlinks:

```bash
cp /bin/busybox /usr/src/initramfs/bin/busybox
cp /sbin/cryptsetup /usr/src/initramfs/sbin/cryptsetup

cd /usr/src/initramfs/bin
ln -s busybox sh
ln -s busybox mount
ln -s busybox umount
ln -s busybox switch_root
ln -s busybox sleep
ln -s busybox cat
ln -s busybox mdev
```

The init script is the heart of the initramfs. Create `/usr/src/initramfs/init`:

```
#!/bin/busybox sh
export PATH="/bin:/sbin"

# Mount virtual filesystems
mount -t proc     proc     /proc
mount -t sysfs    sysfs    /sys
mount -t devtmpfs devtmpfs /dev

rescue_shell() {
    echo "Dropping to rescue shell"
    exec /bin/busybox sh
}

# Find a LUKS container device by its LUKS UUID
find_luks_by_uuid() {
    target_uuid="$1"
    for dev in /dev/sd?* /dev/nvme?n?p* /dev/vd?*; do
        [ -b "$dev" ] || continue
        uuid="$(cryptsetup luksUUID "$dev" 2>/dev/null || true)"
        [ -n "$uuid" ] || continue
        [ "$uuid" = "$target_uuid" ] && { echo "$dev"; return 0; }
    done
    return 1
}

luks_uuid=""
rootfstype="ext4"

# Parse kernel command line
for param in $(cat /proc/cmdline); do
    case "$param" in
        crypt_root=UUID=*)
            luks_uuid="${param#crypt_root=UUID=}"
            ;;
        rootfstype=*)
            rootfstype="${param#rootfstype=}"
            ;;
    esac
done

[ -z "$luks_uuid" ] && echo "No crypt_root=UUID= found" && rescue_shell

# Optional: populate /dev from sysfs (not strictly required for luksUUID)
mdev -s

CRYPTSETUP=/sbin/cryptsetup
[ ! -x "$CRYPTSETUP" ] && echo "cryptsetup missing" && rescue_shell

luks_source="$(find_luks_by_uuid "$luks_uuid")" || {
    echo "Could not find LUKS device with LUKS UUID=$luks_uuid"
    rescue_shell
}

echo "<6>[initramfs] Starting LUKS root unlock" > /dev/kmsg

"$CRYPTSETUP" luksOpen "$luks_source" luksroot || rescue_shell

echo "<6>[initramfs] mounting rw /dev/mapper/luksroot" > /dev/kmsg

# Hardcode root as the filesystem inside the mapper
mount -t "$rootfstype" -o rw /dev/mapper/luksroot /mnt/root || rescue_shell

umount /proc
umount /sys
umount /dev

exec switch_root /mnt/root /sbin/init
```

### package the initramfs

Option 1: build it into the kernel as usual. 

Simply put the path to the initramfs directory tree in `CONFIG_INITRAMFS_SOURCE` and rebuild the kernel.

Option 2: have a separate initrd file

This is helpful for quickly testing initramfs changes without needing to rebuild/link the kernel. Blank out `CONFIG_INITRAMFS_SOURCE`, add `initrd=/EFI/boot/initrd` to `CONFIG_CMDLINE`, and build the file with
```
cd /usr/src/initramfs
find . -print0 | cpio --null -ov --format=newc > /boot/EFI/boot/initrd 
```
(or if you want compression)
```
find . -print0 | cpio --null -ov --format=newc | gzip -9 > /boot/initramfs.cpio.gz
```

## nvidia drivers

for bequiet with the Quadro P620 (Pascal) installed, nouveau drivers do work
with wayland/hyprland, but the performance is poor enough to notice during
normal usage (choppy mouse cursor, slow window movements).

To enable, set `VIDEO_CARDS="nouveau"` in `/etc/portage/make.conf` 

Attempting to use x11-drivers/nvidia-drivers. For right now on bequiet, I'm
using a distribution kernel so enabling the `dist-kernel` use flag; `wayland`
use flag is already enabled.

I ended up emerging nvidia-drivers, then based on warnings I saw from it about
the kernel being built with an older GCC, I emerged gentoo-kernel, then
nvidia-drivers again. Then a normal `genkernel --luks initramfs`, put the images
into `/EFI/boot` and it seems to work fine. The nvidia-drivers package
installed a `/etc/modprobe.d/nvidia.conf` and whatever else it needed.

# minimal systemd

## This is a work in progress.

Note that there is a now a util script in the gentoo-configs repo to help with this

# laptop power profiles

## intro

This is done by writing the correct values to sysfs; see their current values:

```
cat /sys/devices/system/cpu/intel_pstate/status /sys/devices/system/cpu/intel_pstate/min_perf_pct /sys/devices/system/cpu/intel_pstate/max_perf_pct /sys/devices/system/cpu/intel_pstate/no_turbo
```

This is automated by monitoring `/sys/class/power_supply/ADP1/online` with udev and triggering a minimal systemd service that calls a script to write to the sysfs values above. I am told that skipping systemd and using udev to call the script is less robust, plus we lose debug logging.

## General power profile setup (cpu only)

All of these files get deployed along with the other system configs, but they still need to be enabled manually at at this point

The script for `/usr/local/sbin/set-power-profile.sh` (cpu power only)

systemd template service goes in `/etc/systemd/system/power-profile@.service`

we also need a service to run at boot to set the correct initial state; goes in `/etc/systemd/system/power-profile-init.service`
and enable it with `systemctl enable power-profile-init.service`

Finally, our udev rule to react to AC plug/unplug goes in `/etc/udev/rules.d/99-power-profile.rules`
and reload udev with `udevadm control --reload`

nvme and wifi were also added to the `set-power-profile.sh` file. Those details have been removed from here as they are tracked in the configs repo and get deployed there.

## improved power status reporting script

this now lives in the gentoo-configs repo and gets installed to /usr/local/sbin

## add auto powertop adjustments

this now lives in the gentoo-configs repo and gets installed to /usr/local/sbin

and add an `ExecStart=` line to `/etc/systemd/system/power-profile-init.service` so it fires at boot

# package management

## package sets

To see the current list of available sets, `emerge --list-sets`

Define sets in `/etc/portage/sets` with the name of the file as the set name, and one atom per line

## binhost

bequiet should do most of the work

I first need to get threadripper reinstalled to more closely match the profile
and USE flags of nvgen and flattop

<https://wiki.gentoo.org/wiki/Binary_package_guide#Creating_binary_packages>
<https://www.gentoo.org/news/2024/02/04/x86-64-v3.html>

## personal overlay

keep useful packages around that I want

<https://github.com/XAMPPRocky/tokei>

Things I have wanted at some point in the past:

- nerdfonts
- ncdu without llvm deps
  - https://dev.yorhel.nl/ncdu
- nightly neovim
- version bumped tmux
- yt-dlp
- impala https://github.com/pythops/impala
- miniconda
- npm
- machine configs
- grist
- kmonad binary release (alternatives: kanata, keyd)
- sasl oauth2 plugin
- onlykey app
- nvhpc
- config files
- freeplane
- logseq
- gensys (my project)
- sakaki's tools (buildkernel, etc.)
- my savedconfigs
- my kernel image that can be put on an sd card and boot any of my machines
- terminal fun things:
  - <https://github.com/cmatsuoka/asciiquarium>
  - <https://gitlab.com/jallbrit/cbonsai>
  - <https://github.com/bartobri/no-more-secrets>

# Networking

## Proton VPN

Here's the current setup:

1. Log in to Proton VPN web interface and make a wireguard config.
2. `emerge wireguard-tools` - Pay attention to the kernel config requirements
3. put config in `/etc/wireguard`, owned by root, perms 600. Ensure filename is under 15 chars e.g. `pvpn-us-ga.conf`
4. `wg-quick up/down pvpn-us-ga` 
5. check connection with `wg show`
6. `curl https://ip.me` (will probably show ipv6 if the website prefers it) `curl -4 https://ip.me` or `curl -4 https://ipconfig.co`

# secrets management

## proton pass cli

https://protonpass.github.io/pass-cli/get-started/configuration/#secure-key-storage

```
curl -fsSL https://proton.me/download/pass-cli/install.sh | bash
```

Then some usage:

```
pass-cli login --interactive
pass-cli item view pass://utils/gza-ssh-key --output json | jq
pass-cli item view pass://utils/gza-ssh-key/public_key > ~/.ssh/id_ed25519.pub
```

pass-cli uses the kernel keyring; `emerge -av keyutils` to take a look `keyctl show`

## yubikey

This is a future TODO: to get yubikeys set up for various use cases

### ssh keys on yubikey

### proton FIDO2

Can use yubikey and keep TOTP codes as alternative/backup for proton account access

### luks decrypt

- unlock luks root with usb device (storage or yubikey)
    - [about TPM unlock](https://blastrock.github.io/fde-tpm-sb.html)

### mobile (NFC)

## ssh keys and agent

[a very thorough cloudflare article on the kernel keyring](https://blog.cloudflare.com/the-linux-kernel-key-retention-service-and-why-you-should-use-it-in-your-next-application/)
- note this isn't yet supported for ed25519 keys, only RSA which suck

So just use the built-in openssh agent, no keyring utility needed with some shell jankery (see `.zshrc` and `.utils/lazy_ssh.sh`)

# configuration management

## user dot files

This is mostly solved with the tried and true bare repo / working dir solution, but there are always might be some enhancements that are possible.

## system configs

This roughly follows the same method as the user dotfiles, but git is bad at permissions, so I've put a helper fixup script in the repo's utils directory

## kernel configurations

TODO: For right now, these machine-specific kernel configurations, firmware blobs, initrds, and their evolutions live in the gentoo-configs repo in machine-designated files/dirs that get manually copied into place

# Future Enhancements

## unsorted list

A big list of ideas of things I've wanted to try at some point. Some are very
low effort, some are very high.

- external monitors in hyprland
- build up from smaller (non-desktop) profile
- telescope search icons in nvim for "disk" and see many squares and kanji
- screenlocking and fingerprint reader
- user mount removable devices
- more theming (with fast/auto switching): wallpaper+colors/pywal16+fonts
- virutalization:
  - qemu for kernel/boot debugging
  - lightweight containers for linux (lxc, podman, etc.)
  - gentoo prefix
  - gentoo in WSL
  - lookinglass for windows
  - https://github.com/quickemu-project/quickemu
  - https://github.com/HikariKnight/QuickPassthrough
- touchpad palm rejection for nvgen and multigestures

## Screen brightness buttons

`echo 25000 > /sys/class/backlight/intel_backlight/brightness`
note that sys-power/acpilight comes with useful udev rules for allowing video
group write access

testing with `evtest` doesn't show any output when testing the keyboard device
'2', as these buttons are actually on 'event8'. Then the keypresses will
register. Note that the next song button etc. register on the evtest keyboard
event. None of the multimedia keys show up with wev/xev.

- screen brightness buttons
    - framework `blacklist hid_sensor_hub`

## Improve terminal themes

need better (more contrasty) light theme colors

it would be cool to be able to dynamically/interactively change the themes like
I do with neovim

### zsh, tmux, dir_colors

ensure these follow along nicely

### change transparency on the fly or based on dark/light

this may not really be possible in ghostty

probably eventually combine with light/dark theme switching

how to get kitty to reload its config in all running instances? This isn't
really possible, but you can get it to reload its config file with ctrl+shift+F5
or with `kill -SIGUSR1 <kitty_pid>`

so for kitty:

- background_opacity isn't supported in the theme files
- have a separate, single line file with `background_opacity` that is included
  in the main kitty.conf. Do not put this file under version control because it
  will get changed all the time
- now can script `echo "background_opacity 0.8" > ~/.config/kitty/opacity.conf`
  and a `kill -SIGUSR1 <kitty_pids>` to dynamically change

for ghostty, the only way to force a config reload is to interactively use a
keyboard shortcut. But this is probably okay as a workaround, as I usually don't
have too many terminals open and don't change themes too often.

## hyprland complaints

When starting kitty from a terminal:

```
[0.110] [glfw error 65544]: process_desktop_settings: failed with error: [org.freedesktop.DBus.Error.UnknownMethod] No such interface “org.freedesktop.portal.Settings” on object at path /org/freedesktop/portal/desktop
```

suggest installing and starting xdg-desktop-portal-hyprland (via guru overlay)

```
[0.110] [glfw error 65544]: Notify: Failed to get server capabilities error: [org.freedesktop.DBus.Error.ServiceUnknown] The name org.freedesktop.Notifications was not provided by any .service files
```

suggest installing and starting a notification service
<https://www.perplexity.ai/search/how-do-i-solve-the-following-e-RjBEBexwSeusYywGKEiBTg#1>

```
[0.148] Could not move child process into a systemd scope: [Errno 5] Failed to call StartTransientUnit: org.freedesktop.DBus.Error.Spawn.ChildExited: Process org.freedesktop.systemd1 exited with status 1
```

## systemd - other

systemd can handle automatic parition mounting, but I'm not yet sure how
this works with luks encryption, or if I want this over /etc/fstab
(<https://wiki.gentoo.org/wiki/Systemd#Automatic_mounting_of_partitions_at_boot>)

there are a load of USE flags for systemd; there might be some interesting
things to take advantage of. (<https://wiki.gentoo.org/wiki/Systemd#USE_flags>)

verbosity of boot messages can be tweaked
<https://wiki.gentoo.org/wiki/Systemd#Configure_verbosity_of_boot_process>

systemd-bootchart will show boot process performance. It requires the `boot` USE
flag, but this also installs the systemd-boot bootloader, so probably want to
look at 3rd-party utilities for profiling

systemd-sysext and systemd-confext look interesting and may warrant future
investigation.

systemd-pstore for debug and tuning info

## kitty clean exit with disowned process

use `nohup [command] &> /dev/null &`

This makes using kitty as the dropdown terminal less useful

after backgrounding and disowning a process in the kitty terminal, pressing
ctrl+d to close the shell+terminal causes a hang

adding to `.config/kitty/kitty.conf` didn't help:

```
shell_integration enabled  # Ensure proper shell state tracking
confirm_os_window_close -1 # Disable exit confirmation prompts[4]
```

# starfighter quirks and todos

- why does `acpi -bi` report "Not Charging" when plugged in?
- further kernel trim (config_debug, etc.)
- delay devices until userspace on-demand (like bluetooth on systemd services start, wifi after hyprland, etc.)
- test against dist kernel if any more kernel drivers needed for addtl lm_sensors
- compare microsd blk device names to Ubuntu
- enable webcam, test microphone
- battery use is 1.5W higher at idle after suspend/resume
- audio amp clicks
  - turn off soundcard in /sys?
  - remove/add driver module on demand?
- `.utils/hypr_lid.sh` causes lockup
  - could be due to new hyprland version

## fixed

- kkey debounce
  - add `i8042.nomux` to kernel command line improves it quite a bit, but not completely
    - completely gone in kitty, but still happens in firefox
  - also trying `i8042.nomux i8042.reset` to see if we can get any additional improvement
  - libinput was a deadend
  - `/etc/keyd/default.conf` seems to be doing a decent job so far

        # /etc/keyd/default.conf
        [ids]

        *

        [main]

        # Maps capslock to escape when pressed and control when held.
        capslock = overload(control, esc)

        # Remaps the escape key to capslock
        # esc = capslock

        debounce = 50
        repeat_delay = 800
        repeat_rate = 10

- no key repeat in console
  - fix with atkbd.softrepeat=1 kernel arg?
  - this went away somehow after installing 98 packages to get hyprland installed
- 7w idle usage
  - powertop helped a bit
  - booted minimal and measured around 4.2W on console with backlight very low
  - now around 5-5.5W in hyprland
  - plugging usb mouse ups it by 0.5W
  - intel EPP (tuned ebuild) package recommended (StarFighter Perplexity space)

# thinktop quirks and fixes

## trackpoint sensitivity

add to hyprland.conf
```
device {
    name = tpps/2-elan-trackpoint
    sensitivity = -0.30
    accel_profile = adaptive
}
```

# install friction

- graphics setup
    - disable nouveau
    - set up auto power for gpu
- fonts setup
    - minimize but get everything
    - nerd fonts, kaomoji, greek
    - media-fonts/dejavu                    a common font that I don't use much
    - media-fonts/fira-code                 a decent font that I don't use much
    - media-fonts/fira-mono                 a decent font that I don't use much
    - media-fonts/noto-cjk                  for things shrug and table flip emoji
    - media-fonts/noto-emoji                emoji font
- getting local/apps/{tmux,neovim} installed
    - easy enough from source
