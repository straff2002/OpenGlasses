# Realtime and China provider setup

The conversation picker offers **Direct** and **Realtime**. Direct uses ordinary
chat requests; Realtime uses a saved live model with its own credentials and
protocol. OpenAI, Gemini, Qwen and Doubao share the app's session coordinator,
audio engine, camera lifecycle and ordered WebSocket transport. Each provider
keeps its own wire contract.

## Add a model

Open **Add Model** from model settings or the conversation picker. Choose **Chat**
or **Realtime**, then select a provider. Realtime models can also be managed in
**Settings → Assistant → Realtime Models**. Enter the endpoint, API key
and model ID; Qwen and Doubao also expose the voice setting. Select the saved live
model in the conversation's **Realtime** picker to start it.

**Test Connection** checks authentication and the provider's session-ready
acknowledgement. It does not capture microphone audio or prove audio, vision or
tool behavior. Check those in a real conversation after setup.

Each model's secrets and endpoint are stored in Keychain. A running session
snapshots its settings, including the protocol version, and retains them during
reconnects. Editing a text model does not redirect a live session. Existing
OpenAI, Gemini and custom realtime settings are copied into saved live models
once; their original launch identities remain available to existing shortcuts.

## Supported realtime profiles

| Provider/profile | Input / output audio | Images | App context updates | Generated text turns | Speak supplied text |
|---|---|---|---|---|---|
| OpenAI Realtime (current protocol) | PCM16 mono 24 / 24 kHz | Yes | Yes | Yes | Local speech fallback |
| OpenAI Realtime beta v1 (older compatible servers) | PCM16 mono 24 / 24 kHz | Yes | Yes | Yes | Local speech fallback |
| Gemini Live v1 | PCM16 mono 16 / 24 kHz | Yes | Yes | Yes | Local speech fallback |
| Qwen Omni v1 | PCM16 mono 16 / 24 kHz | Bounded image buffer | Yes | Unavailable | Local speech fallback |
| Qwen Audio v1 | PCM16 mono 16 / 24 kHz | Unavailable | Yes | Yes | Local speech fallback |
| Doubao full duplex JSON 3.0 | PCM16 mono 16 / 24 kHz | Unavailable | Yes | Unavailable | Native direct synthesis |

All profiles handle streamed voice replies, transcripts, interruption and
function calls. Capabilities describe this implementation's selected protocol,
not every feature offered elsewhere by that provider. Unsupported actions are
disabled or return an explicit error; they do not report a successful delivery.
Doubao usage totals are not recorded by this adapter pending a verified usage
payload. Gemini retains its existing server resumption behavior; other profiles
reconnect with a locally rebuilt context rather than claiming server resumption.

### China provider test targets

Defaults were checked against provider documentation on 2026-10-11. Issue #715
names Qwen-Omni-Realtime and Doubao without specifying model versions.

**Qwen (China API)** defaults to `qwen3.8-omni-flash-realtime`, voice `Tina`, at
`wss://{workspace}.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime`. Replace
`{workspace}` with your Beijing workspace ID and use its API key. The client uses
Bearer authentication, the Qwen session/audio schema, `qwen3-asr-flash-realtime`
transcription and nested function declarations. Background JPEG images are paced
at at most one per second, sent only after audio, and bounded to 256 KiB after
base64 encoding. See the [model reference](https://www.alibabacloud.com/help/en/model-studio/qwen3-8-omni-flash-realtime),
[connection guide](https://www.alibabacloud.com/help/en/model-studio/realtime)
and [client events](https://www.alibabacloud.com/help/en/model-studio/client-events).

**Qwen Audio (China API)** is a separate voice-only option, defaulting to
`qwen-audio-3.1-realtime-plus` and `longanqian_v3.1`, using the same Beijing
workspace endpoint and Bearer key. It supports user text messages followed by
`response.create`. Its session schema differs from Omni; the app never guesses
that schema from a model name. See the [Qwen-Audio guide](https://www.alibabacloud.com/help/en/model-studio/qwen-audio-realtime-user-guides)
and [client events](https://www.alibabacloud.com/help/en/model-studio/fun-audiochat-client-events).

**Doubao** defaults to the full-duplex JSON 3.0 endpoint
`wss://openspeech.bytedance.com/api/v3/duplex/realtime/dialogue`, model version
`1.2.6.1`, and voice `zh_female_vv_jupiter_bigtts`. It uses `X-Api-Key` with a
Speech Console key. An Ark chat key does not establish access to this speech API.
The app initiates `session.create`, waits for `session.created`, requests
`pcm_s16le` output explicitly, and sends 640-byte input packets at 20 ms intervals.
Mute/unmute events accompany microphone gating. Tool results are returned as one
complete batch without an OpenAI `response.create`. This implements the newer
JSON protocol; the older binary protocol needs a separate adapter. See the
[full-duplex API reference](https://docs.volcengine.com/docs/DoubaoVoice/endtoend-realtime-voice-full-duplex-version?lang=zh).

Neither provider inherently needs a proxy. A custom gateway is an optional
endpoint for servers implementing one of the supported protocol profiles.
Selecting a custom URL does not automatically change the protocol: choose it
explicitly in the editor. Unsupported saved versions fail clearly rather than
silently trying another provider's protocol.

## App context and announcements

The engine distinguishes silent context updates, generated text turns and exact
supplied speech. Job and debrief changes use independent replaceable context
lanes. JSON providers receive the base system instruction plus current app state
through `session.update`; updates never send `response.create` or alter Qwen's
initial audio/VAD settings. The app context is limited to 12 entries and 6,000
characters, retained across automatic reconnects, and cleared on explicit stop.

Doubao announcements use `speech_text_buffer.replacement.append/commit` to speak
exact supplied text in the configured voice. The engine retains the announcement
as app context so later spoken questions can refer to it. It does not invent a
user/assistant exchange, or treat historical QA insertion as a generation trigger.
Doubao also documents conversation-context insertion, but this implementation
uses session instructions for app-owned state.

OpenAI, Gemini and Qwen Audio use a generated text turn for asynchronous results.
Qwen Omni uses local speech and then updates app context. Notification summaries
use the same route; an active live microphone handles follow-up without starting
a second recorder. Delivery waits for a conversational gap and rechecks session
identity before using the wire. Qwen Omni inference after instructions-only
updates remains disabled until authenticated testing establishes its behavior.

These new contracts have documentation-derived tests. Authenticated microphone,
notification speech, follow-up context and reconnect checks still require account
credentials; passing fixtures does not establish deployed-server acceptance.

## Ordinary chat models

The **Chat** provider selector includes **Qwen (China API)** and **Doubao (Ark API)**
templates. These use the existing OpenAI-compatible HTTP engine:

- Qwen: `https://{workspace}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions`,
  default model `qwen3.8-max`. Replace the workspace placeholder. The existing
  Qwen subscription choice remains separate from this API template.
- Doubao: `https://ark.cn-beijing.volces.com/api/v3/chat/completions`, default model
  `doubao-seed-2-1-pro-260628`. Enter an Ark API key and a model/endpoint ID enabled
  for your account.

Model IDs and endpoints remain editable. Chat and speech models have independent
credentials and protocol settings. See the [Qwen chat API guide](https://www.alibabacloud.com/help/en/model-studio/qwen-api-via-openai-chat-completions)
and [Ark compatibility guide](https://docs.volcengine.com/docs/ark/compatible-with-openai-sdk?lang=zh).

## Connection policy

Public realtime endpoints require `wss://` in Release/TestFlight builds. Explicit
custom endpoints can use LAN servers, for example `ws://192.168.1.10:8080/realtime`.
The phone must be able to reach the server. Medical Compliance's local-only
setting blocks live network sessions, including LAN connections. The processing
summary shows the selected destination host without exposing URL paths, query
parameters or credentials.

For both OpenAI profiles, authentication is Bearer and the configured model replaces
any existing `model` query parameter. Other query parameters are retained. No
profile sends the `OpenAI-Beta` header: OpenAI removed the beta on 2026-05-12 and
refuses the header. The OpenAI provider always uses the current protocol, and saved
OpenAI live models were moved to it once. A custom/compatible model keeps the
protocol it was saved with (new ones start on the beta) and can choose either; pick
"OpenAI Realtime" for a server that follows OpenAI's current protocol. Both
session-update payloads and the tool envelopes are covered by golden tests.

## Verification status

Qwen and Doubao adapters have documentation-derived contract fixtures and shared
engine tests. These fixtures are not captured server traffic. **No authenticated
Qwen or Doubao live session has been verified yet:** matching account credentials
are not configured locally.

After supplying account settings, run Test Connection, then verify microphone
input, streamed replies, input/output transcripts, interruption, tool execution,
and network disconnect/reconnect. For Qwen, also test camera frames and sharp
photo size limits. For Doubao, test mute/unmute and stopping while speaking. A
successful setup acknowledgement alone does not establish these behaviors.
