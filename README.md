# Pokémon Rejuvenation — Co-op / Multiplayer Mod

Ein Fan-Mod, der **Mehrspieler** in [Pokémon Rejuvenation](https://www.rebornevolved.org/) **V14** bringt:
Ihr lauft gemeinsam durch dieselbe Welt und seht euch in Echtzeit bewegen — dazu
kooperative Sync-Kämpfe, PvP und Tausch.

> ⚠️ **Dieses Repo enthält NICHT das Spiel.** Es ist nur eine Modifikation.
> Jeder Mitspieler braucht seine **eigene, legale Rejuvenation-V14-Installation
> (Windows)**. „Pokémon" ist eine Marke von Nintendo / Game Freak / The Pokémon
> Company. Dieses Projekt ist weder mit ihnen noch mit dem Rejuvenation-Team
> verbunden oder von ihnen unterstützt.

---

## Features

| Bereich | Status |
|---|---|
| Spieler auf derselben Map sehen + flüssige Bewegung | ✅ |
| Namensschilder über Mitspielern | ✅ |
| Kooperative Sync-Kämpfe (Boss-Wildmon + Trainer, Lockstep, deterministisch) | ✅ |
| PvP (eigene Perspektive, Sieg/Niederlage-Bilanz) | ✅ |
| Tausch (Partner wählen, beidseitige Bestätigung, Dupe-Schutz) | ✅ |
| Multiplayer-Menü im Pausemenü (PvP & Trading) | ✅ |
| Internet-Verbindung über [ZeroTier](https://www.zerotier.com/) | ✅ |

**Bewusst nicht enthalten:** geteilte Story-Flags, synchronisierte Cutscenes, Anti-Cheat.

---

## Schnellstart für Mitspieler (Beitreten)

Du willst dem Spiel eines Freundes beitreten:

1. **Installer holen:** Diesen Ordner (bzw. das Release-ZIP) herunterladen.
2. **Join-Code besorgen:** Dein Host schickt dir einen *Join-Code* (ein langer Text).
3. **`installer/install.bat` doppelklicken.**
   - Rejuvenation-Ordner wählen (der mit `Game.exe` / `Rejuvenation.exe`).
   - Join-Code einfügen → **„Mod installieren + verbinden"**.
4. **ZeroTier** installieren (Button im Installer) und dem Netzwerk beitreten.
   Dein Host muss dein Gerät danach einmalig **freischalten** (siehe unten).
5. **Spiel starten.** Ihr solltet euch auf derselben Map sehen.

---

## Schnellstart für den Host (Spiel bereitstellen)

Du hostest die Runde:

1. **Node.js** (LTS) installieren.
2. **Relay starten:**
   ```bat
   node server/relay.js
   ```
   Der Relay lauscht auf TCP-Port `7777`. Ein Token wird beim ersten Start in
   `server/token.txt` erzeugt (oder per `COOP_TOKEN` gesetzt).
3. **ZeroTier** installieren, ein Netzwerk erstellen (my.zerotier.com) und beitreten.
4. **Join-Code erzeugen:**
   ```bat
   powershell -ExecutionPolicy Bypass -File installer\make-joincode.ps1
   ```
   Der Code bündelt ZeroTier-Netz-ID + deine ZeroTier-IP:Port + Token. An
   Mitspieler weitergeben.
5. **Mitspieler freischalten:** my.zerotier.com → dein Netzwerk → *Members* →
   Haken bei „Auth" für jedes neue Gerät.
6. **Firewall:** Eingehend TCP `7777` erlauben (siehe `docs/internet-setup.md`).

Ein grafischer Launcher (Host/Join/ZeroTier-Status) liegt unter
`server/launcher-gui.ps1` (`server/start-launcher.bat`).

---

## Voraussetzungen

- Windows 10/11
- Pokémon Rejuvenation **V14** (Windows-Version, mkxp-z)
- [ZeroTier](https://www.zerotier.com/download/) (kostenlos) — für Internet-Spiel
- Nur der **Host**: [Node.js](https://nodejs.org/) LTS (für den Relay)

---

## Wie es funktioniert (kurz)

- Die Mod (`mod/coop.rb`, `mod/coop_menu.rb`) wird über Rejuvenations offizielles
  Mod-System nach `patch/Mods/` geladen — **kein** Eingriff in `Scripts.rxdata`.
- Ein kleiner **TCP-Relay** (`server/relay.js`) verteilt zeilenweise JSON zwischen
  den Clients (Positionen, Kampf-Kommandos, Tausch, PvP). Kein State, keine History.
- **ZeroTier** legt ein privates, verschlüsseltes Overlay-Netz über das Internet;
  die Clients verbinden sich zur ZeroTier-IP des Hosts. Der Relay ist per Token
  geschützt.

Mehr Details: [`docs/status.md`](docs/status.md), [`docs/internet-setup.md`](docs/internet-setup.md).

---

## Fehlersuche

Die Mod schreibt Logs in den Spielordner:

- `coop_error.txt` — Ladefehler / Ausnahmen (wichtigste Datei bei Problemen)
- `coop_net.txt` — Verbindungsstatus zum Relay
- `coop_battle.txt` — Kampf-Sync

Häufige Ursachen: falscher/fehlender Join-Code (`coop_config.txt`), Relay läuft
nicht, ZeroTier-Gerät nicht freigeschaltet, Firewall blockt TCP 7777.

---

## Lizenz

MIT — siehe [`LICENSE`](LICENSE). Gilt nur für den Code dieses Repos, **nicht**
für Pokémon Rejuvenation oder Pokémon-Inhalte.
