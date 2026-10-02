# VRChat Link Maker - single-file release
# ---------------------------------------
# Builds dist\VRChat-Link-Maker-vX.Y.bat: one self-extracting file to attach to a GitHub Release.
# Double-clicking it unpacks the tool into a "VRChat Link Maker" folder next to the .bat (only when that folder
# is missing or older) and starts it. From then on the tool's own auto-update keeps that folder current.
# The payload is `git archive` of the vX.Y tag, so it holds exactly what the update zip holds.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-SingleFile.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$main = [IO.File]::ReadAllText((Join-Path $root 'VRChatLinkMaker.ps1'))
if ($main -notmatch "\`$script:Version\s*=\s*'([0-9.]+)'") { throw 'No $script:Version in VRChatLinkMaker.ps1' }
$ver = $Matches[1]
$tag = 'v' + $ver

git rev-parse -q --verify "refs/tags/$tag" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Tag $tag does not exist - tag the release first." }
$head = (git rev-parse HEAD).Trim()
$tagCommit = (git rev-parse "$tag^{commit}").Trim()
if ($head -ne $tagCommit) { Write-Warning "HEAD is not $tag - building from the tag, not the working tree." }

$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
$zip = Join-Path $dist "payload-$ver.zip"
git archive --format=zip -o $zip $tag
if ($LASTEXITCODE -ne 0) { throw 'git archive failed' }
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zip)) -replace '(.{76})', "`$1`r`n"
Remove-Item $zip

# Batch part: hand the file to PowerShell, which runs the block between the PS markers, then start the tool.
# The markers are split ('#'+'<PS>') so the search can't find its own command line.
$bat = @'
@echo off
setlocal
title VRChat Link Maker
set "VLM_SELF=%~f0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:VLM_SELF); $i=$t.IndexOf('#'+'<PS>'); $j=$t.IndexOf('#'+'</PS>'); iex $t.Substring($i,$j-$i)"
if errorlevel 1 (
  echo.
  echo Could not unpack VRChat Link Maker. If there is an error message above, that is what went wrong.
  pause
  exit /b 1
)
call "%~dp0VRChat Link Maker\Make VRChat Link.bat" %*
exit /b

#<PS>
$ErrorActionPreference = 'Stop'
$ver = [version]'@@VERSION@@'
$self = $env:VLM_SELF
$dir = Join-Path (Split-Path -Parent $self) 'VRChat Link Maker'
$have = $null
$mainPs1 = Join-Path $dir 'VRChatLinkMaker.ps1'
if (Test-Path -LiteralPath $mainPs1) {
  if ([IO.File]::ReadAllText($mainPs1) -match "\`$script:Version\s*=\s*'([0-9.]+)'") {
    $s = $Matches[1]; if ($s -notmatch '\.') { $s += '.0' }
    try { $have = [version]$s } catch { }
  }
}
if ($have -and $have -ge $ver) { exit 0 }
Write-Host ('Unpacking VRChat Link Maker ' + $ver + ' into ' + $dir)
$t = [IO.File]::ReadAllText($self)
$k = $t.IndexOf('#' + '<ZIP>')
$b64 = $t.Substring($k + 6) -replace '[^A-Za-z0-9+/=]', ''
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('vlm-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
  $zip = Join-Path $tmp 'p.zip'
  [IO.File]::WriteAllBytes($zip, [Convert]::FromBase64String($b64))
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $out = Join-Path $tmp 'x'
  [IO.Compression.ZipFile]::ExtractToDirectory($zip, $out)
  New-Item -ItemType Directory -Force $dir | Out-Null
  # Only the shipped files are written; config.json, logs and the rest of the user's files stay as they are.
  Copy-Item -Path (Join-Path $out '*') -Destination $dir -Recurse -Force
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
#</PS>
'@
$bat = $bat.Replace('@@VERSION@@', $ver) -replace "`r?`n", "`r`n"
$bat += "`r`n#<ZIP>`r`n" + $b64 + "`r`n"

$outFile = Join-Path $dist "VRChat-Link-Maker-$tag.bat"
[IO.File]::WriteAllText($outFile, $bat, [Text.Encoding]::ASCII)
Write-Host ("Built {0} ({1:N0} KB)" -f $outFile, ((Get-Item $outFile).Length / 1KB))
