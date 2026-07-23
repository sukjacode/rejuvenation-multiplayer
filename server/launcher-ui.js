// Rejuvenation Co-op -- Launcher mit Web-UI.
// Kleiner lokaler HTTP-Server (nur Node-Builtins), oeffnet die UI im Browser.
// Bindet NUR an 127.0.0.1 -- von aussen (auch ZeroTier) nicht erreichbar.
//
// Start:  node launcher-ui.js

const fs = require("fs");
const path = require("path");
const net = require("net");
const http = require("http");
const crypto = require("crypto");
const { spawn, execFileSync } = require("child_process");

const SERVER_DIR = __dirname;
const SETTINGS_FILE = path.join(SERVER_DIR, "launcher_settings.json");
const TOKEN_FILE = path.join(SERVER_DIR, "token.txt");
const RELAY_JS = path.join(SERVER_DIR, "relay.js");
const RELAY_PORT = 7777;
const UI_PORT = 7780;
const ZT_EXE = "C:\\ProgramData\\ZeroTier\\One\\zerotier-one_x64.exe";

// --- Settings / Token -------------------------------------------------------

function loadSettings() {
  try { return JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf8")); } catch (e) { return {}; }
}
function saveSettings(s) {
  try { fs.writeFileSync(SETTINGS_FILE, JSON.stringify(s, null, 2)); } catch (e) {}
}
let settings = loadSettings();

function loadToken() {
  try { const t = fs.readFileSync(TOKEN_FILE, "utf8").trim(); if (t) return t; } catch (e) {}
  return "";
}
function saveToken(t) { fs.writeFileSync(TOKEN_FILE, t + "\n"); }

// --- ZeroTier ---------------------------------------------------------------

function ztInstalled() { return fs.existsSync(ZT_EXE); }

function ztCli(args) {
  try { return execFileSync(ZT_EXE, ["-q"].concat(args), { encoding: "utf8", timeout: 5000 }); }
  catch (e) { return null; }
}

function ztInfo() {
  const out = ztCli(["info"]);
  if (!out) return null;
  const parts = out.trim().split(/\s+/);
  if (parts.length < 5) return null;
  return { nodeId: parts[2], online: parts[4] === "ONLINE" };
}

function ztNetworks() {
  const out = ztCli(["listnetworks"]);
  if (!out) return [];
  const nets = [];
  for (const rawLine of out.split(/\r*\n/)) {
    const line = rawLine.trim();
    const m = line.match(/^200 listnetworks\s+([0-9a-f]{16})\s+(.*)$/);
    if (!m) continue;
    const rest = m[2].trim().split(/\s+/);
    const ips = rest.length >= 1 ? rest[rest.length - 1] : "-";
    const status = rest.length >= 4 ? rest[rest.length - 4] : "?";
    nets.push({
      nwid: m[1],
      status: status,
      ips: ips === "-" ? [] : ips.split(",").map((x) => x.split("/")[0])
    });
  }
  return nets;
}

function ztFirstIp() {
  for (const n of ztNetworks()) {
    if (n.status === "OK" && n.ips.length > 0) return { ip: n.ips[0], nwid: n.nwid };
  }
  return null;
}

// --- Spielordner ------------------------------------------------------------

function hasGameExe(dir) {
  try { return dir && fs.existsSync(path.join(dir, "Rejuvenation.exe")); } catch (e) { return false; }
}
function findGameDir() {
  if (hasGameExe(settings.gameDir)) return settings.gameDir;
  const candidates = [
    path.resolve(SERVER_DIR, "../../game/Rejuvenation-14.0-windows"),
    path.resolve(SERVER_DIR, "../../game"),
  ];
  for (const c of candidates) {
    if (hasGameExe(c)) { settings.gameDir = c; saveSettings(settings); return c; }
  }
  return null;
}

function writeConfig(gameDir, server, token) {
  const lines = ["# von launcher-ui geschrieben", "server = " + server];
  if (token) lines.push("token  = " + token);
  fs.writeFileSync(path.join(gameDir, "coop_config.txt"), lines.join("\n") + "\n");
}

function launchGame(gameDir) {
  const exe = path.join(gameDir, "Rejuvenation.exe");
  const child = spawn(exe, [], { cwd: gameDir, detached: true, stdio: "ignore" });
  child.on("error", () => {});
  child.unref();
}

// --- Relay ------------------------------------------------------------------

let relayProc = null;
const relayLog = [];
function pushRelayLog(data) {
  for (const line of data.toString("utf8").split(/\r?\n/)) {
    if (line.trim() !== "") { relayLog.push(line); if (relayLog.length > 300) relayLog.shift(); }
  }
}
function startRelay() {
  if (relayProc) return;
  relayProc = spawn(process.execPath, [RELAY_JS], { cwd: SERVER_DIR });
  relayProc.stdout.on("data", pushRelayLog);
  relayProc.stderr.on("data", pushRelayLog);
  relayProc.on("exit", (code) => { pushRelayLog("[relay beendet, code " + code + "]"); relayProc = null; });
}
function stopRelay() {
  if (relayProc) { try { relayProc.kill(); } catch (e) {} }
}
function relayClientCount() {
  for (let i = relayLog.length - 1; i >= 0; i--) {
    const m = relayLog[i].match(/clients: (\d+)\)/);
    if (m) return parseInt(m[1], 10);
  }
  return 0;
}
function checkPort(port) {
  return new Promise((resolve) => {
    const s = net.connect(port, "127.0.0.1");
    s.setTimeout(400);
    s.on("connect", () => { s.destroy(); resolve(true); });
    s.on("timeout", () => { s.destroy(); resolve(false); });
    s.on("error", () => resolve(false));
  });
}

// --- API --------------------------------------------------------------------

async function apiStatus() {
  const gameDir = findGameDir();
  let gameNet = [];
  if (gameDir) {
    try {
      gameNet = fs.readFileSync(path.join(gameDir, "coop_net.txt"), "utf8").trim().split(/\r?\n/).slice(-4);
    } catch (e) {}
  }
  const portOpen = await checkPort(RELAY_PORT);
  return {
    zt: {
      installed: ztInstalled(),
      info: ztInfo(),
      networks: ztNetworks()
    },
    relay: {
      running: !!relayProc,
      portOpen: portOpen,
      clients: relayClientCount(),
      log: relayLog.slice(-8)
    },
    game: { dir: gameDir, netLog: gameNet },
    token: loadToken(),
    settings: {
      lastServer: settings.lastServer || "",
      lastNetworkId: settings.lastNetworkId || ""
    }
  };
}

function readBody(req) {
  return new Promise((resolve) => {
    let b = "";
    req.on("data", (c) => { b += c; if (b.length > 65536) req.destroy(); });
    req.on("end", () => { try { resolve(JSON.parse(b || "{}")); } catch (e) { resolve({}); } });
  });
}

const server = http.createServer(async (req, res) => {
  const send = (code, obj, type) => {
    res.writeHead(code, { "Content-Type": type || "application/json; charset=utf-8" });
    res.end(type ? obj : JSON.stringify(obj));
  };
  try {
    if (req.method === "GET" && req.url === "/") return send(200, HTML, "text/html; charset=utf-8");
    if (req.method === "GET" && req.url === "/api/status") return send(200, await apiStatus());

    if (req.method === "POST" && req.url === "/api/host") {
      const b = await readBody(req);
      let token = (b.token || "").trim();
      if (!token) token = crypto.randomBytes(8).toString("hex");
      saveToken(token);
      startRelay();
      const gameDir = findGameDir();
      if (gameDir) writeConfig(gameDir, "127.0.0.1:" + RELAY_PORT, token);
      return send(200, { ok: true, token: token });
    }
    if (req.method === "POST" && req.url === "/api/relay/stop") {
      stopRelay();
      return send(200, { ok: true });
    }
    if (req.method === "POST" && req.url === "/api/join") {
      const b = await readBody(req);
      const gameDir = findGameDir();
      if (!gameDir) return send(400, { ok: false, error: "Spielordner nicht gefunden" });
      if (!b.server) return send(400, { ok: false, error: "Server-Adresse fehlt" });
      writeConfig(gameDir, b.server.trim(), (b.token || "").trim());
      settings.lastServer = b.server.trim(); saveSettings(settings);
      if (b.launch) launchGame(gameDir);
      return send(200, { ok: true });
    }
    if (req.method === "POST" && req.url === "/api/launch") {
      const gameDir = findGameDir();
      if (!gameDir) return send(400, { ok: false, error: "Spielordner nicht gefunden" });
      launchGame(gameDir);
      return send(200, { ok: true });
    }
    if (req.method === "POST" && req.url === "/api/zt/join") {
      const b = await readBody(req);
      const nwid = (b.nwid || "").trim().toLowerCase();
      if (!/^[0-9a-f]{16}$/.test(nwid)) return send(400, { ok: false, error: "Ungueltige Network ID" });
      const out = ztCli(["join", nwid]);
      if (out && out.includes("OK")) {
        settings.lastNetworkId = nwid; saveSettings(settings);
        return send(200, { ok: true });
      }
      return send(500, { ok: false, error: "Join fehlgeschlagen" });
    }
    send(404, { error: "not found" });
  } catch (e) {
    send(500, { error: e.message });
  }
});

// --- HTML-Frontend ----------------------------------------------------------

const HTML = `<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<title>Rejuv Co-op Launcher</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root {
    --bg: #12141a; --card: #1b1e27; --card2: #232734; --text: #e6e8ee;
    --dim: #8a90a2; --accent: #7c5cff; --ok: #3ecf8e; --warn: #f5a623; --bad: #ff5c7a;
    --mono: Consolas, 'Cascadia Mono', monospace;
  }
  * { box-sizing: border-box; margin: 0; }
  body { background: var(--bg); color: var(--text); font: 15px/1.5 'Segoe UI', system-ui, sans-serif; padding: 24px; }
  h1 { font-size: 20px; margin-bottom: 4px; }
  .sub { color: var(--dim); font-size: 13px; margin-bottom: 20px; }
  .grid { display: grid; gap: 16px; grid-template-columns: repeat(auto-fit, minmax(330px, 1fr)); max-width: 1100px; }
  .card { background: var(--card); border: 1px solid #2a2e3d; border-radius: 12px; padding: 18px; }
  .card h2 { font-size: 15px; margin-bottom: 12px; display: flex; align-items: center; gap: 8px; }
  .dot { width: 9px; height: 9px; border-radius: 50%; background: var(--dim); display: inline-block; }
  .dot.ok { background: var(--ok); } .dot.warn { background: var(--warn); } .dot.bad { background: var(--bad); }
  .row { display: flex; justify-content: space-between; padding: 3px 0; font-size: 14px; }
  .row .k { color: var(--dim); }
  .mono { font-family: var(--mono); font-size: 13px; }
  input { width: 100%; background: var(--card2); color: var(--text); border: 1px solid #333849; border-radius: 8px; padding: 9px 11px; font-size: 14px; margin: 4px 0 10px; }
  input:focus { outline: none; border-color: var(--accent); }
  label { font-size: 12.5px; color: var(--dim); }
  button { background: var(--accent); color: #fff; border: 0; border-radius: 8px; padding: 9px 15px; font-size: 14px; cursor: pointer; margin-right: 8px; margin-top: 2px; }
  button:hover { filter: brightness(1.12); }
  button.sec { background: var(--card2); border: 1px solid #333849; }
  button.danger { background: #3a2430; border: 1px solid #57324a; color: var(--bad); }
  button:disabled { opacity: .45; cursor: default; }
  .share { background: var(--card2); border-radius: 10px; padding: 12px; margin-top: 12px; }
  .share .line { display: flex; justify-content: space-between; padding: 2px 0; }
  .log { background: #0e1016; border-radius: 8px; padding: 10px; margin-top: 10px; font-family: var(--mono); font-size: 12px; color: #9aa1b5; max-height: 150px; overflow-y: auto; white-space: pre-wrap; word-break: break-all; }
  .hint { font-size: 12.5px; color: var(--dim); margin-top: 8px; }
  .toast { position: fixed; bottom: 20px; right: 20px; background: var(--ok); color: #08130d; padding: 10px 16px; border-radius: 8px; font-size: 14px; opacity: 0; transition: opacity .25s; pointer-events: none; }
  .toast.show { opacity: 1; }
</style>
</head>
<body>
<h1>Rejuvenation Co-op Launcher</h1>
<div class="sub">Relay läuft, solange dieses Fenster (der Launcher-Prozess) offen ist.</div>

<div class="grid">

  <div class="card">
    <h2><span id="zt-dot" class="dot"></span> ZeroTier</h2>
    <div id="zt-body">lädt…</div>
    <div id="zt-join" style="display:none">
      <label>Network ID vom Host</label>
      <input id="nwid" placeholder="z.B. 0123456789abcdef" maxlength="16">
      <button onclick="ztJoin()">Netz beitreten</button>
    </div>
  </div>

  <div class="card">
    <h2><span id="relay-dot" class="dot"></span> Hosten</h2>
    <label>Passwort / Token</label>
    <input id="host-token" placeholder="leer = zufällig generieren">
    <button id="btn-host" onclick="host()">Server starten</button>
    <button class="danger" id="btn-stop" onclick="stopRelay()" style="display:none">Server stoppen</button>
    <button class="sec" onclick="launchOnly()">Nur Spiel starten</button>
    <div id="share" class="share" style="display:none"></div>
    <div class="log" id="relay-log" style="display:none"></div>
  </div>

  <div class="card">
    <h2>Beitreten</h2>
    <label>Server-Adresse (host:port)</label>
    <input id="join-server" placeholder="z.B. 10.147.20.10:7777">
    <label>Passwort / Token</label>
    <input id="join-token" placeholder="Token vom Host">
    <button onclick="join()">Verbinden &amp; Spiel starten</button>
    <div class="hint">Schreibt die coop_config.txt und startet das Spiel.</div>
  </div>

  <div class="card">
    <h2>Eigene Verbindung</h2>
    <div class="row"><span class="k">Spielordner</span><span id="game-dir" class="mono" style="max-width:60%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"></span></div>
    <div class="log" id="game-log">–</div>
  </div>

</div>
<div class="toast" id="toast"></div>

<script>
let st = null;
const $ = (id) => document.getElementById(id);

function toast(msg) {
  const t = $("toast"); t.textContent = msg; t.classList.add("show");
  setTimeout(() => t.classList.remove("show"), 2200);
}
async function api(url, body) {
  const r = await fetch(url, body ? { method: "POST", headers: {"Content-Type":"application/json"}, body: JSON.stringify(body) } : undefined);
  return r.json();
}
function esc(s) { return String(s).replace(/[&<>]/g, (c) => ({"&":"&amp;","<":"&lt;",">":"&gt;"}[c])); }

function render() {
  if (!st) return;
  // ZeroTier
  const zt = st.zt;
  let dot = "bad", body = "";
  if (!zt.installed) {
    body = 'Nicht installiert.<div class="hint">Installieren: <span class="mono">winget install ZeroTier.ZeroTierOne</span></div>';
  } else if (!zt.info) {
    body = "Dienst antwortet nicht.";
  } else {
    body = '<div class="row"><span class="k">Status</span><span>' + (zt.info.online ? "ONLINE" : "OFFLINE") + '</span></div>';
    if (zt.networks.length === 0) {
      body += '<div class="hint">In keinem Netzwerk.</div>';
      dot = "warn";
    }
    for (const n of zt.networks) {
      const ip = n.ips.length ? n.ips.join(", ") : "–";
      body += '<div class="row"><span class="k mono">' + n.nwid + '</span><span>' + esc(n.status) + '</span></div>';
      body += '<div class="row"><span class="k">IP</span><span class="mono">' + esc(ip) + '</span></div>';
      if (n.status === "OK" && n.ips.length) dot = "ok";
      else if (n.status === "REQUESTING_CONFIGURATION" || n.status === "ACCESS_DENIED") {
        body += '<div class="hint">Wartet auf Freigabe — der Host muss im Dashboard das Auth-Häkchen setzen.</div>';
        dot = "warn";
      }
    }
  }
  $("zt-dot").className = "dot " + dot;
  $("zt-body").innerHTML = body;
  $("zt-join").style.display = (zt.installed && zt.info && zt.networks.length === 0) ? "block" : "none";
  if (st.settings.lastNetworkId && !$("nwid").value) $("nwid").value = st.settings.lastNetworkId;

  // Relay / Hosten
  const r = st.relay;
  const relayUp = r.running || r.portOpen;
  $("relay-dot").className = "dot " + (relayUp ? "ok" : "");
  $("btn-stop").style.display = r.running ? "inline-block" : "none";
  $("btn-host").textContent = relayUp ? (r.running ? "Server läuft (" + r.clients + " verbunden)" : "Server läuft extern") : "Server starten";
  $("btn-host").disabled = relayUp;
  if (!$("host-token").value && st.token) $("host-token").value = st.token;
  const ztIp = ztFirstIp();
  if (relayUp && ztIp) {
    $("share").style.display = "block";
    $("share").innerHTML =
      '<div class="line"><span class="k">Server</span><span class="mono">' + ztIp.ip + ':7777</span></div>' +
      '<div class="line"><span class="k">Token</span><span class="mono">' + esc(st.token) + '</span></div>' +
      '<div class="line"><span class="k">Network ID</span><span class="mono">' + ztIp.nwid + '</span></div>' +
      '<button class="sec" style="margin-top:8px" onclick="copyShare()">Für Mitspieler kopieren</button>';
  } else {
    $("share").style.display = "none";
  }
  $("relay-log").style.display = r.log.length ? "block" : "none";
  $("relay-log").textContent = r.log.join("\\n");

  // Beitreten Defaults
  if (!$("join-server").value && st.settings.lastServer) $("join-server").value = st.settings.lastServer;
  if (!$("join-token").value && st.token) $("join-token").value = st.token;

  // Spiel
  $("game-dir").textContent = st.game.dir || "nicht gefunden";
  $("game-log").textContent = st.game.netLog.length ? st.game.netLog.join("\\n") : "– (Spiel noch nicht verbunden)";
}

function ztFirstIp() {
  for (const n of (st && st.zt.networks) || []) {
    if (n.status === "OK" && n.ips.length) return { ip: n.ips[0], nwid: n.nwid };
  }
  return null;
}

async function refresh() {
  try { st = await api("/api/status"); render(); } catch (e) {}
}

async function host() {
  const res = await api("/api/host", { token: $("host-token").value });
  if (res.ok) { $("host-token").value = res.token; toast("Server gestartet"); }
  refresh();
}
async function stopRelay() {
  await api("/api/relay/stop", {});
  toast("Server gestoppt");
  refresh();
}
async function join() {
  const res = await api("/api/join", { server: $("join-server").value, token: $("join-token").value, launch: true });
  toast(res.ok ? "Config geschrieben, Spiel startet" : ("Fehler: " + res.error));
}
async function launchOnly() {
  const res = await api("/api/launch", {});
  toast(res.ok ? "Spiel gestartet" : ("Fehler: " + res.error));
}
async function ztJoin() {
  const res = await api("/api/zt/join", { nwid: $("nwid").value });
  toast(res.ok ? "Beigetreten — warte auf Freigabe durch den Host" : ("Fehler: " + res.error));
  refresh();
}
function copyShare() {
  const ip = ztFirstIp();
  const text = "Rejuv Co-op:\\n1. ZeroTier installieren: https://www.zerotier.com/download/\\n2. Netz beitreten: " + ip.nwid +
    "\\n3. Mir Bescheid sagen (ich muss dich freigeben)\\n4. Im Launcher 'Beitreten': Server " + ip.ip + ":7777, Token " + st.token;
  navigator.clipboard.writeText(text).then(() => toast("In Zwischenablage kopiert"));
}

refresh();
setInterval(refresh, 2500);
</script>
</body>
</html>`;

// --- Start ------------------------------------------------------------------

server.listen(UI_PORT, "127.0.0.1", () => {
  const url = "http://127.0.0.1:" + UI_PORT;
  console.log("Launcher-UI: " + url);
  // Browser oeffnen (Windows)
  try { spawn("cmd", ["/c", "start", "", url], { detached: true, stdio: "ignore" }).unref(); } catch (e) {}
});

process.on("SIGINT", () => { stopRelay(); process.exit(0); });
