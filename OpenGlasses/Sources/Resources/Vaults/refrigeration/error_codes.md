# Error Codes by Manufacturer

These are the most commonly encountered error codes on the equipment lines OpenGlasses Field Assist supports. Always confirm against the unit's actual service manual.

## Carrier (ComfortLink — 30RB / 30XA / WeatherMaker)

| Code | Meaning | First-line check |
|------|---------|-----------------|
| T01 | Compressor 1 high discharge temperature | Check superheat, condenser airflow, overcharge |
| T02 | Compressor 1 low pressure cutout | Check refrigerant charge, evaporator airflow, low ambient cycling |
| T03 | Compressor 1 high pressure cutout | Check condenser coil, condenser fan, ambient over rating |
| T05 | Compressor 1 oil pressure low | Check oil level, oil pump, oil pressure sensor |
| T19 | Outdoor air temperature sensor failure | Check OAT sensor wiring/resistance |
| T28 | Loss of communications with controller | Check controller power, bus wiring |
| E1xx range | Configuration errors | Check controller config vs unit nameplate |

## Trane (Voyager / Reliatel / Symbio)

| Code | Meaning | First-line check |
|------|---------|-----------------|
| A100 | High pressure cutout circuit 1 | Condenser coil cleanliness, fan operation |
| A101 | Low pressure cutout circuit 1 | Refrigerant charge, evaporator airflow |
| A200 | High pressure cutout circuit 2 | As A100 for circuit 2 |
| A201 | Low pressure cutout circuit 2 | As A101 for circuit 2 |
| A305 | Compressor lockout — too many resets | Trace root cause before clearing |
| A500 | Outdoor coil sensor failure | Check sensor resistance + wiring |

## Daikin (VRV / Rebel — proprietary controller)

Daikin codes are 2-character alphanumeric. Common ones:

| Code | Meaning |
|------|---------|
| E3 | High pressure protection |
| E4 | Low pressure protection |
| E5 | Compressor motor lock / overload |
| E6 | Compressor start-up failure |
| E7 | Fan motor abnormality |
| F3 | Discharge pipe temperature abnormal |
| H6 | Position sensor abnormality (inverter compressor) |
| L4 | Inverter heatsink temperature high |
| L5 | Inverter compressor abnormality |
| P3 | Inverter PCB temperature sensor abnormal |
| U0 | Refrigerant shortage |
| U2 | Power voltage abnormal |

## Lennox (Energence / M3 controller)

| Code | Meaning | First-line check |
|------|---------|-----------------|
| E200 | Low refrigerant pressure | Charge, evap airflow |
| E201 | High refrigerant pressure | Condenser coil, fan |
| E251 | Compressor lockout | Trace root cause |
| E305 | Outdoor temp sensor failure | Sensor + wiring |
| A115 | Indoor blower motor fault | Motor, ECM module |

## Mitsubishi (Mr. Slim / City Multi VRF)

| Code | Meaning |
|------|---------|
| P1 | Indoor return air thermistor failure |
| P2 | Indoor pipe (liquid) thermistor failure |
| P4 | Drain sensor / drain pump failure |
| P5 | Drain overflow |
| P8 | Outdoor coil pipe temperature abnormal |
| U1 | Abnormal high pressure (63HS triggered) |
| U2 | Abnormal high discharge temp / shell sensor |
| U6 | Compressor overcurrent |
| U8 | Outdoor fan motor abnormality |
| FB | Address setting failure |

## General response protocol

When a code is reported:

1. Confirm code on the display (have the tech read the exact alphanumeric).
2. Note the refrigerant type from the nameplate.
3. Identify whether the code indicates a pressure/temperature fault, a sensor/wiring fault, or a control/config fault.
4. Cross-reference with `pt_charts.md` for refrigerant-specific pressure expectations at current ambient.
5. Always remind the technician of the applicable safety steps before opening any panel — refer to `safety.md`.
