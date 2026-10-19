"""Validate the archived web PNG, which is served directly to browsers."""
from pathlib import Path
import struct
import sys
import zlib


def check(path):
    data = Path(path).read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', 'Web icon is not a PNG'
    offset, chunks, compressed = 8, [], bytearray()
    while offset < len(data):
        size, kind = struct.unpack_from('>I4s', data, offset)
        end = offset + 8 + size
        assert end + 4 <= len(data), 'Truncated web PNG'
        assert kind != b'CgBI', 'Web icon was converted to Apple CgBI; disable COMPRESS_PNG_FILES'
        assert zlib.crc32(data[offset + 4:end]) == struct.unpack_from('>I', data, end)[0], 'PNG CRC mismatch'
        chunks.append(kind)
        if kind == b'IDAT':
            compressed.extend(data[offset + 8:end])
        offset = end + 4
    assert chunks[0] == b'IHDR' and chunks[-1] == b'IEND', 'Incomplete PNG structure'
    assert zlib.decompress(compressed), 'Empty PNG pixels'
    print('PASS: archived web icon is a standard PNG with valid chunks and zlib pixels')


if __name__ == '__main__':
    check(sys.argv[1])
