# Rejuvenation Co-op -- Nativer Launcher (WinForms).
# Start am besten ueber start-launcher.bat (versteckt das Konsolenfenster).

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ServerDir    = $PSScriptRoot
$SettingsFile = Join-Path $ServerDir "launcher_settings.json"
$TokenFile    = Join-Path $ServerDir "token.txt"
$RelayJs      = Join-Path $ServerDir "relay.js"
$RelayPort    = 7777
$ZtExe        = "C:\ProgramData\ZeroTier\One\zerotier-one_x64.exe"

# --- Hilfsfunktionen ---------------------------------------------------------

function Load-Settings {
  try { return (Get-Content -Raw $SettingsFile | ConvertFrom-Json) } catch { return New-Object PSObject }
}
function Save-Setting([string]$name, [string]$value) {
  $s = Load-Settings
  if ($s.PSObject.Properties[$name]) { $s.$name = $value }
  else { $s | Add-Member -NotePropertyName $name -NotePropertyValue $value }
  $s | ConvertTo-Json | Set-Content -Encoding utf8 $SettingsFile
}
function Get-Setting([string]$name) {
  $s = Load-Settings
  if ($s.PSObject.Properties[$name]) { return [string]$s.$name }
  return ""
}

function Load-Token {
  try { $t = (Get-Content -Raw $TokenFile).Trim(); if ($t) { return $t } } catch {}
  return ""
}
function Save-Token([string]$t) { $t | Set-Content -Encoding ascii $TokenFile }
function New-RandomToken {
  -join ((1..16) | ForEach-Object { "0123456789abcdef"[(Get-Random -Maximum 16)] })
}

function Get-ZtStatus {
  # Liefert @{ ok=bool; text=string; ip=string; nwid=string }
  $r = @{ ok = $false; text = "ZeroTier nicht installiert (winget install ZeroTier.ZeroTierOne)"; ip = ""; nwid = "" }
  if (-not (Test-Path $ZtExe)) { return $r }
  try {
    $info = (& $ZtExe -q info 2>$null)
    if (-not $info) { $r.text = "ZeroTier-Dienst antwortet nicht"; return $r }
    $online = ($info -match "ONLINE")
    $lines = (& $ZtExe -q listnetworks 2>$null) -split "`n"
    $netLines = @()
    foreach ($ln in $lines) {
      $ln = $ln.Trim()
      if ($ln -match "^200 listnetworks ([0-9a-f]{16})\s+(.*)$") {
        $nwid = $Matches[1]
        $rest = ($Matches[2].Trim()) -split "\s+"
        $ips = $rest[$rest.Length - 1]
        $status = $rest[$rest.Length - 4]
        if ($status -eq "OK" -and $ips -ne "-") {
          $ip = ($ips -split ",")[0] -replace "/\d+$", ""
          $r.ok = $true; $r.ip = $ip; $r.nwid = $nwid
          $netLines += "Netz $nwid  OK  IP: $ip"
        } elseif ($status -eq "REQUESTING_CONFIGURATION" -or $status -eq "ACCESS_DENIED") {
          $netLines += "Netz $nwid  wartet auf Freigabe durch den Host!"
        } else {
          $netLines += "Netz $nwid  Status: $status"
        }
      }
    }
    if ($netLines.Count -eq 0) { $netLines += "In keinem Netzwerk (Host-Netz-ID im Beitreten-Feld eintragen)" }
    $stateStr = "OFFLINE"; if ($online) { $stateStr = "ONLINE" }
    $r.text = "ZeroTier " + $stateStr + "`n" + ($netLines -join "`n")
    return $r
  } catch { $r.text = "ZeroTier-Fehler: $($_.Exception.Message)"; return $r }
}

function Test-RelayPort {
  try {
    $c = New-Object Net.Sockets.TcpClient
    $iar = $c.BeginConnect("127.0.0.1", $RelayPort, $null, $null)
    if ($iar.AsyncWaitHandle.WaitOne(300)) { $c.EndConnect($iar); $c.Close(); return $true }
    $c.Close(); return $false
  } catch { return $false }
}

function Find-GameExe {
  $saved = Get-Setting "gameExe"
  if ($saved -and (Test-Path $saved)) { return $saved }
  $dirSetting = Get-Setting "gameDir"
  if ($dirSetting) {
    $p = Join-Path $dirSetting "Rejuvenation.exe"
    if (Test-Path $p) { return $p }
  }
  $cand = Join-Path (Split-Path (Split-Path $ServerDir)) "game\Rejuvenation-14.0-windows\Rejuvenation.exe"
  if (Test-Path $cand) { return $cand }
  return ""
}

function Write-CoopConfig([string]$gameDir, [string]$server, [string]$token) {
  $lines = @("# vom Launcher geschrieben", "server = $server")
  if ($token) { $lines += "token  = $token" }
  ($lines -join "`n") + "`n" | Set-Content -Encoding ascii (Join-Path $gameDir "coop_config.txt")
}

function Show-Err([string]$text) {
  [Windows.Forms.MessageBox]::Show($text, "Fehler", "OK", "Error") | Out-Null
}

function Test-TokenFormat([string]$token) {
  return ($token -match "^[A-Za-z0-9_\-]{1,64}$")
}

# Live-Pruefung: verbindet kurz zum Relay und testet das Token.
# Rueckgabe: "ok" | "badformat" | "unreachable" | "badtoken"
function Test-CoopServer([string]$server, [string]$token) {
  if ($server -notmatch "^([^\s:]+):(\d{1,5})$") { return "badformat" }
  $sHost = $Matches[1]; $sPort = [int]$Matches[2]
  if ($sPort -lt 1 -or $sPort -gt 65535) { return "badformat" }
  try {
    $c = New-Object Net.Sockets.TcpClient
    $iar = $c.BeginConnect($sHost, $sPort, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne(2500)) { $c.Close(); return "unreachable" }
    $c.EndConnect($iar)
    $stream = $c.GetStream()
    $auth = '{"t":"auth","token":"' + $token + '","id":"launcher-test"}' + "`n"
    $bytes = [Text.Encoding]::UTF8.GetBytes($auth)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.ReadTimeout = 1200
    $buf = New-Object byte[] 512
    try {
      $n = $stream.Read($buf, 0, 512)
      $c.Close()
      if ($n -le 0) { return "badtoken" }   # Server hat sofort getrennt
      $resp = [Text.Encoding]::UTF8.GetString($buf, 0, $n)
      if ($resp -match "bad token" -or $resp -match "auth required") { return "badtoken" }
      return "ok"                            # Daten anderer Spieler -> auth ok
    } catch {
      # Lese-Timeout: Server schweigt bei erfolgreicher Auth -> ok
      $c.Close()
      return "ok"
    }
  } catch { return "unreachable" }
}

# --- Relay-Prozess -----------------------------------------------------------

$script:RelayProc = $null
function Start-Relay {
  if ($script:RelayProc -and -not $script:RelayProc.HasExited) { return }
  $script:RelayProc = Start-Process -FilePath "node" -ArgumentList "`"$RelayJs`"" -WorkingDirectory $ServerDir -WindowStyle Hidden -PassThru
}
function Stop-Relay {
  if ($script:RelayProc -and -not $script:RelayProc.HasExited) {
    try { Stop-Process -Id $script:RelayProc.Id -Force -Confirm:$false } catch {}
  }
  $script:RelayProc = $null
}

# --- GUI ---------------------------------------------------------------------

$form = New-Object Windows.Forms.Form
$form.Text = "Rejuvenation Co-op Launcher"
$form.ClientSize = New-Object Drawing.Size(640, 780)
$form.FormBorderStyle = "Sizable"          # frei skalierbar
$form.MinimumSize = New-Object Drawing.Size(600, 720)
$form.MaximizeBox = $true
$form.BackColor = [Drawing.Color]::FromArgb(24, 26, 34)
$form.ForeColor = [Drawing.Color]::White
$form.Font = New-Object Drawing.Font("Segoe UI", 10)

function New-Label($text, $x, $y, $w, $h) {
  $l = New-Object Windows.Forms.Label
  $l.Text = $text; $l.Location = New-Object Drawing.Point($x, $y)
  $l.Size = New-Object Drawing.Size($w, $h)
  $form.Controls.Add($l); return $l
}
function New-TextBox($x, $y, $w) {
  $t = New-Object Windows.Forms.TextBox
  $t.Location = New-Object Drawing.Point($x, $y); $t.Width = $w
  $t.BackColor = [Drawing.Color]::FromArgb(35, 39, 52); $t.ForeColor = [Drawing.Color]::White
  $t.BorderStyle = "FixedSingle"
  $form.Controls.Add($t); return $t
}
function New-Button($text, $x, $y, $w) {
  $b = New-Object Windows.Forms.Button
  $b.Text = $text; $b.Location = New-Object Drawing.Point($x, $y); $b.Width = $w; $b.Height = 32
  $b.FlatStyle = "Flat"; $b.BackColor = [Drawing.Color]::FromArgb(124, 92, 255); $b.ForeColor = [Drawing.Color]::White
  $b.FlatAppearance.BorderSize = 0
  $form.Controls.Add($b); return $b
}

# Abschnitt: Spiel (oben, Breite waechst mit)
New-Label "SPIEL" 20 15 200 18 | ForEach-Object { $_.ForeColor = [Drawing.Color]::FromArgb(138, 144, 162) }
$txtGame = New-TextBox 20 38 520
$txtGame.Anchor = "Top,Left,Right"
$txtGame.Text = Find-GameExe
$btnBrowse = New-Button "..." 552 36 68
$btnBrowse.Anchor = "Top,Right"
$btnBrowse.BackColor = [Drawing.Color]::FromArgb(45, 49, 64)
$btnBrowse.Add_Click({
  $dlg = New-Object Windows.Forms.OpenFileDialog
  $dlg.Filter = "Spiel-EXE (*.exe)|*.exe"
  $dlg.Title = "Rejuvenation.exe auswaehlen"
  if ($dlg.ShowDialog() -eq "OK") {
    $txtGame.Text = $dlg.FileName
    Save-Setting "gameExe" $dlg.FileName
  }
})

# Abschnitt: ZeroTier-Status
New-Label "NETZWERK" 20 82 200 18 | ForEach-Object { $_.ForeColor = [Drawing.Color]::FromArgb(138, 144, 162) }
$lblZt = New-Label "lade..." 20 104 600 64
$lblZt.Anchor = "Top,Left,Right"
$lblZt.Font = New-Object Drawing.Font("Consolas", 9.5)

# Abschnitt: Hosten
New-Label "HOSTEN" 20 178 200 18 | ForEach-Object { $_.ForeColor = [Drawing.Color]::FromArgb(138, 144, 162) }
New-Label "Passwort/Token:" 20 206 115 22
$txtToken = New-TextBox 140 204 300
$txtToken.Text = Load-Token
$btnHost = New-Button "Server starten" 20 238 190
$btnStop = New-Button "Server stoppen" 220 238 140
$btnStop.BackColor = [Drawing.Color]::FromArgb(90, 40, 60)
$btnStop.Visible = $false

# Anleitungs-Kasten: waechst mit dem Fenster (horizontal + vertikal)
$txtShare = New-Object Windows.Forms.TextBox
$txtShare.Multiline = $true; $txtShare.ReadOnly = $true; $txtShare.ScrollBars = "Vertical"
$txtShare.Location = New-Object Drawing.Point(20, 282); $txtShare.Size = New-Object Drawing.Size(500, 200)
$txtShare.Anchor = "Top,Bottom,Left,Right"
$txtShare.BackColor = [Drawing.Color]::FromArgb(14, 16, 22); $txtShare.ForeColor = [Drawing.Color]::FromArgb(170, 178, 197)
$txtShare.Font = New-Object Drawing.Font("Consolas", 9.5)
$txtShare.BorderStyle = "FixedSingle"
$form.Controls.Add($txtShare)
$btnCopy = New-Button "Kopieren" 530 282 90
$btnCopy.Anchor = "Top,Right"
$btnCopy.BackColor = [Drawing.Color]::FromArgb(45, 49, 64)
$btnCopy.Add_Click({ if ($txtShare.Text) { Set-Clipboard -Value $txtShare.Text } })

# Abschnitt: Beitreten (haengt am unteren Rand)
New-Label "BEITRETEN" 20 502 200 18 | ForEach-Object { $_.ForeColor = [Drawing.Color]::FromArgb(138, 144, 162); $_.Anchor = "Bottom,Left" }
$lblJs = New-Label "Server (ip:port):" 20 530 115 22; $lblJs.Anchor = "Bottom,Left"
$txtJoinServer = New-TextBox 140 528 300
$txtJoinServer.Anchor = "Bottom,Left"
$txtJoinServer.Text = Get-Setting "lastServer"
$lblJt = New-Label "Token:" 20 562 115 22; $lblJt.Anchor = "Bottom,Left"
$txtJoinToken = New-TextBox 140 560 300
$txtJoinToken.Anchor = "Bottom,Left"
$btnJoin = New-Button "Verbinden + Spiel starten" 20 594 230
$btnJoin.Anchor = "Bottom,Left"
$lblNw = New-Label "ZeroTier-Netz-ID:" 20 640 115 22; $lblNw.Anchor = "Bottom,Left"
$txtNwid = New-TextBox 140 638 200
$txtNwid.Anchor = "Bottom,Left"
$txtNwid.Text = Get-Setting "lastNetworkId"
$btnZtJoin = New-Button "Netz beitreten" 350 636 140
$btnZtJoin.Anchor = "Bottom,Left"
$btnZtJoin.BackColor = [Drawing.Color]::FromArgb(45, 49, 64)

# Statuszeile (unten, Breite waechst mit)
$lblStatus = New-Label "" 20 688 600 70
$lblStatus.Anchor = "Bottom,Left,Right"
$lblStatus.Font = New-Object Drawing.Font("Consolas", 9)
$lblStatus.ForeColor = [Drawing.Color]::FromArgb(154, 161, 181)

# --- Aktionen ----------------------------------------------------------------

$btnHost.Add_Click({
  # Vorbedingungen pruefen, bevor irgendwas startet
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Show-Err "Node.js wurde nicht gefunden -- der Server (Relay) braucht es.`nInstallieren: nodejs.org"
    return
  }
  $token = $txtToken.Text.Trim()
  if (-not $token) { $token = New-RandomToken; $txtToken.Text = $token }
  if (-not (Test-TokenFormat $token)) {
    Show-Err "Ungueltiges Token: nur Buchstaben, Ziffern, - und _ erlaubt (max. 64 Zeichen), keine Leerzeichen."
    return
  }
  $exe = $txtGame.Text.Trim()
  if ($exe -and -not (Test-Path $exe)) {
    Show-Err "Spiel-EXE nicht gefunden:`n$exe`n`nPfad pruefen oder ueber '...' neu auswaehlen."
    return
  }
  Save-Token $token
  Start-Relay
  if ($exe) {
    Write-CoopConfig (Split-Path $exe) "127.0.0.1:$RelayPort" $token
    Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe)
  }
})

$btnStop.Add_Click({ Stop-Relay })

$btnJoin.Add_Click({
  $exe = $txtGame.Text.Trim()
  if (-not $exe) {
    Show-Err "Bitte zuerst oben die Rejuvenation.exe auswaehlen ('...'-Button)."
    return
  }
  if (-not (Test-Path $exe)) {
    Show-Err "Spiel-EXE nicht gefunden:`n$exe`n`nPfad pruefen oder ueber '...' neu auswaehlen."
    return
  }
  $server = $txtJoinServer.Text.Trim()
  $token = $txtJoinToken.Text.Trim()
  if (-not $server) {
    Show-Err "Server-Adresse fehlt (bekommst du vom Host, z.B. 10.147.20.10:7777)."
    return
  }
  if ($server -notmatch "^([^\s:]+):(\d{1,5})$") {
    Show-Err "Server-Adresse hat das falsche Format.`nRichtig: ip:port  --  z.B. 10.147.20.10:7777"
    return
  }
  if ($token -and -not (Test-TokenFormat $token)) {
    Show-Err "Ungueltiges Token: nur Buchstaben, Ziffern, - und _ erlaubt, keine Leerzeichen."
    return
  }
  # Live-Test: erst verbinden + Token pruefen, dann Spiel starten
  $btnJoin.Enabled = $false; $btnJoin.Text = "pruefe..."
  $result = Test-CoopServer $server $token
  $btnJoin.Enabled = $true; $btnJoin.Text = "Verbinden + Spiel starten"
  switch ($result) {
    "badformat"   { Show-Err "Server-Adresse hat das falsche Format (ip:port)."; return }
    "unreachable" { Show-Err "Server nicht erreichbar: $server`n`nMoegliche Ursachen:`n- IP oder Port falsch getippt`n- Der Host hat den Server nicht gestartet`n- ZeroTier nicht verbunden / noch nicht freigegeben (siehe NETZWERK oben)"; return }
    "badtoken"    { Show-Err "Der Server hat die Verbindung abgelehnt: Passwort/Token ist falsch.`nToken beim Host nachfragen."; return }
  }
  Write-CoopConfig (Split-Path $exe) $server $token
  Save-Setting "lastServer" $server
  Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe)
})

$btnZtJoin.Add_Click({
  $nwid = $txtNwid.Text.Trim().ToLower()
  if ($nwid -notmatch "^[0-9a-f]{16}$") {
    [Windows.Forms.MessageBox]::Show("Network ID muss 16 Zeichen (0-9a-f) haben.", "Ungueltig") | Out-Null
    return
  }
  $out = & $ZtExe -q join $nwid 2>$null
  if ($out -match "OK") {
    Save-Setting "lastNetworkId" $nwid
    [Windows.Forms.MessageBox]::Show("Beigetreten. Der Host muss dich jetzt im ZeroTier-Dashboard freigeben (Auth-Haekchen). Danach erscheint oben deine IP.", "Beigetreten") | Out-Null
  } else {
    [Windows.Forms.MessageBox]::Show("Join fehlgeschlagen. Laeuft der ZeroTier-Dienst?", "Fehler") | Out-Null
  }
})

# --- Timer: Status aktualisieren --------------------------------------------

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({
  $zt = Get-ZtStatus
  $lblZt.Text = $zt.text
  $relayUp = Test-RelayPort
  $ownRelay = ($script:RelayProc -and -not $script:RelayProc.HasExited)
  $btnStop.Visible = $ownRelay
  if ($ownRelay) { $btnHost.Text = "Server laeuft"; $btnHost.Enabled = $false }
  elseif ($relayUp) { $btnHost.Text = "Server laeuft (extern)"; $btnHost.Enabled = $false }
  else { $btnHost.Text = "Server starten"; $btnHost.Enabled = $true }

  if ($zt.ok) {
    $tok = Load-Token
    if (-not $tok) { $tok = "(noch keins -- wird bei 'Server starten' erzeugt)" }
    $prefix = ""
    if (-not $relayUp) {
      $prefix = ">>> SERVER IST AUS -- erst 'Server starten' klicken, sonst kann niemand beitreten! <<<`r`n`r`n"
    }
    $txtShare.Text = $prefix + @"
=================================================
  POKEMON REJUVENATION CO-OP  --  SO MACHST DU MIT
=================================================

  SCHRITT 1 -- Spiel installieren
  -------------------------------
  Download:  rebornevo.com/rejuvdown
  (Version 14, komplett entpacken)


  SCHRITT 2 -- Co-op-Mod installieren
  -----------------------------------
  Den 'patch'-Ordner vom Host in den
  Spielordner kopieren.
  (wichtig: patch\Mods\coop.rb)


  SCHRITT 3 -- ZeroTier installieren
  ----------------------------------
  Download:  zerotier.com/download


  SCHRITT 4 -- Netz beitreten
  ---------------------------
  Network ID:  $($zt.nwid)
  (ZeroTier-Symbol unten rechts
   -> Join Network -> ID eingeben)


  SCHRITT 5 -- Freigeben lassen
  -----------------------------
  Dem Host Bescheid sagen -- er gibt
  dich im ZeroTier-Dashboard frei.


  SCHRITT 6 -- Verbinden
  ----------------------
  Im Launcher unter BEITRETEN:

      Server:  $($zt.ip):$RelayPort
      Token:   $tok

  (oder im Spielordner die Datei
   'coop_config.txt' anlegen mit:
      server = $($zt.ip):$RelayPort
      token  = $tok )


  SCHRITT 7 -- Spiel starten. Fertig!
  -----------------------------------
  Ihr seht euch, sobald ihr auf
  derselben Map seid.
"@
  } else {
    $txtShare.Text = "ZeroTier ist nicht verbunden -- siehe NETZWERK oben.`r`nOhne ZeroTier-IP kann keine Mitspieler-Anleitung erzeugt werden."
  }

  # eigene Verbindung aus coop_net.txt
  $exe = $txtGame.Text.Trim()
  $statusLines = @()
  if ($relayUp) { $statusLines += "Relay: laeuft auf Port $RelayPort" } else { $statusLines += "Relay: aus" }
  if ($exe) {
    $netFile = Join-Path (Split-Path $exe) "coop_net.txt"
    if (Test-Path $netFile) {
      $tail = Get-Content $netFile -Tail 2 -ErrorAction SilentlyContinue
      if ($tail) { $statusLines += $tail }
    }
  }
  $lblStatus.Text = ($statusLines -join "`n")
})
$timer.Start()

$form.Add_FormClosing({ $timer.Stop(); Stop-Relay })

# initiale Anzeige
$lblZt.Text = (Get-ZtStatus).text

[void]$form.ShowDialog()
