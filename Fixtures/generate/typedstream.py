"""A minimal writer for the NSArchiver "typedstream" blobs Messages stores in `message.attributedBody`
(Stage 0, issue #14).

Written from the format's public description (the NeXT/Apple typedstream layout as described in the
research on #5), not from any GPL implementation. It produces the common shape readers rely on:

    \\x04\\x0bstreamtyped            version 4, signature
    \\x81\\xe8\\x03                   system version 1000
    \\x84\\x01@                      type encoding "@" (an object follows)
    \\x84\\x84\\x84 NSAttributedString\\x00 \\x84\\x84 NSObject\\x00 \\x85   class chain, ending in nil
    \\x92\\x84\\x84\\x84 NSString\\x01 \\x94 \\x84\\x01+   the string object, type "+" (counted bytes)
    <length> <UTF-8 bytes>                          length: one byte below 0x80, else \\x81 + uint16 LE
    \\x86                                     end of the string object
    ...a minimal attribute run...
    \\x86                                     end of the attributed string

Profiles built with it are marked "hypothetical" until checked against a real chat.db (#19).
"""

from __future__ import annotations

import struct

HEADER = b"\x04\x0bstreamtyped\x81\xe8\x03"


def _class_name(name: str, version: int) -> bytes:
    raw = name.encode("ascii")
    return bytes([len(raw)]) + raw + bytes([version])


def _length(count: int) -> bytes:
    if count < 0x80:
        return bytes([count])
    if count <= 0xFFFF:
        return b"\x81" + struct.pack("<H", count)
    return b"\x82" + struct.pack("<I", count)


def attributed_body(text: str) -> bytes:
    """An attributedBody blob whose string is `text`."""
    return attributed_body_from_bytes(text.encode("utf-8"), characters=len(text))


def attributed_body_from_bytes(raw: bytes, characters: int) -> bytes:
    """The same blob around arbitrary bytes, e.g. invalid UTF-8 for edge-case fixtures."""
    blob = bytearray(HEADER)
    blob += b"\x84\x01@"
    blob += b"\x84\x84\x84" + _class_name("NSAttributedString", 0)
    blob += b"\x84\x84" + _class_name("NSObject", 0) + b"\x85"
    blob += b"\x92\x84\x84\x84" + _class_name("NSString", 1) + b"\x94\x84\x01+"
    blob += _length(len(raw)) + raw
    blob += b"\x86"
    # One attribute run covering the whole string: [range start, length] then a small dictionary.
    blob += b"\x84\x02iI\x01" + _length(characters)
    blob += b"\x92\x84\x84\x84" + _class_name("NSDictionary", 0) + b"\x94\x84\x01i\x01"
    blob += b"\x92\x84\x98\x98" + b"\x1d__kIMMessagePartAttributeName" + b"\x86"
    blob += b"\x92\x84\x84\x84" + _class_name("NSNumber", 0) + b"\x84\x84\x07NSValue\x00\x94\x84\x01*\x84\x99\x99\x00\x86"
    blob += b"\x86"
    return bytes(blob)


def corrupt() -> bytes:
    """A blob with a valid header but no decodable string (edge case 3)."""
    return HEADER + b"\x84\x01@garbage\xff\xfe"


def extract_text(blob: bytes) -> str:
    """Reference decoder for tests: the string a reader should recover (replacement chars for bad UTF-8)."""
    marker = blob.index(b"NSString")
    position = blob.index(b"\x84\x01+", marker) + 3
    first = blob[position]
    if first < 0x80:
        count, position = first, position + 1
    elif first == 0x81:
        count, position = struct.unpack("<H", blob[position + 1 : position + 3])[0], position + 3
    else:
        count, position = struct.unpack("<I", blob[position + 1 : position + 5])[0], position + 5
    return blob[position : position + count].decode("utf-8", errors="replace")
