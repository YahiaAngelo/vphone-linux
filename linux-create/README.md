# linux-create

vphone-cli's firmware tooling (`fw prepare`, `fw patch`, `restore`, `cfw install`, `sign`, ...) built
for Linux, so the VM can be created with no Mac. The steps are in
[docs/CREATE-ON-LINUX.md](../docs/CREATE-ON-LINUX.md).

vphone-cli's own files are not copied or changed here. `sync-sources.sh` links them from a vphone-cli
checkout (`VPHONE_CLI`, default `../vphone-cli`; tested with tag `2.14.2`) into `Sources/`, minus the
files listed in `excludes/`, plus:

- `Shims/`: Linux stand-ins for Apple modules (Darwin, CryptoKit, Compression, MachO,
  AppleArchive, CommonCrypto, ...);
- `overlay/`: whole-file replacements and Linux-only files (the Linux `cfw install` path, the restore
  bridge, URLSession workarounds, `fw snapshot-flip`);
- `edits/`: one-line sed edits, one `path<TAB>expression` per line.
- `Vendor/Img4tool/`: libimg4-spm 0.1.1 (the version vphone-cli pins) adapted for Linux; see its README.

```sh
./build.sh                 # clone vphone-cli, install Swift if missing, sync-sources, build Release
./vphone-cli fw prepare …  # run the built Release tool; sudo ./vphone-cli … for root steps
# the binary: .build/out/out/Products/Release-linux-$(uname -m)/vphone-cli
```

`build.sh` uses the Swift version in `.swift-version` (6.4.1). If it's missing, the script installs it
with swiftly (Arch and other unsupported distros use swiftly's `ubi9` platform) and runs it by its full
path, so you don't need to source swiftly's `env.sh` and its `clang`/`lld` stay off your PATH. Extra
arguments go to `swift build`; use `./build.sh -c debug` to build the Debug product explicitly.
`VPHONE_CLI=DIR` builds against an existing vphone-cli checkout. The wrapper prefers Release and
warns before using an existing Debug product when Release is absent. It does not build or install
Swift during an invocation. If neither product exists, run `./build.sh --configuration release`.
To run Debug when both products exist, use its `.build/out/out/Products/Debug-linux-$(uname -m)/vphone-cli` path.

`VPHONE_CLI_REPO` selects the source repository and `VPHONE_CLI_REF` selects its tag, branch or full
commit. They default to the upstream repository and `VPHONE_CLI_VERSION` (`2.14.2`).
`VPHONE_CLI_PUBLIC` selects the public guest-resource release independently.

The managed source directory is `../cpu-tree/vphone-cli-$VPHONE_CLI_VERSION`. Changing the repository
or ref does not select a different directory. If that checkout already exists, clone the desired
source into a new directory and use `VPHONE_CLI` instead. From `linux-create/`, replace the example
repository URL and full commit below with your selection:

```sh
git clone --no-checkout 'https://github.com/example/vphone-cli.git' '../vphone-cli-custom' &&
  git -C '../vphone-cli-custom' checkout --detach '0123456789abcdef0123456789abcdef01234567' &&
  VPHONE_CLI='../vphone-cli-custom' ./build.sh
```

Choose a new directory for each repository/ref. The commands stop if cloning or checkout fails, so
an existing source checkout is not changed by a failed clone.

Managed source checkouts must have the selected origin and commit and no local changes. Origin
comparison ignores a trailing `.git` and `/`. A mismatch stops the build and preserves the checkout.
An already fetched full commit or a locally resolved tag can be rebuilt without contacting its remote.
Fetching a missing ref does not make an existing full clone shallow.

`VPHONE_CLI=DIR` instead uses that existing source directory as supplied, including a fork or local
edits. Setup and `build.sh` skip repository, ref and cleanliness checks for this explicit override.
Neither mode resets an existing checkout or replaces its files.

Re-run `build.sh` after changing anything in `overlay/`, `edits/` or `excludes/`, or after moving
the vphone-cli checkout to another tag.

Patch-set manifests come from that selected CLI checkout. The sync edits expose their original
values, and `FirmwareLinuxDisplayPatchSets.swift` adds the Linux secondary-display declarations
and repair mapping. This keeps new upstream catalog references and manifest members together
without replacing the selected CLI's declarations with an older copy.

Linux CFW connections use the selected bundle's `config.plist` machine identifier to set
`VPHONE_ECID` for each SSHFS connection. A missing identity or a conflicting `VPHONE_ECID`
override is refused before any volume is mounted. This requires the connector's strict ECID
selection: it must reject an absent or ambiguous match rather than try another attached device.
`VPHONE_GUEST_SYSTEM`, `VPHONE_GUEST_XART`, and `VPHONE_GUEST_PREBOOT` select absolute guest
mount paths, passed as literal arguments. Askpass helpers are private to each run.

## Cache publication and recovery

This transaction covers iOS and iPadOS cache families. Linux tvOS CFW stops before mounting or changing guest volumes: its standalone `usr/lib/dyld` and cached dyld form a boot-critical pair, and both need one recoverable transaction. Cache-only rollback also refuses plain-arm64 tvOS targets. This does not affect kernel-only updates.

Reserve four times the total size of the selected cache family and its existing undo log plus 1 GiB on the `--work-parent` filesystem. An optional pristine seed needs five times the family size plus 1 GiB. The installer checks this budget before copying the OS cryptex into the guest and again before local cache staging. Firmware images and other CFW work need additional space. If only the optional seed does not fit, the installer uses the guest as its staging source.

Cache publication keeps verified `before/` and `after/` copies in a private host work directory. It creates and synchronizes `.vphone-dsc-pending.json` before the first guest cache write. Ordinary boot refuses any pending entry. Once the complete family is verified and guest `sync` succeeds, the cache journal is cleared. The later CFW patch receipt still requires the rest of the installer to succeed. A pre-write failure removes its scratch directory. A failed publication retains the directory named by its journal.

To recover an interrupted publication, stop the failed CFW command and repeat [the SSH ramdisk procedure](../docs/CREATE-ON-LINUX.md#4-boot-the-ssh-ramdisk) for the same VM. `tools/dfu-up.sh` can start this repair path while a journal remains. The launcher requires `auto-boot=false` preparation to succeed before permitting that recovery boot. Once the ramdisk has mounted its filesystems:

```sh
sudo linux-create/vphone-cli cfw recover-cache -l vms myphone --work-parent /var/tmp
```

Recovery checks the selected guest ECID against the publisher's journal before contacting the guest, then checks it again before writes. It also verifies the VM and disk identity, the private recovery copies, and the current cache bytes before restoring the original family. Cache files keep their existing inodes. The original undo log is restored, or a new partial undo log is removed. Guest sync must succeed before the boot fence is removed. A failed recovery keeps the journal and can be retried. A changed ECID, replaced disk, symlink, changed copy, or unrelated guest bytes cause recovery to stop without clearing the fence.

Version 2 journals bind the publisher's normalized ECID and immutable recovery plan, and hold a publisher lock while cache writes or recovery run. A complete journal is synchronized before an atomic, exclusive publication, so a torn journal write cannot strand a boot fence. Version 1 journals predate the lock, ECID binding, and plan digest. Before using `--legacy-journal`, confirm that the original command has exited and the selected bundle still contains that command's original guest ECID. The remaining identity, copy, and guest-byte checks still apply. Do not remove a pending journal manually.

Recovery restores only the cache transaction. Rerun the interrupted `cfw install` or `cfw update-environment` command before treating the CFW installation as complete. Neither rollback nor cache publication writes a successful whole-installer receipt.

To run the cache suite without the restore stack's native dependencies:

```sh
cd linux-create
VPHONE_CLI=/path/to/vphone-cli ./sync-sources.sh
./test-staged-cache.sh
```

The harness compiles the production confinement, audit, publication, and recovery files with the existing cache suite. It uses Swift 6.4.1 and the same Crypto shim as the full package. It covers injected write, sync, ownership, and recovery failures; it does not boot a guest. The full `swift test --filter VPhoneStagedDyldCacheTests` also compiles the CLI integration and requires the native dependency prefix from `build.sh`.

## Guest-free transport checks

Guest-free transport checks need Swift 6.4.1, Python 3.12 or later with `uv`, OpenSSH,
and the FUSE 3 userspace library:

```sh
uv run linux-create/tests/test_guest_connection.py  # SWIFTC may select a compiler by absolute path
uv run linux-create/tests/test_ssh_wrappers.py
```

These checks compile the installer's connection helper and run the wrappers against local
stubs. The copied SSHFS wrapper substitutes only its absolute SSH executable with an owned
stub; the production wrapper keeps `/usr/bin/ssh`. The connection check also passes a literal
connector path through the real FUSE option parser and OpenSSH to a local stub that exits
without network or USB access. These checks do not create mounts or verify a guest installation.
