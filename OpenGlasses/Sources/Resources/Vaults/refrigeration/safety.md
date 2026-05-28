# Field Safety Reference

Field-service safety prompts the AI should weave into responses whenever they apply.

## Electrical safety — Lockout/Tagout (LOTO)

Before opening any electrical panel, control box, or accessing energized components:

1. Identify all electrical sources feeding the unit (utility power, control transformer, separate disconnect for fan, etc.).
2. De-energize each source at its disconnect.
3. Lock and tag each disconnect with the technician's personal lock and tag.
4. Verify zero-energy state with a known-good meter on a known-live source first, then the de-energized circuit, then the known-live source again.
5. Test before touch.
6. PPE: insulated gloves, arc-rated clothing for the calculated incident energy level, safety glasses.

Never work on energized equipment unless required for diagnostic measurement and you have:
- Energized-work permit (employer policy).
- Voltage-rated PPE for the panel's incident energy.
- A second qualified person present.

## Refrigerant handling

- Wear refrigerant-rated gloves and ANSI Z87.1 eye protection any time you connect/disconnect gauges or open the circuit.
- Never vent refrigerant — recover per `epa_608.md`.
- A2L refrigerants (R-32, R-454B) are mildly flammable. Eliminate ignition sources before opening the circuit. Verify ventilation in mechanical rooms.
- Never use a torch on a pressurized refrigerant line. Recover to 0 psig minimum before brazing.
- After brazing, nitrogen purge then pressure test before charging.

## Heights and confined spaces

- Roof access requires fall-protection assessment. Parapet edges < 39 inches require either railings or a personal fall arrest system tied to a rated anchor point.
- Mechanical pits and tank rooms may be confined spaces. Test atmosphere (O₂, LEL, CO, H₂S) before entry.

## Heat

- Roof surface temperatures can exceed 150°F in summer. Hydrate. Limit continuous roof time on extreme heat days.
- Hot work in attics or boiler rooms requires elevated heat-stress awareness.

## When the AI should remind the technician

The Field Assist AI should proactively include relevant safety steps before recommending any action that involves:

- Opening an electrical panel or accessing any wiring → **LOTO + PPE**.
- Connecting gauges or opening the refrigerant circuit → **PPE + recovery (if circuit opens) + A2L caution (if applicable)**.
- Brazing or other hot work → **circuit must be at atmospheric pressure, nitrogen purge required**.
- Working on a roof → **fall-protection check**.

These reminders should be terse — one sentence per applicable hazard, not a lecture. The technician already knows the rules; the AI's job is to surface the right one at the right moment.
