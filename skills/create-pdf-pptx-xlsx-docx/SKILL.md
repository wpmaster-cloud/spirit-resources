---
name: create-pdf-pptx-xlsx-docx
requires: python3, libreoffice, pandoc
description: "Create, read, edit, and convert documents — PDF, PowerPoint (.pptx), Excel (.xlsx/.xlsm/.csv/.tsv), and Word (.docx). Use this skill any time one of these files is the input, the output, or both. PDF: read/extract text & tables, merge/split, rotate, watermark, encrypt/decrypt, OCR scanned PDFs, create new PDFs, and fill PDF forms. PowerPoint: build decks/pitch decks, extract or edit slides, templates, layouts, speaker notes, comments. Excel: open/read/edit/fix spreadsheets, add columns, compute & recalculate formulas (zero formula errors), format, chart, clean messy tabular data, create from scratch. Word: create or edit .docx, headings/TOC/tables/images, find-and-replace, tracked changes and comments. Trigger whenever the user mentions a .pdf/.pptx/.xlsx/.csv/.docx file by name, says 'deck'/'slides'/'presentation'/'spreadsheet'/'Word doc'/'report'/'memo'/'letter', or asks to produce one of these as a deliverable. For pure extraction TO Markdown of arbitrary files, prefer the markitdown skill; for authoring/editing the four document types above, use this skill."
license: Proprietary. LICENSE.txt has complete terms
---

# Create / edit PDF, PowerPoint, Excel & Word documents

A unified toolkit for the four document formats. Pick the format guide below — each is the full, self-contained workflow for that format. Run scripts from this skill's directory so the relative `scripts/...` paths resolve.

## Route by format

| The user wants to work with… | Read this guide | Key tools |
|------|------|------|
| **PDF** (`.pdf`) — read/extract, merge/split, watermark, OCR, create, fill forms | **[pdf.md](pdf.md)** (+ [reference.md](reference.md), [forms.md](forms.md)) | `pypdf`, `pdfplumber`, `reportlab`, `qpdf`, `scripts/*` |
| **PowerPoint** (`.pptx`) — build decks, edit slides, templates, notes | **[pptx.md](pptx.md)** (+ [editing.md](editing.md), [pptxgenjs.md](pptxgenjs.md)) | `pptxgenjs`, `scripts/office/*`, `scripts/thumbnail.py` |
| **Excel** (`.xlsx/.xlsm/.csv/.tsv`) — read/edit/fix, formulas, charts, clean data | **[xlsx.md](xlsx.md)** | `openpyxl`, `scripts/recalc.py`, `scripts/office/*` |
| **Word** (`.docx`) — create/edit, TOC, tracked changes, comments | **[docx.md](docx.md)** | `docx` (JS), `pandoc`, `scripts/accept_changes.py`, `scripts/comment.py`, `scripts/office/*` |

> Just need to turn a file into Markdown for reading/summarizing? Use the **markitdown** skill instead.

## Shared Office (OOXML) tooling — `scripts/office/`

PowerPoint, Excel, and Word are ZIP-packaged XML (OOXML). The format guides all rely on one shared toolset in `scripts/office/`:

- `scripts/office/unpack.py <file> <dir>/` — unzip an Office file to raw XML for inspection/editing.
- `scripts/office/pack.py <dir>/ <out> --original <file>` — repack edited XML back into a valid file.
- `scripts/office/validate.py <file>` — validate against the bundled ISO/ECMA OOXML schemas.
- `scripts/office/soffice.py --headless --convert-to <fmt> <file>` — LibreOffice conversion (e.g. → PDF), auto-configured for sandboxed environments.

## Dependencies (install on first use)

Install what the chosen format needs. Python/Node themselves can come from the
**install-runtimes** skill if missing; the system tools below need a package
manager and root (Debian shown — `apk add` the equivalents on Alpine, `brew
install` on macOS). LibreOffice and tesseract are heavyweight: on the minimal
spirit container, bake them into the image or do document work on a host.

```bash
# Python libs (PDF + Excel + Office XML work)
pip install pypdf pdfplumber reportlab openpyxl "markitdown[all]" Pillow pytesseract pdf2image

# Node libs (authoring from scratch)
npm install -g pptxgenjs docx

# System tools (Debian/Ubuntu)
sudo apt-get update && sudo apt-get install -y \
  libreoffice pandoc qpdf poppler-utils tesseract-ocr
```

- **LibreOffice (`soffice`)** — formula recalculation (Excel), PDF conversion (all Office), `.doc`→`.docx`.
- **pandoc** — Word text extraction / Markdown round-trips.
- **qpdf / poppler-utils** — PDF merge/split/rotate, `pdftotext`, `pdfimages`.
- **tesseract** — OCR for scanned PDFs.

## Files in this skill

- `pdf.md`, `pptx.md`, `xlsx.md`, `docx.md` — per-format workflow guides.
- `reference.md`, `forms.md` — PDF advanced reference and form-filling.
- `editing.md`, `pptxgenjs.md` — PowerPoint editing and from-scratch generation.
- `scripts/office/` — shared OOXML pack/unpack/validate/convert toolchain + schemas.
- `scripts/` — format-specific helpers (PDF form scripts, `recalc.py`, `thumbnail.py`, `add_slide.py`, `accept_changes.py`, `comment.py`, …).
