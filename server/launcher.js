// Rejuvenation Co-op -- Terminal-Launcher (ZeroTier-Ausgabe).
// Funktionen: Beitreten (Join), Hosten (Host), Status. Nur Node-Builtins.
//
// Start:  node launcher.js

const fs = require("fs");
const path = require("path");
const net = require("net");
const readline = require("readline");
const { spawn, execFileSync } = require("child_process");

const SERVER_DIR = __dirname;
const SETTINGS_FILE = path.join(SERVER_DIR, "launcher_settings.json");
const TOKEN_FILE = path.join(SERVER_DIR, "token.txt");
const RELAY_JS = path.join(SERVER_DIR, "relay.js");
const RELAY_PORT = 7777;
const ZT_EXE = "C:\\ProgramData\\ZeroTier\\One\\zerotier-one_x64.exe";

// --- Settings ---------------------------------------------------------------

function loadSettings() {
  try { return JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf8")); }
  catch (e) { return {}; }
}
function saveSettings(s) {
  try { fs.writeFileSync(SETTINGS_FILE, JSON.stringify(s, null, 2)); }
  catch (e) { console.log("(Settings konnten nicht gespeichert werden: " + e.message + ")"); }
}
let settings = loadSettings();

// --- readline Helper --------------------------------------------------------

const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
let exiting = false;
let rlClosed = false;
rl.on("close", () => { rlClosed = true; if (!exiting) cleanupAndExit(0); });

function ask(question, def) {
  const suffix = (def !== undefined && def !== "") ? ` [${def}]` : "";
  return new Promise((resolve) => {
    if (rlClosed) { resolve(def !== undefined ? def : ""); return; }
    rl.question(question + suffix + ": ", (a) => {
      a = (a || "").trim();
      resolve(a === "" && def !== undefined ? def : a);
    });
  });
}

// --- ZeroTier ---------------------------------------------------------------

function ztInstalled() {
  return fs.existsSync(ZT_EXE);
}

function ztCli(args) {
  // Liefert stdout oder null bei Fehler.
  try { return execFileSync(ZT_EXE, ["-q"].concat(args), { encoding: "utf8", timeout: 5000 }); }
  catch (e) { return null; }
}

function ztInfo() {
  // { nodeId, online } oder null
  const out = ztCli(["info"]);
  if (!out) return null;
  // "200 info <nodeid> <version> ONLINE"
  const parts = out.trim().split(/\s+/);
  if (parts.length < 5) return null;
  return { nodeId: parts[2], online: parts[4] === "ONLINE" };
}

function ztNetworks() {
  // Liste { nwid, status, ips: [] }
  const out = ztCli(["listnetworks"]);
  if (!out) return [];
  const nets = [];
  for (const rawLine of out.split(/\r*\n/)) {
    // "200 listnetworks <nwid> <name> <mac> <status> <type> <dev> <ips>"
    // trim: ZeroTier haengt \r-Reste an die Zeilen (Ausgabe endet auf \r\r\n)
    const line = rawLine.trim();
    const m = line.match(/^200 listnetworks\s+([0-9a-f]{16})\s+(.*)$/);
    if (!m) continue;
    const rest = m[2].trim().split(/\s+/);
    // von hinten lesen: ips, dev, type, status (name kann leer sein/Leerzeichen enthalten)
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

function ztPrintStatus() {
  if (!ztInstalled()) {
    console.log("ZeroTier: NICHT installiert.");
    console.log("  -> Installieren mit:  winget install ZeroTier.ZeroTierOne");
    return;
  }
  const info = ztInfo();
  if (!info) { console.log("ZeroTier: installiert, aber Dienst antwortet nicht."); return; }
  console.log("ZeroTier: " + (info.online ? "ONLINE" : "OFFLINE") + " (Node " + info.nodeId + ")");
  const nets = ztNetworks();
  if (nets.length === 0) {
    console.log("  In keinem Netzwerk. Beitreten ueber Menuepunkt 1 (Join) moeglich.");
  }
  for (const n of nets) {
    const ipStr = n.ips.length ? n.ips.join(", ") : "(noch keine IP)";
    console.log("  Netz " + n.nwid + "  Status: " + n.status + "  IP: " + ipStr);
    if (n.status === "REQUESTING_CONFIGURATION" || n.status === "ACCESS_DENIED") {
      console.log("    -> wartet auf Freigabe: Der Host muss im ZeroTier-Dashboard das Auth-Haekchen setzen.");
    }
  }
}

async function ztEnsureJoined() {
  // Sorgt dafuer, dass wir in einem ZT-Netz mit IP sind. Gibt {ip,nwid} oder null.
  if (!ztInstalled()) {
    console.log("ZeroTier ist nicht installiert. Installieren mit:");
    console.log("  winget install ZeroTier.ZeroTierOne");
    return null;
  }
  let cur = ztFirstIp();
  if (cur) return cur;
  const nets = ztNetworks();
  if (nets.length > 0) {
    ztPrintStatus();
    return null; // beigetreten, aber noch keine Freigabe/IP
  }
  const nwid = await ask("ZeroTier Network ID vom Host (16 Zeichen, leer = ueberspringen)", settings.lastNetworkId || "");
  if (!nwid) return null;
  if (!/^[0-9a-f]{16}$/i.test(nwid)) { console.log("Ungueltige Network ID."); return null; }
  const out = ztCli(["join", nwid.toLowerCase()]);
  if (out && out.includes("OK")) {
    settings.lastNetworkId = nwid.toLowerCase(); saveSettings(settings);
    console.log("Beigetreten. Der Host muss dich jetzt im Dashboard freigeben (Auth-Haekchen).");
    console.log("Danach Status (Menuepunkt 3) pruefen -- dort erscheint deine ZeroTier-IP.");
  } else {
    console.log("Join fehlgeschlagen: " + (out || "(keine Antwort vom Dienst)"));
  }
  return null;
}

// --- Token ------------------------------------------------------------------

function loadToken() {
  try { const t = fs.readFileSync(TOKEN_FILE, "utf8").trim(); if (t) return t; } catch (e) {}
  return "";
}
function saveToken(t) {
  fs.writeFileSync(TOKEN_FILE, t + "\n");
}
function randomToken() {
  return require("crypto").randomBytes(8).toString("hex");
}

// --- Spielordner finden -----------------------------------------------------

function hasGameExe(dir) {
  try { return dir && fs.existsSync(path.join(dir, "Rejuvenation.exe")); }
  catch (e) { return false; }
}

async function ensureGameDir() {
  if (hasGameExe(settings.gameDir)) return settings.gameDir;
  const candidates = [
    path.resolve(SERVER_DIR, "../../game/Rejuvenation-14.0-windows"),
    path.resolve(SERVER_DIR, "../../game"),
  ];
  for (const c of candidates) {
    if (hasGameExe(c)) { settings.gameDir = c; saveSettings(settings); return c; }
  }
  console.log("Spielordner (mit Rejuvenation.exe) nicht automatisch gefunden.");
  while (true) {
    const p = await ask("Pfad zum Spielordner");
    if (hasGameExe(p)) { settings.gameDir = p; saveSettings(settings); return p; }
    console.log("  Dort ist keine Rejuvenation.exe. Nochmal.");
  }
}

// --- coop_config.txt / Spielstart -------------------------------------------

function writeConfig(gameDir, server, token) {
  const lines = ["# von launcher.js geschrieben", "server = " + server];
  if (token && token !== "") lines.push("token  = " + token);
  fs.writeFileSync(path.join(gameDir, "coop_config.txt"), lines.join("\n") + "\n");
}

function launchGame(gameDir) {
  const exe = path.join(gameDir, "Rejuvenation.exe");
  const child = spawn(exe, [], { cwd: gameDir, detached: true, stdio: "ignore" });
  child.on("error", (e) => console.log("Spielstart fehlgeschlagen: " + e.message));
  child.unref();
  console.log("Spiel gestartet.");
}

// --- Relay ------------------------------------------------------------------

let relayProc = null;
const relayLog = [];
function pushLog(arr, data) {
  const text = data.toString("utf8");
  for (const line of text.split(/\r?\n/)) {
    if (line.trim() !== "") { arr.push(line); if (arr.length > 200) arr.shift(); }
  }
}

function startRelay() {
  if (relayProc) { console.log("Relay laeuft bereits (von diesem Launcher)."); return; }
  relayProc = spawn(process.execPath, [RELAY_JS], { cwd: SERVER_DIR });
  relayProc.stdout.on("data", (d) => pushLog(relayLog, d));
  relayProc.stderr.on("data", (d) => pushLog(relayLog, d));
  relayProc.on("exit", (code) => { pushLog(relayLog, "[relay beendet, code " + code + "]"); relayProc = null; });
  console.log("Relay gestartet (Port " + RELAY_PORT + ").");
}

function checkPort(port) {
  return new Promise((resolve) => {
    const s = net.connect(port, "127.0.0.1");
    s.setTimeout(500);
    s.on("connect", () => { s.destroy(); resolve(true); });
    s.on("timeout", () => { s.destroy(); resolve(false); });
    s.on("error", () => resolve(false));
  });
}

// --- Flows ------------------------------------------------------------------

async function flowJoin() {
  const gameDir = await ensureGameDir();
  // ZeroTier pruefen/joinen (nicht zwingend -- Server koennte auch lokal/LAN sein)
  const zt = await ztEnsureJoined();
  if (zt) console.log("ZeroTier ok (deine IP: " + zt.ip + ").");
  const server = await ask("Server-Adresse (host:port)", settings.lastServer || "");
  if (!server) { console.log("Keine Adresse -> abgebrochen."); return; }
  const token = await ask("Passwort/Token", settings.lastToken || "");
  writeConfig(gameDir, server, token);
  settings.lastServer = server; settings.lastToken = token; saveSettings(settings);
  console.log("coop_config.txt geschrieben (server=" + server + (token ? ", token gesetzt" : "") + ").");
  launchGame(gameDir);
}

async function flowHost() {
  const gameDir = await ensureGameDir();

  // Token: vorhandenes anbieten, sonst generieren
  let token = loadToken();
  if (token) {
    token = await ask("Passwort/Token fuer den Server", token);
  } else {
    token = await ask("Passwort/Token (leer = zufaellig generieren)", "");
    if (!token) { token = randomToken(); console.log("Generiertes Token: " + token); }
  }
  saveToken(token);

  startRelay();

  // ZeroTier-Infos fuer die Freunde
  const zt = ztFirstIp();
  console.log("");
  console.log("----- Weitergeben an Mitspieler -----");
  if (zt) {
    console.log("  Server : " + zt.ip + ":" + RELAY_PORT);
    console.log("  Token  : " + token);
    console.log("  ZeroTier Network ID: " + zt.nwid);
    console.log("  (Mitspieler: ZeroTier installieren, Netz joinen, von dir freigeben lassen,");
    console.log("   dann im Launcher 'Beitreten' mit Server + Token.)");
  } else {
    console.log("  KEINE ZeroTier-IP gefunden!");
    ztPrintStatus();
    console.log("  Mitspieler koennen dich so nicht erreichen (nur lokal 127.0.0.1).");
  }
  console.log("-------------------------------------");
  console.log("");

  writeConfig(gameDir, "127.0.0.1:" + RELAY_PORT, token);
  settings.lastToken = token; saveSettings(settings);
  const launchNow = (await ask("Eigenes Spiel jetzt starten? (j/n)", "j")).toLowerCase();
  if (launchNow !== "n") launchGame(gameDir);
  console.log("Hinweis: Der Relay laeuft, solange dieser Launcher offen ist.");
}

async function flowStatus() {
  console.log("\n----- Status -----");
  ztPrintStatus();
  // Relay
  if (relayProc) {
    console.log("Relay: laeuft (von diesem Launcher).");
    const tail = relayLog.slice(-6);
    if (tail.length) { console.log("  letzte Relay-Zeilen:"); tail.forEach((l) => console.log("    " + l)); }
  } else {
    const up = await checkPort(RELAY_PORT);
    console.log("Relay: " + (up ? "Port " + RELAY_PORT + " offen (laeuft ausserhalb des Launchers)" : "laeuft nicht"));
  }
  // Eigene Verbindung (coop_net.txt im Spielordner)
  if (hasGameExe(settings.gameDir)) {
    const netFile = path.join(settings.gameDir, "coop_net.txt");
    try {
      const lines = fs.readFileSync(netFile, "utf8").trim().split(/\r?\n/);
      console.log("Eigene Verbindung (coop_net.txt):");
      lines.slice(-4).forEach((l) => console.log("    " + l));
    } catch (e) {
      console.log("Eigene Verbindung: noch keine coop_net.txt (Spiel noch nicht verbunden).");
    }
  }
  console.log("------------------\n");
}

// --- Menue ------------------------------------------------------------------

async function menu() {
  console.log("=== Rejuvenation Co-op Launcher ===");
  while (true) {
    console.log("  1) Beitreten (Join)");
    console.log("  2) Hosten (Host)");
    console.log("  3) Status anzeigen");
    console.log("  4) Beenden");
    const choice = await ask("Auswahl", "1");
    if (choice === "1") await flowJoin();
    else if (choice === "2") await flowHost();
    else if (choice === "3") await flowStatus();
    else if (choice === "4") break;
    else console.log("Ungueltige Auswahl.");
    console.log("");
    if (rlClosed) break;
  }
  cleanupAndExit(0);
}

function cleanupAndExit(code) {
  if (exiting) return;
  exiting = true;
  try { if (relayProc) relayProc.kill(); } catch (e) {}
  try { rl.close(); } catch (e) {}
  process.exit(code);
}

process.on("SIGINT", () => { console.log("\nBeende..."); cleanupAndExit(0); });

menu();
