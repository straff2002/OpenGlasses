# Plan IS — Refrigerant Toolkit (gauges to an answer, full P-T tables, refrigerant-rule flags, a door-sticker diagram)

**Status:** 🚧 **P0 and P1 built 2026-10-19** — saturation tables generated with CoolProp 8.0.0 (pinned in
`Scripts/generate-pt-tables.py`, run by hand): 13 bundled tables (the planned twelve plus R-454B, which
CoolProp defines as a predefined mixture), dew and bubble series on the −40…150 °F (1 °F) and −40…65 °C
(0.5 °C) grids, absolute kPa; pure `SaturationTable`, `Atmosphere` (ISA altitude correction) and
`RefrigerantPressure`; `domain_calc` reads them (superheat on dew, subcool on bubble, glide, the source
line and the sea-level line; psig/°F or kPa/bar with °C); `pt_charts.md` reduced to a pointer; CoolProp in
Settings › About › Attributions. **P1 built 2026-10-19:** `refrigerant_gauges` takes one still of the manifold or
digital gauge set through `CameraService.filteredStill(for: .visionAssessment, …)` (roster entry
`refrigerantGaugeReading`), reads it with `instrument_reading` (which now reports each display's printed `label` and
bezel or hose `color`; safety corpus bumped to 1.1.0 with a labelled-manifold case), and files the same filtered
bytes on the open job as its photo. The pure `GaugeRoleResolver` assigns suction, liquid and discharge from a printed
role word, then LOW/HIGH (HIGH is the high side, taken as the liquid line and said as "high side"), then blue/red; the
technician's answer outranks them, and a role it cannot tell, or cues that disagree, are asked ("Is the left gauge
(118 psig) suction?"), never guessed. The line temperature is a probe in the frame or what the technician says. The
pure `RefrigerantGaugeChain` runs the `domain_calc` lookup (now shared as `RefrigerantLineCalculation`) in SI and
renders in the technician's units ("Superheat 10.2 °F: suction 118 psig is 39.8 °F dew for R-410A, line 50 °F" /
"Superheat 5.4 K: suction 820 kPa is 4.6 °C dew for R-410A, line 10 °C"). The refrigerant comes from the technician or
the job's recorded nameplate field; without one the answer is pressures only and asks. `InstrumentPlausibility` gains
per-refrigerant bands: a saturation-temperature window per line and application (cooling, heating, refrigeration,
unspecified) converted through the P0 table on that line's curve, held in kelvin and kPa absolute, so a 30 psig
"suction" on R-410A in cooling asks for a re-look. Each reading is recorded as a `SpokenReading` with method
`instrument_reading`, the job photo id, and the refrigerant and its source, once per photo. `refrigerationUnits`
(pressure kPa/bar/psi, temperature °C/°F, mass kg/lb) is in Settings › Field Assist, defaulting by storefront (AU and
NZ kPa, °C, kg; CA psig, °F, kg; elsewhere psig, °F, lb), and is an organisation-profile starting value
(`refrigerationUnits`, `"kPa,C,kg"`). `organizationJurisdiction` is deferred to P2, where it first decides something.
`domain_calc` keeps its own unit rule (psig answers in °F, kPa/bar in °C). Owed: a device pass reading a real manifold
and digital set; a catalog sync for the new strings. **Trade presets 2026-10-19:** refrigeration tiles for the gauge
reader and P-T lookup — a `FieldTrade` (`refrigeration_hvac`, `electrical`) chosen by the technician in Settings ›
Field Assist › Trade, else the organisation profile's `fieldAssistDefaultTrades`, else the default vault manifest's
optional `trades`, else none; the refrigeration preset adds Read Gauges (`refrigerant_gauges`, phone camera first
without glasses) and P-T Lookup (`domain_calc` `pt_lookup`) after the job tiles, injected and never persisted; the
electrical preset has no tiles yet (Plans IN and IR); the refrigerant log tile waits for P2. The trade also gates
(`FieldTradeGate`): once a trade is active, another trade's tools are not offered to the model — `refrigerant_gauges`
and `domain_calc` (all three of its operations are refrigeration) are tagged refrigeration — the prompt's routing
rules and the router answer a refrigeration request with a redirect to the setting, and Settings › Field Assist shows
Refrigeration Units only with Refrigeration on; no trade set, or an empty choice, leaves every tool and section as it
was, and the general job tools and tiles are never gated. **Trade rows 2026-11-05:** Settings › Field Assist ›
Trades is one collapsible row per trade, holding its switch, what it adds and its own settings (Refrigeration Units
now sit inside the Refrigeration & HVAC row, under the same gate); the technician's trades — on in the selection, or
declared by a vault they can open, the bundled refrigeration vault implying its trade for layout only — come first
and open on arrival, the rest start collapsed (pure `FieldTradeAccordion`, `FieldTradeAccordionTests`). A voice fallback rides
with it: the gauge reader's no-picture and unusable-reading lines offer to take the values by voice, and a spoken
superheat or subcool in `domain_calc` gets the same per-refrigerant band check and is recorded on the open job.
P2–P6 not started. Drafted 2026-10-17, P4–P6 added the same day. The EPA 608 reference was corrected
separately, in [#753](https://github.com/straff2002/OpenGlasses/pull/753). **Amended 2026-10-19
([below](#amendment-2026-10-19-canada-australia-and-new-zealand-first)):** Canada, Australia and New Zealand rules come
first and the US EPA 608 flags become a deferred phase (P2-US); metric units are first-class throughout.
**Track:** Field Assist (B2B), HVAC/R.
**Related:** Plan [structured vision](structured-vision-assessment.md) (AD: `instrument_reading`,
`InstrumentPlausibility`), Plan [GB](GB-field-test-round-3.md) P3 (`SpokenReading`), Plan
[EL](EL-equipment-identity.md) (equipment identity from the nameplate), Plan
[HU](HU-service-history-and-maintenance-flags.md) (the office's history by serial), Plan
[IF](IF-photographed-manuals.md) (`manual_capture`), Plan [IR](IR-test-sheets-from-a-photo.md) (the
electrical sibling: readings from a photo, limits only from a loaded source), Plan
[IQ](IQ-closeout-unknown-units-and-calling-base.md) (close-out), Plan
[IP](IP-organisation-feature-switches.md) (organisation switches).
**Origin:** The October 2026 competitor review. A new HVAC voice copilot markets gauge reading,
P-T charts, wiring diagrams and EPA 608 flags. We build our own versions, from public property
data and the regulation text, and copy none of theirs. Checking our own EPA 608 file for this plan
found it wrong. That fix is #753.

---

## Verified starting point (`main` @ `300047438`, 2026-10-17)

- **Superheat and subcooling exist, from a small table.** `domain_calc` (`DomainCalcTool`) does
  `pt_lookup`, `superheat` and `subcool` by linear interpolation over anchor points kept identical
  to the vault's `pt_charts.md`. That covers four refrigerants (R-410A, R-32, R-454B, R-22) at 8–12
  points each, single column (°F at psig). There is no dew/bubble distinction. Superheat should use
  the dew point and subcooling the bubble point, which matters for blends with glide (R-407C,
  R-448A, R-449A; R-454B a little). Any other refrigerant is refused: "No PT data for…".
- **The camera reads several gauges at once.** `vision_assess kind:"instrument_reading"` returns a
  `readings` array (quantity, instrument, value, unit, confidence, region). `UnitNormalizer` handles
  psi, kPa, bar, inHg and °F/°C. `InstrumentPlausibility` holds bands per quantity, and an
  implausible reading asks for a re-capture. A reading can fill a capture-flow step. Nothing chains
  a gauge reading into `domain_calc`, and nothing tells suction from liquid.
- **Refrigerant quantities are not tracked.** Nothing in `Services/FieldAssist` records
  refrigerant added or recovered, a unit's full charge, or a leak rate. EPA 608 exists only as
  vault text (`epa_608.md`), cited by the leak-check and start-up procedures' safety notes.
- **Wiring diagrams come from manuals.** A diagram passage in a loaded manual is staged and shown
  (`FigureAutoOpenPolicy`, `ManualFigureSheet`). A diagram printed inside a unit's panel door is
  only reachable by photographing it as a one-off or as a captured manual (`manual_capture`, built).
- **Equipment identity has the nameplate text.** `EquipmentIdentity.nameplateText` is kept on
  device. Nameplates usually print the refrigerant and the factory charge, which `equipment_lookup`
  does not yet extract as fields.

## Decisions proposed (owner to confirm)

1. **P-T data is generated from an open property library, not copied from anyone's chart.** A
   script runs CoolProp (MIT licence) offline at a pinned version and writes saturation tables
   (dew and bubble, 1 °F steps, psig at sea level) into the bundle. *(Amended 2026-10-19: both a °C and
   a °F grid, pressures stored absolute — see the amendment's "Metric is first-class".)* Property data are facts, but
   the source matters: an equation of state is citable and reproducible. Blends CoolProp does not
   define (R-454B, R-448A, R-449A may be among them) are added only from a published
   manufacturer table, with that table cited, or not at all. Every table carries its source line.
2. **The tool, not the prompt, is the authority.** The full tables live in a resource the tool
   reads, never in the vault's prompt core. `pt_charts.md` shrinks to a short note pointing at
   `domain_calc`, which saves prompt characters on every refrigeration turn. Every number spoken
   carries its source ("CoolProp 6.x, dew point").
3. **The refrigerant is never assumed.** It comes from the nameplate (identity), from the
   technician, or from a question. A gauge reading without a refrigerant gives pressures, not
   saturation temperatures.
4. **EPA flags inform; they never accuse or block.** Leak repair is the owner's duty under the
   rules. The app says what the rules say for this unit and records it: the applicable rule, the
   evacuation level, the leak rate and the threshold. It never stops a job, and it never tells a
   customer they are in breach.
5. ~~**EPA flags are US-only.** They follow the organisation's jurisdiction (a CT profile key,
   `organizationJurisdiction`, defaulting to the store region for a solo technician). Canada
   (federal halocarbon regulations and provincial rules), Australia and New Zealand have their own
   refrigerant rules, out of scope until someone asks.~~ **Replaced 2026-10-19** by the amendment's
   decision 5: flags follow the jurisdiction, Canada, Australia and New Zealand come first, and the US
   is deferred. Decision 4 applies to every jurisdiction's flags, not only the EPA's.

## Phases (one PR each)

### P0 — Saturation tables, generated and checked

- `Scripts/generate-pt-tables.py` (CoolProp pinned; run by hand, output committed):
  `Resources/Refrigerants/<designation>.json` with `dew` and `bubble` arrays from −40 °F to 150 °F
  in 1 °F steps *(and a −40 °C to 65 °C grid in 0.5 °C steps, pressures absolute: amendment 2026-10-19)*, `source`, `generatedWith` and the library version. The first set: R-22, R-32,
  R-134a, R-404A, R-407A, R-407C, R-410A, R-507A, R-290, R-600a, R-744 (to its critical point) and
  R-1234yf. Then any blend with a cited manufacturer table (decision 1).
- `SaturationTable` (pure): psig ↔ °F for dew and bubble, interpolated, refusing out of range by
  name. `domain_calc` reads it. `superheat` uses dew, `subcool` uses bubble, and the answer says
  which and how much glide there is. `pt_charts.md` is reduced (decision 2), and the anchor points
  move into a test.
- Altitude: psig assumes sea-level atmospheric pressure. The answer says so, and an optional
  `altitude_ft` corrects it.
- **Exit tests:** every table's points against CoolProp's own values at a dozen temperatures; the
  four old anchor tables within ±1 °F (or the difference explained in the test); glide
  correct for R-407C (≈ 10 °F) and zero for R-410A within tolerance; licence and attribution in
  the third-party notices.

### P1 — Gauges to an answer, in one step

- "What's my superheat?" with the camera on the manifold or a digital gauge set:
  `instrument_reading` returns the readings, and a pure `GaugeRoleResolver` assigns suction, liquid
  and discharge from the instrument's own labels (LOW/HIGH, blue/red where the model reports
  them, "suction"/"liquid" on digital units). The line temperature comes from a probe reading in
  the same frame or by voice. `domain_calc` runs, and the answer is "Superheat 11 °F: suction
  118 psig is 39 °F dew for R-410A, line 50 °F."
- Each reading is recorded as a `SpokenReading`-shaped entry with method `instrument_reading`, the
  photo id, and the refrigerant and its source. `InstrumentPlausibility` gains per-refrigerant
  pressure bands, so a 30 psig "suction" on an R-410A system in cooling asks for a re-look instead
  of a confident answer.
- A role it cannot tell is asked: "Is the left gauge suction?" It is never guessed.
- **Exit tests:** role resolution over fixture readings (analog manifold, digital manifold, a
  single gauge); the chain to superheat and subcool; refrigerant missing → pressures only;
  out-of-band → re-capture line.

### P2-US (deferred) — EPA 608 flags (US)

*(Relabelled 2026-10-19. The `refrigerant` tool in the first bullet is now the jurisdiction-neutral
log of the amendment's P2, in kilograms as well as pounds; the `EPA608Policy` and its flags below
are unchanged in substance and ship later, as one more policy behind the same log.)*

- `refrigerant` tool: `added`, `recovered`, `charge`. Each entry has a quantity (lb/oz), the
  refrigerant and an optional cylinder, bound to the unit and the task. The unit's full charge comes
  from the nameplate (identity extraction gains `refrigerant` and `factory_charge`) or from the
  technician. The appliance category (comfort cooling, commercial refrigeration, industrial
  process, residential or light commercial AC) is asked once per unit.
- `EPA608Policy` (pure, from §§ 82.152, 82.156, 82.157 and 84.106 as of October 2026):
  - which rule applies, if any: 82.157 (ODS, ≥ 50 lb), 84.106 (HFC or substitute with GWP > 53,
    ≥ 15 lb, not residential or light commercial AC), or neither;
  - the pressure class and the Table 1 evacuation level;
  - the leak rate by the annualizing method. The last addition's date comes from this phone's
    history or the office's (HU). The first calculation after 1 January 2026 uses 365 days, as the
    rule says. With neither, the rate is shown as unknown, not assumed;
  - the threshold (20 / 30 / 10%) and whether it is exceeded.
- Flags, spoken once and recorded on the work order:
  - "before opening: recover to 10 in Hg" when a procedure step's safety note opens the circuit;
  - "this addition puts the leak rate at about 34%, over the 10% comfort-cooling threshold: the
    owner has 30 days to repair" when refrigerant is added;
  - the owner documentation of refrigerant added or removed, on the work order (84.106(b)).
  Decision 4 governs the wording.
- **Exit tests:** the policy table for a dozen units (R-22 60 lb comfort cooling; R-410A 20 lb
  rooftop; R-410A residential split, which is exempt; R-404A 40 lb walk-in; R-290 self-contained,
  which is not covered; and others); the annualizing calculation and its first-time rule; "unknown"
  when no history exists; jurisdiction other than US → no EPA flags; the wording guard (no
  "violation", "illegal", "fine").

### P3 — A wiring diagram from the unit's door

- "Photograph the wiring diagram" captures the panel-door sticker as a one-page, job-scoped capture
  (`manual_capture`, kind diagram, bound to the unit). It opens in the figure viewer and is attached
  to the next turns as an image, so "what does the black wire on terminal 4 go to?" is answered
  from the sticker, with "from the diagram you photographed" as the source.
- Captured diagrams travel with the job like other captures and may be offered to the office for
  that model (IF's review).
- **Exit tests:** capture scoped to the unit and the job; the source line; nothing kept after the
  job unless the office approves it.

### P4 — Superheat and subcooling read together, and the other calculations

*(Added 2026-10-17 from a review of the topics HVAC technicians look up most.)*

- `RefrigerantCircuitDiagnosis` (pure): given superheat and subcooling (and, where known, suction
  and head pressure, metering type TXV/EEV or fixed orifice, and the evaporator's airflow), it
  returns the quadrant and the vault's candidate causes in order. The quadrants are high or low
  superheat crossed with high or low subcooling, plus normal. Each cause carries the next
  measurement that tells it from its neighbours. `domain_calc` appends it whenever it has computed
  both numbers.
  It never names one cause as *the* fault. It says "points to", lists the alternatives, and names
  the check that would decide.
- The table of quadrants and causes is vault content (`superheat_subcool.md`), not code, so a
  partner or an organisation can correct it. The vault-content review that started this phase
  rewrites that table from cited sources.
- New `domain_calc` operations, each with its formula and source in the answer:
  - `target_superheat` (fixed orifice): from indoor wet bulb and outdoor dry bulb, by the
    manufacturer's chart where the vault carries it. A generic chart is used only if a cited,
    redistributable one is found, and the answer says which.
  - `condensing_split`: saturated condensing temperature from head pressure (P0's bubble
    point), minus outdoor air temperature, compared with the unit's design split when the vault
    has it.
  - `delta_t`: return minus supply air temperature, judged against a target only from the
    manufacturer's data or a calculation from the sensible heat ratio and airflow, never against
    a fixed 20 °F.
- **Exit tests:** every quadrant with TXV and fixed-orifice variants; "unknown metering type" asks;
  the calculations against worked examples; no fixed delta-T target anywhere in the output.

### P5 — More instrument readings

- `UnitNormalizer` and `InstrumentPlausibility` gain microns (vacuum), inches of water column
  (static pressure), microamps (flame rectification), microfarads (capacitance, judged against
  the rated value and its printed tolerance) and ppm (CO, from a combustion analyser).
- An evacuation reading sequence: the micron reading at isolation, then again after a timed
  standing period, judged against the procedure's own pass figure (the vault's, never a number the
  model supplies).
- A CO reading above the vault's action threshold is a safety flag, spoken at once and recorded,
  like the vault's other safety reminders.
- **Exit tests:** normaliser corpus ("500 microns", "0.5 in wc", "2.1 µA", "45/5 µF", "CO 120
  ppm"); capacitor tolerance; the decay sequence; the CO flag.

### P6 — A starter set of diagnostic procedures

- New bundled procedures for the refrigeration vault, written by us and reviewed by a working HVAC
  technician before they ship. None are copied from anyone's articles, and each cites the vault
  files it uses:
  - evacuation and vacuum decay test;
  - run capacitor test (bench and under load);
  - flame sensor (microamps first, then clean);
  - contactor test;
  - control board inputs and outputs, before replacement;
  - short cycling;
  - frozen evaporator coil;
  - heat pump defrost;
  - thermostat wiring and the C wire.
- Each uses P4's and P5's readings and calculations where they fit, and ends in the work record
  like today's procedures.
- **Exit tests:** every procedure passes `validateProcedureGraph`; every step that opens the
  refrigerant circuit carries the recovery safety note; every citation resolves to a vault file.

## Acceptance

- With the camera on a manifold on an R-410A rooftop unit, "what's my superheat and subcool?" gives
  both numbers with their pressures, saturation temperatures (dew and bubble) and source, in one
  turn.
- An R-407C system's superheat uses the dew point and says the glide.
- *(P2-US, deferred)* Recording "added 4 pounds" on a 20 lb R-410A rooftop unit last topped up in March flags the leak
  rate against 10% and names the 30 days. On a residential split it says the leak-repair rule
  doesn't apply.
- No P-T number is spoken without a source, and no refrigerant is assumed.
- With superheat 22 °F and subcooling 4 °F on a TXV system, the answer names the likely low charge,
  the alternatives, and the check that decides between them.
- "500 microns, then 1,400 after ten minutes" is judged against the evacuation procedure's own
  pass figure and recorded.

## Open questions for the owner

1. ~~Decision 5: the US only at first, or should Canada's federal halocarbon rules come with it for
   the partner's market?~~ **Answered 2026-10-19:** Canada, Australia and New Zealand first; the US
   can wait (see the amendment).
2. Which blends matter most beyond the P0 set? It decides which manufacturer tables to cite
   (decision 1).
3. Should the refrigerant log feed the customer close-out (Plan IQ), for example "4 lb R-410A added"
   (or "1.8 kg"), or stay on the organisation's work order only?
4. ~~Which Canadian provinces first?~~ **Answered 2026-10-19:** Manitoba first (the first
   organisation is in Manitoba), then Ontario and British Columbia. The amendment recommends
   Saskatchewan and Alberta next, then Quebec once its text is read, then Newfoundland and Labrador
   and Prince Edward Island (see "Recommended order of provincial policies").
5. Should licence and certificate numbers go on the work order: the Manitoba trained service
   technician certificate number and expiry (it lapses every June 1), the Ontario certificate
   number and expiry, the BC registration number, the federal certificate number, the Australian
   refrigerant handling licence and trading authorisation numbers, the New Zealand approved filler
   certificate? The rules name them as fields, but the app would then hold them in the
   technician's profile.
6. Should the app draft the notice text the technician writes on the equipment (Manitoba's
   recharge label, Ontario's leak test notice, BC's label or tag, the federal withdrawal notice),
   or only list the fields?
7. Canada's default units: the amendment proposes °F and psig for gauge work and kilograms for the
   log, as a setting. Does the partner's crew work that way?
8. Is a Canadian site's federal status asked per site, or set once for the organisation (a crew
   that works on federal sites or First Nations reserve lands)?
9. Does the Manitoba organisation work outside Manitoba (Saskatchewan, northwestern Ontario,
   Nunavut)? If so, the province should be a fact of the site, like `federalSite`, with the
   organisation's province as the default, rather than one profile key.
10. Manitoba wants a leak test before every charge and a yearly summary to the minister by
    February 1. Should "added" prompt for the leak test (method and result) when the job has none,
    and should the office get a January export of the year's log shaped for the summary? Who
    files it in the organisation: each technician or the office?
11. Manitoba's recharge label (s. 25(2)) and record copy for the owner (s. 8(1)(b)): should the
    work order's customer copy double as the owner's copy of the record?
12. For BC's Schedule B lookup, is asking each recovery machine's purchase date once acceptable,
    or should the lookup show both columns?
13. Pure HFOs in the open-ended Canadian lists stay out of scope with a note. Should the
    organisation ask the Manitoba department (or ECCC for federal sites) for a written answer, so
    the note can be replaced by a rule?


---

## Amendment 2026-10-19: Canada, Australia and New Zealand first

The owner's direction, 2026-10-19: Canada, New Zealand and Australian rules first; the USA can
wait. Decision 5 is reversed, P2 is rebuilt around a jurisdiction-neutral log with one pure policy
per jurisdiction, and metric units become first-class in every phase that shows a number. Status is
unchanged: 📝 drafted, nothing built. P3, P6 and the rest of P0, P1, P4 and P5 stand as written,
apart from the unit changes below.

What was checked on `main` @ `e364e24bd` (2026-10-19): `organizationJurisdiction` does not exist
in code or in the CT plan yet. It is proposed here as a new CT profile key. `DomainCalcTool` knows
only °F and psig. `StorefrontReader` (Plan HP) already reads the App Store country as ISO 3166-1
alpha-2, and that is the solo technician's default.

**One correction to the brief:** the Federal Halocarbon Regulations, 2003 (SOR/2003-289) are
repealed. The **Federal Halocarbon Regulations, 2022** (SOR/2022-110, registered 2022-05-20,
s. 29 repeals the 2003 text) replace them, with the same scope. Everything below cites the 2022
text.

### Decision 5 (replaced)

5. **Flags follow the jurisdiction. Canada, Australia and New Zealand come first, and the US is
   deferred.**
   - The jurisdiction comes from `organizationJurisdiction` (a CT profile key, ISO 3166-1 alpha-2,
     with an ISO 3166-2 subdivision for Canada: `CA-MB`, `CA-ON`, `CA-BC`, `CA-SK`, `CA-AB`,
     `CA-QC`, …).
     A solo technician without a profile defaults to the storefront country (`StorefrontReader`).
     A storefront of `CA` has no province, so the province is asked once and kept as a setting.
   - Canada has two layers, and which one applies is a fact about the site, not the province. The
     federal regulations apply to systems owned by the federal Crown, a federal board, agency or
     Crown corporation, or a federal work or undertaking, and to systems on federal lands or
     Aboriginal lands (SOR/2022-110 s. 2). Most residential and commercial work is under the
     province's rules instead. So a Canadian site carries `federalSite: Bool?`, asked once per site
     ("Is this a federal site or on reserve land?"). When it is unanswered, the provincial policy
     runs and the answer carries one line: "If this is a federal site, other rules apply."
   - First policies: Canada federal; **Manitoba first among the provinces** (owner direction,
     2026-10-19: the first organisation is in Manitoba), then Ontario and British Columbia, then
     Saskatchewan and Alberta together (each is a short table). Quebec comes after them, once its
     official text has been read (see Unconfirmed). Newfoundland and Labrador and Prince Edward
     Island are worth a policy later; Nova Scotia, New Brunswick and the territories are not
     modelled now (see "Other provinces and territories, assessed"). Australia. New Zealand.
   - The US EPA 608 policy is P2-US (deferred), unchanged in substance.
   - **A unit or site with no known jurisdiction gets no regulatory flags**, only the calculations
     and the neutral log. The same holds for a jurisdiction with no policy yet (the US until P2-US,
     any province or territory without a policy table, any other country). An unmodelled province
     gets the calculations only. The answer never guesses a neighbouring jurisdiction's rules,
     even where two provinces' rules are close.
   - A policy only speaks about refrigerants inside its own scope. Each policy's scope table says
     which designations it covers, and every policy below leaves out R-290, R-600a, R-1270, R-744 and
     R-717 for its halocarbon duties (they are not halocarbons). Pure HFOs (R-1234yf, R-1234ze(E))
     are out of scope where the instrument lists substances and does not list them (Australia, New
     Zealand). They are marked unconfirmed for Canada federal, where the schedule names the class
     "Hydrofluorocarbons (HFC)" without a list, and for the provinces whose lists end with "all
     other" or "any" hydrofluorocarbon (Manitoba, Ontario, BC, Saskatchewan, Prince Edward Island).
     Alberta's and Newfoundland and Labrador's HFC schedules are closed lists of saturated HFCs,
     so a pure HFO is out of scope there. Blends are in scope wherever one component is:
     every instrument here covers a listed substance "alone or in a mixture", or says the same in
     other words. That puts R-454B (R-32 with R-1234yf) in scope everywhere.

Decision 4 applies to every policy: flags inform and never accuse or block, and they never tell a
customer they are in breach. The duty belongs to whoever the rule names: technician, owner or
business. The flag says whose it is.

### Metric is first-class

- **P0 tables, both unit sets.** The generator writes two temperature grids per refrigerant, each
  computed directly by CoolProp rather than converted from the other: −40 °F to 150 °F in 1 °F
  steps (191 points, as before) and −40 °C to 65 °C in 0.5 °C steps (211 points). Pressures are
  stored **absolute, in kPa**, to 0.01 kPa. Gauge values are derived at read time:
  `P(g) = P(abs) − P(atm)`, and the output is shown in kPa(g), bar(g) or psig. The tables carry
  no gauge column, so there is one source and no sea-level value baked in.
- **Atmospheric pressure and altitude.** A gauge reads relative to local atmosphere. A sea-level
  chart is wrong at altitude because the chart, not the gauge, assumed 101.325 kPa. The answer says
  "assuming sea level" unless it has an altitude (`altitude_m` or `altitude_ft`). With an altitude it
  uses the ISA barometric formula, `P(atm) = 101.325 × (1 − 2.25577×10⁻⁵ × h)^5.25588` kPa with h
  in metres. A reading the instrument reports as absolute (kPa abs, bar abs, psia) skips the
  correction. The P0 altitude bullet stands, now in either unit.
- **No change to the CoolProp decision.** Decision 1 needs only the second grid and absolute
  storage. Same library, same pinned version, same source line. The anchor-point test checks the
  old °F/psig anchors against the °F grid converted to psig at 101.325 kPa.
- **P1 and P4 accept and speak either.** Inputs are normalised to SI (kPa abs, K) inside the
  calculation, and the answer is rendered in the technician's units: "Superheat 6 K: suction
  820 kPa is 4 °C dew for R-410A, line 10 °C" or the existing °F sentence. A temperature difference
  is shown as K (metric) or °F (imperial) and spoken as "degrees". `InstrumentPlausibility`'s
  per-refrigerant bands are stored in SI. P4's `delta_t` and `condensing_split` follow suit. A
  manufacturer's target-superheat chart in °F is converted for display and cited as printed.
- **P5 gains metric vacuum units:** Pa and mbar next to microns, and `UnitNormalizer` learns
  "67 Pa" and "0.67 mbar" (≈ 500 microns). Static pressure in Pa as well as in. w.c.
- **Defaults by jurisdiction, always a setting.** `refrigerationUnits` holds pressure (kPa / bar /
  psi), temperature (°C / °F) and mass (kg / lb). An organisation profile can set the default.
  Defaults: Australia and New Zealand use kPa, °C and kg. Canada uses psig and °F for gauge work
  and kg for the log. The Canadian rules state quantities in kilograms (SOR/2022-110 Sch. 2 Part 5;
  Manitoba, Ontario and BC set their thresholds in kilograms but ask for record amounts without
  units), and US-built equipment and gauge sets dominate. What
  Canadian technicians actually use day to day is **unconfirmed** by any official source, so it is
  open question 7. The US uses psig, °F and lb/oz.
- **Log quantities.** The log stores grams as an integer and accepts "1.8 kg", "1800 g", "4 lb" and
  "4 lb 6 oz" (1 lb = 0.45359237 kg exactly, 1 oz = 28.349523125 g). Records show kilograms to two
  decimals where a rule asks for kilograms, next to the quantity as it was said.

### P2 (restructured) — refrigerant log and jurisdiction policies

**The log (jurisdiction-neutral; the old P2's first bullet, kept).** The `refrigerant` tool records
`added`, `recovered` and `charge`, plus `leak_test` (date, result, method) and `released` (an
estimate, with a reason). Entries are bound to the unit and the task, with an optional cylinder.
The unit's facts:

- refrigerant and **design refrigerant** (from the nameplate or compliance plate via identity
  extraction, or from the technician; Australia and New Zealand turn on the difference);
- full charge, **per circuit** where there is more than one (the Canadian federal size test is per
  circuit);
- equipment kind (split or ducted AC or heat pump, rooftop, chiller, commercial refrigeration,
  commercial stand-alone, domestic appliance, vehicle AC), asked once per unit;
- for Canada, the site's `federalSite`.

The technician's profile can hold licence and certificate numbers (open question 5).

**The policies.** There is one pure, table-driven function per jurisdiction:
`(RefrigerantUnitFacts, [RefrigerantLogEntry], RefrigerantEvent, today) → [RefrigerantRuleFlag]`.
A `RefrigerantJurisdictionResolver` (pure) picks the policy from the profile key, the storefront and
the site. Each flag carries its kind (licence, recovery, charging precondition, leak deadline, leak
test due, record fields, notice, flammable, report), the person whose duty it is, any due date, and
a citation (instrument, section, as-at date). The facts live in a per-jurisdiction table with
their citations, so a rule change is a data change with a test. A flag is spoken once per job and
written to the work order. The events are: opening a circuit (a procedure step with the recovery
safety note), adding, recovering, a leak test, a recorded release, and decommissioning.

#### `CanadaFederalHalocarbonPolicy` — SOR/2022-110 (current to 2026-09-30)

Scope: air-conditioning or refrigeration systems (compressor, condenser, evaporator and expansion
valve, containing a halocarbon refrigerant) on a federal site. Halocarbons are Schedule 1 (CFCs,
HCFCs, HFCs, PFCs, halons and others), "whether existing alone or in a mixture" (s. 1). A system is
**large** if any circuit contains or is designed to contain more than 10 kg, and **small** otherwise
(s. 1).

| Event | Flag | Source |
|---|---|---|
| Any work | Only a certified person may install, service or recover. That means a provincially recognised environmental-awareness certificate plus trade recognition. The work order carries the certificate number. | ss. 1, 14; Sch. 2 Pt 5 item 8(e) |
| Opening a circuit | Recover into a container designed for that halocarbon; no release. | ss. 3(1), 15(1), 6 |
| Adding | Charging needs a previous leak test, and any leak found must have been reported to the owner and repaired. If the log has no leak test, or has an unrepaired leak, the flag says so. Charging for a leak test is not allowed. | ss. 9, 10 |
| Adding to prevent immediate danger | Allowed while the danger lasts. The owner must be told at once, and the owner reports to the Minister within 7 days. | s. 11 |
| Leak found | Repair it, isolate the leaking part and recover, or recover the system, as soon as possible and within 7 days. The flag names the date. | s. 18 |
| Large system, any visit | A leak test is due at least once every calendar year and no more than 15 months after the last one. The flag reads the log or the office's history (HU) and says when the next one is due; with no history it says the date is unknown. | s. 17 |
| Any service | Activity log fields go on the work order, in kilograms: equipment type, owner name and address, responsible person, location, serial or owner's identifier, halocarbon type, charging capacity (kg), date, activity type, description, technician and employer, certificate number, kg recovered, and type and kg charged. A large system logs installation, service, withdrawal and transfer of ownership; a small system logs each service. The owner keeps it for 5 years. | s. 23; Sch. 2 Pt 5; s. 26 |
| Decommissioning | Recover everything first, and fix a notice to the system: owner, location, identifier, halocarbon type and kg recovered, charging capacity, technician, employer and certificate number. | s. 16; Sch. 2 Pt 2 |
| Release recorded | 100 kg or more: the owner reports within 24 hours and in writing within 30 days. More than 10 kg and under 100 kg: the owner reports by 31 July (January to June releases) or by 31 January (July to December releases). | ss. 24, 25 |

There is no leak-rate threshold in the federal rules, so the policy computes none.

#### `CanadaProvincialHalocarbonPolicy` — Manitoba first, then Ontario and British Columbia, then Saskatchewan, Alberta and Quebec

One pure policy with one facts table per province, keyed by the ISO 3166-2 code. Manitoba comes
first because the first organisation is in Manitoba. Ontario and BC come next, as before: both
reach HFCs as well as ODS, both set a leak-test-before-charging rule, and both set record fields a
work order can carry. Manitoba is close to them in shape: a trained-technician rule, a leak test
before every charge, a label on recharge and a record per job. Its leak rule is stricter than
the others (repair or recover at once, with no grace period), and it adds an annual summary. A
province without a table gets the calculations and the neutral log only.

**Manitoba (`CA-MB`) — M.R. 103/94, Ozone Depleting Substances and Other Halocarbons Regulation.**
Made under **The Ozone Depleting Substances Act, C.C.S.M. c. O80** (not The Environment Act, as
the brief had it). Manitoba Laws consolidation: in effect since 2005-12-09, last amendment
M.R. 178/2005, stated by the site to be the most current version on 2026-10-19. The HTML
consolidation is unofficial; the bilingual PDF on the same site is the official copy.

Scope. "Air conditioning equipment" is any air cooling, **heating** or dehumidifying unit or
system, mobile or stationary, so heat pumps are in scope. "Refrigeration equipment" is any
refrigeration unit or system. "White goods" (domestic fridges and freezers, window ACs, plug-in
units such as dehumidifiers) are named separately and are in scope for servicing (s. 1). The
duties attach to Class 1 (CFCs, halons, chlorocarbons), Class 2 (HCFCs) and Class 3 (listed HFCs
"plus all other hydrofluorocarbons", and PFCs), each "whether existing alone or in a mixture"
(Schedule, s. 4). A mixture of an HFC with an HCFC is Class 2, and with a CFC is Class 1 (Schedule
notes). R-410A, R-32, R-134a, R-404A and R-454B are Class 3; R-22 is Class 2. R-290, R-600a,
R-744 and R-717 are not listed. Pure HFOs are unconfirmed, as for the other open-ended lists; one
pointer is that the PFC list names unsaturated compounds (perfluoropropene, hexafluorobutadiene).
**There is no charge-size or capacity trigger for any technician duty.** The only quantities are
the 10 kg release report (s. 24) and a chiller purge limit (s. 15.1).

| Event | Flag | Source |
|---|---|---|
| Any work that installs, repairs or services equipment, or could release a substance (charging, topping up, moving, dismantling, decommissioning, start-up, testing) | Only a **trained service technician** may do it, white goods included. Certification follows a minister-approved course, carries a certification number, and **expires on June 1 of the year after it was issued**; renewal is applied for in the 30 days before expiry. If the profile's certificate date has passed, the flag says so once. Employers and contractors must require it of their staff. | ss. 1 ("service"), 6, 20(1), (3), (4), 26(3) |
| Any such work | Operational recovery equipment that can recover and contain the substance must be **available at the job site**. Recover it and reuse, recycle or reclaim it, or arrange its destruction. AC and refrigeration recovery follows ARI 740-98 (cited by number). | s. 7(1), (3) |
| Opening a circuit, or a release recorded | No release into the environment. Refrigerant in a charging hose shorter than 92 cm (36 in) is excepted. | s. 5(1), (3) |
| Adding (charge, recharge or top up) | **Leak test first**, by the procedure in the MOPIA 1998–1999 Manitoba Compliance Guide (cited by title, as the regulation cites it), and repair any leak found "so that leaking can no longer occur" before adding. The flag reads the job's log: no leak test recorded on this job before the add, or a leak recorded and not repaired, gets the flag. | s. 12(1) |
| Adding for flushing or for leak testing | Not allowed. | s. 11(1)(a), (4) |
| Leak found | **Repair it immediately, or immediately recover the refrigerant and disable the equipment.** There is no grace period, so the flag gives no due date (the federal rule's 7 days does not apply here). | s. 12(2) |
| Recharging labelled equipment | Fix a new label: type and amount used, date, the name of the person or business, and the technician's certificate number. | s. 25(2) |
| Any such work | A record in the minister's approved form: type of equipment and work; date and location; whether a substance was removed, recovered, charged or recharged; the type recovered and recharged, if known; any amount to be stored pending recycling, reclamation or destruction; and the Manitoba location where it will be stored. **Leave a copy with the owner or operator.** An employed technician gives the record to the employer. Kept 3 years. | s. 8(1)–(3) |
| Year end (technician; office reminder) | Before **February 1**, each person who makes the records (the technician) sends the minister a summary of the previous year's records, in the approved form. The log's totals for the calendar year feed it; the flag is an office reminder in January. The minister may appoint a not-for-profit body to receive it instead. | ss. 8(4), 28(3) |
| Release recorded | More than **10 kg**: whoever owns, operates, services or did the work reports it to an environment officer **immediately** after the release. | s. 24 |
| Charging a vehicle AC | No Class 1 or Class 2 substance (so no R-12 or R-22). No Class 1 into mobile refrigeration. | s. 8.2 |
| Decommissioning or disposal | Do not dispose of equipment until the substance is, or will be, recovered (handing it to a recovery program counts). Remove the substance from a vehicle's AC before the vehicle is disposed of. | s. 16 |

Owner duties are few: an owner reports a chiller's decommissioning, replacement or conversion away
from a Class 1 or 2 substance, and the technician's copy of the record satisfies it (s. 8(5)–(6)).
Manitoba sets no periodic leak test and no leak-rate threshold.

**Ontario — O. Reg. 463/10, Ozone Depleting Substances and Other Halocarbons** (re-checked
2026-10-19: consolidation from 2024-08-30, e-Laws currency 2026-10-14, last amendment
O. Reg. 336/24). Scope: "refrigeration equipment" (air conditioning, heat pump, refrigeration or
freezer units, including vehicle AC) with a class 1 or class 2 ODS or a "halocarbon" (listed HFCs
and PFCs, any other HFC or PFC, and mixtures) (s. 1).

| Event | Flag | Source |
|---|---|---|
| Any service or test | Needs an Ontario refrigerant certificate (valid 5 years), and the technician or employer must own, or have a written contract giving immediate access to, recovery equipment. | ss. 22(1), 34(7) |
| Opening a circuit, or a release recorded | No discharge into the environment or within a building. A discharge of 100 kg or more is reported to the Ministry as soon as reasonably possible. | s. 19 |
| Adding | A refill needs the technician's certificate, a **no-leak notice on the equipment no more than six months old**, and no apparent damage. The flag reads the log's last leak test and its result. Filling for the purpose of testing is not allowed (vehicle AC aside). | ss. 22(2)–(3), 25(1) |
| A refill made without all three conditions | **Whenever** a refill is made without the s. 25(1) conditions, whether or not it was an emergency, the owner reports to the Director promptly, has the equipment leak tested and any leak repaired within 7 days, and reports the result with the latest notice. The emergency exception (immediate danger to life or health, or to crops, animals or food at a farm or food facility) only excuses the notice and damage conditions; it does not remove the owner's duties. | s. 25(2)–(3) |
| Charging a vehicle AC | No class 1 or class 2 ODS (so no R-12 or R-22). | s. 21(2) |
| Leak test | Follow the federal code of practice named in the regulation (dated March 1996). Tell the owner the result. Fix a notice to the equipment with the date, name, certificate number and expiry, employer, the result, and, if it leaks, a statement that no refrigerant may be added until the leak is repaired. The notice is not removed except to replace it. | ss. 17, 22(4)–(5), 23(3)–(6) |
| Any service or test | Record refrigerant bought for the job and its supplier; any discharge and why; date, technician and employer; and a description, with amount and type used and type and estimated amount recovered. Name the type by the regulation's own terms. The employer, or a self-employed technician, keeps the records **and a copy of each leak-test notice** for 2 years. | s. 23(1), (2), (7) |
| Determined empty | Fix a "no refrigerant" notice: date, name, certificate number and expiry, employer, statement. Keep a copy for 2 years. Equipment is not dismantled or disposed of without this notice. | ss. 32, 41(1) |

Corrections to the first draft of this table: the s. 25(3) owner duties apply to every refill
made without the s. 25(1) conditions, not only emergency refills; the 2-year retention covers the
leak-test notices as well as the records; and the vehicle AC rule (s. 21(2)) and the disposal rule
(s. 41) were missing.

**British Columbia — B.C. Reg. 387/99, Ozone Depleting Substances and Other Halocarbons Regulation**
(re-checked 2026-10-19: current to 2026-10-13, last amended by B.C. Reg. 171/2025, 2025-10-27).
Scope: Class I and II ODS, and "other halocarbons" (Class III: listed HFCs and PFCs, all others
not listed, and mixtures). **Section 3 extends only some sections to equipment containing other
halocarbons: ss. 4 to 8, 10, 11(2), 12 to 18, 21 and 22.** Section 28 names other halocarbons
itself. So s. 11(1) (no adding for leak testing), s. 9 (sales records) and s. 19 (vehicle AC)
reach ODS only.

| Event | Flag | Source |
|---|---|---|
| Any service | Only an "approved person" may service AC, refrigeration or vehicle AC equipment: trade credentials or an apprenticeship under the Skilled Trades BC Act (or a recognised program, or a year of supervised experience), plus an environmental awareness course approved by Environment Canada and the ministry. Supervised trainees are allowed, and so is decommissioning equipment already tagged as evacuated. The owner must not knowingly use anyone else. | ss. 1, 7 |
| Opening a circuit | No release unless the regulation or its codes allow it. Emissions from an approved person connecting or disconnecting hoses or gauges are not a "release". The recovery device must meet Schedule B. | ss. 1 ("release"), 4(1), 13 |
| Adding | Leak test before charging or recharging (ODS and other halocarbons). Do not add to leaking equipment (applied to HFC equipment through s. 3). **For ODS only** (R-22, R-12), do not add refrigerant for the purpose of leak testing. | ss. 3, 4(3), 11(1)–(2) |
| Evacuating, charging or recharging | Record on a permanent label or tag on the equipment **and** in the service log: leak test results, type and amount added or removed, whether it is now evacuated, the date, and the technician's name and registration number (and the business). The log covers the preceding 36 months, in order, at the service person's normal place of business, and must be shown on request at the premises or electronically. | ss. 10(2)–(3), 12.1 |
| Any service (office) | The business owner keeps a record of each approved employee: name, registration number and the date the course was completed. | s. 8 |
| Disposal | Recover with a device or method meeting Schedule B first, or deliver the equipment to a recognised program. | s. 15 |
| Release recorded | More than 10 kg (carbon tetrachloride over 1 kg, trichloroethane over 5 kg) is reported under the Spill Reporting Regulation. | s. 28 |

Corrections to the first draft: s. 11(1) does not reach HFCs (s. 3 leaves it out), so an R-410A
unit gets no "adding for leak testing" flag in BC; the hose-connection carve-out from "release",
the s. 8 employee record, the s. 12.1 inspection rule and s. 15 disposal were missing.

**BC Schedule B, Table 1 (now read).** Table 1 is a recovery-device performance standard: a
device for that equipment type must be able to pull the system below atmosphere to the level shown
(Sch. B s. 1). Column 2 is for devices bought before 1994-01-01; Column 3 for devices bought on or
after it. Values as printed, in inches of mercury vacuum and micrometres of mercury absolute:

| Equipment type (Column 1) | Before 1994 | On or after 1994 |
|---|---|---|
| Very high pressure equipment, and HCFC-22 appliances with a charge under 23 kg | 0 in Hg / 760,000 µm | 0 in Hg / 760,000 µm |
| High pressure equipment, charge under 23 kg | 4 in Hg / 658,000 µm | 10 in Hg / 506,000 µm |
| High pressure equipment, charge over 23 kg | 4 in Hg / 658,000 µm | 15 in Hg / 379,000 µm |
| Low pressure equipment | 25 in Hg / 125,000 µm | 29 in Hg / 23,000 µm |

The table's own examples: very high pressure is CFC-13, 402, 407, 502 and Halons 1211 and 1301;
high pressure is CFC-12, 114, 401A, 500, HFC-134a (under 23 kg) and CFC-12, 114, 401A, 500,
HCFC-22 (over 23 kg); low pressure is CFC-11 and HCFC-123. Small appliances (household fridges and
freezers, water coolers) must recover at least 90% of the charge, or 80% with no working
compressor, or reach 10 in Hg vacuum (506,000 µm) (Sch. B s. 2). This becomes a lookup the
answer can quote at recovery and disposal, with the device's purchase date asked once per device.
Two gaps stay open (Unconfirmed): which row R-410A, R-32, R-404A and R-454B fall in, since the
table only gives examples; and a charge of exactly 23 kg, which neither row covers.

**Saskatchewan (`CA-SK`) — Halocarbon Control Chapter (E.1.1) of the Saskatchewan Environmental
Code.** The Code's chapters are adopted by The Environmental Management and Protection
(Saskatchewan Environmental Code Adoption) Regulations, RRS c E-10.22 Reg 2, under The
Environmental Management and Protection Act, 2010 (effective 2015-06-01; consolidation as amended
to SR 36/2025, unofficial). Section 10 of those regulations repealed the old Halocarbon Control
Regulations (RRS c E-10.21 Reg 2), which some summaries still cite. Scope: Class I (CFCs, halons,
chlorocarbons), Class II (HCFCs) and Class III (listed HFCs and PFCs, "all other" HFCs and PFCs,
and mixtures) (Appendix). No size trigger for technician duties.

| Event | Flag | Source |
|---|---|---|
| Any install, service, alteration, repair, charge or recharge | Only a "qualified person": post-secondary training in one of the listed trades (refrigeration and AC mechanic, domestic appliance technician, automotive and heavy-duty mechanics, power engineer and others), or certified for safe halocarbon handling by the Heating, Refrigeration and Air Conditioning Institute of Canada, or designated by the minister. The work follows the federal code of practice (March 1996), **including all of its recommendations**. | E.1.1 ss. 1-2(b), 1-6 |
| Adding | Before recharging, test for leaks and repair any leaks found. Use appropriate halocarbon fittings; do not fit one to equipment without halocarbon. | s. 1-7 |
| Removing refrigerant | Collect, store, recycle, destroy or dispose of it by the code of practice. | s. 1-7(1)(c) |
| Any job | A **work invoice**: date; type of service; type and quantity of halocarbon in the equipment; type and quantity recovered or added; how recovered halocarbon was recycled, destroyed or disposed of. Give it to the owner or operator and keep a copy for **7 years**. | s. 1-8(1) |
| Changing refrigerant type | Label the equipment with the new refrigerant and its amount. | s. 1-12(2) |
| Release recorded | More than 10 kg and under 100 kg: records kept 7 years (owner and contact, type and quantity, location and system type, circumstances, corrective actions, prevention). Whether a release is reportable at once depends on the Discharge and Discovery Reporting Chapter (B.1.1) and its standard's Table 1, which was not read. | ss. 1-8(2); B.1.1 ss. 1-2, 1-4 |
| Decommissioning or discarding | The halocarbon is removed by a qualified person first. | s. 1-13 |
| Charging mobile AC or mobile refrigeration | No Class I substance. | s. 1-15(1) |

Saskatchewan is close to Manitoba (a leak test before every recharge, a per-job record handed to
the owner) and shares a border with it, so most of its rows reuse flag kinds already built for
Manitoba.

**Alberta (`CA-AB`) — Alta Reg 181/2000, Ozone-depleting Substances and Halocarbons Regulation**
(office consolidation current as of 2022-07-20, amendments to AR 157/2022; no later amendment was
found on 2026-10-19, unconfirmed). Made under the Environmental Protection and Enhancement Act.
Scope: ODS (Schedules 1 and 2), and HFCs (Schedule 3) and PFCs (Schedule 4) "where used as a
refrigerant", with "all mixtures and azeotropes". **Schedule 3 is a closed list** of saturated HFCs
(it has no "all other HFCs" line), so a pure HFO is out of scope in Alberta, while R-410A, R-32,
R-134a and R-454B are in. Its flags:

| Event | Flag | Source |
|---|---|---|
| Any servicing (installation, maintenance, inspection, testing, leak detection, repair, labelling, conversion or decommissioning) | Only a person authorised under the Skilled Trades and Apprenticeship Education Act. | ss. 1(e), 7 |
| Any servicing | Follow the Environment Canada *Environmental Code of Practice for Elimination of Fluorocarbon Emissions from Refrigeration and Air Conditioning Systems* (EPS 1/RA/2, March 1996), cited by title. | s. 5 |
| Opening a circuit, or a release recorded | No release into the environment. | s. 2(1) |
| Charging a vehicle AC, mobile refrigeration or a refrigeration system (other than chillers and small systems under 19 kW) | No CFC (Schedule 1 items (a) to (e)). | s. 2(3), (5)–(7) |

Alberta sets no leak-test notice, log fields, release threshold or deadlines of its own (the
Director can require returns by notice, s. 8). The code of practice is a government publication,
but this plan does not model it. Alberta's policy stays thin.

**Quebec (`CA-QC`) — Regulation respecting halocarbons, CQLR c. Q-2, r. 29.** Still not modelled:
on 2026-10-19 LegisQuébec returned 403 to a fetch and 502 to direct requests (the English and
French document, ShowDoc and PDF addresses were all tried), and the CanLII mirror returned 403. What
the ministry's own pages say (read 2026-10-19; official, but not the regulation): the regulation
covers ODS and their replacements, **naming HFCs, PFCs, HCFOs and HFOs**; anyone who installs,
services, repairs, modifies, dismantles or reconditions halocarbon AC or refrigeration equipment
needs the "qualification environnementale relative aux halocarbures", issued for the ministry by
the Commission de la construction du Québec or Emploi-Québec depending on the trade; a leak test is
required before charging and once a year for some equipment; workers keep a register of recovery,
maintenance and dismantling work and leak tests; and GWP limits apply to new installations and
conversions (150 for food-preservation refrigeration over 50 kW and 1,500 for refrigeration
appliances from 2021-01-01; 2,200 for transport refrigeration and 750 for chillers from
2025-01-01; arts. 21.1 and 21.2 per the ministry). The ministry gives the regulation's last update
as 2023-07-06. Size thresholds, deadlines, register fields and reporting are unconfirmed until the
text is read. Quebec is worth its own policy (the second-largest market, and the most detailed
rules), and the GWP limits matter to a technician proposing a conversion.

#### Other provinces and territories, assessed

| Jurisdiction | Instrument (official source) | Key technician duties | Policy now? |
|---|---|---|---|
| Newfoundland and Labrador | *Halocarbon Regulations*, NLR 41/05, Environmental Protection Act (official version on the House of Assembly site; currency not checked) | Approved person (accepted course, certificate with registration number, listed in a database) (s. 9). Recovery equipment at the job site (s. 14(3)). **Owner has an approved person leak test the equipment once a year**, except under 3 hp, vehicle AC and domestic heat pumps (s. 15(1)–(2)). Leak found: repair at once, or recover and tag it not to be recharged, or notify the department within one working day (s. 15(6)). Leak test before adding; never add to a leaking system; health care or farm and food emergency exception with owner duties within 24 hours (s. 16). Leak-test notice on the equipment, copy to the owner, kept 3 years (s. 17). Label on service: type and amount, date, name, registration number, business (s. 23(2)); records of refrigerant received and used kept 3 years (s. 23(3)). Release over 10 kg reported within one working day (s. 6). "Halocarbon Free" label before disposal (s. 7). HFC schedule is closed (Sch. C). | Yes, after Quebec. It is a close fit with Ontario and Manitoba (notice, label, before-charge test) and adds an annual test by horsepower. |
| Prince Edward Island | *Ozone Layer Protection Regulations*, Environmental Protection Act, R.S.P.E.I. 1988, c. E-9 (Legislative Counsel office consolidation, current to 2024-06-08) | Registered handler: trade certificate of qualification, apprentice, or power engineer or refrigeration licence, plus an approved environmental awareness program; registration lasts to October 31 of the second year (ss. 6, 7). Recover into an approved cylinder; green certification label when the equipment is empty (s. 8(1)). Record of Service (Schedule C) for stationary work that opens a loop, copy to the owner within 5 days, kept 3 years; domestic equipment exempt (s. 8(4)–(5)). **Owner has a registered handler leak test equipment of 3 hp or more each year**, with a written report kept 3 years (s. 11(1)–(1.2)). Leak test before charging or topping up (s. 11(2)). Leak found: repair at once, or recover and note on the Record of Service; at 3 hp or more, notify the department and mail the record within 5 days (s. 11(3)–(4)). Release of 10 kg or more: notify the department and the owner at once; over 4 kg or the full charge, a written report within 5 days (s. 4). HFCs in Category III with "all other HFCs". | Yes, after Newfoundland and Labrador. Small market, but the rules are complete enough to model. |
| Nova Scotia | *Ozone Layer Protection Regulations*, N.S. Reg. 54/95, Environment Act (unofficial consolidation, copyright 2009) | Covers **ODS only** (Schedules A and B: CFCs, halons, HCFCs). Environmental awareness course, or direct supervision (s. 5(1)); recover (s. 5(2)); leak test before recharging and repair any leak (s. 5(3)); label on a change of refrigerant or oil (s. 9). | No. An R-410A or R-32 system gets no provincial duties in this text. Recheck for a later amendment that adds HFCs (Unconfirmed). |
| New Brunswick | *Ozone Depleting Substances and Other Halocarbons Regulation*, Reg. 97-132, Clean Air Act | **Not read**: laws.gnb.ca and gnb.ca returned 403. Known only from search summaries: a 2008 amendment (2008-66) extended it to HFCs and PFCs, and buyers and sellers need a permit tied to certification. | Not yet. Read the text first. |
| Yukon | *Ozone Depleting Substances and Other Halocarbons Regulation*, O.I.C. 2000/127, Environment Act | **Not read**: laws.yukon.ca and yukon.ca returned 403. Search summaries describe a permit, an approved environmental awareness course, servicing by the federal code of practice, labels, records and leak testing. | Not yet. Read the text first; small market. |
| Northwest Territories | An *Environmental Guideline for Ozone Depleting Substances and Halocarbon Alternatives* (seen as a search result only) | A guideline, not a regulation, so it creates no flags under this plan's rule that only legislation does. | No. |
| Nunavut | No territorial regulation found. | Federal sites and lands come under SOR/2022-110 through `federalSite`; how much of Nunavut that covers is unconfirmed. | No. |

#### Recommended order of provincial policies

1. **Manitoba**: the first organisation is there (owner direction).
2. **Ontario**, then **British Columbia**: the largest and third-largest markets with the most
   specific technician rules (notices, labels, logs), already drafted above.
3. **Saskatchewan and Alberta together**: each is a short table. Saskatchewan borders Manitoba and
   reuses Manitoba's flag kinds (leak test before recharge, per-job record to the owner); Alberta
   is a large market with three rows.
4. **Quebec**: the second-largest market and the most detailed rules, but only once its text has
   been read; it will need its own thresholds and the GWP limits.
5. **Newfoundland and Labrador**, then **Prince Edward Island**: complete, modelable rules close to
   Ontario's and Manitoba's, in small markets.
6. **Nova Scotia, New Brunswick and the territories**: not now (ODS only, unread, or guidance only).

The ranking uses market size by population and how close each province's rules are to ones already
modelled. The HVAC/R workforce per province was not checked against an official count
(Unconfirmed).

#### `AustraliaOzoneSGGPolicy` — Ozone Protection and Synthetic Greenhouse Gas Management Act 1989 and Regulations 1995

Act: compilation C36, 2026-07-01. Regulations: compilation No. 48, 2026-07-01. Scope: "RAC
equipment", meaning equipment for cooling or heating anything that uses CFC, HCFC, HFC, PFC or halon
(reg 110). HFCs are the substances listed in clause 9 of Schedule 1 to the Act, alone or in a
mixture (Act s. 7). HFOs and hydrocarbons are not listed. The licences and authorisations are
administered by the RAC Industry Board, the Australian Refrigeration Council.

| Event | Flag | Source |
|---|---|---|
| Any work that risks a release (decanting; installing, commissioning, servicing, maintaining; decommissioning with refrigerant present) | Needs a refrigerant handling licence that covers the work. The flag compares the work with the licence type recorded in the profile. A full RAC licence covers all but automotive work. An automotive AC licence covers cabin AC. A restricted heat pump licence covers **installation and decommissioning only** of single-head splits and two-part water or pool heat pumps under 18 kW. A restricted domestic licence covers domestic appliances and commercial stand-alone equipment. Example: "A restricted heat pump licence covers installing and decommissioning this unit, not servicing it." | regs 111, 131 (Table 131) |
| Opening a circuit | No discharge of a scheduled substance where it is likely to reach the atmosphere. Use refillable containers only. Recovered refrigerant goes to a refrigerant trading authorisation holder or a destruction facility. | Act s. 45B; reg 135(1)(b)–(c) |
| Adding | **Prohibited refrigerant charging:** charging with an HFC or HCFC other than the design refrigerant on the compliance plate (or in the manual, if the plate names none) is caught when the design refrigerant is not scheduled (for example R-1234yf or R-290) or the new one has a higher 100-year GWP. It is not caught when the design refrigerant is an HCFC, when the new refrigerant's GWP is lower or equal, or when the equipment is essential for health or public safety and no alternative is available (the reason is recorded). Examples from the department's guidance: R-410A into an R-32 system is caught; R-452A into an R-404A system is not; R-427A into an R-22 system is not. | regs 2AAA, 111A, 135(1)(ba), 141(1)(ba) |
| Adding a refrigerant of a higher flammability class than the design one | A note, from the department's guidance rather than the regulation: such a change needs the system converted under the relevant codes, standards and state or territory laws, with full recovery and a leak test first. | DCCEEW charging-rules page |
| Any job | Work-order fields: the technician's licence number on invoices, receipts and quotes when they are not employed by an authorisation holder, and the business's trading authorisation number on the same documents. | regs 135(1)(e), 141(1)(o) |
| Quarter end (office) | An authorisation holder keeps quarterly records of refrigerant bought, recovered, sold and otherwise disposed of. The log's totals by quarter feed that record and do not replace it. | reg 141(1)(a) |

The Australian regulations set **no leak-test interval, leak-rate threshold or repair deadline** of
their own. A licence requires work to follow standards the department's CEO determines (reg
135(1)(a), (5)), and those incorporate licensed industry standards and codes. The policy does not
model those standards and flags no leak timelines for Australia. For the GWP comparison, the GWP of a
listed HFC is taken from the Act's Schedule 1. Blend GWPs are computed from composition. The method
is unconfirmed (see Unconfirmed).

#### `NewZealandRefrigerantPolicy` — Ozone Layer Protection Act 1996 and Regulations; HSW (Hazardous Substances) Regulations 2017

New Zealand has **no refrigerant technician licence**. The Ozone Layer Protection Act lets
regulations require accreditation (s. 11), but the Ozone Layer Protection Regulations 1996 contain
no accreditation provisions. They control imports, exports, manufacture and sale, and since 2019
they list HFCs as controlled substances (Schedule 1 Part 10). The duties that reach a technician are
few, and the policy says only these:

| Event | Flag | Source |
|---|---|---|
| Opening a circuit | Do not knowingly release a controlled substance (CFC, HCFC, HFC and the others in Schedule 1) while installing, operating, servicing, modifying or dismantling refrigeration or AC equipment: recover it. A release that could not reasonably be avoided while connecting or disconnecting transfer equipment is excused. | Act ss. 13(f), 14; Regs r. 2 and Sch. 1 Pt 10 |
| Recovering into a cylinder | Charging a gas container needs an **approved filler** certificate covering that gas class (or a trainee supervised by an approved filler). WorkSafe has said that recovery from a system into a cylinder counts. The PCBU must ensure it. | HSW(HS) Regs 15.64, 15.65, 15.66 |
| Hydrocarbon refrigerant (R-290, R-600a, R-1270) | The equipment must be designed and installed for a flammable refrigerant. WorkSafe states that the Hazardous Substances Regulations require hydrocarbon RAC equipment to comply with AS/NZS 5149 (cited by number only; domestic fridges, domestic heat pumps and room ACs fall under their appliance standard instead). | WorkSafe technical bulletin, October 2022 |
| Adding a refrigerant other than the design one | A note: WorkSafe states that under the Electricity (Safety) Regulations 2010 an installation retrofitted with a refrigerant other than its design refrigerant is deemed unsafe, and a non-flammable to flammable change makes it unsafe unless properly converted. | Same bulletin (regulation number unconfirmed) |

There is no leak-test, record-keeping or leak-repair duty on a New Zealand technician in these
instruments, so the log stays neutral there. Two things are on watch. The Climate Change Response
Act's synthetic greenhouse gas levy falls on importers, not technicians, and is not modelled.
Refrigerants have been a priority product under the Waste Minimisation Act since 2020, and
regulations for a mandatory stewardship scheme were agreed for drafting in 2024. Their status at
October 2026 is unconfirmed. A later tranche was proposed to limit recovery and decommissioning to
qualified technicians, which would add a licence-style flag when it lands.

#### Flammable refrigerants (A2L, A3) in every jurisdiction

Only legislation creates a flag. The safety class shown for a refrigerant comes from its
manufacturer's safety data sheet, cited per refrigerant, not from a licensed standard. AS/NZS 5149,
AS/NZS ISO 817, AS/NZS 60335 and CSA B52 are cited by number and title where an official source
names them, and they are never quoted or turned into thresholds. Charge limits, room-size rules and
ventilation are not computed for any jurisdiction.

#### Exit tests (P2)

- **Canada federal** (`federalSite: true`): R-410A rooftop, 25 kg on one circuit, last leak test 16
  months ago, so a test is due (s. 17). An R-410A split of 8 kg is small: no annual test, and one
  log entry per service (s. 23(2)). R-404A, 40 kg, leak found today: deadline today + 7 days
  (s. 18). Adding to a unit whose log shows an unrepaired leak gets the s. 10 flag, and the
  emergency path gets the s. 11 owner duties. An R-290 self-contained unit gets no flags. Release
  estimates of 120 kg (24 h + 30 days) and 40 kg (31 July or 31 January by detection date).
  Decommissioning lists the Part 2 notice fields. A multi-circuit system with circuits of 6 kg and
  12 kg is large.
- **Manitoba** (`CA-MB`, not federal): adding 0.5 kg of R-410A to a split heat pump with no leak
  test recorded on the job gets the s. 12(1) flag; with a no-leak test recorded earlier in the same
  job it gets none, and the s. 25(2) label fields (type, amount, date, name or business,
  certificate number) are listed. A leak test that finds a leak gets the s. 12(2) flag with **no
  due date** (repair now, or recover and disable), where the same unit on a federal site gets
  today + 7 days. Any job lists the s. 8(1) record fields and "leave a copy with the owner".
  A release estimate of 12 kg gets the s. 24 "report immediately" line; 8 kg gets none. R-22 into a
  vehicle AC gets the s. 8.2 flag; R-134a into a vehicle AC does not (but still needs the s. 12
  leak test). Repairing an R-134a domestic fridge is in scope (white good, s. 6(b)). A technician
  profile whose Manitoba certificate was issued in 2025 shows it lapsed on 2026-06-01 for a job on
  2026-10-19 (s. 20(4)). A January job adds the February 1 summary reminder (s. 8(4)). R-454B is in
  scope (R-32); R-290 gets no flags; pure R-1234yf gets the out-of-scope note.
- **Ontario** (`CA-ON`, not federal): an R-410A refill with no leak-test notice in the log, or a
  no-leak notice seven months old, gets the s. 25(1)(b) flag and the s. 25(3) owner duties; a
  five-month-old notice gets neither. A leak test with a leak found produces notice fields that
  include the "no refrigerant may be added" statement. An emergency refill at a farm cooler is
  allowed and still gets the s. 25(3) owner duties. R-22 into a vehicle AC gets the s. 21(2) flag.
  Decommissioning lists the s. 32 notice fields. R-22 is in scope (class 2 ODS). R-744 and R-290
  are not. A vehicle AC is in scope.
- **British Columbia** (`CA-BC`): a recharge with no leak test recorded gets the s. 11(2) flag. An
  evacuation lists the s. 10(2) tag and log fields. Adding R-22 to leak test gets the s. 11(1)
  flag; adding R-410A to leak test does not (s. 3). Schedule B lookup: a recovery device bought in
  2020 on a 30 kg R-134a system gives 15 in Hg vacuum (379,000 µm); the same device on an 8 kg
  R-22 unit gives 0 in Hg (760,000 µm); an R-410A unit says the row is unconfirmed. R-290 gets no
  flags.
- **Saskatchewan** (`CA-SK`): an R-410A recharge with no leak test recorded gets the s. 1-7(1)(a)
  flag. Any job lists the s. 1-8(1) work invoice fields with "keep 7 years". Converting R-22 to
  R-407C gets the s. 1-12(2) label line. A release estimate of 40 kg lists the s. 1-8(2) record
  fields and says the reporting threshold is unconfirmed.
- **Alberta** (`CA-AB`): an R-410A service gets the Alberta lines and no deadlines. Pure R-1234yf
  is out of scope with no "unconfirmed" note (closed Schedule 3). R-12 into a vehicle AC gets the
  s. 2(3) flag.
- **Canada, federal status unanswered:** the provincial policy runs and the "If this is a federal
  site" line appears once. **Quebec, Newfoundland and Labrador, Prince Edward Island, Nova Scotia,
  New Brunswick and the territories (until each has a table):** no flags, calculations only.
- **Australia:** R-32 design charged with R-410A, caught. R-404A design charged with R-452A, not
  caught. R-22 design charged with R-427A, not caught. R-1234yf design charged with R-134a, caught.
  R-290 charged with R-290, no flags. The health and public safety exception recorded, not caught,
  with the reason on the work order. A restricted heat pump licence recorded against a service of a
  7 kW split gets the entitlement note; against an installation, none. A self-employed licensee
  gets the licence-number field. No leak-deadline flag for any Australian unit.
- **New Zealand:** an R-410A heat pump, opening the circuit, gets the release line and the approved
  filler line at recovery. A commercial R-290 unit gets the hydrocarbon note; a domestic R-600a
  fridge does not. An R-134a system topped up with R-600a gets the design-refrigerant note. R-744
  gets no ozone-layer flags. No leak-deadline flag for any New Zealand unit.
- **Jurisdiction unknown, or no policy (US before P2-US ships):** no flags, the calculations
  unchanged, and the log still records.
- **Units:** kPa(g) ↔ psig ↔ bar(g) ↔ kPa abs round-trips at 0 m and 1,500 m. °C ↔ °F, and K ↔ °F
  differences. kg ↔ lb/oz ↔ g with exact constants, so "4 lb 6 oz" is stored as 1984 g and shown
  as 1.98 kg. The −40 °C and −40 °F rows agree exactly. Interpolating the °C grid at 10 °C and the
  °F grid at 50 °F agree within 0.1 kPa. The same superheat in either unit set gives the same
  answer in K.
- **Wording guard** across every policy's flag text: no "violation", "illegal", "fine", "offence",
  "breach", "penalty" or "contravene". The legislation uses these words, and the flags must not.
- **Citations:** every flag carries an instrument, a section and an as-at date. A test fails if a
  policy's facts table has a row without one.

### Acceptance (added to the plan's list)

- On a Manitoba site, "added 0.8 kilos of R-410A" with no leak test recorded on the job says a
  leak test comes first and any leak is repaired before charging, lists the recharge label fields,
  and records the amount in kilograms. A leak found says to repair it now or recover and disable
  the unit, with no grace period.
- On an Ontario site, "added 1.5 kilos of R-410A" on a unit whose last leak test notice is eight
  months old says a refill needs a no-leak notice no more than six months old. It records the
  amount in kilograms, and the technician can say it in pounds.
- In Australia, recording R-410A added to a unit whose compliance plate says R-32 says that
  charging a higher-GWP refrigerant than the design one is not allowed, and why.
- In New Zealand, opening an R-410A circuit reminds the technician to recover and that recovery into
  a cylinder needs an approved filler certificate.
- With the units set to metric, "what's my superheat?" on an R-410A system answers in K, kPa and
  °C, with the dew point and the source, and "assuming sea level" unless an altitude is known.
- A unit with no known jurisdiction gets the calculations and no regulatory flags.

### Phases

- **P0:** both grids and absolute storage (above). Otherwise unchanged.
- **P1, P4, P5:** units as above. Otherwise unchanged.
- **P2:** the neutral log, the resolver, and the Canada federal, Manitoba, Ontario, BC,
  Saskatchewan, Alberta, Australia and New Zealand policies. If the PR is too large, it splits as
  Canada federal and Manitoba first (the first organisation's jurisdiction), then Ontario and BC,
  then Saskatchewan and Alberta, then Australia and New Zealand (each is one table). Quebec,
  Newfoundland and Labrador and Prince Edward Island follow as one table each, Quebec once its
  text is read.
- **P2-US (deferred):** the existing `EPA608Policy` text, unchanged, behind the same log, scheduled
  when the owner asks for the US.
- **P3, P6:** unchanged.

### Sources (official; read 2026-10-19 unless marked)

- *Federal Halocarbon Regulations, 2022*, SOR/2022-110. Justice Laws, current to 2026-09-30.
  <https://laws-lois.justice.gc.ca/eng/regulations/SOR-2022-110/FullText.html>
- *Federal Halocarbon Regulations, 2003*, SOR/2003-289. Shown as repealed by SOR/2022-110 s. 29.
  <https://laws-lois.justice.gc.ca/eng/regulations/SOR-2003-289/FullText.html>
- ECCC, *Federal Halocarbon Regulations information* (scope, and "provinces and territories regulate
  in their jurisdictions"). Seen as a search summary only.
  <https://www.canada.ca/en/environment-climate-change/services/air-pollution/issues/ozone-layer/measures-protect/federal-halocarbon-regulations-information.html>
- Manitoba, *Ozone Depleting Substances and Other Halocarbons Regulation*, M.R. 103/94, under The
  Ozone Depleting Substances Act, C.C.S.M. c. O80. Manitoba Laws consolidation, in effect since
  2005-12-09, last amendment M.R. 178/2005, stated as the most current version on 2026-10-19 (HTML
  unofficial; the bilingual PDF is official).
  <https://web2.gov.mb.ca/laws/regs/current/103-94.php?lang=en>
- Manitoba, *Ozone depleting substances management program* page (names the regulation and the
  Act; nothing on certification or reporting). No date shown.
  <https://www.gov.mb.ca/sd/environment_and_biodiversity/environmental-protection/>
- Ontario, *O. Reg. 463/10: Ozone Depleting Substances and Other Halocarbons*. e-Laws, consolidation
  from 2024-08-30, currency 2026-10-14, last amendment O. Reg. 336/24. Re-read in full 2026-10-19.
  <https://www.ontario.ca/laws/regulation/100463>
- British Columbia, *Ozone Depleting Substances and Other Halocarbons Regulation*, B.C. Reg. 387/99,
  under the Environmental Management Act. BC Laws, current to 2026-10-13, last amended by
  B.C. Reg. 171/2025. Re-read in full 2026-10-19, Schedule B included.
  <https://www.bclaws.gov.bc.ca/civix/document/id/complete/statreg/387_99>
- Saskatchewan, *The Environmental Management and Protection (Saskatchewan Environmental Code
  Adoption) Regulations*, RRS c E-10.22 Reg 2, with the Code's Halocarbon Control Chapter (E.1.1)
  and Discharge and Discovery Reporting Chapter (B.1.1). Publications Saskatchewan consolidation
  (unofficial), effective 2015-06-01, as amended by SR 124/2020, 97/2021, 18/2023 and 36/2025.
  <https://publications.saskatchewan.ca/api/v1/products/73308/formats/81966/download>
- Alberta, *Ozone-depleting Substances and Halocarbons Regulation*, Alta Reg 181/2000. King's
  Printer office consolidation, current as of 2022-07-20 (to AR 157/2022). Re-read in full
  2026-10-19. <https://kings-printer.alberta.ca/documents/Regs/2000_181.pdf>
- Quebec, *Regulation respecting halocarbons*, CQLR c. Q-2, r. 29. **Not read**: LegisQuébec
  returned 403 to a fetch and 502 to direct requests on 2026-10-19 (English and French document,
  ShowDoc and PDF addresses); the CanLII mirror returned 403.
  <https://www.legisquebec.gouv.qc.ca/en/document/cr/Q-2,%20r.%2029>
- Quebec, Ministère de l'Environnement, *Halocarbures* pages: the overview (scope, including HFOs
  and HCFOs), *Le Règlement en bref* (gives the regulation's last update as 2023-07-06, and the
  GWP limits) and *Qualification environnementale* (CCQ and Emploi-Québec). Official secondary
  sources, not the regulation.
  <https://www.environnement.gouv.qc.ca/air/halocarbures/index.htm>,
  <https://www.environnement.gouv.qc.ca/air/halocarbures/enbref.htm>,
  <https://www.environnement.gouv.qc.ca/air/halocarbures/qualification-enviro.htm>
- Newfoundland and Labrador, *Halocarbon Regulations*, NLR 41/05, under the Environmental
  Protection Act. House of Assembly site, marked "an official version"; consolidation date not
  checked. <https://assembly.nl.ca/Legislation/sr/Regulations/rc050041.htm>
- Prince Edward Island, *Environmental Protection Act Ozone Layer Protection Regulations*.
  Legislative Counsel office consolidation, current to 2024-06-08 (unofficial).
  <https://www.princeedwardisland.ca/sites/default/files/legislation/E09-11-Environmental%20Protection%20Act%20Ozone%20Layer%20Protection%20Regulations.pdf>
- Nova Scotia, *Ozone Layer Protection Regulations*, N.S. Reg. 54/95, under the Environment Act.
  Registry of Regulations consolidation (unofficial), copyright 2009.
  <https://novascotia.ca/just/regulations/regs/env5495.htm>
- New Brunswick, *Ozone Depleting Substances and Other Halocarbons Regulation*, Reg. 97-132, under
  the Clean Air Act. **Not read** (laws.gnb.ca returned 403). <https://laws.gnb.ca/en/document/cr/97-132>
- Yukon, *Ozone Depleting Substances and Other Halocarbons Regulation*, O.I.C. 2000/127, under the
  Environment Act. **Not read** (laws.yukon.ca and yukon.ca returned 403).
  <https://yukon.ca/en/get-ozone-depleting-substances-and-other-halocarbons-permit>
- Australia, *Ozone Protection and Synthetic Greenhouse Gas Management Act 1989*. Compilation C36
  (C2026C00241), 2026-07-01. <https://www.legislation.gov.au/C2004A03755/latest/text>
- Australia, *Ozone Protection and Synthetic Greenhouse Gas Management Regulations 1995*.
  Compilation No. 48 (F2026C00546), 2026-07-01.
  <https://www.legislation.gov.au/F1996B02085/latest/text>
- DCCEEW, *Rules on charging refrigeration and air conditioning equipment*, last updated
  2024-05-29.
  <https://www.dcceew.gov.au/environment/protection/ozone/rac/rules-charging-rac-equipment>
- DCCEEW, *Refrigeration and air conditioning*, last updated 2026-04-30 (ARC as the Industry Board;
  notes that a National Environmental Protection Agency was established on 2026-07-01).
  <https://www.dcceew.gov.au/environment/protection/ozone/rac>
- New Zealand, *Ozone Layer Protection Act 1996*, version as at 2021-10-28.
  <https://www.legislation.govt.nz/act/public/1996/40/en/latest/>
- New Zealand, *Ozone Layer Protection Regulations 1996* (SR 1996/222), version as at 2025-04-05.
  <https://www.legislation.govt.nz/secondary-legislation/pco-drafted/1996/222/en/latest/>
- New Zealand, *Health and Safety at Work (Hazardous Substances) Regulations 2017* (LI 2017/131),
  version as at 2026-09-23.
  <https://www.legislation.govt.nz/secondary-legislation/pco-drafted/2017/131/en/latest/>
- WorkSafe NZ, *Technical bulletin: Hydrocarbon refrigerants*, October 2022.
  <https://www.worksafe.govt.nz/dmsdocument/55344-technical-bulletin-hydrocarbon-refrigerants/latest/>

Standards and codes named above (AS/NZS 5149, AS/NZS ISO 817, AS/NZS 60335, CSA B52, and the
industry codes that the Australian CEO's standards draw on) are cited by number and title only.

### Unconfirmed

- Whether pure HFOs (R-1234yf, R-1234ze(E)) are "Hydrofluorocarbons (HFC)" under the Canadian
  federal Schedule 1, which names the class without a list. Ontario's "any hydrofluorocarbon"
  and the "all other hydrofluorocarbons" lines in Manitoba, BC, Saskatchewan and Prince Edward
  Island raise the same question (Manitoba's PFC list naming unsaturated compounds is a pointer,
  not an answer). Until it is settled, those policies treat a pure HFO as out of scope and say so.
  Alberta and Newfoundland and Labrador have closed lists, so there it is out of scope outright.
  Quebec's ministry says its regulation covers HFOs; unconfirmed until the text is read.
- Quebec's regulation, in full: the text was unreachable (LegisQuébec 403/502, CanLII 403). Seen
  only in search summaries, not relied on: a 20 kW threshold with a 48-hour recovery duty after a
  leak, a re-test one month after a repair, and a 10 kg release report.
- Manitoba: which body, if any, the minister has appointed under s. 28 to receive the s. 8(4)
  annual summaries, and the approved forms for the s. 8(1) record and the summary (the
  regulation names forms "approved by the minister" but the official text does not show them);
  whether the MOPIA compliance guide named in s. 12(1) has been replaced (s. 12 allows "as amended
  or replaced").
- BC Schedule B: which row R-410A, R-32, R-404A and R-454B fall in (the table gives examples
  only), and the row for a charge of exactly 23 kg.
- BC: whether s. 4(3) ("must not add an ozone depleting substance" to leaking equipment) reaches
  HFC equipment through s. 3; the policy assumes yes.
- Saskatchewan: the discharge reporting threshold for halocarbons in Table 1 of the Discharge and
  Discovery Reporting Standard (not read).
- Alberta: whether any amendment after AR 157/2022 exists (none found on 2026-10-19), and whether a
  release-reporting duty under another Alberta regulation applies to refrigerant.
- Nova Scotia: whether N.S. Reg. 54/95 has been amended since the 2009 consolidation to cover HFCs.
  New Brunswick and Yukon: the texts, unread (403).
- Newfoundland and Labrador: the consolidation date ("How current is this regulation?" not read).
- Nunavut and the Northwest Territories: how much work falls under SOR/2022-110 as federal or
  Aboriginal lands, and the legal status of the NWT guideline.
- The HVAC/R workforce by province (no official count was checked); the provincial order rests on
  population and how close the rules are.
- What units Canadian technicians use day to day (open question 7).
- How Ontario wants a blend named in records (s. 23(2) points at single-substance terms; R-410A is a
  mixture of HFC-32 and HFC-125).
- Australia: the title and contents of the CEO's standards determination under reg 135(5); the
  method for a blend's GWP under reg 2AAA(5) (the department publishes a GWP list, not read); the
  effect, if any, of the new National Environmental Protection Agency on who administers the scheme;
  and state and territory rules for hydrocarbon refrigerant work (not modelled). Queensland
  requires a gas work licence (hydrocarbon refrigerants) under its petroleum and gas safety law
  (Queensland Government, *Hydrocarbon refrigerants guideline*,
  <https://www.business.qld.gov.au/industries/mining-energy-water/resources/safety-health/petroleum-gas/gas-work-devices/guidelines/hydrocarbon-refrigerants>,
  seen as a search summary only). No equivalent licence was found for Victoria or Western
  Australia, where workplace safety and dangerous goods guidance applies instead; the other states
  and territories were not checked. All of this stays open, and no state rule is modelled.
- New Zealand: WorkSafe's position that recovery into a cylinder needs an approved filler (seen in
  a summary of a 2017 submissions report, not read in full); the Electricity (Safety) Regulations
  2010 provision behind the retrofit statement; whether A2L refrigerants are treated like
  hydrocarbons under the Hazardous Substances Regulations; the status at October 2026 of the
  refrigerant product stewardship regulations; and whether s. 13(f)'s "controlled substance"
  reaches a blend inside equipment (assumed yes: blends of listed HFCs).
