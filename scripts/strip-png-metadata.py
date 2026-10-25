#!/usr/bin/env python3
"""Remove metadata chunks from PNG files in place without re-encoding pixels.

Keeps the critical chunks (IHDR, PLTE, IDAT, IEND) and the colour/size chunks
listed in KEPT_ANCILLARY. Text, XMP, EXIF, C2PA and every other ancillary chunk
is dropped. Chunk bytes, including their CRCs, are copied unchanged.
"""
import struct
import sys
from pathlib import Path

SIGNATURE = b'\x89PNG\r\n\x1a\n'
KEPT_ANCILLARY = {b'tRNS', b'sRGB', b'gAMA', b'cHRM', b'iCCP', b'pHYs'}


def chunks(data):
    if not data.startswith(SIGNATURE):
        raise ValueError('not a PNG file')
    offset = len(SIGNATURE)
    while offset < len(data):
        if offset + 8 > len(data):
            raise ValueError('truncated chunk header')
        length, kind = struct.unpack('>I4s', data[offset:offset + 8])
        end = offset + 12 + length
        if end > len(data):
            raise ValueError('truncated chunk')
        yield kind, data[offset:end]
        offset = end
        if kind == b'IEND':
            return
    raise ValueError('missing IEND chunk')


def is_kept(kind):
    # An uppercase first letter marks a critical chunk.
    return kind[:1].isupper() or kind in KEPT_ANCILLARY


def strip(data):
    return SIGNATURE + b''.join(raw for kind, raw in chunks(data) if is_kept(kind))


def main(paths):
    if not paths:
        print('usage: strip-png-metadata.py FILE.png...', file=sys.stderr)
        return 2
    for name in paths:
        path = Path(name)
        original = path.read_bytes()
        stripped = strip(original)
        if stripped != original:
            path.write_bytes(stripped)
            print(f'Stripped {path} ({len(original) - len(stripped)} bytes removed)')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
