# Recon-Ergebnis (Phase B)

Ausgeführt über `patch/Init/netcheck.rb` beim Spielstart, Rejuvenation V14 Windows-Build.

## Umgebung

- **RUBY_VERSION:** 3.1.3
- **RUBY_PLATFORM:** x64-mingw32 (native Windows, echte Sockets)

## Bibliotheken

| Lib | Status |
|-----|--------|
| socket | OK |
| thread | OK |
| json | OK |
| Win32API | bereits vom Spiel geladen |
| HTTPLite | bereits vom Spiel geladen |

## $LOAD_PATH

```
<Spielordner>
stdlib
stdlib/x64-mingw32
gems
```

## Konsequenzen fürs Design

- Native `socket`-API nutzbar → TCP-Client direkt, kein Win32API-Umweg nötig.
- `Thread` verfügbar → Netzwerk läuft im Hintergrund-Thread.
- `json` verfügbar → Serialisierung ohne eigene Lib.
- Trotz moderner Ruby-Version bleiben die RGSS-Constraints: kein blockierendes I/O in der Spiel-Loop, `read_nonblock` + `rescue Errno::EWOULDBLOCK`, jeder Thread-Body mit `rescue Exception` in Datei geloggt, kein `puts` (Konsole unsichtbar).

## Injektionspunkt (aus Phase A)

- `patch/Init/*.rb` läuft vor dem Hauptmenü — das ist der Einstiegspunkt.
- `patch/Mods/*.rb` überschreibt einzelne Methoden (später für Game_Character etc.).
- Kein Eingriff in `Scripts.rxdata` oder Core-Dateien nötig — offizielles Mod-System (siehe `Modding.txt`).
