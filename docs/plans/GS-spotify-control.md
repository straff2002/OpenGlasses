# Plan GS — Spotify Playback Control and "What's Playing"

**Status:** 📝 Drafted (not scheduled), 2026-10-01 — nothing built. **Blocked for the App Store
build by Spotify's developer policy (Decision 1)**; the shippable part is a music-provider layer
with Apple Music and Home Assistant providers.
**Extends:** `music_control` (`NativeTools/MusicControlTool.swift`, Apple Music via MediaPlayer).
**Related:** Plan [CH](CH-media-button-trigger.md) / Plan [GJ](GJ-remappable-temple-gestures.md)
(temple taps), Plan [GF](GF-recipe-add-ons.md) (not a viable route), Plan [GR](GR-android-tv-control.md)
(shares the Home Assistant service-data change), `ShazamTool`.

---

## Trigger

People who use Spotify expect "play my Discover Weekly", "skip", "what's this song?" and "like it"
to work from their glasses. Today `music_control` only drives the Apple Music app, and asking for
Spotify gets nothing useful.

## Decision 1 — Spotify's developer policy and quotas (verified 2026-10-01)

1. **Voice control is a prohibited application.** The Spotify Developer Policy (effective 15 May
   2025), section III "Some prohibited applications", says: "Do not create a voice-enabled SDA that
   enables a user to control Spotify with their voice, or any kind of voice assistant that provides
   voice-control functionality." The policy governs everything built on the Spotify Platform — the
   Web API and the iOS SDK (App Remote) alike.
2. **Development Mode is capped.** Since 11 Feb 2026 for new apps (9 Mar 2026 for existing ones), a
   Development Mode app allows **up to 5 authenticated users**, each allowlisted by hand, and the app
   owner must hold Premium. The 23 Jul 2026 update raised the Client ID limit to 25 per developer
   account and pooled quota per account; it did not change the user cap. Development Mode also
   lost several endpoints and fields in February 2026 (library writes consolidated into
   `PUT /me/library` with URIs; search `limit` max 10).
3. **Extended Quota is out of reach.** Since 15 May 2025 extended quota is granted only to an
   established, legally registered business or organisation with a launched service, at least
   250k monthly active users, availability in key Spotify markets, and commercial viability; review
   takes up to six weeks. The app's developer account is an individual one.
4. **The iOS SDK** (App Remote, `SpotifyiOS` 5.0.1, available through Swift Package Manager) needs the
   Spotify app installed and authorises with the same Client ID, so it is bound by the same policy
   and the same user allowlist.

**Consequence for a public App Store release:** Avenkin cannot integrate the Spotify Platform
(Web API or App Remote) for voice control — the use case itself is prohibited, independently of
the 5-user cap. Building it anyway would put the Client ID, and plausibly the App Store listing, at
risk. **Recommendation:** do not ship a Spotify Platform integration; ship the provider layer below,
and keep the Web API design in this plan as a blocked phase (P3) that is built only if Spotify gives
written permission or the policy changes.

**Recipe add-ons are not a way around it.** GF refuses `oauth` MCP entries at install and recipe
`http` steps have no OAuth flow, so a recipe cannot hold a Spotify user token — and the policy would
bind the add-on author the same way. The app will not ship or promote one.

## Outcome (what can ship)

- A **default music provider** setting: Apple Music (today's behaviour) or a **Home Assistant media
  player** (which may be a Spotify Connect speaker, a Sonos, or HA's own Spotify entity — HA holds
  its own Spotify credentials under its own arrangement; Avenkin never calls Spotify).
- "Play / pause / skip / previous / volume" go to the default provider; "on the kitchen speaker"
  picks a specific HA media player.
- "What's playing?" answers from the provider that is playing (Apple Music now-playing item; HA's
  `media_title`/`media_artist`), and says honestly when it cannot see another app's playback.
- When the wearer names Spotify and no route exists, one clear sentence: Avenkin can't control
  the Spotify app directly; the glasses' temple controls still work on whatever is playing, and a
  Home Assistant speaker can be set as the music provider. Copy never names plan letters.

## What exists today (verified 2026-10-01)

- `MusicControlTool` (`music_control`): `MPMusicPlayerController.systemMusicPlayer` + `MPMediaQuery`
  library search; actions play/pause/toggle/next/previous/now_playing/search/play_song/play_artist/
  shuffle; posts `MediaTriggerService.userPlaybackRequested` before commands so the temple-tap claim
  (Plan CH) stands down. `NSAppleMusicUsageDescription` is present.
- Spotify today: only `spotify` in `LSApplicationQueriesSchemes`, `"spotify": "spotify://"` in
  `OpenAppTool`, and a Discover row in `DiscoverCapabilitiesTool`. No Spotify SDK, no OAuth.
- OAuth building blocks exist: `PKCE` (`Utils/OAuthSupport.swift`), `ASWebAuthenticationSession` use
  in `GoogleOAuthService`, `KeychainService`, and `NetworkRouteRegistry` routes for other providers'
  tokens (`googleOAuthToken`, …).
- `HomeAssistantTool.callService` posts only `entity_id` — enough for `media_player.media_play_pause`,
  `media_next_track`, `volume_up`, not for `play_media` or `volume_set` (need service data).
- iOS offers no public API to read or control *another* app's playback: `MPNowPlayingInfoCenter`
  is the app's own entry, `systemMusicPlayer` is the Music app only.

## Design (shippable part)

**`MusicProvider` protocol** (`@MainActor`): `id`, `displayName`, `capabilities` (play, pause, next,
previous, volume, nowPlaying, playByName, like, devices), `perform(_ command:) async ->
MusicCommandResult`, `nowPlaying() async -> NowPlayingSummary?`. Two conformances:
- `AppleMusicProvider` — today's `MusicControlTool` body moved behind the protocol, unchanged
  behaviour; `like` unsupported (MediaPlayer cannot rate; MusicKit is a separate decision).
- `HomeAssistantMusicProvider` — any `media_player.*` entity: transport and volume services,
  `play_media` for a named playlist/URI only when the entity advertises it, now-playing from the
  entity's attributes. Uses the service-data extension shared with GR P2 (allowlisted keys:
  `media_content_id`, `media_content_type`, `volume_level`, `source`).

**`MusicCommandRouter`** (pure): utterance-level command + named target ("on the kitchen speaker",
"on Spotify") + default provider + which provider is currently playing → a provider and command, or
an honest refusal line. Rules: a named HA speaker wins; "on Spotify" with no HA route → the refusal
above; otherwise the provider that is playing, else the default.

**`music_control` tool**: same name and actions (no model-visible churn), plus optional `provider`
and `device`; new `devices` action lists HA media players. `description` rewritten so the model
stops promising Spotify.

**Settings**: Settings → Music (general section, not glasses): default provider, HA speakers to
expose (from the HA entity cache), "Ask which speaker when unsure". No telemetry: no SDK is linked,
so `TelemetryOptOutGuardTests` and `PrivacyInfo.xcprivacy` are untouched in the shippable phases.

**Temple taps (CH/GJ).** When Spotify (or any app) plays on the phone it owns Now Playing, and the
glasses' AVRCP play/pause/next/previous go straight to it — nothing to build, and GJ already
yields taps to the wearer's own music. When music plays on an HA speaker the phone is silent, so
the CH claim may hold Now Playing; GJ gains an optional tap action "music play/pause (default
provider)" that routes through `MusicCommandRouter`.

**Shazam** stays for identifying ambient music; it cannot hear audio playing into the wearer's ears,
so "what's playing" never falls back to it silently — it offers ("want me to listen?") only for
ambient sound.

**Modes.** Phone-only identical. HIPAA/Medical Local Only: HA provider follows
`homeAssistantCommand`'s policy. Not agentic — no Agent Mode gate. CarPlay: spoken answers only.

## Design (blocked phase — Spotify Web API provider)

Specified so the work is ready if Decision 1 changes; **not to be built otherwise.**
- **Auth:** Authorization Code + PKCE via `ASWebAuthenticationSession` and the existing `PKCE`
  helpers; redirect on a claimed scheme; scopes `user-read-playback-state`,
  `user-modify-playback-state`, `user-read-currently-playing`, `user-library-read`,
  `user-library-modify`; access/refresh tokens in `KeychainService` (this-device-only); refresh on
  401; sign-out deletes both. Routes `spotifyOAuthToken` (`.credential`, first-party cloud) and
  `spotifyWebAPI` (`.promptText`, `.credential`), both `blockedWhenLocalOnly`.
- **Player:** `GET /me/player` and `/me/player/currently-playing` for "what's playing";
  `PUT /me/player/play|pause`, `POST /me/player/next|previous`, `PUT /me/player/volume`;
  `GET /me/player/devices` and `PUT /me/player` (transfer) for device choice. Playback control
  requires Premium — a 403 becomes "Spotify only lets Premium accounts be controlled remotely".
- **Play by name:** `GET /search` (≤ 10 results in Development Mode) → pick by type and exact-name
  match → `PUT /me/player/play` with `context_uri` or `uris`.
- **Like/save:** `PUT /me/library` with the track URI (the post-February 2026 endpoint).
- **Limits:** honour `429` + `Retry-After`; `"reason": "QUOTA_EXCEEDED"` becomes "Spotify's limit for
  this app is used up today".
- **Attribution:** policy II.4 requires attributing Spotify content and linking back where metadata
  or art is displayed — the phone card shows the Spotify attribution and an "Open in Spotify" link.
- **App Remote SDK:** not recommended even then (it needs the Spotify app installed, connecting may
  switch to it — device-unverified — and it adds a closed binary that would need the MWDAT-style
  telemetry `strings` review and disclosure).

## Phases (one PR each)

**P0 — Provider layer (pure + Apple Music move).** `MusicProvider`, `AppleMusicProvider` (behaviour
unchanged), `MusicCommandRouter`, `NowPlayingSummary` phrasing. Tests: `MusicCommandRouterTests`
(named speaker wins; "on Spotify" without a route → refusal line; playing provider beats default),
`AppleMusicProviderTests` over an injected player seam, `MusicControlToolTests` regression (same
actions, `userPlaybackRequested` still posted).

**P1 — Home Assistant provider.** HA client service-data support (shared with GR P2 — whichever
lands first adds it), `HomeAssistantMusicProvider`, settings, `devices` action. Tests:
`HomeAssistantMusicProviderTests` (request bodies, attribute parsing, unsupported `play_media`),
`HomeAssistantServiceDataTests` (allowlist rejects other keys).

**P2 — Surfaces.** Settings → Music, GJ tap action, refusal copy, device checks (owed): HA with a
Spotify Connect speaker, phone locked, Spotify playing on the phone with temple taps.

**P3 — Spotify Web API provider (blocked by Decision 1).**

## Risks

- **Expectation gap.** Spotify is many users' main service; a clear, one-time explanation beats a
  silent failure. The refusal is short and offers what does work.
- **HA dependency.** The HA route helps only HA users; everyone else keeps temple controls and the
  Spotify app itself.

## Decisions for Greig

1. **Accept the policy finding: no Spotify Platform integration in the App Store build**
   (recommended), or approach Spotify for written permission before any P3 work. A personal
   Development Mode build is still a voice-enabled SDA under section III, so it is not a loophole.
2. **Default provider** for new installs: Apple Music (recommended, unchanged behaviour).
3. **MusicKit for Apple Music** (catalogue search, "add to library") as a follow-up plan, or not.
4. **Refusal wording** that mentions the glasses' built-in assistant (which may have its own Spotify
   link, region-dependent) or stays generic. *Recommend generic.*

## Out of scope

Spotify Platform integration (unless Decision 1 changes), podcasts, playlist editing, lyrics,
Apple Music catalogue search, and other streaming services' APIs.

## References

- Spotify Developer Policy (effective 15 May 2025): https://developer.spotify.com/policy
- Quota modes (Development Mode 5 users; extended quota criteria): https://developer.spotify.com/documentation/web-api/concepts/quota-modes
- February 2026 Development Mode changes: https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide
- Web API quota updates, 23 Jul 2026: https://developer.spotify.com/blog/2026-07-23-web-api-quota-updates
- Rate limits: https://developer.spotify.com/documentation/web-api/concepts/rate-limits
- iOS SDK overview: https://developer.spotify.com/documentation/ios — package: https://github.com/spotify/ios-sdk
