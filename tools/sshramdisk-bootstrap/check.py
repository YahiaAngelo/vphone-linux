#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Validate a source-built or explicitly supplied arm64 iOS bootstrap."""

import hashlib
import plistlib
import struct
import sys
from pathlib import Path
from xml.parsers.expat import ExpatError

IDENTIFIER = b"org.vphone.sshramdisk-bootstrap"
ENTITLEMENTS = (
    "platform-application",
    "com.apple.private.usbdevice.setdescription",
    "com.apple.private.iowatchdog.user-access",
    "com.apple.security.network.server",
)


def der_item(data):
    """Read the bounded DER forms used by the bootstrap's boolean entitlements."""
    if len(data) < 2:
        raise ValueError("truncated DER entitlement")
    tag, length = data[:2]
    start = 2
    if length & 0x80:
        count = length & 0x7F
        if not 1 <= count <= 4 or len(data) < 2 + count:
            raise ValueError("invalid DER entitlement length")
        length = int.from_bytes(data[2 : 2 + count], "big")
        start += count
    if start + length > len(data):
        raise ValueError("DER entitlement exceeds its blob")
    return tag, data[start : start + length], data[start + length :]


def der_entitlements(blob):
    if len(blob) < 8 or struct.unpack_from(">I", blob)[0] != 0xFADE7172:
        raise ValueError("missing signed DER entitlements")
    tag, body, tail = der_item(blob[8:])
    if tag != 0x70 or tail:
        raise ValueError("unsupported DER entitlement container")
    tag, version, body = der_item(body)
    if tag != 2 or version != b"\x01":
        raise ValueError("unsupported DER entitlement version")
    tag, body, tail = der_item(body)
    if tag != 0xB0 or tail:
        raise ValueError("unsupported DER entitlement dictionary")
    values = {}
    while body:
        tag, entry, body = der_item(body)
        if tag != 0x30:
            raise ValueError("invalid DER entitlement entry")
        tag, key, entry = der_item(entry)
        if tag != 0x0C:
            raise ValueError("invalid DER entitlement key")
        key = key.decode("utf-8")
        tag, value, tail = der_item(entry)
        if tag != 1 or value not in (b"\0", b"\xff") or tail or key in values:
            raise ValueError("unsupported or duplicate DER boolean entitlement")
        values[key] = value == b"\xff"
    return values


def check(path):
    data = Path(path).read_bytes()
    if len(data) < 32:
        raise ValueError("truncated Mach-O")
    magic, cpu, _, kind, commands, command_bytes, _, _ = struct.unpack_from("<8I", data)
    if (magic, cpu, kind) != (0xFEEDFACF, 0x100000C, 2):
        raise ValueError("bootstrap must be a thin arm64 Mach-O executable")
    end = 32 + command_bytes
    if end > len(data) or commands > command_bytes // 8:
        raise ValueError("invalid Mach-O load commands")
    position = 32
    signature = None
    ios = False
    for _ in range(commands):
        if position + 8 > end:
            raise ValueError("truncated Mach-O command")
        command, size = struct.unpack_from("<II", data, position)
        if size < 8 or position + size > end:
            raise ValueError("invalid Mach-O command size")
        if command == 0x1D:
            if size != 16 or signature is not None:
                raise ValueError("invalid or duplicate code signature")
            signature = struct.unpack_from("<II", data, position + 8)
        if command == 0x32 and size >= 24:
            ios = struct.unpack_from("<I", data, position + 8)[0] == 2
        if command == 0x25 and size == 16:
            ios = True
        position += size
    if position != end or not ios or signature is None:
        raise ValueError(
            "bootstrap needs an iOS platform and embedded ad-hoc signature"
        )
    offset, size = signature
    if offset < end or offset + size > len(data):
        raise ValueError("invalid code signature bounds")
    signed = data[offset : offset + size]
    if len(signed) < 12:
        raise ValueError("truncated signature")
    magic, length, count = struct.unpack_from(">III", signed)
    if (
        magic != 0xFADE0CC0
        or not 12 <= length <= len(signed)
        or count > (length - 12) // 8
    ):
        raise ValueError("invalid signature superblob")
    blobs = {}
    for index in range(count):
        slot, start = struct.unpack_from(">II", signed, 12 + index * 8)
        if slot in blobs or start < 12 + count * 8 or start + 8 > length:
            raise ValueError("invalid signature slot")
        blob_length = struct.unpack_from(">I", signed, start + 4)[0]
        if blob_length < 8 or start + blob_length > length:
            raise ValueError("invalid signature blob bounds")
        blobs[slot] = signed[start : start + blob_length]
    if any(0x1000 <= slot <= 0x1005 for slot in blobs):
        raise ValueError("bootstrap must have a single primary CodeDirectory")
    entitlement_blob = blobs.get(5, b"")
    if (
        len(entitlement_blob) < 8
        or struct.unpack_from(">I", entitlement_blob)[0] != 0xFADE7171
    ):
        raise ValueError("missing signed XML entitlements")
    entitlements = plistlib.loads(entitlement_blob[8:])
    if not isinstance(entitlements, dict) or any(
        entitlements.get(key) is not True for key in ENTITLEMENTS
    ):
        raise ValueError(
            "missing bootstrap USB, watchdog, platform, or network entitlement"
        )
    if der_entitlements(blobs.get(7, b"")) != entitlements:
        raise ValueError("DER and XML entitlements disagree")
    if blobs.get(2) != struct.pack(">III", 0xFADE0C01, 12, 0):
        raise ValueError("bootstrap requires an empty ad-hoc RequirementSet")
    directory = blobs.get(0, b"")
    if len(directory) < 44:
        raise ValueError("missing primary CodeDirectory")
    magic, length, _, flags, hash_offset, ident_offset, special, slots, limit = (
        struct.unpack_from(">9I", directory)
    )
    hash_size, hash_type, _, page_shift = struct.unpack_from("4B", directory, 36)
    if magic != 0xFADE0C02 or length != len(directory) or not flags & 2:
        raise ValueError("bootstrap needs an ad-hoc CodeDirectory")
    digest = {1: hashlib.sha1, 2: hashlib.sha256, 3: hashlib.sha256}.get(hash_type)
    expected_size = {1: 20, 2: 32, 3: 20}.get(hash_type)
    if digest is None or hash_size != expected_size or not 12 <= page_shift <= 16:
        raise ValueError("unsupported code-signing digest or page size")
    if (
        not 44 <= ident_offset < len(directory)
        or directory[ident_offset:].split(b"\0", 1)[0] != IDENTIFIER
    ):
        raise ValueError("incorrect bootstrap signing identifier")
    page = 1 << page_shift
    if limit != offset or slots != (limit + page - 1) // page:
        raise ValueError("signature does not cover the executable")
    if (
        hash_offset < special * hash_size
        or hash_offset + slots * hash_size > len(directory)
        or special < 7
    ):
        raise ValueError("invalid CodeDirectory hash bounds")
    for index in range(slots):
        actual = digest(data[index * page : min((index + 1) * page, limit)]).digest()[
            :hash_size
        ]
        if (
            actual
            != directory[
                hash_offset + index * hash_size : hash_offset + (index + 1) * hash_size
            ]
        ):
            raise ValueError("executable page hash mismatch")
    for slot in range(1, special + 1):
        stored = directory[
            hash_offset - slot * hash_size : hash_offset - (slot - 1) * hash_size
        ]
        actual = (
            digest(blobs[slot]).digest()[:hash_size]
            if slot in blobs
            else bytes(hash_size)
        )
        if actual != stored:
            raise ValueError(f"special-slot {slot} signature mismatch")
    if any(special < slot < 0x1000 for slot in blobs):
        raise ValueError("unsigned special-slot blob")
    return hashlib.sha256(data).hexdigest()


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: check.py BOOTSTRAP")
    try:
        sha256 = check(sys.argv[1])
    except (
        OSError,
        ValueError,
        IndexError,
        struct.error,
        plistlib.InvalidFileException,
        ExpatError,
    ) as error:
        raise SystemExit(f"invalid SSH ramdisk bootstrap: {error}") from error
    print(
        f"SSH ramdisk bootstrap: arm64 iOS, signed code and entitlements verified, sha256={sha256}"
    )


if __name__ == "__main__":
    main()
