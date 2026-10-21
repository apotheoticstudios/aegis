"""Recovers the plain text from a Messages `attributedBody` blob (an NSArchiver typedstream holding an
NSAttributedString). Written from the format's public description (research on #5), not from GPL code.

The string object follows the class name `NSString`: after it come a class version byte, `\\x94`, and
`\\x84\\x01+` (type "+": counted bytes), then the length (one byte below 0x80, or \\x81 + uint16 LE,
or \\x82 + uint32 LE) and that many UTF-8 bytes. Invalid UTF-8 becomes U+FFFD.
"""

from __future__ import annotations

import struct

SIGNATURE = b"streamtyped"


def text_from_attributed_body(blob: bytes) -> str:
    """Raises ValueError when the blob isn't a typedstream with a readable string."""
    if not isinstance(blob, (bytes, bytearray)) or SIGNATURE not in blob[:16]:
        raise ValueError("not a typedstream")
    marker = blob.find(b"NSString")
    if marker < 0:
        raise ValueError("no NSString in typedstream")
    start = blob.find(b"\x84\x01+", marker)
    if start < 0:
        raise ValueError("no string payload after NSString")
    position = start + 3
    if position >= len(blob):
        raise ValueError("truncated typedstream")
    first = blob[position]
    if first < 0x80:
        count, position = first, position + 1
    elif first == 0x81 and position + 3 <= len(blob):
        count, position = struct.unpack("<H", blob[position + 1 : position + 3])[0], position + 3
    elif first == 0x82 and position + 5 <= len(blob):
        count, position = struct.unpack("<I", blob[position + 1 : position + 5])[0], position + 5
    else:
        raise ValueError("bad string length in typedstream")
    if position + count > len(blob):
        raise ValueError("string runs past the end of the typedstream")
    return bytes(blob[position : position + count]).decode("utf-8", errors="replace")
