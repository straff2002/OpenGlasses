# Diagnostic codes — SLP99UHVK integrated control

The seven-segment LED on the integrated control shows status characters and E-codes. Sources: SLP99UHVK Service Manual p.19–22 (Integrated Control Diagnostic Codes, TABLE 5) and Installation Instructions p.45–48; the two tables are identical. "See E 223" in the manual means the E223 row.

Reading codes: hold the diagnostic push button; the menu advances every five seconds. Release on solid **E** for Error Code Recall (last 10 codes; **c** then a second press clears history; **b** exits), on solid **-** for Field Test mode (solid **C** runs pressure-switch calibration), on solid **P** to program the unit size code (II p.45, p.52).

## LED status characters

| Display | Meaning |
|---|---|
| `.` blinking 1 Hz | Idle |
| `A` | Indoor blower cfm setting for the current mode |
| `C` then 1 or 2 | Cooling stage, then cfm setting |
| `d` | Dehumidification mode, cfm setting |
| `h` then % | Variable-capacity heat, % input rate, then cfm |
| `H` then 1 or 2 | Heat stage, then cfm setting |
| `df` | Defrost mode |
| `U` | Discharge air temperature |
| `- -` two horizontal bars | Soft disable: the thermostat found a BUS device it does not recognise. Check wiring, cycle power to the displaying control, run thermostat setup, reset / resetAll under system devices (SM p.18) |
| `≡` three horizontal bars, then E203 | Unit size code not recognised; program it (II p.70, procedure slp99_unit_size_code) |

## Power, ground and communication (E105–E126, E331)

| Code | Meaning | Action |
|---|---|---|
| E105 | Device communication problem; no other devices on the BUS | Check for mis-wire, loose connections, and a high-voltage noise source nearby (welder etc.) |
| E110 | Low line voltage (below nameplate) | Check voltage |
| E111 | Line voltage polarity reversed | Reverse line wiring; resumes 5 s after recovery |
| E112 | Earth ground not detected; system shuts down | Provide proper earth ground; resumes 5 s after recovery |
| E113 | High line voltage (above nameplate) | Check voltage |
| E114 | Line frequency out of range; no 60 Hz | Check voltage and frequency |
| E115 | Low 24 V (range 18–30 V); control restarts when recovered | Check 24 V |
| E117 | Poor ground detected (warning only) | Provide proper grounding; clears 30 s after recovery |
| E118 | Reset limit exceeded, hard lockout: six manual soft-lockout exits within 15 min | Power-cycle to clear |
| E120 | Unresponsive device; usually the outdoor unit slow to answer polling | Recycle power, check wiring |
| E124 | Communicating thermostat signal missing more than 3 min | Check connections; cycle power on the thermostat |
| E125 | Control failed self-check / internal hardware error (flame-sense circuit, pin shorts) | Cycle power; replace control if persistent |
| E126 | Failed internal communication between microcontrollers | Cycle power; replace control if persistent |
| E331 | Global network connection link problem | For future use |

## Sensors, blower configuration and gas valve (E180–E205)

| Code | Meaning | Action |
|---|---|---|
| E180 | Outdoor air sensor failure; only if shorted or out of range (no error if disconnected) | Check sensor |
| E200 | Hard lockout: rollout circuit open or previously open | Correct the cause of the rollout trip or replace the flame rollout switch; test furnace |
| E201 | Indoor blower communication failure (includes power outage) | Check blower motor communication |
| E202 | Indoor blower motor mismatch: motor hp does not match unit capacity | Wrong unit size code; check size codes (II p.70) |
| E203 | Appliance capacity / size not programmed | Program the unit size code (II p.70) |
| E204 | Gas valve mis-wired | Check gas valve operation and wiring |
| E205 | Gas valve control relay contact shorted | Check gas valve operation |

## Ignition, pressure switches, flame and limit (E207–E252)

| Code | Meaning | Action |
|---|---|---|
| E207 | Hot surface ignitor sensed open | Measure ignitor resistance; replace if open or out of specification |
| E223 | Low pressure switch failed open | Measure in. w.c. across the low pressure switch on a heat call; inspect vent and combustion air inducer for restriction |
| E224 | Low pressure switch failed closed | Check switch for closed contacts; measure operating pressure; inspect vent and inducer |
| E225 | High pressure switch failed open | Measure in. w.c. across the high pressure switch on a heat call; inspect vent and inducer |
| E226 | High pressure switch failed closed | Check switch for closed contacts; measure operating pressure; inspect vent and inducer |
| E227 | Low pressure switch opened during trial for ignition or run | As E223 |
| E228 | Unable to complete pressure switch calibration | Retry after 300 s; check vent system and pressure switch wiring |
| E240 | Low flame current in run mode | Check flame sensor microamps (service_values.md); clean or replace sensor; check neutral-to-ground voltage (TABLE 40 / SM p.68) |
| E241 | Flame sensed out of sequence; flame still present | Shut off gas; check for a leaking gas valve |
| E250 | Limit switch circuit open | Find why the limit trips: overfire, low airflow |
| E252 | Discharge air temperature too high (gas heat only) | Check temperature rise, airflow and input rate |

## Soft lockouts (E270–E276)

Soft lockout clears after one hour with a call for heat, or by cycling the call for heat or power (II p.71).

| Code | Meaning | Action |
|---|---|---|
| E270 | Maximum ignition retries; no flame current sensed | Check gas flow, ignitor lighting the burner, flame sensor current (procedure slp99_no_ignition) |
| E271 | Maximum retries; last retry failed on the pressure switch opening | See E223 (procedure slp99_pressure_switch_lockout) |
| E272 | Maximum recycles; last recycle due to the pressure switch opening | See E223 and E225 |
| E273 | Maximum recycles; last recycle due to flame failure | See E240 |
| E274 | Maximum recycles; limit circuit opened or stayed open longer than 3 min | See E250 |
| E275 | Flame sensed out of sequence (from E241); flame signal now gone | See E241 |
| E276 | Maximum pressure-switch calibration retries | See E228 |

## Motors and airflow (E290–E313)

| Code | Meaning | Action |
|---|---|---|
| E290 | Ignitor circuit fault: failed ignitor or triggering circuitry | See E207 |
| E291 | Restricted airflow: cfm below what minimum firing rate needs | Check filter, airflow restriction, blower performance |
| E292 | Indoor blower motor unable to start (seized bearing, stuck wheel) | Replace motor or wheel if the assembly will not run or perform |
| E294 | Combustion air inducer amp draw too high | Check inducer bearings, wiring, amps; replace if it does not perform |
| E295 | Indoor blower motor over temperature (internal protector tripped) | Check motor bearings and amps; replace if necessary |
| E310 | Discharge air temperature sensor (DATS) out of range; only shorted or out of range, shown in Field Test mode | Check DATS location and wiring (SM p.69–70) |
| E311 | Heat rate reduced to match blower airflow (cutback) | Replace filter or repair duct restriction |
| E312 | Restricted airflow in cooling or continuous fan; blower running below cfm setting (cutback, 0–0.8 in. w.c. design range) | Check filter and ductwork |
| E313 | Indoor / outdoor capacity code mismatch (warning only; clears when commissioning exits) | Check configuration per installation instructions |

## Relays and interlock (E345–E370)

| Code | Meaning | Action |
|---|---|---|
| E345 | O relay failure | Replace integrated control |
| E347 | No 24 V on Y1 to C with a non-communicating outdoor unit; Y1 / stage 1 relay failed | Check relay; replace control |
| E348 | No 24 V on Y2 to C with a non-communicating outdoor unit; Y2 / stage 2 relay failed | Check relay; replace control |
| E370 | Interlock switch open for 2 min (loss of 24 VAC on DS) | Wait for the interlock to close; clears after 10 s of continuous 24 VAC on DS or a power reset |

## Low GWP refrigerant detection, R-454B (E150–E164, E390)

The furnace control board runs the leak-detection system for an A2L (R-454B) coil. Source: SM p.22 and p.61–62; II p.53–55.

| Code | Meaning | Action |
|---|---|---|
| E150 | Refrigerant leak detected | Blower purges at high speed and 24 V to the thermostat is dropped; repair the leak and verify charge. Cannot be cleared while the sensor reports a leak |
| E151 | Leak detector sensor #1 fault | Sensor may need replacement; clears when the sensor stops reporting a fault |
| E152 | Leak detector sensor #2 fault | As E151 |
| E154 | Sensor #1 communication lost, or invalid sensor DIP switch (enable/disable) | Check harness, connector and sensor for damage; check Low GWP DIP switches. Blower latches at least 5 min; retest with the LGWP test button |
| E155 | Sensor #2 communication lost | As E154 |
| E160 | Sensor #1 type incorrect for this application | Replace with a Lennox-approved sensor; blower latches at least 5 min |
| E161 | Sensor #2 type incorrect | As E160 |
| E163 | Furnace control board failure (Low GWP) | May require control board replacement; clears when the controller operates normally |
| E164 | Low GWP test mode (test button pressed) | Normal operation resumes and the code clears after 1 min |
| E390 | Low GWP relay stuck | May require control board replacement; clears when the relay operates normally |
