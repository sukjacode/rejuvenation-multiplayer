# make-joincode.ps1  --  HOST-Helfer
# ----------------------------------------------------------------------------
# Erzeugt einen "Join-Code": einen einzelnen String, der alles buendelt, was ein
# Mitspieler zum Verbinden braucht -- ZeroTier-Netz-ID, deine Relay-Adresse
# (ZeroTier-IP:Port) und das Relay-Token. Der Mitspieler fuegt den Code einfach
# in den Installer ein; er muss keine IP/kein Token von Hand eintippen.
#
# Aufruf (im Ordner rejuv-coop):
#   powershell -ExecutionPolicy Bypass -File installer\make-joincode.ps1
#
# Der Code wird angezeigt UND in die Zwischenablage kopiert.
# ----------------------------------------------------------------------------

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot   # ...\rejuv-coop

function Read-WithDefault([string]$prompt, [string]$default) {
    if ($default) { $p = "$prompt [$default]" } else { $p = $prompt }
    $v = Read-Host $p
    if ([string]::IsNullOrWhiteSpace($v)) { return $default }
    return $v.Trim()
}

# --- Token aus server/token.txt lesen (Fallback: nachfragen) ---
$tokenFile = Join-Path $repoRoot "server\token.txt"
$token = ""
if (Test-Path $tokenFile) {
    $token = (Get-Content $tokenFile -Raw).Trim()
    Write-Host "Token aus server\token.txt gelesen." -ForegroundColor DarkGray
}

# --- ZeroTier-Netz-ID + eigene ZeroTier-IP automatisch ermitteln ---
$ztNet = ""
$ztIp  = ""
$ztCli = "$env:ProgramData\ZeroTier\One\zerotier-cli.bat"
if (Test-Path $ztCli) {
    try {
        $lines = & $ztCli listnetworks 2>$null
        foreach ($l in $lines) {
            # Format: 200 listnetworks <nwid> <name> <mac> <status> <type> <dev> <ips>
            if ($l -match '^\s*200 listnetworks\s+(\S+)\s+.*\s(OK|REQUESTING_CONFIGURATION)\s+\S+\s+\S+\s+(\S+)') {
                $ztNet = $Matches[1]
                $ipField = $Matches[3]
                if ($ipField -and $ipField -ne '-') {
                    $ztIp = ($ipField -split ',')[0] -replace '/\d+$', ''
                }
                break
            }
        }
    } catch { }
}

Write-Host ""
Write-Host "=== Join-Code erzeugen ===" -ForegroundColor Cyan
$ztNet = Read-WithDefault "ZeroTier-Netzwerk-ID"        $ztNet
$ztIp  = Read-WithDefault "Deine ZeroTier-IP (Host)"    $ztIp
$port  = Read-WithDefault "Relay-Port"                  "7777"
$token = Read-WithDefault "Relay-Token"                 $token

if ([string]::IsNullOrWhiteSpace($ztIp) -or [string]::IsNullOrWhiteSpace($token)) {
    Write-Host "ABBRUCH: ZeroTier-IP und Token sind Pflicht." -ForegroundColor Red
    exit 1
}

# --- Kodieren:  v1|<ztnet>|<ip:port>|<token>  -> Base64 ---
$plain = "v1|$ztNet|${ztIp}:$port|$token"
$code  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($plain))

Write-Host ""
Write-Host "Dein Join-Code (an Mitspieler weitergeben):" -ForegroundColor Green
Write-Host ""
Write-Host "  $code" -ForegroundColor Yellow
Write-Host ""
try { Set-Clipboard -Value $code; Write-Host "(in die Zwischenablage kopiert)" -ForegroundColor DarkGray } catch { }
Write-Host ""
Write-Host "WICHTIG fuer den Host:" -ForegroundColor Cyan
Write-Host " - Relay laeuft (server\relay.js bzw. ueber den Launcher)."
Write-Host " - Mitspieler-Geraet im ZeroTier-Central autorisieren (my.zerotier.com ->"
Write-Host "   Netzwerk -> Members -> Haken bei 'Auth')."
Write-Host " - Windows-Firewall laesst eingehend TCP $port zu (siehe docs\internet-setup.md)."
