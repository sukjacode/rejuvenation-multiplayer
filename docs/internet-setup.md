# Internet-Verbindung

**GEWAEHLTER WEG: ZeroTier (Abschnitt Z)** -- gratis, kein Zeitlimit, feste Adresse,
verschluesselt, keine Kreditkarte. Eingerichtet und getestet (`auth ok` ueber die
ZeroTier-IP). Alternativen weiter unten als Referenz: Pinggy/ssh (Abschnitt 0,
getestet, aber 60-Min-Cap), Tunnel-Programme (A), Tailscale (B).

---

## Z) ZeroTier (aktiver Weg)

ZeroTier ist ein verschluesseltes privates Overlay-Netz. Jeder Teilnehmer installiert
den Client einmal und tritt dem Netz bei; danach haben alle feste interne IPs.

### Werte deines Setups (Beispiel-Platzhalter)

- Network ID: `<DEINE_ZEROTIER_NETZ_ID>` (16 Hex-Zeichen aus my.zerotier.com)
- Host (Relay-Rechner) ZeroTier-IP: `<HOST_ZEROTIER_IP>` (die 10.x/172.x aus dem Netz)
- Relay-Port: 7777, Token: siehe `server/token.txt`

### Host (einmalig, bereits erledigt)

1. ZeroTier installieren: `winget install ZeroTier.ZeroTierOne`
2. Account auf my.zerotier.com, Netzwerk anlegen -> Network ID.
3. Beitreten: `"C:\ProgramData\ZeroTier\One\zerotier-one_x64.exe" -q join <networkid>`
4. Im Dashboard unter Members das Geraet autorisieren (Auth-Haekchen).
5. Relay starten: `node rejuv-coop/server/relay.js` (Token in `server/token.txt`).
6. WICHTIG einmalig in einer ADMIN-PowerShell (sonst blockt die Windows-Firewall
   eingehende Verbindungen der Mitspieler):
   ```
   New-NetFirewallRule -DisplayName "Rejuv Coop Relay TCP 7777" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 7777 -Profile Any
   ```

### Mitspieler (einmalig)

1. ZeroTier installieren (zerotier.com/download oder winget wie oben).
2. Netz beitreten (Network ID vom Host bekommen) -- per GUI (Tray-Icon -> Join
   Network) oder CLI wie oben.
3. Host setzt im Dashboard das Auth-Haekchen fuer das neue Geraet.
4. `coop_config.txt` im Spielordner:
   ```
   server = <HOST_ZEROTIER_IP>:7777
   token  = <token vom Host>
   ```
5. Spiel starten. Fertig -- gilt dauerhaft, nichts muss pro Session neu gemacht werden.

### Sicherheit

- Netz ist PRIVATE: nur vom Host autorisierte Geraete kommen ueberhaupt ins Netz.
- ZeroTier verschluesselt den gesamten Verkehr Ende-zu-Ende.
- Token bleibt als zweite Schicht im Relay aktiv.

---

---

## 0) Pinggy via ssh (kein Download -- empfohlen)

Windows 10/11 hat OpenSSH eingebaut. Pinggy gibt dir per ssh-Reverse-Tunnel eine
oeffentliche TCP-Adresse fuer den lokalen Relay. Nichts zu installieren.

### Host

1. Relay mit Token starten (Token in `server/token.txt` oder env `COOP_TOKEN`):
   ```
   node rejuv-coop/server/relay.js
   ```
2. Tunnel oeffnen (laeuft im Vordergrund, offen lassen):
   ```
   ssh -p 443 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -R0:localhost:7777 tcp@a.pinggy.io
   ```
   Pinggy gibt eine Zeile wie `tcp://xxxxx.run.pinggy-free.link:43051` aus. Der Teil
   nach `tcp://` (also `xxxxx.run.pinggy-free.link:43051`) ist die oeffentliche Adresse.
3. Eigenes Spiel: `coop_config.txt` mit `server = 127.0.0.1:7777` + Token.

### Mitspieler

- `coop_config.txt` mit `server = <pinggy-adresse>` + gleichem Token. Sonst nichts.

### Haken der Gratis-Variante

- Tunnel laeuft **60 Minuten**, danach ssh neu starten.
- Adresse ist bei jedem Start **neu** -> Mitspieler tragen sie pro Session neu ein.
- Fuer feste Adresse / kein Timeout: Pinggy-Account bzw. Pro, oder Tailscale/Portforwarding.

---

## A) Tunnel-Programm + Token (playit/ngrok etc.)

---

## A) Tunnel + Passwort (Host lokal, Mitspieler brauchen nur Adresse + Token)

Idee: Der Host laesst Relay lokal laufen und "durchreicht" ihn per Tunnel-Dienst
nach aussen. Der Tunnel liefert eine oeffentliche Adresse (der "Link"). Weil die
oeffentlich ist, schuetzt ein gemeinsames **Token** (Passwort) den Zugang.

### Host

1. Token festlegen -- entweder Datei `rejuv-coop/server/token.txt` (eine Zeile) ODER
   env-Variable `COOP_TOKEN` beim Start. Beispiel Datei:
   ```
   geheimespasswort
   ```
2. Relay starten (liest das Token automatisch):
   ```
   node rejuv-coop/server/relay.js
   ```
   Log zeigt `auth: token REQUIRED`, wenn ein Token gesetzt ist.
3. Tunnel starten, der TCP 7777 nach aussen bringt. Empfehlung: **playit.gg**
   (kostenlos, fuer Game-Server gedacht) oder ngrok (`ngrok tcp 7777`).
   Der Tunnel gibt eine oeffentliche Adresse aus, z.B. `147.xxx.yyy.zzz:12345`
   oder `xxxx.playit.gg:12345`. Das ist der "Link".
4. Eigenes Spiel: `coop_config.txt` im Spielordner:
   ```
   server = 127.0.0.1:7777
   token  = geheimespasswort
   ```
   (Der Host selbst kann direkt lokal auf den Relay, kein Tunnel noetig.)

### Mitspieler (brauchen KEIN Zusatztool)

1. `patch/Mods/coop.rb` installiert haben (der Mod).
2. `coop_config.txt` im Spielordner mit der **Tunnel-Adresse** + Token:
   ```
   server = xxxx.playit.gg:12345
   token  = geheimespasswort
   ```
3. Spiel starten.

### Sicherheit

- Ohne passendes Token wird die Verbindung sofort getrennt (`reject: bad token`).
- Token teilt ihr privat (nicht oeffentlich posten), sonst kann jeder mit der
  Tunnel-Adresse mitmachen.

---

## B) Tailscale (privates Netz, jeder Mitspieler installiert Tailscale)

Tailscale baut ein privates Mesh-VPN zwischen den Rechnern. Jeder Rechner bekommt
eine feste 100.x-IP; darueber laeuft der Relay-Traffic, ohne Portfreigabe am Router.

## Rollen

- **Ein** Rechner hostet den Relay (Empfehlung: dein Rechner). Nennen wir ihn HOST.
- Alle Spiele (deins + Freunde) verbinden sich zur **Tailscale-IP des HOST**.

## Einmaliges Setup (auf JEDEM Rechner)

1. Tailscale installieren: https://tailscale.com/download (Windows).
2. Tailscale starten und einloggen -- **alle** Rechner in denselben Tailnet
   (gleiches Konto oder per Einladung ins selbe Netz).
3. Pruefen, dass die Rechner sich sehen:
   - IP anzeigen:  `tailscale ip -4`   (oder `"C:\Program Files\Tailscale\tailscale.exe" ip -4`)
   - Status:       `tailscale status`  (listet alle Peers samt 100.x-IP)

> Account-Anlage/Login macht ihr selbst -- das kann und darf ich nicht fuer euch tun.

## HOST-Rechner

1. Tailscale-IP herausfinden: `tailscale ip -4`  -> z.B. `100.101.102.103`.
2. Relay starten:
   ```
   node rejuv-coop/server/relay.js
   ```
   (bindet auf 0.0.0.0:7777, also auch ueber das Tailscale-Interface erreichbar)
3. Windows-Firewall: beim ersten Start fragt Windows evtl., ob node.exe im Netz
   lauschen darf -> erlauben (mind. "Private Netzwerke"). Falls kein Dialog kam und
   die Verbindung spaeter scheitert, eine eingehende Regel fuer TCP 7777 anlegen.

## Jeder Spiel-Rechner (auch der HOST selbst)

1. Im Spielordner (neben `Rejuvenation.exe`) eine Datei `coop_config.txt` anlegen mit
   EINER Zeile = Tailscale-IP des HOST:
   ```
   100.101.102.103:7777
   ```
   (Vorlage: `rejuv-coop/mod/coop_config.example.txt`)
2. Sicherstellen, dass `patch/Mods/coop.rb` installiert ist (der Mod).
3. Spiel starten.

## Verifikation

- Auf jedem Rechner entsteht im Spielordner `coop_net.txt` mit z.B.
  `connecting to relay 100.101.102.103:7777` und danach `connected to relay ...`.
  Steht dort nur "connecting" ohne "connected" -> die Adresse ist nicht erreichbar
  (falsche IP, Relay laeuft nicht, oder Firewall).
- Auf dem HOST zeigt das Relay-Log `connect <ip>:<port> (clients: N)` fuer jeden
  verbundenen Spieler und `recv ...` mit den Positions-JSONs.
- Bei Fehlern in der Verbindung: `coop_error.txt` im Spielordner ansehen.

## Haeufige Stolpersteine

- **Falsche IP in coop_config.txt** -> nur "connecting", kein "connected".
- **Relay laeuft nicht auf dem HOST** -> dito.
- **Firewall blockt node** -> HOST erreichbar per `tailscale ping <peer>`, aber Port
  7777 zu. Eingehende TCP-7777-Regel erlauben.
- **Verschiedene Tailnets** -> `tailscale status` zeigt den anderen Rechner nicht.
  Beide muessen im selben Netz sein.
