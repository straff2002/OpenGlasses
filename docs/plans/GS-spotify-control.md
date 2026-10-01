# Plan GS — Music Providers: Apple Music (with the MusicKit Catalogue) and Home Assistant Speakers

**Status:** ✅ Shipped 2026-10-01 — P0, P1, P2 and the MusicKit phase (P2a) in one PR: a `MusicProvider`
layer behind the unchanged `music_control` tool; Apple Music plays from the whole catalogue through
MusicKit for subscribers and from the library otherwise; any Home Assistant media player can be the
default provider; Settings → Services → Music; a "Play or pause music" temple-tap action in the GJ set.
**P3 (Spotify Web API) stays blocked** by Spotify's developer policy (Decision 1, accepted) and is not
to be built unless that changes. **Owed:** device checks — catalogue playback with and without a
subscription, the first-use access prompt, playback with the phone locked and Avenkin backgrounded,
temple taps with Apple Music playing and with music on a Home Assistant (Spotify Connect) speaker,
add to library. MusicKit App Service is enabled on the App ID (no entitlement key needed).
**Extends:** `music_control` (`NativeTools/MusicControlTool.swift`).
**Related:** Plan [CH](CH-media-button-trigger.md) / Plan [GJ](GJ-remappable-temple-gestures.md)
(temple taps), Plan [GF](GF-recipe-add-ons.md) (not a viable route), Plan [GR](GR-android-tv-control.md)
(shares the Home Assistant service-data allowlist, which this plan added), `ShazamTool`.

The file keeps its original name; the plan began as "Spotify playback control", and the Spotify
policy finding below is why it became a music-provider plan.

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

## Outcome (shipped)

- A **default music provider** setting: Apple Music (the default for new installs and for everyone
  upgrading — unchanged behaviour) or a **Home Assistant media player** (a Sonos, a smart speaker, or
  a speaker Home Assistant plays a streaming service on under its own account link; Avenkin never
  calls a streaming service).
- **Apple Music by name, from the whole catalogue.** With Apple Music access allowed and a
  subscription that can play catalogue content, "play Rumours by Fleetwood Mac", "play the album …",
  "play my … playlist", "play jazz radio" and "play some songs by …" search the Apple Music catalogue
  and play the best match. Without a subscription it plays from the wearer's library, exactly as
  before; when neither has it, one sentence says why. "Add this to my library" (and "like", its
  honest nearest thing — apps cannot love a song).
- "Play / pause / skip / previous / volume" go to the provider that is playing, else the default;
  "on the kitchen speaker" picks a specific Home Assistant media player.
- "What's playing?" answers from the provider that is playing — title, artist, album and year, and
  how far in — and says honestly when it cannot see another app's playback.
- When the wearer names Spotify (or another service with no route), one generic sentence: Avenkin
  can't control it directly; the glasses' temple controls still work on whatever's playing, and a
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

## Design — Apple Music catalogue through MusicKit (P2a, added 2026-10-01)

Greig asked for Apple Music access; the MusicKit App Service is enabled on the App ID
`com.openglasses.app`. MusicKit is a system framework: no SDK is linked, the developer token comes
from the App Service, and no key ships. API shapes were checked against the iOS 27 SDK
`MusicKit.swiftinterface`.

- **Access.** `MusicAuthorization` reuses `NSAppleMusicUsageDescription` (reworded to mention the
  catalogue and adding to the library). The prompt is only shown while Avenkin is in the foreground
  (a locked phone cannot show it): from the glasses the first time, the answer is "open Avenkin on
  your phone once and allow access"; Settings → Services → Music has an "Allow Apple Music Access"
  button. Denied → one sentence pointing to iPhone Settings.
- **Catalogue or library.** `MusicSubscription.current.canPlayCatalogContent` decides. True →
  `MusicCatalogSearchRequest` over the kinds the request allows, ranked, played. False → the library
  (MediaPlayer). Unknown (offline) → the library. A catalogue miss or error falls through to the
  library; only when both miss does the answer explain (subscription needed, access off, Medical
  Local Only, or "couldn't find it"). Never a dead end.
- **Player: `SystemMusicPlayer`, not `ApplicationMusicPlayer`.** The system player plays in the Music
  app's process, so playback survives Avenkin being backgrounded or killed and the phone locking,
  with no background-audio work of Avenkin's own. An application player would put the wearer's music
  on Avenkin's audio session — the wake-word listener's, speech output's and the temple-tap claim's —
  where every reply and listening turn would duck or interrupt it, and where
  `MediaTriggerPolicy` would see no "other audio" and could claim Now Playing over the wearer's own
  music. With the system player the Music app owns Now Playing, the policy stands down, the glasses'
  temple controls go straight to Music, and `music_control` still posts
  `MediaTriggerService.userPlaybackRequested` before every command. It is also the player the library
  path drives, so pause/skip/"what's playing" behave the same whichever path started the music.
- **Pure core.** `MusicRequestParser` (kind hints — "the album", "playlist", "radio"/"station",
  "songs by" — a "<title> by <artist>" reading kept alongside the whole phrase because "Stand by Me"
  is a title, and trailing targets such as "on the kitchen speaker" / "on Spotify");
  `MusicCatalogRanker` (an explicit kind filters; exact title beats contains; a named artist that
  matches is a strong bonus and one that does not a strong penalty; edition tags like "(Remastered
  2009)" ignored; popularity only breaks ties; nothing below a threshold plays); `MusicPhraser`. The
  library path ranks its own matches through the same ranker. MusicKit sits behind
  `MusicCatalogServing` (production `MusicKitCatalog`), MediaPlayer behind `MusicLibraryPlaying`
  (production `MediaPlayerLibrary`); tests never reach either.
- **Artists** are not playable in MusicKit: their top songs are queued shuffled, else their station.
- **Add to library** uses `MusicLibrary.shared.add` on a searched item, or on what is playing (its
  catalogue id is the now-playing item's `playbackStoreID`); "already in your library" is reported
  as such. It needs a subscription.
- **Privacy.** Catalogue search terms go to Apple. The privacy page's Apple row and the Apple Music
  permission line say so; `PrivacyInfo.xcprivacy` already declares `SearchHistory` (App
  Functionality, not linked) and its notes now name the MusicKit egress; Settings → Services → Music
  says it in-app. There is no `NetworkRoute` for it because Avenkin owns no transport — like MapKit
  search and ShazamKit, the request is the system framework's — so Medical Local Only is enforced in
  `AppleMusicProvider` instead: under it only the library is searched and nothing is added.

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

## Phases

All of P0–P2a shipped in one PR (2026-10-01).

**P0 — Provider layer. ✅** `MusicProvider`, `AppleMusicProvider` (transport behaviour unchanged),
`MusicCommandRouter`, `NowPlayingSummary` phrasing. Tests: `MusicCommandRouterTests` (named speaker
wins; "on Spotify" without a route → refusal line; playing provider beats default; unusable Home
Assistant falls back to Apple Music; "what's playing" never asks which speaker),
`AppleMusicProviderTests` over injected seams, `MusicControlToolTests` regression (same name and
actions; `userPlaybackRequested` still posted for commands, not for reads or speaker commands).

**P1 — Home Assistant provider. ✅** `HomeAssistantServiceData` (allowlist: `media_content_id`,
`media_content_type`, `volume_level`, `source`; typed and range-checked; also accepted by the
`home_assistant` tool's `call_service` as `data`), `HomeAssistantRESTClient` on the
`homeAssistantCommand` route, `HomeAssistantMediaPlayer` parsing, `HomeAssistantMusicProvider`
(transport, volume — step service or `volume_set` ± 10 %, `play_media` only when advertised,
now-playing from attributes), `devices` action. Tests: `HomeAssistantMusicProviderTests`,
`HomeAssistantServiceDataTests`.

**P2 — Surfaces. ✅** Settings → Services → Music (default provider, Apple Music access and
catalogue status, speakers to make available, default speaker, "Ask Which Speaker When Unsure"),
the GJ tap action "Play or pause music" (standby only; routed like a spoken "pause"; speaks only an
answer the wearer needs), generic refusal copy.

**P2a — Apple Music catalogue (MusicKit). ✅** As designed above. Tests: `MusicRequestParserTests`,
`MusicCatalogRankerTests`, `MusicPhraserTests`, plus the catalogue cases in
`AppleMusicProviderTests`.

**Device checks owed:** catalogue play with and without a subscription; first-use prompt from the
phone and the glasses; playback with the phone locked and Avenkin backgrounded; temple taps with
Apple Music playing (they go to Music) and with a Home Assistant Spotify Connect speaker playing
(the music tap action); add to library; a Home Assistant speaker's `play_media` by name.

**P3 — Spotify Web API provider (blocked by Decision 1).** Not built; not to be built unless Spotify
gives written permission or the policy changes.

**Where the draft was wrong or moved.** The draft said MusicKit would not change "like": MusicKit has
no rating API for apps either, so "like" adds to the library and says so. It planned to list
speakers from `HomeAssistantEntityCache`, which keeps no attributes (`supported_features`, media
titles), so the provider reads `/api/states` through its own client on the same route. The Music
screen sits under Services beside Parking rather than as a top-level section. "Otherwise the
provider that is playing, else the default" is applied to transport only; play-by-name goes to the
default provider. The draft's "no telemetry, `PrivacyInfo.xcprivacy` untouched" held for P0–P2; the
MusicKit phase adds an Apple egress, disclosed as above.

## Risks

- **Expectation gap.** Spotify is many users' main service; a clear, one-time explanation beats a
  silent failure. The refusal is short and offers what does work.
- **HA dependency.** The HA route helps only HA users; everyone else keeps temple controls and the
  Spotify app itself.

## Decisions (Greig, 2026-10-01)

1. **Accepted:** no Spotify Platform integration in the App Store build. A personal Development Mode
   build is still a voice-enabled SDA under section III, so it is not a loophole.
2. **Default provider:** Apple Music for new installs (unchanged behaviour).
3. **MusicKit: yes, in this PR** (catalogue search and play, add to library) — the P2a phase.
4. **Refusal wording:** generic — it does not mention the glasses' built-in assistant.

## Out of scope

Spotify Platform integration (unless Decision 1 changes), podcasts, playlist editing, lyrics,
rating ("love") — not in MusicKit's app API — and other streaming services' APIs.

## References

- Spotify Developer Policy (effective 15 May 2025): https://developer.spotify.com/policy
- Quota modes (Development Mode 5 users; extended quota criteria): https://developer.spotify.com/documentation/web-api/concepts/quota-modes
- February 2026 Development Mode changes: https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide
- Web API quota updates, 23 Jul 2026: https://developer.spotify.com/blog/2026-07-23-web-api-quota-updates
- Rate limits: https://developer.spotify.com/documentation/web-api/concepts/rate-limits
- iOS SDK overview: https://developer.spotify.com/documentation/ios — package: https://github.com/spotify/ios-sdk
