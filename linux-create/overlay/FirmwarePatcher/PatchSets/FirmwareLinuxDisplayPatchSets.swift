import Foundation
import VPhonePatchKit

// Extend the selected CLI's manifests instead of replacing their evolving declarations.
extension FirmwareDeviceTreePatchSet {
    public static let manifest: VPhonePatchSetManifest = {
        var manifest = linuxSourceManifest
        manifest.patches.append(
            VPhonePatchDeclaration(
                identifier: "devicetree-cfw-product_display_nodes",
                title: "Secondary display nodes",
                summary:
                    "Removes the board's second and further display nodes. The platform presents one paravirtual display; a 27 display stack that binds a panel the VM does not have composites into a framebuffer nothing scans out.",
                target: .firmware(.deviceTree),
            ))
        return manifest
    }()
}

extension FirmwareGuestSystemPatchSet {
    public static let prebootDisplayNodes = "preboot-cfw-devicetree_display_nodes"

    public static let manifest: VPhonePatchSetManifest = {
        var manifest = linuxSourceManifest
        manifest.patches.append(
            VPhonePatchDeclaration(
                identifier: prebootDisplayNodes,
                title: "Secondary display nodes",
                summary: """
                    Removes the board's second and further display nodes from a guest's restored \
                    Preboot device tree, as fw patch now does. The platform presents one paravirtual \
                    display; a 27 display stack that binds a panel the VM does not have composites \
                    into a framebuffer nothing scans out, and the host window stays black.
                    """,
                target: .prebootDeviceTree,
            ))
        return manifest
    }()

    public static let prebootRepairs: [String: String] = {
        var repairs = linuxSourcePrebootRepairs
        repairs["devicetree-cfw-product_display_nodes"] = prebootDisplayNodes
        return repairs
    }()
}
