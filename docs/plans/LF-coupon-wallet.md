# Plan LF — The Coupon Wallet (photograph a coupon, show its barcode at the till)

**Status:** 📝 Drafted 2026-11-11. Nothing built. The [decisions](#decisions-for-greig-open) are
recommendations and are still open.
**Track:** Everyday assistant. No Field Assist dependency, no paid unlock.
**Origin:** an example list of routines a cloud personal agent runs, which the owner shared on 2026-11-11.
One of them keeps store coupons that arrive on paper or by email. It rebuilds each coupon's barcode from a
photo of the printed number, so the paper can stay at home.
**Builds on:** `BarcodeScannerTool` (`scan_code`, `VNDetectBarcodesRequest`), `OCRService`,
`SmartCaptureTool` and `CaptureParsers` (the capture-to-fields pattern), the privacy chokepoint
(`FilteredStillProviding.filteredStill(for:source:)`, `OutboundFrameConsumer`, Plan
[CP](CP-outbound-frame-privacy.md)), `ParkingPhotoFlow` (a filtered still kept with a record, phone photos
filtered through `StillImageFiltering`), `DataStoreRegistry`, `BrightnessTool`, My Day (`MyDaySources`,
Plan [DY](DY-my-day-everyday-briefing.md)), the watch's shared payload pattern (`Shared/WatchToday.swift`,
Plan [KS](KS-watch-today-screens.md)).
**Sits beside:** Plan [FH](FH-handle-this-visual-actions.md) P3 (structured expense and tracking records,
drafted). A coupon is a third record of the same shape: see, review, save, undo. Plan
[DU](DU-eyes-free-capture-confirmation.md) P2 (`RepeatReadConfirmer`, drafted). Plan
[LK](LK-reading-mail-the-decision.md) (coupons that arrive by email). Plan
[LG](LG-reminders-on-a-rhythm.md) (reminders that wait on a condition).

---

## Trigger

Paper coupons get left at home, and emailed ones are buried when you reach the till. The barcode on a coupon
is usually just its printed number in bars. A phone that has read the number once can show the bars again,
so the paper is not needed.

Avenkin already has half of this. `scan_code` decodes a barcode from the glasses or phone camera and
`smart_capture` reads text into fields. Neither keeps anything. `scan_code` answers "Found EAN barcode:
9415…" and stops.

## Outcome

- "Save this coupon" while looking at it (glasses), or from a photo on the phone:
  → "Savers, 30% off one item, until 30 November. Code 0400 1234 5678 9. Save it?" → "Yes" → saved.
  The number is read back in groups. The expiry is said as a date, never "in three weeks".
- No barcode, only a printed number or promo code → the same flow, from the text. The wallet shows the
  number large, or draws the barcode when the wearer says which kind it is (decision 2).
- "What coupons have I got?" / "Any coupons for Savers?" → a short list, soonest expiry first.
- At the till: "Show my Savers coupon" → the phone opens the coupon full screen with brightness at maximum,
  the bars drawn edge-to-edge, the number underneath and the terms below that. Brightness goes back when it
  closes.
- "I used it" or a tap on **Used** → it leaves the list and keeps a record for 30 days, so it can be undone.
- The day before a coupon expires it shows in My Day, plus one notification if the wearer turns that on
  (decision 6). An expired coupon leaves the list by itself.
- A coupon that says it must be the original ("void if copied", "original only", "no photocopies") is
  saved with that line shown at the top of the till view. The app does not refuse it. The store decides
  what it accepts, and the wearer should know what the coupon says.

## What exists, and what doesn't

**Exists (verified 2026-11-11 at `main` 2d936d2):**
- `BarcodeScannerTool` (`Services/NativeTools/BarcodeScannerTool.swift`): one `filteredStill(for:
  .onDeviceVision)`, then `VNDetectBarcodesRequest`. `type: barcode` restricts to EAN-8, EAN-13, UPC-E,
  Code 39, Code 93, Code 128, ITF-14 and PDF417. `any` uses Vision's full set, which includes the GS1
  DataBar family, but `symbologyName` names DataBar only as "Code". It returns a `String` for the model
  ("Found EAN barcode: …"). It has no typed result, no repeat-read and nothing stored. Its roster entry is
  `barcodeScannerTool`.
- `SmartCaptureTool` (`smart_capture`): `filteredStill(for: .onDeviceVision, source:
  .cachedFrameThenPhoto)`, `OCRService.recognizeText(in:)`, then `CaptureParsers` for the `contact`,
  `receipt` and `event` modes. It returns fields plus a bracketed next-step hint for the model, and keeps
  nothing.
- `ParkingPhotoFlow` (`Services/Parking/`): the precedent for keeping a picture with a record. The glasses
  still comes from the chokepoint, and a phone photo goes through `StillImageFiltering.filteredOrUnavailable`.
  The scope is `.toolPhotoCapture`, reused on purpose ("a scope names where pixels *go*"), with two roster
  entries (`parkingSignCapture`, `parkingPhonePhoto`). It fails closed: no filter, no picture kept. The
  Parking settings view uses `PhotosPicker`.
- `DataStoreRegistry` (`Services/Privacy/`): every store is registered with data class, protection, backup
  and deletion. `DataStoreRegistryTests` fails on an unregistered owner.
- `BrightnessTool` (`brightness`): sets the phone's screen brightness.
- My Day: `MyDaySources.swift` defines one protocol per source (`CalendarDaySource`, `RemindersDaySource`,
  `WeatherDaySource`, `TravelTimeDaySource`, `DigestDaySource`, `GoalsDaySource`). `MyDayKind` has `event`,
  `leaveBy`, `preparation`, `reminder`, `update` and `weather`.
- The watch: `Shared/WatchToday.swift` is compiled into both targets (listed in `project.watch.yml`). The
  watch app (`OpenGlassesWatch/`) draws glance surfaces, jobs and Today, and the watch target imports no
  image framework.
- The Share extension (`OpenGlassesShareExtension/`) accepts text, one web URL or one attachment, and hands
  text to the teleprompter inbox. **It does not take images.**

**Doesn't exist:**
- Any stored coupon, loyalty or voucher record. FH P3's saved captures are drafted, not built.
- A barcode drawn by the app. Core Image has generators for **Code 128, QR, PDF417 and Aztec** only. It has
  **none for EAN-13, EAN-8, UPC-A, UPC-E, Code 39 or ITF**, and the grocery and retail codes most coupons
  carry are in that second group, so the app needs its own encoder (P0).
- Any parser for coupon wording: store, offer, expiry, terms.

## Design

### 1 · The record (`Coupon`, pure, `Codable`)

```
struct Coupon: Codable, Identifiable, Equatable {
    let id: UUID
    var store: String                // as printed, normalised for matching ("Savers")
    var offer: String                // "30% off one item"
    var code: CouponCode?            // what draws the bars, if anything does
    var printedNumber: String?       // the digits or promo code as printed, leading zeros kept
    var expires: DateComponents?     // a date, never a time; nil = "no expiry printed"
    var terms: [String]              // short lines the parser kept, "original only" among them
    var mustBeOriginal: Bool
    var source: Source               // .glasses, .phonePhoto, .photoLibrary, .shared, .email (LK)
    var photo: String?               // file name of the kept filtered still, if kept (decision 5)
    var addedAt: Date
    var usedAt: Date?
}
struct CouponCode: Codable, Equatable { let symbology: CouponSymbology; let payload: String }
```

`CouponSymbology` is a closed list: `ean13`, `ean8`, `upcA`, `upcE`, `code128`, `code39`, `itf`, `qr`,
`pdf417`, `aztec`, `dataBar` (stored, not drawn in v1: decision 2). **The payload is exactly what Vision
decoded, or exactly the digits the wearer confirmed.** It is never corrected, padded or guessed.

### 2 · Reading a coupon (`CouponReader`, pure over observations)

The input is the barcode observations (symbology and payload) and the OCR lines from one filtered still.

1. **A decoded barcode wins** over OCR for the code. Two different decoded payloads give a choice to the
   wearer, never a pick. With DU's `RepeatReadConfirmer` built, the glasses path needs two equal reads.
   Until then, one read plus the spoken number read-back.
2. **No barcode:** the OCR lines are searched for a code line. That is a run of 8 to 14 digits under or
   near the words "barcode", "code" or "scan", or a promo code such as `SAVE30`. EAN and UPC candidates
   must pass their check digit (`GTINCheckDigit`, pure). A run that fails the check is offered as "a number
   I couldn't check", and drawn only if the wearer confirms the kind.
3. **Store:** the line nearest the top that matches a known store name (the wearer's earlier coupons first,
   then a small bundled list), else the largest text line. The wearer can correct it by voice ("it's
   Savers").
4. **Offer:** the first line with a percent, a currency amount or "free", kept verbatim.
5. **Expiry:** dates after "expires", "valid until", "exp", "use by" or "ends", parsed with the wearer's
   locale. A date with no year takes the next occurrence. Two dates take the later one, and the wearer
   hears it. **No date found → no expiry, said as "I didn't see an expiry date"**, never an assumed one.
6. **Must be original:** a small per-language phrase list ("void if copied", "original only", "no
   photocopies", "not valid if reproduced"). A language with no list sets nothing, and the till view still
   shows the terms.

### 3 · Drawing the bars (`BarcodeEncoder`, pure)

The encoder turns `CouponCode` into modules (bars and spaces, widths in units) with quiet zones. Drawing is
a separate, dumb step: SwiftUI `Canvas` on the phone and the same on the watch. The encoder is plain Swift
with no image framework, so it compiles into the watch target like `WatchToday.swift`.

| Symbology | v1 | How |
|---|---|---|
| EAN-13, EAN-8, UPC-A, UPC-E | ✅ | Our encoder; check digit verified before drawing |
| Code 128 (B and C, auto-switch) | ✅ | Our encoder (Core Image would do it on the phone, but not on the watch) |
| Code 39, ITF | ✅ | Our encoder |
| QR, PDF417, Aztec | ✅ phone | `CIQRCodeGenerator`, `CIPDF417BarcodeGenerator`, `CIAztecCodeGenerator`. The watch shows the number only |
| GS1 DataBar (incl. Expanded) | ❌ v1 | Stored and shown as the number. The encoding is complex, and decision 2 says whether to add it |

**Golden tests:** every symbology against published test vectors, plus a round-trip: the encoder draws the
bars, the drawing is rasterised in a test, and `VNDetectBarcodesRequest` must decode the original payload.
The round-trip runs on the simulator, which has Vision.

**The honest limit, on the till view and in the Help text:** a phone screen scans with camera-type
scanners, which most modern tills use. Older laser scanners often cannot read a screen. Some stores also
require the paper coupon. The app cannot change either.

### 4 · The tool (`coupons`)

One native tool, `coupons`, with actions:

- `save` takes the still from the chokepoint, runs `CouponReader` and returns the reading. Nothing is stored
  until the wearer says yes through `ToolConfirmationCoordinator`. The effect is `localMutation`.
- `list` and `find` filter by store and say the soonest expiry first. `show` opens the till view for one
  coupon. When several coupons match, the tool returns a short list for the model to ask which one, and
  never picks.
- `used`, `undo` and `remove`.

Its description says plainly that the numbers it returns are the only numbers to say. **The model never
supplies or edits a payload.** A spoken correction goes through `save` again with the wearer's digits, read
back, then confirmed.

### 5 · The store (`CouponStore`)

The store is one JSON file in Application Support, under a format number. The pattern is `VanStockStore`:
an unreadable file is refused, never overwritten. Photos sit beside the JSON in its own folder. The store is
registered in `DataStoreRegistry` as `coupons`, `dataClass: .personalMemory`, wearer-linked, with
`deleteAll` supported. Backup: see decision 7. Used coupons are kept 30 days, then purged. Expired coupons
are purged 7 days after expiry.

New roster entries in `OutboundFrameConsumer` are `couponCapture` (glasses still) and `couponPhonePhoto`
(phone camera and library), both under `.toolPhotoCapture`, as Parking does. With the blur unable to run, the
coupon is saved without a photo. The code is still read, because barcode and OCR reading are
`.onDeviceVision`.

### 6 · The phone, the watch and My Day

- **Phone:** a Coupons screen, sorted by expiry and grouped by store. The till view is full screen with
  brightness at maximum and auto-lock held while it is open. The bars run as wide as the screen allows, with
  quiet zones kept. Under them are the number, then a "must be original" banner if set, then the terms and the
  photo. Brightness and auto-lock are put back on close, on backgrounding, and after 3 minutes.
- **Watch** (decision 3): a Coupons row listing store, offer and expiry. A coupon opens to its 1D bars or
  its number. The phone sends a small `coupons` payload (store, offer, expiry, symbology, payload, at most
  20 coupons, no photos) beside `today`. The watch cannot raise its own brightness, and the view says
  "If it won't scan, use the phone."
- **My Day:** a `CouponsDaySource` adds a `reminder`-kind item the day before expiry and on the day
  ("Savers coupon ends tomorrow"). It is ranked `routine` and never `important`. A coupon is not a
  commitment.

### 7 · Ways in

- Glasses: "save this coupon".
- Phone: the Coupons screen's **Add** (camera or library, filtered like Parking's picker).
- Share extension: adding images to the extension's activation rule, with images handed to the main app
  through an app-group inbox the way `SharedTeleprompterInbox` hands over text. This is its own phase (P2),
  because the extension's single job changes.
- Email: when Plan [LK](LK-reading-mail-the-decision.md) decides how mail arrives, a coupon email becomes
  one more source of the same `CouponReader` input (barcode image attachments and HTML text). Nothing in
  this plan reads mail.

## What LF leaves out

Coupon discovery, deal hunting and clipping digital coupons on store accounts. Loyalty cards (they are the
same shape, and could join later, decision 8). Payment cards, gift-card balances and anything with a PIN or
a stored value. Apple Wallet passes (decision 4). Defeating single-use: the app shows the wearer's own coupon
and marks it used when told, nothing more. Sharing coupons with another person.

## Decisions for Greig (open)

Recommendations first.

1. **Its own small store, built to FH's record contract** (review before save, typed id, undo), rather than
   waiting for FH P3. When FH lands, "handle this" over a coupon proposes `coupons save`.
2. **Symbologies in v1:** the table in §3. GS1 DataBar is stored and shown as a number, not drawn. Revisit
   if real coupons in the pilot use DataBar. US manufacturer coupons do; store coupons mostly use
   Code 128, Code 39 or UPC.
3. **The watch shows the list and 1D bars**, labelled as best-effort. The phone is the scanning surface.
4. **No Apple Wallet passes.** A pass has to be signed with a pass-type certificate. The signing key cannot
   ship inside the app, so passes would need a server we run, and the product has none.
5. **Keep the filtered photo by default**, with a switch on the save sheet. The terms and the
   printed design help at the till, and the picture is the wearer's own coupon.
6. **Expiry reminders:** the My Day item always, and one notification the day before **off by default**.
7. **Backup: included**, like saved places and notes. It is the wearer's own record, and a new phone
   should still have the coupons.
8. **Loyalty cards later**, as a `kind` on the same record, after the device pass shows tills read the
   screen.

## Phases (one PR each)

### P0 — the pure core (headless)

- `Coupon`, `CouponCode`, `CouponSymbology`, `GTINCheckDigit`, `CouponReader` (barcode-first rule, code-line
  search, store, offer and expiry parsing, the "must be original" list), `BarcodeEncoder` for the ✅ 1D
  symbologies, and the wording for every result.
- **Exit tests:** published vectors per symbology; an encode → rasterise → Vision decode round-trip per
  symbology on the simulator; leading zeros kept; a bad EAN check digit refused for drawing; expiry fixtures
  (no year, two dates, a day-first locale, none at all → no expiry); two decoded payloads → a choice;
  "void if copied" found; an unsupported language sets nothing.

### P1 — save, list and show on the phone (headless, wired)

- The `coupons` tool with its confirmation and `localMutation` effect, `CouponStore` and its registry entry,
  roster entries `couponCapture` and `couponPhonePhoto`, `scan_code`'s detection factored so both tools share
  one typed observation (and DataBar named), the Coupons screen, the till view with brightness and
  auto-lock restored, and used/undo/purge.

### P2 — more ways in (headless)

- Phone camera and library on the Coupons screen. Images in the Share extension through an app-group inbox,
  with its activation rule extended and the teleprompter path for text unchanged.

### P3 — reminders and the watch (headless, wired)

- `CouponsDaySource` in My Day, the opt-in day-before notification, the watch payload and Coupons row.

### P4 — email (waits for Plan LK)

- Coupon emails as a `CouponReader` source, in whatever form LK decides. Not started until LK is decided.

### P5 — device pass (owed)

- Five real coupons from different stores: read from glasses and phone, drawn, and **scanned at a real
  till** (camera scanner and, where one can be found, a laser scanner). Watch at a till. Till view legibility
  in sunlight. VoiceOver over the list and the till view.

## Acceptance

- A coupon read from the glasses is saved only after "yes", and its number is read back first.
- Every drawn barcode decodes, through Vision in tests and at a till on device, to exactly the stored payload.
- Nothing invents a store, an expiry or a digit. Missing ones are said as missing.
- Closing the till view always restores brightness and auto-lock.

## Risks

- **A till that won't read a screen.** Said plainly in the till view. The device pass measures how common
  it is before loyalty cards are added.
- **A misread digit draws a valid-looking wrong barcode.** The check digit catches most of these for EAN and
  UPC. Code 128 and Code 39 have no check digit the wearer can see, which is why the number is read back
  and confirmed on every save.
- **Store policy.** Some coupons are not valid as a copy. The banner and the terms keep this visible, and
  the wearer decides.
