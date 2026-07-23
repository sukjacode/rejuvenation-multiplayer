# Pokémon Rejuvenation — Co-op / Multiplayer Mod

A fan-made mod that brings **multiplayer** to [Pokémon Rejuvenation](https://www.rebornevolved.org/)
**V14**: walk through the same world together and see each other move in real time —
plus co-op sync battles, PvP and trading.

> ⚠️ **This repo does NOT contain the game.** It is only a modification.
> Every player needs their own legal copy of Pokémon Rejuvenation V14 (Windows).
> "Pokémon" is a trademark of Nintendo / Game Freak / The Pokémon Company. This
> project is not affiliated with or endorsed by them or by the Rejuvenation team.

---

## Features

| Area | Status |
|---|---|
| See other players on the same map + smooth movement | ✅ |
| Name tags above other players | ✅ |
| Co-op sync battles (boss wild + trainer, lockstep, deterministic) | ✅ |
| PvP (own perspective, win/loss record) | ✅ |
| Trading (pick a partner, two-sided confirm, dupe protection) | ✅ |
| Multiplayer menu in the pause menu (PvP & Trading) | ✅ |
| Internet play over [ZeroTier](https://www.zerotier.com/) | ✅ |

**Deliberately out of scope:** shared story flags, synchronized cutscenes, anti-cheat.

---

## Quick start for players (joining)

You want to join a friend's game:

1. **Get the installer:** download this repo (or the release ZIP).
2. **Get a join code:** your host sends you a *join code* (one long text string).
3. **Double-click `installer/install.bat`.**
   - Pick your Rejuvenation folder (the one with `Game.exe` / `Rejuvenation.exe`).
   - Paste the join code → **"Install mod + connect"**.
4. **Install ZeroTier** (button in the installer) and join the network.
   Your host then has to **authorize** your device once (see below).
5. **Start the game.** You should see each other on the same map.

---

## Quick start for the host (providing the game)

You host the session:

1. Install **Node.js** (LTS).
2. **Start the relay:**
   ```bat
   node server/relay.js
   ```
   The relay listens on TCP port `7777`. A token is generated on first start in
   `server/token.txt` (or set it via `COOP_TOKEN`).
3. Install **ZeroTier**, create a network (my.zerotier.com) and join it.
4. **Generate a join code:**
   ```bat
   powershell -ExecutionPolicy Bypass -File installer\make-joincode.ps1
   ```
   The code bundles ZeroTier network ID + your ZeroTier IP:port + token. Send it
   to your players.
5. **Authorize players:** my.zerotier.com → your network → *Members* → tick "Auth"
   for each new device.
6. **Firewall:** allow inbound TCP `7777` (see `docs/internet-setup.md`).

A graphical launcher (host/join/ZeroTier status) is in `server/launcher-gui.ps1`
(`server/start-launcher.bat`).

---

## Requirements

- Windows 10/11
- Pokémon Rejuvenation **V14** (Windows version, mkxp-z)
- [ZeroTier](https://www.zerotier.com/download/) (free) — for internet play
- Host only: [Node.js](https://nodejs.org/) LTS (for the relay)

---

## How it works (short)

- The mod (`mod/coop.rb`, `mod/coop_menu.rb`) loads through Rejuvenation's official
  mod system into `patch/Mods/` — **no** patching of `Scripts.rxdata`.
- A small **TCP relay** (`server/relay.js`) forwards line-delimited JSON between
  clients (positions, battle commands, trades, PvP). No state, no history.
- **ZeroTier** creates a private, encrypted overlay network over the internet;
  clients connect to the host's ZeroTier IP. The relay is protected by a token.

More detail: [`docs/status.md`](docs/status.md), [`docs/internet-setup.md`](docs/internet-setup.md).

---

## Troubleshooting

The mod writes logs into the game folder:

- `coop_error.txt` — load errors / exceptions (most important file when something breaks)
- `coop_net.txt` — connection status to the relay
- `coop_battle.txt` — battle sync

Common causes: wrong/missing join code (`coop_config.txt`), relay not running,
ZeroTier device not authorized, firewall blocking TCP 7777.

---

## License

MIT — see [`LICENSE`](LICENSE). Applies only to this repo's code, **not** to
Pokémon Rejuvenation or any Pokémon content.
