#!/usr/bin/env python3
"""Export SentencePiece unigram scores from the verified public keyword model. Build-time only."""
import json
from pathlib import Path
import struct
import sys


def fields(data):
    offset = 0

    def varint():
        nonlocal offset
        value, shift = 0, 0
        while True:
            byte = data[offset]
            offset += 1
            value |= (byte & 127) << shift
            if byte < 128:
                return value
            shift += 7
            if shift > 63:
                raise ValueError("Invalid protobuf varint")

    while offset < len(data):
        tag = varint()
        wire = tag & 7
        if wire == 0:
            value = varint()
        elif wire == 2:
            length = varint()
            value = data[offset:offset + length]
            offset += length
        elif wire in (1, 5):
            size = 8 if wire == 1 else 4
            value = data[offset:offset + size]
            offset += size
        else:
            raise ValueError("Unsupported protobuf field")
        yield tag >> 3, value


scores = {}
for number, value in fields(Path(sys.argv[1]).read_bytes()):
    if number == 1:
        piece = dict(fields(value))
        scores[piece[1].decode("utf-8")] = struct.unpack("<f", piece[2])[0]
if len(scores) != 500:
    raise ValueError("Unexpected keyword vocabulary size")
Path(sys.argv[2]).write_text(json.dumps(scores, ensure_ascii=False), encoding="utf-8")
