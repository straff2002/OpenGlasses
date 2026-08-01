# Building a Skill Pack

A skill pack adds voice-invocable capability to OpenGlasses as **installable data** — no app
update, no code (Plan BX). A pack is a folder with a `skillpack.json` manifest plus optional
payload files, zipped.

## The fast loop

```bash
mkdir mypack && $EDITOR mypack/skillpack.json     # write the manifest (reference below)
./Scripts/serve-skillpack.sh mypack               # serves over LAN + prints a QR
```

Turn on **Settings → Skill Packs → Developer Mode**, scan the QR with the iPhone camera, and the
app previews the pack and asks to install. Edit, re-run, re-scan — seconds per iteration.
Sideloads work over HTTPS anywhere, or plain HTTP on your own LAN only; unsigned packs always
require Developer Mode and are badged `UNSIGNED`.

## Manifest reference

```json
{
  "id": "com.you.mypack",            // reverse-DNS, required
  "version": "1.0.0",                // semver, required
  "name": "My Pack",                 // required
  "summary": "One line for the catalog row",
  "minAppBuild": 331,                // optional — refuse on older builds
  "hardware": [                      // optional
    {"type": "camera",  "level": "optional"},   // "camera" | "display"
    {"type": "display", "level": "required"}    // "required" blocks install without it
  ],
  "actions": [ … ],                  // see below; ≤ 32
  "settings": [                      // rendered by the host, no UI code
    {"key": "roast_level", "type": "select", "label": "Roast level",
     "options": ["light", "medium", "dark"]}
    // types: "toggle" | "select" | "text" | "number"
  ]
}
```

### Actions

Each action is a JSON-Schema tool declaration the assistant can call. Write the `description` for
the model: say *when to use it*, not what it is.

```json
{
  "name": "dial_in_shot",            // lowercase identifier; registered as pack_<id>_<name>
  "description": "Use when the user wants help dialing in espresso — shot ran fast/slow, tastes sour/bitter.",
  "parameters": {                    // JSON-Schema object (or omit for none)
    "type": "object",
    "properties": {"shot_time_s": {"type": "number", "description": "Shot time in seconds"}}
  },
  "binding": { … }                   // what the action does — one of four kinds
}
```

### Bindings

| Kind | Shape | Behaviour |
|---|---|---|
| `prompt` | `{"kind": "prompt", "template": "…"}` | The filled template rides the normal assistant turn as tool output. |
| `tool` | `{"kind": "tool", "name": "set_timer", "boundArgs": {"label": "focus"}}` | Composes over a **native** tool. Bound args are templates and win over caller args; purely numeric/boolean results are typed (`"300"` → `300`). |
| `procedure` | `{"kind": "procedure", "id": "…"}` | Reserved — parses today, runs in a later build. |
| `gateway` | `{"kind": "gateway", "task": "…"}` | Delegates to the remote agent. Inert unless Agent Mode is on. |

Templates substitute `{{param}}` from the call's arguments and `{{setting.key}}` from the pack's
configured settings. Unmatched placeholders stay visible in the output on purpose — a mismatch
should be diagnosable from the transcript.

### What the validator refuses

Non-reverse-DNS ids, non-semver versions, >32 actions, duplicate or native-colliding action
names, non-object parameter schemas, `tool` bindings to unknown native tools, empty prompt
templates, oversized descriptions/templates — and any description the Plan R definition screen
flags (instructions to the model hidden in a description reject the whole pack). A pack with one
malformed action installs the rest and reports the drop by name.

## Publishing to the catalog

Signing and the index flow live in [`skillpacks/README.md`](../skillpacks/README.md). Sources for
the first-party packs are under `skillpacks/src/` as working examples — `com.openglasses.barista`
(prompt bindings + a setting) and `com.openglasses.focus` (tool binding with typed bound args).
