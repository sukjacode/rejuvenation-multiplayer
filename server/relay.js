// Minimaler TCP-Relay fuer Rejuvenation Co-op.
// Jede empfangene, mit \n abgeschlossene Zeile wird an ALLE anderen
// AUTHENTIFIZIERTEN Clients weitergeschickt. Kein State, keine Serialisierung.
//
// Auth: Der erste Zeilen-Frame eines Clients muss {"t":"auth","token":"..."} sein.
//   - Ist ein Token gesetzt (env COOP_TOKEN oder Datei token.txt), muss es passen,
//     sonst wird die Verbindung getrennt.
//   - Ohne gesetztes Token laeuft der Relay offen (nur fuer lokalen Test gedacht).

const net = require("net");
const fs = require("fs");
const path = require("path");

const PORT = 7777;
const HOST = "0.0.0.0"; // lauscht auf allen Interfaces -> Tunnel/Tailscale nutzbar

// Token laden: env COOP_TOKEN hat Vorrang, sonst token.txt neben relay.js.
function loadToken() {
  if (process.env.COOP_TOKEN && process.env.COOP_TOKEN.trim() !== "") {
    return process.env.COOP_TOKEN.trim();
  }
  try {
    const p = path.join(__dirname, "token.txt");
    const t = fs.readFileSync(p, "utf8").trim();
    if (t !== "") return t;
  } catch (e) { /* keine Datei -> offen */ }
  return "";
}
const TOKEN = loadToken();

const clients = new Set();

function log(msg) {
  const t = new Date().toISOString();
  console.log(`[${t}] ${msg}`);
}

log(TOKEN ? "auth: token REQUIRED" : "auth: OPEN (kein Token gesetzt - nur fuer lokalen Test)");

function handleLine(socket, id, line) {
  if (!socket.authed) {
    let msg = null;
    try { msg = JSON.parse(line); } catch (e) { /* ignore */ }
    if (msg && msg.t === "auth") {
      if (TOKEN && msg.token !== TOKEN) {
        log(`reject ${id}: bad token`);
        try { socket.write(JSON.stringify({ t: "error", msg: "bad token" }) + "\n"); } catch (e) {}
        socket.destroy();
        return;
      }
      socket.authed = true;
      socket.coopId = msg.id || "";
      log(`auth ok ${id} (id=${socket.coopId}, clients: ${countAuthed()})`);
      return; // Auth-Zeile nicht broadcasten
    }
    // Erste Zeile war kein Auth-Frame
    if (TOKEN) {
      log(`reject ${id}: auth required`);
      try { socket.write(JSON.stringify({ t: "error", msg: "auth required" }) + "\n"); } catch (e) {}
      socket.destroy();
      return;
    }
    // Offener Modus: als authentifiziert behandeln und diese Zeile normal verarbeiten
    socket.authed = true;
  }

  // Ab hier: authentifiziert -> an alle anderen authentifizierten Clients weiter
  log(`recv ${id}: ${line}`);
  for (const other of clients) {
    if (other !== socket && other.authed && !other.destroyed) {
      other.write(line + "\n");
    }
  }
}

function countAuthed() {
  let n = 0;
  for (const c of clients) if (c.authed) n++;
  return n;
}

const server = net.createServer((socket) => {
  const id = `${socket.remoteAddress}:${socket.remotePort}`;
  socket.setNoDelay(true);
  socket._buf = "";
  socket.authed = false;
  clients.add(socket);
  log(`connect ${id}`);

  // Auth-Timeout: wer nicht binnen 5s authentifiziert, fliegt raus.
  socket._authTimer = setTimeout(() => {
    if (!socket.authed) {
      log(`timeout ${id}: no auth`);
      socket.destroy();
    }
  }, 5000);

  socket.on("data", (chunk) => {
    socket._buf += chunk.toString("utf8");
    let idx;
    while ((idx = socket._buf.indexOf("\n")) >= 0) {
      const line = socket._buf.slice(0, idx);
      socket._buf = socket._buf.slice(idx + 1);
      handleLine(socket, id, line);
      if (socket.authed && socket._authTimer) {
        clearTimeout(socket._authTimer);
        socket._authTimer = null;
      }
    }
  });

  socket.on("close", () => {
    clients.delete(socket);
    if (socket._authTimer) clearTimeout(socket._authTimer);
    log(`close ${id} (clients: ${countAuthed()})`);
  });

  socket.on("error", (err) => {
    clients.delete(socket);
    if (socket._authTimer) clearTimeout(socket._authTimer);
    log(`error ${id}: ${err.message}`);
  });
});

server.listen(PORT, HOST, () => {
  log(`relay listening on ${HOST}:${PORT}`);
});
