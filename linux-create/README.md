# linux-create

vphone-cli's firmware tooling (`fw prepare`, `fw patch`, `restore`, `cfw install`, `sign`, ...) built
for Linux, so the VM can be created with no Mac. The steps are in
[docs/CREATE-ON-LINUX.md](../docs/CREATE-ON-LINUX.md).

vphone-cli's own files are not copied or changed here. `sync-sources.sh` links them from a vphone-cli
checkout (`VPHONE_CLI`, default `../vphone-cli`; tested with tag `2.12.1`) into `Sources/`, minus the
files listed in `excludes/`, plus:

- `Shims/`: Linux stand-ins for Apple modules (Darwin, CryptoKit, Compression, MachO,
  AppleArchive, CommonCrypto, ...);
- `overlay/`: whole-file replacements and Linux-only files (the Linux `cfw install` path, the restore
  bridge, URLSession workarounds, `fw snapshot-flip`);
- `edits/`: one-line sed edits, one `path<TAB>expression` per line.
- `Vendor/Img4tool/`: libimg4-spm 0.1.1 (the version vphone-cli pins) adapted for Linux; see its README.

```sh
./build.sh                 # clone vphone-cli, install Swift if missing, sync-sources, swift build
./vphone-cli fw prepare …  # run it (builds first when needed); sudo ./vphone-cli … for root steps
# the binary: .build/out/out/Products/Debug-linux-x86_64/vphone-cli
```

`build.sh` uses the Swift version in `.swift-version` (6.4.1). If it's missing, the script installs it
with swiftly (Arch and other unsupported distros use swiftly's `ubi9` platform) and runs it by its full
path, so you don't need to source swiftly's `env.sh` and its `clang`/`lld` stay off your PATH. Extra
arguments go to `swift build` (for example `./build.sh -c release`). `VPHONE_CLI=DIR` builds against an
existing vphone-cli checkout.

Re-run `build.sh` after changing anything in `overlay/`, `edits/` or `excludes/`, or after moving
the vphone-cli checkout to another tag.
