"""Compile production parser/storage helpers and run their regressions on macOS."""
from pathlib import Path
import io
import shutil
import struct
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def epub(missing=False, malformed=False):
    files = {
        'META-INF/container.xml': '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
        'OPS/book.opf': '<package><metadata><title>测试书</title></metadata><manifest>'
                        '<item id="one" href="../Text/one.xhtml"/>'
                        '<item id="two" href="../Text/two.xhtml"/></manifest>'
                        '<spine><itemref idref="one"/><itemref idref="two"/></spine></package>',
        'Text/one.xhtml': '<html><body><p>短章</p></body></html>',
        'Text/two.xhtml': '<html><body><p>😀第二章</p></body></html>',
    }
    if missing:
        del files['Text/two.xhtml']
    if malformed:
        files['OPS/book.opf'] = files['OPS/book.opf'].removesuffix('</package>')
    result = io.BytesIO()
    with zipfile.ZipFile(result, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, content in files.items():
            archive.writestr(name, content.encode())
    return result.getvalue()


def write_fixtures(destination):
    valid = epub()
    (destination / 'valid.epub').write_bytes(valid)
    (destination / 'missing-spine.epub').write_bytes(epub(missing=True))
    (destination / 'bad-opf.epub').write_bytes(epub(malformed=True))
    (destination / 'truncated.epub').write_bytes(valid[:-10])
    offset = valid.index(b'PK\x01\x02')
    bad_crc = bytearray(valid)
    bad_crc[offset + 16] ^= 1
    (destination / 'bad-crc.epub').write_bytes(bad_crc)
    oversized = bytearray(valid)
    struct.pack_into('<I', oversized, offset + 24, 33 * 1024 * 1024)
    (destination / 'oversize.epub').write_bytes(oversized)


def main():
    compiler = shutil.which('swiftc')
    if compiler is None:
        raise SystemExit('Swift compiler required. Run on macOS with Xcode installed.')
    sources = ['Photo/Books/MiniZip.swift', 'Photo/Books/EpubParser.swift',
               'Photo/Books/TextDecoding.swift', 'Photo/Books/ChapterSplitter.swift',
               'Photo/Books/BookText.swift', 'Photo/Core/Storage.swift',
               'Photo/Core/SnapshotWriter.swift', 'Photo/Server/HTTPTypes.swift',
               'Tools/Checks/ReaderRegressionTests.swift']
    with tempfile.TemporaryDirectory(prefix='reader-tests-') as temporary:
        output = Path(temporary)
        write_fixtures(output)
        binary = output / 'reader-tests'
        subprocess.run([compiler, '-swift-version', '5', '-parse-as-library',
                        *[str(ROOT / name) for name in sources], '-o', str(binary)], check=True)
        subprocess.run([str(binary), str(output)], check=True)


if __name__ == '__main__':
    main()
