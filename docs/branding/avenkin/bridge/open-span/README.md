# Open Span — selected direction

Editable vector reconstruction of the selected Bridge concept. These files are a separate branding asset set; application asset catalogues have not been changed.

## Artwork

- `masters/avenkin-mark.svg`: transparent orange mark.
- `masters/avenkin-office-mark.svg`: transparent charcoal mark.
- `masters/*-light.svg`, `*-dark.svg`, `*-monochrome.svg`: square icon sources with backgrounds.
- `exports/*-1024.png`: 1024px PNG exports of each source.
- `04-open-span-vector-review.png`: light, dark and monochrome review sheet, including actual 16–64px samples.

Both products use the exact same arch and crossbar path. Office adds a joined 56-unit foundation on the 1024-unit canvas. The crossbar terminates at x=570, leaving a visible gap before the right leg. All appearances preserve this geometry.

Orange: `#E77F47`. Ivory: `#F6F2EB`. Charcoal: `#202B2D`.

## Exports

App-icon PNGs are square RGB files with opaque backgrounds and no baked-in corner mask or shadows. The platform supplies its own mask. Mark PNGs have transparency. SVG masters have paths and solid fills, with no embedded raster images or font dependencies.

Monochrome exports provide white artwork on black for tinting workflows; platform-specific tinted presentation still needs an application check. The review sheet uses an approximate rounded mask for presentation only. Its sample sizes are accurate when the PNG is viewed at 100%; an inline viewer may scale the sheet.

## Rebuild

Run `python3 build_assets.py` from this directory, with Pillow and ImageMagick 7 installed. The script creates every SVG and PNG from the shared path geometry; it does not modify application assets or use the earlier generated boards as export sources.

The typography in the review sheet is a presentation label, not a final vector wordmark.
