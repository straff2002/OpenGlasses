# Conductor figures

Conductor areas and factors for voltage drop come from the `domain_calc` tool, not from this file. Never quote
a conductor's area, resistance or factor from memory.

- `voltage_drop` takes a wire's AWG size, or its area in mm², with its metal (copper or aluminium) and reads
  the standard areas and the factors at 75 °C from the app's conductor data. Its answer names the figures and
  their source; repeat them.
- The metal comes from the technician, never a guess.
- A resistance, factor or area from the organisation's own book or the technician wins over the app's figures:
  pass it instead.
