// OpenGlasses WebRTC signaling relay (Plan M1).
//
// Stateless WebSocket relay that rooms peers and forwards SDP/ICE. NO media passes through here —
// it only relays the small JSON signaling protocol the app speaks (see SignalingMessage in
// WebRTCPeerTransport.swift). Point the app's "Expert Signaling URL" at ws(s)://<host>:<port>.
//
//   npm init -y && npm install ws && node signaling-server.js
//   (behind TLS in production, e.g. via a reverse proxy, so the app can use wss://)
//
// Protocol (JSON text frames):
//   { type:"join",      room }
//   { type:"offer",     room, sdp }
//   { type:"answer",    room, sdp }
//   { type:"candidate", room, candidate, sdpMid, sdpMLineIndex }
//   { type:"bye",       room }

const { WebSocketServer } = require("ws");

const PORT = process.env.PORT || 8080;
const wss = new WebSocketServer({ port: PORT });

/** room id -> Set<WebSocket> */
const rooms = new Map();

function join(ws, room) {
  ws.room = room;
  if (!rooms.has(room)) rooms.set(room, new Set());
  rooms.get(room).add(ws);
  console.log(`join room=${room} size=${rooms.get(room).size}`);
}

function leave(ws) {
  const room = ws.room;
  if (!room || !rooms.has(room)) return;
  const peers = rooms.get(room);
  peers.delete(ws);
  if (peers.size === 0) rooms.delete(room);
}

/** Forward a raw message to every OTHER peer in the same room. */
function relay(ws, raw) {
  const peers = rooms.get(ws.room);
  if (!peers) return;
  for (const peer of peers) {
    if (peer !== ws && peer.readyState === peer.OPEN) peer.send(raw);
  }
}

wss.on("connection", (ws) => {
  ws.on("message", (data) => {
    const raw = data.toString();
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }
    if (!msg || !msg.room) return;

    if (msg.type === "join") {
      join(ws, msg.room);
      return;
    }
    // offer / answer / candidate / bye are relayed to the other peer.
    relay(ws, raw);
    if (msg.type === "bye") leave(ws);
  });

  ws.on("close", () => leave(ws));
  ws.on("error", () => leave(ws));
});

console.log(`OpenGlasses signaling relay listening on :${PORT}`);
