"""Compile production parser/storage helpers and run their regressions on macOS."""
from pathlib import Path
import io
import json
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
    mixed = 'Chapter 1: ' + 'English text and numbers 12345. ' * 100 + '\n第一章 开始\n这是一段中文正文。'
    traditional = '第一章 開始\n這是一段繁體中文小說，閱讀書籍時應該完整保留文字。\n' * 20
    samples = {
        'gbk': ('gbk', mixed),
        'gb18030': ('gb18030', '第一章 开始\n这是中文正文，𠮷野家的故事😀。' * 20),
        'big5': ('big5', traditional),
        'short-gbk': ('gbk', 'Chapter 1: 中文'),
        'short-big5': ('big5', '第一章 開始'),
    }
    unicode_text = 'Chapter 1\n中文繁體😀𠮷\t正文\r\n'
    for codec in ['utf-8', 'utf-8-sig', 'utf-16', 'utf-32',
                  'utf-16-le', 'utf-16-be', 'utf-32-le', 'utf-32-be']:
        samples[codec] = (codec, unicode_text)
    expected = {}
    for name, (codec, text) in samples.items():
        filename = f'encoding-{name}.txt'
        (destination / filename).write_bytes(text.encode(codec))
        expected[filename] = text
    (destination / 'encodings.json').write_text(json.dumps(expected), encoding='utf-8')

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
