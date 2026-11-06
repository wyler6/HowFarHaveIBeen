# Copy the shipped addon files from this repo into the live WoW AddOns folder,
# so changes can be tested in game. The repo lives outside the WoW directory.
#
#   pwsh tools/deploy.ps1
#   pwsh tools/deploy.ps1 -WowAddOns "D:\Games\WoW\_forever_\Interface\AddOns"
#
# One-way on purpose: never edit inside the AddOns folder, because the next run
# overwrites it. SavedVariables live under WTF and are never touched by this.

param(
    [string]$WowAddOns = "F:\World of Warcraft\_forever_\Interface\AddOns"
)

$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $WowAddOns "HowFarHaveIBeen"

if (-not (Test-Path $WowAddOns)) {
    throw "AddOns folder not found: $WowAddOns`nPass the right path with -WowAddOns."
}

# The .toc is the authority on which Lua files the addon loads, so the list is
# read from it rather than repeated here. A hand-maintained copy silently went
# stale once in another addon: a file was added to the .toc but not here, so the game got a
# .toc referencing a file that was never copied, and the feature it powered did
# nothing with no error to explain why.
#
# Everything else is fixed and matches the .pkgmeta ignore list, so tests/,
# tools/, .github/ and art/ never reach the game folder.
$toc = "HowFarHaveIBeen.toc"
$luaFiles = Get-Content (Join-Path $repo $toc) |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and $_ -notmatch '^#' -and $_ -match '\.lua$' }

if (-not $luaFiles) {
    throw "No Lua files listed in $toc -- refusing to deploy an addon with no code."
}

$files = @($toc) + $luaFiles + @(
    "Media\icon.tga",
    "README.md",
    "CHANGELOG.md"
)

$missing = $files | Where-Object { -not (Test-Path (Join-Path $repo $_)) }
if ($missing) {
    throw "Missing from the repo: $($missing -join ', ')"
}

# -Force on a directory only ensures it exists; it does not clear the contents.
New-Item -ItemType Directory -Force -Path $dest | Out-Null

foreach ($file in $files) {
    $target = Join-Path $dest $file
    $parent = Split-Path -Parent $target
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    Copy-Item -Path (Join-Path $repo $file) -Destination $target -Force
}

Write-Output "Copied $($files.Count) files to $dest"
Write-Output "Now type /reload in game (full restart only needed the first time)."
