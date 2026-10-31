#if os(Linux)
import ArgumentParser
import Foundation
import Glibc
import FirmwarePatcher
import VPhoneArchiveKit
import VPhoneCoreKit
import VPhonePatchKit
import VPhoneSign

// vphone-linux: the host installer path for a VM booted into the SSH ramdisk.
//
// The macOS installer clones Disk.img, attaches it with diskutil and mounts the
// guest volumes with mount_apfs.  On Linux the sealed System cannot be mounted
// read-write on the host, so the ramdisk guest mounts the target volumes under
// /mnt1 (System), /mnt7 (xART) and /mnt6 (Preboot) and the host reaches them
// over sshfs.  The sshfs wrapper in tools/ runs sftp-server as a command
// because the SSHRD dropbear has no sftp subsystem.
//
// Everything below reuses the guest-half functions of the macOS path; only the
// volume plumbing and the host-only cryptex/AEA/sign steps still need their
// Linux replacements (they call the macOS tools today).
/// The vphone-linux checkout: $VPHONE_LINUX_ROOT, or the first directory above
/// this binary (it lives in linux-create/.build/...) that holds run-vphone.sh.
func vphoneLinuxRoot() -> String {
    if let root = ProcessInfo.processInfo.environment["VPHONE_LINUX_ROOT"], !root.isEmpty {
        return root
    }
    var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent()
    while dir.path != "/" {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("run-vphone.sh").path) {
            return dir.path
        }
        dir = dir.deletingLastPathComponent()
    }
    return FileManager.default.currentDirectoryPath
}

/// rcodesign: $VPHONE_RCODESIGN, then PATH, then ~/.cargo/bin of the user who ran
/// sudo (cargo installs it there), then root's.
func rcodesignPath() -> String {
    let env = ProcessInfo.processInfo.environment
    var candidates = [env["VPHONE_RCODESIGN"]].compactMap { $0 }
    for dir in (env["PATH"] ?? "").split(separator: ":") {
        candidates.append("\(dir)/rcodesign")
    }
    if let user = env["SUDO_USER"], let pw = getpwnam(user), let home = pw.pointee.pw_dir {
        candidates.append(String(cString: home) + "/.cargo/bin/rcodesign")
    }
    if let home = env["HOME"] { candidates.append(home + "/.cargo/bin/rcodesign") }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "rcodesign"
}

extension VPhoneCustomFirmwareInstaller {
    func runLinuxGuest(
        bundleDirectory: VPhoneConfinedDirectory,
        bundlePath: String,
        restore: VPhoneConfinedDirectory?,
        plan: VPhoneVirtualMachinePatchPlan?,
        receipt: VPhoneVirtualMachinePatchReceipt?,
        receiptGuest: Set<String>?,
        receiptKernel: Set<String>?,
        priorFallback: Set<String>,
        invokingUser: VPhoneInvokingUser?,
        callerUID: uid_t?,
    ) throws {
        _ = bundlePath
        _ = receipt
        let work = try makeWorkDirectory()
        defer { try? removeWorkDirectory(work) }

        let system = work.file("system")
        let xart = work.file("xart")
        let preboot = work.file("preboot")
        _ = try work.directory.directory("system", create: true, mode: 0o700)
        _ = try work.directory.directory("xart", create: true, mode: 0o700)
        _ = try work.directory.directory("preboot", create: true, mode: 0o700)
        // Register the unmounts before mounting anything: if the second or third
        // mount throws, a defer declared afterwards would never run and would
        // leave root-owned sshfs mounts behind for the next attempt.
        defer {
            // Unconditional: fusermount3 fails harmlessly when the path is not a
            // mountpoint, and stat() on a dead FUSE mount would block.
            for path in [preboot.path, xart.path, system.path] {
                _ = try? tool("/usr/bin/fusermount3", ["-u", path], quiet: true)
            }
        }
        // Where the ramdisk mounted each volume. The guest's mount_filesystems mounts by
        // role (System /mnt1, Preboot /mnt6, xART /mnt7 on the 2026-10-24 OpenAVB restore),
        // and the device numbers differ between restores, so they can be overridden.
        let env = ProcessInfo.processInfo.environment
        try mountRemote(system, guestPath: env["VPHONE_GUEST_SYSTEM"] ?? "/mnt1")
        try mountRemote(xart, guestPath: env["VPHONE_GUEST_XART"] ?? "/mnt7")
        try mountRemote(preboot, guestPath: env["VPHONE_GUEST_PREBOOT"] ?? "/mnt6")

        print("[*] opening mounted volumes")
        let systemRoot = try work.directory.mountedVolume("system")
        print("[+] system volume open")
        let xartRoot = try work.directory.mountedVolume("xart")
        print("[+] xart volume open")
        let wasInstalled = (try? systemRoot.exists("System/Library/xpc/launchd.plist.bak")) ?? false
        print("[*] wasInstalled=\(wasInstalled), mode=\(mode)")
        let priorGuest = receiptGuest ?? (wasInstalled ? priorFallback : [])
        let device = configuredGuestDevice(in: bundleDirectory) ?? guestDevice(of: restore)
        var liveGuest = Set<String>()
        switch mode {
        case .kernelUpdate:
            return
        case .full:
            guard let restore else {
                throw ValidationError("A full CFW install needs a prepared restore tree.")
            }
            liveGuest = try applyGuestPatches(
                guestDevice: device,
                system: systemRoot,
                xart: xartRoot,
                restore: restore,
                work: work,
                owner: callerUID,
                otaUserland: nil,
                homePodDisplay: nil,
                plan: plan,
                priorGuest: priorGuest,
                kernelPatches: receiptKernel,
                environmentOnly: false,
            )
        case .environmentOnly:
            guard wasInstalled else {
                throw ValidationError(
                    "This VM has no CFW install to update. Run `vphone-cli cfw install` first.",
                )
            }
            // xART too: the SSH ramdisk step gave the gigalocker the UUID name its own seputil
            // asks for, and the installed system's seputil looks for AA.gl again.
            liveGuest = try applyGuestPatches(
                guestDevice: device,
                system: systemRoot,
                xart: xartRoot,
                restore: nil,
                work: work,
                owner: nil,
                otaUserland: nil,
                homePodDisplay: nil,
                plan: plan,
                priorGuest: priorGuest,
                kernelPatches: receiptKernel,
                environmentOnly: true,
            )
        }

        let buildVersion = plan?.parameters[FirmwareGuestSystemPatchSet.buildVersionParameter]
        let boardDeviceTree = try stageBoardDeviceTree(
            in: bundleDirectory,
            work: work,
            device: device,
        )
        liveGuest.formUnion(try patchPreboot(
            volumes: [
                ["DeviceIdentifier": "disk1s1", "Roles": ["System"]],
                ["DeviceIdentifier": "disk1s5", "Roles": ["Preboot"]],
                ["DeviceIdentifier": "disk1s4", "Roles": ["xART"]],
            ],
            work: work,
            plan: plan,
            priorGuest: priorGuest,
            guestDevice: device,
            includeIdentity: mode == .full
                || plan?.isEnabled(FirmwareGuestIdentityPatchSet.prebootDeviceTreeIdentity) == true,
            buildVersion: buildVersion,
            boardDeviceTree: boardDeviceTree,
        ))

        var notApplicableGuest = Set<String>()
        if !device.presentsBoard {
            notApplicableGuest.insert(FirmwareGuestSystemPatchSet.prebootBoardAudio)
        }
        // As the macOS path's list (VPhoneCustomFirmwareInstaller.swift).
        if device.family != .iPhone {
            notApplicableGuest.insert(FirmwareGuestSystemPatchSet.prebootIPhoneProduct)
        }
        if device.family != .homePod {
            notApplicableGuest.insert(FirmwareGuestSystemPatchSet.homePodAudioProduct)
        }
        if !Self.isFoldable(device) {
            notApplicableGuest.insert(FirmwareGuestSystemPatchSet.prebootFoldableVMSubtype)
            notApplicableGuest.insert(FirmwareGuestSystemPatchSet.prebootFoldableProductId)
            notApplicableGuest.insert(FirmwareGuestSystemPatchSet.prebootFoldableDisplays)
            notApplicableGuest.insert(FirmwareGuestSystemPatchSet.hinge)
            notApplicableGuest.insert(FirmwareGuestSystemPatchSet.foldGuard)
        }
        if Self.isFoldable(device) {
            // The display-node strip leaves a foldable's panels.
            notApplicableGuest.insert(FirmwareGuestSystemPatchSet.prebootDisplayNodes)
        }
        if !device.usesTVOS {
            notApplicableGuest.insert(FirmwareGuestSystemPatchSet.tvTPRO)
        }
        if buildVersion?.isEmpty ?? true {
            notApplicableGuest.insert("system-systemversion-cfw-build_version")
        }
        notApplicableGuest.subtract(liveGuest)

        try installSignedDaemonCopy(
            in: bundleDirectory,
            work: work,
            owner: invokingUser.map { ($0.uid, $0.gid) },
        )
        recordGuestReceipt(
            live: liveGuest,
            notApplicable: notApplicableGuest,
            in: bundleDirectory,
            owner: invokingUser.map { ($0.uid, $0.gid) },
        )
        print("[+] Linux guest install complete")
    }

    /// Mount a guest path on the host over sshfs.  The wrapper drops the
    /// unsupported `-s sftp` request and runs /usr/libexec/sftp-server instead.
    ///
    /// sshfs -f stays in the foreground, so Process.run() returns without
    /// waiting; poll mountinfo for the kernel to publish the mount.  (Waiting
    /// on sshfs itself deadlocks: its daemon child never exits.)
    ///
    /// The guest is emulated and its dropbear is single-connection slow, so a
    /// mount that takes 0.1 s on localhost can take tens of seconds here.  We
    /// deliberately do *not* kill the wrapper on timeout: a late mount is still
    /// usable, and killing the shell orphans sshfs in a busy FUSE state.
    private func mountRemote(_ hostPath: URL, guestPath: String) throws {
        // tools/ssh-ramdisk.sh creates this; the installer must not depend on it
        // having been run first.
        let askpass = "/tmp/vphone-askpass.sh"
        if !FileManager.default.fileExists(atPath: askpass) {
            try? "#!/bin/sh\necho alpine\n".write(toFile: askpass, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass)
        }
        setenv("SSH_ASKPASS", askpass, 1)
        setenv("SSH_ASKPASS_REQUIRE", "force", 1)
        setenv("DISPLAY", ":0", 1)
        // Launch through a shell, backgrounded, like the manual command that
        // does mount. Direct Process execution of sshfs has not mounted here.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let script = "printf 'alpine\\n' | /usr/bin/sshfs -f 'root@vphone:\(guestPath)' '\(hostPath.path)' "
            + "-o ssh_command='\(vphoneLinuxRoot())/tools/sshfs-remote-sftp.sh' "
            + "-o reconnect -o ServerAliveInterval=15 -o password_stdin &"
        process.arguments = ["-c", script]
        // Inherit stderr: piping it from a daemonizing sshfs can block forever.
        print("[*] sshfs \(guestPath) -> \(hostPath.path)")
        try process.run()
        let start = Date()
        var announced = 0
        var attempts = 0
        while attempts < 600 {
            if Self.isMounted(hostPath.path) {
                let elapsed = Date().timeIntervalSince(start)
                print(String(format: "[+] mounted %@ after %.1fs", hostPath.path, elapsed))
                return
            }
            // Keep the user informed during the slow first mount (build/patches
            // otherwise look hung for up to a minute).
            if attempts > 0, attempts % 50 == 0, announced < 10 {
                announced += 1
                print(String(format: "[.] still waiting for %@ -> %@ (%.0fs)", guestPath, hostPath.path, Date().timeIntervalSince(start)))
            }
            usleep(100_000)
            attempts += 1
        }
        let table = (try? String(contentsOfFile: "/proc/self/mountinfo", encoding: .utf8)) ?? ""
        let matches = table.split(separator: "\n").filter { $0.contains(hostPath.path) }
        print("[!] mountinfo rows for \(hostPath.path): \(matches)")
        throw ValidationError("""
            sshfs did not mount \(guestPath) within 60s. Check the guest with \
            `tools/ssh-ramdisk.sh 'ls /mnt1 | head'` and look for stray mounts \
            (`findmnt -l | grep vphone-cfw`).
            """)
    }

    /// Two independent checks.  The mountinfo row is what the installer started
    /// with, but parsing that procfs table has proved unreliable here (it is
    /// re-read while it grows and it did not report a mount that `findmnt` showed
    /// from another shell).  `st_dev` always reflects the kernel's mount tree: a
    /// mountpoint's inode lives on the mounted filesystem, not on its parent's.
    private static func isMounted(_ path: String) -> Bool {
        if let table = try? String(contentsOfFile: "/proc/self/mountinfo", encoding: .utf8),
           table.split(separator: "\n").contains(where: { line in
               line.split(separator: " ").dropFirst(4).first.map(String.init) == path
           }) {
            return true
        }
        var mounted = stat()
        guard stat(path, &mounted) == 0 else { return false }
        var parent = stat()
        let parentPath = (path as NSString).deletingLastPathComponent
        guard stat(parentPath, &parent) == 0 else { return false }
        return mounted.st_dev != parent.st_dev
    }
}
#endif
