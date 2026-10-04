# VRChat Link Maker - updates
# ---------------------------
# Dot-sourced by VRChatLinkMaker.ps1. At start (in the main window only, before anything streams) the tool asks
# GitHub for the newest vX.Y tag of github.com/Leo-romeo/VRChat-Link-Maker. When that is newer than this copy it
# shows the release notes and asks. Yes = download that version's zip, check every script in it parses, swap in
# the files that changed (all or nothing) and start again. config.json, the logs and the rest of your own files
# are not in the zip and are never touched, so the link stays the same.
# Off: "Updates": "off" in config.json, or VRCLM_NO_UPDATE=1. A copy that is a git checkout is left to git.

$script:UpdateRepo = 'Leo-romeo/VRChat-Link-Maker'
$script:RestartAfterUpdate = $false

# Never written by an update, whatever the zip holds.
$script:UpdateKeep = @('config.json', 'state.json', 'queue.txt', 'log.txt', 'log-previous.txt')

# 'v1.2' / '1.2.3' -> [version], anything else -> $null.
function ConvertTo-UpdateVersion([string]$s) {
  if ($s -notmatch '^\s*[vV]?(\d+(?:\.\d+){0,3})\s*$') { return $null }
  $t = $Matches[1]
  if ($t -notmatch '\.') { $t += '.0' }
  try { return [version]$t } catch { return $null }
}

# The newest version on GitHub: Version, Tag, Notes (the release text, '' when the tag has no release). Throws
# when GitHub can't be reached.
function Get-LatestVersion {
  $api = 'https://api.github.com/repos/' + $script:UpdateRepo
  $h = @{ 'Accept' = 'application/vnd.github+json' }
  $r = Invoke-Web -Url ($api + '/tags?per_page=100') -Headers $h -TimeoutSec 6
  if ($r.Status -ne 200) { throw "GitHub: HTTP $($r.Status)" }
  $best = $null
  foreach ($t in @(ConvertFrom-JsonDict $r.Text)) {
    $v = ConvertTo-UpdateVersion ([string]$t['name'])
    if ($v -and (-not $best -or $v -gt $best.Version)) { $best = [pscustomobject]@{ Version = $v; Tag = [string]$t['name']; Notes = '' } }
  }
  if ($best) {
    try {
      $r = Invoke-Web -Url ($api + '/releases/tags/' + [Uri]::EscapeDataString($best.Tag)) -Headers $h -TimeoutSec 6
      if ($r.Status -eq 200) { $best.Notes = ([string](ConvertFrom-JsonDict $r.Text)['body']).Trim() }
    } catch {}
  }
  return $best
}

function Save-UpdateDownload([string]$url, [string]$path) {
  $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($url)
  $req.UserAgent = $script:WebUA
  $req.Timeout = 30000
  $req.ReadWriteTimeout = 30000
  $resp = $req.GetResponse()
  try {
    $st = $resp.GetResponseStream()
    $fs = [System.IO.File]::Create($path)
    try { $st.CopyTo($fs) } finally { $fs.Dispose(); $st.Dispose() }
  } finally { $resp.Close() }
}

# Downloads $latest and replaces the files that differ. Returns how many changed. Throws (with everything put
# back as it was) when anything goes wrong.
function Install-Update($latest) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $work = PathJoin $script:TempRoot ('update-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  [void][System.IO.Directory]::CreateDirectory($work)
  try {
    $zip = PathJoin $work 'update.zip'
    $root = PathJoin $work 'files'
    Save-UpdateDownload ('https://github.com/' + $script:UpdateRepo + '/archive/refs/tags/' + [Uri]::EscapeDataString($latest.Tag) + '.zip') $zip
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $root)
    # GitHub's zip holds one folder (<repo>-<version>) with the files in it.
    $dirs = @([System.IO.Directory]::GetDirectories($root))
    if ($dirs.Count -eq 1 -and @([System.IO.Directory]::GetFiles($root)).Count -eq 0) { $root = $dirs[0] }
    if (-not [System.IO.File]::Exists((PathJoin $root 'VRChatLinkMaker.ps1'))) { throw (T 'the download has no VRChatLinkMaker.ps1 in it') }
    $files = @([System.IO.Directory]::GetFiles($root, '*', [System.IO.SearchOption]::AllDirectories))
    # A script with errors would leave the tool unable to start: then nothing is replaced.
    foreach ($f in $files) {
      if ($f -notmatch '(?i)\.ps1$') { continue }
      $tokens = $null; $errs = $null
      [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errs)
      if ($errs -and $errs.Count -gt 0) { throw (T '{0} in the download has errors' ([System.IO.Path]::GetFileName($f))) }
    }
    # Write every changed file next to its old one first (*.update-new), then swap them all in. The old copies
    # (*.update-old) stay until the last swap worked, so a failure part-way puts every file back.
    $staged = New-Object System.Collections.ArrayList
    foreach ($f in $files) {
      $rel = $f.Substring($root.Length).TrimStart([char]'\', [char]'/')
      if ($rel.StartsWith('.') -or $script:UpdateKeep -contains $rel) { continue }
      $dst = PathJoin $script:ToolDir $rel
      $new = [System.IO.File]::ReadAllBytes($f)
      if ([System.IO.File]::Exists($dst)) {
        $old = [System.IO.File]::ReadAllBytes($dst)
        if ([Convert]::ToBase64String($old) -eq [Convert]::ToBase64String($new)) { continue }
      }
      [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($dst))
      [System.IO.File]::WriteAllBytes($dst + '.update-new', $new)
      [void]$staged.Add([pscustomobject]@{ Dst = $dst; Had = [System.IO.File]::Exists($dst); Swapped = $false })
    }
    try {
      foreach ($s in $staged) {
        if ($s.Had) { [System.IO.File]::Replace($s.Dst + '.update-new', $s.Dst, $s.Dst + '.update-old') }
        else { [System.IO.File]::Move($s.Dst + '.update-new', $s.Dst) }
        $s.Swapped = $true
      }
    } catch {
      foreach ($s in $staged) {
        try {
          if ($s.Swapped -and $s.Had) { [System.IO.File]::Copy($s.Dst + '.update-old', $s.Dst, $true) }
          elseif ($s.Swapped) { [System.IO.File]::Delete($s.Dst) }
        } catch {}
      }
      throw
    } finally {
      foreach ($s in $staged) {
        try { [System.IO.File]::Delete($s.Dst + '.update-new') } catch {}
        try { [System.IO.File]::Delete($s.Dst + '.update-old') } catch {}
      }
    }
    return $staged.Count
  } finally {
    try { [System.IO.Directory]::Delete($work, $true) } catch {}
  }
}

# Called by Main once config.json is read. $true = updated: Main returns and the tool starts again.
function Invoke-UpdateCheck {
  if (-not $script:Interactive -or $env:VRCLM_NO_UPDATE) { return $false }
  if ("$(Get-Prop $script:Cfg 'Updates')" -match '^(?i)\s*(off|no|false|0)\s*$') { return $false }
  if ([System.IO.Directory]::Exists((PathJoin $script:ToolDir '.git'))) { return $false }
  $cur = ConvertTo-UpdateVersion $script:Version
  $latest = $null
  try { $latest = Get-LatestVersion }
  catch { Say (T 'Couldn''t check for a new version: {0}' $_.Exception.Message) 'DarkGray'; return $false }
  if (-not $latest -or -not $cur -or $latest.Version -le $cur) { return $false }
  if ("$(Get-Prop $script:Cfg 'SkipVersion')" -eq $latest.Tag) { return $false }
  Say ''
  Say (T 'A new version is out: {0} (this one is {1}).' $latest.Version.ToString() $script:Version) 'Green'
  if ($latest.Notes) {
    $lines = @($latest.Notes -split "`r?`n")
    foreach ($l in ($lines | Select-Object -First 20)) { Say ('  ' + $l) 'Gray' }
    if ($lines.Count -gt 20) { Say ('  ... https://github.com/' + $script:UpdateRepo + '/releases') 'Gray' }
  }
  $c = Read-Choice (T 'Update now? Your settings and your link stay as they are.') @((T 'Yes, update and restart'), (T 'Not now'), (T 'Skip this version')) 0 $false -Esc 1
  if ($c -eq 2) {
    if ($script:Cfg.PSObject.Properties['SkipVersion']) { $script:Cfg.SkipVersion = $latest.Tag }
    else { $script:Cfg | Add-Member -NotePropertyName 'SkipVersion' -NotePropertyValue $latest.Tag }
    try { Save-Config $script:Cfg } catch {}
    Say (T 'OK, you won''t be asked about {0} again.' $latest.Tag) 'Gray'
    return $false
  }
  if ($c -ne 0) { return $false }
  Say (T 'Downloading {0}...' $latest.Tag) 'Gray'
  try { [void](Install-Update $latest) }
  catch {
    Say (T 'The update didn''t work, so nothing was changed: {0}' $_.Exception.Message) 'Red'
    return $false
  }
  Say (T 'Updated to {0}. Starting it...' $latest.Version.ToString()) 'Green'
  $script:RestartAfterUpdate = $true
  return $true
}

# After Main returned and everything was closed (the single-instance lock is free again): start the updated tool
# in a new window with the same arguments. $true = started, this window can close.
function Restart-AfterUpdate {
  try {
    $argv = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $script:ScriptFile) + @($script:Args0 | ForEach-Object { "$_" })
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = Join-CmdArgs $argv
    $psi.UseShellExecute = $true
    if (Get-Command Write-StartLog -CommandType Function -ErrorAction SilentlyContinue) { Write-StartLog $psi }
    [void][System.Diagnostics.Process]::Start($psi)
    return $true
  } catch {
    Say (T 'Couldn''t start the new version ({0}). Start the tool again.' $_.Exception.Message) 'Yellow'
    return $false
  }
}
