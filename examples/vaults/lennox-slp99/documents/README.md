# documents/ — the manuals go here

The manuals are Lennox's copyright and are **not** in the repository. To complete this vault, extract
your own copies with the repository's extractor and drop the results in this folder under the exact
names `manifest.json` lists:

```
swift Scripts/extract-manual-text.swift "Lennox SLP99 Service Manual.pdf"      documents/SLP99UHVK-service-manual.md
swift Scripts/extract-manual-text.swift "Lennox SLP99 Installation Manual.pdf" documents/SLP99UHVK-installation-instructions.md
```

Both PDFs carry a full text layer (0 of 85 and 0 of 78 pages needed recognition), so the original
PDFs work just as well in place of the `.md` files — change the `file` entries in `manifest.json` to
match. Page numbers in the manuals match the PDF page index — the extractor reports `0 pages printed
a page number that disagreed with the PDF page` for both — so citations read as printed.

The extractor closes with a manifest line suggesting a `title` and a `kind` from the input file
name. Both are guesses to edit: `manifest.json` here calls the two manuals *SLP99UHVK Service
Manual* and *SLP99UHVK Installation Instructions*, which is what a technician hears in a citation,
rather than whatever your PDFs happen to be named. Only the `file` name has to match exactly.
