# Frida

vphone-cli has four kernel patches for [Frida](https://frida.re), mainly so that Stalker (Frida's code
tracer) works in the guest:

| Patch | What it relaxes |
|---|---|
| `kernel-exp-frida_thread_set_state_entitlement_flag` | setting another thread's state |
| `kernel-exp-frida_vm_map_delete_immutable_code` | unmapping code pages marked immutable |
| `kernel-exp-frida_tpro_off` | TPRO (read-only page protection) |
| `kernel-exp-frida_syscall_filter_off` | the syscall filter |

Every preset declares them, but `standard` (what `setup/create-vm.sh` uses) leaves them off because
they widen what any process in the guest may do. vphone-cli applies them on cloudOS 26.4 and newer
only; the Linux-tested pairings use 26.4.

## Turn them on for a new VM

```sh
./setup/create-vm.sh --frida                                   # with the menus
./setup/create-vm.sh --frida --device "iPhone17,3" --ios 26.6.2
```

`--frida` adds a `frida` step before the firmware is patched. It runs:

```sh
vphone-cli fw set-patches -l <library> <vm> \
  --allow kernel-exp-frida_thread_set_state_entitlement_flag \
  --allow kernel-exp-frida_vm_map_delete_immutable_code \
  --allow kernel-exp-frida_tpro_off --allow kernel-exp-frida_syscall_filter_off
```

This records the choice in the VM's `PatchSelection.plist`, and `fw patch` reads it. Nothing needs
rebuilding: `fw set-patches` is part of the Linux build of vphone-cli (`linux-create/vphone-cli`).

## An existing VM

Its kernel was patched when the VM was created, so the choice alone changes nothing. Run the same
`fw set-patches` command on it (`linux-create/vphone-cli fw set-patches -l ~/vphone-setup-work/devices
<vm> --allow …`). On an installed VM it then lists which patches differ from what the guest has, and
the vphone-cli steps that install each one. Those steps have not been tried on Linux yet; creating a
new VM with `--frida` is the tested path.

## What --frida does not do

The patches only make the kernel allow what Frida does. Two parts are still open on Linux:

- **Installing `frida-server`.** On a Mac, vphone-cli's app installs a package manager
  (*Apps > Install Bootstrap…*) and frida-server comes from it. That menu is part of the macOS app.
- **Connecting to it.** On a Mac, Frida connects over the VM's network with a port forward
  (`vm config --forward`). Networking is untested in this QEMU setup; the channel that works today is
  vsock (vphoned, port 1339), which Frida does not speak without a relay.

Expect instrumentation to be slow: the guest already runs under TCG emulation.
