# Safety — Lennox SLP99UHVK gas furnace

Read the matching reminder aloud before the technician opens a panel, the gas train, the burner box, or touches the control. Every line below comes from the SLP99UHVK Service Manual (SM) or Installation Instructions (II); page numbers are the printed ones.

## Before opening any panel — electrical

- Turn electrical power to the unit OFF at the disconnect switch(es) before any service or maintenance. The unit may have more than one power supply (SM p.1, II p.61).
- Do not touch the blower drive (ECM motor) until its LEDs are off (II p.33).
- The unit must be properly grounded per national and local codes; use copper wire only, never aluminium (II p.33). A poorly grounded furnace shortens ignitor life; the ground check is in service_values.md (SM p.68).
- Handle the integrated control with electrostatic-discharge precautions: touch hand and tools to bare metal first (II p.33).
- During blower operation the ECM motor emits energy that can interfere with a pacemaker; distance and the cabinet reduce it (II p.61).

## Before opening the gas train or burner box — gas

- Never use an open flame to test for gas leaks. Use a commercial leak-detection solution and rinse it off afterwards; some soaps corrode gas-piping metals (II p.30, SM p.64).
- Isolate and disconnect the gas valve before any line pressure test at or above 1/2 psig (14 in. w.c.); higher pressure damages the valve (II p.30, SM p.64).
- Do not attempt to adjust the gas valve, the pressure switches, or the primary limit. They are factory set; vault values are measurements to compare against, not targets to adjust to (II p.62 and p.64, SM p.67).
- Gas piping to the valve is torqued between 350 and 800 in-lbs, using two wrenches so no torque reaches the manifold. Only black iron pipe inside the cabinet (II p.30).
- Move the gas valve switch by hand only, never with tools. If it will not move by hand, do not force or repair it (II p.61).
- Before placing the unit in operation, smell all around the furnace area for gas, including next to the floor. If gas is smelled after the five-minute wait, stop and call the gas supplier from outside (II p.61).
- LP/propane settles near the floor and its odorant can fade; an LP leak detector should be installed in every LP application (II p.4).
- If the gas supply fails to shut off, or the furnace overheats, shut off the gas valve to the furnace before shutting off the electrical supply (II p.61, SM p.63).

## Emergency and shutdown

- Emergency shutdown: turn off unit power and close the manual and main gas valves (SM p.64). The installer should have labelled these controls.
- Do not use a furnace that has been under water. A flood-damaged furnace must be inspected and its gas controls, control-system parts, and electrical parts replaced before use (II p.61, SM p.63).

## Flame rollout and lockouts

- The two flame rollout switches are manual reset, inside the burner box. If tripped, confirm adequate combustion air and find the cause before resetting; E200 is the hard lockout for an open or previously open rollout circuit (II p.64, SM p.19).
- Soft lockouts reset automatically after one hour with a call for heat active, or by cycling the call for heat or power. Hard lockout is reset by cycling power to the control (II p.71). Six manually exited soft lockouts in 15 minutes hard-locks the control with E118 (SM p.19).

## R-454B (A2L) refrigerant detection

- The ignition control is factory enabled for Lennox A2L refrigerant systems. Disabling refrigerant detection on an A2L system is prohibited by safety codes (SM p.1).
- On a detected leak (E150) the control drops 24 V to the thermostat, runs the blower at high speed to purge, and holds it for the rest of a seven-minute cycle. Do not defeat this; the fault cannot be cleared while the sensor still reports a leak (SM p.22 and p.61).
- Use only Lennox-approved evaporator coils and LGWP sensors, or the coil manufacturer's recommended sensor with a non-Lennox coil (II p.53).

## Handling and codes

- Sheet-metal edges are sharp; wear gloves and protective clothing (SM p.1).
- The SLP99UHVK is a Category IV, direct-vent-only furnace. Install and service per local codes; in their absence the National Fuel Gas Code (ANSI Z223.1/NFPA 54) in the USA or CSA B149 in Canada (II p.4). Manual procedures are recommendations and do not replace code (SM p.1).
- Do not run the furnace as a construction heater unless every condition on II p.5 is met (final location, permanent two-pipe venting, sealed ducts, MERV 11 filters, panels in place, return air 60–80 °F).
