# Vehicle / EV Status Tool

**Status:** ✅ v1 shipped on `feat/vehicle-tool` (Home Assistant path).

## Why this shape

iOS sandboxes apps — we **cannot** read a vendor car app's data (Tesla, etc.) directly. The reliable bridge is **Home Assistant**: most cars and chargers (Tesla, Wallbox, Easee, Ohme, Zaptec, Enode/Smartcar-via-HA) expose battery %, range, charging state, and plug status as HA entities. OpenGlasses already integrates HA, so the tool reads those sensors with **no new auth or infrastructure**.

## v1 (this PR)

- **`vehicle_status`** native tool ([VehicleTool.swift](../../OpenGlasses/Sources/Services/NativeTools/VehicleTool.swift)) — no params; answers "what's my car's charge?", "is it charging?", "how much range?".
- Resolves metrics by **fuzzy-matching** the HA entity cache (`HomeAssistantEntityCache.fuzzyMatch`), force-refreshed for a live reading. Pure, tested `summary(...)` formatter turns the raw states into one sentence ("Tesla Battery: 72% charged, about 210 mi range, currently charging, plugged in.").
- Registered in `NativeToolRegistry`; described in the `LLMService` + `GeminiLive` prompts.
- Graceful when HA isn't configured or no vehicle sensors are found (tells the user to expose the car to HA).
- 6 headless tests on the formatter.

## Follow-ups

- **Explicit entity overrides** in Settings → Services → Vehicle (battery / range / charging / plug entity IDs) for when fuzzy matching picks the wrong sensor. The tool is structured so this is a small addition (swap `resolve`'s fuzzy lookup for a configured id first).
- **Vendor-direct path** — a `Smartcar` or `Enode` integration (one OAuth, most brands) for users who don't run Home Assistant. Larger (OAuth + token storage); the `summary` formatter and tool surface are reused as-is.
