# Status

## Erledigt

- **Voller Sync-Kampf (Weg B), M1-M4-Kern** — deterministischer Co-op-Doppelkampf,
  beide Spieler geben live je fuer ihren Slot Inputs (Lockstep pro Runde ueber
  bcmd/bswitch), identische RNG-Digests auf beiden Rechnern bestaetigt.
  - Wild-Co-op (Builder run_coop_wild_battle) + Trainer-Co-op (run_coop_trainer_battle,
    Gegner serialisiert im bstart uebertragen, da pbLoadTrainer nicht deterministisch).
  - **Gating (Endziel):** normales Gras = SOLO, Co-op nur bei Boss-Wildmon + Trainer.
  - EXP: anteilig (COOP_EXP_PERCENT=50) an die lokale echte Party; Geld unangetastet.
  - V1-Sperren im Co-op-Kampf: keine Items/Flucht/Spezialmoves.
  - Debug-Trigger: coop_debug_wildbattle.txt (Force-Wild), coop_debug_trainerbattle.txt
    (erster Trainer aus $cache.trainers).
  - OFFEN: Disconnect mitten im Kampf, waitingTrainer-Spezialdoppel, Items/Flucht nachziehen.

- **Party-Sync + Co-op-Doppelkampf (Stufe 2)** — Jede Instanz broadcastet ihre Party
  (`t:"party"`, Marshal+Base64-Blob: [name, trainertyp, trainer_id, party]) ~alle 2s
  bei Aenderung. Bei angenommener Kampf-Anfrage wird der Partner mit seinem echten
  Team als `$PokemonGlobal.partner` registriert -> Engine macht bei Trainer-/Boss-
  kaempfen automatisch einen Doppelkampf (Partner-Pokemon KI-gesteuert, lokal).
  Normale Wildkaempfe bleiben bewusst solo (Boss-only-Regel unangetastet).
  Nach dem Kampf Deregistrierung; Story-Partner wird nie ueberschrieben.
  Getestet: Invite-Kette + Party-Fluss (10 msgs am Relay) + Leere-Party-Weiche.
  OFFEN zum Verifizieren: Partner-Pokemon sichtbar im Kampf (braucht Spielstand
  mit Pokemon + Trainer-/Bosskampf).

- **Kampf-Anfrage-Geruest (Co-op-Kampf Stufe 1)** — Protokoll hat jetzt Nachrichtentypen
  (`t`: pos/binvite/breply). Vor jedem Wild-/Trainerkampf (`pbWildBattleObject`,
  `pbTrainerBattle` gehookt): ist ein Mitspieler auf derselben Map, geht eine Anfrage
  raus (5s Timeout); der Partner bekommt einen Ja/Nein-Dialog (Scene_Map-Hook).
  Annahme setzt `$coop_battle_partner` (Doppelkampf-Regeln = naechster Schritt via
  `pbRegisterPartner`/`$PokemonGlobal.partner` — Mechanik ist in Rejuv schon verdrahtet,
  siehe pbWildBattleObject in Field.rb). Ablehnung/Timeout -> Solokampf.
  End-to-end getestet (Log `coop_battle.txt`: sent/received/ACCEPTED in 3s).
  DEBUG: Datei `coop_debug_invite.txt` im Spielordner loest das Gate manuell aus.
- **Nativer Launcher** — `server/launcher-gui.ps1` (WinForms, via `start-launcher.bat`):
  EXE-Auswahl, ZeroTier-Status/-Join, Host mit Token + Relay, Join mit Live-
  Verbindungs- und Token-Pruefung (Fehlermeldungen), Mitspieler-Anleitung mit
  Live-Werten. CLI-Variante `launcher.js`, Web-Variante `launcher-ui.js` als Fallback.

- **Internet via ZeroTier** — privates Overlay-Netz (ID + Host-IP lokal, nicht im
  Repo), Relay mit Token (`server/token.txt`). Zwei Instanzen ueber die ZT-IP verbunden,
  Positionen fliessen. Ueberlebt Reboots (Dienst autostartet); nur der Relay muss
  nach Reboot neu gestartet werden.
- **Cutscene-Gating bestaetigt** — waehrend Cutscene/Dialog/Menue/Mapwechsel sendet
  eine Instanz nichts und ist fuer andere unsichtbar (Stale-Timeout 3s).
- **Map-Gating im Praxistest bestaetigt** — verschiedene Maps: unsichtbar fuereinander;
  betritt einer die Map des anderen, erscheint er am Eingang und laeuft sichtbar weiter.

- **Phase A** — Eigener Ruby-Code laeuft im Spiel. Injektion ueber Rejuvenations
  offizielles Mod-System (siehe `Modding.txt`), kein Eingriff in `Scripts.rxdata`.
- **Phase B** — Recon: Ruby 3.1.3, x64-mingw32, `socket`/`thread`/`json` verfuegbar.
  Details in `recon.md`.
- **Phase C** — TCP-Relay (Node) + Client im Spiel, eine Zeile floss durch.
- **Schritt D** — Remote-Spieler sehen + Bewegung. Ein Remote-Spieler wird auf der
  Map gezeichnet und bewegt sich (Movement-Replay). Bestaetigt mit einem Node-Bot,
  der einen laufenden Mitspieler emittiert.

## Injektionspunkte (WICHTIG, Reihenfolge klaeren war nicht trivial)

Ladereihenfolge laut `Scripts/ScriptLoader.rb`:

1. `INIT`-Skripte
2. **`patch/Init/*.rb`** — laeuft VOR den Engine-Klassen. Hier ist z.B.
   `Game_Character` NOCH NICHT definiert. Nur fuer engine-unabhaengigen Code.
3. `SCRIPTS` (gesamte Engine: `Game_Character`, `Spriteset_Map`, ...)
4. **`patch/Mods/*.rb`** — laeuft NACH der Engine. Hier gehoert alles hin, das von
   Engine-Klassen erbt oder sie per `alias` erweitert. `coop.rb` liegt hier.

## Zwei nicht-offensichtliche Stolpersteine (beide gekostet)

1. **`Game_OnlinePlayer < Game_Character` in `patch/Init` -> `NameError:
   uninitialized constant Game_Character`.** Engine-abhaengiger Code muss nach
   `patch/Mods`. Ladefehler auf oberster Datei-Ebene landen sonst nur im
   mkxp-Popup, nicht in Logdateien -> Top-Level-`begin/rescue` in `coop.rb`, das
   Ladefehler in `coop_error.txt` schreibt.

2. **Blockierender `TCPSocket#write` im Main-Thread friert das ganze Spiel ein.**
   In mkxp-z blockiert ein normaler `write` (auch bei winzigen lokalen Paketen) den
   Main-Thread hart -> kompletter Freeze, kein Byte kommt am Relay an, keine
   Exception. Loesung: `write_nonblock` mit `rescue IO::WaitWritable` (Position
   diesmal ueberspringen). Der empfangende Netz-Thread nutzt weiterhin
   `read_nonblock` + `sleep`.

## Architektur des Mods (`rejuv-coop/mod/coop.rb`, deployed nach `patch/Mods/`)

- `Coop` — szenenunabhaengiger Singleton. Netz-Thread (read_nonblock), Mutex-
  geschuetzter State-Store `@remote`, Sender `tick_send` (write_nonblock, gedrosselt:
  bei Aenderung sofort, sonst Keepalive ~alle 20 Frames). Eigene id = random hex.
- `Game_OnlinePlayer < Game_Character` — `through = true`. Abgespecktes `update`:
  NUR Bewegungs-Interpolation + Pattern-Animation, KEINE Event-/Encounter-Trigger
  (`onStepTakenFieldMovement` wuerde sonst beim Remote-Spieler Encounter ausloesen).
  `warp_to` (Snap), `step_to` (Ein-Tile-Schritt -> Engine interpoliert).
- `Spriteset_Map`-Hooks (alias initialize/update/dispose) — erzeugen/aktualisieren/
  entfernen Remote-Sprites, gated auf `map_id`. Map-Wechsel-sicher (Spriteset wird
  je Map neu gebaut). Veraltete Remotes (>3s ohne Update) oder andere Map werden
  entfernt.

## Protokoll (eine JSON-Zeile pro Update, \n-terminiert)

`{"id":"<hex>","m":<map_id>,"x":<x>,"y":<y>,"d":<dir 2/4/6/8>,"name":"<charset>"}`

Relay broadcastet jede Zeile an alle ANDEREN Clients. Keine History, kein State.

## Offen / bewusst spaeter

- Remote-Spieler ignoriert Hindernisse (`through = true`, keine Kollisions-Sync). OK fuer jetzt.
- Bewegungsglaettung: haengt an der Sende-Rate. Test-Bot war erst zu langsam
  (400ms -> move-stop), dann etwas zu schnell (200ms). Echte Spieler treiben das
  Tempo selbst. Optionaler Feinschliff spaeter: Interpolations-Puffer (Kachel-Queue
  mit konstantem Playback), macht die Bewegung jitter-unabhaengig.
- Heartbeat fuer `in battle` (Scene_Battle ersetzt Scene_Map-Loop) -- Zukunft.

## Test-Setup lokal

- Relay: `node rejuv-coop/server/relay.js` (Port 7777).
- Bot (simuliert Mitspieler neben dir): `node rejuv-coop/server/bot.js`.
- `testclient.js` -- roher Zeilen-Test (Phase C).
