#!/usr/bin/env python3
"""Resolve a pairing's download URLs from vphone-cli's fw catalog.

Usage: get-firmware.py <vphone-cli> <DEVICE> <OSVERSION> [CLOUDOS_LABEL]

Prints one line per image as:  <name>\t<url>\t<size, where known>
  name = the file to cache it as (the .ipsw basename, or a stable
         cloudOS-<build>.ipsw built from the catalog's own cloudOS name)

CLOUDOS_LABEL (e.g. 26.6-23G71) selects the release's OWn cloudOS instead
of the recommended one when the label names a different build. Exit 1 when
the pairing is not in the catalog."""
import json
import re
import subprocess
import sys

# Restores the catalog does not list (vphone-cli's catalog is iPhone17,3's alone): the device and
# iOS version -> the restore's name, URL and size. Their cloudOS is the catalog's for the same
# iOS major (cloudOS images serve every device).
KNOWN_IOS = {
    ("iPhone19,4", "27.1"): {
        "name": "iOS 27.1",
        "url": "https://updates.cdn-apple.com/2026FallFCS/3f41a447-d8a6-48ae-83ae-056a64f57fd4/"
               "iPhone19,4_27.1_24A94425_Restore.ipsw",
        "size": 12724731538,
    },
}


def catalog(vc, device):
    raw = subprocess.run([vc, "fw", "catalog", "--json", "--device", device],
                         capture_output=True, text=True, timeout=180, check=True).stdout
    import json as _j
    data = _j.loads(raw[raw.index("{"):])
    import sys as _s
    if (data.get("device") and data["device"] != device and data.get("pairings")
            and not any(k[0] == device for k in KNOWN_IOS)):
        print(f"note: the fw catalog lists {data['device']}'s restores only; "
              f"resolving {device} from that list", file=_s.stderr)
    return data.get("pairings")


def main() -> int:
    vc, device, ver = sys.argv[1], sys.argv[2], sys.argv[3]
    cloudos_label = sys.argv[4] if len(sys.argv) > 4 else ""
    data = catalog(vc, device)   # the list of pairings for the device
    if not data:
        return 1
    pairings = data

    ios = cloud = None
    for it in pairings:
        name = (it.get("ios") or {}).get("name", "")
        m = re.match(r"^(?:iOS|iPadOS|watchOS|tvOS|HomePod Software) +(\S+)$", name)
        if m and m.group(1) == ver:
            ios = it["ios"]
            rec = it.get("recommendedCloudOS") or {}
            mat = it.get("matchingCloudOS") or {}
            label_build = cloudos_label.rsplit("-", 1)[-1]
            cloud = mat if label_build and label_build in mat.get("name", "") else rec

    # A restore the catalog does not list: its known URL, and the cloudOS of the catalog's newest
    # pairing of the same iOS major (the one whose cloudOS build the label names, if any).
    if not ios and (device, ver) in KNOWN_IOS:
        ios = KNOWN_IOS[(device, ver)]
        major = ver.split(".")[0]
        label_build = cloudos_label.rsplit("-", 1)[-1]
        for it in pairings:
            name = (it.get("ios") or {}).get("name", "")
            if not re.match(rf"^iOS {major}(\.|$| )", name):
                continue
            rec = it.get("recommendedCloudOS") or {}
            mat = it.get("matchingCloudOS") or {}
            cloud = mat if label_build and label_build in mat.get("name", "") else rec

    if not ios or not cloud or not cloud.get("url"):
        print(f"no catalog pairing for {device} {ver} "
              f"(cloudOS {cloudos_label or 'recommended'})", file=sys.stderr)
        return 1

    out = []
    for key, item in (("ios", ios), ("cloudos", cloud)):
        size = item.get("size") or ""
        url = item["url"]
        base = url.rsplit("/", 1)[-1]
        if re.match(r"^(iPhone|iPad|Watch|AppleTV|Audio)", base):
            fname = base
        else:  # cloudOS URLs are opaque CDN hashes
            build = re.search(r"\(([0-9A-Za-z]+)\)", item["name"])
            plain = re.match(r"cloudOS ([0-9A-Za-zb.x]+)$", item["name"].strip())
            if build:
                fname = "cloudOS-%s.ipsw" % build.group(1)
            elif plain:
                fname = "cloudOS-%s.ipsw" % plain.group(1)
            else:
                fname = "cloudOS-unknown-%d.ipsw" % (abs(hash(url)) % 10**8)
        out.append(f"{fname}\t{url}\t{size}")
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
