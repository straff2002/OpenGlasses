# Service values — SLP99UHVK

Measurement targets from the SLP99UHVK Service Manual (SM) and Installation Instructions (II). These are comparison values only; the gas valve, pressure switches and primary limit are factory set and must not be adjusted (SM p.67, II p.62, II p.64).

## Gas supply (line) pressure — TABLE 34, SM p.64

Measured at the supply pressure tap on the inlet side of the gas valve, unit firing at maximum rate. Supply piping must not drop more than 0.5 in. w.c. between meter and unit.

| Gas | Line pressure, in. w.c. |
|---|---|
| Natural | 4.5 – 10.5 |
| LP/propane | 11.0 – 13.0 |

## Manifold pressure and operating pressure signal (Delta P) — TABLE 39 SM p.67, TABLE 35 II p.64

Manifold pressure is a differential: "+" on the manifold tap on the outlet side of the gas valve, "-" teed into the gas valve regulator vent hose (adapter kit 10L34). Delta P is taken across the positive and negative lines between the gas valve and the pressure switch. Run low heat (35%) for 5 minutes before reading, then repeat on high heat. Natural gas should burn blue and the flame should not lift. Valid 0–7,500 ft.

| Firing rate | Manifold, natural gas | Manifold, LP/propane | Operating pressure signal (Delta P) |
|---|---|---|---|
| Low, all models except 090XV60C | 0.40 – 0.95 | 1.2 – 2.8 | 0.20 – 0.40 |
| Low, 090XV60C natural gas | 0.30 – 0.85 | — | 0.15 – 0.35 |
| Low, 090XV60C LP | — | 1.2 – 2.8 | 0.20 – 0.40 |
| High, all models | 3.0 – 3.8 | 9.1 – 10.5 | 0.95 – 1.25 |

Nameplate values for reference: 3.5 in. w.g. natural / 10.0 LP at maximum input, 0.5 / 1.5 at minimum input (SM p.2).

## Gas flow, meter clocking — TABLE 35 SM p.65, TABLE 34 II p.62

Run at least 5 minutes, time two revolutions and halve. Natural gas 1000 Btu/cu ft, LP 2500 Btu/cu ft. If manifold pressure is right and the rate is wrong, check orifice size and restriction.

| Unit | Natural, 1 cu ft dial | Natural, 2 cu ft dial | LP, 1 cu ft dial | LP, 2 cu ft dial |
|---|---|---|---|---|
| -070 | 55 s | 110 s | 136 s | 272 s |
| -090 | 41 s | 82 s | 102 s | 204 s |
| -110 | 33 s | 66 s | 82 s | 164 s |
| -135 | 27 s | 54 s | 68 s | 136 s |

## Combustion — TABLES 36–37, SM p.67

Run 15 minutes at correct manifold pressure first; sample beyond the flue outlet. CO must not exceed 100 ppm.

| Unit | High fire CO2 % natural | High fire CO2 % LP | Low fire CO2 % natural | Low fire CO2 % LP |
|---|---|---|---|---|
| -070, -090XV36C/48C, -110, -135 | 6.5 – 9.0 | 7.7 – 10.2 | 4.7 – 7.2 | 5.7 – 8.2 |
| -090XV60C | 6.7 – 9.2 | 8.0 – 10.5 | 5.3 – 7.8 | — |

## Flame signal — TABLE 39 II p.64

Read in Field Test mode on the seven-segment display. Normal 2.6 µA or greater; low 2.5 or less; drop-out 1.1 µA. A much higher reading (15, for example) may appear and is not a fault. The flame sensor is on the left of the burner support, tip in the left-most burner's flame; it can be removed without disturbing the burners.

## Voltage and ground — SM p.68, TABLE 40

Line hot to line neutral at the control: 97 – 132 VAC. Line neutral to low-voltage "C": the table below; readings above the maximum mean a poor or partial ground, which shortens ignitor life. 24 V range for the control is 18 – 30 V (E115).

| Furnace state | Expected VAC | Maximum VAC |
|---|---|---|
| Power on, idle | 0.3 | 2 |
| Inducer / ignitor energised | 0.75 | 5 |
| Indoor blower energised | under 2 | 10 |

## Airflow, temperature rise and static

- Set blower speed so the rise at 100% firing rate falls in the nameplate range (see models.md). Measure with the unit on second-stage heat; a single-stage thermostat must fire 10 minutes before switching to second stage. Rise too low: decrease blower speed. Too high: check firing rate first, then increase blower speed (SM p.69, II p.65).
- Heating blower speed adjustments allowed: -15%, -7.5%, default, +7.5%, +15% (TABLE 30, II p.59).
- External static pressure must not exceed 0.8 in. w.c. heating, 1.0 in. w.c. cooling (SM p.69). The variable-speed motor cuts back above 0.8 in. w.c. (E311/E312).
- Return air: minimum 60 °F continuous, 55 °F intermittent with night setback, maximum 85 °F dry bulb. Do not set the thermostat below 60 °F in heating (II p.5).
- Discharge air temperature sensor (DATS) mounting positions per model are TABLES 41–43, SM p.70.

## Heating sequence timings — II p.65–66, flowchart p.71–72

Pressure switch calibration, then inducer at ignition speed (about the 70% speed); low-fire pressure switch must close within 150 s. Pre-purge 15 s. Ignitor warm-up 20 s. Gas valve opens; flame must be sensed within 4 s. Indoor blower on-delay 30 s. Ignition stabilisation 10 s, then the inducer moves to the target rate. Five failed trials is a soft lockout (E270). Second-stage recognition delay 30 s; the high-fire pressure switch must close within 10 s, five attempts, otherwise the cycle finishes on low fire. Post-purge 20 s, then the field-selected blower off delay. Initial cycle after power-up fires at about 35%; later cycles range 35–90% with a first-stage call and step up 10% every 5 minutes on a continued second-stage call. The Watchguard automatically retries a lockout after one hour of continuous demand (II p.65).

## Pressure switch tubing — FIGURE 65, II p.65

1. Black tubing: low-fire switch front port to the gas valve positive port.
2. Red-and-black tubing: low-fire switch rear port to the gas valve negative port.
3. Red-and-black tubing: high-fire switch front port to the cold end header box negative port.
4. Black tubing: high-fire switch rear port to the cold end header box positive port.

## Start-up and condensate — II p.61, SM p.63

Prime the condensate trap with 10 fl. oz. (300 ml) of water, or run two 3-minute heat cycles waiting for the inducer to stop each time. Gas valve lighting sequence: thermostat lowest, power off, valve switch OFF, wait 5 minutes and smell for gas, switch ON by hand, power on. If the unit will not run, work the "Failure To Operate" list: heat call, panels in place, disconnect closed, fuse, filter, gas at meter, manual shut-off open, valve on, ignition lockout, blower harness connected to the control (II p.62).

## High altitude — TABLE 38, SM p.67

No manifold pressure adjustment to 10,000 ft. 7,501–10,000 ft needs the high-altitude pressure switch (14T65, or 20A87 for the 090XV60C). Only the 090XV60C needs a gas orifice change from 4,501 ft. In Canada, installations above 4,500 ft are the local authority's jurisdiction.
