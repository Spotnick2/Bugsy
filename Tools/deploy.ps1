<#
    deploy.ps1 - Copy Bugsy (and optionally BugsyProbe) into the Forever AddOns folder.

    The repo keeps "## Version: @project-version@" for the packager; the deployed
    copy gets "dev". The repo copy is never modified. Bugsy embeds no library yet.

    Usage:
        pwsh Tools/deploy.ps1               # !Bugsy
        pwsh Tools/deploy.ps1 -Probe        # ...and BugsyProbe
        pwsh Tools/deploy.ps1 -ProbeOnly    # just BugsyProbe

    BugsyProbe is a ForeverProbe module, so -Probe and -ProbeOnly deploy the
    ForeverProbe checkout first ($env:FOREVERPROBE, else ..\ForeverProbe).
        pwsh Tools/deploy.ps1 -AddOnsPath "D:\...\_forever_\Interface\AddOns"
#>

param(
    [string]$AddOnsPath = "C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns",
    [switch]$Probe,
    [switch]$ProbeOnly
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path $AddOnsPath)) { Write-Error "AddOns path not found: $AddOnsPath"; exit 1 }
$ForeverProbe = if ($env:FOREVERPROBE) { $env:FOREVERPROBE } else { Join-Path (Split-Path -Parent $RepoRoot) "ForeverProbe" }
$Toc = "!Bugsy.toc"

function Deploy-Addon {
    $dest = Join-Path $AddOnsPath "!Bugsy"
    Write-Host "Deploying Bugsy -> $dest" -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    # The TOC is the list of what ships.
    $lua = @(Get-Content -LiteralPath (Join-Path $RepoRoot $Toc) | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -notmatch "^#" -and $_ -match "[.]lua$" })
    $media = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot "Media") -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in ".tga", ".blp" } | ForEach-Object { "Media\" + $_.Name })
    $files = @($Toc, "LICENSE") + $lua + $media
    foreach ($f in $files) {
        $src = Join-Path $RepoRoot $f
        $to = Join-Path $dest $f
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
        if ($f -like "*.toc") {
            (Get-Content -LiteralPath $src -Raw) -replace '## Version: @project-version@', '## Version: dev' |
                Set-Content -LiteralPath $to -NoNewline
        } else {
            Copy-Item -LiteralPath $src -Destination $to -Force
        }
        Write-Host "  $f"
    }
    # A file removed from the repo must not linger where the client finds it.
    $keep = $files | ForEach-Object { $_.Replace("/", "\") }
    Get-ChildItem -LiteralPath $dest -File -Recurse | ForEach-Object {
        $rel = $_.FullName.Substring($dest.Length + 1)
        if ($keep -notcontains $rel) {
            Write-Host "  removing stale $rel" -ForegroundColor DarkYellow
            Remove-Item -LiteralPath $_.FullName -Force
        }
    }
}

function Deploy-Probe {
    # The host first: BugsyProbe has ## Dependencies: ForeverProbe.
    if (-not (Test-Path -LiteralPath (Join-Path $ForeverProbe "Tools\deploy.ps1"))) {
        Write-Error "ForeverProbe checkout not found at $ForeverProbe (or set `$env:FOREVERPROBE)"
        exit 1
    }
    & pwsh -NoProfile -File (Join-Path $ForeverProbe "Tools\deploy.ps1") -AddOnsPath $AddOnsPath
    if ($LASTEXITCODE -ne 0) { Write-Error "ForeverProbe deploy refused; BugsyProbe was not touched"; exit 1 }
    $dest = Join-Path $AddOnsPath "BugsyProbe"
    Write-Host "Deploying BugsyProbe -> $dest" -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $RepoRoot "Tools\BugsyProbe") -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $dest $_.Name) -Force
        Write-Host "  $($_.Name)"
    }
}

if (-not $ProbeOnly) { Deploy-Addon }
if ($Probe -or $ProbeOnly) { Deploy-Probe }

Write-Host ""
Write-Host "/reload is enough, a brand-new addon folder included." -ForegroundColor Yellow
Write-Host "In game:  /bugsy   (probe: /fp bugsy, /fp steps; disable any other error collector for the probe)" -ForegroundColor Green
