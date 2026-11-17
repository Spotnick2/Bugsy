<#
    run.ps1 - Syntax-check the addon, the library and the probe, and run every
    tests\test_*.lua under Lua 5.1, through WowTestKit's runner at the commit
    tests\kit.pin names (its README).

    Usage:
        pwsh tests/run.ps1
        pwsh tests/run.ps1 -Lua "C:\path\to\lua5.1.exe"
        pwsh tests/run.ps1 -KitDev        # the ..\WowTestKit working copy instead of the pin
#>

param(
    [string]$Lua = "C:\Program Files (x86)\Lua\5.1\lua.exe",
    [switch]$KitDev
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $PSScriptRoot "kit.ps1")
$kit = Get-WowTestKit -RepoRoot $RepoRoot -KitDev:$KitDev

# The TOC's files are syntax-checked by the kit; the library and the probe are ours.
$extra = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot "LibBugsy-1.0") -Filter *.lua -File -ErrorAction SilentlyContinue |
    ForEach-Object { "LibBugsy-1.0\" + $_.Name })
$probeToc = Join-Path $RepoRoot "Tools\BugsyProbe\BugsyProbe.toc"
if (Test-Path -LiteralPath $probeToc) {
    $extra += @(Get-Content $probeToc | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -notmatch "^#" -and $_ -match "[.]lua$" } | ForEach-Object { "Tools\BugsyProbe\$_" })
}
& (Join-Path $kit "scripts\run.ps1") -RepoRoot $RepoRoot -Toc "!Bugsy.toc" -Extra $extra -Lua $Lua
exit $LASTEXITCODE
