# Plan CI — Broadcast Chat Read-Aloud (two-way streaming)

**Status: 📋 Planned (2026-08-02)**

`BroadcastService` streams the glasses POV out over RTMP; nothing comes back. A streamer
wearing glasses can't see chat at all — their phone is in their pocket. Reading chat to them
over TTS (and mirroring a line or two on the HUD when a display backend is up) turns
broadcast from a one-way feed into something you can actually host from.

## Deterministic core

- **`ChatMessageParser` (pure):** platform wire line → `ChatMessage(user, text, badges)`.
  Twitch first: IRC-over-WebSocket lines (`PRIVMSG`, tags for badges/emotes) parsed with
  fixture tests covering emote-only messages, `/me` actions, tag escaping, and UTF-8 names.
  The parser is per-platform behind one protocol; YouTube Live chat (API-polled JSON) is a
  second conformer later.
- **`ChatReadbackPolicy` (pure):** the taste layer — decides which messages get spoken.
  Inputs: message stream + TTS-busy state + clock. Rules as data, each tested: rate cap
  (max N spoken/minute, drop-oldest queue with cap), dedup window (identical text within
  30 s reads once, "×3" suffix), strip URLs and emote spam, skip bot/command prefixes
  (`!so`, `!uptime`), name-then-text rendering with names spoken once per burst
  ("Sam says: great view — and: where is this?"). Mentions of the streamer's handle jump
  the queue. Output is `SpokenChatItem`s — the policy never touches TTS directly.

## Wiring (thin)

- **Twitch read connection:** anonymous read-only IRC login over WebSocket to the channel
  being broadcast to — read access needs no OAuth, so v1 ships with zero new auth surface.
  Channel name derives from the configured stream target; a settings override exists for
  restreams. Reconnect with capped backoff; the connection lives and dies with
  `BroadcastService`'s active session.
- **Speech:** spoken items go through `TextToSpeechService` at a lower priority than
  assistant replies (assistant speech pre-empts chat, chat never queues behind itself more
  than the cap). While a realtime session is live, chat readback is suppressed entirely —
  two voices in the ear is chaos (policy input, tested).
- **HUD mirror (optional):** when a display backend is up, the last 2 messages render as an
  ambient lines-only screen through the normal render queue; no interaction in v1.
- Settings: per-broadcast toggle (default off), rate cap slider, "mentions only" mode.

## Phases

- **P1 — cores:** parser + policy + tests (fixtures incl. hostile input: control chars,
  10k-char messages, tag-injection attempts — output is always plain text for TTS).
- **P2 — wiring:** WebSocket client, broadcast lifecycle coupling, TTS priority lane,
  settings. Sim-testable end-to-end against a fake server.
- **P3 — device smoke (deferred):** readback volume vs. ambient mic pickup while streaming
  (does the TTS bleed into the broadcast mic?), battery, YouTube chat conformer.

## Non-goals

- No posting to chat, no moderation actions — read-only.
- No LLM summarization of chat in v1 (a "summarize the last minute of chat" tool is a natural
  follow-up but rides on this plan's parser, not in it).
