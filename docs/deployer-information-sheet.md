# Avenkin at work: information for organisations

*Avenkin · for an employer, clinic or other organisation that gives Avenkin to its staff · October 2026*

This sheet is for an organisation that puts Avenkin in the hands of its staff, in the EU or anywhere else. It says what the assistant is, where data can go, what the EU AI Act asks of you today, and how to set the phones up. It describes the app as it is; it is not legal advice.

## 1. What the assistant is, and where data can go

Avenkin is an AI assistant on an iPhone, used by voice, on screen, from an Apple Watch or through compatible smart glasses. It answers questions, looks through the camera when asked, searches your own manuals in Field Assist, and writes job records, notes and transcripts.

**The answers come from an AI model, and the phone decides which.** Either the wearer picks a provider and enters their own key, or your organisation's profile names the provider and model (never the key). The app can use about a dozen cloud providers, among them Anthropic, OpenAI, Google Gemini and Mistral AI, or a server you run yourself. A provider receives the request, the recent conversation, a camera image when the wearer asks about what they are looking at, and the results of any tools the assistant used to answer.

**Some of it can stay on the phone.** On-device AI models, speech recognition and voices keep those steps on the phone, and with an on-device model the conversation does not leave it. In Medical Compliance mode, "Local LLM Only" refuses a request rather than send it to the cloud.

Other services are used only once someone sets them up: a natural voice (ElevenLabs), telling speakers apart (Deepgram), web search, live streaming, and remote expert calls through a signalling server your organisation runs. The [privacy notice](https://avenkin.com/privacy.html) lists every one, with what it receives and when.

## 2. What the EU AI Act asks of you today

An organisation that uses an AI system in its work is a "deployer" under the Act. For Avenkin as it is today, that means two things.

- **Support AI literacy (Article 4).** Take reasonable steps so that the people who use the assistant understand what it is and where it falls short: an answer can be wrong, it can misread a manual page or a gauge, safety and first-aid assessments are advisory, and what is said can go to a cloud provider. This is a duty to make a reasonable effort, not to pass a test. A short briefing at hand-over, with this sheet and the vault guide, is a fair start. Keep a note of what you did.
- **Tell people exposed to emotion recognition (Article 50(3)).** The only feature that could count is Social mode in Assistive Mode, which describes how the person in front of the wearer seems to feel. It is not available on a phone managed by an organisation or in a Field Assist edition, so on your phones this duty does not arise.

Two other transparency duties are the app's, not yours, and they are done. **Telling people they are talking to an AI:** the assistant introduces itself as Avenkin AI, says "Connecting to Avenkin AI" each time it starts (your profile can make sure it always does), and says it is an AI whenever asked. A translation played from the phone's loudspeaker tells the other person, once, that it is an AI translation. **Marking what the AI made:** PDFs the assistant helped write, clinical exports, recordings that may contain its voice and the text it saves all say so in the file. The privacy notice lists the markers.

## 3. One rule: no AI output in performance figures

Do not let anything a model produced feed a performance figure, a ranking, a shift or job allocation, or a disciplinary decision.

The reason is the law's list of high-risk uses. From 2 December 2027, an AI system used to allocate work by people's behaviour or traits, or to monitor and evaluate how staff perform and behave, is high-risk (Annex III, point 4(b)). That brings heavy duties for you and for us. Avenkin does none of this: it scores, ranks and tracks nobody, and the records it produces are records of the work, sent by the technician. Counting jobs from those records yourself is an ordinary employment and data-protection matter. Asking a model to score or rank people from them would turn it into the high-risk case.

## 4. What your organisation receives, and what it never does

Everything below goes only to addresses and systems you set up.

| Record | When it comes to you |
|---|---|
| Job report (work order PDF and data file) | When the technician sends it, or straight away to your office endpoint if you set one. The work order never contains the conversation. |
| Transcript of the job | Only where your rule says. Your profile decides whether reports to your office always or never carry it, and can forbid transcripts going to customers. |
| Help request | When the technician asks for help. It can carry a transcript and their location, to the notification address you set. |
| Support report | Only when someone makes and sends one. On your phones it always goes to your support address, or else your job-report office, and never to us. |
| Recorded job | If you use Avenkin Office and allow it: video and audio of a job the technician chose to record, after a recording consent. You can require faces blurred first, keep it off mobile data, or forbid recording. |
| Live expert call | Camera and sound to the expert, through your signalling server, only while the call runs. |

What you never receive, because nothing collects it: a continuous feed of location, camera or captions; a productivity score, ranking or activity log; the person's conversation history, memories, AI request records or enrolled faces, which stay on the phone. We run no server and no account system, so nothing passes through us and we keep no copy.

## 5. Pinning settings with an organisation profile

An organisation profile is a signed document we prepare with you. Each phone enrols from it by a QR code or link, and the technician sees what it sets before accepting. It may only touch a fixed list of settings, and **each one moves in one direction only**, towards more privacy or more disclosure. A profile that tries the other way is refused for that setting. A pinned setting is shown on the phone with your organisation's name and cannot be changed there.

| Setting | Profile key | Can be pinned |
|---|---|---|
| Face recognition | `faceRecognitionEnabled` | Off only. Recognising a bystander is never an employer's to switch on. |
| "Connecting to Avenkin AI" at voice startup | `aiConnectionCueEnabled` | On only |
| Bystander face blur | `privacyFilterEnabled` | On only |
| Agent mode | `agentModeEnabled` | Off only. While it is off, no remote command runs at all. |
| Remote commands: status (observe), speak and display (output), camera, recording and transcript (capture) | `remoteInvokeObserveEnabled`, `remoteInvokeOutputEnabled`, `remoteInvokeCaptureEnabled` | Off only. Capture is off by default and always asks first. |
| The phone's local agent server | `mcpServerEnabled` | Off only |
| Vaults that aren't signed | `organizationAllowsUnsignedVaults` | Off only |
| Signed job files only | `organizationRequiresSignedJobFiles` | On only |
| Customer sign-off on a job | `organizationRequiresCustomerSignOff` | On only |
| No transcript to customers | `organizationForbidsCustomerTranscript` | On only |
| No job recording | `organizationForbidsJobRecording` | On only |
| Faces blurred before a recording goes to the office | `organizationRequiresBlurBeforeOfficeSync` | On only |
| No recording sent over mobile data | `organizationForbidsRecordingSyncOnCellular` | On only |

While it is in place the profile also sets your organisation's name, report recipients and channel, whether office reports carry the transcript, the key your job files are signed with, and your colour. It can name the AI provider and model, lock whole groups of settings and close tools in a Field Assist edition, and give starting values the technician may change later (Field Assist on, the default vault and mode, the support address).

## 6. What a technician can switch off themselves

Anything below can be switched off on the phone without asking anyone, unless your profile has pinned it the other way.

- **Face recognition:** Settings › Devices & Privacy › Glasses › Enrolled Faces. "Forget Everyone" on the same screen removes every enrolled face.
- **Bystander face blur** and **First-Aid Coaching and Triage:** Settings › Devices & Privacy › Hardware & Privacy.
- **"Connecting to Avenkin AI":** Settings, under Voice.
- **Any single tool:** the Tools list in Settings.
- **Agent features:** Agentic Features in Settings.
- **The assistant's voice in recordings and streams:** "Include Assistant Voice", off unless switched on.

What stays on the phone whatever is switched on: conversation history, memories, notes, enrolled faces, the 14-day record of AI requests (which holds no words), and recordings until someone sends one. The technician can delete each of these in the app.

## 7. Where to read more

- The [privacy notice](https://avenkin.com/privacy.html): every service, what it receives, how AI-made files are marked, and the rights of the people using the app, including under the GDPR.
- The [support guide](support-reports-guide.md): setting the support address, and what a support report contains.
- The [vault guide](field-assist-vault-guide.md): building a vault from your manuals and sending job reports.
