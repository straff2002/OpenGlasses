# Building from Source

Full setup: Meta developer credentials, Universal Links, personal signing overlays,
in-app configuration, and troubleshooting. Start with the [Quick Start](../README.md#quick-start)
if you just want it running.

### 1. Clone

```bash
git clone https://github.com/straff2002/OpenGlasses.git
cd OpenGlasses
```

### 2. Meta Developer Credentials

1. Go to [wearables.developer.meta.com](https://wearables.developer.meta.com/)
2. Create an account, organization, and app
3. Note your **Meta App ID** and **Client Token**
4. In Meta dashboard → iOS settings, enter your Apple Team ID, Bundle ID, and Universal Link URL

### 3. Configure Meta keys

Your Meta **App ID** and **Client Token** are build settings, substituted into the committed
`OpenGlasses/Info.plist` at build time. Put them in the gitignored `project.local.yml` — never
in the plist itself:

```yaml
targets:
  OpenGlasses:
    settings:
      base:
        MWDAT_META_APP_ID: "<your Meta app id>"
        MWDAT_CLIENT_TOKEN_HASH: "<hash after the second | of your client token>"
```

Then re-run `./Scripts/generate-xcodeproj.sh`. A client token looks like
`AR|<app id>|<hash>`; only the trailing hash goes in `MWDAT_CLIENT_TOKEN_HASH`, since the plist
composes the rest. `./Scripts/setup-local-dev.sh` preserves both values when it rewrites
`project.local.yml`.

Without them the app builds and launches normally, but DAT registration never completes — and
because the camera permission prompt is gated behind registration, the symptom is a Connect
button that appears to do nothing rather than an obvious credentials error. The app names this
at launch (`⚠️ Glasses config is still the committed placeholder`) and in the connect-failure
message.

> Don't override `INFOPLIST_FILE` to a personal plist copy. That mechanism was removed: the
> copy went stale and silently dropped newly added usage descriptions (App Store ITMS-90683),
> and when it was withdrawn it took the Meta credentials with it.

### 4. Universal Links

Host an `apple-app-site-association` file at `https://YOUR-DOMAIN/.well-known/apple-app-site-association`:

```json
{
  "applinks": {
    "details": [{
      "appID": "YOUR_TEAM_ID.YOUR_BUNDLE_ID",
      "paths": ["/YOUR-PATH/*"]
    }]
  }
}
```

**Both ends must match your build, or registration silently never completes** (#246):

- The AASA `appID` must be **your** Team ID + bundle ID — a copied AASA still declaring the upstream app makes iOS refuse the domain association.
- Your entitlements file must contain the **associated-domains** entitlement for the same domain (`applinks:YOUR-DOMAIN`). Without it, iOS never even attempts the link-back. If you use a personal entitlements overlay, check it has:

```xml
<key>com.apple.developer.associated-domains</key>
<array>
    <string>applinks:YOUR-DOMAIN</string>
</array>
```

The failure mode when either end is wrong: approval completes in the Meta AI app, but the approval callback (a Universal Link) never reaches OpenGlasses — registration never finalises, the devices listener never fires, and connecting fails. The in-app error names the stalled registration state and points here.

### 5. Enable Developer Mode

On iPhone: Meta AI app → Settings → About → tap version number **5 times** → toggle Developer Mode on.

### 6. Build & Run

Same as [Quick Start](#quick-start) step 1. The repo ships [`project.base.yml`](project.base.yml) plus optional [`project.local.yml`](project.local.yml.example); XcodeGen writes `OpenGlasses.xcodeproj` locally. Do not commit the generated project.

```bash
brew install xcodegen
./Scripts/generate-xcodeproj.sh
open OpenGlasses.xcodeproj
```

[Xcode Cloud](https://developer.apple.com/documentation/xcode/xcode-cloud) runs `./Scripts/generate-xcodeproj.sh` in `ci_scripts/ci_post_clone.sh` (full app + watch + tests).

Default generate includes **watch** and **unit tests**. To build a slimmer project locally (iPhone + widget only):

```bash
cp .openglasses-generate.env.example .openglasses-generate.env   # gitignored
./Scripts/generate-xcodeproj.sh
```

Or one-off: `OPENGLASSES_SKIP_WATCH=1 OPENGLASSES_SKIP_TESTS=1 ./Scripts/generate-xcodeproj.sh`

#### Optional: personal signing & Meta config

Team ID, entitlements, and Meta keys differ per developer. Those settings live in **gitignored** files (never committed), merged on top of the shared spec via `project.local.yml`:

| File (gitignored) | Purpose |
|-------------------|---------|
| `project.local.yml` | Team ID + `DEVELOPMENT_TEAM`, personal entitlements paths, and the Meta credentials `MWDAT_META_APP_ID` / `MWDAT_CLIENT_TOKEN_HASH` (see `project.local.yml.example`) |
| `Config/Entitlements/Personal/*.entitlements` | Capabilities your provisioning profile supports |

First-time setup from the templates:

```bash
./Scripts/setup-local-dev.sh
```

Edit `project.local.yml` (`developmentTeam`) and the files under `Config/` as needed, then run `./Scripts/generate-xcodeproj.sh` again.

If you only need Xcode’s automatic signing with the shared entitlements, skip the local overlay and set your team in Xcode after opening the generated project.

Select your iPhone, fix signing if prompted, and run (⌘R).

---

## Configuration

All settings are in-app — no source code editing needed.

### API Keys (Settings → AI Models)

| Service | Purpose | Where to Get |
|---------|---------|--------------|
| Anthropic | Claude LLM | [console.anthropic.com](https://console.anthropic.com/) |
| OpenAI | GPT + Realtime | [platform.openai.com](https://platform.openai.com/) |
| Google Gemini | Gemini Live | [aistudio.google.com](https://aistudio.google.com/) |
| Groq | Fast inference | [console.groq.com](https://console.groq.com/) |
| ElevenLabs | Natural TTS | [elevenlabs.io](https://elevenlabs.io/) |
| Perplexity | Web search | [perplexity.ai/settings/api](https://perplexity.ai/settings/api) |

### Services (Settings → Services & Integrations)

| Service | Settings |
|---------|----------|
| **ElevenLabs** | API key + voice selection (24 voices) |
| **Perplexity** | API key (DuckDuckGo fallback if not set) |
| **Live Streaming** | Platform + RTMP URL + stream key + chat read-aloud (Twitch channel, rate, mentions-only) |
| **OpenClaw** | Enable + connection mode + host/port + token |
| **Home Assistant** | URL + Long-Lived Access Token |

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Wake word not detecting | Tap mic button to restart; check Bluetooth audio routing |
| No audio through glasses | Verify Bluetooth connection in iOS Settings |
| Glasses not connecting | Tap "Connect to Glasses"; enable Developer Mode in Meta AI app |
| Camera says "Your glasses need an update" | The glasses-side DAT software lags the SDK this app builds against. Update the Meta AI app from the App Store, power-cycle the glasses in their case, and if it persists unlink/relink the app connection in Meta AI. If none of that helps, Meta hasn't shipped the matching glasses update yet — everything else works; camera/streaming resume automatically once the rollout lands |
| Glasses mic silent (beeps play, nothing transcribed) | Bluetooth *audio* pairing is broken while the app link still works — happens after a glasses reset. Forget the glasses in iOS Settings → Bluetooth, put them in the case with the lid open, hold the case button until the LED pulses blue, re-pair via the Meta AI app prompt, then restart the iPhone. Re-grant the app connection + camera permission after |
| HomeKit not finding devices | HomeKit initializes on first tool call — say "list smart home devices" and wait 10s |
| Local model won't load ("not enough memory") | Close other apps in the app switcher and use **Try again** in Download & Manage Models (live headroom shown there), or switch to a smaller model (0.5B–2B) |
| Model download stuck | Keep app in foreground; downloads continue if briefly backgrounded |
| "Untrusted Developer" | Settings → General → VPN & Device Management → Verify (requires internet) |

---

