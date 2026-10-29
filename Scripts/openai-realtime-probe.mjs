// OpenAI Realtime protocol probe (Plan KC P0 evidence). Node 22+ (global WebSocket with headers).
//   OPENAI_API_KEY=sk-... node Scripts/openai-realtime-probe.mjs
// Reads the key from the environment only. Prints event TYPES and error codes, never content
// or the key (the whole-turn and dictation cases also print transcripts of their synthetic speech).
// Costs a few cents: each case asks for one short spoken reply.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { deflateSync, crc32 } from "node:zlib";

const key = process.env.OPENAI_API_KEY;
if (!key) { console.error("Set OPENAI_API_KEY"); process.exit(2); }
const redact = (s) => String(s ?? "").replace(/sk-[A-Za-z0-9_*\-]+/g, "sk-…");

const betaSession = {
  modalities: ["text", "audio"], instructions: "Answer in one word.",
  input_audio_format: "pcm16", output_audio_format: "pcm16",
  input_audio_transcription: { model: "gpt-4o-mini-transcribe" },
  turn_detection: { type: "server_vad", threshold: 0.5, prefix_padding_ms: 300, silence_duration_ms: 500,
                    create_response: true, interrupt_response: true },
};
const gaSession = (transcribe) => ({
  type: "realtime", output_modalities: ["audio"], instructions: "Answer in one word.",
  audio: {
    input: { format: { type: "audio/pcm", rate: 24000 }, transcription: { model: transcribe },
             turn_detection: { type: "server_vad", threshold: 0.5, prefix_padding_ms: 300,
                               silence_duration_ms: 500, create_response: true, interrupt_response: true } },
    output: { format: { type: "audio/pcm", rate: 24000 } },
  },
});

const cases = [
  // What the app sends today on api.openai.com.
  { name: "app today: beta header + beta shape, gpt-realtime", model: "gpt-realtime", beta: true, session: betaSession },
  // Isolates the header: GA shape, but still with the beta header.
  { name: "GA shape + beta header, gpt-realtime", model: "gpt-realtime", beta: true, session: gaSession("gpt-4o-mini-transcribe") },
  // Isolates the shape: no header, beta shape (a compatible server's view).
  { name: "beta shape, no header, gpt-realtime", model: "gpt-realtime", beta: false, session: betaSession },
  // The fix.
  { name: "GA, gpt-realtime", model: "gpt-realtime", beta: false, session: gaSession("gpt-4o-mini-transcribe") },
  { name: "GA, gpt-realtime-2.1 + gpt-live-transcribe", model: "gpt-realtime-2.1", beta: false, session: gaSession("gpt-live-transcribe") },
  { name: "GA, gpt-realtime-2.1 + gpt-transcribe", model: "gpt-realtime-2.1", beta: false, session: gaSession("gpt-transcribe") },
  // P1's rewrite target for the mini models.
  { name: "GA, gpt-realtime-2.1-mini + gpt-live-transcribe", model: "gpt-realtime-2.1-mini", beta: false, session: gaSession("gpt-live-transcribe") },
];

function run(c) {
  return new Promise((resolve) => {
    const headers = { Authorization: `Bearer ${key}` };
    if (c.beta) headers["OpenAI-Beta"] = "realtime=v1";
    const ws = new WebSocket(`wss://api.openai.com/v1/realtime?model=${c.model}`, { headers });
    const types = new Map(); const errors = []; let closeInfo = "";
    const done = () => { try { ws.close(); } catch {} resolve({ types, errors, closeInfo }); };
    const timer = setTimeout(done, 20000);
    ws.onmessage = (m) => {
      const e = JSON.parse(m.data);
      types.set(e.type, (types.get(e.type) ?? 0) + 1);
      if (e.type === "error") errors.push(`${e.error?.type}/${e.error?.code}: ${redact(e.error?.message)}`);
      if (e.type === "session.created") ws.send(JSON.stringify({ type: "session.update", session: c.session }));
      if (e.type === "session.updated") {
        ws.send(JSON.stringify({ type: "conversation.item.create", item: { type: "message", role: "user",
          content: [{ type: "input_text", text: "Say the word ready." }] } }));
        ws.send(JSON.stringify({ type: "response.create" }));
      }
      if (e.type === "response.done") { clearTimeout(timer); setTimeout(done, 300); }
    };
    ws.onclose = (ev) => { closeInfo = `close ${ev.code} ${redact(ev.reason)}`; clearTimeout(timer); resolve({ types, errors, closeInfo }); };
    ws.onerror = () => {};
  });
}

const print = (name, r) => {
  console.log(`\n== ${name}`);
  console.log("events:", [...r.types].map(([t, n]) => `${t}×${n}`).join(", ") || "(none)");
  for (const e of r.errors) console.log("error:", e);
  for (const f of r.findings ?? []) console.log("found:", f);
  if (r.closeInfo) console.log(r.closeInfo);
};
// PROBE_TURN_ONLY=1 skips the protocol cases.
if (!process.env.PROBE_TURN_ONLY) for (const c of cases) print(c.name, await run(c));

// A whole turn the way the app's current-protocol adapter sends it: a photo as an `image_url` data
// URI, then spoken audio (macOS `say`) answered by server VAD, a tool call, and its result.
// macOS only (`say`, `sips`); skipped elsewhere.

function fixtures() {
  const dir = mkdtempSync(join(tmpdir(), "realtime-probe-"));
  const chunk = (t, d) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(d.length);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(Buffer.concat([Buffer.from(t), d])) >>> 0);
    return Buffer.concat([len, Buffer.from(t), d, crc]);
  };
  const ihdr = Buffer.from([0, 0, 0, 16, 0, 0, 0, 16, 8, 2, 0, 0, 0]);
  const rows = Buffer.concat(Array.from({ length: 16 }, () => Buffer.from([0, ...Array(16).fill([200, 60, 40]).flat()])));
  writeFileSync(join(dir, "p.png"), Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", ihdr), chunk("IDAT", deflateSync(rows)), chunk("IEND", Buffer.alloc(0))]));
  execFileSync("sips", ["-s", "format", "jpeg", join(dir, "p.png"), "--out", join(dir, "p.jpg")], { stdio: "ignore" });
  execFileSync("say", ["-o", join(dir, "q.wav"), "--data-format=LEI16@24000",
    "What is the torque for bolt A? Please use the tool."]);
  const wav = readFileSync(join(dir, "q.wav"));
  const data = wav.indexOf("data");
  return { jpeg: readFileSync(join(dir, "p.jpg")).toString("base64"), pcm: wav.subarray(data + 8) };
}

function turn(model) {
  const { jpeg, pcm } = fixtures();
  return new Promise((resolve) => {
    const ws = new WebSocket(`wss://api.openai.com/v1/realtime?model=${model}`, { headers: { Authorization: `Bearer ${key}` } });
    const types = new Map(); const errors = []; const findings = []; let closeInfo = ""; let responses = 0;
    const done = () => { try { ws.close(); } catch {} resolve({ types, errors, findings, closeInfo }); };
    const timer = setTimeout(done, 45000);
    const send = (o) => ws.send(JSON.stringify(o));
    ws.onmessage = (m) => {
      const e = JSON.parse(m.data);
      types.set(e.type, (types.get(e.type) ?? 0) + 1);
      if (e.type === "error") errors.push(`${e.error?.type}/${e.error?.code}: ${redact(e.error?.message)}`);
      if (e.type === "session.created") {
        const session = gaSession("gpt-live-transcribe");
        session.tools = [{ type: "function", name: "get_torque", description: "Torque for a named bolt.",
          parameters: { type: "object", properties: { bolt: { type: "string" } }, required: ["bolt"] } }];
        session.tool_choice = "auto";
        send({ type: "session.update", session });
      }
      if (e.type === "session.updated" && !findings.length) {
        findings.push("session with tools accepted");
        send({ type: "conversation.item.create", item: { type: "message", role: "user", content: [
          { type: "input_text", text: "This is the bolt I'm looking at." },
          { type: "input_image", image_url: `data:image/jpeg;base64,${jpeg}` }] } });
        const silence = Buffer.alloc(24000 * 2); // one second, so server VAD ends the turn
        const audio = Buffer.concat([pcm, silence]);
        for (let i = 0; i < audio.length; i += 9600) send({ type: "input_audio_buffer.append", audio: audio.subarray(i, i + 9600).toString("base64") });
      }
      if (e.type === "conversation.item.input_audio_transcription.completed") findings.push(`wearer transcript: ${JSON.stringify(e.transcript)}`);
      if (e.type === "response.function_call_arguments.done") {
        findings.push(`tool call ${e.name}(${e.arguments})`);
        send({ type: "conversation.item.create", item: { type: "function_call_output", call_id: e.call_id, output: "{\"torque\":\"25 N·m\"}" } });
        send({ type: "response.create" });
      }
      if (e.type === "response.output_audio_transcript.done") findings.push(`reply transcript: ${JSON.stringify(e.transcript)}`);
      if (e.type === "response.done" && ++responses >= 2) { clearTimeout(timer); setTimeout(done, 300); }
    };
    ws.onclose = (ev) => { closeInfo = `close ${ev.code} ${redact(ev.reason)}`; clearTimeout(timer); resolve({ types, errors, findings, closeInfo }); };
    ws.onerror = () => {};
  });
}
// PROBE_DICTATION_ONLY=1 runs only the dictation upload below.
if (process.platform === "darwin" && !process.env.PROBE_DICTATION_ONLY) for (const model of ["gpt-realtime-2.1", "gpt-realtime-2.1-mini"]) {
  print(`GA turn: photo, speech, tool, ${model} + gpt-live-transcribe`, await turn(model));
}

// Dictation (Plan KC P2): the upload `OpenAIDictationRequest` makes, a WAV of spoken audio with the
// model, `response_format: json` and a vocabulary prompt, to `/v1/audio/transcriptions`. Prints the
// reply's field names and the synthetic question's transcript.
async function dictation(model) {
  const dir = mkdtempSync(join(tmpdir(), "dictation-probe-"));
  // Spelled as a technician says it: `say` reads "R-454B" as "R negative 454 B".
  execFileSync("say", ["-o", join(dir, "d.wav"), "--data-format=LEI16@16000", "Check the TXV on the R four fifty four B unit."]);
  const form = new FormData();
  form.append("model", model);
  form.append("response_format", "json");
  form.append("prompt", "TXV, R-454B");
  form.append("file", new Blob([readFileSync(join(dir, "d.wav"))], { type: "audio/wav" }), "question.wav");
  const reply = await fetch("https://api.openai.com/v1/audio/transcriptions",
                            { method: "POST", headers: { Authorization: `Bearer ${key}` }, body: form });
  const body = await reply.json().catch(() => ({}));
  const findings = [`HTTP ${reply.status}`, `fields: ${Object.keys(body).join(", ") || "(none)"}`];
  if (typeof body.text === "string") findings.push(`transcript: "${body.text}"`);
  const errors = body.error ? [`${body.error.type}/${body.error.code}: ${redact(body.error.message)}`] : [];
  return { types: new Map(), errors, findings };
}
// The outgoing model beside its replacement, on the same synthetic question, until it goes.
if (process.platform === "darwin") for (const model of ["gpt-transcribe", "gpt-4o-transcribe"]) {
  print(`Dictation upload, ${model}`, await dictation(model));
}
