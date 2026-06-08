# HealthEquity parser samples (local-only)

Drop real HealthEquity HSA statement PDFs in this folder to build/iterate on the
parser. **PDFs/CSVs here are git-ignored** (see `.gitignore`) so personal
financial data is never committed. Only this README is tracked.

Once a statement is here, the parser is developed against the `pdftotext` output;
the committed test uses a redacted/synthetic excerpt, never the real file.
