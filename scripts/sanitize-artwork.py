#!/usr/bin/env python3
"""Strip PNG metadata, including embedded ICNS PNGs, and PDF build metadata.

PNG image chunks and PDF drawing streams remain unchanged. PDF dictionary
fields are blanked in place so cross-reference offsets stay valid.
"""
import re
import struct
import sys
from pathlib import Path
from importlib.util import module_from_spec, spec_from_file_location

spec = spec_from_file_location('strip_png', Path(__file__).with_name('strip-png-metadata.py'))
png = module_from_spec(spec)
spec.loader.exec_module(png)


def sanitize(data):
    if data.startswith(png.SIGNATURE):
        return png.strip(data)
    if data.startswith(b'icns'):
        pieces, offset = [], 8
        if len(data) < 8 or struct.unpack('>I', data[4:8])[0] != len(data):
            raise ValueError('invalid ICNS length')
        while offset < len(data):
            if offset + 8 > len(data):
                raise ValueError('truncated ICNS header')
            kind, size = struct.unpack('>4sI', data[offset:offset + 8])
            if size < 8 or offset + size > len(data):
                raise ValueError('invalid ICNS element')
            part = data[offset + 8:offset + size]
            if part.startswith(png.SIGNATURE):
                part = png.strip(part)
            pieces.append(kind + struct.pack('>I', len(part) + 8) + part)
            offset += size
        body = b''.join(pieces)
        return b'icns' + struct.pack('>I', len(body) + 8) + body
    if data.startswith(b'%PDF'):
        return re.sub(rb'/(?:CreationDate|ModDate|Producer|Author|Creator|Title|Subject|Keywords)\s*\((?:\\.|[^\\)])*\)',
                      lambda match: b' ' * len(match.group()), data)
    return data


if __name__ == '__main__':
    for name in sys.argv[1:]:
        path = Path(name)
        original = path.read_bytes()
        cleaned = sanitize(original)
        if cleaned != original:
            path.write_bytes(cleaned)
            print(f'Stripped metadata: {path}')
