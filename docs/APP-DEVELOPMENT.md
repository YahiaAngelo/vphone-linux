# Developing iOS apps on Linux

Write an iOS app on Linux with [xtool](https://github.com/xtool-org/xtool), then build it, run it in
the VM, read its log and iterate, all without a Mac, an Apple Developer account or signing on the
host. vphoned installs and signs the app inside the guest.

Tested on an iPhone 16 Pro VM with iOS 27.0.1, made with `setup/create-vm.sh`. A rebuild takes about
8 s and a reinstall about 3 s.

<img src="screenshots/xtool-app.png" width="260" alt="A SwiftUI app built with xtool on Linux, running in the VM">

## 1. Install xtool

xtool is a cross-platform replacement for Xcode's build step: it builds SwiftPM apps for iOS and
packages them as `.ipa` files. It needs Swift, which `setup/setup.sh` already installs.

```sh
mkdir -p ~/.local/bin
curl -L -o ~/.local/bin/xtool \
  https://github.com/xtool-org/xtool/releases/latest/download/xtool-x86_64.AppImage
chmod +x ~/.local/bin/xtool
xtool --version
```

It is an AppImage. If it does not start, your system lacks FUSE 2: run it with
`--appimage-extract-and-run`, or install your distribution's `fuse` / `libfuse2` package.

## 2. Install the iOS SDK (once)

xtool builds against the iOS SDK that ships inside Xcode. Download Xcode's `.xip` from
[Apple's developer downloads](https://developer.apple.com/download/all/?q=xcode) (a free Apple ID
is enough), then:

```sh
xtool sdk install          # asks for the path to Xcode_*.xip and builds the Darwin SDK
xtool sdk status           # "Darwin SDK is installed"
```

`xtool setup` does the same and also signs in to Apple Developer Services. That sign-in is only
needed for real devices; the VM does not need it.

## 3. Create an app

```sh
xtool new HelloVPhone
cd HelloVPhone
```

This makes a SwiftPM project: `Package.swift`, your code in `Sources/HelloVPhone/`, and
`xtool.yml` with the app's bundle ID (`com.example.HelloVPhone` here). Edit the bundle ID there.

## 4. Build, install, run

With the VM running (its vsock CID is 3 unless you chose another, e.g. `create-vm.sh --cid 5`):

```sh
xtool dev build --ipa                                    # -> xtool/HelloVPhone.ipa (unsigned)
/path/to/vphone-linux/tools/install-ipa.py xtool/HelloVPhone.ipa \
    --launch com.example.HelloVPhone --cid 3
```

`install-ipa.py` uploads the `.ipa` over vsock, installs it with vphoned (which signs it in the
guest) and opens it in the window. Use `xtool dev build --ipa`, not `xtool dev run`: `dev run`
installs on a USB-connected device, and the VM is not one.

**The edit–build–run loop.** Installing over an installed app replaces it and relaunches it, so
one command does the whole loop:

```sh
vrun() {
  xtool dev build --ipa &&
    /path/to/vphone-linux/tools/install-ipa.py "xtool/$1.ipa" --launch "$2" --cid "${CID:-3}"
}
vrun HelloVPhone com.example.HelloVPhone
```

## 5. Read your app's log

Log with `os.Logger`, and mark the values you want to read as public. Like a real iPhone, the
guest shows other dynamic values as `<private>`:

```swift
import os
private let log = Logger(subsystem: "com.example.HelloVPhone", category: "ui")

log.notice("tapped \(taps, privacy: .public) times")
```

Then, while you use the app:

```sh
tools/app-logs.py HelloVPhone --subsystem com.example.HelloVPhone --seconds 15 --cid 3
```

```text
13:29:16 notice com.example.HelloVPhone/ui: tapped 1 times
13:29:17 notice com.example.HelloVPhone/ui: tapped 2 times
```

Without `--subsystem` you also get the lines UIKit and the frameworks log for your process. `--json`
prints the raw entries.

**Crashes.** iOS writes a crash report as on a phone. List and read them through vphoned:

```sh
tools/vphoned.sh POST /v1/rpc '{"method":"logs.crashes","params":{"bundle_id":"com.example.HelloVPhone"},"id":1}'
tools/vphoned.sh POST /v1/rpc '{"method":"logs.crash","params":{"path":"<a path from the list>"},"id":1}'
```

## 6. Drive and check the app from the host

vphoned also takes input and screenshots, which is enough for simple automated checks.
Coordinates are in screen points (430x932 on an iPhone 16 Pro):

```sh
tools/vphoned.sh POST /v1/rpc '{"method":"input.tap","params":{"x":215,"y":571},"id":1}'
tools/vphoned.sh POST /v1/rpc '{"method":"screen.screenshot","params":{},"id":1}'   # base64 JPEG
tools/vphoned.sh POST /v1/rpc '{"method":"apps.terminate","params":{"bundle_id":"com.example.HelloVPhone"},"id":1}'
```

## 7. Uninstall

```sh
tools/vphoned.sh POST /v1/rpc '{"method":"apps.uninstall","params":{"bundle_id":"com.example.HelloVPhone","force":true},"id":1}'
```

This removes the app and its data container (without `force` vphoned asks for it).

## Notes

- Set `CID=<n>` (or pass `--cid`) for every tool when the VM does not use CID 3.
- Apps run in the guest's sandbox, as installed apps do on a phone. vphoned's signing makes them
  run without an Apple account; entitlements that need Apple's provisioning (push, iCloud, ...)
  have not been tested.
- See [docs/TOOLS.md](TOOLS.md) for `install-ipa.py` and `app-logs.py`, and vphone-cli's
  `Research/vphoned_http_api.md` for every vphoned method.
