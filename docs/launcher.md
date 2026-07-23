# Launcher (Terminal)

Ein Node-CLI, das Beitreten/Hosten/Status/Tunnel buendelt, damit man nicht mehr von
Hand `coop_config.txt` schreiben oder Relay/Spiel einzeln starten muss.

## Start

```
node rejuv-coop/server/launcher.js
```

Beim ersten Start sucht er den Spielordner automatisch (relativ zum Repo). Wird er
nicht gefunden, fragt er einmal nach dem Pfad zu `Rejuvenation.exe` und merkt ihn sich
in `launcher_settings.json`.

## Menue

1. **Beitreten (Join)** -- fragt Server-Adresse (`host:port`) und Passwort/Token,
   schreibt `coop_config.txt` in den Spielordner und startet das Spiel.
2. **Hosten (Host)** -- fragt ein Token, startet den Relay (mit Token), optional den
   Tunnel, schreibt die eigene `coop_config.txt` (127.0.0.1:7777) und startet das
   eigene Spiel. Relay/Tunnel laufen, solange der Launcher offen bleibt.
3. **Status anzeigen** -- zeigt, ob der Relay laeuft, die letzten Relay-/Tunnel-Zeilen
   (dort steht die oeffentliche Tunnel-Adresse) und den eigenen Verbindungsstatus aus
   `coop_net.txt`.
4. **Beenden** -- stoppt vom Launcher gestartete Relay-/Tunnel-Prozesse und beendet.

## Hinweise

- Der Launcher merkt sich letzte Server-Adresse, Token, Tunnel-Befehl und Spielordner
  in `launcher_settings.json` (neben `launcher.js`).
- Tunnel-Befehl ist frei konfigurierbar (Default `ngrok tcp 7777`); fuer playit.gg den
  entsprechenden Befehl eintragen.
- Relay/Tunnel sind an den Launcher gebunden (fuer Status/Stop). Das Spiel wird
  losgeloest gestartet und laeuft unabhaengig weiter.
- Muss in einem echten Terminal laufen (interaktive Eingaben). Nicht ueber Pipes
  automatisierbar.
