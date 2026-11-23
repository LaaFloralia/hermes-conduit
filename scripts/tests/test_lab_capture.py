import binascii
import importlib.util
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zlib

LAB = Path(__file__).resolve().parents[1] / 'laa' / 'lab'
SPEC = importlib.util.spec_from_file_location('lab_capture', LAB / 'capture.py')
capture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(capture)


def png(path, pixels, chunk=True):
    def field(name, data):
        return struct.pack('>I', len(data)) + name + data + struct.pack('>I', binascii.crc32(name + data))

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(capture.PNG + field(b'IHDR', struct.pack('>IIBBBBB', len(pixels), 1, 8, 6, 0, 0, 0))
                     + (field(b'tEXt', b'Test\0illustration') if chunk else b'')
                     + field(b'IDAT', zlib.compress(b'\0' + bytes(sum(pixels, ())))) + field(b'IEND', b''))


def screen(ident, **extra):
    return {'id': ident, 'title': '<日本語>', 'route': 'Button', 'fixture': 'unit', **extra}


class ScreenManifestTests(unittest.TestCase):
    def test_committed_screen_list_and_full_matrix(self):
        screens = capture.validate_screens(json.loads((LAB / 'capture-screens.json').read_text()))
        cells = capture.matrix(screens, ('iphone', 'mac'))
        self.assertEqual(len(cells), len(screens) * 8 + sum('mac' in row for row in screens) * 9)
        self.assertEqual(len(cells), len(set(cells)))
        self.assertIn(('iphone', 'text-max', 'chat-staff', ''), cells)
        self.assertIn(('mac', 'long-japanese', 'chat-staff', '1680x1050'), cells)
        self.assertNotIn(('mac', 'text-max', 'chat-staff', '1680x1050'), cells)
        self.assertEqual(capture.matrix([screen('one')], ['iphone'], ['light']), [('iphone', 'light', 'one', '')])

    def test_rejects_duplicate_or_unsafe_ids_and_missing_descriptors(self):
        for value in ([], [screen('a'), screen('a')], [screen('../image')], [{'id': 'a'}],
                      [screen('a', mac={'section': 'not-real'})]):
            with self.subTest(value=value), self.assertRaises(capture.CaptureError):
                capture.validate_screens(value)
        with self.assertRaises(capture.CaptureError):
            capture.selection('light,missing', capture.VARIANTS, '--variants')


class OutputTests(unittest.TestCase):
    black, white = (0, 0, 0, 255), (255, 255, 255, 255)

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)

    def make(self, base, shots, chunk=True):
        screens = [screen(name) for name in shots]
        keys = capture.matrix(screens, ['iphone'], ['light'])
        rows = []
        for key in keys:
            png(base / capture.filename(key), shots[key[2]], chunk=chunk)
            rows.append(capture.image_entry(base, key, 'sha', 0))
        capture.index(base, keys, rows, screens, {}, 0.2)
        return keys, rows

    def test_index_schema_and_local_contact_sheet(self):
        keys, rows = self.make(self.root, {'one': [self.black]})
        doc = json.loads((self.root / 'index.json').read_text())
        self.assertEqual(doc['images'], rows)
        self.assertEqual(rows[0]['taken_at'], '1970-01-01T00:00:00.000+00:00')
        self.assertEqual(rows[0]['pixel_size'], [1, 1])
        self.assertEqual(rows[0]['app_sha'], 'sha')
        self.assertEqual(rows[0]['simulator']['udid'], capture.PHONE)
        self.assertRegex(rows[0]['sha256'], r'^[a-f0-9]{64}$')
        sheet = (self.root / 'index.html').read_text()
        self.assertIn('&lt;日本語&gt;', sheet)
        self.assertIn('src="iphone/light/one.png"', sheet)
        self.assertNotIn('https://', sheet)
        self.assertEqual(list(capture.load_index(self.root)), keys)

    def test_missing_listed_cell_fails_without_publishing(self):
        screens = [screen('one'), screen('two')]
        keys = capture.matrix(screens, ['iphone'], ['light'])
        png(self.root / capture.filename(keys[0]), [self.black])
        row = capture.image_entry(self.root, keys[0], 'sha', 0)
        with self.assertRaisesRegex(capture.CaptureError, 'missing=.*iphone/light/two.png'):
            capture.index(self.root, keys, [row], screens, {}, 0)
        self.assertFalse((self.root / 'index.json').exists())
        with self.assertRaisesRegex(capture.CaptureError, 'duplicates=1'):
            capture.index(self.root, keys, [row, row], screens, {}, 0)

    def test_compare_added_missing_and_change(self):
        a, b = self.root / 'a', self.root / 'b'
        self.make(a, {'same': [self.black], 'gone': [self.black], 'different': [self.black, self.black]})
        self.make(b, {'same': [self.black], 'new': [self.black], 'different': [self.black, self.white]})
        out = capture.compare(a, b, lambda pairs: [0.5] * len(pairs))
        self.assertEqual(out, {'changed': [{'path': 'iphone/light/different.png', 'changed_pixel_ratio': 0.5}],
                               'added': ['iphone/light/new.png'], 'missing': ['iphone/light/gone.png'], 'unchanged': 1})
        (b / 'iphone/light/new.png').unlink()
        with self.assertRaisesRegex(capture.CaptureError, 'File is missing'):
            capture.compare(a, b, lambda pairs: [])

    @unittest.skipUnless(sys.platform == 'darwin' and Path(capture.DEVELOPER).is_dir(), 'CoreGraphics and Xcode required')
    def test_coregraphics_pixel_diff_and_png_metadata(self):
        a, b = self.root / 'a', self.root / 'b'
        self.make(a, {'one': [self.black, self.black], 'same': [self.black], 'size': [self.black]})
        self.make(b, {'one': [self.black, self.white], 'same': [self.black], 'size': [self.black, self.black]}, chunk=False)
        out = capture.compare(a, b, capture.coregraphics_ratios)
        self.assertEqual(out['changed'], [{'path': 'iphone/light/one.png', 'changed_pixel_ratio': 0.5},
                                          {'path': 'iphone/light/size.png', 'changed_pixel_ratio': 0.5}])
        self.assertEqual(out['unchanged'], 1)


if __name__ == '__main__':
    unittest.main()
