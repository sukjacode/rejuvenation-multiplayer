# install.ps1  --  Pokemon Rejuvenation Co-op: One-Click-Installer fuer Mitspieler
# ============================================================================
# Installiert die Co-op-Mod in eine VORHANDENE Rejuvenation-V14-Installation und
# richtet die Verbindung zum Spiel eines Freundes ueber einen Join-Code ein.
#
# Dieses Programm liefert NICHT das Spiel selbst. Du brauchst deine eigene
# Rejuvenation-V14-Installation (Windows).
#
# Start:  Doppelklick auf install.bat  (oder)
#   powershell -ExecutionPolicy Bypass -File install.ps1
# ============================================================================

# --- Fallback-Download-Quelle (nur falls die Mod-Dateien nicht mitgeliefert sind) ---
# Nach dem Anlegen des GitHub-Repos hier Owner/Name eintragen:
$RepoOwner  = "REPLACE_ME"
$RepoName   = "rejuvenation-coop"
$RepoBranch = "main"

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ModFiles = @("coop.rb", "coop_menu.rb")

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

function Find-GameFolder {
    $cands = @(
        "$env:USERPROFILE\Desktop\pokemulti\game\Rejuvenation-14.0-windows",
        "$env:USERPROFILE\Desktop\Rejuvenation-14.0-windows",
        "$env:USERPROFILE\Downloads\Rejuvenation-14.0-windows",
        "$env:USERPROFILE\Games\Rejuvenation-14.0-windows",
        "C:\Rejuvenation-14.0-windows"
    )
    foreach ($c in $cands) {
        if (Test-Path (Join-Path $c "Game.exe")) { return $c }
        if (Test-Path (Join-Path $c "Rejuvenation.exe")) { return $c }
    }
    return ""
}

function Test-GameFolder([string]$folder) {
    if ([string]::IsNullOrWhiteSpace($folder)) { return $false }
    if (Test-Path (Join-Path $folder "Game.exe")) { return $true }
    if (Test-Path (Join-Path $folder "Rejuvenation.exe")) { return $true }
    return $false
}

function Decode-JoinCode([string]$code) {
    $code = ($code -replace '\s', '')
    if ([string]::IsNullOrWhiteSpace($code)) { throw "Join-Code ist leer." }
    try {
        $plain = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($code))
    } catch {
        throw "Join-Code ist ungueltig (kein gueltiger Code)."
    }
    $parts = $plain -split '\|'
    # Erwartet: v1 | <ztnet> | <ip:port> | <token>
    if ($parts.Count -lt 4 -or $parts[0] -ne "v1") {
        throw "Join-Code hat ein unbekanntes Format."
    }
    return [pscustomobject]@{
        ZtNet  = $parts[1]
        Server = $parts[2]
        Token  = ($parts[3..($parts.Count-1)] -join '|')  # Token darf '|' enthalten
    }
}

# Liefert lokale Pfade der Mod-Dateien; laedt bei Bedarf aus dem Repo.
function Resolve-ModFiles([scriptblock]$log) {
    $result = @{}
    $bases = @(
        (Join-Path $PSScriptRoot "..\mod"),   # Repo-Layout
        (Join-Path $PSScriptRoot "mod"),      # flach gebuendelt
        $PSScriptRoot                          # direkt daneben
    )
    foreach ($f in $ModFiles) {
        $found = $null
        foreach ($b in $bases) {
            $p = Join-Path $b $f
            if (Test-Path $p) { $found = (Resolve-Path $p).Path; break }
        }
        if (-not $found) {
            if ($RepoOwner -eq "REPLACE_ME") {
                throw "Mod-Datei '$f' nicht gefunden und kein Download-Repo konfiguriert."
            }
            $url = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$RepoBranch/mod/$f"
            $tmp = Join-Path $env:TEMP $f
            & $log "Lade $f aus dem Repo..."
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
            $found = $tmp
        }
        $result[$f] = $found
    }
    return $result
}

function Get-ZeroTierStatus {
    $svc = Get-Service -Name "ZeroTierOneService" -ErrorAction SilentlyContinue
    if ($svc) { return "installiert (Dienst: $($svc.Status))" }
    if (Test-Path "$env:ProgramData\ZeroTier\One\zerotier-cli.bat") { return "installiert" }
    return "NICHT installiert"
}

# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------

$form                = New-Object System.Windows.Forms.Form
$form.Text           = "Rejuvenation Co-op -- Installer"
$form.Size           = New-Object System.Drawing.Size(600, 660)
$form.StartPosition  = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox    = $false
$form.Font           = New-Object System.Drawing.Font("Segoe UI", 9)

$y = 12
function Add-Label([string]$text, [int]$size, [bool]$bold, [int]$height) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $style = if ($bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $l.Font = New-Object System.Drawing.Font("Segoe UI", $size, $style)
    $l.Location = New-Object System.Drawing.Point(16, $script:y)
    $l.Size = New-Object System.Drawing.Size(560, $height)
    $form.Controls.Add($l)
    $script:y += $height
    return $l
}

Add-Label "Rejuvenation Co-op installieren" 14 $true 30 | Out-Null
Add-Label "Fuer Mitspieler, die dem Spiel eines Freundes beitreten. Du brauchst deine eigene Rejuvenation-V14-Installation." 9 $false 34 | Out-Null
$script:y += 4

# --- Spielordner ---
Add-Label "1) Rejuvenation-Ordner (enthaelt Game.exe / Rejuvenation.exe)" 9 $true 20 | Out-Null
$txtFolder = New-Object System.Windows.Forms.TextBox
$txtFolder.Location = New-Object System.Drawing.Point(16, $y)
$txtFolder.Size = New-Object System.Drawing.Size(460, 24)
$txtFolder.Text = (Find-GameFolder)
$form.Controls.Add($txtFolder)
$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "Durchsuchen"
$btnBrowse.Location = New-Object System.Drawing.Point(484, $y-1)
$btnBrowse.Size = New-Object System.Drawing.Size(90, 26)
$form.Controls.Add($btnBrowse)
$script:y += 34

# --- Join-Code ---
Add-Label "2) Join-Code (vom Host bekommen und hier einfuegen)" 9 $true 20 | Out-Null
$txtCode = New-Object System.Windows.Forms.TextBox
$txtCode.Location = New-Object System.Drawing.Point(16, $y)
$txtCode.Size = New-Object System.Drawing.Size(558, 54)
$txtCode.Multiline = $true
$txtCode.ScrollBars = "Vertical"
$form.Controls.Add($txtCode)
$script:y += 62

# --- Installieren-Button ---
$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Text = "Mod installieren + verbinden"
$btnInstall.Location = New-Object System.Drawing.Point(16, $y)
$btnInstall.Size = New-Object System.Drawing.Size(280, 34)
$btnInstall.BackColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
$btnInstall.ForeColor = [System.Drawing.Color]::White
$btnInstall.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnInstall)
$script:y += 44

# --- ZeroTier ---
Add-Label "3) ZeroTier (fuer Internet-Verbindung)" 9 $true 20 | Out-Null
$lblZt = New-Object System.Windows.Forms.Label
$lblZt.Location = New-Object System.Drawing.Point(16, $y)
$lblZt.Size = New-Object System.Drawing.Size(558, 20)
$lblZt.Text = "Status: " + (Get-ZeroTierStatus)
$form.Controls.Add($lblZt)
$script:y += 26
$btnZtDownload = New-Object System.Windows.Forms.Button
$btnZtDownload.Text = "ZeroTier herunterladen"
$btnZtDownload.Location = New-Object System.Drawing.Point(16, $y)
$btnZtDownload.Size = New-Object System.Drawing.Size(170, 28)
$form.Controls.Add($btnZtDownload)
$btnZtJoin = New-Object System.Windows.Forms.Button
$btnZtJoin.Text = "Netzwerk beitreten"
$btnZtJoin.Location = New-Object System.Drawing.Point(196, $y)
$btnZtJoin.Size = New-Object System.Drawing.Size(170, 28)
$form.Controls.Add($btnZtJoin)
$script:y += 38

# --- Log ---
$log = New-Object System.Windows.Forms.RichTextBox
$log.Location = New-Object System.Drawing.Point(16, $y)
$log.Size = New-Object System.Drawing.Size(558, 150)
$log.ReadOnly = $true
$log.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 24)
$log.ForeColor = [System.Drawing.Color]::Gainsboro
$log.Font = New-Object System.Drawing.Font("Consolas", 9)
$form.Controls.Add($log)

$Logger = {
    param($msg, $color)
    if (-not $color) { $color = [System.Drawing.Color]::Gainsboro }
    $log.SelectionColor = $color
    $log.AppendText((Get-Date -Format "HH:mm:ss") + "  " + $msg + "`n")
    $log.ScrollToCaret()
    $form.Refresh()
}
$Say = { param($m) & $Logger $m ([System.Drawing.Color]::Gainsboro) }
$Ok  = { param($m) & $Logger $m ([System.Drawing.Color]::LightGreen) }
$Err = { param($m) & $Logger $m ([System.Drawing.Color]::Salmon) }

# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Rejuvenation-Ordner waehlen (mit Game.exe / Rejuvenation.exe)"
    if ($dlg.ShowDialog() -eq "OK") { $txtFolder.Text = $dlg.SelectedPath }
})

$btnZtDownload.Add_Click({
    Start-Process "https://www.zerotier.com/download/"
    & $Say "ZeroTier-Download-Seite geoeffnet. Installieren, dann hier 'Netzwerk beitreten'."
})

$script:JoinNet = ""
$btnZtJoin.Add_Click({
    $net = $script:JoinNet
    if ([string]::IsNullOrWhiteSpace($net)) {
        try { $net = (Decode-JoinCode $txtCode.Text).ZtNet } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($net)) {
        & $Err "Keine ZeroTier-Netz-ID. Erst gueltigen Join-Code einfuegen."
        return
    }
    $cli = "$env:ProgramData\ZeroTier\One\zerotier-cli.bat"
    if (-not (Test-Path $cli)) {
        & $Err "ZeroTier nicht gefunden. Erst installieren (Button links)."
        return
    }
    try {
        & $Say "Trete ZeroTier-Netz $net bei (Adminrechte noetig)..."
        Start-Process -FilePath $cli -ArgumentList "join", $net -Verb RunAs -Wait
        & $Ok "Beitritt angestossen. Der HOST muss dein Geraet noch autorisieren (my.zerotier.com)."
    } catch {
        & $Err ("Beitritt fehlgeschlagen: " + $_.Exception.Message)
        & $Say "Alternativ manuell: ZeroTier-Tray -> Join Network -> $net eingeben."
    }
    $lblZt.Text = "Status: " + (Get-ZeroTierStatus)
})

$btnInstall.Add_Click({
    try {
        $btnInstall.Enabled = $false
        $folder = $txtFolder.Text.Trim()

        if (-not (Test-GameFolder $folder)) {
            & $Err "Kein gueltiger Rejuvenation-Ordner (Game.exe / Rejuvenation.exe fehlt)."
            return
        }

        # Join-Code auswerten
        $jc = Decode-JoinCode $txtCode.Text
        $script:JoinNet = $jc.ZtNet
        & $Say ("Join-Code ok. Server: " + $jc.Server + "  ZT-Netz: " + $jc.ZtNet)

        # Mod-Dateien holen + kopieren
        $mods = Resolve-ModFiles $Say
        $modsDir = Join-Path $folder "patch\Mods"
        if (-not (Test-Path $modsDir)) {
            New-Item -ItemType Directory -Path $modsDir -Force | Out-Null
            & $Say "Ordner patch\Mods angelegt."
        }
        foreach ($f in $ModFiles) {
            Copy-Item -Path $mods[$f] -Destination (Join-Path $modsDir $f) -Force
            & $Ok "installiert: patch\Mods\$f"
        }

        # coop_config.txt schreiben
        $cfg = Join-Path $folder "coop_config.txt"
        $content = @(
            "# Automatisch vom Installer erzeugt.",
            ("server = " + $jc.Server),
            ("token  = " + $jc.Token)
        ) -join "`r`n"
        Set-Content -Path $cfg -Value $content -Encoding UTF8
        & $Ok "Verbindung geschrieben: coop_config.txt"

        # ZeroTier-Hinweis
        $zt = Get-ZeroTierStatus
        $lblZt.Text = "Status: $zt"
        if ($zt -like "*NICHT*") {
            & $Say "Naechster Schritt: ZeroTier installieren + Netzwerk $($jc.ZtNet) beitreten (Schritt 3)."
        } else {
            & $Say "Falls noch nicht geschehen: ZeroTier-Netz $($jc.ZtNet) beitreten (Schritt 3)."
        }

        & $Ok "FERTIG. Spiel starten -- ihr solltet euch auf derselben Map sehen."
    } catch {
        & $Err ("Fehler: " + $_.Exception.Message)
    } finally {
        $btnInstall.Enabled = $true
    }
})

& $Say "Bereit. Ordner pruefen, Join-Code einfuegen, dann 'Mod installieren + verbinden'."
[void]$form.ShowDialog()
