"""pdf2md.py: page ranges always; the conversion when PyMuPDF is importable (the installed pdf\\venv python).

    python pdf\\test\\test_pdf2md.py
    %LOCALAPPDATA%\\ClaudeMaxxing\\pdf\\venv\\Scripts\\python.exe pdf\\test\\test_pdf2md.py
"""
import contextlib
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'bin'))
import pdf2md  # noqa: E402


class PageRanges(unittest.TestCase):
    def test_ranges(self):
        self.assertEqual(pdf2md.parse_pages('1-3,7', 10), [0, 1, 2, 6])
        self.assertEqual(pdf2md.parse_pages('9-', 10), [8, 9])
        self.assertEqual(pdf2md.parse_pages('2,1-2, ,2', 10), [1, 0])
        self.assertEqual(pdf2md.parse_pages('8-20', 9), [7, 8])
        self.assertEqual(pdf2md.parse_pages('12', 9), [])

    def test_bad(self):
        for spec in ('0', '3-1', 'a', '-2'):
            with self.assertRaises(ValueError):
                pdf2md.parse_pages(spec, 10)


try:
    import pymupdf
except ImportError:
    pymupdf = None


@unittest.skipIf(pymupdf is None, 'PyMuPDF not installed in this python')
class Convert(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.pdf = os.path.join(self.dir, 'sample.pdf')
        doc = pymupdf.open()
        for text in ('First page about apples', 'Second page about pears', ''):
            page = doc.new_page()
            if text:
                page.insert_text((72, 72), text)
        doc.save(self.pdf)

    def run_main(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = pdf2md.main([self.pdf, *args])
        return code, out.getvalue()

    def test_to_file_with_pages(self):
        md_path = os.path.join(self.dir, 'out.md')
        code, out = self.run_main('--pages', '2', '-o', md_path)
        self.assertEqual(code, 0)
        self.assertIn('1 of 3 pages', out)
        with open(md_path, encoding='utf-8') as f:
            md = f.read()
        self.assertIn('pears', md)
        self.assertNotIn('apples', md)

    def test_scanned_page(self):
        self.assertEqual(self.run_main('--pages', '3')[0], 3)

    def test_no_such_page(self):
        self.assertEqual(self.run_main('--pages', '9')[0], 1)


if __name__ == '__main__':
    unittest.main()
