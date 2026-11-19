"""ClaudeMaxxing PDF: a PDF as Markdown for Claude, with PyMuPDF4LLM from the plugin's own venv (pdf2md.sh).

    pdf2md.py <file.pdf> [--pages 1-3,7,10-] [-o out.md]

Pages are numbered from 1, as a PDF viewer shows them. Without -o the Markdown goes to stdout, unless it is too
long for the Bash tool's output: then it goes to a file in %TEMP% and only its path is printed.
"""
import argparse
import contextlib
import os
import re
import sys
import tempfile

# The Bash tool cuts its output at 30000 characters; past this the Markdown goes to a file.
MAX_STDOUT = 25000


def parse_pages(spec, count):
    """'1-3,7,10-' -> 0-based page numbers, in order, without repeats; pages past the end are dropped."""
    pages = []
    for part in spec.split(','):
        part = part.strip()
        if not part:
            continue
        first, dash, last = part.partition('-')
        start = int(first)
        end = int(last) if last else (count if dash else start)
        if start < 1 or end < start:
            raise ValueError('bad page range: ' + part)
        for page in range(start - 1, min(end, count)):
            if page not in pages:
                pages.append(page)
    return pages


def main(argv=None):
    parser = argparse.ArgumentParser(description='PDF to Markdown (PyMuPDF4LLM)')
    parser.add_argument('pdf')
    parser.add_argument('--pages', help='1-based pages: 1-3,7,10-')
    parser.add_argument('-o', '--output', help='write the Markdown to this file')
    args = parser.parse_args(argv)

    # PyMuPDF prints its notices ("RapidOCR is missing") to stdout: they go to stderr, stdout is for the Markdown.
    # Imported here so parse_pages is testable without PyMuPDF.
    with contextlib.redirect_stdout(sys.stderr):
        import pymupdf
        import pymupdf4llm

        doc = pymupdf.open(args.pdf)
        pages = parse_pages(args.pages, doc.page_count) if args.pages else list(range(doc.page_count))
        if not pages:
            print('no such pages: the PDF has %d' % doc.page_count)
            return 1
        md = pymupdf4llm.to_markdown(doc, pages=pages, page_separators=True)
    shown = '%d of %d pages' % (len(pages), doc.page_count)
    # Only the "--- end of page..." lines: no page had a text layer.
    if not any(ch.isalnum() for ch in re.sub(r'^--- end of page.*$', '', md, flags=re.M)):
        print('No text layer in %s (%s): a scanned PDF. Read those pages with the Read tool instead.' % (args.pdf, shown), file=sys.stderr)
        return 3

    output = args.output
    if not output and len(md) > MAX_STDOUT:
        name = os.path.splitext(os.path.basename(args.pdf))[0] + '.md'
        output = os.path.join(tempfile.gettempdir(), 'claudemaxxing-pdf', name)
    if not output:
        sys.stdout.write(md)
        return 0
    os.makedirs(os.path.dirname(os.path.abspath(output)), exist_ok=True)
    with open(output, 'w', encoding='utf-8') as f:
        f.write(md)
    print('%s: %d characters, %s, in %s (search it with Grep, read parts with Read)' % (args.pdf, len(md), shown, output))
    return 0


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    sys.exit(main())
