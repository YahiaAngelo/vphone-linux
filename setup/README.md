# vphone-setup

The two-step Linux setup, part of this checkout: **build everything, then pick a device and an iOS
version and create the VM.** The scripts build THIS checkout (VSETUP_SRC defaults to the repo root)
and keep all state in `~/vphone-setup-work/` plus one directory per VM.

```sh
# from the repo root:
# step 1 — dependencies + sources + all binaries (re-runnable, resumes)
./setup/setup.sh

# step 2 — interactive device + iOS version menus, then the full create flow
./setup/create-vm.sh
```

Non-interactive:

```sh
./setup/setup.sh -y
./setup/create-vm.sh --device "iPhone17,3" --ios 26.6.2 --scale 1
```

## Status: what is actually tested on Linux

**Verified pairings on Linux:**

| Device | iOS | cloudOS | Preset | State |
|---|---|---|---|---|
| `iPhone17,3` (iPhone 16 Pro) | **26.6.2** (23G90) | `26.4-23E5207q` | standard | end-to-end: home screen |
| `iPhone17,3` (iPhone 16 Pro) | **27.0.1** (24A446) | `26.4-23E5207q` | standard | end-to-end with create-vm.sh: home screen at 2x |
| `iPhone19,4` (iPhone Duo) | **27.1** (24A94425) | `26.4-23E5207q` | standard | home screen (keep at 3x) |

iOS 27 pairings need this repo's QEMU (it implements FEAT_CSSC — without it the
27.1 first boot crawls at a trap per instruction) and run `fw patch` under sudo
(the seal patcher mounts the restore ramdisk read-write). Everything else in
`setup/data/compatibility.json` is **verified on macOS hosts only and under test on
Linux**. Choosing one works — the menus label it "mac-tested -- under test", the
script warns and asks before continuing, and a first run may need manual
attention (extra patches, restore retries). iOS 18 pairings additionally need a
macOS kmutil (refused here).

## What it does

`setup.sh` (phases: `deps`, `sources`, `build`, `release`, `all`):

1. **deps** — installs the distro's packages (Fedora, Debian 13+ / Ubuntu 25.04+, Arch and
   Omarchy; the lists are `lib/packages.sh`), rustup, Swift (for vphone-cli's Linux tooling,
   through swiftly), rcodesign; sets `vm.max_map_count` and `/dev/vhost-vsock` where missing,
   and on Hyprland (Omarchy) offers the iPhone-window rule.
2. **sources** — this checkout (or a `--src` second one) and its three QEMU/GPU submodules.
3. **build** — reims-vgpu → QEMU (`-M vresearch101`) → vphone-cli's firmware
   tooling for Linux → the restore QEMU (`vusb-restore`) → the 32 KiB usbmuxd.
4. **release** — downloads vphone-cli's release bundle for the boot ROMs and
   guest resources. Everything is self-contained under
   `~/vphone-setup-work/` — it never touches any other checkout or
   QEMU instance on the host.

`create-vm.sh` reads `setup/data/compatibility.json` (mirrored from
[vphone-cli's compatibility.md](https://github.com/Lakr233/vphone-cli/blob/main/Documents/Guides/compatibility.md))
and menus down to one of the tested pairings — e.g.

```text
iPhone17,3 (iPhone 16 Pro)
  iOS 26.6.2 | build 23G90 | cloudOS 26.4-23E5207q | standard | linux-tested recommended
  iOS 27.0.1 | build 24A446 | cloudOS 26.4-23E5207q | standard | linux-tested mac-tested
iPhone18,2 (iPhone 17 Pro Max)
  iOS 27.0.1 | ... | extra patches: shared-region
iPhone11,6 (iPhone XS Max)
  iOS 18.7.2 | ... | needs-mac-builder (refused here with instructions)
```

Then it runs the whole Linux create flow (the GPU driver's one-time extraction from a stock
cloudOS restore, `fw prepare` + `fw patch`, the DFU
restore, the SSH-ramdisk CFW install, the snapshot flip, the first boot and
unlock) with one state file per VM, so re-runs resume from the step that
failed. QEMU is started exactly once (the "first boot" step) and never
killed by these scripts — stop the guest with
`tools/vphoned.sh POST /v1/rpc '{"method":"system.shutdown","params":{"force":true},"id":1'}`
or Ctrl-A X, never `pkill` (that would hit another agent's VM too).

Pairings `requiresMacBuilder` (iOS 18, kernel-first) are refused with the
macOS instructions instead of pretending they work on Linux alone.

## Uninstalling

`./setup/uninstall.sh` (`--dry-run` to preview, `-y` for no prompts, `--vms` to also delete
`~/vphone-setup-work`) removes Swift/swiftly, rcodesign, rustup if setup installed it, the build
output, swiftly's lines in your shell profile, and the system packages setup.sh recorded in
`~/.local/state/vphone-linux/packages.txt`, except ones another package still needs.

## Flags

| | |
|---|---|
| `--device ID` / `--ios V` | skip the menus |
| `--cloudos IPSW` | override the pairing's cloudOS image |
| `--name N` | VM name (default `vphone-<device>-<ios>`) |
| `--scale 1|2|3` | display scale (default 1x — 9× fewer pixels than 3x; iOS 27 does not go below 2x) |
| `--frida` | turn on vphone-cli's Frida kernel patches before the firmware is patched (cloudOS 26.4+; see [docs/FRIDA.md](../docs/FRIDA.md)) |
| `--dry-run` | print every command the pipeline would run, execute nothing |
| `--list` | print devices and their pairings |
| `--cid N` | the VM's vsock CID (default 3; pick another next to a running VM) |
| `GPU_DRIVER_BUNDLE=` | path to `AppleParavirtGPUMetalIOGPUFamily.bundle` |
| `IPSW_URL=`, `CLOUDOS_IPSW_URL=` | restore-image URLs instead of local files |

Pairings labeled **TESTED-ON-LINUX** in `--list` are fully supported here
(today: iPhone17,3 + iOS 26.6.2 and 27.0.1, iPhone19,4 + iOS 27.1); everything else is
**mac-tested -- under test**: selectable with a confirmation prompt.

## CI

`.github/workflows/validate.yml` validates **all** setup scripts on every
push/PR, and weekly for pairing drift:

- **lint** — `bash -n` + `shellcheck` on every script;
- **data** — `lib/json_query.py validate` (schema, missing ipsws, duplicate pairings);
- **smoke** — full `--dry-run` pipelines for the key pairings, plus an
  assertion that no QEMU process was started or killed and no `pkill`-style
  cleanup exists in any script;
- **compat-sync** (report-only) — diffs recorded pairings against upstream's
  compatibility.md so new tested combinations surface here before release.

Run the same checks locally: `setup/test/smoke.sh`.

## Isolation rules

- The build happens in this checkout; the VM bundles and the release tree live in the work directory
  (`VSETUP_SRC`/`VSETUP_RELEASE`/`VSETUP_DEVICES`, default
  `~/vphone-setup-work/…`). Override with `--src` / `--workdir`.
- No script here enumerates or signals processes; a separate QEMU instance on
  the host (e.g. a VM another agent boots) is untouched.
- Dry-run mode never runs QEMU, sudo, or the network.
