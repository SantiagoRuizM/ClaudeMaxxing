---
name: pdf-markdown
description: Read a PDF as Markdown (text, headings, tables, page by page) with PyMuPDF4LLM instead of loading its pages as images with Read, which costs many times more of the plan. Use whenever you need what a .pdf file says - the user mentions or attaches a PDF, asks to summarize, search, quote, translate or compare one, or a task needs facts from a PDF (a spec, a paper, an invoice, a manual). Not for creating, filling, merging or splitting PDFs, nor for judging how a page looks (charts, layout, signatures): use Read on those pages.
---

# PDF as Markdown

`pdf2md.sh` sits in `bin/`, two folders above this skill's base directory. Run it with the Bash tool:

```bash
bash "<base>/../../bin/pdf2md.sh" "C:/path/file.pdf"                 # whole PDF to stdout
bash "<base>/../../bin/pdf2md.sh" "C:/path/file.pdf" --pages 1-3,7   # only those pages (1-based, "10-" = to the end)
bash "<base>/../../bin/pdf2md.sh" "C:/path/file.pdf" -o "<scratchpad>/file.md"
```

- Each page ends with a `--- end of page.page_number=N ---` line: cite pages by that number.
- When the Markdown is longer than the Bash output can hold, it goes to a file in `%TEMP%\claudemaxxing-pdf` and only the path is printed. For a long PDF, write it with `-o` to the scratchpad and use Grep and Read (with offset/limit) on the `.md` instead of reading it all.
- Stderr may say "RapidOCR is missing": harmless.
- Exit 3 means the pages have no text layer (a scanned PDF): read those pages with Read (`pages` parameter).
- Exit 2 means PyMuPDF is not installed on this PC: fall back to Read and tell the user to run ClaudeMaxxing's `install.ps1` again.
- Tables come out as Markdown tables; images are left out. When a figure matters, Read that page.
