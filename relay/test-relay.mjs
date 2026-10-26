// Local test: node test-relay.mjs ws://127.0.0.1:8787
const base = process.argv[2] || "ws://127.0.0.1:8787";
const open = (role, token, name = "") => new Promise((res, rej) => {
  const ws = new WebSocket(`${base}/ws?role=${role}${name ? "&name=" + name : ""}`, { headers: { Authorization: `Bearer ${token}` } });
  ws.got = []; ws.onmessage = (e) => ws.got.push(JSON.parse(e.data));
  ws.onopen = () => res(ws); ws.onerror = (e) => rej(new Error(`${role} failed`));
});
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) process.exitCode = 1; };

let bad = false; try { await open("family", "wrong"); } catch { bad = true; } ok(bad, "wrong token refused");
const fam = await open("family", "local-family-test", "Iles"); await wait(300);
ok(fam.got[0]?.type === "welcome" && fam.got[0].dadOnline === false, "family welcome, Dad offline");
fam.send(JSON.stringify({ type: "say", id: "m1", text: "Hi Dad" })); await wait(300);
ok(fam.got.some((m) => m.type === "queued"), "message queued while Dad offline");
const dad = await open("dad", "local-dad-test"); await wait(400);
ok(dad.got.some((m) => m.type === "say" && m.text === "Hi Dad" && m.from === "Iles"), "Dad gets queued message on connect");
ok(fam.got.some((m) => m.type === "dad" && m.online), "family told Dad is online");
dad.send(JSON.stringify({ type: "line", line: { id: "l1", from: "Dad", to: "Iles", text: "Hello son", date: new Date().toISOString() } }));
dad.send(JSON.stringify({ type: "presence", idleSeconds: 12, locked: false })); await wait(300);
ok(fam.got.some((m) => m.type === "line" && m.line.text === "Hello son"), "family gets Dad's line");
fam.send(JSON.stringify({ type: "screenshot", id: "s1" })); await wait(300);
ok(dad.got.some((m) => m.type === "screenshot" && m.from === "Iles"), "screenshot request reaches Dad");
const fam2 = await open("family", "local-family-test", "Nicole"); await wait(300);
ok(fam2.got[0]?.history?.length === 1 && fam2.got[0].presence?.idleSeconds === 12, "new family app gets history + presence");
dad.close(); await wait(400);
ok(fam.got.some((m) => m.type === "dad" && m.online === false), "family told Dad went offline");
fam.close(); fam2.close();
