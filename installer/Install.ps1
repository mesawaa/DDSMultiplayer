# DDS1 CO-OP installer. Run Install.bat (it starts this script).
# Finds Drug Dealer Simulator, copies the mod next to the game's exe, removes the
# "downloaded from the internet" mark from the copied files, and checks the result.
param([string]$Target = "", [switch]$DetectOnly)

$version = "0.19.2"
$exe = "DrugDealerSimulator-Win64-Shipping.exe"
$rel = "steamapps\common\DrugDealerSimulator\DrugDealerSimulator\Binaries\Win64"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$needed = @("dwmapi.dll", "ue4ss\UE4SS.dll", "ue4ss\Mods\DDSMultiplayer\bin\ddsmp_steam.dll", "ue4ss\Mods\DDSMultiplayer\Scripts\main.lua")

function Say($text, $color = "Gray") { Write-Host $text -ForegroundColor $color }

function Missing($folder) {
    $out = @()
    foreach ($f in $needed) { if (-not (Test-Path -LiteralPath (Join-Path $folder $f))) { $out += $f } }
    return $out
}

function AntivirusHelp($files, $where) {
    Say ""
    Say ("These files are missing {0}:" -f $where) Red
    foreach ($f in $files) { Say ("    " + $f) Red }
    Say ""
    Say "Your antivirus removed them. They are the mod's loader (UE4SS, open source) and"
    Say "the mod's own network library. To fix it:"
    Say "  1. Right-click the zip you downloaded > Properties > tick Unblock > OK."
    Say "  2. Extract the zip again and run Install.bat again."
    Say "If they are removed again, open your antivirus, find the removed file in its"
    Say "history or quarantine, choose Allow / Restore, and run Install.bat again."
}

function Find-Game {
    $roots = @()
    foreach ($key in "HKCU:\Software\Valve\Steam", "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam", "HKLM:\SOFTWARE\Valve\Steam") {
        try {
            $p = Get-ItemProperty -Path $key -ErrorAction Stop
            foreach ($name in "SteamPath", "InstallPath") {
                if ($p.$name) { $roots += ($p.$name -replace "/", "\") }
            }
        } catch {}
    }
    $libs = @()
    foreach ($r in ($roots | Select-Object -Unique)) {
        $libs += $r
        $vdf = Join-Path $r "steamapps\libraryfolders.vdf"
        if (Test-Path -LiteralPath $vdf) {
            foreach ($line in Get-Content -LiteralPath $vdf) {
                if ($line -match '"path"\s+"([^"]+)"') { $libs += ($Matches[1] -replace "\\\\", "\") }
            }
        }
    }
    foreach ($l in ($libs | Select-Object -Unique)) {
        $w = Join-Path $l $rel
        if (Test-Path -LiteralPath (Join-Path $w $exe)) { return $w }
    }
    return $null
}

function Resolve-Typed($typed) {
    $p = $typed.Trim().Trim('"')
    if ($p -eq "") { return $null }
    foreach ($c in @($p, (Join-Path $p "DrugDealerSimulator\Binaries\Win64"), (Join-Path $p "Binaries\Win64"))) {
        if (Test-Path -LiteralPath (Join-Path $c $exe)) { return $c }
    }
    return $null
}

Say ""
Say ("DDS1 CO-OP v{0} - installer" -f $version) White
Say ""

# 1. where the game is
$win64 = $null
if ($Target -ne "") { $win64 = Resolve-Typed $Target }
if (-not $win64 -and (Test-Path -LiteralPath (Join-Path $here $exe))) { $win64 = $here }   # the zip was extracted into the game folder
if (-not $win64) { $win64 = Find-Game }
while (-not $win64) {
    Say "Drug Dealer Simulator was not found automatically." Yellow
    Say "In Steam: right-click the game > Manage > Browse local files."
    Say "Copy the path from the address bar of the window that opens, paste it here and press Enter."
    $typed = Read-Host "Game folder (or just Enter to quit)"
    if ($typed.Trim() -eq "") { exit 1 }
    $win64 = Resolve-Typed $typed
}
Say ("Game found: " + $win64)
if ($DetectOnly) { exit 0 }

# 2. the game must be closed
$gameExe = Join-Path $win64 $exe
$running = @(Get-Process -Name "DrugDealerSimulator-Win64-Shipping" -ErrorAction SilentlyContinue | Where-Object { -not $_.Path -or $_.Path -ieq $gameExe })
if ($running.Count -gt 0) {
    Say ""
    Say "The game is running. Close it and run Install.bat again." Red
    exit 1
}

# 3. everything arrived from the zip?
$gone = Missing $here
if ($gone.Count -gt 0) {
    AntivirusHelp $gone "in the folder you extracted the zip to"
    exit 1
}

# 4. copy
$same = ((Resolve-Path -LiteralPath $here).Path.TrimEnd("\") -ieq (Resolve-Path -LiteralPath $win64).Path.TrimEnd("\"))
if (-not $same) {
    try {
        $old = Join-Path $win64 "ue4ss\Mods\DDSMultiplayer"
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction Stop }
        Copy-Item -LiteralPath (Join-Path $here "dwmapi.dll") -Destination $win64 -Force -ErrorAction Stop
        & robocopy (Join-Path $here "ue4ss") (Join-Path $win64 "ue4ss") /E /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "copying the ue4ss folder failed (robocopy code $LASTEXITCODE)" }
    } catch {
        Say ""
        Say ("Could not copy the files: " + $_.Exception.Message) Red
        Say "Close the game and any window that has the game folder's files open, then run Install.bat again."
        exit 1
    }
}

# 5. take the "downloaded from the internet" mark off the installed files
try {
    Unblock-File -LiteralPath (Join-Path $win64 "dwmapi.dll") -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath (Join-Path $win64 "ue4ss") -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
} catch {}

# 6. still there a moment later?
Start-Sleep -Seconds 4
$gone = Missing $win64
if ($gone.Count -gt 0) {
    AntivirusHelp $gone "in the game folder after installing"
    exit 1
}

Say ""
Say ("Installed. DDS1 CO-OP v{0} is in the game folder." -f $version) Green
Say ""
Say "Start the game from Steam. The main menu has a MULTIPLAYER entry below SETTINGS;"
Say ("open it and it says `"Mod v{0}`"." -f $version)
Say "Steam launch options for the game must be empty."
exit 0
