// TTD relay: connects Dad's Mac (Talk to Dad) with the family app over WebSockets.
// Both sides connect *out* to this Worker, so nothing on Dad's Mac is exposed.
//
//   wss://<host>/ws?role=dad          Authorization: Bearer <DAD_TOKEN>
//   wss://<host>/ws?role=family&name=Iles   Authorization: Bearer <FAMILY_TOKEN>
//
// The relay keeps the last 300 chat lines (text only) and queues family messages while
// Dad's Mac is offline. Audio, screenshots and camera photos pass through and are not stored.

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/health") return new Response("ok");
    if (url.pathname !== "/ws") return new Response("Not found", { status: 404 });
    if (request.headers.get("Upgrade") !== "websocket") return new Response("Expected WebSocket", { status: 426 });

    const role = url.searchParams.get("role");
    const token = (request.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const expected = role === "dad" ? env.DAD_TOKEN : role === "family" ? env.FAMILY_TOKEN : null;
    if (!expected || !token || !timingSafeEqual(token, expected)) return new Response("Unauthorized", { status: 401 });

    const room = env.ROOM.get(env.ROOM.idFromName("dennis"));
    return room.fetch(request);
  },
};

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

const HISTORY = 300;
const PENDING = 100;

export class Room {
  constructor(state) {
    this.state = state;
  }

  async fetch(request) {
    const url = new URL(request.url);
    const role = url.searchParams.get("role");
    const name = (url.searchParams.get("name") || "family").slice(0, 40);
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.state.acceptWebSocket(server, [role, `name:${name}`]);

    if (role === "dad") {
      // Close any older Dad connection, then deliver what was queued while he was offline.
      for (const ws of this.state.getWebSockets("dad")) if (ws !== server) ws.close(4000, "replaced");
      const pending = (await this.state.storage.get("pending")) || [];
      for (const msg of pending) server.send(JSON.stringify(msg));
      await this.state.storage.put("pending", []);
      this.toFamily({ type: "dad", online: true, at: Date.now() });
    } else {
      const history = (await this.state.storage.get("history")) || [];
      const presence = await this.state.storage.get("presence");
      server.send(JSON.stringify({
        type: "welcome",
        dadOnline: this.state.getWebSockets("dad").length > 0,
        history,
        presence: presence || null,
      }));
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, raw) {
    if (typeof raw !== "string" || raw.length > 12_000_000) return;
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }
    const tags = this.state.getTags(ws);

    if (tags.includes("dad")) {
      if (msg.type === "line" && msg.line) {
        const history = (await this.state.storage.get("history")) || [];
        history.push(msg.line);
        await this.state.storage.put("history", history.slice(-HISTORY));
      }
      if (msg.type === "presence") await this.state.storage.put("presence", msg);
      this.toFamily(msg);
      return;
    }

    // From family: say, screenshot, camera, audio (request a recording). Stamp who sent it.
    const name = (tags.find((t) => t.startsWith("name:")) || "name:family").slice(5);
    if (!["say", "screenshot", "camera", "audio", "presence?"].includes(msg.type)) return;
    msg.from = msg.type === "say" ? (msg.from || name) : name;
    msg.at = Date.now();
    const dad = this.state.getWebSockets("dad");
    if (dad.length) {
      dad[0].send(JSON.stringify(msg));
    } else if (msg.type === "say") {
      const pending = (await this.state.storage.get("pending")) || [];
      pending.push(msg);
      await this.state.storage.put("pending", pending.slice(-PENDING));
      ws.send(JSON.stringify({ type: "queued", id: msg.id }));
    } else {
      ws.send(JSON.stringify({ type: "error", id: msg.id, message: "Dad's Mac is offline right now." }));
    }
  }

  async webSocketClose(ws) {
    if (this.state.getTags(ws).includes("dad") && this.state.getWebSockets("dad").filter((w) => w !== ws).length === 0) {
      this.toFamily({ type: "dad", online: false, at: Date.now() });
    }
  }

  toFamily(msg) {
    const text = JSON.stringify(msg);
    for (const ws of this.state.getWebSockets("family")) {
      try { ws.send(text); } catch {}
    }
  }
}
