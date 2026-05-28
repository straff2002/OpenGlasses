# Refrigerant Pressure–Temperature (PT) Reference

Saturation temperatures (°F) at given gauge pressures (psig) for common HVAC/R refrigerants.
Values are approximate and intended for field reference; always confirm against a calibrated PT chart for precision diagnostics.

## R-410A (most common 2010-2024 commercial)

| Pressure (psig) | Saturation Temp (°F) |
|----------------:|---------------------:|
| 50  | 8   |
| 75  | 23  |
| 100 | 31  |
| 125 | 44  |
| 135 | 47  |
| 150 | 54  |
| 175 | 63  |
| 200 | 70  |
| 250 | 84  |
| 300 | 96  |
| 400 | 119 |
| 450 | 129 |

## R-32 (newer single-component, mildly flammable A2L)

| Pressure (psig) | Saturation Temp (°F) |
|----------------:|---------------------:|
| 50  | 12  |
| 100 | 38  |
| 135 | 52  |
| 150 | 58  |
| 200 | 75  |
| 250 | 89  |
| 300 | 102 |
| 400 | 124 |

## R-454B (A2L blend; replacing R-410A from 2024)

| Pressure (psig) | Saturation Temp (°F) |
|----------------:|---------------------:|
| 50  | 9   |
| 100 | 35  |
| 135 | 49  |
| 150 | 55  |
| 200 | 73  |
| 250 | 87  |
| 300 | 100 |
| 400 | 124 |

## R-22 (legacy — phaseout, virgin production banned in US since 2020)

| Pressure (psig) | Saturation Temp (°F) |
|----------------:|---------------------:|
| 50  | 25  |
| 75  | 44  |
| 100 | 59  |
| 125 | 72  |
| 150 | 83  |
| 200 | 102 |
| 250 | 117 |
| 300 | 130 |

## Quick rule-of-thumb pressures (R-410A, 70-75°F ambient, normal operation)

| Position | Expected gauge reading |
|----------|------------------------|
| Suction (low side) | 110-130 psig |
| Liquid (high side) | 250-300 psig |

Significant departure from these ranges (with the unit running, stabilized) suggests undercharge, overcharge, airflow restriction, or compressor issue. Diagnose with superheat + subcool — see `superheat_subcool.md`.

## Diagnostic interpretation

- **Low suction pressure + low superheat** → likely overcharge or restricted metering device.
- **Low suction pressure + high superheat** → likely undercharge or restricted suction.
- **High discharge pressure + low subcool** → undercharge or non-condensables.
- **High discharge pressure + high subcool** → overcharge, condenser airflow restriction, or non-condensables.
- **Normal pressures + high superheat + low subcool** → undercharge (often the answer).
