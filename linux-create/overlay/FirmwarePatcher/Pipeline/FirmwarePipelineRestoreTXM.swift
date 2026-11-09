// FirmwarePipelineRestoreTXM.swift — patch the restore ramdisk's release TXM.
//
// vphone-linux: the restore boot chain loads `Firmware/txm.iphoneos.release.im4p`
// (manifest component `Ap,RestoreTrustedExecutionMonitor`), a separate image
// from the guest's research TXM. Its trustcache binary-search /
// selector24 hash-flags call must return success for the ramdisk's ad-hoc
// signed binaries; the JB TXM patch set is for the research image and is not
// applied here. The old ramdisk_send.sh flow calls this the "base TXM patch (1)".

import Foundation
import Img4tool
import VPhonePatchKit

extension FirmwarePipeline {
    /// Apply the base TXM trustcache bypass to the release (restore) TXM at `url`.
    /// Returns the number of patches written (0 when the site is already patched).
    @discardableResult
    public func patchRestoreTXMFile(at url: URL) throws -> Int {
        let image = try IM4PHandler.load(contentsOf: url)
        let patcher = TXMPatcher(data: image.payload, verbose: verbose)
        _ = try patcher.findAll()
        let count = try patcher.apply()
        guard count > 0 else { return 0 }
        try IM4PHandler.save(patchedData: patcher.patchedData, originalIM4P: image.im4p, to: url)
        return count
    }

    /// Admit the SSH ramdisk's signatures through native classification.
    /// Requires pristine restore firmware; leaves the policy pre-check and
    /// executable-mapping restrictions intact. No other dev patches apply.
    @discardableResult
    public func patchRestoreTXMPrecheckFile(at url: URL) throws -> Int {
        let image = try IM4PHandler.load(contentsOf: url)
        let patcher = TXMDevPatcher(data: image.payload, verbose: verbose)
        do {
            try RestoreTXMNativePrecheck.validate(image.payload)
            try patcher.patchExecutableRemap()
            patcher.patchSelector24ForcePass()
            let required: Set<String> = [
                "txm-boot-trustcache_bypass",
                "txm-cfw-executable_remap.cms",
                "txm-cfw-executable_remap.adhoc",
                "txm-cfw-executable_remap.ldid",
                "txm-cfw-executable_remap.library",
                "txm-boot-selector24_bypass.mov",
                "txm-boot-selector24_bypass.b",
            ]
            guard patcher.patches.count == required.count,
                  Set(patcher.patches.map(\.patchID)) == required else {
                throw PatcherError.patchSiteNotFound(
                    "restore TXM requires complete native-classification and selector-24 patches",
                )
            }
        } catch {
            throw PatcherError.patchSiteNotFound(
                "restore TXM \(RestoreTXMNativePrecheck.buildLabel(in: image.payload)) is unsupported: \(error)",
            )
        }
        let count = try patcher.apply()
        try IM4PHandler.save(patchedData: patcher.patchedData, originalIM4P: image.im4p, to: url)
        return count
    }
}
