# VRChat Link Maker - streaming hosts
# ----------------------------------
# Loaded by VRChatLinkMaker.ps1. Where the stream goes: Topaz Chat (default), MediaMTX on this PC, MediaMTX on the
# user's own VPS, or custom links. Host profiles and config (part 1), MediaMTX: binary, locked-down config, security
# test, VPS setup files (part 2), network checks: public address / CGNAT, IPv6, UPnP, firewall, DuckDNS, Tailscale
# Funnel, upload speed test (part 3).

# ================================================================== streaming hosts (part 1: profiles, config, links, host menu)
# Where the stream goes ("host"), chosen in the host menu (Select-Host) and kept in config.json as "Host":
#   topaz  - Topaz Chat (the default): free, trusted by VRChat, plays in every instance (Public too). About 1.4 Mbps.
#   pc     - MediaMTX on this PC. Viewers connect to this PC (they see its internet address). Not for Public instances.
#   vps    - MediaMTX on the user's own server on the internet; this PC sends the stream there (SRT with a passphrase).
#            One server carries several streams at once (one per PC, each with its own link); other PCs get theirs as a
#            connection code (see "my VPS: streams and connection codes").
#   custom - links typed in by hand (IngestUrl / PcUrl / QuestUrl / VlcUrl in config.json), e.g. Twitch.
# Get-HostProfile turns the config into one object with every link and limit of the active host (see HOSTS.md).
# The pc / vps links carry a secret token (New-LinkToken); "new link" (Reset-StreamLink) replaces it.

$script:HostIds = @('topaz', 'pc', 'vps', 'custom')
$script:TopazRe = '^(?i)[a-z][a-z0-9+.-]*://(?:[^/@]*@)?(?:[^/:?#@]+\.)?topaz\.chat(?:[:/?#]|$)'
# Domains on VRChat's video allowlist (https://creators.vrchat.com/worlds/udon/video-players/www-whitelist/) that a
# custom host may use. "x" also stands for "*.x". Unknown hosts count as untrusted (the safe mistake).
$script:HostAllowlist = @('topaz.chat', 'twitch.tv', 'ttvnw.net', 'twitchcdn.net', 'jtvnw.net', 'youtube.com', 'youtu.be', 'googlevideo.com')
$script:HostSecretRe = '^[A-Za-z0-9._~-]+$'   # passwords / passphrases: nothing that breaks a link or SRT's streamid (":")
$script:VpsSafeRe = '^[A-Za-z0-9_-]+$'          # what the server's config takes (Assert-MtxSecret): the further streams' secrets
$script:VpsCodePrefix = 'vrclm-vps1:'
$script:VpsMaxStreams = 10                      # streams on one VPS in all, this PC's own one included
# Cyrillic letters for Test-AnswerYes (these files stay plain ASCII): "d" of "da" (yes), and "n" (what the Y key types
# on a Russian keyboard layout).
$script:HostYesDa = '[' + [char]0x0434 + [char]0x0414 + ']'
$script:HostYesN = '[' + [char]0x043D + [char]0x041D + ']'

function Test-HostFn([string]$name) { return [bool](Get-Command $name -CommandType Function -ErrorAction SilentlyContinue) }

# Console navigation (the main script's flows): the host menu's questions run as one flow, so Esc goes back. Before a
# step that can't be undone (config saved, a code imported, setup files written, DuckDNS told) Lock-HostStep makes sure
# no Back crosses it; a flow re-running its earlier answers (Test-HostReplaying) skips the slow server checks.
function Lock-HostStep { if (Test-HostFn 'Lock-NavStep') { Lock-NavStep } }
function Test-HostReplaying { return ((Test-HostFn 'Test-NavReplaying') -and (Test-NavReplaying)) }

# A short wait that keeps the control window answering (the main script's Wait-Pump), else a plain sleep.
function Wait-HostPump([int]$ms) {
  if (Test-HostFn 'Wait-Pump') { Wait-Pump ($ms / 1000.0) } else { Start-Sleep -Milliseconds $ms }
}

# A link token: 16 random bytes (128 bits) as base64url without padding (22 characters of A-Z a-z 0-9 - _).
function New-LinkToken {
  $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
  try {
    $bytes = New-Object byte[] 16
    do {
      $rng.GetBytes($bytes)
      $t = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    } while ($t.StartsWith('~'))   # (base64url never has "~"; MediaMTX would read a path starting with it as a regex)
    return $t
  } finally { $rng.Dispose() }
}

# A random password of letters and digits (no bias: bytes 248-255 are thrown away).
function New-HostSecret([int]$len) {
  $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
  $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
  try {
    $sb = New-Object System.Text.StringBuilder
    $b = New-Object byte[] 1
    while ($sb.Length -lt $len) {
      $rng.GetBytes($b)
      if ($b[0] -lt 248) { [void]$sb.Append($alphabet[$b[0] % 62]) }
    }
    return $sb.ToString()
  } finally { $rng.Dispose() }
}

function Test-LinkToken($t) { return ($t -is [string] -and $t -match '^[A-Za-z0-9_-]{22,64}$' -and -not $t.StartsWith('~')) }

function ConvertTo-HostInt($v, [int]$default, [int]$min, [int]$max) {
  $n = 0
  if ($null -eq $v -or -not [int]::TryParse("$v".Trim(), [ref]$n)) { return $default }
  if ($n -lt $min -or $n -gt $max) { return $default }
  return $n
}

function ConvertTo-HostBool($v, [bool]$default) {
  if ($null -eq $v) { return $default }
  if ($v -is [bool]) { return $v }
  if ("$v" -match '^(?i)\s*(true|yes|on|1)\s*$') { return $true }
  if ("$v" -match '^(?i)\s*(false|no|off|0)\s*$') { return $false }
  return $default
}

# Sets $obj.$name = $value; $chg becomes $true when that is a change (a missing field, another value or another type).
function Set-HostField($obj, [string]$name, $value, [ref]$chg) {
  $p = $obj.PSObject.Properties[$name]
  if (-not $p) { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value; $chg.Value = $true; return }
  $old = $p.Value
  if ($null -eq $old -and $null -eq $value) { return }
  if ($null -ne $old -and $null -ne $value -and $old.GetType() -eq $value.GetType() -and "$old" -ceq "$value") { return }
  $p.Value = $value
  $chg.Value = $true
}

# "https://Name.DuckDNS.org:443/x" -> "name.duckdns.org"; "[2001:db8::1]" -> "2001:db8::1". "" when it isn't a host name / IP.
function ConvertTo-HostAddress([string]$s) {
  $s = "$s".Trim()
  if (-not $s) { return '' }
  $s = $s -replace '^(?i)[a-z][a-z0-9+.-]*://', ''
  $s = $s -replace '^[^@/]*@', ''
  $s = ($s -split '[/?#]')[0]
  $ip = $null
  if ($s -match '^\[([0-9A-Fa-f:.]+)\](?::\d+)?$') { $s = $matches[1] }
  elseif ($s -match '^([^:]+):\d+$') { $s = $matches[1] }
  if ([System.Net.IPAddress]::TryParse($s, [ref]$ip)) {
    # (TryParse also takes "12345" or "1.2.3" as IPv4 shorthand, and IPv6 zone ids like "%12": none of them work in a link.)
    if ($s -notmatch ':' -and $s -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return '' }
    if ($s -notmatch ':' -and $s -match '(^|\.)0\d') { return '' }   # (.NET reads "010" as octal: 8)
    if ($s.Contains('%')) { return '' }
    return $ip.ToString()
  }
  $s = $s.TrimEnd('.').ToLowerInvariant()
  if ($s.Length -le 253 -and $s -match '^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$') { return $s }
  return ''
}

# An IPv6 address goes in [brackets] inside a link.
function Format-HostForUrl([string]$h) {
  if ($h -match ':') { return "[$h]" }
  return $h
}

function Get-UrlHost([string]$url) {
  $m = [regex]::Match($url, '^(?i)[a-z][a-z0-9+.-]*://(?:[^/@?#]*@)?(\[[^\]]+\]|[^:/?#]+)')
  if (-not $m.Success) { return '' }
  return $m.Groups[1].Value.Trim('[', ']').ToLowerInvariant()
}

# The unique part of a stream link: its last path segment (the one before a file name like index.m3u8).
function Get-UrlKey([string]$url) {
  $path = [regex]::Replace($url, '^(?i)[a-z][a-z0-9+.-]*://[^/]*', '')
  $path = ($path -split '[?#]')[0]
  $segs = @($path.Split('/') | Where-Object { $_ })
  if ($segs.Count -eq 0) { return '' }
  $last = $segs[$segs.Count - 1]
  if ($segs.Count -ge 2 -and $last -match '^(?i)[^.]+\.(m3u8|mpd|ts|mp4|flv|m4s)$') { return $segs[$segs.Count - 2] }
  return $last
}

function Test-HostAllowlisted([string]$h) {
  $h = "$h".ToLowerInvariant().TrimEnd('.')
  if (-not $h) { return $false }
  foreach ($d in $script:HostAllowlist) { if ($h -eq $d -or $h.EndsWith('.' + $d)) { return $true } }
  return $false
}

function Get-TopazLinks([string]$key) {
  return [ordered]@{
    IngestUrl = "rtmp://topaz.chat/live/$key"; PcUrl = "rtspt://topaz.chat/live/$key"
    QuestUrl  = "rtmp://topaz.chat/live/$key"; VlcUrl = "rtsp://topaz.chat/live/$key"
  }
}

# The English names written to config.json's "Server" (the display name comes from Get-HostProfile).
function Get-HostServerName([string]$id) {
  switch ($id) {
    'topaz' { return 'Topaz Chat (free, trusted by VRChat)' }
    'pc' { return 'This PC (self-host)' }
    'vps' { return 'My VPS (self-host)' }
    default { return 'Custom' }
  }
}

function Get-HostDisplayName([string]$id) {
  switch ($id) {
    'topaz' { return (T 'Topaz Chat') }
    'pc' { return (T 'This PC') }
    'vps' { return (T 'My VPS') }
    default { return (T 'Custom server') }
  }
}

# Writes the Topaz links of $key into the config's IngestUrl / PcUrl / QuestUrl / VlcUrl (what older code reads).
function Set-TopazConfigLinks($c, [string]$key, [ref]$chg) {
  $l = Get-TopazLinks $key
  foreach ($k in $l.Keys) { Set-HostField $c $k $l[$k] $chg }
}

# Keeps "Server" (older code shows it) in step with the host, unless the user wrote their own name there.
function Sync-HostServerName($c, [string]$id, [ref]$chg) {
  $srv = "$(Get-Prop $c 'Server')"
  $known = @($script:HostIds | ForEach-Object { Get-HostServerName $_ })
  if ((-not $srv -or $srv -in $known) -and $srv -ne (Get-HostServerName $id)) { Set-HostField $c 'Server' (Get-HostServerName $id) $chg }
}

# Migration + defaults + secrets. Returns $true when $script:Cfg changed (the caller saves it with Save-Config).
#  - "Host" missing: an IngestUrl on topaz.chat (or none at all) means topaz, anything else custom.
#  - "StreamKey" missing: taken once from the Topaz PcUrl (so the link people already have keeps working), else new.
#  - "SelfHost" / "Vps": missing fields get their defaults, missing / broken tokens and passwords are made.
#  - The old default of 1700 kbps (too much for Topaz) becomes 1350 - on Topaz only.
function Initialize-HostConfig {
  $chg = $false
  if ($null -eq $script:Cfg) { $script:Cfg = New-Object psobject; $chg = $true }
  $c = $script:Cfg

  $ing = "$(Get-Prop $c 'IngestUrl')".Trim()
  $pc = "$(Get-Prop $c 'PcUrl')".Trim()
  $id = "$(Get-Prop $c 'Host')".Trim().ToLowerInvariant()
  if ($id -notin $script:HostIds) {
    if (-not $ing -or $ing -match $script:TopazRe) { $id = 'topaz' } else { $id = 'custom' }
  }
  if ($id -eq 'custom' -and (-not $ing -or -not $pc)) {
    Say (T 'config.json says "Host": "custom" but has no IngestUrl / PcUrl - using Topaz Chat.') 'Yellow'
    $id = 'topaz'
  }
  Set-HostField $c 'Host' $id ([ref]$chg)

  $key = "$(Get-Prop $c 'StreamKey')".Trim()
  if ($key -notmatch '^[A-Za-z0-9_-]{4,64}$') {
    $key = ''
    foreach ($u in @($pc, $ing)) {
      if (-not $key -and $u -match $script:TopazRe) {
        $k = Get-UrlKey $u
        if ($k -match '^[A-Za-z0-9_-]{4,64}$') { $key = $k }
      }
    }
    if (-not $key) { $key = New-StreamKey }
  }
  Set-HostField $c 'StreamKey' $key ([ref]$chg)
  if ($id -eq 'topaz') { Set-TopazConfigLinks $c $key ([ref]$chg) }
  foreach ($k in @('QuestUrl', 'VlcUrl')) { if (-not $c.PSObject.Properties[$k]) { Set-HostField $c $k '' ([ref]$chg) } }
  Sync-HostServerName $c $id ([ref]$chg)

  if ($id -eq 'topaz') {
    $vk = ConvertTo-HostInt (Get-Prop $c 'VideoKbps') 0 0 1000000
    $ak = ConvertTo-HostInt (Get-Prop $c 'AudioKbps') 128 0 1000000
    if ($vk -eq 1700 -and $ak -eq 128) {
      # 1700 was the old default, but Topaz Chat only takes in about 1.6 Mbps in all, so that stuttered.
      Set-HostField $c 'VideoKbps' 1350 ([ref]$chg)
      Say (T 'Using 1350 kbps video (Topaz Chat only takes about 1.6 Mbps in total; the old 1700 made it stutter).') 'DarkGray'
    }
  }

  # ---- this PC
  $s = Get-Prop $c 'SelfHost'
  if ($s -isnot [System.Management.Automation.PSCustomObject]) {
    $s = New-Object psobject
    Set-HostField $c 'SelfHost' $s ([ref]$chg)
  }
  if (-not (Test-LinkToken (Get-Prop $s 'Token'))) { Set-HostField $s 'Token' (New-LinkToken) ([ref]$chg) }
  Set-HostField $s 'HostName' (ConvertTo-HostAddress (Get-Prop $s 'HostName')) ([ref]$chg)
  Set-HostField $s 'DuckDnsToken' "$(Get-Prop $s 'DuckDnsToken')".Trim() ([ref]$chg)
  $ports = @((ConvertTo-HostInt (Get-Prop $s 'RtspPort') 8554 1 65535), (ConvertTo-HostInt (Get-Prop $s 'RtmpPort') 1935 1 65535),
    (ConvertTo-HostInt (Get-Prop $s 'HlsPort') 8888 1 65535))
  if (@($ports | Select-Object -Unique).Count -ne 3) { $ports = @(8554, 1935, 8888) }
  Set-HostField $s 'RtspPort' $ports[0] ([ref]$chg)
  Set-HostField $s 'RtmpPort' $ports[1] ([ref]$chg)
  Set-HostField $s 'HlsPort' $ports[2] ([ref]$chg)
  Set-HostField $s 'Hls' (ConvertTo-HostBool (Get-Prop $s 'Hls') $false) ([ref]$chg)
  Set-HostField $s 'MaxReaders' (ConvertTo-HostInt (Get-Prop $s 'MaxReaders') 10 1 1000) ([ref]$chg)
  $up = Get-Prop $s 'Upnp'   # null = ask once
  if ($null -ne $up -and $up -isnot [bool]) {
    if ("$up" -match '^(?i)\s*(true|yes|on|1)\s*$') { $up = $true }
    elseif ("$up" -match '^(?i)\s*(false|no|off|0)\s*$') { $up = $false }
    else { $up = $null }
  }
  Set-HostField $s 'Upnp' $up ([ref]$chg)
  Set-HostField $s 'Firewall' (ConvertTo-HostBool (Get-Prop $s 'Firewall') $true) ([ref]$chg)
  Set-HostField $s 'Ipv6' (ConvertTo-HostBool (Get-Prop $s 'Ipv6') $true) ([ref]$chg)
  Set-HostField $s 'VideoKbps' (ConvertTo-HostInt (Get-Prop $s 'VideoKbps') 3000 200 100000) ([ref]$chg)

  # ---- my VPS
  $v = Get-Prop $c 'Vps'
  if ($v -isnot [System.Management.Automation.PSCustomObject]) {
    $v = New-Object psobject
    Set-HostField $c 'Vps' $v ([ref]$chg)
  }
  Set-HostField $v 'Address' (ConvertTo-HostAddress (Get-Prop $v 'Address')) ([ref]$chg)
  # (A secret that was there but isn't valid is replaced too - and then the server no longer matches: say so.)
  $remade = New-Object System.Collections.ArrayList
  $t = "$(Get-Prop $v 'Token')"
  if (-not (Test-LinkToken $t)) {
    if ($t) { [void]$remade.Add('Token') }
    Set-HostField $v 'Token' (New-LinkToken) ([ref]$chg)
  }
  $u = "$(Get-Prop $v 'PublishUser')".Trim()
  if ($u -notmatch '^[A-Za-z0-9._-]{1,32}$' -or $u -ieq 'any') {   # ("any" = MediaMTX's everybody)
    if ($u) { [void]$remade.Add('PublishUser') }
    $u = 'vrclm'
  }
  Set-HostField $v 'PublishUser' $u ([ref]$chg)
  $pw = "$(Get-Prop $v 'PublishPass')"
  if (-not (Test-VpsSecret $pw 12 64 $script:HostSecretRe)) {
    if ($pw) { [void]$remade.Add('PublishPass') }
    $pw = New-HostSecret 24
  }
  Set-HostField $v 'PublishPass' $pw ([ref]$chg)
  foreach ($k in @('SrtPassphrase', 'ReadPassphrase')) {
    $pp = "$(Get-Prop $v $k)"
    if (-not (Test-VpsSecret $pp 16 79 $script:HostSecretRe)) {   # (SRT takes 10-79)
      if ($pp) { [void]$remade.Add($k) }
      $pp = New-HostSecret 32
    }
    Set-HostField $v $k $pp ([ref]$chg)
  }
  if ("$($v.SrtPassphrase)" -ceq "$($v.ReadPassphrase)") { Set-HostField $v 'ReadPassphrase' (New-HostSecret 32) ([ref]$chg) }
  if ($remade.Count -gt 0 -and "$(Get-Prop $v 'Address')") {
    if ("$(Get-Prop $v 'Role')" -eq 'guest') { Say (T 'config.json: Vps {0} wasn''t valid, so a new one was made. The VPS doesn''t know it: ask whoever manages the server for the connection code and paste it again (H -> My VPS).' ($remade -join ', ')) 'Yellow' }
    else { Say (T 'config.json: Vps {0} wasn''t valid, so a new one was made. Your VPS doesn''t know it: paste install.sh on the server again, or the connection code again.' ($remade -join ', ')) 'Yellow' }
  }
  $ports = @((ConvertTo-HostInt (Get-Prop $v 'SrtPort') 8890 1 65535), (ConvertTo-HostInt (Get-Prop $v 'RtspPort') 8554 1 65535),
    (ConvertTo-HostInt (Get-Prop $v 'RtmpPort') 1935 1 65535), (ConvertTo-HostInt (Get-Prop $v 'HlsPort') 8888 1 65535))
  if (@($ports[1..3] | Select-Object -Unique).Count -ne 3) { $ports = @($ports[0], 8554, 1935, 8888) }   # (SRT is UDP: it may share a number)
  Set-HostField $v 'SrtPort' $ports[0] ([ref]$chg)
  Set-HostField $v 'RtspPort' $ports[1] ([ref]$chg)
  Set-HostField $v 'RtmpPort' $ports[2] ([ref]$chg)
  Set-HostField $v 'HlsPort' $ports[3] ([ref]$chg)
  $push = "$(Get-Prop $v 'Push')".Trim().ToLowerInvariant()
  if ($push -notin @('srt', 'rtmp')) { $push = 'srt' }
  Set-HostField $v 'Push' $push ([ref]$chg)
  Set-HostField $v 'Hls' (ConvertTo-HostBool (Get-Prop $v 'Hls') $false) ([ref]$chg)
  Set-HostField $v 'MaxReaders' (ConvertTo-HostInt (Get-Prop $v 'MaxReaders') 30 1 1000) ([ref]$chg)
  Set-HostField $v 'VideoKbps' (ConvertTo-HostInt (Get-Prop $v 'VideoKbps') 4000 200 100000) ([ref]$chg)
  # owner = this PC set the server up (it writes install.sh); guest = it streams with a connection code from that PC.
  $role = "$(Get-Prop $v 'Role')".Trim().ToLowerInvariant()
  if ($role -notin @('owner', 'guest')) { $role = 'owner' }
  Set-HostField $v 'Role' $role ([ref]$chg)
  Set-HostField $v 'Name' (ConvertTo-VpsStreamName (Get-Prop $v 'Name')) ([ref]$chg)
  # The further streams on the server, for other PCs (only the PC that manages the server keeps them).
  $old = @(@(Get-Prop $v 'Streams') | Where-Object { $null -ne $_ })
  $keep = New-Object System.Collections.ArrayList
  if ($role -eq 'owner') {
    $seenTok = New-VpsSeenSet; [void]$seenTok.Add("$($v.Token)")
    $seenUser = New-VpsSeenSet; [void]$seenUser.Add("$($v.PublishUser)".ToLowerInvariant())
    foreach ($e in $old) {
      if ($e -isnot [System.Management.Automation.PSCustomObject] -or $keep.Count + 1 -ge $script:VpsMaxStreams) { continue }
      Repair-VpsStream $e (T 'Stream {0}' ($keep.Count + 2)) $seenTok $seenUser "$($v.ReadPassphrase)" ([ref]$chg)
      [void]$keep.Add($e)
    }
  }
  $sp = $v.PSObject.Properties['Streams']
  if (-not $sp -or $sp.Value -isnot [array] -or $keep.Count -ne $old.Count) { Set-VpsStreamList $v $keep.ToArray() ([ref]$chg) }
  return [bool]$chg
}

# Everything about the active host (or the one named by $id) in one object: links, limits, trust, warnings.
# (For vps, IngestUrl holds the VPS publish password and SRT passphrase: never print or log it.)
function Get-HostProfile([string]$id = '') {
  $c = $script:Cfg
  if (-not $id) { $id = "$(Get-Prop $c 'Host')".Trim().ToLowerInvariant() }
  if ($id -notin $script:HostIds) { $id = 'topaz' }
  $p = [ordered]@{
    Id = $id; Name = (Get-HostDisplayName $id); Trusted = $false; PublicOk = $false; Key = ''
    IngestUrl = ''; IngestFormat = 'flv'; PcUrl = ''; QuestUrl = ''; QuestAltUrl = ''; VlcUrl = ''
    Ipv6PcUrl = ''; Ipv6QuestUrl = ''; HlsUrl = ''
    VideoKbps = 0; DefaultKbps = 0; MaxKbps = 0; MinKbps = 0; UsesMediaMtx = $false; Warnings = @()
  }
  $warn = New-Object System.Collections.ArrayList
  switch ($id) {
    'topaz' {
      $key = "$(Get-Prop $c 'StreamKey')".Trim()
      if (-not $key) { $key = Get-UrlKey "$(Get-Prop $c 'PcUrl')" }
      $l = Get-TopazLinks $key
      $p.Trusted = $true; $p.PublicOk = $true; $p.Key = $key
      $p.IngestUrl = $l.IngestUrl; $p.PcUrl = $l.PcUrl; $p.QuestUrl = $l.QuestUrl; $p.VlcUrl = $l.VlcUrl
      $p.QuestAltUrl = "rtsp://topaz.chat/live/$key"
      $p.DefaultKbps = 1350; $p.MaxKbps = 1400; $p.MinKbps = 700
      $p.VideoKbps = ConvertTo-HostInt (Get-Prop $c 'VideoKbps') 1350 200 100000
    }
    'pc' {
      $s = Get-Prop $c 'SelfHost'
      $tok = "$(Get-Prop $s 'Token')"
      $rtsp = ConvertTo-HostInt (Get-Prop $s 'RtspPort') 8554 1 65535
      $rtmp = ConvertTo-HostInt (Get-Prop $s 'RtmpPort') 1935 1 65535
      $hlsPort = ConvertTo-HostInt (Get-Prop $s 'HlsPort') 8888 1 65535
      $name = $null
      if (Test-HostFn 'Get-SelfHostName') { try { $name = Get-SelfHostName $s } catch { $name = $null } }
      $name = ConvertTo-HostAddress "$name"
      if (-not $name) {
        $name = '127.0.0.1'
        [void]$warn.Add((T 'Couldn''t find this PC''s internet address, so for now these links only work on this PC.'))
      }
      $h = Format-HostForUrl $name
      $p.Key = $tok; $p.UsesMediaMtx = $true
      $p.Trusted = Test-HostAllowlisted $name; $p.PublicOk = $p.Trusted
      # (With this run's publish password: only the relay may send, see New-MediaMtxConfig.)
      $p.IngestUrl = "rtmp://127.0.0.1:$rtmp/live/$tok" + '?user=vrclm&pass=' + (Get-PcPublishPass $s)
      $p.PcUrl = "rtspt://${h}:$rtsp/live/$tok"
      $p.QuestUrl = "rtmp://${h}:$rtmp/live/$tok"
      $p.QuestAltUrl = "rtsp://${h}:$rtsp/live/$tok"
      $p.VlcUrl = "rtsp://127.0.0.1:$rtsp/live/$tok"
      if (ConvertTo-HostBool (Get-Prop $s 'Ipv6') $true) {
        $v6 = $null; $n6 = $null
        if (Test-HostFn 'Get-GlobalIPv6') { try { $v6 = Get-GlobalIPv6 } catch { $v6 = $null } }
        if ($v6 -and (Test-HostFn 'Get-SelfHostName6')) { try { $n6 = ConvertTo-HostAddress "$(Get-SelfHostName6)" } catch { $n6 = $null } }
        if ($n6) {
          $h6 = Format-HostForUrl $n6
          $p.Ipv6PcUrl = "rtspt://${h6}:$rtsp/live/$tok"
          $p.Ipv6QuestUrl = "rtmp://${h6}:$rtmp/live/$tok"
        }
      }
      if (ConvertTo-HostBool (Get-Prop $s 'Hls') $false) { $p.HlsUrl = "http://127.0.0.1:$hlsPort/live/$tok/index.m3u8" }
      $p.DefaultKbps = 3000; $p.MaxKbps = 12000; $p.MinKbps = 1000
      $p.VideoKbps = ConvertTo-HostInt (Get-Prop $s 'VideoKbps') 3000 200 100000
      $k = [Math]::Max($p.MinKbps, [Math]::Min($p.MaxKbps, $p.VideoKbps)) + (ConvertTo-HostInt (Get-Prop $c 'AudioKbps') 128 0 1000)
      [void]$warn.Add((T 'Everyone who watches can see your home internet address (IP).'))
      [void]$warn.Add((T 'Each viewer uses about {0} Mbps of your upload: 5 viewers need about {1} Mbps. Viewers far away may stutter.' (Format-Num ([Math]::Round($k / 1000.0, 1))) (Format-Num ([Math]::Round($k * 5 / 1000.0, 1)))))
      [void]$warn.Add((T 'Viewers connect to this PC on TCP ports {0} and {1}: your router must let them in (forward them to this PC).' $rtsp $rtmp))
      if (-not "$(Get-Prop $s 'HostName')") {
        [void]$warn.Add((T 'The link contains your current internet address, so it changes when that changes (e.g. after a router restart). A free DuckDNS name keeps it the same: choose "This PC" in the host menu.'))
      }
    }
    'vps' {
      $v = Get-Prop $c 'Vps'
      $tok = "$(Get-Prop $v 'Token')"
      $addr = ConvertTo-HostAddress "$(Get-Prop $v 'Address')"
      $srtPort = ConvertTo-HostInt (Get-Prop $v 'SrtPort') 8890 1 65535
      $rtsp = ConvertTo-HostInt (Get-Prop $v 'RtspPort') 8554 1 65535
      $rtmp = ConvertTo-HostInt (Get-Prop $v 'RtmpPort') 1935 1 65535
      $hlsPort = ConvertTo-HostInt (Get-Prop $v 'HlsPort') 8888 1 65535
      $user = "$(Get-Prop $v 'PublishUser')"
      $pass = "$(Get-Prop $v 'PublishPass')"
      if (-not $addr) {
        $addr = 'VPS-ADDRESS'
        [void]$warn.Add((T 'The VPS address isn''t set yet: choose "My VPS" in the host menu and type it in.'))
      }
      $h = Format-HostForUrl $addr
      $p.Key = $tok
      $p.Trusted = Test-HostAllowlisted $addr; $p.PublicOk = $p.Trusted
      $useSrt = ("$(Get-Prop $v 'Push')" -ne 'rtmp')
      if ($useSrt) {
        $srtOk = $false
        if (Test-HostFn 'Test-FfmpegHasSrt') { try { $srtOk = [bool](Test-FfmpegHasSrt) } catch { $srtOk = $false } }
        if (-not $srtOk) {
          $useSrt = $false
          [void]$warn.Add((T 'This PC''s ffmpeg can''t send SRT, so the stream goes to the VPS over RTMP (its password isn''t encrypted on the way).'))
        }
      }
      if ($useSrt) {
        # latency (microseconds): SRT's 120 ms default leaves no time to resend a lost packet on a ~100 ms path.
        $p.IngestUrl = "srt://${h}:$srtPort" + "?streamid=publish:live/${tok}:${user}:${pass}&pkt_size=1316&passphrase=$(Get-Prop $v 'SrtPassphrase')&pbkeylen=32&latency=400000"
        $p.IngestFormat = 'mpegts'
      } else {
        $p.IngestUrl = "rtmp://${h}:$rtmp/live/$tok" + '?user=' + [Uri]::EscapeDataString($user) + '&pass=' + [Uri]::EscapeDataString($pass)
      }
      $p.PcUrl = "rtspt://${h}:$rtsp/live/$tok"
      $p.QuestUrl = "rtmp://${h}:$rtmp/live/$tok"
      $p.QuestAltUrl = "rtsp://${h}:$rtsp/live/$tok"
      $p.VlcUrl = "rtsp://${h}:$rtsp/live/$tok"
      if (ConvertTo-HostBool (Get-Prop $v 'Hls') $false) {
        $p.HlsUrl = "http://${h}:$hlsPort/live/$tok/index.m3u8"
        [void]$warn.Add((T 'The HLS link is plain http, so it plays on PC only (Quest needs https).'))
      }
      $p.DefaultKbps = 4000; $p.MaxKbps = 12000; $p.MinKbps = 1000
      $p.VideoKbps = ConvertTo-HostInt (Get-Prop $v 'VideoKbps') 4000 200 100000
    }
    default {
      $ing = "$(Get-Prop $c 'IngestUrl')".Trim()
      $pcU = "$(Get-Prop $c 'PcUrl')".Trim()
      $p.IngestUrl = $ing; $p.PcUrl = $pcU
      $p.QuestUrl = "$(Get-Prop $c 'QuestUrl')".Trim(); $p.VlcUrl = "$(Get-Prop $c 'VlcUrl')".Trim()
      if ($ing -match '^(?i)srt://') { $p.IngestFormat = 'mpegts' }
      $p.Key = Get-UrlKey $pcU
      if ($pcU -match '^(?i)https?://.*\.m3u8') { $p.HlsUrl = $pcU }
      $vh = Get-UrlHost $pcU
      $p.Trusted = Test-HostAllowlisted $vh
      if ($p.Trusted -and $p.QuestUrl) { $p.Trusted = Test-HostAllowlisted (Get-UrlHost $p.QuestUrl) }
      $p.PublicOk = $p.Trusted
      if ($vh -match '(?:^|\.)(?:twitch\.tv|ttvnw\.net|twitchcdn\.net|jtvnw\.net|youtube\.com|youtu\.be|googlevideo\.com)$') {
        [void]$warn.Add((T 'This stream is public on that site: anime and films may get taken down (DMCA).'))
      }
      $p.DefaultKbps = 3000; $p.MaxKbps = 8000; $p.MinKbps = 700
      $p.VideoKbps = ConvertTo-HostInt (Get-Prop $c 'VideoKbps') 3000 200 100000
    }
  }
  $p.Warnings = [string[]]@($warn)
  return [pscustomobject]$p
}

# The video bitrate to encode at on that host: its setting, kept between the host's floor and cap.
function Get-HostKbps($p) {
  $k = [int]$p.VideoKbps
  if ($k -le 0) { $k = [int]$p.DefaultKbps }
  if ($p.MaxKbps -gt 0 -and $k -gt $p.MaxKbps) { $k = [int]$p.MaxKbps }
  if ($k -lt $p.MinKbps) { $k = [int]$p.MinKbps }
  return [int]$k
}

# The link block: where it streams, whether VRChat trusts it, the PC link, Quest links, the IPv6 fallback, the
# VLC test link and the host's warnings. $pcLink = the PC link as the world's player gets it (with ?retry=-1 etc.);
# empty = $script:ShownLink (when it belongs to this host) or the profile's PcUrl. The caller draws the frame
# around it, adds the Stream / Live mode and world-player control hints and copies the link.
function Show-HostLinks($p, [string]$pcLink = '') {
  if (-not $pcLink) {
    $pcLink = $p.PcUrl
    $sl = "$($script:ShownLink)"
    if ($sl -and $p.PcUrl -and $sl.StartsWith($p.PcUrl, [System.StringComparison]::OrdinalIgnoreCase)) { $pcLink = $sl }
  }
  Say (T '  YOUR VRCHAT LINK  (via {0})' $p.Name) 'White'
  if ($p.Trusted) {
    Say (T '  Trusted by VRChat: plays in every instance (Public ones too), nobody has to change a setting.') 'DarkGreen'
  } else {
    Say (T '  Not on VRChat''s trusted list: everyone who watches, you included, must turn on "Allow Untrusted URLs" in VRChat''s settings.') 'Yellow'
    Say (T '  It doesn''t play in Public or Group Public instances - use a Friends, Invite or Group instance.') 'Yellow'
    Say (T '  (In a Public instance only if the world''s creator adds this address to the world''s allowed domains.)') 'DarkGray'
  }
  if ($p.Id -eq 'vps') { Say (T '  Viewers connect to your VPS, not to this PC: your home address stays hidden.') 'DarkGreen' }
  Say ''
  Say "      $pcLink" 'Green'
  Say ''
  if ($p.QuestUrl) { Say (T '  Quest / Android viewers use:  {0}' $p.QuestUrl) 'Gray' }
  if ($p.QuestAltUrl -and $p.QuestAltUrl -ne $p.QuestUrl) {
    if ($p.Id -in @('pc', 'vps')) { Say (T '    If that doesn''t play on Quest:  {0}  (takes about 10 s to start)' $p.QuestAltUrl) 'DarkGray' }
    else { Say (T '    If that doesn''t play on Quest:  {0}' $p.QuestAltUrl) 'DarkGray' }
  }
  if ($p.Ipv6PcUrl) {
    Say (T '  If a viewer can''t connect, try the IPv6 link (only works for viewers whose internet has IPv6):') 'Gray'
    Say (T '    PC:     {0}' $p.Ipv6PcUrl) 'Gray'
    if ($p.Ipv6QuestUrl) { Say (T '    Quest:  {0}' $p.Ipv6QuestUrl) 'Gray' }
  }
  if ($p.HlsUrl) {
    $shown = $false
    if ($p.Id -eq 'pc' -and (Test-HostFn 'Get-TailscaleFunnelUrl')) {
      $f = $null
      $hp = ConvertTo-HostInt (Get-Prop (Get-Prop $script:Cfg 'SelfHost') 'HlsPort') 8888 1 65535
      # (It prints the https link and the command that turns Funnel on itself, or why there is none.)
      try { $f = Get-TailscaleFunnelUrl $p.Key $hp } catch { $f = $null }
      if ($f) { $shown = $true }
    }
    if (-not $shown) {
      if ($p.Id -eq 'pc') { Say (T '  HLS (only on this PC, 10-30 s behind):  {0}' $p.HlsUrl) 'DarkGray' }
      else { Say (T '  HLS link (10-30 s behind the others):  {0}' $p.HlsUrl) 'Gray' }
    }
  }
  if ($p.VlcUrl) {
    if ($p.Id -eq 'pc') { Say (T '  To test it on this PC in VLC: {0}' $p.VlcUrl) 'Gray' }
    else { Say (T '  To test it on your PC in VLC: {0}' $p.VlcUrl) 'Gray' }
  }
  foreach ($w in @($p.Warnings)) { if ($w) { Say ('  ! ' + $w) 'Yellow' } }
}

# A yes / no question where just Enter means no (for things that can't be undone). Yes = y, or Russian "da", or the
# Y key on a Russian keyboard layout in the English window (it types the Cyrillic "n", see Test-AnswerNo).
function Test-AnswerYes([string]$ans) {
  if ($ans -match '^\s*[yY]') { return $true }
  if ($ans -match ('^\s*' + $script:HostYesDa)) { return $true }
  if ($script:Lang -eq 'en' -and $ans -match ('^\s*' + $script:HostYesN + '\s*$')) { return $true }
  return $false
}

# A line of text (trimmed). Asked through Invoke-Ask: inside a flow Esc goes back and your earlier text comes back
# pre-filled (-Secret: shown as *, never pre-filled; Right arrow = what you typed before; -Private: shown as typed, but
# never pre-filled and *** in the path line, e.g. an address, a token or a link with a stream key). -Key: the step's
# name; -Esc: what Esc gives on a one-off question.
function Read-HostLine {
  [CmdletBinding(PositionalBinding = $false)]
  param([Parameter(Position = 0)][string]$prompt, [string]$Key = '', [switch]$Secret, [switch]$Private, [object]$Esc = $null)
  if (-not (Test-HostFn 'Invoke-Ask')) {
    $a = Read-Host $prompt
    if ($null -eq $a) { return '' }
    return "$a".Trim()
  }
  $q = New-NavAsk 'text' '' $Key
  $q.Prompt = $prompt
  $q.Secret = [bool]$Secret
  $q.Private = [bool]$Private
  if ($PSBoundParameters.ContainsKey('Esc')) { $q.HasEsc = $true; $q.EscValue = [string]$Esc }
  $a = Invoke-Ask $q
  if ($null -eq $a) { return '' }
  return "$a".Trim()
}

# pc: an optional fixed name (DuckDNS or your own domain) instead of the automatic <your-ip>.sslip.io one.
function Set-SelfHostNameInteractive($s) {
  Say ''
  Say (T '  Optional: a fixed free name, so the link stays the same when your internet address changes:') 'Gray'
  Say (T '   1) Go to duckdns.org and sign in (e.g. with a Google or GitHub account).') 'Gray'
  Say (T '   2) Type a name and click "add domain": you get <name>.duckdns.org.') 'Gray'
  Say (T '   3) Type that name here, then paste the "token" shown at the top of that page.') 'Gray'
  $cur = "$(Get-Prop $s 'HostName')"
  $n = ''
  while ($true) {
    if ($cur) { $ans = Read-HostLine (T 'Name (just Enter = keep {0}, "auto" = your internet address)' $cur) -Key 'pc-name' }
    else { $ans = Read-HostLine (T 'Name (e.g. myname.duckdns.org; just Enter = automatic: your internet address)') -Key 'pc-name' }
    if (-not $ans) { return }
    if ($ans -match '^(?i)(auto|automatic|-)$') { $s.HostName = ''; return }
    if ($ans -notmatch '[.:]') { $ans = $ans + '.duckdns.org' }
    $n = ConvertTo-HostAddress $ans
    if ($n) { break }
    Say (T '   That isn''t a name like myname.duckdns.org - try again.') 'Yellow'
  }
  $s.HostName = $n
  if ($n -notmatch '\.duckdns\.org$') {
    Say (T '  Make sure {0} points at your internet address (this tool can only update DuckDNS names).' $n) 'DarkGray'
    return
  }
  $old = "$(Get-Prop $s 'DuckDnsToken')"
  # (The token is a password: never in the path line, nor typed in again for you.)
  if ($old) { $t = Read-HostLine (T 'DuckDNS token (just Enter = keep the saved one)') -Key 'pc-token' -Private }
  else { $t = Read-HostLine (T 'DuckDNS token (just Enter = skip)') -Key 'pc-token' -Private }
  if ($t) {
    if ($t -notmatch '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$') {
      Say (T '   That doesn''t look like a DuckDNS token (like a1b2c3d4-...), but it is saved anyway.') 'Yellow'
    }
    $s.DuckDnsToken = $t
  }
  if (-not "$(Get-Prop $s 'DuckDnsToken')") {
    Say (T '  Without the token this tool can''t keep the name pointing at your PC - it has to be kept up to date some other way.') 'Yellow'
  } elseif (Test-HostFn 'Update-DuckDns') {
    Lock-HostStep   # (DuckDNS is told the new name now: no Back past this)
    $r = $null
    try { $r = Update-DuckDns $s } catch { $r = $_.Exception.Message }
    if ($r) { Say ('  ' + $r) 'DarkGray' }
  }
}

# ------------------------------------------------------------------ my VPS: streams and connection codes
# One VPS carries several streams at the same time, each with its own link (token), publish user + password and SRT
# passphrase, so several PCs can stream at once without taking the stream from each other:
#   - this PC's own stream: Vps.Token / PublishUser / PublishPass / SrtPassphrase (Vps.Name = its name, optional);
#   - Vps.Streams: the further ones, made here for other PCs ("Add a stream for another PC").
# Vps.Role 'owner' = this PC set the server up: its install.sh (New-VpsSetupBundle) carries every stream. 'guest' = this
# PC got one stream as a connection code from that PC: it streams, but never writes install.sh (that would wipe the rest).
# A connection code is "vrclm-vps1:" + base64url of a small JSON: the address, the ports and one stream's secrets
# (a, sp, rp, mp, hp, h; n = name, t, u, p, s). A "whole server" code adds r (the read passphrase), m (MaxReaders) and
# x (the further streams), so another PC of the same person can manage the server too.
# Codes are as secret as the vps-setup files: they are shown with Write-Host only (Say would put them into log.txt).

function Test-VpsSecret([string]$s, [int]$min, [int]$max, [string]$re = $script:VpsSafeRe) {
  return ($s.Length -ge $min -and $s.Length -le $max -and $s -match $re)
}

# A stream's name for the menus: letters, digits, spaces and . _ - ( ), at most 32 characters ('' = $default).
function ConvertTo-VpsStreamName($s, [string]$default = '') {
  $n = (("$s" -replace '[^\p{L}\p{Nd} ._()-]', '') -replace '\s+', ' ').Trim()
  if ($n.Length -gt 32) { $n = $n.Substring(0, 32).Trim() }
  if (-not $n) { return $default }
  return $n
}

# A set of tokens / user names (exact case: links are case-sensitive).
function New-VpsSeenSet { return , (New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)) }

function New-VpsUserName($seen) {
  $i = 2
  while ($seen.Contains("vrclm$i")) { $i++ }
  return "vrclm$i"
}

# One of Vps.Streams: what is missing or broken is made (a new token = a new link for that stream). $seenTok / $seenUser
# = the tokens / user names (lower case) taken already: no two streams may share one.
function Repair-VpsStream($e, [string]$defName, $seenTok, $seenUser, [string]$readPass, [ref]$chg) {
  Set-HostField $e 'Name' (ConvertTo-VpsStreamName (Get-Prop $e 'Name') $defName) $chg
  $t = "$(Get-Prop $e 'Token')"
  if (-not (Test-LinkToken $t) -or $seenTok.Contains($t)) { $t = New-LinkToken }
  [void]$seenTok.Add($t)
  Set-HostField $e 'Token' $t $chg
  $u = "$(Get-Prop $e 'PublishUser')".Trim()
  if ($u -notmatch '^[A-Za-z0-9_-]{1,32}$' -or $u -ieq 'any' -or $seenUser.Contains($u.ToLowerInvariant())) { $u = New-VpsUserName $seenUser }
  [void]$seenUser.Add($u.ToLowerInvariant())
  Set-HostField $e 'PublishUser' $u $chg
  $pw = "$(Get-Prop $e 'PublishPass')"
  if (-not (Test-VpsSecret $pw 16 64)) { $pw = New-HostSecret 24 }
  Set-HostField $e 'PublishPass' $pw $chg
  $pp = "$(Get-Prop $e 'SrtPassphrase')"
  if (-not (Test-VpsSecret $pp 16 79) -or $pp -ceq $readPass) { $pp = New-HostSecret 32 }
  Set-HostField $e 'SrtPassphrase' $pp $chg
}

# Vps.Streams = $list (always an array, so config.json keeps its [ ] with a single stream too).
function Set-VpsStreamList($v, $list, [ref]$chg) {
  $arr = [object[]]@(@($list) | Where-Object { $null -ne $_ })
  $p = $v.PSObject.Properties['Streams']
  if ($p) { $p.Value = $arr } else { $v | Add-Member -NotePropertyName 'Streams' -NotePropertyValue $arr }
  $chg.Value = $true
}

# This PC's stream first, then (on the PC that manages the server) the further ones -> Name, Token, PublishUser,
# PublishPass, SrtPassphrase, Own.
function Get-VpsStreams($v) {
  $list = New-Object System.Collections.ArrayList
  [void]$list.Add([pscustomobject]@{ Name = (ConvertTo-VpsStreamName (Get-Prop $v 'Name')); Token = "$(Get-Prop $v 'Token')"
      PublishUser = "$(Get-Prop $v 'PublishUser')"; PublishPass = "$(Get-Prop $v 'PublishPass')"; SrtPassphrase = "$(Get-Prop $v 'SrtPassphrase')"; Own = $true
    })
  if ("$(Get-Prop $v 'Role')" -ne 'guest') {
    foreach ($e in @(Get-Prop $v 'Streams')) {
      if ($e -isnot [System.Management.Automation.PSCustomObject]) { continue }
      [void]$list.Add([pscustomobject]@{ Name = "$(Get-Prop $e 'Name')"; Token = "$(Get-Prop $e 'Token')"; PublishUser = "$(Get-Prop $e 'PublishUser')"
          PublishPass = "$(Get-Prop $e 'PublishPass')"; SrtPassphrase = "$(Get-Prop $e 'SrtPassphrase')"; Own = $false
        })
    }
  }
  return $list.ToArray()
}

# $stream (one of Get-VpsStreams) -> its connection code. $manage: the whole server (every stream + the read passphrase).
function ConvertTo-VpsConnectCode($v, $stream, [bool]$manage = $false) {
  $o = [ordered]@{
    a = "$(Get-Prop $v 'Address')"; sp = [int]$v.SrtPort; rp = [int]$v.RtspPort; mp = [int]$v.RtmpPort; hp = [int]$v.HlsPort
    h = [bool](ConvertTo-HostBool (Get-Prop $v 'Hls') $false)
    n = "$($stream.Name)"; t = "$($stream.Token)"; u = "$($stream.PublishUser)"; p = "$($stream.PublishPass)"; s = "$($stream.SrtPassphrase)"
  }
  if ($manage) {
    $o.r = "$(Get-Prop $v 'ReadPassphrase')"
    $o.m = ConvertTo-HostInt (Get-Prop $v 'MaxReaders') 30 1 1000
    $x = New-Object System.Collections.ArrayList
    foreach ($e in @(Get-VpsStreams $v)) {
      if ($e.Own -or $e.Token -eq $stream.Token) { continue }
      [void]$x.Add([ordered]@{ n = $e.Name; t = $e.Token; u = $e.PublishUser; p = $e.PublishPass; s = $e.SrtPassphrase })
    }
    $o.x = $x.ToArray()
  }
  $json = ConvertTo-Json -InputObject $o -Compress -Depth 4
  $b = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
  return $script:VpsCodePrefix + $b
}

function Test-VpsCodeText([string]$s) { return ($s -match '(?i)vrclm-vps\d*:') }

# One stream inside a code -> Name, Token, PublishUser, PublishPass, SrtPassphrase (checked with the same rules as
# config.json: Initialize-HostConfig for this PC's own stream, Repair-VpsStream for the further ones).
function ConvertFrom-VpsCodeStream($e, [bool]$own, [string]$bad) {
  if ($e -isnot [System.Management.Automation.PSCustomObject]) { throw $bad }
  $r = [pscustomobject]@{ Name = (ConvertTo-VpsStreamName (Get-Prop $e 'n')); Token = "$(Get-Prop $e 't')"; PublishUser = "$(Get-Prop $e 'u')"
    PublishPass = "$(Get-Prop $e 'p')"; SrtPassphrase = "$(Get-Prop $e 's')"
  }
  if ($own) { $ok = ($r.PublishUser -match '^[A-Za-z0-9._-]{1,32}$') -and (Test-VpsSecret $r.PublishPass 12 64 $script:HostSecretRe) -and (Test-VpsSecret $r.SrtPassphrase 16 79 $script:HostSecretRe) }
  else { $ok = ($r.PublishUser -match '^[A-Za-z0-9_-]{1,32}$') -and (Test-VpsSecret $r.PublishPass 16 64) -and (Test-VpsSecret $r.SrtPassphrase 16 79) }
  if (-not $ok -or $r.PublishUser -ieq 'any' -or -not (Test-LinkToken $r.Token)) { throw $bad }
  return $r
}

# Pasted text with a connection code in it -> the settings it carries (Address, SrtPort, RtspPort, RtmpPort, HlsPort, Hls,
# Name, Token, PublishUser, PublishPass, SrtPassphrase, Manage; for a whole-server code ReadPassphrase, MaxReaders and
# Streams too). Throws a message in plain words when it isn't a usable code.
function ConvertFrom-VpsConnectCode([string]$text) {
  $bad = T 'That connection code is incomplete or damaged - copy all of it again (it is one long line).'
  # As pasted, else without spaces / line breaks (a chat window may have wrapped it).
  $o = $null
  foreach ($cand in @("$text", ("$text" -replace '\s', ''))) {
    $m = [regex]::Match($cand, '(?i)vrclm-vps(\d+):([A-Za-z0-9_-]*)')
    if (-not $m.Success) { continue }
    if ($m.Groups[1].Value -ne '1') { throw (T 'That connection code is from a newer VRChat Link Maker: update this one first.') }
    $b = $m.Groups[2].Value
    if ($b.Length -lt 40 -or $b.Length -gt 8000 -or $b.Length % 4 -eq 1) { continue }
    $b = $b.Replace('-', '+').Replace('_', '/') + ('=' * ((4 - $b.Length % 4) % 4))
    try { $o = ConvertFrom-Json ((New-Object System.Text.UTF8Encoding($false, $true)).GetString([Convert]::FromBase64String($b))) } catch { $o = $null }
    if ($o -is [System.Management.Automation.PSCustomObject]) { break }
    $o = $null
  }
  if (-not $o) { throw $bad }
  $addr = ConvertTo-HostAddress "$(Get-Prop $o 'a')"
  if (-not $addr) { throw $bad }
  $ports = @{}
  foreach ($k in @('sp', 'rp', 'mp', 'hp')) {
    $ports[$k] = ConvertTo-HostInt (Get-Prop $o $k) 0 1 65535
    if ($ports[$k] -eq 0) { throw $bad }
  }
  if (@($ports.rp, $ports.mp, $ports.hp | Select-Object -Unique).Count -ne 3) { throw $bad }
  $main = ConvertFrom-VpsCodeStream $o $true $bad
  $k = [ordered]@{
    Address = $addr; SrtPort = $ports.sp; RtspPort = $ports.rp; RtmpPort = $ports.mp; HlsPort = $ports.hp
    Hls = [bool](ConvertTo-HostBool (Get-Prop $o 'h') $false); Name = $main.Name; Token = $main.Token; PublishUser = $main.PublishUser
    PublishPass = $main.PublishPass; SrtPassphrase = $main.SrtPassphrase; Manage = $false; ReadPassphrase = ''; MaxReaders = 30; Streams = @()
  }
  $rp = Get-Prop $o 'r'
  if ($null -ne $rp) {
    $rp = "$rp"
    if (-not (Test-VpsSecret $rp 16 79 $script:HostSecretRe) -or $rp -ceq $main.SrtPassphrase) { throw $bad }
    $seenTok = New-VpsSeenSet; [void]$seenTok.Add($main.Token)
    $seenUser = New-VpsSeenSet; [void]$seenUser.Add($main.PublishUser.ToLowerInvariant())
    $xs = New-Object System.Collections.ArrayList
    foreach ($e in @(Get-Prop $o 'x')) {
      if ($null -eq $e) { continue }
      $st = ConvertFrom-VpsCodeStream $e $false $bad
      if (-not $seenTok.Add($st.Token) -or -not $seenUser.Add($st.PublishUser.ToLowerInvariant()) -or $st.SrtPassphrase -ceq $rp) { throw $bad }
      [void]$xs.Add($st)
    }
    if ($xs.Count + 1 -gt $script:VpsMaxStreams) { throw $bad }
    $k.Manage = $true; $k.ReadPassphrase = $rp; $k.MaxReaders = ConvertTo-HostInt (Get-Prop $o 'm') 30 1 1000; $k.Streams = $xs.ToArray()
  }
  return [pscustomobject]$k
}

# Takes a code's settings over ($k from ConvertFrom-VpsConnectCode). This PC's own preferences (Push, VideoKbps) stay.
function Import-VpsConnectCode($v, $k) {
  $chg = $false
  foreach ($f in @('Address', 'SrtPort', 'RtspPort', 'RtmpPort', 'HlsPort', 'Hls', 'Name', 'Token', 'PublishUser', 'PublishPass', 'SrtPassphrase')) {
    Set-HostField $v $f $k.$f ([ref]$chg)
  }
  $list = @()
  if ($k.Manage) {
    Set-HostField $v 'Role' 'owner' ([ref]$chg)
    Set-HostField $v 'ReadPassphrase' $k.ReadPassphrase ([ref]$chg)
    Set-HostField $v 'MaxReaders' ([int]$k.MaxReaders) ([ref]$chg)
    $list = @($k.Streams | ForEach-Object { [pscustomobject][ordered]@{ Name = $_.Name; Token = $_.Token; PublishUser = $_.PublishUser; PublishPass = $_.PublishPass; SrtPassphrase = $_.SrtPassphrase } })
  } else {
    Set-HostField $v 'Role' 'guest' ([ref]$chg)
    # (A guest never uses it; it only has to differ from the publish passphrase.)
    if ("$(Get-Prop $v 'ReadPassphrase')" -ceq $k.SrtPassphrase) { Set-HostField $v 'ReadPassphrase' (New-HostSecret 32) ([ref]$chg) }
  }
  Set-VpsStreamList $v $list ([ref]$chg)
}

# New secrets for this PC's own stream and no further streams (a new server of its own, set up with install.sh).
function Reset-VpsOwnSecrets($v) {
  $chg = $false
  Set-HostField $v 'Token' (New-LinkToken) ([ref]$chg)
  Set-HostField $v 'PublishUser' 'vrclm' ([ref]$chg)
  Set-HostField $v 'PublishPass' (New-HostSecret 24) ([ref]$chg)
  Set-HostField $v 'SrtPassphrase' (New-HostSecret 32) ([ref]$chg)
  Set-HostField $v 'ReadPassphrase' (New-HostSecret 32) ([ref]$chg)
  Set-HostField $v 'Name' '' ([ref]$chg)
  Set-HostField $v 'Role' 'owner' ([ref]$chg)
  Set-VpsStreamList $v @() ([ref]$chg)
}

function Save-VpsConfig {
  try { Save-Config $script:Cfg } catch { Say (T '  Couldn''t save config.json: {0}' $_.Exception.Message) 'Red' }
}

# Shows a connection code (on the screen only, never in log.txt) and copies it to the clipboard.
# The code onto the clipboard, but not into Windows' clipboard history or cloud clipboard (Win+V): it is a password.
# (Needs the STA thread the .bat starts; $false = not copied.)
function Set-VpsClipboard([string]$text) {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    $d = New-Object System.Windows.Forms.DataObject
    $d.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $text)
    foreach ($f in @('CanIncludeInClipboardHistory', 'CanUploadToCloudClipboard', 'ExcludeClipboardContentFromMonitorProcessing')) {
      $d.SetData($f, (New-Object System.IO.MemoryStream(, [BitConverter]::GetBytes([int]0))))
    }
    [System.Windows.Forms.Clipboard]::SetDataObject($d, $true)
    return $true
  } catch { return $false }
}

function Show-VpsCode([string]$code) {
  Say ''
  Write-Host "      $code" -ForegroundColor Green
  Say ''
  if (Set-VpsClipboard $code) { Say (T '  (The code is copied to your clipboard.)') 'DarkGray' }
  else { Say (T '  (Select the code above with the mouse and copy it: it is one long line.)') 'DarkGray' }
  Say (T '  The code works like a password for that stream: send it only to whoever streams with it (in a private message).') 'Yellow'
}

# ------------------------------------------------------------------ my VPS: is it ready?
# One RTSP request to the VPS (a name, an IPv4 or an IPv6 address) -> Code (the status, e.g. 404; 0 = no connection or no
# answer) and Detail. Its own small client: Send-MtxRtspAnnounce only does IPv4 addresses.
function Invoke-VpsRtsp([string]$addr, [int]$port, [string]$request, [int]$ms) {
  $sock = $null
  try {
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($addr, [ref]$ip)) {
      $ar = [System.Net.Dns]::BeginGetHostAddresses($addr, $null, $null)
      if (-not $ar.AsyncWaitHandle.WaitOne($ms)) { return [pscustomobject]@{ Code = 0; Detail = 'name lookup timed out' } }
      $all = @([System.Net.Dns]::EndGetHostAddresses($ar))
      $ip = @(@($all | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork }) +
        @($all | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6 })) | Select-Object -First 1
      if (-not $ip) { return [pscustomobject]@{ Code = 0; Detail = 'name not found' } }
    }
    $sock = New-Object System.Net.Sockets.Socket($ip.AddressFamily, [System.Net.Sockets.SocketType]::Stream, [System.Net.Sockets.ProtocolType]::Tcp)
    $ar = $sock.BeginConnect($ip, $port, $null, $null)
    if (-not $ar.AsyncWaitHandle.WaitOne($ms)) { return [pscustomobject]@{ Code = 0; Detail = 'connection timed out' } }
    $sock.EndConnect($ar)
    $sock.ReceiveTimeout = $ms
    $sock.SendTimeout = $ms
    [void]$sock.Send([System.Text.Encoding]::ASCII.GetBytes($request))
    $buf = New-Object byte[] 4096
    $got = ''
    while ($got -notmatch "`r`n`r`n" -and $got.Length -lt 65536) {
      $n = $sock.Receive($buf)
      if ($n -le 0) { break }
      $got += [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
    }
    $m = [regex]::Match($got, '^RTSP/1\.0 (\d{3})[^\r\n]*')
    if ($m.Success) { return [pscustomobject]@{ Code = [int]$m.Groups[1].Value; Detail = $m.Value } }
    return [pscustomobject]@{ Code = 0; Detail = 'no RTSP answer' }
  } catch {
    return [pscustomobject]@{ Code = 0; Detail = $_.Exception.Message }
  } finally { if ($sock) { try { $sock.Close() } catch {} } }
}

# What the VPS says about a stream's link (anyone may ask: reading needs no password) -> State, Code, Detail, PassOk:
#   'live' (200) = someone streams on it right now; 'idle' (404) = the server knows the link, nobody streams on it;
#   'unknown' (400 "path is not configured") = the server doesn't know the link (another token, or install.sh wasn't
#   pasted again since); 'down' = no connection or no answer; 'other' = any other answer (Code).
# With $user / $pass it also sends them in an ANNOUNCE (the first step of publishing, without RECORD, so it doesn't take
# a live stream over) -> PassOk $true (200) / $false (401) / $null (not checked). Checked with MediaMTX v1.21.1.
function Test-VpsStream([string]$addr, [int]$port, [string]$token, [string]$user = '', [string]$pass = '', [int]$ms = 4000) {
  $url = "rtsp://$(Format-HostForUrl $addr):$port/live/$token"
  $d = Invoke-VpsRtsp $addr $port "DESCRIBE $url RTSP/1.0`r`nCSeq: 1`r`nAccept: application/sdp`r`nUser-Agent: VRChatLinkMaker`r`n`r`n" $ms
  $state = 'other'
  switch ($d.Code) { 0 { $state = 'down' } 200 { $state = 'live' } 404 { $state = 'idle' } 400 { $state = 'unknown' } }
  $r = [pscustomobject]@{ State = $state; Code = $d.Code; Detail = $d.Detail; PassOk = $null }
  if ($user -and $pass -and ($state -eq 'live' -or $state -eq 'idle')) {
    $sdp = "v=0`r`no=- 0 0 IN IP4 127.0.0.1`r`ns=vrclm-check`r`nc=IN IP4 0.0.0.0`r`nt=0 0`r`nm=video 0 RTP/AVP 96`r`n" +
      "a=rtpmap:96 H264/90000`r`na=fmtp:96 packetization-mode=1`r`na=control:trackID=0`r`n"
    $auth = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("${user}:$pass"))
    # (MediaMTX answers a wrong password only after a pause of a few seconds.)
    $a = Invoke-VpsRtsp $addr $port ("ANNOUNCE $url RTSP/1.0`r`nCSeq: 1`r`nUser-Agent: VRChatLinkMaker`r`nAuthorization: Basic $auth`r`n" +
      "Content-Type: application/sdp`r`nContent-Length: $($sdp.Length)`r`n`r`n$sdp") ([Math]::Max($ms, 8000))
    if ($a.Code -eq 200) { $r.PassOk = $true } elseif ($a.Code -eq 401 -or $a.Code -eq 403) { $r.PassOk = $false }
  }
  return $r
}

# This PC's stream on its VPS, from config.json -> Test-VpsStream's answer ($null = no address).
function Test-VpsOwnStream([bool]$withPass, [int]$ms = 4000) {
  $v = Get-Prop $script:Cfg 'Vps'
  $addr = ConvertTo-HostAddress "$(Get-Prop $v 'Address')"
  if (-not $addr) { return $null }
  $user = ''; $pass = ''
  if ($withPass) { $user = "$(Get-Prop $v 'PublishUser')"; $pass = "$(Get-Prop $v 'PublishPass')" }
  return (Test-VpsStream $addr (ConvertTo-HostInt (Get-Prop $v 'RtspPort') 8554 1 65535) "$(Get-Prop $v 'Token')" $user $pass $ms)
}

# What's wrong when the VPS won't take this PC's stream, in plain words ('' = nothing found).
function Get-VpsProblemText($r) {
  $v = Get-Prop $script:Cfg 'Vps'
  $guest = ("$(Get-Prop $v 'Role')" -eq 'guest')
  if (-not $r) { return (T '  The VPS address isn''t set yet: choose "My VPS" in the host menu (H) and type it in.') }
  switch ($r.State) {
    'down' { return (T '  Your VPS ({0}) doesn''t answer on port {1}: is the server on, is MediaMTX installed there (install.sh), and are its ports open?' $v.Address $v.RtspPort) }
    'unknown' {
      if ($guest) { return (T '  The VPS doesn''t know your link: ask whoever manages the server for a new connection code (they may have to paste install.sh on the server again first).') }
      return (T '  The VPS doesn''t know this PC''s link. Set up from this PC? Then paste install.sh from the vps-setup folder on the server again. Set up from another PC? Then paste that PC''s connection code here (H -> My VPS) instead.')
    }
  }
  if ($r.PassOk -eq $false) {
    if ($guest) { return (T '  The VPS refused your stream''s password: ask whoever manages the server for a new connection code.') }
    return (T '  The VPS refused this PC''s publish password: paste install.sh on the server again, or the connection code from the PC that manages it.')
  }
  return ''
}

# Before streaming to the VPS (Start-HostServer): does it answer, know this PC's link and take its password, and is
# nobody else on that link? -> $true (stream there), $false (through Topaz Chat this time) or 'menu' (choose another host).
function Test-VpsReady($p) {
  if (-not (ConvertTo-HostAddress "$(Get-Prop (Get-Prop $script:Cfg 'Vps') 'Address')")) {
    Say (T 'The VPS address isn''t set yet, so this time it streams through Topaz Chat (H on the start screen = type it in).') 'Yellow'
    return $false
  }
  Say (T 'Checking your VPS...') 'Gray'
  $r = Test-VpsOwnStream $true
  if ($r.State -eq 'live') {
    # Maybe only this PC's last run still ending on the server (it lets a lost publisher go after about 10 s).
    $until = (Get-Date).AddSeconds(12)
    while ($r.State -eq 'live' -and (Get-Date) -lt $until) { Wait-HostPump 2000; $r = Test-VpsOwnStream $false }
    if ($r.State -eq 'live' -or $r.State -eq 'idle') { $r = Test-VpsOwnStream $true }
  }
  $canAsk = (Test-HostFn 'Test-CanAsk') -and (Test-CanAsk) -and (Test-HostFn 'Read-Choice')
  $problem = Get-VpsProblemText $r
  if ($problem) {
    Say $problem 'Yellow'
    if (-not $canAsk) { Say (T '  This time it streams through Topaz Chat.') 'Yellow'; return $false }
    $pick = Read-Choice (T 'Stream to the VPS anyway?') @((T 'No - stream through Topaz Chat this time'), (T 'Yes - try the VPS anyway'), (T 'Choose another host')) 0 $false -Esc 0
    if ($pick -eq 1) { return $true }
    if ($pick -eq 2) { return 'menu' }
    return $false
  }
  if ($r.State -eq 'live') {
    Say (T '  Someone is streaming on this VPS link right now (another PC with the same connection code?). Streaming from here takes the stream over.') 'Yellow'
    if (-not $canAsk) { Say (T '  This time it streams through Topaz Chat.') 'Yellow'; return $false }
    $pick = Read-Choice (T 'Take the stream over?') @((T 'No - stream through Topaz Chat this time'), (T 'Yes - take it over'), (T 'Choose another host')) 0 $false -Esc 0
    if ($pick -eq 1) { return $true }
    if ($pick -eq 2) { return 'menu' }
    return $false
  }
  if ($r.State -eq 'idle') { Say (T '  Your VPS is ready.') 'DarkGray' }
  return $true
}

# After the relay to the VPS broke (Wait-RelayRetry): why, as the server sees it. $sent = the relay had been sending;
# $endedItself = the server or the network ended it (not this tool: a stall, a resync...).
# -> $null, or Why (a reason in plain words) and Stop + Message: another PC streams on the same link and took it twice
# within 3 minutes, so this PC gives way instead of taking it back again and again (both would keep kicking each other).
# (The server still lists a lost connection for up to about 10 s, so "live" right after a break may be this PC's own.)
$script:VpsTakeoverAt = $null
function Get-VpsRelayVerdict([bool]$sent, [bool]$endedItself = $true) {
  $r = Test-VpsOwnStream (-not $sent) 2500
  if (-not $r) { return $null }
  $why = ''
  if ($r.State -eq 'down') { $why = T 'your VPS doesn''t answer' }
  elseif ($r.State -eq 'unknown') { $why = T 'the VPS doesn''t know this link (H -> My VPS says what to do)' }
  elseif ($r.PassOk -eq $false) { $why = T 'the VPS refused the publish password (H -> My VPS says what to do)' }
  elseif (-not $endedItself) { return $null }   # (this tool ended it - a stall, a resync: that reason stands)
  elseif (-not $sent) {
    if ($r.PassOk -eq $true -and "$($script:HostP.IngestUrl)" -match '^(?i)srt://') { $why = T 'the VPS didn''t take the stream: UDP port {0} (SRT) may be closed in its firewall, or the SRT passphrase doesn''t match' (Get-Prop (Get-Prop $script:Cfg 'Vps') 'SrtPort') }
  } elseif ($r.State -eq 'live') {
    $now = Get-Date
    if ($script:VpsTakeoverAt -and ($now - $script:VpsTakeoverAt).TotalSeconds -lt 180) {
      # Taken again soon: wait until this PC's own lost connection would be gone from the server, then give way.
      $until = $now.AddSeconds(12)
      do { Wait-HostPump 2000; $r2 = Test-VpsOwnStream $false 2500 } while ($r2 -and $r2.State -eq 'live' -and (Get-Date) -lt $until)
      if ($r2 -and $r2.State -eq 'live') {
        $msg = T 'Another PC is streaming on your VPS link (it uses the same connection code), so this PC stopped sending - otherwise both would keep taking the stream from each other. Each PC needs its own stream: on the PC that manages the server choose H -> My VPS -> "Add a stream for another PC".'
        return [pscustomobject]@{ Why = ''; Stop = $true; Message = $msg }
      }
      return $null
    }
    # (Only noted: it may be this PC's own connection still listed. Reconnecting takes the link over either way.)
    $script:VpsTakeoverAt = $now
  }
  if (-not $why) { return $null }
  return [pscustomobject]@{ Why = $why; Stop = $false; Message = '' }
}

# ------------------------------------------------------------------ my VPS: the menus
# Makes the VPS setup files (part 2) and says where they are and what to do with them. Not on a PC that streams with a
# connection code: the server is managed on another PC, and this one's install.sh would replace everything there.
function Show-VpsBundle($v, [switch]$Quiet) {
  if (-not (Test-HostFn 'New-VpsSetupBundle')) { return }
  if ("$(Get-Prop $v 'Role')" -eq 'guest') { return }
  $dir = $null
  try { $dir = New-VpsSetupBundle $v } catch { Say (T '  Couldn''t make the VPS setup files: {0}' $_.Exception.Message) 'Red'; return }
  if (-not $dir -or $Quiet) { return }
  $tcp = "$($v.RtspPort), $($v.RtmpPort)"
  if (ConvertTo-HostBool (Get-Prop $v 'Hls') $false) { $tcp += ", $($v.HlsPort)" }
  Say ''
  Say (T '  The setup files for your VPS are in:  {0}' $dir) 'White'
  Say (T '   1) Open README-VPS.txt there: it shows how to get the free Oracle Cloud server (or Hetzner). Viewers in Russia can''t watch from either: see "Viewers in Russia" in README.txt.') 'Gray'
  Say (T '   2) In the server''s network rules allow TCP ports {0} and UDP port {1}.' $tcp $v.SrtPort) 'Gray'
  Say (T '   3) Log in to the server (ssh) and paste the text of install.sh. That''s it.') 'Gray'
  Say (T '  Keep these files to yourself: they contain your VPS''s passwords.') 'Yellow'
}

# The VPS settings so far, kept in config.json as "VpsBefore" before a code or a new server replaces them.
function Save-VpsBefore($v) {
  # (Not Set-HostField: it compares objects by their text, which leaves the Streams list out.)
  $copy = $v | ConvertTo-Json -Depth 6 | ConvertFrom-Json
  $p = $script:Cfg.PSObject.Properties['VpsBefore']
  if ($p) { $p.Value = $copy } else { $script:Cfg | Add-Member -NotePropertyName 'VpsBefore' -NotePropertyValue $copy }
}

# A pasted code: checked, then taken over (after asking, if it would replace the server this PC manages). $true = done.
function Invoke-VpsCodeImport($v, [string]$text) {
  try { $k = ConvertFrom-VpsConnectCode $text } catch { Say ('   ' + $_.Exception.Message) 'Yellow'; return $false }
  $isOwner = ("$(Get-Prop $v 'Role')" -ne 'guest')
  $addrNow = ConvertTo-HostAddress "$(Get-Prop $v 'Address')"
  if ($isOwner -and $addrNow) {
    # Only a whole-server code for this same server that knows every stream this PC knows replaces nothing.
    $kept = @($k.Streams | ForEach-Object { $_.Token })
    $lost = @(Get-VpsStreams $v | Where-Object { -not $_.Own -and $kept -notcontains $_.Token } | ForEach-Object { $_.Name })
    $same = ($k.Address -eq $addrNow -and $k.Token -ceq "$($v.Token)")
    if (-not ($k.Manage -and $same -and $lost.Count -eq 0)) {
      if (-not $k.Manage) { Say (T '  This PC manages the VPS {0} now. With this code it only streams on one stream of a server, and can''t change {0} any more (its streams keep running).' $addrNow) 'Yellow' }
      elseif ($lost.Count -gt 0) { Say (T '  This code replaces this PC''s VPS settings. These streams are only known here and would be dropped: {0}.' ($lost -join ', ')) 'Yellow' }
      else { Say (T '  This code replaces this PC''s VPS settings (this PC then uses the link in the code).') 'Yellow' }
      Say (T '  (The settings so far are kept in config.json as "VpsBefore".)') 'DarkGray'
      if (-not (Read-YesNoUi (T 'Use the code anyway? [y/N]') $false -Esc $false -Key 'vps-code-anyway')) { return $false }
      Lock-HostStep
      Save-VpsBefore $v
    }
  }
  Lock-HostStep   # (taken over and saved: no Back past this)
  Import-VpsConnectCode $v $k
  Save-VpsConfig
  if ($k.Manage) { Show-VpsBundle $v -Quiet }
  if ($k.Manage) {
    Say (T '  Done: this PC manages the VPS {0} too ({1} streams on it).' $k.Address ($k.Streams.Count + 1)) 'Green'
    Say (T '  It uses the same link as the PC the code came from (only one of the two can stream on it at a time). Change the streams on one PC only: the server gets the streams of the PC that pasted install.sh last.') 'Yellow'
  }
  elseif ($k.Name) { Say (T '  Done: this PC streams on "{0}" on the VPS {1}.' $k.Name $k.Address) 'Green' }
  else { Say (T '  Done: this PC streams on the VPS {0}.' $k.Address) 'Green' }
  Show-VpsDiagnosis $true
  return $true
}

# Asks the VPS about this PC's stream and says what's wrong. $okLine: also say so when all is well.
function Show-VpsDiagnosis([bool]$okLine) {
  Say (T 'Checking your VPS...') 'Gray'
  $r = Test-VpsOwnStream $true
  $problem = Get-VpsProblemText $r
  if ($problem) { Say $problem 'Yellow'; return }
  if (-not $okLine) { return }
  if ($r.PassOk -eq $true) { Say (T '  The VPS knows this stream and takes its password.') 'DarkGreen' }
  elseif ($r.State -eq 'idle' -or $r.State -eq 'live') { Say (T '  The VPS knows this stream.') 'DarkGreen' }
}

# The streams on the server this PC manages: their state on the server, and add / show a code / remove.
function Get-VpsStreamStates($v, $list) {
  $addr = ConvertTo-HostAddress "$(Get-Prop $v 'Address')"
  $port = ConvertTo-HostInt (Get-Prop $v 'RtspPort') 8554 1 65535
  $out = @()
  $down = $false
  foreach ($e in $list) {
    if (-not $addr -or $down) { $out += 'down'; continue }
    $r = Test-VpsStream $addr $port $e.Token '' '' 3000
    if ($r.State -eq 'down') { $down = $true }
    $out += $r.State
  }
  return $out
}

function Format-VpsStreamLine($e, [string]$state) {
  $name = $e.Name
  if ($e.Own -and $e.Name) { $name = T '{0} (this PC)' $e.Name }
  elseif ($e.Own) { $name = T 'this PC' }
  switch ($state) {
    'live' { return (T '{0} - on the air now' $name) }
    'idle' { return (T '{0} - ready' $name) }
    'unknown' { return (T '{0} - not on the server yet: paste install.sh there again' $name) }
    'down' { return (T '{0} - the server doesn''t answer' $name) }
  }
  return $name
}

function Add-VpsStream($v) {
  $list = @(Get-VpsStreams $v)
  if ($list.Count -ge $script:VpsMaxStreams) { Say (T '  That''s {0} streams already, the most this tool puts on one server.' $script:VpsMaxStreams) 'Yellow'; return }
  $taken = @($list | ForEach-Object { $_.Name })
  $i = 2
  while ($taken -contains (T 'Stream {0}' $i)) { $i++ }
  $def = T 'Stream {0}' $i
  # (Its own little flow: Esc at the name = don't add a stream.)
  $nr = Invoke-NavFlow -Name 'vps-add' -Origin 'menu' -Body { Read-HostLine (T 'A name for it, e.g. who streams with it (just Enter = "{0}")' $def) -Key 'vps-add-name' }
  if ($nr.Nav) { return }
  $name = ConvertTo-VpsStreamName ([string](@($nr.Value) | Select-Object -Last 1)) $def
  Lock-HostStep
  # (Two streams with one name couldn't be told apart in the menus.)
  $base = $name; $i = 2
  while ($taken -contains $name) {
    $suf = " ($i)"
    $name = $base.Substring(0, [Math]::Min($base.Length, 32 - $suf.Length)).TrimEnd() + $suf
    $i++
  }
  $seenTok = New-VpsSeenSet; $seenUser = New-VpsSeenSet
  foreach ($e in $list) { [void]$seenTok.Add($e.Token); [void]$seenUser.Add($e.PublishUser.ToLowerInvariant()) }
  $new = [pscustomobject][ordered]@{ Name = $name; Token = ''; PublishUser = ''; PublishPass = ''; SrtPassphrase = '' }
  $chg = $false
  Repair-VpsStream $new $def $seenTok $seenUser "$($v.ReadPassphrase)" ([ref]$chg)
  Set-VpsStreamList $v (@(@(Get-Prop $v 'Streams') | Where-Object { $null -ne $_ }) + $new) ([ref]$chg)
  Save-VpsConfig
  Show-VpsBundle $v -Quiet
  Say (T '  Added "{0}". Two more steps:' $name) 'Green'
  Say (T '   1) Paste install.sh (vps-setup folder) on the server again: the streams on it keep working, the new one works after that.') 'White'
  Say (T '   2) Give this code to the PC that streams with it. There: H -> My VPS -> paste the code instead of an address.') 'White'
  $st = @(Get-VpsStreams $v | Where-Object { $_.Token -eq $new.Token })[0]
  Show-VpsCode (ConvertTo-VpsConnectCode $v $st)
  Say (T '  All streams share the server''s upload: e.g. 2 streams with 10 viewers each at 4 Mbps need 80 Mbps.') 'DarkGray'
}

function Select-VpsCode($v, $list) {
  $opts = @()
  foreach ($e in $list) {
    if ($e.Own) { $opts += (T 'This PC''s own link - for another PC of yours (only one of the two can stream on it at a time)') }
    else { $opts += $e.Name }
  }
  $opts += (T 'The whole server - for another PC of yours that should manage it too (it also gets this PC''s link)')
  $i = Read-Choice (T 'The code for which stream?') $opts -1 $true -Esc -1
  if ($i -lt 0) { return }
  if ($i -ge $list.Count) {
    Say (T '  The code for the whole server (it holds every stream''s password):') 'White'
    Show-VpsCode (ConvertTo-VpsConnectCode $v $list[0] $true)
    return
  }
  if ($list[$i].Own) { Say (T '  The code for this PC''s own link:') 'White' }
  else { Say (T '  The code for "{0}":' $list[$i].Name) 'White' }
  Show-VpsCode (ConvertTo-VpsConnectCode $v $list[$i])
}

function Remove-VpsStreamInteractive($v, $list) {
  $others = @($list | Where-Object { -not $_.Own })
  if ($others.Count -eq 0) { return }
  # (The pick and its confirm are their own little flow: Esc at the confirm = back to the pick, Esc at the pick = none.)
  $names = @($others | ForEach-Object { $_.Name })
  $rr = Invoke-NavFlow -Name 'vps-remove' -Origin 'menu' -Body {
    $i = Read-Choice (T 'Remove which stream?') $names -1 $true -Key 'vps-remove' -Values $names
    if ($i -lt 0) { return }
    if (-not (Read-YesNoUi (T 'Remove "{0}"? Its link stops working once install.sh is pasted on the server again. [y/N]' $others[$i].Name) $false -Esc $false -Key 'vps-remove-yes')) { return }
    $i
  }
  if ($rr.Nav) { return }
  $pick = @($rr.Value | Where-Object { $_ -is [int] })
  if ($pick.Count -eq 0) { return }
  $gone = $others[$pick[-1]]
  Lock-HostStep
  $chg = $false
  Set-VpsStreamList $v @(@(Get-Prop $v 'Streams') | Where-Object { $null -ne $_ -and "$($_.Token)" -cne $gone.Token }) ([ref]$chg)
  Save-VpsConfig
  Show-VpsBundle $v -Quiet
  Say (T '  Removed. Paste install.sh (vps-setup folder) on the server again: then that link stops working.') 'Green'
}

# New passwords for every stream (the links stay): every code given out stops working once install.sh is pasted again.
function Reset-VpsAllPasswords($v) {
  if (-not (Read-YesNoUi (T 'New passwords for every stream? Every code given out stops working once install.sh is pasted on the server again; the links stay the same. [y/N]') $false -Esc $false)) { return }
  $chg = $false
  Set-HostField $v 'PublishPass' (New-HostSecret 24) ([ref]$chg)
  Set-HostField $v 'SrtPassphrase' (New-HostSecret 32) ([ref]$chg)
  Set-HostField $v 'ReadPassphrase' (New-HostSecret 32) ([ref]$chg)
  foreach ($e in @(Get-Prop $v 'Streams')) {
    if ($e -isnot [System.Management.Automation.PSCustomObject]) { continue }
    Set-HostField $e 'PublishPass' (New-HostSecret 24) ([ref]$chg)
    Set-HostField $e 'SrtPassphrase' (New-HostSecret 32) ([ref]$chg)
  }
  Save-VpsConfig
  Show-VpsBundle $v -Quiet
  Say (T '  Done. Paste install.sh (vps-setup folder) on the server again, then send every other PC its new code ("Show a connection code").') 'Green'
}

function Invoke-VpsStreamsMenu($v) {
  if (-not (Test-HostFn 'Read-Choice')) { return }
  # (Reached after the setup files were written: its questions are one-off, Esc here = Done.)
  Lock-HostStep
  while ($true) {
    $list = @(Get-VpsStreams $v)
    $states = @(Get-VpsStreamStates $v $list)
    Say ''
    Say (T '  Streams on your VPS (each has its own link; all of them can be on the air at the same time):') 'White'
    for ($i = 0; $i -lt $list.Count; $i++) { Say ('   - ' + (Format-VpsStreamLine $list[$i] $states[$i])) 'Gray' }
    $opts = @((T 'Done'), (T 'Add a stream for another PC'), (T 'Show a connection code'), (T 'New passwords for every stream (takes back every code given out)'))
    if ($list.Count -gt 1) { $opts += (T 'Remove a stream') }
    $pick = Read-Choice (T 'Anything else for the VPS?') $opts 0 $false -Esc 0
    if ($pick -eq 1) { Add-VpsStream $v }
    elseif ($pick -eq 2) { Select-VpsCode $v $list }
    elseif ($pick -eq 3) { Reset-VpsAllPasswords $v }
    elseif ($pick -eq 4) { Remove-VpsStreamInteractive $v $list }
    else { return }
  }
}

# vps: the address or a connection code, then (on the PC that manages the server) the setup files and the streams menu.
# $false = no address yet.
function Set-VpsInteractive($v) {
  Say ''
  Say (T '  Your own small server on the internet streams to the viewers: they don''t see your home address and') 'Gray'
  Say (T '  don''t use your upload. Free with Oracle Cloud "Always Free", or about 5.49 EUR/month at Hetzner.') 'Gray'
  Say (T '  Viewers in Russia can''t watch from Oracle, Hetzner or the other big clouds: see "Viewers in Russia" in README.txt.') 'Yellow'
  Say (T '  One server can carry several streams at the same time (one per PC), each with its own link.') 'Gray'
  if ("$(Get-Prop $v 'Role')" -eq 'guest') {
    $name = ConvertTo-VpsStreamName (Get-Prop $v 'Name')
    if ($name) { Say (T '  This PC streams on "{0}" on the VPS {1} (from a connection code); the server is managed on another PC.' $name $v.Address) 'White' }
    else { Say (T '  This PC streams on the VPS {0} (from a connection code); the server is managed on another PC.' $v.Address) 'White' }
    if (-not (Test-HostReplaying)) { Show-VpsDiagnosis $false }   # (a Back re-runs this: the check is shown already)
    while ($true) {
      $ans = Read-HostLine (T 'Paste a new connection code, or type an address to set up a server of your own (just Enter = keep it like this)') -Key 'vps-address' -Private
      if (-not $ans) { return [bool]"$(Get-Prop $v 'Address')" }
      if (Test-VpsCodeText $ans) {
        if (Invoke-VpsCodeImport $v $ans) { return $true }
        continue
      }
      $n = ConvertTo-HostAddress $ans
      if ($n -and $n -eq (ConvertTo-HostAddress "$(Get-Prop $v 'Address')")) { return $true }   # (the same server: nothing changes)
      if ($n) {
        Say (T '  That sets up a server of your own at {0}: this PC stops using the connection code. Its settings are kept in config.json as "VpsBefore".' $n) 'Yellow'
        if (-not (Read-YesNoUi (T 'Set up a server of your own? [y/N]') $false -Esc $false -Key 'vps-own')) { continue }
        Lock-HostStep
        Save-VpsBefore $v
        # A server of its own: new passwords (the old ones belong to the other server's stream).
        Reset-VpsOwnSecrets $v
        $v.Address = $n
        break
      }
      Say (T '   That is neither a connection code nor an address like vps.example.com - try again.') 'Yellow'
    }
  } else {
    Say (T '  Setting it up takes about 20 minutes, once. The steps are in README-VPS.txt (made now).') 'Gray'
    Say (T '  Got a connection code from the PC that manages a server? Paste it here instead of the address.') 'Gray'
    $cur = "$(Get-Prop $v 'Address')"
    while ($true) {
      if ($cur) { $ans = Read-HostLine (T 'The VPS''s address, or a connection code (just Enter = keep the saved address)') -Key 'vps-address' -Private }
      else { $ans = Read-HostLine (T 'The VPS''s address, or a connection code (just Enter = I don''t have one yet)') -Key 'vps-address' -Private }
      if (-not $ans) { break }
      if (Test-VpsCodeText $ans) {
        if (Invoke-VpsCodeImport $v $ans) { return $true }
        continue
      }
      $n = ConvertTo-HostAddress $ans
      if ($n) {
        $v.Address = $n
        if ($cur -and $n -ne $cur -and @(Get-VpsStreams $v).Count -gt 1) {
          Say (T '  The address changed: every other PC needs its code again ("Show a connection code" below).') 'Yellow'
        }
        break
      }
      Say (T '   That isn''t an IP address or a name like vps.example.com - try again.') 'Yellow'
    }
  }
  Lock-HostStep   # (the setup files are written now: no Back past this)
  Show-VpsBundle $v
  if (-not "$(Get-Prop $v 'Address')") {
    Say (T '  Once the server runs, choose "My VPS" here again and type its address.') 'Cyan'
    return $false
  }
  Show-VpsDiagnosis $false
  Invoke-VpsStreamsMenu $v
  return $true
}

# custom: the links typed in by hand. Enter keeps each one. $false = cancelled (no ingest / PC link typed).
function Set-CustomInteractive($c) {
  $saved = Get-Prop $c 'CustomLinks'
  $cur = @{}
  foreach ($k in @('IngestUrl', 'PcUrl', 'QuestUrl', 'VlcUrl')) {
    $val = "$(Get-Prop $c $k)"
    if ("$(Get-Prop $c 'Host')" -ne 'custom') { $val = "$(Get-Prop $saved $k)" }
    $cur[$k] = $val
  }
  Say ''
  Say (T '  Type the links your streaming service gives you (e.g. Twitch: rtmp://live-fra.twitch.tv/app/<your key>).') 'Gray'
  $ask = @(
    @{ K = 'IngestUrl'; Q = (T 'Where to send the stream (rtmp://..., rtmps://... or srt://...)'); Re = '^(?i)(rtmps?|srt)://[^/\s]+\S*$'; Need = $true },
    @{ K = 'PcUrl'; Q = (T 'The link for VRChat on PC'); Re = '^(?i)(rtspt?|rtmps?|https?)://[^/\s]+\S*$'; Need = $true },
    @{ K = 'QuestUrl'; Q = (T 'The link for Quest (optional)'); Re = '^(?i)(rtsp|rtmps?|https)://[^/\s]+\S*$'; Need = $false }
  )
  foreach ($a in $ask) {
    while ($true) {
      $d = $cur[$a.K]
      # (The address to send to holds the stream key: it is never printed, nor shown in the path line.)
      $sec = ($a.K -eq 'IngestUrl')
      $key = 'custom-' + $a.K
      if ($d -and $sec) { $ans = Read-HostLine (T '{0} (just Enter = keep the saved link)' $a.Q) -Key $key -Private }
      elseif ($d) { $ans = Read-HostLine (T '{0} (just Enter = {1})' $a.Q $d) -Key $key -Private:$sec }
      elseif ($a.Need) { $ans = Read-HostLine (T '{0} (just Enter = cancel)' $a.Q) -Key $key -Private:$sec }
      else { $ans = Read-HostLine (T '{0} (just Enter = none)' $a.Q) -Key $key -Private:$sec }
      if (-not $ans) {
        if ($d -or -not $a.Need) { break }
        return $false
      }
      if (-not $a.Need -and $ans -match '^(?i)(none|-)$') { $cur[$a.K] = ''; break }
      if ($ans -match $a.Re) { $cur[$a.K] = $ans; break }
      Say (T '   That doesn''t look like such a link - try again.') 'Yellow'
    }
  }
  $chg = $false
  foreach ($k in @('IngestUrl', 'PcUrl', 'QuestUrl', 'VlcUrl')) { Set-HostField $c $k ([string]$cur[$k]) ([ref]$chg) }
  return $true
}

# The host menu. Saves config.json (only when something changed). Returns $true when the host or its links changed (the
# stream must restart). The main script runs it as a flow (Invoke-HostChoice): Esc at the first question leaves it.
function Select-Host {
  if (-not $script:Interactive) { return $false }
  $c = $script:Cfg
  $was = $c | ConvertTo-Json -Depth 8 -Compress
  [void](Initialize-HostConfig)
  $cfgP = Get-HostProfile
  $cfgId = $cfgP.Id
  $before = $cfgP
  # The configured host couldn't start (Topaz streams instead): Topaz is "now", and picking the other one again retries it.
  if ($script:HostP -and $script:HostP.Id -ne $cfgId) { $before = Get-HostProfile $script:HostP.Id }
  $curId = $before.Id
  $opts = @(
    (T 'Topaz Chat - free, trusted by VRChat, plays everywhere (Public too). Up to about 1.4 Mbps.'),
    (T 'This PC - free, sharper picture; viewers see your home IP; not for Public instances; uses your upload.'),
    (T 'My VPS - your own server (Oracle free, or ~5.49 EUR/month; viewers in Russia need another host, see README); hides your IP; not for Public instances.'),
    (T 'Custom server - type the links yourself (e.g. Twitch: trusted, but the stream is public).')
  )
  $ci = [array]::IndexOf($script:HostIds, $curId)
  $opts[$ci] = T '{0}  <- now' $opts[$ci]
  Say ''
  $i = Read-Choice (T 'Where should the stream go?') $opts $ci $false
  $id = $script:HostIds[$i]

  $ok = $true
  switch ($id) {
    'pc' { Set-SelfHostNameInteractive $c.SelfHost }
    'vps' { $ok = [bool](Set-VpsInteractive $c.Vps) }
    'custom' { $ok = [bool](Set-CustomInteractive $c) }
  }
  $chg = $false
  if ($ok -and $id -ne $cfgId) {
    # The typed-in custom links are kept ("CustomLinks") when Topaz takes over IngestUrl / PcUrl / ...
    if ($cfgId -eq 'custom') {
      $keep = [pscustomobject][ordered]@{ IngestUrl = "$(Get-Prop $c 'IngestUrl')"; PcUrl = "$(Get-Prop $c 'PcUrl')"; QuestUrl = "$(Get-Prop $c 'QuestUrl')"; VlcUrl = "$(Get-Prop $c 'VlcUrl')" }
      Set-HostField $c 'CustomLinks' $keep ([ref]$chg)
    }
    $c.Host = $id
    Sync-HostServerName $c $id ([ref]$chg)
  }
  [void](Initialize-HostConfig)
  if (($c | ConvertTo-Json -Depth 8 -Compress) -cne $was) {
    Lock-HostStep
    try { Save-Config $c } catch { Say (T '  Couldn''t save config.json: {0}' $_.Exception.Message) 'Red' }
  }
  $after = Get-HostProfile
  $changed = ($after.Id -ne $before.Id -or $after.IngestUrl -ne $before.IngestUrl -or $after.PcUrl -ne $before.PcUrl -or $after.QuestUrl -ne $before.QuestUrl)
  if ($ok) { Say (T '  Streaming via: {0}' $after.Name) 'Green' }
  else { Say (T '  Still streaming via: {0}' $after.Name) 'Green' }
  return [bool]$changed
}

# "New link": a new key / token for the active host, after asking. Saves config.json. $true = the link changed
# (the caller then updates the shown link and restarts the stream).
function Reset-StreamLink {
  $c = $script:Cfg
  [void](Initialize-HostConfig)
  $p = Get-HostProfile
  # (After a fallback to Topaz the new link is for Topaz, the host that really streams.)
  if ($script:HostP -and $script:HostP.Id -ne $p.Id) { $p = Get-HostProfile $script:HostP.Id }
  if ($p.Id -eq 'custom') {
    Say (T '  Your links were typed in by hand (custom server): change them in the host menu or in config.json.') 'Yellow'
    return $false
  }
  if ($p.Id -eq 'vps' -and "$(Get-Prop $c.Vps 'Role')" -eq 'guest') {
    Say (T '  This PC''s VPS link comes from a connection code: ask whoever manages the server for a new code.') 'Yellow'
    return $false
  }
  if (-not $script:Interactive) { return $false }
  Say (T '  A new link replaces the old one: the old link stops working (worlds and friends who have it need the new one).') 'Yellow'
  if (-not (Read-YesNoUi (T 'Make a new link? [y/N]') $false -Esc $false -Key 'newlink')) { Say (T '  The link stays as it is.') 'DarkGray'; return $false }
  Lock-HostStep
  $chg = $false
  switch ($p.Id) {
    'topaz' {
      $key = New-StreamKey
      Set-HostField $c 'StreamKey' $key ([ref]$chg)
      Set-TopazConfigLinks $c $key ([ref]$chg)
    }
    'pc' { $c.SelfHost.Token = New-LinkToken }
    'vps' {
      $c.Vps.Token = New-LinkToken
      # (New passwords too: a code given out for this PC's own link stops working.)
      $c.Vps.PublishPass = New-HostSecret 24
      $c.Vps.SrtPassphrase = New-HostSecret 32
    }
  }
  try { Save-Config $c } catch { Say (T '  Couldn''t save config.json: {0}' $_.Exception.Message) 'Red' }
  $np = Get-HostProfile $p.Id
  Say (T '  Your new link:  {0}' $np.PcUrl) 'Green'
  if ($p.Id -eq 'vps') {
    Say (T '  Your VPS must learn the new link: paste install.sh on the server again (the new files are below).') 'Yellow'
    Say (T '  (Its password changes too, so a code given out for this PC''s own link stops working.)') 'DarkGray'
    if (@(Get-VpsStreams $c.Vps).Count -gt 1) { Say (T '  Only this PC''s link changes: the other streams on the server keep theirs.') 'DarkGray' }
    Show-VpsBundle $c.Vps
  }
  return $true
}

# ================================================================== Part 2 - MediaMTX (the stream server for self-hosting)
# MediaMTX (github.com/bluenviron/mediamtx, MIT licence, one exe) takes the relay's stream in and hands it to the viewers
# over RTSP (PC: rtspt://), RTMP (Quest) and, if wanted, HLS. Out of the box it lets anyone publish and read every path
# and allows RTSP over UDP, so New-MediaMtxConfig always writes a locked-down config instead:
#   pc:  publish only from 127.0.0.1 / ::1 to live/<token>; anyone may read live/<token> and nothing else; every other
#        path is refused; RTSP over TCP only; RTMP on; HLS only on 127.0.0.1 (for Tailscale Funnel) and only when asked;
#        SRT, WebRTC, MoQ, API, metrics, pprof and playback off.
#   vps: publish only as the named user + password (from any IP) to live/<token>; SRT on, with a publish passphrase and a
#        separate read passphrase (so nobody reads over SRT); reads as above.
# Test-MediaMtxSecurity runs the real server on test ports and proves all of this with ffmpeg / ffprobe.

$script:MediaMtxVersion = 'v1.21.1'
$script:MediaMtxBaseUrl = 'https://github.com/bluenviron/mediamtx/releases/download/v1.21.1/'
$script:MediaMtxZip = 'mediamtx_v1.21.1_windows_amd64.zip'
# From the release's checksums.sha256 (checked 2026-09-28):
$script:MediaMtxZipSha256 = 'faa97974861eb75a68b5aa326c78e7e7a6f670b5ef191bace78e715130381f23'
$script:MediaMtxLinuxSha256 = @{
  amd64 = '653abc672a3e693f8d3b2717752492fdcfb8072291ec108d03d3dd857411b0ee'
  arm64 = '6a3aa635fb60ea9b8d566ec306f0a42ff1b6b52a3942bc2baffbe55880d4c3dd'
}
# mediamtx.exe inside that zip (so an installed copy can be checked without the zip):
$script:MediaMtxExeSha256 = '7de0b5c1060f716cc813c6fab302c938f1fe7faccbd92eba6567f3bf18c9054e'
$script:MediaMtxProc = $null
$script:MediaMtxHandle = $null
$script:MediaMtxExeChecked = $null
$script:FfmpegSrt = $null

# ------------------------------------------------------------------ small helpers
function Get-MtxSha256([string]$path) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $fs = [System.IO.File]::OpenRead($path)
  try { $h = $sha.ComputeHash($fs) } finally { $fs.Dispose(); $sha.Dispose() }
  return (-join ($h | ForEach-Object { $_.ToString('x2') }))
}

function ConvertTo-MtxYamlString([string]$v) { return ("'" + $v.Replace("'", "''") + "'") }

function Get-MtxSetting($s, [string]$name, $default) {
  $v = Get-Prop $s $name
  if ($null -eq $v -or "$v" -eq '') { return $default }
  return $v
}

function Get-MtxPort($s, [string]$name, [int]$default) {
  $n = 0
  if (-not [int]::TryParse("$(Get-MtxSetting $s $name $default)", [ref]$n) -or $n -lt 1 -or $n -gt 65535) {
    throw (T 'The port {0} in config.json must be a number from 1 to 65535.' $name)
  }
  return $n
}

# Secrets end up in URLs, the SRT streamid (fields split by ':') and YAML: only base64url characters are allowed.
function Assert-MtxSecret([string]$v, [string]$name, [int]$minLen, [int]$maxLen) {
  if ($v -notmatch '^[A-Za-z0-9_-]+$' -or $v.Length -lt $minLen -or $v.Length -gt $maxLen) {
    throw (T 'The {0} in config.json is missing or not valid (it needs {1} to {2} of the characters A-Z a-z 0-9 - _).' $name $minLen $maxLen)
  }
}

function New-MtxSecret([int]$bytes) {
  $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
  $b = New-Object byte[] $bytes
  $rng.GetBytes($b)
  $rng.Dispose()
  return ([Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_'))
}

function Format-MtxAddress([string]$bindHost, [int]$port) {
  if (-not $bindHost) { return ":$port" }
  if ($bindHost.Contains(':')) { return "[$bindHost]:$port" }
  return "${bindHost}:$port"
}

# The ports a generated config listens on: Proto, Port, Udp.
function Get-MtxPorts([string]$yml) {
  $list = @()
  foreach ($p in @('rtsp', 'rtmp', 'hls', 'srt')) {
    if ($yml -notmatch "(?m)^${p}:\s*(true|yes)\s*$") { continue }
    $m = [regex]::Match($yml, "(?m)^${p}Address:\s*'?(.*?):(\d+)'?\s*$")
    if ($m.Success) { $list += [pscustomobject]@{ Proto = $p; Port = [int]$m.Groups[2].Value; Udp = ($p -eq 'srt') } }
  }
  return $list
}

function Get-MtxBusyPorts($ports) {
  $ipg = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
  $tcp = @($ipg.GetActiveTcpListeners() | ForEach-Object { $_.Port })
  $udp = @($ipg.GetActiveUdpListeners() | ForEach-Object { $_.Port })
  return @(@($ports) | Where-Object { ($_.Udp -and ($udp -contains $_.Port)) -or ((-not $_.Udp) -and ($tcp -contains $_.Port)) })
}

# MediaMTX (and the test's ffmpeg) are put in a job that Windows closes when this window closes, so they never outlive it.
function Add-MtxToJob($proc) {
  # (VRCLM_DEBUG: log.txt notes the start.)
  if (Get-Command Write-StartLog -CommandType Function -ErrorAction SilentlyContinue) { try { Write-StartLog $proc.StartInfo } catch {} }
  # (The main script puts every program it starts into one such job.)
  if (Get-Command Add-ChildToJob -CommandType Function -ErrorAction SilentlyContinue) { Add-ChildToJob $proc; return }
  try {
    if (-not ('VRCLinkMaker.MtxJob' -as [type])) {
      Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace VRCLinkMaker {
  public static class MtxJob {
    [StructLayout(LayoutKind.Sequential)] struct Basic { public long A; public long B; public uint LimitFlags; public UIntPtr C; public UIntPtr D; public uint E; public UIntPtr F; public uint G; public uint H; }
    [StructLayout(LayoutKind.Sequential)] struct Io { public ulong A; public ulong B; public ulong C; public ulong D; public ulong E; public ulong F; }
    [StructLayout(LayoutKind.Sequential)] struct Ext { public Basic B; public Io I; public UIntPtr C; public UIntPtr D; public UIntPtr E; public UIntPtr F; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr a, string n);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr j, int c, ref Ext i, uint l);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
    static IntPtr job = IntPtr.Zero;
    public static bool Add(IntPtr process) {
      if (job == IntPtr.Zero) {
        IntPtr j = CreateJobObject(IntPtr.Zero, null);
        if (j == IntPtr.Zero) return false;
        Ext e = new Ext();
        e.B.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if (!SetInformationJobObject(j, 9, ref e, (uint)Marshal.SizeOf(typeof(Ext)))) return false;
        job = j;
      }
      return AssignProcessToJobObject(job, process);
    }
  }
}
'@
    }
    [void][VRCLinkMaker.MtxJob]::Add($proc.Handle)
  } catch {}
}

# Starts a MediaMTX with this config text (as <TempRoot>\<name>.yml, log in <TempRoot>\<name>-log.txt) and waits until
# its ports listen. Throws a clear message when it can't.
function Start-MtxProcess([string]$exe, [string]$yml, [string]$name, [int]$waitSec = 12) {
  if (-not $exe -or -not [System.IO.File]::Exists($exe)) { throw (T 'MediaMTX was not found ({0}).' $exe) }
  if (-not [System.IO.Directory]::Exists($script:TempRoot)) { [void][System.IO.Directory]::CreateDirectory($script:TempRoot) }
  $ymlPath = PathJoin $script:TempRoot "$name.yml"
  $logPath = PathJoin $script:TempRoot "$name-log.txt"
  $text = [regex]::Replace($yml, '(?m)^logDestinations:.*$', 'logDestinations: [file]')
  $logLine = 'logFile: ' + (ConvertTo-MtxYamlString $logPath)
  if ($text -match '(?m)^logFile:') { $text = [regex]::Replace($text, '(?m)^logFile:.*$', $logLine.Replace('$', '$$')) }
  else { $text += "`n$logLine`n" }
  $ports = @(Get-MtxPorts $text)
  $busy = @(Get-MtxBusyPorts $ports)
  if ($busy.Count -gt 0) {
    throw (T 'MediaMTX can''t start: port {0} is already used by another program. Close that program, or pick another port in config.json.' (($busy | ForEach-Object { "$($_.Port)" }) -join ', '))
  }
  [System.IO.File]::WriteAllText($ymlPath, $text, (New-Object System.Text.UTF8Encoding($false)))
  try { [System.IO.File]::Delete($logPath) } catch {}
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe
  $psi.Arguments = ConvertTo-CmdArg $ymlPath
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.WorkingDirectory = $script:TempRoot
  $p = [System.Diagnostics.Process]::Start($psi)
  Add-MtxToJob $p
  $h = [pscustomobject]@{ Proc = $p; Name = $name; Yml = $ymlPath; Log = $logPath; Ports = $ports
    Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() }
  $deadline = (Get-Date).AddSeconds($waitSec)
  while ($true) {
    if ($p.HasExited) { break }
    if (@(Get-MtxBusyPorts $ports).Count -eq $ports.Count) { return $h }
    if ((Get-Date) -gt $deadline) { break }
    Start-Sleep -Milliseconds 150
  }
  $timedOut = -not $p.HasExited
  Stop-MtxProcess $h
  $said = Get-MtxLogText $h
  $m = [regex]::Match($said, '(?i)listen (?:tcp|udp)\S* [^\s]*?:(\d+): bind')
  if ($m.Success -or $said -match '(?i)Only one usage of each socket address|address already in use') {
    $port = '?'
    if ($m.Success) { $port = $m.Groups[1].Value }
    throw (T 'MediaMTX can''t start: port {0} is already used by another program. Close that program, or pick another port in config.json.' $port)
  }
  if ($timedOut) { throw (T 'MediaMTX didn''t open its ports in time. Its log: {0}' $logPath) }
  $last = @($said -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1
  throw (T 'MediaMTX stopped right away: {0}' "$last".Trim())
}

function Get-MtxLogText($h) {
  $s = ''
  try {
    if ([System.IO.File]::Exists($h.Log)) {
      # MediaMTX still has it open for writing.
      $fs = New-Object System.IO.FileStream($h.Log, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
      try { $s += (New-Object System.IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    }
  } catch {}
  try { if ($h.Out.Wait(1500)) { $s += "`n" + $h.Out.Result } } catch {}
  try { if ($h.Err.Wait(1500)) { $s += "`n" + $h.Err.Result } } catch {}
  return $s
}

function Stop-MtxProcess($h) {
  if (-not $h -or -not $h.Proc) { return }
  try { if (-not $h.Proc.HasExited) { $h.Proc.Kill(); [void]$h.Proc.WaitForExit(5000) } } catch {}
}

# ------------------------------------------------------------------ the exe
function Get-MediaMtxDir { return (PathJoin (PathJoin $script:ToolDir 'bin') 'mediamtx') }

# (Save-WebFile in VRChatLinkMaker.ps1: the same download with progress, also used for rqbit.)
function Save-MtxDownload([string]$url, [string]$dest) { Save-WebFile $url $dest 'Downloading MediaMTX... {0}%' }

# Path to mediamtx.exe (<ToolDir>\bin\mediamtx\), or $null. Downloads it only after asking, and only the pinned,
# checksum-verified release.
function Get-MediaMtxExe([bool]$canAsk) {
  $dir = Get-MediaMtxDir
  $exe = PathJoin $dir 'mediamtx.exe'
  if ([System.IO.File]::Exists($exe)) {
    if ($script:MediaMtxExeChecked -eq $exe) { return $exe }
    $ok = $false
    try { $ok = ((Get-MtxSha256 $exe) -eq $script:MediaMtxExeSha256) } catch {}
    if ($ok) { $script:MediaMtxExeChecked = $exe; return $exe }
    Say (T 'The MediaMTX in {0} is not the expected version ({1}) or is damaged.' $dir $script:MediaMtxVersion) 'Yellow'
  }
  if (-not $canAsk) { return $null }
  Say (T 'Streaming from your own PC or server needs MediaMTX, a free stream server (one program, nothing is installed).') 'Cyan'
  if (-not (Read-YesNoUi (T 'Download MediaMTX (28 MB) from github.com/bluenviron/mediamtx? [Y/n]') $true -Esc $false)) { return $null }
  $zip = PathJoin $script:TempRoot 'mediamtx-download.zip'
  try {
    if (-not [System.IO.Directory]::Exists($script:TempRoot)) { [void][System.IO.Directory]::CreateDirectory($script:TempRoot) }
    Save-MtxDownload ($script:MediaMtxBaseUrl + $script:MediaMtxZip) $zip
    if ((Get-MtxSha256 $zip) -ne $script:MediaMtxZipSha256) {
      Say (T 'The download doesn''t match the expected checksum, so it was not used. Try again later.') 'Red'
      return $null
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $tmp = $exe + '.new'
    $z = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
      foreach ($e in $z.Entries) {
        if ($e.FullName -eq 'mediamtx.exe') { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $tmp, $true) }
        elseif ($e.FullName -eq 'LICENSE') { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, (PathJoin $dir 'LICENSE.txt'), $true) }
      }
    } finally { $z.Dispose() }
    if (-not [System.IO.File]::Exists($tmp) -or (Get-MtxSha256 $tmp) -ne $script:MediaMtxExeSha256) {
      try { [System.IO.File]::Delete($tmp) } catch {}
      Say (T 'The download doesn''t match the expected checksum, so it was not used. Try again later.') 'Red'
      return $null
    }
    if ([System.IO.File]::Exists($exe)) { [System.IO.File]::Delete($exe) }
    [System.IO.File]::Move($tmp, $exe)
    $script:MediaMtxExeChecked = $exe
    Say (T 'MediaMTX {0} is ready.' $script:MediaMtxVersion) 'Green'
    return $exe
  } catch {
    Clear-StatusLine
    Say (T 'MediaMTX could not be downloaded: {0}' $_.Exception.Message) 'Red'
    return $null
  } finally { try { [System.IO.File]::Delete($zip) } catch {} }
}

function Test-FfmpegHasSrt {
  if ($null -ne $script:FfmpegSrt) { return $script:FfmpegSrt }
  $ok = $false
  if ($script:FFmpeg) {
    try {
      $r = Invoke-Capture $script:FFmpeg @('-hide_banner', '-nostdin', '-protocols')
      $txt = "$($r.Out)`n$($r.Err)"
      $i = $txt.IndexOf('Output:')
      if ($i -ge 0) { $ok = ($txt.Substring($i) -match '(?m)^\s*srt\s*$') }
    } catch {}
  }
  $script:FfmpegSrt = $ok
  return $ok
}

# ------------------------------------------------------------------ the config
# $mode 'pc' ($s = the SelfHost settings) or 'vps' ($s = the Vps settings) -> the text of mediamtx.yml.
# $bindHost: '' = listen on every address (what streaming needs); the tests pass 127.0.0.1 or the LAN IP.
# The password the relay publishes to this PC's MediaMTX with: config.json's SelfHost.PublishPass if set, else a new
# random one per run (kept in memory only).
$script:PcPublishPass = ''
function Get-PcPublishPass($s) {
  $p = "$(Get-Prop $s 'PublishPass')"
  # (It goes into the publish URL and MediaMTX's config as is: only letters, digits, - and _.)
  if ($p -match '^[A-Za-z0-9_-]{12,64}$') { return $p }
  if (-not $script:PcPublishPass) { $script:PcPublishPass = New-MtxSecret 18 }
  return $script:PcPublishPass
}

function New-MediaMtxConfig([string]$mode, $s, [string]$bindHost = '') {
  if ($mode -ne 'pc' -and $mode -ne 'vps') { throw "New-MediaMtxConfig: unknown mode '$mode'" }
  # The stream paths it serves: pc one (the relay's); vps this PC's own stream and the further ones (Get-VpsStreams).
  if ($mode -eq 'vps') { $streams = @(Get-VpsStreams $s) }
  else { $streams = @([pscustomobject]@{ Token = "$(Get-Prop $s 'Token')" }) }
  $seenTok = New-VpsSeenSet
  foreach ($st in $streams) {
    Assert-MtxSecret $st.Token 'Token' 22 128
    if (-not $seenTok.Add($st.Token)) { throw (T 'Two streams in config.json have the same {0}.' 'Token') }
  }
  $path = "live/$($streams[0].Token)"
  $rtspPort = Get-MtxPort $s 'RtspPort' 8554
  $rtmpPort = Get-MtxPort $s 'RtmpPort' 1935
  $hlsPort = Get-MtxPort $s 'HlsPort' 8888
  $hls = ("$(Get-MtxSetting $s 'Hls' $false)" -match '^(?i)(true|yes|on|1)$')
  $maxReaders = 10
  if ($mode -eq 'vps') { $maxReaders = 30 }
  $n = 0
  if ([int]::TryParse("$(Get-MtxSetting $s 'MaxReaders' $maxReaders)", [ref]$n) -and $n -ge 1) { $maxReaders = $n }
  $srtPort = 0
  if ($mode -eq 'vps') {
    $readPass = "$(Get-Prop $s 'ReadPassphrase')"
    Assert-MtxSecret $readPass 'ReadPassphrase' 10 79
    $seenUser = New-VpsSeenSet
    foreach ($st in $streams) {
      Assert-MtxSecret $st.PublishUser 'PublishUser' 1 64
      Assert-MtxSecret $st.PublishPass 'PublishPass' 12 128
      Assert-MtxSecret $st.SrtPassphrase 'SrtPassphrase' 10 79      # SRT allows 10..79 characters
      if ($st.SrtPassphrase -ceq $readPass) { throw (T 'SrtPassphrase and ReadPassphrase in config.json must be different.') }
      if (-not $seenUser.Add($st.PublishUser.ToLowerInvariant())) { throw (T 'Two streams in config.json have the same {0}.' 'PublishUser') }
    }
    $srtPort = Get-MtxPort $s 'SrtPort' 8890
  }
  $used = @($rtspPort, $rtmpPort)
  if ($hls) { $used += $hlsPort }
  if (@($used | Select-Object -Unique).Count -ne $used.Count) { throw (T 'The ports in config.json must all be different.') }
  $q = ConvertTo-MtxYamlString $path
  $L = New-Object System.Collections.Generic.List[string]
  $L.Add("# Made by VRChat Link Maker for MediaMTX $($script:MediaMtxVersion), mode '$mode'. The tool rewrites it: change config.json instead.")
  $L.Add('logLevel: info')
  $L.Add('logDestinations: [stdout]')
  $L.Add('logFile: mediamtx.log')
  $L.Add('readTimeout: 10s')
  $L.Add('writeTimeout: 10s')
  # Counted in RTP packets per viewer: 512 (~700 KB) is less than one keyframe at 6+ Mbps, and the tail of it was dropped.
  $L.Add('writeQueueSize: 4096')
  $L.Add('authMethod: internal')
  $L.Add('authInternalUsers:')
  if ($mode -eq 'pc') {
    # A password too, made new for every run (never saved): a program on this PC, or a tunnel that makes internet
    # visitors look local (playit, ngrok, Tailscale...), could otherwise take the stream over.
    $L.Add('  # Only this PC (the relay, with this run''s password) may publish, and only to the stream path.')
    $L.Add('  - user: vrclm')
    $L.Add('    pass: ' + (ConvertTo-MtxYamlString (Get-PcPublishPass $s)))
    $L.Add("    ips: ['127.0.0.1', '::1']")
    $L.Add('    permissions:')
    $L.Add('      - action: publish')
    $L.Add("        path: $q")
  } else {
    $L.Add('  # Each stream: only its own user may publish (from any IP: home IPs change), and only to its own path.')
    foreach ($st in $streams) {
      $L.Add('  - user: ' + (ConvertTo-MtxYamlString $st.PublishUser))
      $L.Add('    pass: ' + (ConvertTo-MtxYamlString $st.PublishPass))
      $L.Add('    ips: []')
      $L.Add('    permissions:')
      $L.Add('      - action: publish')
      $L.Add('        path: ' + (ConvertTo-MtxYamlString "live/$($st.Token)"))
    }
  }
  $L.Add('  # Viewers (anyone with a link) may only read the stream path(s). No playback, api, metrics or pprof for anyone.')
  $L.Add('  - user: any')
  $L.Add("    pass: ''")
  $L.Add('    ips: []')
  $L.Add('    permissions:')
  foreach ($st in $streams) {
    $L.Add('      - action: read')
    $L.Add('        path: ' + (ConvertTo-MtxYamlString "live/$($st.Token)"))
  }
  $L.Add('api: false')
  $L.Add('metrics: false')
  $L.Add('pprof: false')
  $L.Add('playback: false')
  $L.Add('rtsp: true')
  $L.Add('rtspTransports: [tcp]')
  $L.Add("rtspEncryption: 'no'")
  $L.Add('rtspAddress: ' + (ConvertTo-MtxYamlString (Format-MtxAddress $bindHost $rtspPort)))
  $L.Add('rtspAuthMethods: [basic]')
  $L.Add('rtmp: true')
  $L.Add("rtmpEncryption: 'no'")
  $L.Add('rtmpAddress: ' + (ConvertTo-MtxYamlString (Format-MtxAddress $bindHost $rtmpPort)))
  if ($hls) {
    # On this PC HLS is only for Tailscale Funnel, which connects locally; on a VPS it is public.
    $hlsHost = $bindHost
    if ($mode -eq 'pc' -and -not $hlsHost) { $hlsHost = '127.0.0.1' }
    $L.Add('hls: true')
    $L.Add('hlsAddress: ' + (ConvertTo-MtxYamlString (Format-MtxAddress $hlsHost $hlsPort)))
    $L.Add('hlsEncryption: false')
    $L.Add('hlsAllowOrigins: []')
    $L.Add('hlsAlwaysRemux: true')
    $L.Add('hlsVariant: mpegts')          # fMP4 / low-latency HLS plays without sound in VRChat
    $L.Add('hlsSegmentCount: 7')
    $L.Add('hlsSegmentDuration: 1s')
    $L.Add("hlsDirectory: ''")
  } else {
    $L.Add('hls: false')
  }
  $L.Add('webrtc: false')
  if ($mode -eq 'vps') {
    $L.Add('srt: true')
    $L.Add('srtAddress: ' + (ConvertTo-MtxYamlString (Format-MtxAddress $bindHost $srtPort)))
  } else {
    $L.Add('srt: false')
  }
  $L.Add('moq: false')
  $L.Add('pathDefaults:')
  $L.Add('  source: publisher')
  if ($hls) {
    # The always-on HLS muxer takes one reader place itself (every HLS viewer then takes one too).
    $L.Add('  # MaxReaders viewers + 1 place for the HLS muxer.')
    $L.Add("  maxReaders: $($maxReaders + 1)")
  } else {
    $L.Add("  maxReaders: $maxReaders")
  }
  $L.Add('  overridePublisher: true')
  $L.Add('  record: false')
  if ($mode -eq 'vps') {
    $L.Add('  # Nobody is given this one: reading over SRT is effectively off.')
    $L.Add('  srtReadPassphrase: ' + (ConvertTo-MtxYamlString $readPass))
  }
  $L.Add('# The only paths. Anything else is "not configured" and refused (besides the permissions above).')
  $L.Add('paths:')
  foreach ($st in $streams) {
    $L.Add('  ' + (ConvertTo-MtxYamlString "live/$($st.Token)") + ':')
    # (Each stream sends with its own SRT passphrase.)
    if ($mode -eq 'vps') { $L.Add('    srtPublishPassphrase: ' + (ConvertTo-MtxYamlString $st.SrtPassphrase)) }
  }
  return (($L -join "`n") + "`n")
}

# ------------------------------------------------------------------ start / stop
function Start-MediaMtx([string]$exe, [string]$yml) {
  Stop-MediaMtx
  # One left over from a run that crashed would hold the ports.
  try {
    foreach ($old in @(Get-Process -Name 'mediamtx' -ErrorAction SilentlyContinue)) {
      $pp = $null
      try { $pp = $old.Path } catch {}
      if ($pp -and ($pp -eq $exe)) { try { $old.Kill(); [void]$old.WaitForExit(3000) } catch {} }
    }
  } catch {}
  $h = Start-MtxProcess $exe $yml 'mediamtx'
  $script:MediaMtxHandle = $h
  $script:MediaMtxProc = $h.Proc
  return $h.Proc
}

function Stop-MediaMtx {
  if ($script:MediaMtxHandle) {
    Stop-MtxProcess $script:MediaMtxHandle
    # Its config holds the link's secret path, its log the viewers' addresses: neither is needed once it stopped.
    foreach ($f in @($script:MediaMtxHandle.Yml, $script:MediaMtxHandle.Log)) { if ($f) { try { [System.IO.File]::Delete($f) } catch {} } }
  }
  elseif ($script:MediaMtxProc) { try { if (-not $script:MediaMtxProc.HasExited) { $script:MediaMtxProc.Kill(); [void]$script:MediaMtxProc.WaitForExit(5000) } } catch {} }
  $script:MediaMtxHandle = $null
  $script:MediaMtxProc = $null
}

# ------------------------------------------------------------------ security test
function Invoke-MtxTimed([string]$exe, [string[]]$argv, [int]$ms) {
  $psi = New-StartInfo $exe $argv ''
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.RedirectStandardInput = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  Add-MtxToJob $p
  try { $p.StandardInput.Close() } catch {}
  $o = $p.StandardOutput.ReadToEndAsync()
  $e = $p.StandardError.ReadToEndAsync()
  $timedOut = -not $p.WaitForExit($ms)
  if ($timedOut) { try { $p.Kill() } catch {}; [void]$p.WaitForExit(3000) } else { $p.WaitForExit() }
  $out = ''; $err = ''
  try { if ($o.Wait(2000)) { $out = $o.Result } } catch {}
  try { if ($e.Wait(2000)) { $err = $e.Result } } catch {}
  $code = -999
  if (-not $timedOut) { $code = $p.ExitCode }
  return [pscustomobject]@{ ExitCode = $code; Out = $out; Err = $err; TimedOut = $timedOut }
}

function Start-MtxBackground([string]$exe, [string[]]$argv) {
  $psi = New-StartInfo $exe $argv ''
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.RedirectStandardInput = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  Add-MtxToJob $p
  try { $p.StandardInput.Close() } catch {}
  return [pscustomobject]@{ Proc = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() }
}

function Stop-MtxBackground($b) {
  if (-not $b) { return }
  try { if (-not $b.Proc.HasExited) { $b.Proc.Kill(); [void]$b.Proc.WaitForExit(3000) } } catch {}
}

function Get-MtxLastLine([string]$s) {
  $l = @($s -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1
  return (Get-ShortText "$l".Trim() 150)
}

# ffmpeg args for a small synthetic test stream (picture + sound).
function Get-MtxTestSource([int]$seconds) {
  return @('-hide_banner', '-nostdin', '-v', 'error', '-re', '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', "$seconds",
    '-c:v', 'libx264', '-preset', 'ultrafast', '-tune', 'zerolatency', '-pix_fmt', 'yuv420p', '-g', '24', '-b:v', '300k',
    '-c:a', 'aac', '-b:a', '64k', '-ar', '48000')
}

function Get-MtxOutArgs([string]$url) {
  if ($url -match '^srt://') { return @('-f', 'mpegts', $url) }
  if ($url -match '^rtsp://') { return @('-f', 'rtsp', '-rtsp_transport', 'tcp', $url) }
  return @('-f', 'flv', $url)
}

# A publish that runs its full few seconds = accepted. Refused ones end early with an error.
function Test-MtxPublish([string]$url) {
  $r = Invoke-MtxTimed $script:FFmpeg ((Get-MtxTestSource 3) + (Get-MtxOutArgs $url)) 20000
  $ok = ($r.ExitCode -eq 0)
  $d = 'ffmpeg exit 0 (ran 3 s)'
  if (-not $ok) { $d = "ffmpeg exit $($r.ExitCode): " + (Get-MtxLastLine $r.Err) }
  return [pscustomobject]@{ Ok = $ok; Detail = $d }
}

function Test-MtxRead([string]$url, [string[]]$pre = @(), [int]$ms = 15000) {
  $argv = @('-hide_banner', '-v', 'error') + $pre + @('-show_entries', 'stream=codec_type', '-of', 'csv=p=0', $url)
  $r = Invoke-MtxTimed $script:FFprobe $argv $ms
  $ok = ($r.ExitCode -eq 0 -and $r.Out -match 'video')
  if ($ok) { $d = 'ffprobe: ' + ((($r.Out -split '\s+') | Where-Object { $_ }) -join ',') }
  elseif ($r.TimedOut) { $d = 'ffprobe timed out' }
  else { $d = "ffprobe exit $($r.ExitCode): " + (Get-MtxLastLine $r.Err) }
  return [pscustomobject]@{ Ok = $ok; Detail = $d }
}

function Wait-MtxReadable([string]$url, [int]$sec) {
  $deadline = (Get-Date).AddSeconds($sec)
  do {
    $r = Test-MtxRead $url @('-rtsp_transport', 'tcp', '-timeout', '4000000') 8000
    if ($r.Ok) { return $r }
    Start-Sleep -Milliseconds 400
  } while ((Get-Date) -lt $deadline)
  return $r
}

# Raw RTSP ANNOUNCE (the first step of publishing) from a chosen local address -> the status code MediaMTX answers.
function Send-MtxRtspAnnounce([string]$srcIp, [string]$dstIp, [int]$port, [string]$path) {
  $sdp = "v=0`r`no=- 0 0 IN IP4 127.0.0.1`r`ns=vrclm-test`r`nc=IN IP4 0.0.0.0`r`nt=0 0`r`nm=video 0 RTP/AVP 96`r`n" +
    "a=rtpmap:96 H264/90000`r`na=fmtp:96 packetization-mode=1`r`na=control:trackID=0`r`n"
  $req = "ANNOUNCE rtsp://${dstIp}:$port/$path RTSP/1.0`r`nCSeq: 1`r`nUser-Agent: vrclm-test`r`nContent-Type: application/sdp`r`n" +
    "Content-Length: $($sdp.Length)`r`n`r`n$sdp"
  $sock = New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Stream, [System.Net.Sockets.ProtocolType]::Tcp)
  try {
    $sock.ReceiveTimeout = 5000
    $sock.SendTimeout = 5000
    $sock.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($srcIp), 0)))
    $sock.Connect([System.Net.IPAddress]::Parse($dstIp), $port)
    $b = [System.Text.Encoding]::ASCII.GetBytes($req)
    [void]$sock.Send($b)
    $buf = New-Object byte[] 4096
    $got = ''
    while ($got -notmatch "`r`n`r`n") {
      $n = $sock.Receive($buf)
      if ($n -le 0) { break }
      $got += [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
    }
    $m = [regex]::Match($got, '^RTSP/1\.0 (\d{3})[^\r\n]*')
    if ($m.Success) { return [pscustomobject]@{ Code = [int]$m.Groups[1].Value; Text = $m.Value } }
    return [pscustomobject]@{ Code = -1; Text = 'no RTSP answer' }
  } catch {
    return [pscustomobject]@{ Code = -1; Text = $_.Exception.Message }
  } finally { $sock.Close() }
}

function Get-MtxHttp([string]$url, [int]$ms = 6000) {
  try {
    $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($url)
    $req.Timeout = $ms
    $req.ReadWriteTimeout = $ms
    $req.Proxy = $null
    $resp = $null
    try { $resp = $req.GetResponse() } catch [System.Net.WebException] { if ($_.Exception.Response) { $resp = $_.Exception.Response } else { throw } }
    try {
      $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
      $t = $sr.ReadToEnd()
      return [pscustomobject]@{ Status = [int]$resp.StatusCode; Text = $t }
    } finally { $resp.Close() }
  } catch { return [pscustomobject]@{ Status = 0; Text = $_.Exception.Message } }
}

# What a process listens on, from netstat (TCP: listening sockets; UDP: bound sockets). Works in every Windows language.
function Get-MtxProcListeners([int]$procId) {
  $tcp = @(); $udp = @()
  $lines = @()
  try { $lines = @(& netstat.exe -ano) } catch {}
  foreach ($l in $lines) {
    $m = [regex]::Match($l, '^\s*TCP\s+(\S+)\s+(?:0\.0\.0\.0:0|\[::\]:0)\s+\S+\s+(\d+)\s*$')
    if ($m.Success -and [int]$m.Groups[2].Value -eq $procId) { $tcp += $m.Groups[1].Value; continue }
    $m = [regex]::Match($l, '^\s*UDP\s+(\S+)\s+\*:\*\s+(\d+)\s*$')
    if ($m.Success -and [int]$m.Groups[2].Value -eq $procId) { $udp += $m.Groups[1].Value }
  }
  return [pscustomobject]@{ Tcp = @($tcp | Sort-Object -Unique); Udp = @($udp | Sort-Object -Unique) }
}

function Get-MtxFreePort([System.Collections.Generic.List[int]]$taken) {
  $ipg = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
  $busy = @($ipg.GetActiveTcpListeners() | ForEach-Object { $_.Port }) + @($ipg.GetActiveUdpListeners() | ForEach-Object { $_.Port })
  $rnd = New-Object System.Random
  for ($i = 0; $i -lt 200; $i++) {
    $p = $rnd.Next(20000, 40000)
    if (($busy -notcontains $p) -and -not $taken.Contains($p)) { $taken.Add($p); return $p }
  }
  throw 'no free test port'
}

# Would listening on the LAN IP make Windows Firewall pop up its "allow access?" question? (Read-only check.)
function Test-MtxFirewallQuiet {
  try {
    $cats = @(Get-NetConnectionProfile -ErrorAction Stop | ForEach-Object { "$($_.NetworkCategory)" })
    foreach ($c in $cats) {
      $name = $c
      if ($c -eq 'DomainAuthenticated') { $name = 'Domain' }
      $fw = Get-NetFirewallProfile -Name $name -ErrorAction Stop
      if ("$($fw.Enabled)" -eq 'True' -and "$($fw.NotifyOnListen)" -ne 'False') { return $false }
    }
    return ($cats.Count -gt 0)
  } catch { return $false }
}

# Runs the generated pc (and vps) config on test ports and proves the lock-down. -> rows (Name, Ok, Detail);
# Ok = the outcome was the safe / expected one. $lanIp: also prove that publishing from that address is refused
# (skipped when Windows Firewall would ask about it). $vps: also test the VPS config (needs ffmpeg with SRT).
function Test-MediaMtxSecurity([string]$exe, [string]$lanIp = '', [bool]$vps = $true) {
  $rows = New-Object System.Collections.ArrayList
  $add = { param($n, $o, $d) [void]$rows.Add([pscustomobject]@{ Name = $n; Ok = [bool]$o; Detail = "$d" }) }
  if (-not $script:FFmpeg) { $script:FFmpeg = Find-Exe 'ffmpeg' }
  if (-not $script:FFprobe -and $script:FFmpeg) {
    $sib = PathJoin ([System.IO.Path]::GetDirectoryName($script:FFmpeg)) 'ffprobe.exe'
    if ([System.IO.File]::Exists($sib)) { $script:FFprobe = $sib } else { $script:FFprobe = Find-Exe 'ffprobe' }
  }
  if (-not $script:FFmpeg -or -not $script:FFprobe) { & $add 'ffmpeg and ffprobe found' $false 'missing'; return $rows.ToArray() }
  $taken = New-Object System.Collections.Generic.List[int]
  $lo = '127.0.0.1'
  $bg = New-Object System.Collections.ArrayList
  $h = $null

  # ---------------- this PC
  $tok = New-MtxSecret 16
  $s = [pscustomobject]@{ Token = $tok; RtspPort = (Get-MtxFreePort $taken); RtmpPort = (Get-MtxFreePort $taken); HlsPort = (Get-MtxFreePort $taken)
    Hls = $true; MaxReaders = 50; PublishPass = (New-MtxSecret 18) }
  $cred = "?user=vrclm&pass=$($s.PublishPass)"
  $rtsp = "rtsp://${lo}:$($s.RtspPort)/live/$tok"
  $rtmp = "rtmp://${lo}:$($s.RtmpPort)/live/$tok"
  $hlsUrl = "http://${lo}:$($s.HlsPort)/live/$tok/index.m3u8"
  $tcpOpt = @('-rtsp_transport', 'tcp', '-timeout', '5000000')
  try {
    $yml = New-MediaMtxConfig 'pc' $s $lo
    try { $h = Start-MtxProcess $exe $yml 'mediamtx-test-pc'; & $add 'pc: MediaMTX accepts the config and starts' $true ("pid $($h.Proc.Id)") }
    catch { & $add 'pc: MediaMTX accepts the config and starts' $false $_.Exception.Message; return $rows.ToArray() }

    $want = @("${lo}:$($s.RtspPort)", "${lo}:$($s.RtmpPort)", "${lo}:$($s.HlsPort)") | Sort-Object
    $got = Get-MtxProcListeners $h.Proc.Id
    $okL = ((($got.Tcp | Sort-Object) -join ' ') -eq ($want -join ' ')) -and $got.Udp.Count -eq 0
    & $add 'pc: listens only on the RTSP, RTMP and HLS ports (no UDP, SRT, WebRTC, MoQ, API)' $okL ("TCP: $($got.Tcp -join ', '); UDP: $(if ($got.Udp.Count) { $got.Udp -join ', ' } else { 'none' })")

    $r = Send-MtxRtspAnnounce $lo $lo $s.RtspPort "live/$tok"
    & $add 'pc: publish without the password is refused, even from 127.0.0.1 (RTSP handshake)' ($r.Code -eq 401 -or $r.Code -eq 403) $r.Text
    $r = Send-MtxRtspAnnounce '127.0.0.2' $lo $s.RtspPort "live/$tok"
    & $add 'pc: publish from another address (127.0.0.2) is refused' ($r.Code -eq 401 -or $r.Code -eq 403) $r.Text
    $r = Send-MtxRtspAnnounce $lo $lo $s.RtspPort 'live/other'
    & $add 'pc: publish handshake to another path (live/other) is refused' ($r.Code -ne 200) $r.Text

    foreach ($bad in @("rtmp://${lo}:$($s.RtmpPort)/live/other", "rtsp://${lo}:$($s.RtspPort)/live/other", "rtmp://${lo}:$($s.RtmpPort)/live/${tok}x", "rtmp://${lo}:$($s.RtmpPort)/other/$tok")) {
      $r = Test-MtxPublish $bad
      & $add ("pc: publish to another path is refused: " + ($bad -replace [regex]::Escape($tok), '<token>')) (-not $r.Ok) $r.Detail
    }

    # The real publisher, like the relay: RTMP from 127.0.0.1.
    $r = Test-MtxPublish $rtmp
    & $add 'pc: RTMP publish from 127.0.0.1 without the password is refused' (-not $r.Ok) $r.Detail
    $pub = Start-MtxBackground $script:FFmpeg ((Get-MtxTestSource 600) + (Get-MtxOutArgs ($rtmp + $cred)))
    [void]$bg.Add($pub)
    $r = Wait-MtxReadable $rtsp 15
    & $add 'pc: publish over RTMP from 127.0.0.1 to live/<token> with the password works' $r.Ok $r.Detail

    $r = Test-MtxRead $rtsp $tcpOpt
    & $add 'pc: read over RTSP/TCP (what rtspt:// does) works' $r.Ok $r.Detail
    $r = Test-MtxRead $rtsp @('-timeout', '5000000') 25000
    & $add 'pc: read over rtsp:// with default transports (UDP refused, falls back to TCP, like Quest) works' $r.Ok $r.Detail
    $r = Test-MtxRead $rtmp @('-rw_timeout', '5000000')
    & $add 'pc: read over RTMP (Quest link) works' $r.Ok $r.Detail
    foreach ($qs in @('?pause', '?retry=-1&pause', '?retry=-1?next', '?vrclm=back30')) {
      $r = Test-MtxRead ($rtsp + $qs) $tcpOpt
      & $add "pc: read over RTSP/TCP with $qs works (query ignored)" $r.Ok $r.Detail
    }
    foreach ($qs in @('?pause', '?retry=-1&play')) {
      $r = Test-MtxRead ($rtmp + $qs) @('-rw_timeout', '5000000')
      & $add "pc: read over RTMP with $qs works (query ignored)" $r.Ok $r.Detail
    }

    $hv = $null
    $deadline = (Get-Date).AddSeconds(12)
    do { $hv = Get-MtxHttp $hlsUrl; if ($hv.Status -eq 200) { break }; Start-Sleep -Milliseconds 500 } while ((Get-Date) -lt $deadline)
    $d = "HTTP $($hv.Status)"
    $okH = $false
    if ($hv.Status -eq 200) {
      $var = [regex]::Match($hv.Text, '(?m)^([^#\s][^\r\n]*\.m3u8[^\r\n]*)$')
      if ($var.Success) {
        $mp = Get-MtxHttp ("http://${lo}:$($s.HlsPort)/live/$tok/" + $var.Groups[1].Value.Trim())
        $okH = ($mp.Status -eq 200 -and $mp.Text -match '(?m)\.ts(\?|$)')
        $d += "; media playlist HTTP $($mp.Status), MPEG-TS segments: $($mp.Text -match '(?m)\.ts(\?|$)')"
      }
    }
    & $add 'pc: read over HLS (index.m3u8, MPEG-TS segments) works' $okH $d
    $r = Test-MtxRead ($hlsUrl + '?pause') @('-rw_timeout', '8000000') 20000
    & $add 'pc: read over HLS with ?pause works (query ignored)' $r.Ok $r.Detail

    $r = Test-MtxRead $rtsp @('-rtsp_transport', 'udp', '-timeout', '5000000')
    & $add 'pc: read over RTSP with UDP only is refused' (-not $r.Ok) $r.Detail
    $others = @('live/other', "live/${tok}x", "live/$tok/extra", 'live', $tok, "other/$tok")
    if ($tok.ToUpperInvariant() -cne $tok) { $others += "live/$($tok.ToUpperInvariant())" }
    foreach ($op in $others) {
      $r = Test-MtxRead "rtsp://${lo}:$($s.RtspPort)/$op" $tcpOpt
      & $add ("pc: RTSP read of another path is refused: " + ($op -creplace [regex]::Escape($tok), '<token>' -creplace [regex]::Escape($tok.ToUpperInvariant()), '<TOKEN>')) (-not $r.Ok) $r.Detail
    }
    $r = Test-MtxRead "rtmp://${lo}:$($s.RtmpPort)/live/other" @('-rw_timeout', '5000000')
    & $add 'pc: RTMP read of another path (live/other) is refused' (-not $r.Ok) $r.Detail
    $hv = Get-MtxHttp "http://${lo}:$($s.HlsPort)/live/other/index.m3u8"
    & $add 'pc: HLS read of another path (live/other) is refused' ($hv.Status -ne 200) ("HTTP $($hv.Status)")
    $hv = Get-MtxHttp "http://${lo}:$($s.HlsPort)/"
    & $add 'pc: HLS root shows no listing' ($hv.Status -ne 200 -or $hv.Text -notmatch [regex]::Escape($tok)) ("HTTP $($hv.Status)")

  } finally {
    foreach ($b in @($bg)) { Stop-MtxBackground $b }
    $bg.Clear()
    Stop-MtxProcess $h
    $h = $null
  }

  # ---------------- maxReaders, on its own instance (HLS on, so the muxer's own place is accounted for too)
  $s3 = [pscustomobject]@{ Token = $tok; RtspPort = (Get-MtxFreePort $taken); RtmpPort = (Get-MtxFreePort $taken); HlsPort = (Get-MtxFreePort $taken)
    Hls = $true; MaxReaders = 2 }
  $rtsp3 = "rtsp://${lo}:$($s3.RtspPort)/live/$tok"
  try {
    $h = Start-MtxProcess $exe (New-MediaMtxConfig 'pc' $s3 $lo) 'mediamtx-test-max'
    $pub = Start-MtxBackground $script:FFmpeg ((Get-MtxTestSource 600) + (Get-MtxOutArgs "rtmp://${lo}:$($s3.RtmpPort)/live/${tok}?user=vrclm&pass=$(Get-PcPublishPass $s3)"))
    [void]$bg.Add($pub)
    [void](Wait-MtxReadable $rtsp3 15)
    Start-Sleep -Seconds 2   # the probe's own place frees up
    $readers = @()
    foreach ($i in 1..2) {
      $rd = Start-MtxBackground $script:FFmpeg @('-hide_banner', '-nostdin', '-v', 'error', '-rtsp_transport', 'tcp', '-i', $rtsp3, '-c', 'copy', '-f', 'null', '-')
      [void]$bg.Add($rd); $readers += $rd
      Start-Sleep -Milliseconds 800
    }
    Start-Sleep -Seconds 3
    $alive = @($readers | Where-Object { -not $_.Proc.HasExited }).Count
    & $add 'pc: MaxReaders (2) viewers get in while HLS is on (muxer has its own place)' ($alive -eq 2) ("$alive of 2 long readers connected")
    $r = Test-MtxRead $rtsp3 $tcpOpt
    & $add 'pc: one viewer more than MaxReaders is refused' ((-not $r.Ok) -and ((Get-MtxLogText $h) -match 'maximum reader count reached')) ($r.Detail + ' / log: maximum reader count reached')
    $hv = Get-MtxHttp "http://${lo}:$($s3.HlsPort)/live/$tok/index.m3u8"
    & $add 'pc: an HLS viewer over the limit is refused too' ($hv.Status -ne 200) ("HTTP $($hv.Status)")
    Stop-MtxBackground $readers[0]
    $ok3 = $false
    $deadline = (Get-Date).AddSeconds(12)
    do { Start-Sleep -Milliseconds 700; $r = Test-MtxRead $rtsp3 $tcpOpt; $ok3 = $r.Ok } while (-not $ok3 -and (Get-Date) -lt $deadline)
    & $add 'pc: when a viewer leaves, a new one gets in' $ok3 $r.Detail
  } catch { & $add 'pc: maxReaders test' $false $_.Exception.Message }
  finally {
    foreach ($b in @($bg)) { Stop-MtxBackground $b }
    $bg.Clear()
    Stop-MtxProcess $h
    $h = $null
  }

  # ---------------- this PC, seen from the LAN IP
  if ($lanIp) {
    if (-not (Test-MtxFirewallQuiet)) {
      & $add "pc: publish from the LAN IP is refused" $true 'skipped: Windows Firewall would ask about a program listening on the LAN IP (127.0.0.2 test above covers the rule)'
    } else {
      $s2 = [pscustomobject]@{ Token = $tok; RtspPort = (Get-MtxFreePort $taken); RtmpPort = (Get-MtxFreePort $taken); Hls = $false; MaxReaders = 2 }
      try {
        $h = Start-MtxProcess $exe (New-MediaMtxConfig 'pc' $s2 $lanIp) 'mediamtx-test-lan'
        $r = Send-MtxRtspAnnounce $lanIp $lanIp $s2.RtspPort "live/$tok"
        & $add "pc: publish handshake from the LAN IP $lanIp is refused" ($r.Code -eq 401 -or $r.Code -eq 403) $r.Text
        $r = Test-MtxPublish "rtmp://${lanIp}:$($s2.RtmpPort)/live/$tok"
        & $add "pc: RTMP publish from the LAN IP $lanIp is refused" (-not $r.Ok) $r.Detail
        $r = Test-MtxPublish "rtsp://${lanIp}:$($s2.RtspPort)/live/$tok"
        & $add "pc: RTSP publish from the LAN IP $lanIp is refused" (-not $r.Ok) $r.Detail
      } catch { & $add "pc: publish from the LAN IP $lanIp is refused" $false $_.Exception.Message }
      finally { Stop-MtxProcess $h; $h = $null }
    }
  }

  # ---------------- VPS
  if (-not $vps) { return $rows.ToArray() }
  if (-not (Test-FfmpegHasSrt)) { & $add 'vps: ffmpeg has SRT' $false 'this ffmpeg has no SRT - VPS SRT tests skipped (the tool would push over RTMP)'; return $rows.ToArray() }
  $tok = New-MtxSecret 16
  # A second stream on the same server (another PC's): its own token, user, password and passphrase.
  $b2 = [pscustomobject]@{ Name = 'B'; Token = (New-MtxSecret 16); PublishUser = 'vrclm2'; PublishPass = (New-MtxSecret 18); SrtPassphrase = (New-MtxSecret 24) }
  $v = [pscustomobject]@{ Token = $tok; PublishUser = 'vrclm'; PublishPass = (New-MtxSecret 18); SrtPassphrase = (New-MtxSecret 24); ReadPassphrase = (New-MtxSecret 24)
    SrtPort = (Get-MtxFreePort $taken); RtspPort = (Get-MtxFreePort $taken); RtmpPort = (Get-MtxFreePort $taken); Hls = $false; MaxReaders = 5
    Role = 'owner'; Streams = @($b2) }
  $rtsp = "rtsp://${lo}:$($v.RtspPort)/live/$tok"
  $rtmpBase = "rtmp://${lo}:$($v.RtmpPort)/live/$tok"
  $srtBase = "srt://${lo}:$($v.SrtPort)"
  $srtOk = "${srtBase}?streamid=publish:live/${tok}:$($v.PublishUser):$($v.PublishPass)&pkt_size=1316&passphrase=$($v.SrtPassphrase)&pbkeylen=32"
  $tok2 = $b2.Token
  $rtsp2 = "rtsp://${lo}:$($v.RtspPort)/live/$tok2"
  $srt2 = { param($t, $u, $pw, $pp) "${srtBase}?streamid=publish:live/${t}:${u}:${pw}&pkt_size=1316&passphrase=${pp}&pbkeylen=32" }
  $hide = { param($u) (((($u -replace [regex]::Escape($tok), '<token>') -replace [regex]::Escape($tok2), '<token2>') -replace [regex]::Escape($v.PublishPass), '<pass>') -replace [regex]::Escape($b2.PublishPass), '<pass2>') -replace '(passphrase=)[^&]+', '$1<secret>' }
  try {
    try { $h = Start-MtxProcess $exe (New-MediaMtxConfig 'vps' $v $lo) 'mediamtx-test-vps'; & $add 'vps: MediaMTX accepts the config and starts' $true ("pid $($h.Proc.Id)") }
    catch { & $add 'vps: MediaMTX accepts the config and starts' $false $_.Exception.Message; return $rows.ToArray() }
    $got = Get-MtxProcListeners $h.Proc.Id
    $okL = ((($got.Tcp | Sort-Object) -join ' ') -eq ((@("${lo}:$($v.RtspPort)", "${lo}:$($v.RtmpPort)") | Sort-Object) -join ' ')) -and ((($got.Udp) -join ' ') -eq "${lo}:$($v.SrtPort)")
    & $add 'vps: listens only on RTSP + RTMP (TCP) and SRT (UDP)' $okL ("TCP: $($got.Tcp -join ', '); UDP: $($got.Udp -join ', ')")

    $r = Send-MtxRtspAnnounce $lo $lo $v.RtspPort "live/$tok"
    & $add 'vps: publish without a password is refused, even from 127.0.0.1 (RTSP handshake)' ($r.Code -eq 401 -or $r.Code -eq 403) $r.Text
    $cases = @(
      @('vps: RTMP publish without user/password is refused', $rtmpBase),
      @('vps: RTMP publish with a wrong password is refused', "${rtmpBase}?user=$($v.PublishUser)&pass=wrong$($v.PublishPass)"),
      @('vps: SRT publish without the passphrase is refused', "${srtBase}?streamid=publish:live/${tok}:$($v.PublishUser):$($v.PublishPass)&pkt_size=1316"),
      @('vps: SRT publish with a wrong passphrase is refused', "${srtBase}?streamid=publish:live/${tok}:$($v.PublishUser):$($v.PublishPass)&pkt_size=1316&passphrase=$($v.ReadPassphrase)&pbkeylen=32"),
      @('vps: SRT publish with the passphrase inside streamid is refused', "${srtBase}?streamid=publish:live/${tok}:$($v.PublishUser):$($v.PublishPass)&passphrase=$($v.SrtPassphrase)".Replace('&passphrase=', ':passphrase=')),
      @('vps: SRT publish with a wrong user is refused', "${srtBase}?streamid=publish:live/${tok}:intruder:$($v.PublishPass)&pkt_size=1316&passphrase=$($v.SrtPassphrase)&pbkeylen=32"),
      @('vps: SRT publish without user/password is refused', "${srtBase}?streamid=publish:live/${tok}&pkt_size=1316&passphrase=$($v.SrtPassphrase)&pbkeylen=32"),
      @('vps: SRT publish to another path is refused', "${srtBase}?streamid=publish:live/other:$($v.PublishUser):$($v.PublishPass)&pkt_size=1316&passphrase=$($v.SrtPassphrase)&pbkeylen=32"),
      @('vps: RTMP publish with user/password to another path is refused', "rtmp://${lo}:$($v.RtmpPort)/live/other?user=$($v.PublishUser)&pass=$($v.PublishPass)")
    )
    foreach ($c in $cases) {
      $r = Test-MtxPublish $c[1]
      & $add $c[0] (-not $r.Ok) ($r.Detail + '  [' + (& $hide $c[1]) + ']')
    }
    # RTMP with user + password (the fallback when ffmpeg has no SRT): accepted and readable.
    $pub = Start-MtxBackground $script:FFmpeg ((Get-MtxTestSource 600) + (Get-MtxOutArgs "${rtmpBase}?user=$($v.PublishUser)&pass=$($v.PublishPass)"))
    [void]$bg.Add($pub)
    $r = Wait-MtxReadable $rtsp 15
    & $add 'vps: RTMP publish with user/password works (fallback)' $r.Ok $r.Detail
    Stop-MtxBackground $pub
    Start-Sleep -Milliseconds 1500
    # SRT with user + password + passphrase: the normal way.
    $pub = Start-MtxBackground $script:FFmpeg ((Get-MtxTestSource 600) + (Get-MtxOutArgs $srtOk))
    [void]$bg.Add($pub)
    $r = Wait-MtxReadable $rtsp 15
    & $add 'vps: SRT publish with user, password and passphrase works' $r.Ok $r.Detail
    $r = Test-MtxRead $rtsp $tcpOpt
    & $add 'vps: read over RTSP/TCP works' $r.Ok $r.Detail
    $r = Test-MtxRead ($rtsp + '?retry=-1&pause') $tcpOpt
    & $add 'vps: read over RTSP/TCP with ?retry=-1&pause works' $r.Ok $r.Detail
    $r = Test-MtxRead $rtmpBase @('-rw_timeout', '5000000')
    & $add 'vps: read over RTMP works' $r.Ok $r.Detail
    $r = Test-MtxRead ($rtmpBase + '?next') @('-rw_timeout', '5000000')
    & $add 'vps: read over RTMP with ?next works' $r.Ok $r.Detail
    # Several streams: each PC on its own path, at the same time, and none can send on another's.
    $cases2 = @(
      @("vps: stream 1's user can't publish to stream 2's path (SRT)", (& $srt2 $tok2 $v.PublishUser $v.PublishPass $b2.SrtPassphrase)),
      @("vps: stream 1's user can't publish to stream 2's path (SRT, stream 1's passphrase)", (& $srt2 $tok2 $v.PublishUser $v.PublishPass $v.SrtPassphrase)),
      @("vps: stream 2's user can't publish to stream 1's path (SRT)", (& $srt2 $tok $b2.PublishUser $b2.PublishPass $v.SrtPassphrase)),
      @("vps: stream 2's user can't publish to stream 1's path (RTMP)", "${rtmpBase}?user=$($b2.PublishUser)&pass=$($b2.PublishPass)"),
      @("vps: stream 2 with stream 1's passphrase is refused", (& $srt2 $tok2 $b2.PublishUser $b2.PublishPass $v.SrtPassphrase))
    )
    foreach ($c in $cases2) {
      $r = Test-MtxPublish $c[1]
      & $add $c[0] (-not $r.Ok) ($r.Detail + '  [' + (& $hide $c[1]) + ']')
    }
    $r = Test-MtxRead $rtsp $tcpOpt
    & $add 'vps: stream 1 still plays after those refused attempts (nobody took it over)' $r.Ok $r.Detail
    $pub2 = Start-MtxBackground $script:FFmpeg ((Get-MtxTestSource 600) + (Get-MtxOutArgs (& $srt2 $tok2 $b2.PublishUser $b2.PublishPass $b2.SrtPassphrase)))
    [void]$bg.Add($pub2)
    $r = Wait-MtxReadable $rtsp2 15
    & $add 'vps: stream 2 (its own user, password and passphrase) is on the air at the same time' $r.Ok $r.Detail
    $r = Test-MtxRead $rtsp $tcpOpt
    & $add 'vps: stream 1 still plays while stream 2 is on' $r.Ok $r.Detail
    $r = Test-MtxRead "rtmp://${lo}:$($v.RtmpPort)/live/$tok2" @('-rw_timeout', '5000000')
    & $add 'vps: stream 2 plays over RTMP (Quest link) too' $r.Ok $r.Detail
    $d = Test-VpsStream $lo $v.RtspPort $tok2 $b2.PublishUser $b2.PublishPass 4000
    & $add 'vps check: a live stream answers 200 and its own password is taken (ANNOUNCE)' ($d.State -eq 'live' -and $d.PassOk -eq $true) "$($d.State) $($d.Code) pass=$($d.PassOk)"
    $d = Test-VpsStream $lo $v.RtspPort $tok2 $v.PublishUser $v.PublishPass 4000
    & $add "vps check: stream 1's password on stream 2's link is refused (401)" ($d.PassOk -eq $false) "$($d.State) $($d.Code) pass=$($d.PassOk)"
    $r = Test-MtxRead $rtsp2 $tcpOpt
    & $add 'vps check: the ANNOUNCE checks did not take stream 2 over' $r.Ok $r.Detail
    $d = Test-VpsStream $lo $v.RtspPort (New-MtxSecret 16) '' '' 4000
    & $add 'vps check: an unknown link answers 400 (unknown)' ($d.State -eq 'unknown') "$($d.State) $($d.Code)"
    Stop-MtxBackground $pub2
    $deadline = (Get-Date).AddSeconds(15)
    do { Start-Sleep -Milliseconds 700; $d = Test-VpsStream $lo $v.RtspPort $tok2 '' '' 4000 } while ($d.State -ne 'idle' -and (Get-Date) -lt $deadline)
    & $add 'vps check: a known link with nobody on it answers 404 (idle)' ($d.State -eq 'idle') "$($d.State) $($d.Code)"
    $d = Test-VpsStream $lo (Get-MtxFreePort $taken) $tok '' '' 3000
    & $add 'vps check: no server on the port = down' ($d.State -eq 'down') "$($d.State) $($d.Detail)"
    $r = Test-MtxRead "${srtBase}?streamid=read:live/$tok" @() 12000
    & $add 'vps: SRT read without a passphrase is refused' (-not $r.Ok) $r.Detail
    $r = Test-MtxRead "${srtBase}?streamid=read:live/$tok&passphrase=$($v.SrtPassphrase)&pbkeylen=32" @() 12000
    & $add 'vps: SRT read with the publish passphrase is refused' (-not $r.Ok) $r.Detail
    $r = Test-MtxRead "${srtBase}?streamid=read:live/$tok&passphrase=$($v.ReadPassphrase)&pbkeylen=32" @() 15000
    & $add 'vps: SRT read with the (unshared) read passphrase works - proves which one is checked' $r.Ok $r.Detail
    $r = Test-MtxRead $rtsp @('-rtsp_transport', 'udp', '-timeout', '5000000')
    & $add 'vps: read over RTSP with UDP only is refused' (-not $r.Ok) $r.Detail
    foreach ($op in @('live/other', "live/${tok}x")) {
      $r = Test-MtxRead "rtsp://${lo}:$($v.RtspPort)/$op" $tcpOpt
      & $add ("vps: RTSP read of another path is refused: " + ($op -replace [regex]::Escape($tok), '<token>')) (-not $r.Ok) $r.Detail
    }
    $r = Test-MtxRead "rtmp://${lo}:$($v.RtmpPort)/live/other" @('-rw_timeout', '5000000')
    & $add 'vps: RTMP read of another path is refused' (-not $r.Ok) $r.Detail
  } finally {
    foreach ($b in @($bg)) { Stop-MtxBackground $b }
    Stop-MtxProcess $h
  }
  return $rows.ToArray()
}

# ------------------------------------------------------------------ VPS setup bundle
# Writes <DataDir>\vps-setup\ with mediamtx.yml, install.sh (one paste as root) and README-VPS.txt -> the folder.
function New-VpsSetupBundle($s) {
  $yml = New-MediaMtxConfig 'vps' $s ''
  $dir = PathJoin $script:DataDir 'vps-setup'
  if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
  $rtspPort = Get-MtxPort $s 'RtspPort' 8554
  $rtmpPort = Get-MtxPort $s 'RtmpPort' 1935
  $hlsPort = Get-MtxPort $s 'HlsPort' 8888
  $srtPort = Get-MtxPort $s 'SrtPort' 8890
  $hls = ("$(Get-MtxSetting $s 'Hls' $false)" -match '^(?i)(true|yes|on|1)$')
  $tcpPorts = "$rtspPort $rtmpPort"
  if ($hls) { $tcpPorts += " $hlsPort" }
  $addr = "$(Get-MtxSetting $s 'Address' '<address>')".Trim()
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText((PathJoin $dir 'mediamtx.yml'), $yml, $utf8)
  $sh = Get-VpsInstallScript $yml $tcpPorts "$srtPort"
  [System.IO.File]::WriteAllText((PathJoin $dir 'install.sh'), $sh, $utf8)
  $tcpList = ($tcpPorts -split ' ') -join ', '
  $readme = @(
    (T 'VRChat Link Maker - your own stream server on a VPS (MediaMTX {0})' $script:MediaMtxVersion),
    '==================================================================',
    (T 'A VPS is a small rented Linux server. This PC sends the stream to it once, and it hands the stream to the viewers. Your home IP stays hidden, and the viewers don''t use your home upload.'),
    (T 'These files contain your stream passwords. Don''t share them or post them anywhere.'),
    '',
    (T '1) Get a free VPS: Oracle Cloud Always Free (https://www.oracle.com/cloud/free/).'),
    (T '   - Not for viewers in Russia: Russian internet providers cut video from Oracle, Hetzner and the other big cloud hosts. See "Viewers in Russia" in README.txt before you pick a server for them.'),
    (T '   - IMPORTANT: the home region is picked once, when you sign up, and can''t be changed later. Always Free servers only run there. Pick one in Europe, e.g. Germany Central (Frankfurt).'),
    (T '   - Create a VM: Compute > Instances > Create instance. Image: Canonical Ubuntu 24.04 (or 22.04). Shape: Ampere VM.Standard.A1.Flex with 2 OCPU and 12 GB memory (the Always Free limit). Download the SSH key it offers.'),
    (T '   - Write down the instance''s public IP address.'),
    (T '2) Open the ports in Oracle''s cloud firewall: Networking > Virtual cloud networks > your VCN > Security Lists > Default Security List > Add Ingress Rules, source CIDR 0.0.0.0/0:'),
    (T '   - TCP, destination port(s) {0} (the viewers: RTSP for PC, RTMP for Quest)' $tcpList),
    (T '   - UDP, destination port {0} (SRT: the stream from this PC)' $srtPort),
    (T '3) Install MediaMTX on the VPS:'),
    (T '   - Connect from PowerShell on this PC: ssh -i <the key file> ubuntu@{0}' $addr),
    (T '   - Type: sudo -i   (you are then root)'),
    (T '   - Open install.sh from this folder in Notepad, copy all of it, paste it into the SSH window and press Enter.'),
    (T '     (Or copy the file over: scp -i <the key file> install.sh ubuntu@{0}:   and then run: sudo bash install.sh)' $addr),
    (T '   - It downloads MediaMTX {0} from GitHub, checks its SHA256 checksum, installs it as a service that starts with the server, and opens the same ports in the server''s own firewall. At the end it says: MediaMTX is running.' $script:MediaMtxVersion),
    (T '4) In VRChat Link Maker choose "My VPS" with the address {0}. Try the VLC link first.' $addr),
    '',
    (T 'After "New link" in the tool this folder is made again: paste the new install.sh again (the old link then stops working).'),
    '',
    (T 'More streams at the same time (one per PC, each with its own link): in VRChat Link Maker choose "My VPS" -> "Add a stream for another PC", paste the new install.sh here again, and give the other PC the connection code the tool shows. That PC pastes the code under "My VPS" instead of an address - it must not run an install.sh of its own (that would replace this setup).'),
    (T 'All streams share the server''s upload: e.g. 2 streams with 10 viewers each at 4 Mbps need 80 Mbps.'),
    (T 'Paid alternative: Hetzner Cloud CX23 (about 5.49 EUR a month plus a public IPv4 address). Create an Ubuntu 24.04 server in an EU location, then do step 3 as root (ssh root@<address>, no sudo needed). If you turned on Hetzner''s cloud firewall, open the same ports there. Viewers in Russia can''t watch from Hetzner either.'),
    '',
    (T 'Security: only this tool can send the stream (user + password, and on SRT an encryption passphrase). Viewers can only watch live/<token>; every other path is refused. Like any stream link, anyone who has the link can watch.'),
    (T 'The server''s address is not trusted by VRChat: everyone who watches, you included, needs "Allow Untrusted URLs", and it doesn''t play in Public or Group Public instances.')
  )
  [System.IO.File]::WriteAllText((PathJoin $dir 'README-VPS.txt'), (($readme -join "`r`n") + "`r`n"), $utf8)
  return $dir
}

# The install script (bash, LF line endings). Written so it can be pasted into an SSH window as root: everything runs in
# a ( subshell ), so an error ends the script, not the SSH session.
function Get-VpsInstallScript([string]$yml, [string]$tcpPorts, [string]$udpPorts) {
  if ($yml -match '(?m)^VRCLM_') { throw 'config text contains a heredoc marker' }
  $L = New-Object System.Collections.Generic.List[string]
  $L.Add('#!/bin/bash')
  $L.Add("# VRChat Link Maker - installs MediaMTX $($script:MediaMtxVersion) as a locked-down service (Ubuntu 22.04+ / Debian 12+, amd64 or arm64).")
  $L.Add('# Run as root: paste all of it into the SSH window after "sudo -i", or run: sudo bash install.sh')
  $L.Add('# Running it again is safe: it replaces the settings (e.g. after "New link") and restarts the server.')
  $L.Add('set +H 2>/dev/null || true')
  $L.Add('(')
  $L.Add('set -eu')
  $L.Add("MTX_VERSION='$($script:MediaMtxVersion)'")
  $L.Add("SHA_AMD64='$($script:MediaMtxLinuxSha256.amd64)'")
  $L.Add("SHA_ARM64='$($script:MediaMtxLinuxSha256.arm64)'")
  $L.Add("TCP_PORTS='$tcpPorts'")
  $L.Add("UDP_PORTS='$udpPorts'")
  $L.Add(@'
say() { printf '\n=== %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail 'Please run this as root: type  sudo -i  first, then paste it again.'
command -v systemctl >/dev/null 2>&1 || fail 'This needs a Linux with systemd (Ubuntu 22.04 or newer, Debian 12 or newer).'
SYSTEMD_VER=$(systemctl --version | awk 'NR == 1 { print $2 }' | tr -cd '0-9')
[ "${SYSTEMD_VER:-0}" -ge 248 ] || fail "systemd ${SYSTEMD_VER:-?} is too old (needs 248 or newer: Ubuntu 22.04+, Debian 12+)."

case "$(uname -m)" in
  x86_64 | amd64) ARCH=amd64; SHA=$SHA_AMD64 ;;
  aarch64 | arm64) ARCH=arm64; SHA=$SHA_ARM64 ;;
  *) fail "Unsupported CPU type: $(uname -m) (needs x86_64 or arm64)." ;;
esac
FILE="mediamtx_${MTX_VERSION}_linux_${ARCH}.tar.gz"
URL="https://github.com/bluenviron/mediamtx/releases/download/${MTX_VERSION}/${FILE}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say "Downloading MediaMTX $MTX_VERSION ($ARCH)"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL --retry 3 --connect-timeout 20 -o "$TMP/$FILE" "$URL" || fail "Download failed: $URL"
elif command -v wget >/dev/null 2>&1; then
  wget -q -O "$TMP/$FILE" "$URL" || fail "Download failed: $URL"
else
  fail 'Neither curl nor wget is installed. Run: apt-get install -y curl'
fi
echo "$SHA  $TMP/$FILE" | sha256sum -c --status - || fail 'The download does not match the expected SHA256 checksum. Nothing was installed.'
echo 'SHA256 checksum OK.'
mkdir "$TMP/x"
tar -xzf "$TMP/$FILE" -C "$TMP/x" || fail 'Could not unpack the download.'
BIN=$(find "$TMP/x" -type f -name mediamtx | head -n 1)
[ -n "$BIN" ] || fail 'The download has no mediamtx program in it.'

say 'Installing'
systemctl stop mediamtx >/dev/null 2>&1 || true
install -m 0755 -o root -g root "$BIN" /usr/local/bin/mediamtx
install -d -m 0700 -o root -g root /etc/mediamtx
umask 077
cat > /etc/mediamtx/mediamtx.yml.new <<'VRCLM_YML_EOF'
'@)
  foreach ($line in ($yml.TrimEnd("`n") -split "`n")) { $L.Add($line) }
  $L.Add(@'
VRCLM_YML_EOF
mv -f /etc/mediamtx/mediamtx.yml.new /etc/mediamtx/mediamtx.yml
chmod 0600 /etc/mediamtx/mediamtx.yml
/usr/local/bin/mediamtx --validate-conf=/etc/mediamtx/mediamtx.yml || fail 'MediaMTX does not accept the settings (see above).'
umask 022

# The settings (with the passwords) stay readable by root only; systemd hands the service a private copy.
cat > /etc/systemd/system/mediamtx.service <<'VRCLM_UNIT_EOF'
[Unit]
Description=MediaMTX stream server (VRChat Link Maker)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
LoadCredential=mediamtx.yml:/etc/mediamtx/mediamtx.yml
ExecStart=/usr/local/bin/mediamtx %d/mediamtx.yml
Restart=on-failure
RestartSec=3
DynamicUser=yes
NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
UMask=0077
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
VRCLM_UNIT_EOF
chmod 0644 /etc/systemd/system/mediamtx.service

say 'Opening the ports in the server firewall'
add_rule() {  # $1 = iptables | ip6tables, $2 = tcp | udp, $3 = port
  if "$1" -C INPUT -p "$2" --dport "$3" -m comment --comment vrclm-mediamtx -j ACCEPT >/dev/null 2>&1; then return 0; fi
  pos=$("$1" -L INPUT -n --line-numbers | awk '$2 == "REJECT" || $2 == "DROP" { print $1; exit }')
  if [ -n "$pos" ]; then
    "$1" -I INPUT "$pos" -p "$2" --dport "$3" -m comment --comment vrclm-mediamtx -j ACCEPT
  else
    "$1" -A INPUT -p "$2" --dport "$3" -m comment --comment vrclm-mediamtx -j ACCEPT
  fi
}
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  for p in $TCP_PORTS; do ufw allow "$p/tcp" >/dev/null; done
  for p in $UDP_PORTS; do ufw allow "$p/udp" >/dev/null; done
  echo "ufw: opened TCP $TCP_PORTS and UDP $UDP_PORTS."
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  for p in $TCP_PORTS; do firewall-cmd --quiet --permanent --add-port="$p/tcp"; done
  for p in $UDP_PORTS; do firewall-cmd --quiet --permanent --add-port="$p/udp"; done
  firewall-cmd --quiet --reload
  echo "firewalld: opened TCP $TCP_PORTS and UDP $UDP_PORTS."
elif command -v iptables >/dev/null 2>&1; then
  for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null 2>&1 || continue
    "$ipt" -L INPUT -n >/dev/null 2>&1 || continue
    for p in $TCP_PORTS; do add_rule "$ipt" tcp "$p"; done
    for p in $UDP_PORTS; do add_rule "$ipt" udp "$p"; done
  done
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || echo 'Note: netfilter-persistent could not save the rules.'
  elif [ -d /etc/iptables ]; then
    iptables-save > /etc/iptables/rules.v4
    if command -v ip6tables-save >/dev/null 2>&1; then ip6tables-save > /etc/iptables/rules.v6; fi
  else
    echo 'Note: the iptables rules are not saved for the next reboot (apt-get install -y iptables-persistent saves them).'
  fi
  echo "iptables: opened TCP $TCP_PORTS and UDP $UDP_PORTS."
else
  echo 'No firewall found on the server (nothing to open here).'
fi

say 'Starting MediaMTX'
systemctl daemon-reload
systemctl enable mediamtx >/dev/null 2>&1 || fail 'Could not enable the mediamtx service.'
systemctl restart mediamtx
sleep 3
if systemctl is-active --quiet mediamtx; then
  echo 'MediaMTX is running and starts with the server.'
  if command -v ss >/dev/null 2>&1; then ss -lntup 2>/dev/null | grep mediamtx || true; fi
else
  journalctl -u mediamtx -n 30 --no-pager || true
  fail 'MediaMTX did not start (see above).'
fi
echo
echo "Done. Also open TCP $TCP_PORTS and UDP $UDP_PORTS in your cloud provider's firewall (Oracle: the VCN security list)."
)
'@)
  return (($L -join "`n").Replace("`r", '') + "`n")
}

# ------------------------------------------------------------------ hosts, part 3: network
# This PC's public / LAN address, the CGNAT check, IPv6, sslip.io / DuckDNS names, UPnP port forwarding, the
# firewall rule for MediaMTX, Tailscale Funnel and the speed test.
# Nothing here changes the router or the firewall by itself: the caller asks the user first. Every function that
# would change something has -DryRun, which only prints what it would do.

$script:UpnpDesc = 'VRChat Link Maker'
$script:FirewallRuleName = 'VRChat Link Maker (MediaMTX)'
$script:NetCache = @{}
$script:UpnpIgd = $null
$script:UpnpTried = $false
$script:UpnpMapped = New-Object System.Collections.ArrayList
$script:FirewallWatch = $null

# ------------------------------------------------------------------ address helpers
function Test-IPv4Text([string]$s) {
  if (-not $s -or $s -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
  $ip = $null
  return [System.Net.IPAddress]::TryParse($s, [ref]$ip)
}

# 100.64.0.0/10: the range providers use behind carrier-grade NAT.
function Test-CgnatIPv4([string]$s) {
  if (-not (Test-IPv4Text $s)) { return $false }
  $b = ([System.Net.IPAddress]::Parse($s)).GetAddressBytes()
  return ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127)
}

# Addresses nobody on the internet can reach: private, CGNAT, link-local, loopback, multicast.
function Test-NonPublicIPv4([string]$s) {
  if (-not (Test-IPv4Text $s)) { return $true }
  $b = ([System.Net.IPAddress]::Parse($s)).GetAddressBytes()
  if ($b[0] -eq 0 -or $b[0] -eq 10 -or $b[0] -eq 127 -or $b[0] -ge 224) { return $true }
  if ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) { return $true }
  if ($b[0] -eq 192 -and $b[1] -eq 168) { return $true }
  if ($b[0] -eq 169 -and $b[1] -eq 254) { return $true }
  return (Test-CgnatIPv4 $s)
}

# Global unicast IPv6 (2000::/3), without Teredo, 6to4 and the documentation range.
function Test-GlobalIPv6([string]$s) {
  $ip = $null
  if (-not $s -or -not [System.Net.IPAddress]::TryParse(($s -split '%')[0], [ref]$ip)) { return $false }
  if ($ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetworkV6) { return $false }
  $b = $ip.GetAddressBytes()
  if (($b[0] -band 0xE0) -ne 0x20) { return $false }
  if ($b[0] -eq 0x20 -and $b[1] -eq 0x01 -and $b[2] -eq 0x00 -and $b[3] -eq 0x00) { return $false }   # Teredo
  if ($b[0] -eq 0x20 -and $b[1] -eq 0x01 -and $b[2] -eq 0x0d -and $b[3] -eq 0xb8) { return $false }   # documentation
  if ($b[0] -eq 0x20 -and $b[1] -eq 0x02) { return $false }                                           # 6to4
  return $true
}

# Does an adapter name look like a VPN? (Its default route would send the stream out through the VPN.)
function Test-VpnName([string]$name) {
  return ($name -match '(?i)vpn|wintun|wireguard|openvpn|tap-windows|tap-win|surfshark|nordlynx|proton|mullvad|expressvpn|hamachi|zerotier|tailscale|anyconnect|fortinet|pangp|cloudflare ?warp')
}

# The VPN adapter the internet traffic goes through right now, or $null.
function Get-ActiveVpn {
  try {
    $r = @(Find-NetRoute -RemoteIPAddress '1.1.1.1' -ErrorAction Stop | Where-Object { $_.PSObject.Properties['NextHop'] })
    foreach ($x in $r) {
      $desc = ''
      try { $desc = "$((Get-NetAdapter -InterfaceIndex $x.InterfaceIndex -ErrorAction Stop).InterfaceDescription)" } catch {}
      $name = "$($x.InterfaceAlias) $desc"
      if (Test-VpnName $name) { return "$($x.InterfaceAlias)".Trim() }
    }
  } catch {}
  return $null
}

# This PC's public IPv4, asked from two services over HTTPS (plus Cloudflare as a spare). Remembered for 10 minutes
# (a failure for 1 minute, so a PC without internet doesn't wait again at once).
function Get-PublicIPv4([switch]$Refresh) {
  $c = $script:NetCache['ip4']
  if (-not $Refresh -and $c) {
    $age = ((Get-Date) - $c.At).TotalMinutes
    if (($c.Ip -and $age -lt 10) -or (-not $c.Ip -and $age -lt 1)) { return $c.Ip }
  }
  $found = $null
  foreach ($u in @('https://api.ipify.org', 'https://ipv4.icanhazip.com', 'https://1.1.1.1/cdn-cgi/trace')) {
    try {
      $r = Invoke-Web -Url $u -TimeoutSec 5
      if ($r.Status -ne 200) { continue }
      $m = [regex]::Match("$($r.Text)", '(?m)^(?:ip=)?\s*(\d{1,3}(?:\.\d{1,3}){3})\s*$')
      if ($m.Success -and -not (Test-NonPublicIPv4 $m.Groups[1].Value)) { $found = $m.Groups[1].Value; break }
    } catch {}
  }
  $script:NetCache['ip4'] = @{ Ip = $found; At = Get-Date }
  return $found
}

# The IPv4 of this PC on the home network: the address of the default-route adapter (a VPN adapter only when
# there's nothing else).
function Get-LanIPv4 {
  $best = $null
  try {
    $rows = @(foreach ($r in @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop)) {
        $ifm = 0
        try { $ifm = [int](Get-NetIPInterface -InterfaceIndex $r.ifIndex -AddressFamily IPv4 -ErrorAction Stop).InterfaceMetric } catch {}
        $desc = ''
        try { $desc = "$((Get-NetAdapter -InterfaceIndex $r.ifIndex -ErrorAction Stop).InterfaceDescription)" } catch {}
        [pscustomobject]@{ If = $r.ifIndex; Metric = [int]$r.RouteMetric + $ifm; Vpn = [bool](Test-VpnName "$($r.InterfaceAlias) $desc"); Gw = "$($r.NextHop)" }
      })
    foreach ($row in @($rows | Sort-Object Vpn, Metric)) {
      $a = @(Get-NetIPAddress -InterfaceIndex $row.If -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object { "$($_.AddressState)" -eq 'Preferred' -and $_.IPAddress -notmatch '^169\.254\.' })
      if ($a.Count -gt 0) { $best = $a[0].IPAddress; $script:NetCache['gw4'] = $row.Gw; break }
    }
  } catch {}
  if (-not $best) {
    # Fallback: which local address would talk to the internet (a UDP "connect" sends nothing).
    $u = $null
    try {
      $u = New-Object System.Net.Sockets.UdpClient
      $u.Connect('192.0.2.1', 9)
      $best = $u.Client.LocalEndPoint.Address.ToString()
    } catch {} finally { if ($u) { $u.Close() } }
    if ($best -and -not (Test-IPv4Text $best)) { $best = $null }
  }
  return $best
}

# A stable (not temporary) global IPv6 of this PC, or $null. Windows marks its temporary privacy addresses with
# suffix origin "Random"; the stable one is "Link" (also with randomized identifiers), "Dhcp" or "Manual".
function Get-GlobalIPv6 {
  $cands = @()
  try {
    $v6If = @{}
    try { foreach ($r in @(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix '::/0' -ErrorAction Stop)) { $v6If[[int]$r.ifIndex] = $true } } catch {}
    $cands = @(Get-NetIPAddress -AddressFamily IPv6 -ErrorAction Stop | Where-Object {
        "$($_.AddressState)" -eq 'Preferred' -and -not $_.SkipAsSource -and "$($_.SuffixOrigin)" -ne 'Random' -and (Test-GlobalIPv6 $_.IPAddress)
      } | Sort-Object @{ e = { -not $v6If.ContainsKey([int]$_.InterfaceIndex) } }, @{ e = { "$($_.SuffixOrigin)" -ne 'Link' } } |
      ForEach-Object { ($_.IPAddress -split '%')[0] })
  } catch {
    try {
      foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($ni.OperationalStatus -ne 'Up') { continue }
        foreach ($ua in $ni.GetIPProperties().UnicastAddresses) {
          $a = $ua.Address.ToString()
          if ((Test-GlobalIPv6 $a) -and "$($ua.SuffixOrigin)" -ne 'Random' -and "$($ua.DuplicateAddressDetectionState)" -eq 'Preferred') { $cands += ($a -split '%')[0] }
        }
      }
    } catch {}
  }
  if ($cands.Count -gt 0) { return ([System.Net.IPAddress]::Parse($cands[0])).ToString() }
  return $null
}

# ------------------------------------------------------------------ host names (sslip.io / DuckDNS)
function ConvertTo-SslipName([string]$ip) {
  $a = $null
  if (-not [System.Net.IPAddress]::TryParse(($ip -split '%')[0], [ref]$a)) { return $null }
  $t = (($a.ToString() -split '%')[0]).ToLowerInvariant()
  if ($a.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
    # sslip.io wants dashes for IPv6 ("::" becomes "--"); a name part can't start or end with a dash.
    $t = $t -replace ':', '-'
    if ($t.StartsWith('-')) { $t = '0' + $t }
    if ($t.EndsWith('-')) { $t = $t + '0' }
  } else {
    $t = $t -replace '\.', '-'
  }
  return $t + '.sslip.io'
}

# The user's own host name, cleaned ("https://Name.duckdns.org/" -> "name.duckdns.org").
function Get-CleanHostName([string]$h) {
  $h = "$h".Trim()
  $h = $h -replace '^(?i)[a-z][a-z0-9+.-]*://', ''
  $h = ($h -split '[/?#]')[0]
  $h = $h -replace ':\d+$', ''
  return $h.TrimEnd('.').ToLowerInvariant()
}

# The host name viewers connect to: the user's own (e.g. a DuckDNS name), else <a-b-c-d>.sslip.io made from the
# public IPv4 (it points back to that address). $null when the public address can't be found (no internet).
function Get-SelfHostName($s) {
  $h = Get-CleanHostName (Get-Prop $s 'HostName')
  if ($h) { return $h }
  $ip = Get-PublicIPv4
  if (-not $ip) { return $null }
  return (ConvertTo-SslipName $ip)
}

# The IPv6 fallback name (<dashed-ipv6>.sslip.io), or $null without a stable global IPv6.
function Get-SelfHostName6 {
  $ip = Get-GlobalIPv6
  if (-not $ip) { return $null }
  return (ConvertTo-SslipName $ip)
}

# Point the user's DuckDNS name at this PC: IPv4, and IPv6 too when $s.Ipv6 is on and there is one.
# Returns a line to show ('' when there is nothing to do: no DuckDNS name or no token).
function Update-DuckDns($s) {
  $h = Get-CleanHostName (Get-Prop $s 'HostName')
  $tok = "$(Get-Prop $s 'DuckDnsToken')".Trim()
  if ($h -notmatch '^(?:[a-z0-9-]+\.)*([a-z0-9-]+)\.duckdns\.org$' -or -not $tok) { return '' }
  $sub = $Matches[1]
  $ip4 = Get-PublicIPv4 -Refresh
  $ip6 = $null
  if ((Get-Prop $s 'Ipv6') -ne $false) { $ip6 = Get-GlobalIPv6 }
  if (-not $ip4 -and -not $ip6) { return (T 'DuckDNS: not updated (this PC''s internet address could not be found).') }
  $q = 'domains=' + [Uri]::EscapeDataString($sub) + '&token=' + [Uri]::EscapeDataString($tok)
  if ($ip4) { $q += '&ip=' + $ip4 }
  if ($ip6) { $q += '&ipv6=' + [Uri]::EscapeDataString($ip6) }
  try {
    $r = Invoke-Web -Url ('https://www.duckdns.org/update?' + $q) -TimeoutSec 10
    $txt = "$($r.Text)".Trim()
    if ($r.Status -eq 200 -and $txt -match '^OK') {
      $to = @($ip4, $ip6 | Where-Object { $_ }) -join ' + '
      return (T 'DuckDNS: {0} now points to this PC ({1}).' $h $to)
    }
    return (T 'DuckDNS said no. Check the name and the token on duckdns.org.')
  } catch {
    return (T 'DuckDNS could not be reached ({0}).' $_.Exception.Message)
  }
}

# ------------------------------------------------------------------ UPnP (the router's port forwarding)
# Plain SSDP + SOAP (UPnP IGD), so every step is time-boxed and works without Windows' UPnP services.

# Find the router's UPnP service ($null when no router answers). Remembered for the session.
function Get-UpnpIgd([switch]$Refresh) {
  if ($script:UpnpTried -and -not $Refresh) { return $script:UpnpIgd }
  $script:UpnpTried = $true
  $script:UpnpIgd = $null
  $lan = Get-LanIPv4
  $gw = "$($script:NetCache['gw4'])"
  $locs = New-Object System.Collections.ArrayList
  $u = $null
  try {
    $bind = [System.Net.IPAddress]::Any
    if ($lan) { $bind = [System.Net.IPAddress]::Parse($lan) }
    $u = New-Object System.Net.Sockets.UdpClient((New-Object System.Net.IPEndPoint($bind, 0)))
    $dst = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse('239.255.255.250'), 1900)
    foreach ($st in @('urn:schemas-upnp-org:device:InternetGatewayDevice:1', 'urn:schemas-upnp-org:device:InternetGatewayDevice:2',
        'urn:schemas-upnp-org:service:WANIPConnection:1', 'urn:schemas-upnp-org:service:WANPPPConnection:1')) {
      $msg = "M-SEARCH * HTTP/1.1`r`nHOST: 239.255.255.250:1900`r`nMAN: `"ssdp:discover`"`r`nMX: 2`r`nST: $st`r`n`r`n"
      $bytes = [System.Text.Encoding]::ASCII.GetBytes($msg)
      [void]$u.Send($bytes, $bytes.Length, $dst)
    }
    $until = (Get-Date).AddSeconds(2.5)
    while ((Get-Date) -lt $until) {
      if (-not $u.Client.Poll(200000, [System.Net.Sockets.SelectMode]::SelectRead)) { continue }
      $from = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
      $data = $u.Receive([ref]$from)
      $txt = [System.Text.Encoding]::ASCII.GetString($data)
      $m = [regex]::Match($txt, '(?im)^LOCATION:\s*(\S+)\s*$')
      if ($m.Success -and $m.Groups[1].Value -match '^(?i)http://' -and -not $locs.Contains($m.Groups[1].Value)) { [void]$locs.Add($m.Groups[1].Value) }
    }
  } catch {} finally { if ($u) { $u.Close() } }
  # The default gateway's answer first (another device on the network could answer too).
  $ordered = @($locs | Sort-Object @{ e = { -not ($gw -and ([Uri]$_).Host -eq $gw) } })
  foreach ($loc in $ordered) {
    try {
      $r = Invoke-Web -Url $loc -TimeoutSec 3
      if ($r.Status -ne 200) { continue }
      $x = [xml]$r.Text
      $base = $loc
      $ub = $x.SelectSingleNode("//*[local-name()='URLBase']")
      if ($ub -and "$($ub.InnerText)".Trim()) { $base = "$($ub.InnerText)".Trim() }
      $svcs = @()
      foreach ($n in @($x.SelectNodes("//*[local-name()='service']"))) {
        $type = "$($n.SelectSingleNode("*[local-name()='serviceType']").InnerText)".Trim()
        $ctl = "$($n.SelectSingleNode("*[local-name()='controlURL']").InnerText)".Trim()
        if ($type -match '^urn:schemas-upnp-org:service:WAN(IP|PPP)Connection:\d$' -and $ctl) {
          $svcs += [pscustomobject]@{ Type = $type; Control = (New-Object System.Uri((New-Object System.Uri($base)), $ctl)).AbsoluteUri }
        }
      }
      if ($svcs.Count -gt 0) {
        $script:UpnpIgd = [pscustomobject]@{ Location = $loc; Router = ([Uri]$loc).Host; Services = $svcs; Lan = $lan }
        break
      }
    } catch {}
  }
  return $script:UpnpIgd
}

# One UPnP SOAP call. -> Ok, Code (UPnP error code, 0 = none), Values (hashtable of the answer's fields), Text.
function Invoke-UpnpSoap($svc, [string]$action, $fields) {
  $sb = New-Object System.Text.StringBuilder
  if ($fields) { foreach ($k in $fields.Keys) { [void]$sb.Append("<$k>" + [System.Security.SecurityElement]::Escape([string]$fields[$k]) + "</$k>") } }
  $body = '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">' +
    "<s:Body><u:$action xmlns:u=`"$($svc.Type)`">" + $sb.ToString() + "</u:$action></s:Body></s:Envelope>"
  $res = [pscustomobject]@{ Ok = $false; Code = 0; Values = @{}; Text = '' }
  try {
    $r = Invoke-Web -Url $svc.Control -Method 'POST' -Body $body -ContentType 'text/xml; charset="utf-8"' -TimeoutSec 5 -Headers @{ 'SOAPAction' = "`"$($svc.Type)#$action`"" }
    $res.Text = "$($r.Text)"
    foreach ($m in [regex]::Matches($res.Text, '<(?:[\w-]+:)?(New\w+|errorCode|errorDescription)>([^<]*)</')) { $res.Values[$m.Groups[1].Value] = $m.Groups[2].Value }
    if ($res.Values.ContainsKey('errorCode')) { [void][int]::TryParse($res.Values['errorCode'], [ref]$res.Code) }
    $res.Ok = ($r.Status -eq 200 -and $res.Code -eq 0)
  } catch { $res.Text = $_.Exception.Message }
  return $res
}

# The router's own internet (WAN) address as UPnP reports it, or $null (no UPnP answer). Read-only.
function Get-UpnpWanIp {
  $igd = Get-UpnpIgd
  if (-not $igd) { return $null }
  foreach ($svc in $igd.Services) {
    $r = Invoke-UpnpSoap $svc 'GetExternalIPAddress' $null
    $ip = "$($r.Values['NewExternalIPAddress'])".Trim()
    if ($r.Ok -and (Test-IPv4Text $ip) -and $ip -ne '0.0.0.0') { $igd | Add-Member -Force -NotePropertyName WanService -NotePropertyValue $svc; return $ip }
  }
  return $null
}

# The router's current port forwards (read-only): Port, Proto, Client, Desc, Enabled, Service.
function Get-UpnpPortMappings {
  $igd = Get-UpnpIgd
  $list = New-Object System.Collections.ArrayList
  if (-not $igd) { return @() }
  foreach ($svc in $igd.Services) {
    for ($i = 0; $i -lt 256; $i++) {
      $r = Invoke-UpnpSoap $svc 'GetGenericPortMappingEntry' ([ordered]@{ NewPortMappingIndex = $i })
      if (-not $r.Ok) { break }
      $v = $r.Values
      [void]$list.Add([pscustomobject]@{ Port = [int]$v['NewExternalPort']; Proto = "$($v['NewProtocol'])".ToUpperInvariant(); Client = "$($v['NewInternalClient'])"
          InternalPort = [int]$v['NewInternalPort']; Desc = "$($v['NewPortMappingDescription'])"; Enabled = "$($v['NewEnabled'])"; Remote = "$($v['NewRemoteHost'])"; Service = $svc })
    }
  }
  return @($list)
}

function Get-UpnpService($igd) {
  $w = Get-Prop $igd 'WanService'
  if ($w) { return $w }
  return $igd.Services[0]
}

# Forward TCP ports from the router to this PC (only after the user agreed). Removes our own stale forwards from a
# crashed run first. Leases last 1 h where the router allows it and are renewed every 30 min while the stream runs
# (Update-UpnpLeases), so a forward left by a crash or a closed window ends within the hour by itself.
# -> $true when every port is forwarded. -DryRun: only prints what it would do (reading the router is fine).
function Add-UpnpPortMappings([int[]]$ports, [switch]$DryRun) {
  $lan = Get-LanIPv4
  $igd = Get-UpnpIgd
  if (-not $igd -or -not $lan) {
    Say (T 'The router did not answer (UPnP is off or not supported), so the ports could not be opened automatically.') 'Yellow'
    if ($DryRun) { foreach ($p in $ports) { Say ('  [dry run] ' + (T 'would forward TCP port {0} to {1}:{0}' $p $lan)) 'DarkGray' } }
    Show-PortForwardHelp $ports
    return $false
  }
  $wan = Get-UpnpWanIp
  if ($wan -and (Test-NonPublicIPv4 $wan)) {
    # Behind CGNAT / another router: a forward here would open a port that still can't be reached.
    Say (T 'Not opening ports: the router''s internet address ({0}) is shared (CGNAT), so viewers still couldn''t reach this PC.' $wan) 'Yellow'
    return $false
  }
  [void](Remove-UpnpPortMappings -DryRun:$DryRun -StaleOnly)
  $svc = Get-UpnpService $igd
  $existing = @(Get-UpnpPortMappings)
  $all = $true
  foreach ($p in $ports) {
    $taken = @($existing | Where-Object { $_.Port -eq $p -and $_.Proto -eq 'TCP' -and $_.Client -ne $lan })
    if ($taken.Count -gt 0) {
      Say (T 'Port {0} is already forwarded to another device ({1}). Pick another port in config.json, or change it in the router.' $p $taken[0].Client) 'Yellow'
      $all = $false
      continue
    }
    if ($DryRun) {
      Say ('  [dry run] ' + (T 'would ask the router ({0}) to forward TCP port {1} to {2}:{1} ("{3}")' $igd.Router $p $lan $script:UpnpDesc)) 'DarkGray'
      continue
    }
    $f = [ordered]@{ NewRemoteHost = ''; NewExternalPort = $p; NewProtocol = 'TCP'; NewInternalPort = $p; NewInternalClient = $lan
      NewEnabled = 1; NewPortMappingDescription = $script:UpnpDesc; NewLeaseDuration = $script:UpnpLease }
    $r = Invoke-UpnpSoap $svc 'AddPortMapping' $f
    if (-not $r.Ok -and $r.Code -eq 725) { $f['NewLeaseDuration'] = 0; $r = Invoke-UpnpSoap $svc 'AddPortMapping' $f }   # only permanent leases
    if ($r.Ok) {
      [void]$script:UpnpMapped.Add([pscustomobject]@{ Port = $p; Service = $svc; Fields = $f })
      $script:UpnpRenewAt = (Get-Date).AddSeconds($script:UpnpLease / 2)
    } else {
      $why = "$($r.Values['errorDescription'])"
      if (-not $why) { $why = Get-ShortText $r.Text 80 }
      Say (T 'The router did not open port {0} ({1}).' $p $why) 'Yellow'
      $all = $false
    }
  }
  if (-not $DryRun -and $script:UpnpMapped.Count -gt 0) {
    Say (T 'The router forwards port(s) {0} to this PC now (removed again when this window closes).' ((@($script:UpnpMapped | ForEach-Object { $_.Port }) -join ', '))) 'DarkGray'
  }
  if (-not $all -and -not $DryRun) { Show-PortForwardHelp $ports }
  return $all
}

# Renews this run's forwards before their lease runs out (called every few seconds; asks the router only every 30 min).
$script:UpnpLease = 3600
$script:UpnpRenewAt = [datetime]::MaxValue
function Update-UpnpLeases {
  if ($script:UpnpMapped.Count -eq 0 -or (Get-Date) -lt $script:UpnpRenewAt) { return }
  $script:UpnpRenewAt = (Get-Date).AddSeconds($script:UpnpLease / 2)
  foreach ($m in @($script:UpnpMapped)) {
    if (-not $m.Fields -or [int]$m.Fields['NewLeaseDuration'] -eq 0) { continue }
    try {
      $r = Invoke-UpnpSoap $m.Service 'AddPortMapping' $m.Fields
      if (-not $r.Ok) {
        # Some routers refuse to renew an existing forward (e.g. 718 "conflict"): remove it and add it again.
        [void](Invoke-UpnpSoap $m.Service 'DeletePortMapping' ([ordered]@{ NewRemoteHost = ''; NewExternalPort = $m.Port; NewProtocol = 'TCP' }))
        [void](Invoke-UpnpSoap $m.Service 'AddPortMapping' $m.Fields)
      }
    } catch {}
  }
}

# Remove our forwards: the ones this run added, and stale ones from a crashed run (description "VRChat Link Maker"
# and this PC's LAN address). -StaleOnly: only the stale ones. -> how many were removed.
function Remove-UpnpPortMappings([switch]$DryRun, [switch]$StaleOnly) {
  $n = 0
  $done = @{}
  if (-not $StaleOnly) {
    foreach ($m in @($script:UpnpMapped)) {
      $key = "$($m.Port)"
      if ($DryRun) { Say ('  [dry run] ' + (T 'would remove the router''s forward of TCP port {0}' $m.Port)) 'DarkGray'; $done[$key] = $true; continue }
      $r = Invoke-UpnpSoap $m.Service 'DeletePortMapping' ([ordered]@{ NewRemoteHost = ''; NewExternalPort = $m.Port; NewProtocol = 'TCP' })
      if ($r.Ok -or $r.Code -eq 714) { $n++; $done[$key] = $true }
    }
    if (-not $DryRun) { $script:UpnpMapped.Clear() }
  }
  # Looking for stale ones asks the router (a few seconds); on exit only when the router was already asked this run.
  $igd = $script:UpnpIgd
  if (-not $igd -and $StaleOnly -and -not $script:UpnpTried) { $igd = Get-UpnpIgd }
  if (-not $igd) { return $n }
  $lan = Get-LanIPv4
  if (-not $lan) { return $n }
  foreach ($m in @(Get-UpnpPortMappings | Where-Object { $_.Desc -eq $script:UpnpDesc -and $_.Client -eq $lan -and $_.Proto -eq 'TCP' })) {
    if ($done.ContainsKey("$($m.Port)")) { continue }
    if ($DryRun) { Say ('  [dry run] ' + (T 'would remove an old forward of TCP port {0} left by an earlier run' $m.Port)) 'DarkGray'; continue }
    $r = Invoke-UpnpSoap $m.Service 'DeletePortMapping' ([ordered]@{ NewRemoteHost = $m.Remote; NewExternalPort = $m.Port; NewProtocol = 'TCP' })
    if ($r.Ok -or $r.Code -eq 714) { $n++ }
  }
  return $n
}

# Short manual steps for the router's port forwarding page.
function Show-PortForwardHelp([int[]]$ports) {
  $lan = Get-LanIPv4
  $gw = "$($script:NetCache['gw4'])"
  if (-not $gw) { $gw = '192.168.1.1' }
  Say (T 'To open the ports yourself: open http://{0} in a browser, log in to the router, find "Port forwarding" (or "Virtual server" / "NAT"),' $gw) 'Gray'
  Say (T '  and forward TCP port(s) {0} to this PC ({1}), same port numbers.' (($ports | ForEach-Object { "$_" }) -join ', ') $lan) 'Gray'
}

# ------------------------------------------------------------------ CGNAT check
# Is this PC reachable from the internet through port forwarding? Compares the router's WAN address (UPnP) with the
# public address. -> PublicIp, WanIp, Verdict ('ok' | 'cgnat' | 'unknown'), Text (what it means), Vpn, Hint.
function Test-Cgnat {
  $pub = Get-PublicIPv4
  $lan = Get-LanIPv4
  $vpn = Get-ActiveVpn
  $wan = $null
  $verdict = 'unknown'
  $hint = ''
  $has6 = [bool](Get-GlobalIPv6)
  if ($lan -and $pub -and $lan -eq $pub) {
    $wan = $lan
    $verdict = 'ok'
  } else {
    $wan = Get-UpnpWanIp
    if ($wan) {
      if ((Test-NonPublicIPv4 $wan) -or ($pub -and $wan -ne $pub)) { $verdict = 'cgnat' } elseif ($pub) { $verdict = 'ok' }
    } elseif ($pub) {
      $hint = Get-CgnatHopHint
    }
  }
  $lines = @()
  if ($vpn) { $lines += (T 'A VPN is on ({0}): turn it off while you stream from this PC, or viewers can''t reach you.' $vpn) }
  if (-not $pub) {
    $lines += (T 'Could not find this PC''s internet address (no internet, or the address services are blocked).')
  } elseif ($verdict -eq 'ok') {
    $lines += (T 'Good: your router has the public address {0}, so port forwarding can work.' $pub)
  } elseif ($verdict -eq 'cgnat') {
    if (Test-CgnatIPv4 $wan) {
      $lines += (T 'Your provider shares one internet address between many homes (CGNAT: the router got {0}, the internet sees {1}).' $wan $pub)
    } else {
      $lines += (T 'The router''s internet address ({0}) is not your public address ({1}): there is another router or a shared address (CGNAT) in front of it.' $wan $pub)
    }
    $lines += (T 'Port forwarding can''t work like this. Use "my VPS" instead (hides your address too), or ask your provider for a public IPv4.')
    if ($has6) { $lines += (T 'Or use the IPv6 link: it needs no port forwarding, but only viewers with IPv6 can open it.') }
  } else {
    $lines += (T 'The router didn''t say its internet address (UPnP is off or not supported), so it''s not known if port forwarding can work.')
    if ($hint) { $lines += (T 'A hint says it probably can''t: the provider''s network right after the router uses shared addresses ({0}).' $hint) }
    $lines += (T 'Check the router''s status page: if its internet (WAN) address is {0}, it can. If not, use "my VPS".' $pub)
    if ($has6) { $lines += (T 'The IPv6 link needs no port forwarding (only viewers with IPv6 can open it).') }
  }
  return [pscustomobject]@{ PublicIp = $pub; WanIp = $wan; Verdict = $verdict; Text = ($lines -join "`n"); Vpn = $vpn; Hint = $hint }
}

# Second opinion without UPnP: when the first hops after the router use 100.64.0.0/10 addresses, the provider
# very probably uses CGNAT. Returns that hop's address or ''. (A few ICMP echoes with a small TTL; read-only.)
function Get-CgnatHopHint {
  $ping = New-Object System.Net.NetworkInformation.Ping
  try {
    $opt = $null
    for ($ttl = 2; $ttl -le 4; $ttl++) {
      $opt = New-Object System.Net.NetworkInformation.PingOptions($ttl, $true)
      try {
        $r = $ping.Send('1.1.1.1', 800, (New-Object byte[] 16), $opt)
        if ($r.Address) {
          $a = $r.Address.ToString()
          if (Test-CgnatIPv4 $a) { return $a }
          if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { break }
        }
      } catch {}
    }
  } finally { $ping.Dispose() }
  return ''
}

# ------------------------------------------------------------------ firewall (one UAC prompt, removed on exit)
function Get-FirewallStatusPath { return (PathJoin $script:TempRoot ("firewall-$PID.status")) }
function Get-FirewallStopPath { return (PathJoin $script:TempRoot ("firewall-$PID.stop")) }

function ConvertTo-PsQuoted([string]$s) { return "'" + ($s -replace "'", "''") + "'" }

# The script the elevated PowerShell runs: add ONE inbound allow rule for MediaMTX on exactly these TCP ports, then
# wait until this window's process is gone (closed, Ctrl+C, crash) or asks to stop, and delete the rule.
function New-FirewallWatcherScript([string]$exe, [int[]]$ports) {
  $me = [System.Diagnostics.Process]::GetCurrentProcess()
  $start = $me.StartTime.ToFileTimeUtc()
  $portList = (@($ports | ForEach-Object { "'$([int]$_)'" }) -join ',')
  return @"
`$ErrorActionPreference = 'Stop'
`$name = $(ConvertTo-PsQuoted $script:FirewallRuleName)
`$exe = $(ConvertTo-PsQuoted $exe)
`$status = $(ConvertTo-PsQuoted (Get-FirewallStatusPath))
`$stop = $(ConvertTo-PsQuoted (Get-FirewallStopPath))
`$watch = $PID
`$started = $start
function Remove-Ours { Get-NetFirewallRule -DisplayName `$name -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue }
try {
  Remove-Ours
  New-NetFirewallRule -DisplayName `$name -Description 'Added by VRChat Link Maker while it streams from this PC; removed when it closes.' -Direction Inbound -Action Allow -Program `$exe -Protocol TCP -LocalPort @($portList) -Profile Any | Out-Null
  `$blocks = 0
  try { `$blocks = @(Get-NetFirewallApplicationFilter -Program `$exe -ErrorAction SilentlyContinue | Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { `$_.Direction -eq 'Inbound' -and `$_.Action -eq 'Block' -and "`$(`$_.Enabled)" -eq 'True' }).Count } catch {}
  [System.IO.File]::WriteAllText(`$status, "ok `$blocks")
} catch {
  try { [System.IO.File]::WriteAllText(`$status, 'err ' + `$_.Exception.Message) } catch {}
  Remove-Ours
  exit 1
}
try {
  while (`$true) {
    `$p = Get-Process -Id `$watch -ErrorAction SilentlyContinue
    if (-not `$p) { break }
    try { if (`$p.StartTime.ToFileTimeUtc() -ne `$started) { break } } catch {}
    if ([System.IO.File]::Exists(`$stop)) { break }
    Start-Sleep -Seconds 2
  }
} finally {
  Remove-Ours
  try { [System.IO.File]::Delete(`$stop) } catch {}
  try { [System.IO.File]::WriteAllText(`$status, 'removed') } catch {}
}
"@
}

# Let viewers reach MediaMTX through Windows Firewall: one UAC prompt starts a hidden elevated PowerShell that adds
# the rule and removes it when this window closes (also after Ctrl+C or a crash). -> $true when the rule is in place.
# -DryRun prints the elevated script and the command instead of running them.
function Enable-SelfHostFirewall([string]$exe, [int[]]$ports, [switch]$DryRun) {
  $ps = PathJoin $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $code = New-FirewallWatcherScript $exe $ports
  $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($code))
  $argLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand ' + $enc
  if ($DryRun) {
    Say ('  [dry run] ' + (T 'would run as administrator (one UAC prompt): {0}' "$ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand <the script below>")) 'DarkGray'
    foreach ($l in ($code -split "`r?`n")) { Say ('    ' + $l) 'DarkGray' }
    return $true
  }
  if ($script:FirewallWatch -and -not $script:FirewallWatch.HasExited) { return $true }
  [void][System.IO.Directory]::CreateDirectory($script:TempRoot)
  foreach ($f in @((Get-FirewallStatusPath), (Get-FirewallStopPath))) { try { [System.IO.File]::Delete($f) } catch {} }
  Say (T 'Windows will ask to allow a change (UAC): it lets viewers reach MediaMTX on port(s) {0}. The rule is removed when this window closes.' (($ports | ForEach-Object { "$_" }) -join ', ')) 'Gray'
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $ps
  $psi.Arguments = $argLine
  $psi.Verb = 'runas'
  $psi.UseShellExecute = $true
  $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  if (Get-Command Write-StartLog -CommandType Function -ErrorAction SilentlyContinue) { Write-StartLog $psi }
  try {
    $script:FirewallWatch = [System.Diagnostics.Process]::Start($psi)
  } catch {
    $script:FirewallWatch = $null
    Say (T 'No firewall rule was added. If Windows asks whether to allow MediaMTX, allow it, or viewers can''t connect.') 'Yellow'
    return $false
  }
  $status = ''
  $until = (Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $until) {
    try { if ([System.IO.File]::Exists((Get-FirewallStatusPath))) { $status = [System.IO.File]::ReadAllText((Get-FirewallStatusPath)).Trim() } } catch {}
    if ($status) { break }
    try { if ($script:FirewallWatch.HasExited) { break } } catch {}
    Wait-HostPump 300
  }
  if ($status -match '^ok\s+(\d+)') {
    if ([int]$Matches[1] -gt 0) {
      Say (T 'Note: Windows Firewall also has a rule that BLOCKS MediaMTX (probably from an earlier "Cancel"). Block rules win: remove it in "Windows Defender Firewall with Advanced Security" > Inbound Rules.') 'Yellow'
    }
    return $true
  }
  $why = $status -replace '^err\s*', ''
  if (-not $why) { $why = T 'no answer' }
  Say (T 'The firewall rule could not be added ({0}). If Windows asks whether to allow MediaMTX, allow it.' $why) 'Yellow'
  return $false
}

# Remove the rule now (the elevated helper sees the request and deletes it; no new UAC prompt).
function Disable-SelfHostFirewall([switch]$DryRun) {
  if ($DryRun) { Say ('  [dry run] ' + (T 'would ask the elevated helper to remove the firewall rule "{0}"' $script:FirewallRuleName)) 'DarkGray'; return }
  if (-not $script:FirewallWatch) { return }
  try { [System.IO.File]::WriteAllText((Get-FirewallStopPath), 'stop') } catch {}
  try { [void]$script:FirewallWatch.WaitForExit(8000) } catch {}
  $script:FirewallWatch = $null
}

# ------------------------------------------------------------------ Tailscale Funnel (HTTPS link for the HLS mode)
function Get-TailscaleExe {
  $c = Get-Command 'tailscale.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { return $c.Source }
  foreach ($d in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
    if (-not $d) { continue }
    $f = PathJoin (PathJoin $d 'Tailscale') 'tailscale.exe'
    if ([System.IO.File]::Exists($f)) { return $f }
  }
  return $null
}

# `tailscale status --json` as an object, or $null. Time-boxed (the service may hang).
function Get-TailscaleStatus([string]$exe) {
  try {
    $psi = New-StartInfo $exe @('status', '--json') ''
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi); Add-MtxToJob $p
    $out = $p.StandardOutput.ReadToEndAsync()
    [void]$p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(8000)) { Stop-Proc $p; return $null }
    return ($out.Result | ConvertFrom-Json)
  } catch { return $null }
}

# The public HTTPS link of the HLS stream through Tailscale Funnel, or $null (Tailscale missing / logged out).
# Prints the command that turns Funnel on (it is not run here) unless -Quiet.
function Get-TailscaleFunnelUrl([string]$token, [int]$hlsPort = 8888, [switch]$Quiet) {
  $exe = Get-TailscaleExe
  if (-not $exe) {
    if (-not $Quiet) { Say (T 'Tailscale is not installed (free: tailscale.com/download). With it, Funnel gives this PC an HTTPS link without port forwarding.') 'Gray' }
    return $null
  }
  $j = Get-TailscaleStatus $exe
  $state = "$(Get-Prop $j 'BackendState')"
  $self = Get-Prop $j 'Self'
  $dns = "$(Get-Prop $self 'DNSName')".Trim().TrimEnd('.')
  if ($state -ne 'Running' -or -not $dns) {
    if (-not $Quiet) { Say (T 'Tailscale is installed but not logged in (or turned off). Open Tailscale, log in, then try again.') 'Yellow' }
    return $null
  }
  $url = "https://$dns/live/$token/index.m3u8"
  if (-not $Quiet) {
    $capText = ''
    try { $capText = (@(Get-Prop $self 'Capabilities') -join ' ') + ' ' + ((Get-Prop $self 'CapMap') | ConvertTo-Json -Compress -Depth 3) } catch {}
    Say (T 'Tailscale Funnel link (HTTPS, about 10-30 s behind): {0}' $url) 'Gray'
    Say (T 'To turn Funnel on, run this once in a command window (it keeps working in the background):') 'Gray'
    Say ('  "' + $exe + '" funnel --bg ' + $hlsPort) 'White'
    Say (T 'To turn it off again: {0}' ('"' + $exe + '" funnel --https=443 off')) 'DarkGray'
    if ($capText -notmatch 'funnel') { Say (T 'Funnel may first need to be allowed for your tailnet: the command above then shows a link to do that.') 'DarkGray' }
  }
  return $url
}

# ------------------------------------------------------------------ speed test
# Parse an ffmpeg -progress file: the last block's out_time (s), total_size (bytes) and speed.
function Read-ProgressBlock([string]$file) {
  try {
    if (-not [System.IO.File]::Exists($file)) { return $null }
    $fs = New-Object System.IO.FileStream($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $len = $fs.Length
      $take = [int][Math]::Min($len, 4096)
      if ($take -le 0) { return $null }
      [void]$fs.Seek($len - $take, [System.IO.SeekOrigin]::Begin)
      $buf = New-Object byte[] $take
      $n = $fs.Read($buf, 0, $take)
      $txt = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
    } finally { $fs.Dispose() }
    $blocks = [regex]::Split($txt, 'progress=(?:continue|end)')
    for ($i = $blocks.Count - 1; $i -ge 0; $i--) {
      $t = [regex]::Match($blocks[$i], 'out_time_us=(\d+)')
      $s = [regex]::Match($blocks[$i], 'total_size=(\d+)')
      if ($t.Success -and $s.Success) {
        $sp = [regex]::Match($blocks[$i], 'speed=\s*([\d.]+)x')
        $speed = 0.0
        if ($sp.Success) { $speed = [double]::Parse($sp.Groups[1].Value, $script:Inv) }
        return [pscustomobject]@{ Time = [double]$t.Groups[1].Value / 1000000.0; Size = [double]$s.Groups[1].Value; Speed = $speed }
      }
    }
  } catch {}
  return $null
}

function Get-TestSourceArgs([switch]$Realtime) {
  $re = @()
  if ($Realtime) { $re = @('-re') }
  # testsrc2 with a little noise, so the encoder really uses the test bitrate (a clean test picture compresses to almost nothing).
  return $re + @('-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=30,noise=alls=10:allf=t') + $re + @('-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000')
}

function Get-TestEncodeArgs([string]$venc, [int]$kbps, [int]$ak) {
  $a = @('-map', '0:v', '-map', '1:a') + @(Get-VideoEncArgs $venc $kbps 30 -ForTest)
  if ($venc -eq 'libx264') { $a += @('-x264-params', 'nal-hrd=cbr') }
  return $a + @('-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', "$($ak)k", '-ar', '48000', '-ac', '2')
}

# How fast can this PC encode the test stream (no network)? -> speed factor (2.0 = twice real time), 0 = failed.
function Measure-EncodeSpeed([string]$venc, [int]$kbps, [int]$ak) {
  try {
    $argv = @('-hide_banner', '-nostdin') + (Get-TestSourceArgs) + (Get-TestEncodeArgs $venc $kbps $ak) + @('-t', '4', '-f', 'null', '-')
    $r = Invoke-Capture $script:FFmpeg $argv $script:TempRoot
    $ms = [regex]::Matches($r.Err, 'speed=\s*([\d.]+)x')
    if ($ms.Count -gt 0) { return [double]::Parse($ms[$ms.Count - 1].Groups[1].Value, $script:Inv) }
  } catch {}
  return 0.0
}

# Push the synthetic stream to $url for $seconds (real time) and see how much of it got through.
# -> Ok, Speed (1.0 = kept up), NetSpeed (Speed without the PC's own limit: when the encoder alone can't keep up,
#    the network's share is Speed / EncodeSpeed), StreamKbps (what was really sent, audio included), EffectiveKbps
#    (video that got through: video bitrate x NetSpeed), EncodeSpeed, Error.
function Measure-PushSpeed([string]$url, [string]$fmt, [int]$kbps, [int]$seconds = 30) {
  $venc = "$($script:VEnc)"
  if (-not $venc) { $venc = 'libx264' }
  $ak = 128
  $x = 0
  if ([int]::TryParse("$(Get-Prop $script:Cfg 'AudioKbps')", [ref]$x) -and $x -ge 32) { $ak = $x }
  if (-not $fmt) { if ($url -match '^(?i)srt://') { $fmt = 'mpegts' } else { $fmt = 'flv' } }
  [void][System.IO.Directory]::CreateDirectory($script:TempRoot)
  $res = [pscustomobject]@{ Ok = $false; Speed = 0.0; NetSpeed = 0.0; StreamKbps = 0; EffectiveKbps = 0; EncodeSpeed = 0.0; TestKbps = $kbps; Error = '' }
  $res.EncodeSpeed = Measure-EncodeSpeed $venc $kbps $ak
  $prog = PathJoin $script:TempRoot "speedtest-$PID.txt"
  try { [System.IO.File]::Delete($prog) } catch {}
  $argv = @('-hide_banner', '-v', 'error', '-nostats', '-progress', $prog) + (Get-TestSourceArgs -Realtime) + (Get-TestEncodeArgs $venc $kbps $ak) + @('-t', "$($seconds + 20)", '-f', $fmt)
  if ($fmt -eq 'flv') { $argv += @('-flvflags', 'no_duration_filesize') }
  $argv += $url
  $psi = New-StartInfo $script:FFmpeg $argv $script:TempRoot
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  $psi.CreateNoWindow = $true   # (no console window of its own; 'q' still goes in through stdin)
  $p = $null
  $samples = New-Object System.Collections.ArrayList
  try {
    $p = [System.Diagnostics.Process]::Start($psi); Add-MtxToJob $p
    $errTask = $p.StandardError.ReadToEndAsync()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited -and $sw.Elapsed.TotalSeconds -lt $seconds) {
      Wait-HostPump 500
      $b = Read-ProgressBlock $prog
      if ($b) { [void]$samples.Add([pscustomobject]@{ Wall = $sw.Elapsed.TotalSeconds; Time = $b.Time; Size = $b.Size; Speed = $b.Speed }) }
      $left = [int][Math]::Max(0, [Math]::Ceiling($seconds - $sw.Elapsed.TotalSeconds))
      $sp = 0.0
      if ($b) { $sp = $b.Speed }
      Show-Status (T '  Speed test: {0} s left (speed {1}x)' $left (Format-Num ([Math]::Round($sp, 2))))
    }
    if (-not $p.HasExited) {
      Send-Key $p 'q'
      if (-not $p.WaitForExit(5000)) { Stop-Proc $p }
    }
    Clear-StatusLine
    $err = ''
    try { if ($errTask.Wait(3000)) { $err = $errTask.Result } } catch {}
    # Measure after a short warm-up (connecting and filling the network buffers would make the start look fast).
    $warm = [Math]::Min(5.0, $seconds / 5.0)
    $useful = @($samples | Where-Object { $_.Wall -ge $warm -and $_.Time -gt 0 })
    if ($useful.Count -ge 2) {
      $a = $useful[0]; $z = $useful[$useful.Count - 1]
      $dWall = $z.Wall - $a.Wall
      $dTime = $z.Time - $a.Time
      if ($dWall -gt 0.5 -and $dTime -gt 0) {
        $res.Speed = [Math]::Min(1.0, $dTime / $dWall)
        $res.StreamKbps = [int]((($z.Size - $a.Size) * 8.0 / $dTime) / 1000.0)
        $videoSent = [Math]::Min([double]$kbps, [Math]::Max(0.0, $res.StreamKbps - $ak))
        $cpu = 1.0
        if ($res.EncodeSpeed -gt 0 -and $res.EncodeSpeed -lt 1.0) { $cpu = $res.EncodeSpeed }
        $res.NetSpeed = [Math]::Min(1.0, $res.Speed / $cpu)
        $res.EffectiveKbps = [int]($videoSent * $res.NetSpeed)
        $res.Ok = $true
      }
    }
    if (-not $res.Ok) {
      $last = Get-LastLines $err 1
      if (-not $last) { $last = T 'the stream did not start' }
      $res.Error = Hide-UrlSecrets $last.Trim()   # (ffmpeg's message may contain the link with its password)
    }
  } catch {
    $res.Error = Hide-UrlSecrets $_.Exception.Message
  } finally {
    if ($p) { Stop-Proc $p }
    try { [System.IO.File]::Delete($prog) } catch {}
  }
  return $res
}

# Upload speed to Cloudflare's speed test (several connections at once, like several viewers).
# -> Ok, Kbps (all connections together), Bytes, Seconds, Error.
function Measure-UploadSpeed([long]$maxBytes = 40MB, [int]$conns = 4, [int]$timeoutSec = 25, [string]$url = 'https://speed.cloudflare.com/__up') {
  $res = [pscustomobject]@{ Ok = $false; Kbps = 0; Bytes = 0L; Seconds = 0.0; Error = '' }
  $per = [long][Math]::Floor($maxBytes / $conns)
  $buf = New-Object byte[] 65536
  (New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($buf)
  $worker = {
    param([string]$url, [long]$bytes, [int]$timeoutSec, [byte[]]$buf)
    $o = @{ Bytes = 0L; Start = 0L; End = 0L; Status = 0; Error = '' }
    try {
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
      $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($url)
      $req.Method = 'POST'
      $req.ContentType = 'application/octet-stream'
      $req.ContentLength = $bytes
      $req.AllowWriteStreamBuffering = $false
      $req.KeepAlive = $false
      $req.Timeout = $timeoutSec * 1000
      $req.ReadWriteTimeout = $timeoutSec * 1000
      $req.ServicePoint.Expect100Continue = $false
      $req.ServicePoint.ConnectionLimit = 32
      $rs = $req.GetRequestStream()
      $o.Start = [DateTime]::UtcNow.Ticks
      $left = $bytes
      try {
        while ($left -gt 0) {
          $n = [int][Math]::Min($left, [long]$buf.Length)
          $rs.Write($buf, 0, $n)
          $left -= $n
          $o.Bytes += $n
        }
      } finally { $rs.Dispose() }
      $resp = $req.GetResponse()
      $o.Status = [int]$resp.StatusCode
      $resp.Close()
    } catch { $o.Error = $_.Exception.Message }
    $o.End = [DateTime]::UtcNow.Ticks
    return [pscustomobject]$o
  }
  $pool = $null
  $jobs = @()
  try {
    $pool = [runspacefactory]::CreateRunspacePool(1, $conns)
    $pool.Open()
    for ($i = 0; $i -lt $conns; $i++) {
      $ps = [powershell]::Create()
      $ps.RunspacePool = $pool
      [void]$ps.AddScript($worker).AddArgument($url).AddArgument($per).AddArgument($timeoutSec).AddArgument($buf)
      $jobs += [pscustomobject]@{ Ps = $ps; H = $ps.BeginInvoke() }
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (@($jobs | Where-Object { -not $_.H.IsCompleted }).Count -gt 0 -and $sw.Elapsed.TotalSeconds -lt ($timeoutSec + 10)) {
      Show-Status (T '  Measuring upload speed... {0} s' ([int]$sw.Elapsed.TotalSeconds))
      Wait-HostPump 300
    }
    Clear-StatusLine
    $outs = @()
    foreach ($j in $jobs) { if ($j.H.IsCompleted) { $outs += @($j.Ps.EndInvoke($j.H)) } }
    $good = @($outs | Where-Object { -not $_.Error -and $_.Status -eq 200 -and $_.Start -gt 0 })
    if ($good.Count -gt 0) {
      $t0 = ($good | Measure-Object -Property Start -Minimum).Minimum
      $t1 = ($good | Measure-Object -Property End -Maximum).Maximum
      $res.Bytes = [long](($good | Measure-Object -Property Bytes -Sum).Sum)
      $res.Seconds = ($t1 - $t0) / 10000000.0
      if ($res.Seconds -gt 0) { $res.Kbps = [int]($res.Bytes * 8.0 / $res.Seconds / 1000.0); $res.Ok = $true }
    }
    if (-not $res.Ok) {
      $e = @($outs | Where-Object { $_.Error } | ForEach-Object { $_.Error })
      if ($e.Count -gt 0) { $res.Error = $e[0] } else { $res.Error = T 'no answer' }
    }
  } catch {
    $res.Error = $_.Exception.Message
  } finally {
    foreach ($j in $jobs) { try { $j.Ps.Stop() } catch {}; try { $j.Ps.Dispose() } catch {} }
    if ($pool) { try { $pool.Close(); $pool.Dispose() } catch {} }
  }
  return $res
}

# Save a video bitrate for a host profile in config.json (Topaz / custom: VideoKbps; pc: SelfHost.VideoKbps; vps: Vps.VideoKbps).
function Save-HostKbps($p, [int]$kbps) {
  $target = $script:Cfg
  if ($p.Id -eq 'pc') { $target = Get-Prop $script:Cfg 'SelfHost' }
  elseif ($p.Id -eq 'vps') { $target = Get-Prop $script:Cfg 'Vps' }
  if (-not $target) { return $false }
  if ($target.PSObject.Properties['VideoKbps']) { $target.VideoKbps = $kbps } else { $target | Add-Member -NotePropertyName VideoKbps -NotePropertyValue $kbps }
  Save-Config $script:Cfg
  if ("$(Get-Prop $script:Cfg 'Host')" -eq $p.Id -or (-not (Get-Prop $script:Cfg 'Host') -and $p.Id -eq 'topaz')) { $script:VideoKbps = $kbps }
  return $true
}

function Get-Floor50([double]$x) { return [int]([Math]::Floor($x / 50.0) * 50) }

# The speed test (a menu item). Topaz: a throwaway stream key; vps / custom: the profile's own ingest address;
# pc: an upload test (viewers pull from this PC, so the upload speed is the limit). -> Kbps (recommended), Saved, Result.
# -Target / -TargetFormat / -TestKbps override where and how hard it pushes (tests use a local MediaMTX).
# -BeforeRun runs once the test is really going to start (after "yes"): the caller stops the stream there.
# -ViewersWatch: the question says viewers lose the picture meanwhile, and only a real yes starts it (just Enter = no).
function Invoke-SpeedTest($p, [int]$Seconds = 30, [string]$Target = '', [string]$TargetFormat = '', [int]$TestKbps = 0, [int]$UploadMB = 40, [switch]$NoSave, [scriptblock]$BeforeRun = $null, [switch]$ViewersWatch) {
  $out = [pscustomobject]@{ Kbps = 0; Saved = $false; Result = $null }
  if (-not $BeforeRun -and (Test-RelayAlive)) { Say (T 'Stop the stream first: the speed test needs the whole connection.') 'Yellow'; return $out }
  $q = T 'Start the speed test? [Y/n]'
  if ($ViewersWatch) { $q = T 'Viewers lose the picture for about 30-40 s meanwhile. Start the speed test? [y/N]' }
  $ask = Test-CanAsk
  $ak = 128
  $x = 0
  if ([int]::TryParse("$(Get-Prop $script:Cfg 'AudioKbps')", [ref]$x) -and $x -ge 32) { $ak = $x }
  $maxK = [int]$p.MaxKbps
  $minK = [int]$p.MinKbps
  if ($maxK -le 0) { $maxK = 8000 }
  if ($minK -le 0) { $minK = 700 }

  if ($p.Id -eq 'pc' -and -not $Target) {
    Say (T 'Speed test for streaming from this PC: every viewer pulls the stream from your internet line, so what counts is your upload speed.') 'Cyan'
    Say (T 'It sends {0} MB of random test data to speed.cloudflare.com.' $UploadMB) 'Gray'
    if ($ask -and -not (Read-YesNoUi $q (-not $ViewersWatch) -Esc $false)) { return $out }
    if ($BeforeRun) { & $BeforeRun }
    $u = Measure-UploadSpeed ([long]$UploadMB * 1MB)
    $out.Result = $u
    if (-not $u.Ok) { Say (T 'The speed test did not work ({0}).' $u.Error) 'Yellow'; return $out }
    Say (T 'Upload: {0} Mbps.' (Format-Num ([Math]::Round($u.Kbps / 1000.0, 1)))) 'Green'
    $counts = @(2, 5, 10)
    $opts = @()
    $vals = @()
    foreach ($n in $counts) {
      $v = [Math]::Max(0, (Get-Floor50 ((($u.Kbps * 0.8) / $n) - $ak)))
      $v = [Math]::Min($v, $maxK)
      $vals += $v
      $note = ''
      if ($v -lt $minK) { $note = ' ' + (T '(too little: fewer viewers, or use "my VPS")') }
      $opts += (T '{0} viewers: {1} kbps video each' $n $v) + $note
    }
    foreach ($o in $opts) { Say ('   ' + $o) 'Gray' }
    Say (T 'Viewers far away may get less than this.') 'DarkGray'
    $out.Kbps = $vals[1]
    if ($ask -and -not $NoSave) {
      $i = Read-Choice (T 'Use which bitrate for this PC? (0 = keep the current one)') $opts 1 $true -Esc -1
      if ($i -ge 0) {
        $k = [Math]::Max($vals[$i], $minK)
        $out.Kbps = $k
        $out.Saved = Save-HostKbps $p $k
        if ($out.Saved) { Say (T 'Saved: {0} kbps (used from the next video).' $k) 'Green' }
      }
    }
    return $out
  }

  $url = $Target
  $fmt = $TargetFormat
  $kbps = $TestKbps
  $where = ''
  if (-not $url) {
    if ($p.Id -eq 'topaz') {
      $url = 'rtmp://topaz.chat/live/' + (New-StreamKey)   # a throwaway key: nobody watches it
      $fmt = 'flv'
      $where = 'Topaz Chat'
    } else {
      $url = "$($p.IngestUrl)"
      $fmt = "$($p.IngestFormat)"
      try { $where = ([Uri]$url).Host } catch { $where = $url }
    }
  } else {
    try { $where = ([Uri]$url).Host } catch { $where = $url }
  }
  if (-not $url) { Say (T 'This host has no stream address to test.') 'Yellow'; return $out }
  if ($kbps -le 0) {
    if ($p.Id -eq 'topaz') { $kbps = 2000 } else { $kbps = [Math]::Min(12000, [Math]::Max($maxK, 2000)) }
  }
  Say (T 'Speed test: sends a test picture at {0} kbps to {1} for about {2} s and measures how much gets through.' $kbps $where $Seconds) 'Cyan'
  if ($p.Id -eq 'custom' -and -not $Target) { Say (T 'This uses your own stream address: if it is a public channel (e.g. Twitch), people may see the test picture.') 'Yellow' }
  if ($ask -and -not (Read-YesNoUi $q (-not $ViewersWatch) -Esc $false)) { return $out }
  if ($BeforeRun) { & $BeforeRun }
  $r = Measure-PushSpeed $url $fmt $kbps $Seconds
  $out.Result = $r
  if (-not $r.Ok) {
    Say (T 'The speed test did not work ({0}).' $r.Error) 'Yellow'
    Say (T 'Check that the server is running and that its address, port and password are right.') 'Gray'
    return $out
  }
  if ($r.EncodeSpeed -gt 0 -and $r.EncodeSpeed -lt 1.0) {
    Say (T 'Note: with the current settings this PC can''t encode {0} kbps in real time ({1}x). The line was measured anyway, but streaming this high would stutter because of the PC.' $kbps (Format-Num ([Math]::Round($r.EncodeSpeed, 2)))) 'Yellow'
  } elseif ($r.EncodeSpeed -gt 0 -and $r.EncodeSpeed -lt 1.15) {
    Say (T 'Note: this PC only just encodes the test picture in real time ({0}x), so the result may be lower than your line can do.' (Format-Num ([Math]::Round($r.EncodeSpeed, 2)))) 'Yellow'
  }
  Say (T 'Result: {0}x real time, about {1} kbps of video got through.' (Format-Num ([Math]::Round($r.NetSpeed, 2))) $r.EffectiveKbps) 'Green'
  if ($r.NetSpeed -ge 0.95) { Say (T 'The whole test stream got through, so the line may take even more.') 'DarkGray' }
  $rec = Get-Floor50 ([Math]::Min($r.EffectiveKbps * 0.8, $maxK))
  if ($rec -lt $minK) {
    Say (T 'That is below {0} kbps, the lowest this tool uses for this host: expect stutter.' $minK) 'Yellow'
    $rec = $minK
  }
  $out.Kbps = $rec
  Say (T 'Recommended video bitrate: {0} kbps (80% of what got through, at most {1}).' $rec $maxK) 'Cyan'
  if ($ask -and -not $NoSave) {
    if (Read-YesNoUi (T 'Save {0} kbps for {1}? [Y/n]' $rec $p.Name) $true -Esc $false) {
      $out.Saved = Save-HostKbps $p $rec
      if ($out.Saved) { Say (T 'Saved: {0} kbps (used from the next video).' $rec) 'Green' }
    }
  }
  return $out
}
