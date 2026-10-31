# Setup

From an empty Linux PC to an iPhone home screen in a window, with no Mac: you install the
dependencies, build vphone-linux, create the virtual iPhone from Apple's published firmware, and
start it.

> **The short path.** `setup/setup.sh` builds everything (dependencies, sources, binaries, the
> release bundle — re-runnable, it skips what is done), and `setup/create-vm.sh` then menus you
> down to a tested device + iOS pairing and runs the whole create flow with one state file per VM.
> That is all most people need:
>
> ```sh
> ./setup/setup.sh
> ./setup/create-vm.sh
> ```
>
> The rest of this guide is the manual path — the same steps, every command visible — plus the
> parts the two scripts do not cover (your own apps, performance tuning).

1. [What you need](#1-what-you-need)
2. [Install the dependencies](#2-install-the-dependencies)
3. [Build](#3-build)
4. [Create the VM](#4-create-the-vm)
5. [Start it](#5-start-it)
6. [Run your own app](#6-run-your-own-app)
7. [Make it faster (optional)](#7-make-it-faster-optional)

Something not working? See [TROUBLESHOOTING.md](TROUBLESHOOTING.md). Every detail this guide leaves
out (building by hand, display scale, services, the pinned commits) is in [ADVANCED.md](ADVANCED.md).

> Already have a VM made with vphone-cli on a Mac? [CREATE-ON-MAC.md](CREATE-ON-MAC.md) replaces
> step 4; everything else here is the same.

## 1. What you need

| | Minimum | Recommended |
|---|---|---|
| CPU | x86_64, 8 threads | 8 or more fast cores (speed per core matters most) |
| RAM | 16 GB | 32 GB |
| GPU | A Vulkan GPU | NVIDIA (the only vendor tested so far) |
| Disk | 100 GB free, btrfs or XFS | SSD, 150 GB free |
| OS | Fedora, Debian 13+, Ubuntu 25.04+, Arch/Omarchy, or Windows 11 with WSL2 | Fedora (the most tested) |

- **Root** (sudo) for a few steps while creating the VM.
- **An internet connection**: about 13 GB of firmware comes from Apple's servers.
- **Disk:** the builds take about 15 GB; creating the VM needs about 45 GB on a file system with
  reflink copies (btrfs, XFS), not tmpfs; the finished VM uses about 16 GB.

The minimum column is an estimate: vphone-linux was tested on one PC so far (Fedora 44, Intel
i7-14700K, 62 GB RAM, RTX 4080 SUPER). Reports from other hardware are welcome. On a CPU with fewer
than 8 cores, start the VM with fewer virtual CPUs (`SMP=4`). AMD GPUs need access to
`/dev/udmabuf` ([reims-vgpu's notes](https://github.com/steelbrain/reims-vgpu#readme)). No KVM is
needed.

Everything runs under emulation, so expect it to be slower than a real iPhone: apps take a few
seconds to open and scrolling runs at about 60 frames/s with occasional stutters.

## 2. Install the dependencies

On Fedora (and RHEL-likes):

```sh
sudo dnf install git gcc gcc-c++ clang lld binutils make cmake ninja-build meson python3 \
  python3-pillow rsync glib2-devel pixman-devel lzfse-devel libslirp-devel \
  libssh-devel libzstd-devel nettle-devel gnutls-devel gtk3-devel \
  sdl2-compat-devel bzip2-devel libX11-devel libXScrnSaver-devel \
  wayland-devel libxkbcommon-devel vulkan-loader vulkan-loader-devel \
  vulkan-tools socat gdb perf unzip curl zstd usbip fuse-sshfs fuse3 7zip \
  kernel-devel libusb1-devel libplist-devel libimobiledevice-glue-devel \
  openssl-devel libcurl-devel libimobiledevice-devel libusbmuxd-devel \
  libtatsu-devel libarchive-devel zip libedit-devel sqlite-devel \
  libuuid-devel python3-devel libstdc++-static
```

On Debian 13+ and Ubuntu 25.04+ (and Mint, Pop!_OS... built on them):

```sh
sudo apt-get update
sudo apt-get install git gcc g++ clang lld binutils make cmake ninja-build meson python3 \
  python3-pil python3-setuptools pkg-config rsync unzip curl zstd \
  libglib2.0-dev libpixman-1-dev liblzfse-dev libslirp-dev libssh-dev \
  libzstd-dev nettle-dev libgnutls28-dev libgtk-3-dev libsdl2-dev \
  libbz2-dev libx11-dev libxss-dev libxkbcommon-dev libwayland-dev \
  wayland-protocols libvulkan-dev mesa-vulkan-drivers vulkan-tools socat \
  gdb hwdata sshfs fuse3 7zip bc flex bison libelf-dev binutils-gold zip \
  gnupg2 libpython3-dev libxml2-dev libncurses-dev libz3-dev libedit-dev \
  libsqlite3-dev libusb-1.0-0-dev libplist-dev libimobiledevice-glue-dev \
  libssl-dev libcurl4-openssl-dev libimobiledevice-dev libusbmuxd-dev \
  libtatsu-dev libarchive-dev \
  linux-headers-generic usbip        # Ubuntu: linux-tools-generic in place of usbip
```

Ubuntu 24.04 and other older releases have no `libimobiledevice-glue` or `libtatsu` and an older
libimobiledevice than the 1.4 that vphone-cli's restore code links; use a newer release.

On Arch Linux and Omarchy (and CachyOS, EndeavourOS, Manjaro...), with the system up to date first
(`sudo pacman -Syu`, or `omarchy update` on Omarchy; reboot if the kernel was updated):

```sh
sudo pacman -S --needed git base-devel gcc clang lld binutils make cmake ninja meson pkgconf \
  python python-pillow python-setuptools rsync glib2 pixman libslirp libssh zstd nettle gnutls \
  gtk3 sdl2-compat bzip2 zlib libx11 libxss libxkbcommon wayland vulkan-icd-loader vulkan-headers \
  vulkan-tools libxext libxrandr libxcursor libxi libxfixes libxtst libdecor libdrm flex bison dtc \
  socat gdb perf usbip sshfs fuse3 7zip zip unzip curl gnupg libusb libplist \
  libimobiledevice-glue libimobiledevice libusbmuxd libtatsu libarchive openssl \
  libxml2-legacy libedit sqlite "$(cat /usr/lib/modules/$(uname -r)/pkgbase)-headers"
git clone https://aur.archlinux.org/lzfse.git /tmp/lzfse
echo "options+=('!lto')" >> /tmp/lzfse/PKGBUILD && (cd /tmp/lzfse && makepkg -sif)
```

`lzfse` is only in the AUR. Build it with LTO off as above (not with yay/paru): Arch's default LTO
fills its static `liblzfse.a` with GCC's intermediate code, which the Swift toolchain's linker cannot
read (`undefined symbol: lzfse_encode_buffer`). `libxml2-legacy` provides `libxml2.so.2`, which the Swift toolchain
(`swift build`, `lld`) needs; Arch's own `libxml2` is a newer, incompatible version. The last
package is the headers for the kernel you run (`linux-headers`, `linux-zen-headers`...). Your GPU's
Vulkan driver must be installed too: `nvidia-utils` (Omarchy installs it on NVIDIA PCs),
`vulkan-radeon` or `vulkan-intel`. Arch already sets `vm.max_map_count` to 1048576.
`setup/setup.sh` does all of this (the list lives in `setup/lib/packages.sh`).

These lists are `setup/lib/packages.sh`, which `setup/setup.sh` installs and CI checks on Fedora
43/44, Debian 13, Ubuntu 25.10/26.04 and Arch. On other distributions, install the same packages
under their names there. `lld` provides
`lld-link` and `ld.lld`, which reims-vgpu's option ROM is linked with (`reims-vgpu/firmware/Makefile`). (Checked in a clean
Fedora 44 container: they all install, every library the build links against is then present, and the GPU library's SDL window code configures.)

Then:

- **Rust**, with [rustup](https://rustup.rs).
- **Swift 6.4.1** for Linux (the version in `linux-create/.swift-version`). You don't need to install
  it yourself: `linux-create/build.sh` installs [swiftly](https://www.swift.org/install/linux/) and
  this toolchain when it's missing, and calls it by its full path. Nothing is added to your shell's
  PATH. It always names swiftly's platform, because swiftly only recognises the exact releases it
  lists (on Fedora 44 its own detection fails with "Unsupported Linux platform"): Fedora gets the
  `fedora41` build, Debian `debian12`/`debian13`, Ubuntu its LTS (or the one below it), and Arch,
  RHEL-likes and the rest `ubi9`. On Arch it also links Arch's `libncursesw.so.6` into the
  toolchain as the `libncurses.so.6` it expects.
- **rcodesign**, which signs app bundles while the VM is created: `cargo install apple-codesign --locked`.

Set two system options. They are permanent, so this is needed only once:

```sh
echo vhost_vsock | sudo tee /etc/modules-load.d/vhost-vsock.conf
echo 'KERNEL=="vhost-vsock", MODE="0666"' | sudo tee /etc/udev/rules.d/90-vhost-vsock.rules
sudo modprobe vhost_vsock && sudo chmod 666 /dev/vhost-vsock
echo 'vm.max_map_count = 1048576' | sudo tee /etc/sysctl.d/90-vphone.conf && sudo sysctl --system
```

`vhost_vsock` is how the tools talk to the iPhone; `max_map_count` lets the GPU code map the guest's
memory. Then get the code and check your PC:

```sh
git clone https://github.com/YahiaAngelo/vphone-linux.git
cd vphone-linux
tools/check-host.sh
```

All commands from here on run in this `vphone-linux` directory.

## 3. Build

**QEMU and the GPU library:**

```sh
./build.sh
```

This downloads the three submodules and builds the GPU library and QEMU. The first build takes a
while (the GPU library is large). Run `./build.sh` again after every `git pull`.

The rest of this step builds the tools that create the VM.

**vphone-cli's firmware tools, for Linux** (`linux-create/`, about 5 minutes):

```sh
linux-create/build.sh      # fetches vphone-cli, installs Swift if needed, syncs and builds
linux-create/vphone-cli --help
```

`linux-create/vphone-cli` runs the built tool (it builds it first if needed); use it as
`sudo linux-create/vphone-cli ...` for the steps that need root.

**vphone-cli's release files.** Download
[VPhone-2.14.2.zip](https://github.com/Lakr233/vphone-cli/releases/download/2.14.2/VPhone-2.14.2.zip)
from [vphone-cli's 2.14.2 release](https://github.com/Lakr233/vphone-cli/releases/tag/2.14.2). It is
the macOS app; nothing in it runs here, but it carries the open-source boot ROMs (OpenAVB and OpenSEP)
and the iPhone-side programs the VM gets (vphoned and others):

```sh
curl -L -o .build/VPhone-2.14.2.zip https://github.com/Lakr233/vphone-cli/releases/download/2.14.2/VPhone-2.14.2.zip
mkdir -p .build/vphone-release-2.14.2/app
unzip -q .build/VPhone-2.14.2.zip -d .build/vphone-release-2.14.2/app
R=.build/vphone-release-2.14.2/app/VPhone.bundle/Contents/Resources
ln -sfn $R/guest-resources guest-resources
mkdir -p OpenAVB OpenSEP
cp $R/OpenAVB/OpenAVB.bin OpenAVB/ && cp $R/OpenSEP/OpenSEP.bin OpenSEP/
```

The release and the vphone-cli checkout must be the same version.

**The APFS driver** ([linux-apfs-rw](https://github.com/linux-apfs/linux-apfs-rw)), which reads the
firmware's disk images, built for the running kernel:

```sh
git clone https://github.com/linux-apfs/linux-apfs-rw.git .build/linux-apfs-rw
git -C .build/linux-apfs-rw checkout 03187127cd2e62cf78321cdb942eb3a7b17981f9
git -C .build/linux-apfs-rw apply ../../patches/linux-apfs-rw-ios27.patch   # iOS 27 volumes
make -C .build/linux-apfs-rw          # -> .build/linux-apfs-rw/apfs.ko, loaded when needed
```

The patch accepts the volume features iOS 27 sets (three new feature bits, and PFK, which it
now warns about instead of refusing); without it iOS 27's volumes do not mount. `setup/setup.sh`
does all of this.

Rebuild it after a kernel update.

**usbmuxd with 32 KiB packets**, which the restore needs (the stock one breaks it):

```sh
tools/build-usbmuxd-32k.sh            # -> .build/usbmuxd-32k/usbmuxd
```

## 4. Create the VM

Follow [CREATE-ON-LINUX.md](CREATE-ON-LINUX.md). In short, it:

1. makes an empty VM;
2. downloads Apple's iPhone and cloudOS firmware and patches it;
3. restores it into the VM, over a virtual USB connection;
4. starts a small SSH system in the VM and installs vphone-cli's custom firmware (vphoned and the
   patches the VM needs);
5. boots the finished VM for the first time.

It takes about an hour plus the downloads, and asks for sudo a few times. You end up with
`vms/myphone`, already at the lock screen; continue with step 5.

## 5. Start it

**NVIDIA only, after every reboot:** lock the GPU clocks. Otherwise the GPU stays at idle speed and
every frame waits for it. These numbers are for an RTX 4080 SUPER; `nvidia-smi -q -d SUPPORTED_CLOCKS`
lists yours.

```sh
sudo nvidia-smi --lock-gpu-clocks=2000,3105 && sudo nvidia-smi --lock-memory-clocks=10000,11501
```

Start the VM (a VM made by `setup/create-vm.sh` starts with `./setup/start-vm.sh`, which does
this and the unlock below for you):

```sh
GFX=1 WINDOW=1 ./run-vphone.sh vms/myphone
```

A window opens with the iPhone's screen; the terminal shows the boot log. It takes 1-3 minutes to
the lock screen. Then unlock it, from a second terminal:

```sh
tools/vphoned.sh POST /v1/rpc '{"method":"screen.unlock","params":{},"id":1}'
```

If it answers "Lock Screen did not dismiss in time", wait 15 seconds and run it again. Swiping up from
the bottom of the screen also works.

**On Omarchy (or any Hyprland setup)** the window is tiled and stretched by default. Run
`tools/omarchy-window.sh` once (`setup/setup.sh` offers it): it adds a Hyprland rule,
`~/.config/hypr/vphone-linux.lua`, that floats the window centred at the iPhone's shape, 85% of the
screen's height, fully opaque, and keeps the PC from idling while it has focus.
`tools/omarchy-window.sh --remove` undoes it.

**Using it:** click to tap, drag to scroll, swipe up from the bottom edge (or middle-click) to go
Home. If clicks do nothing, the screen has gone to sleep: run the unlock command again, and set
Auto-Lock to Never (step 7).

**Stopping it:**

```sh
tools/vphoned.sh POST /v1/rpc '{"method":"system.shutdown","params":{"force":true},"id":1}'
```

or press Ctrl-A then X in the terminal QEMU runs in.

## 6. Run your own app

Build an iOS app on Linux with [xtool](https://github.com/xtool-org/xtool) and run it in the VM. No
Apple ID or signing is needed: vphoned signs the app inside the guest when it installs it.

```sh
xtool new HelloVPhone && cd HelloVPhone
xtool dev build --ipa                     # -> xtool/HelloVPhone.ipa, unsigned
../tools/install-ipa.py xtool/HelloVPhone.ipa --launch com.example.HelloVPhone
```

`xtool sdk install` installs the iOS SDK it needs once (it asks for Xcode's `.xip`, which you download
from Apple). On the test PC the sample app built in 9 s, installed in 2 s and opened in the window,
where taps reach it. The full workflow (installing xtool, the edit–build–run loop, reading your
app's log, crashes, uninstalling) is in [APP-DEVELOPMENT.md](APP-DEVELOPMENT.md).

<img src="screenshots/xtool-app.png" width="260" alt="A SwiftUI app built with xtool on Linux, running in the VM">

## 7. Make it faster (optional)

These made the biggest difference on the test PC:

1. **In the iPhone's Settings:** Accessibility > Motion > **Reduce Motion** on; Accessibility >
   Display & Text Size > **Reduce Transparency** on; Display & Brightness > **Auto-Lock: Never**
   (or, with the VM running, `python3 tools/auto-lock-never.py vms/myphone 3`).
2. **Render at 1x** instead of 3x, about 9 times fewer pixels with the same layout. With the VM
   running:

   ```sh
   tools/set-scale.sh vms/myphone 1
   ```

   It clears the screen scale iOS has cached, shuts the VM down, patches the scale and sets the
   matching display size. Start the VM again, and once it is up, give it a boot Apple logo (iOS has
   none for 1x, so the boot screen stays black without it):

   ```sh
   GFX=1 WINDOW=1 ./run-vphone.sh vms/myphone
   python3 tools/guest-1x-logo.py 3       # from a second terminal, once it is up
   ```

   `tools/set-scale.sh vms/myphone 3` goes back to 3x.
   On iOS 27 use `2` instead of `1`: iOS 27 does not go below 2x (2x is still 2.25 times fewer
   pixels than 3x, and needs no boot logo). Keep an iPhone Duo at 3x for now
   ([ADVANCED.md](ADVANCED.md#display-scale)).
3. **Turn off background services** the VM doesn't need for app testing (iCloud, Siri, analytics...).
   More are listed in [ADVANCED.md](ADVANCED.md#background-services).

[PERFORMANCE.md](PERFORMANCE.md) explains where the time goes and every tuning switch.
