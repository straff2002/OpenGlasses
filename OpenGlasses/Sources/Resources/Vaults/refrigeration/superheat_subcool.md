# Superheat and Subcool — Measurement and Interpretation

Superheat and subcool are the two most useful diagnostic measurements for charge and system health. Always measure with the system stabilized (10+ minutes runtime after startup, steady ambient).

## Definitions

- **Superheat**: How much the suction-line refrigerant has warmed above its saturation temperature.
  `superheat_F = actual_suction_temp_F − saturation_temp_F_at_suction_pressure`
- **Subcool (Subcooling)**: How much the liquid-line refrigerant has cooled below its saturation temperature.
  `subcool_F = saturation_temp_F_at_liquid_pressure − actual_liquid_temp_F`

Both use values from the PT chart for the refrigerant in question (`pt_charts.md`).

## Measurement procedure (TXV / EEV systems — target subcool)

1. Confirm refrigerant type from nameplate. Pull up the right PT column.
2. Ensure the unit is in cooling, with stable load (10+ min runtime).
3. Connect gauge manifold:
   - Low-side hose on suction service port.
   - High-side hose on liquid-line service port.
4. Clamp a calibrated pipe thermometer on the liquid line within 6 inches of the condenser exit.
5. Read liquid-line pressure → convert to saturation temp via PT chart.
6. `subcool = saturation_temp − measured_liquid_line_temp`.
7. Target: most manufacturers spec **8-12°F subcool**. Always confirm against the nameplate sticker — Carrier 30RB and many newer units publish unit-specific target subcool.

## Measurement procedure (fixed-orifice / cap-tube systems — target superheat)

1. Same setup as above, but clamp thermometer on the suction line 6 inches from the compressor.
2. Read suction pressure → saturation temp via PT chart.
3. `superheat = measured_suction_line_temp − saturation_temp`.
4. Target superheat depends on indoor wet-bulb and outdoor dry-bulb. Use the manufacturer's superheat chart, or as a rough field starting point:
   - 75°F indoor / 80°F outdoor: ~15°F superheat
   - 75°F indoor / 95°F outdoor: ~10°F superheat
   - 80°F indoor / 95°F outdoor: ~8°F superheat

## Interpretation cheat sheet

| Subcool | Superheat | Likely diagnosis |
|---------|-----------|------------------|
| Low (<5°F) | High (>20°F) | Undercharge |
| High (>15°F) | Low (<5°F) | Overcharge |
| Low | Low | Restricted metering device + overcharge — investigate further |
| High | High | Restricted liquid line / metering device starvation |
| Normal | Normal | Charge is correct — look elsewhere for the complaint (airflow, sensors, controls) |

## Common mistakes

- Reading subcool on a fixed-orifice system. Subcool only diagnoses charge on TXV/EEV systems. On fixed orifice, use superheat.
- Adjusting charge without 10+ minutes of stable runtime. Numbers will be misleading.
- Forgetting to compensate for line set length on long pipe runs.
- Using an uncalibrated clamp thermometer — they drift; check against ice water (32°F) periodically.

## Safety reminder

Charging adjustments require connecting a refrigerant cylinder. Before opening the refrigerant circuit:
- Confirm proper PPE (refrigerant gloves, eye protection).
- Verify refrigerant in the cylinder matches the unit nameplate.
- Recover refrigerant per EPA 608 if the circuit must be opened for component access (see `epa_608.md`).
