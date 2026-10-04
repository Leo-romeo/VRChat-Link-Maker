# VRChat Link Maker - web sites
# ------------------------------
# Loaded by VRChatLinkMaker.ps1. Reads anime / video sites the way their own web players do and finds the
# actual video stream (an HLS playlist or an MP4 file) plus the headers the video server expects.
# Sites change their players now and then; when one breaks, this is the file to update.
#
# Needs from VRChatLinkMaker.ps1: Invoke-Web, ConvertTo-FormBody, ConvertFrom-JsonDict, ConvertFrom-HtmlText, $script:WebUA.

# ==================================================================================================
# Kodik (kodikplayer.com): the player most sites embed
# ==================================================================================================
# VERIFIED COPY (research/kodik-verify): fixes vs research/kodik/kodik.ps1 = complete Qualities (720 probed even when 1080 exists), optional
# $maxQuality cap, step-down when the chosen manifest fails, no silent wrong-season fallback, clearer POST/find-player errors, working shift cached.
# Kodik resolver for VRChat Link Maker - Windows PowerShell 5.1 (.NET Framework 4.x).
# Requires the shared helper to be dot-sourced first (Invoke-Web, ConvertTo-FormBody, ConvertFrom-JsonDict, ConvertFrom-HtmlText).
#
# Public functions:
#   Test-KodikUrl      [string]$url                                   -> bool
#   Resolve-Kodik      [string]$playerUrl, [string]$referer, [int]$season = 0, [int]$episode = 0, [int]$maxQuality = 0
#                      -> [pscustomobject] Url, Qualities, Headers, Title, Duration, Expires, ...
#   Get-KodikEpisodes  [string]$playerUrl, [string]$referer          -> [pscustomobject] Seasons, Episodes, Translations, ...
#
# Flow (verified 2026-09-27):
#   player page  GET https://kodikplayer.com/{seria|serial|video}/<id>/<hash>/720p?...   (Referer = embedding site, optional)
#     -> var urlParams = '{"d":..,"d_sign":..,"pd":..,"pd_sign":..,"ref":..,"ref_sign":..}' ; vInfo.type/hash/id ;
#        <script src="/assets/js/app.player_single.<sha>.js">
#   player JS    -> POST endpoint hidden as $.ajax({type:"POST",url:atob("L2Z0b3I=")...}) = "/ftor" ; decode shift "charCodeAt(0)+18"
#   POST <origin>/ftor  form: d,d_sign,pd,pd_sign,ref,ref_sign,bad_user,cdn_is_working,type,hash,id,info
#     -> {"links":{"240":[{"src":"<rot+base64>","type":"application/x-mpegURL"}],"360":..,"480":..,"720":..}}
#   src decode: rotate letters by +18 (A-Z / a-z separately), then base64 -> "https://sky.solodcdn.com/.../<sig>:<YYYYMMDDHH>/480.mp4:hls:manifest.m3u8"
#   The "720" entry often points to 480.mp4; replacing the number with 720/1080 works when that rendition exists (both probed;
#   1080 exists for some titles, e.g. Overlord S3 AniLibria = 1920x1080).
#   find-player  (wparty) -> GET https://kodik-api.com/get-player?token=..&kinopoiskID|shikimoriID=..&translationID=..&season=..&episode=..
#     -> {"found":true,"allowed":1,"link":"//kodikplayer.com/serial/<id>/<hash>/720p"} -> serial page ?season=S&episode=E

$script:KodikDefaultHost = 'kodikplayer.com'
$script:KodikEndpointCache = @{}          # player JS file name -> @{ Endpoint = '/ftor'; Shift = 18 }
$script:KodikApiConfig = $null            # @{ Api = 'https://kodik-api.com/get-player'; Token = '...' }
$script:KodikApiDefault = @{ Api = 'https://kodik-api.com/get-player'; Token = '447d179e875efe44217f20d1ee2146be' }
$script:KodikAddPlayersJs = 'https://kodik-add.com/add-players.min.js?v=2'
$script:KodikFallbackEndpoints = @('/ftor', '/tri', '/kor', '/vdu', '/gvi')

# ---------------------------------------------------------------- small helpers

function ConvertTo-KodikAbsoluteUrl([string]$u) {
  $u = $u.Trim()
  if ($u.StartsWith('//')) { $u = 'https:' + $u }
  elseif ($u -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $u = 'https://' + $u.TrimStart('/') }
  if ($u -match '^(?i)http://') { $u = 'https://' + $u.Substring(7) }
  return $u
}

function Test-KodikUrl([string]$url) {
  if (-not $url) { return $false }
  try { $u = [Uri](ConvertTo-KodikAbsoluteUrl $url) } catch { return $false }
  # any host with the Kodik path shape (Kodik rotates mirror domains), or a known Kodik host with find-player
  if ($u.AbsolutePath -match '(?i)^/(seria|serial|video)/\d+/[0-9a-f]{32}/\d+p') { return $true }
  $hostOk = $u.Host -match '(?i)(^|\.)(kodik[a-z0-9-]*\.[a-z]+|aniqit\.com)$'
  $pathOk = $u.AbsolutePath -match '(?i)^/(seria|serial|video)/\d+/[0-9a-f]{16,}(/|$)' -or $u.AbsolutePath -match '(?i)^/find-player'
  return ($hostOk -and $pathOk)
}

function ConvertFrom-KodikQuery([string]$query) {
  $d = [ordered]@{}
  if (-not $query) { return $d }
  foreach ($part in $query.TrimStart('?').Split('&')) {
    if (-not $part) { continue }
    $i = $part.IndexOf('=')
    if ($i -lt 0) { $k = $part; $v = '' } else { $k = $part.Substring(0, $i); $v = $part.Substring($i + 1) }
    try { $k = [Uri]::UnescapeDataString($k.Replace('+', ' ')) } catch {}
    try { $v = [Uri]::UnescapeDataString($v.Replace('+', ' ')) } catch {}
    $d[$k] = $v
  }
  return $d
}

function Join-KodikQuery($dict) {
  $parts = foreach ($k in $dict.Keys) { [Uri]::EscapeDataString([string]$k) + '=' + [Uri]::EscapeDataString([string]$dict[$k]) }
  return ($parts -join '&')
}

# Replace/add query parameters of a URL (values $null remove the key).
function Set-KodikUrlQuery([string]$url, $changes) {
  $q = ''; $base = $url
  $i = $url.IndexOf('?')
  if ($i -ge 0) { $base = $url.Substring(0, $i); $q = $url.Substring($i + 1) }
  $d = ConvertFrom-KodikQuery $q
  foreach ($k in $changes.Keys) {
    if ($null -eq $changes[$k]) { if ($d.Contains($k)) { $d.Remove($k) } } else { $d[$k] = [string]$changes[$k] }
  }
  if ($d.Count -eq 0) { return $base }
  return $base + '?' + (Join-KodikQuery $d)
}

function ConvertFrom-KodikBase64([string]$b) {
  $b = $b.Trim().Replace('-', '+').Replace('_', '/')
  $r = $b.Length % 4
  if ($r -eq 1) { return $null }
  if ($r -eq 2) { $b += '==' } elseif ($r -eq 3) { $b += '=' }
  try { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b)) } catch { return $null }
}

# Decode an obfuscated "src" from the links JSON: rotate letters by N then base64. Tries the shift found in the
# player JS first, then 18 / 13, then every shift 0..25, until the result looks like a media URL.
$script:KodikLastShift = -1                # shift that decoded the last src (-1 = plain / none)
function ConvertFrom-KodikSrc([string]$src, [int]$preferredShift = -1) {
  $script:KodikLastShift = -1
  if (-not $src) { return $null }
  if ($src.Contains('//')) { return $src }                   # already plain (player does the same check)
  $order = New-Object System.Collections.Generic.List[int]
  if ($preferredShift -ge 0) { $order.Add($preferredShift % 26) }
  foreach ($s in @(18, 13)) { if (-not $order.Contains($s)) { $order.Add($s) } }
  for ($s = 0; $s -lt 26; $s++) { if (-not $order.Contains($s)) { $order.Add($s) } }
  foreach ($sh in $order) {
    $chars = $src.ToCharArray()
    for ($k = 0; $k -lt $chars.Length; $k++) {
      $c = [int]$chars[$k]
      if ($c -ge 65 -and $c -le 90) { $chars[$k] = [char](65 + (($c - 65 + $sh) % 26)) }
      elseif ($c -ge 97 -and $c -le 122) { $chars[$k] = [char](97 + (($c - 97 + $sh) % 26)) }
    }
    $dec = ConvertFrom-KodikBase64 (-join $chars)
    if ($dec -and $dec -match '^(https?:)?//' -and $dec -match '(?i)(\.m3u8|\.mp4)') { $script:KodikLastShift = $sh; return $dec }
  }
  return $null
}

# GET a Kodik page; if the host is dead (several old Kodik domains are NXDOMAIN now) retry on kodikplayer.com.
function Invoke-KodikGet([string]$url, [string]$referer) {
  $hdr = @{}
  if ($referer) { $hdr['Referer'] = $referer }
  $cands = New-Object System.Collections.Generic.List[string]
  $cands.Add($url)
  $h = ([Uri]$url).Host
  if ($h -ne $script:KodikDefaultHost) { $cands.Add(($url -replace '^https://[^/]+', ('https://' + $script:KodikDefaultHost))) }
  $lastErr = ''
  foreach ($x in $cands) {
    try { $r = Invoke-Web -Url $x -Headers $hdr -TimeoutSec 20 }
    catch { $lastErr = $_.Exception.Message; continue }
    if ($r.Status -eq 200 -and $r.Text) { return $r }
    $lastErr = "HTTP $($r.Status)"
  }
  throw "Kodik: cannot load $url ($lastErr)"
}

function Get-KodikBlock([string]$html, [string]$startMarker, [string]$endMarker) {
  $i = $html.IndexOf($startMarker)
  if ($i -lt 0) { return '' }
  $j = $html.IndexOf($endMarker, $i + $startMarker.Length)
  if ($j -lt 0) { $j = $html.Length }
  return $html.Substring($i, $j - $i)
}

# Parse every <option ...>text</option> of an HTML fragment into hashtables of attributes (+ '_text').
function Get-KodikOptions([string]$fragment) {
  $list = New-Object System.Collections.ArrayList
  if (-not $fragment) { return , $list }
  foreach ($m in [regex]::Matches($fragment, '(?s)<option\b([^>]*)>(.*?)</option>')) {
    $a = @{}
    foreach ($am in [regex]::Matches($m.Groups[1].Value, '([\w-]+)\s*=\s*"([^"]*)"')) { $a[$am.Groups[1].Value] = ConvertFrom-HtmlText $am.Groups[2].Value }
    $a['_text'] = (ConvertFrom-HtmlText ([regex]::Replace($m.Groups[2].Value, '\s+', ' '))).Trim()
    [void]$list.Add($a)
  }
  return , $list
}

function ConvertTo-KodikInt($v) { $n = 0; if ([int]::TryParse([string]$v, [ref]$n)) { return $n } else { return 0 } }

# Everything the resolver needs from a player page.
function Get-KodikPageInfo([string]$html) {
  $p = @{ Params = @{}; Type = $null; Id = $null; Hash = $null; PlayerJs = $null; TranslationId = $null; TranslationTitle = $null; PageTitle = $null }
  $m = [regex]::Match($html, "var\s+urlParams\s*=\s*'([^']*)'")
  if ($m.Success) { try { $j = ConvertFrom-JsonDict $m.Groups[1].Value; foreach ($k in $j.Keys) { $p.Params[$k] = $j[$k] } } catch {} }
  # fallback: plain JS vars (var domain = "..."; var d_sign = "..."; ...)
  $map = @{ d = 'domain'; d_sign = 'd_sign'; pd = 'pd'; pd_sign = 'pd_sign'; ref = 'ref'; ref_sign = 'ref_sign' }
  foreach ($k in $map.Keys) {
    if (-not $p.Params.ContainsKey($k)) {
      $mm = [regex]::Match($html, 'var\s+' + $map[$k] + '\s*=\s*"([^"]*)"')
      if ($mm.Success) { $p.Params[$k] = $mm.Groups[1].Value }
    }
  }
  foreach ($k in @('type', 'hash', 'id')) {
    $mm = [regex]::Match($html, 'vInfo\.' + $k + '\s*=\s*[''"]([^''"]*)[''"]')
    if ($mm.Success) { $p[($k.Substring(0, 1).ToUpper() + $k.Substring(1))] = $mm.Groups[1].Value }
  }
  if (-not $p.Type) { $mm = [regex]::Match($html, 'var\s+type\s*=\s*"([^"]+)"'); if ($mm.Success) { $p.Type = $mm.Groups[1].Value } }
  if (-not $p.Id) { $mm = [regex]::Match($html, 'var\s+videoId\s*=\s*"([^"]+)"'); if ($mm.Success) { $p.Id = $mm.Groups[1].Value } }
  $mm = [regex]::Match($html, 'src="([^"]*/assets/js/app\.player_single[^"]*\.js[^"]*)"')
  if (-not $mm.Success) { $mm = [regex]::Match($html, 'src="([^"]*/assets/js/app\.(?:player|serial|movie)[^"]*\.js[^"]*)"') }
  if ($mm.Success) { $p.PlayerJs = $mm.Groups[1].Value }
  $mm = [regex]::Match($html, 'var\s+translationId\s*=\s*(\d+)'); if ($mm.Success) { $p.TranslationId = [int]$mm.Groups[1].Value }
  $mm = [regex]::Match($html, 'var\s+translationTitle\s*=\s*"([^"]*)"'); if ($mm.Success) { $p.TranslationTitle = ConvertFrom-HtmlText $mm.Groups[1].Value }
  $mm = [regex]::Match($html, '<title>([^<]*)</title>')
  if ($mm.Success) { $t = (ConvertFrom-HtmlText $mm.Groups[1].Value).Trim(); if ($t -and $t -notmatch '^(?i)kodik player$|^player$') { $p.PageTitle = $t } }
  return $p
}

# Seasons / episodes / translations of a serial page (empty lists for seria/video pages).
function Get-KodikPanel([string]$html, [string]$origin) {
  $seasons = New-Object System.Collections.ArrayList
  foreach ($o in (Get-KodikOptions (Get-KodikBlock $html 'class="serial-seasons-box"' '</select>'))) {
    [void]$seasons.Add([pscustomobject]@{
        Season           = ConvertTo-KodikInt $o['value']
        Title            = $o['data-title']
        SerialId         = $o['data-serial-id']
        SerialHash       = $o['data-serial-hash']
        OtherTranslation = ($o['data-other-translation'] -eq 'true')
        TranslationTitle = $o['data-translation-title']
        Selected         = $o.ContainsKey('selected')
        Url              = $origin + '/serial/' + $o['data-serial-id'] + '/' + $o['data-serial-hash'] + '/720p'
      })
  }
  $episodes = New-Object System.Collections.ArrayList
  $all = Get-KodikBlock $html 'class="series-options"' 'class="serial-next-button'
  if (-not $all) { $all = Get-KodikBlock $html 'class="series-options"' 'class="serial-translations-box"' }
  if ($all) {
    foreach ($sm in [regex]::Matches($all, '(?s)<div class="season-(-?\d+)">(.*?)</div>')) {
      $sn = [int]$sm.Groups[1].Value
      foreach ($o in (Get-KodikOptions $sm.Groups[2].Value)) {
        [void]$episodes.Add([pscustomobject]@{
            Season = $sn; Episode = ConvertTo-KodikInt $o['value']; Value = $o['value']; Title = $o['data-title']
            Id = $o['data-id']; Hash = $o['data-hash']; OtherTranslation = ($o['data-other-translation'] -eq 'true')
            Url = $origin + '/seria/' + $o['data-id'] + '/' + $o['data-hash'] + '/720p'
          })
      }
    }
  }
  if ($episodes.Count -eq 0) {
    # older layout: only the current season's <select>
    $cur = 0; foreach ($s in $seasons) { if ($s.Selected) { $cur = $s.Season } }
    foreach ($o in (Get-KodikOptions (Get-KodikBlock $html 'class="serial-series-box"' '</select>'))) {
      [void]$episodes.Add([pscustomobject]@{
          Season = $cur; Episode = ConvertTo-KodikInt $o['value']; Value = $o['value']; Title = $o['data-title']
          Id = $o['data-id']; Hash = $o['data-hash']; OtherTranslation = ($o['data-other-translation'] -eq 'true')
          Url = $origin + '/seria/' + $o['data-id'] + '/' + $o['data-hash'] + '/720p'
        })
    }
  }
  $translations = New-Object System.Collections.ArrayList
  $tb = Get-KodikBlock $html 'class="serial-translations-box"' '</select>'
  if (-not $tb) { $tb = Get-KodikBlock $html 'class="movie-translations-box"' '</select>' }
  foreach ($o in (Get-KodikOptions $tb)) {
    [void]$translations.Add([pscustomobject]@{
        Id = ConvertTo-KodikInt $o['data-id']; Title = $o['data-title']; Type = $o['data-translation-type']
        MediaType = $o['data-media-type']; MediaId = $o['data-media-id']; MediaHash = $o['data-media-hash']
        EpisodeCount = ConvertTo-KodikInt $o['data-episode-count']; Selected = $o.ContainsKey('selected')
        Url = $origin + '/' + $o['data-media-type'] + '/' + $o['data-media-id'] + '/' + $o['data-media-hash'] + '/720p'
      })
  }
  $curSeason = 0; foreach ($s in $seasons) { if ($s.Selected) { $curSeason = $s.Season } }
  $curEp = $null
  foreach ($o in (Get-KodikOptions (Get-KodikBlock $html 'class="serial-series-box"' '</select>'))) { if ($o.ContainsKey('selected')) { $curEp = ConvertTo-KodikInt $o['value'] } }
  return [pscustomobject]@{ Seasons = $seasons; Episodes = $episodes; Translations = $translations; CurrentSeason = $curSeason; CurrentEpisode = $curEp }
}

# POST endpoint + letter shift, discovered from the player JS and cached per JS file name.
function Get-KodikEndpoint([string]$origin, [string]$jsPath, [string]$referer) {
  $name = ($jsPath -split '\?')[0]
  $name = $name.Substring($name.LastIndexOf('/') + 1)
  if ($script:KodikEndpointCache.ContainsKey($name)) { return $script:KodikEndpointCache[$name] }
  $res = @{ Endpoint = $null; Shift = -1; Js = $name }
  $jsUrl = $jsPath
  if ($jsUrl.StartsWith('//')) { $jsUrl = 'https:' + $jsUrl } elseif ($jsUrl.StartsWith('/')) { $jsUrl = $origin + $jsUrl }
  $js = $null
  try { $r = Invoke-Web -Url $jsUrl -Headers @{ Referer = $referer } -TimeoutSec 20; if ($r.Status -eq 200) { $js = $r.Text } } catch {}
  if ($js) {
    $rx = 'url\s*:\s*(?:atob\(\s*["'']([A-Za-z0-9+/=_-]+)["'']\s*\)|["''](/[A-Za-z0-9_/-]*)["''])'
    $i = $js.IndexOf('cdn_is_working')
    if ($i -ge 0) {
      $m = [regex]::Match($js.Substring($i, [Math]::Min(4000, $js.Length - $i)), $rx)
      if ($m.Success) { if ($m.Groups[1].Success) { $res.Endpoint = ConvertFrom-KodikBase64 $m.Groups[1].Value } else { $res.Endpoint = $m.Groups[2].Value } }
    }
    if (-not $res.Endpoint) {
      foreach ($m in [regex]::Matches($js, 'type\s*:\s*"POST"\s*,\s*url\s*:\s*atob\(\s*"([A-Za-z0-9+/=]+)"\s*\)')) {
        $e = ConvertFrom-KodikBase64 $m.Groups[1].Value
        if ($e -and $e.StartsWith('/')) { $res.Endpoint = $e; break }
      }
    }
    $m = [regex]::Match($js, 'charCodeAt\(0\)\s*\+\s*(\d+)')
    if ($m.Success) { $res.Shift = [int]$m.Groups[1].Value % 26 }
    if ($res.Endpoint -and $res.Endpoint -notmatch '^/[A-Za-z0-9_/-]+$') { $res.Endpoint = $null }
  }
  if ($res.Endpoint) { $script:KodikEndpointCache[$name] = $res }   # failures are not cached
  return $res
}

# find-player API config (token lives in kodik-add.com/add-players.min.js); fetched once per session.
function Get-KodikApiConfig {
  if ($script:KodikApiConfig) { return $script:KodikApiConfig }
  $cfg = @{ Api = $script:KodikApiDefault.Api; Token = $script:KodikApiDefault.Token }
  try {
    $r = Invoke-Web -Url $script:KodikAddPlayersJs -TimeoutSec 15
    if ($r.Status -eq 200) {
      $m = [regex]::Match($r.Text, '\.token\s*=\s*"([0-9a-fA-F]{16,64})"'); if ($m.Success) { $cfg.Token = $m.Groups[1].Value }
      $m = [regex]::Match($r.Text, '"(https://[^"]+/get-player)"'); if ($m.Success) { $cfg.Api = $m.Groups[1].Value }
    }
  } catch {}
  $script:KodikApiConfig = $cfg
  return $cfg
}

# find-player URL -> serial/video URL (+ season/episode query), via kodik-api get-player (same call add-players.min.js makes).
function Resolve-KodikFindPlayer([string]$findUrl, [int]$season = 0, [int]$episode = 0) {
  $u = [Uri]$findUrl
  $q = ConvertFrom-KodikQuery $u.Query
  $cfg = Get-KodikApiConfig
  $p = [ordered]@{ title = 'Player'; hasPlayer = 'false'; url = $findUrl; token = $cfg.Token }
  foreach ($k in @('kinopoiskID', 'imdbID', 'mdlID', 'worldartAnimationID', 'worldartCinemaID', 'worldartLink', 'types', 'camrip', 'blockTranslations', 'translationType', 'prioritizeTranslations', 'unprioritizeTranslations')) {
    if ($q.Contains($k) -and $q[$k] -ne '') { $p[$k] = $q[$k] }
  }
  if ($q.Contains('shikimoriID') -and $q['shikimoriID'] -match '(\d+)') { $p['shikimoriID'] = $Matches[1] }
  $tr = $null
  if ($q.Contains('onlyTranslationID')) { $tr = ($q['onlyTranslationID'] -replace '[\[\]\s"]', '') }
  if ($tr) { $p['translationID'] = $tr }
  $s = $season; $e = $episode
  if ($s -le 0 -and $q.Contains('season')) { $s = ConvertTo-KodikInt $q['season'] }
  if ($e -le 0 -and $q.Contains('episode')) { $e = ConvertTo-KodikInt $q['episode'] }
  if ($s -gt 0) { $p['season'] = $s }
  if ($e -gt 0) { $p['episode'] = $e }
  $r = Invoke-Web -Url ($cfg.Api + '?' + (Join-KodikQuery $p)) -Headers @{ Referer = $findUrl } -TimeoutSec 20
  $j = $null; try { $j = ConvertFrom-JsonDict $r.Text } catch {}
  if (-not $j) { throw "Kodik find-player: bad API answer (HTTP $($r.Status))" }
  if ($j.ContainsKey('error')) { throw ('Kodik find-player: API error: ' + $j['error']) }
  if ($j['found'] -and $j['link'] -and [string]$j['allowed'] -ne '1' -and [string]$j['allowed'] -ne 'True') { throw 'Kodik find-player: found but not allowed (region/rights block, allowed=' + $j['allowed'] + ') for ' + $u.Query }
  if (-not $j['found'] -or -not $j['link']) { throw 'Kodik find-player: nothing found for ' + $u.Query + ' (Kodik has no such title/translation/season/episode)' }
  $link = ConvertTo-KodikAbsoluteUrl ([string]$j['link'])
  $add = [ordered]@{}
  if ($s -gt 0) { $add['season'] = $s }
  if ($e -gt 0) { $add['episode'] = $e }
  if ($add.Count -gt 0) { $link = Set-KodikUrlQuery $link $add }
  return [pscustomobject]@{ Link = $link; Season = $s; Episode = $e; ApiTranslation = $j['translation']; ApiQuality = $j['quality'] }
}

# Probe an HLS manifest: returns the response (with .Text) when it is a playlist, else $null.
function Test-KodikManifest([string]$url) {
  try { $r = Invoke-Web -Url $url -TimeoutSec 15 } catch { return $null }
  if ($r.Status -eq 200 -and $r.Text -match '#EXTM3U') { return $r }
  return $null
}

function Get-KodikFileQuality([string]$url) {
  $m = [regex]::Match($url, '/(\d{3,4})\.mp4(?::hls:manifest\.m3u8)?(?:$|\?)')
  if ($m.Success) { return [int]$m.Groups[1].Value }
  return 0
}

# ---------------------------------------------------------------- public API

# Resolve any Kodik player URL to direct HLS URLs.
#   $playerUrl : //kodikplayer.com/seria/<id>/<hash>/720p?..., /serial/..., /video/..., <any-kodik-host>/find-player?...
#   $referer   : embedding site (https://animego.me/, https://wparty.net/); optional, Kodik does not require it today
#   $season/$episode : for serial pages / find-player (0 = keep whatever the URL/page selects)
#   $maxQuality : optional cap (e.g. 720); 0 = best available. 1080 exists for some titles (e.g. Overlord S3 AniLibria).
function Resolve-Kodik([string]$playerUrl, [string]$referer = '', [int]$season = 0, [int]$episode = 0, [int]$maxQuality = 0) {
  $url = ConvertTo-KodikAbsoluteUrl $playerUrl
  $u = [Uri]$url
  if ($u.AbsolutePath -match '(?i)^/find-player') {
    $fp = Resolve-KodikFindPlayer $url $season $episode
    $url = $fp.Link; $season = $fp.Season; $episode = $fp.Episode
    $u = [Uri]$url
  }
  elseif ($u.AbsolutePath -match '(?i)^/serial/' -and ($season -gt 0 -or $episode -gt 0)) {
    $add = [ordered]@{}
    if ($season -gt 0) { $add['season'] = $season }
    if ($episode -gt 0) { $add['episode'] = $episode }
    $url = Set-KodikUrlQuery $url $add
  }
  if (-not $referer) { $referer = 'https://' + $script:KodikDefaultHost + '/' }

  $page = Invoke-KodikGet $url $referer
  $pageUrl = $page.Url
  $origin = ([Uri]$pageUrl).GetLeftPart([UriPartial]::Authority)
  $info = Get-KodikPageInfo $page.Text
  $vType = $info.Type; $vId = $info.Id; $vHash = $info.Hash
  $epTitle = $null; $seasonTitle = $null; $pickedSeason = 0; $pickedEpisode = 0

  if ([Uri]$pageUrl -and ([Uri]$pageUrl).AbsolutePath -match '(?i)^/serial/') {
    $panel = Get-KodikPanel $page.Text $origin
    $wantS = $season; $wantE = $episode
    if ($wantS -le 0) { $wantS = $panel.CurrentSeason }
    if ($wantE -le 0 -and $null -ne $panel.CurrentEpisode) { $wantE = $panel.CurrentEpisode }
    $pick = $null
    foreach ($ep in $panel.Episodes) { if ($ep.Season -eq $wantS -and $ep.Episode -eq $wantE) { $pick = $ep; break } }
    if (-not $pick -and $season -gt 0) {
      # requested season belongs to another serial (e.g. other translation) -> load it
      foreach ($s in $panel.Seasons) {
        if ($s.Season -eq $season -and $s.SerialId -and $pageUrl -notmatch ('/serial/' + $s.SerialId + '/')) {
          $url2 = Set-KodikUrlQuery $s.Url ([ordered]@{ season = $season; episode = $wantE })
          $page = Invoke-KodikGet $url2 $referer
          $pageUrl = $page.Url
          $info = Get-KodikPageInfo $page.Text
          $vType = $info.Type; $vId = $info.Id; $vHash = $info.Hash
          $panel = Get-KodikPanel $page.Text $origin
          foreach ($ep in $panel.Episodes) { if ($ep.Season -eq $season -and $ep.Episode -eq $wantE) { $pick = $ep; break } }
          break
        }
      }
    }
    if ($pick) {
      $vType = 'seria'; $vId = $pick.Id; $vHash = $pick.Hash; $epTitle = $pick.Title
      $pickedSeason = $pick.Season; $pickedEpisode = $pick.Episode
    }
    elseif (($episode -gt 0 -or $season -gt 0) -and $panel.Episodes.Count -gt 0) {
      # never fall back silently to the page's default episode when a specific season/episode was asked for
      $have = ($panel.Episodes | Group-Object Season | ForEach-Object { 'S' + $_.Name + ':' + $_.Count }) -join ' '
      throw "Kodik: season $wantS episode $wantE not found (this serial has $($panel.Episodes.Count) episodes: $have)"
    }
    foreach ($s in $panel.Seasons) { if ($s.Season -eq $pickedSeason) { $seasonTitle = $s.Title } }
  }
  if (-not $vType -or -not $vId -or -not $vHash) { throw 'Kodik: vInfo (type/id/hash) not found in player page' }
  foreach ($k in @('d', 'd_sign', 'pd', 'pd_sign', 'ref_sign')) { if (-not $info.Params.ContainsKey($k)) { throw "Kodik: urlParams.$k missing in player page" } }

  # POST endpoint from the player JS (cached per JS file)
  $ep = @{ Endpoint = $null; Shift = -1 }
  if ($info.PlayerJs) { $ep = Get-KodikEndpoint $origin $info.PlayerJs $pageUrl }
  $endpoints = New-Object System.Collections.Generic.List[string]
  if ($ep.Endpoint) { $endpoints.Add($ep.Endpoint) }
  foreach ($e in $script:KodikFallbackEndpoints) { if (-not $endpoints.Contains($e)) { $endpoints.Add($e) } }

  $refVal = [string]$info.Params['ref']
  try { $refVal = [Uri]::UnescapeDataString($refVal) } catch {}
  $fields = [ordered]@{
    d = $info.Params['d']; d_sign = $info.Params['d_sign']; pd = $info.Params['pd']; pd_sign = $info.Params['pd_sign']
    ref = $refVal; ref_sign = $info.Params['ref_sign']; bad_user = 'true'; cdn_is_working = 'true'
    type = $vType; hash = $vHash; id = $vId; info = '{}'
  }
  $body = ConvertTo-FormBody $fields
  $hdr = @{ 'X-Requested-With' = 'XMLHttpRequest'; Referer = $pageUrl; Origin = $origin; Accept = 'application/json, text/javascript, */*; q=0.01' }
  $json = $null; $usedEndpoint = $null; $errs = New-Object System.Collections.Generic.List[string]
  foreach ($e in $endpoints) {
    try { $r = Invoke-Web -Url ($origin + $e) -Method 'POST' -Body $body -ContentType 'application/x-www-form-urlencoded; charset=UTF-8' -Headers $hdr -TimeoutSec 20 }
    catch { $errs.Add("${e}: " + $_.Exception.Message); continue }
    if ($r.Status -eq 200 -and $r.Text -match '"links"|"link"') {
      try { $json = ConvertFrom-JsonDict $r.Text } catch { $json = $null }
      if ($json) { $usedEndpoint = $e; break }
    }
    $errs.Add("${e}: HTTP $($r.Status)")
  }
  if (-not $json) {
    # 500 on the discovered endpoint = params/signature rejected (stale page?); 404 on all = endpoint changed (see player JS)
    $src = 'endpoint from player JS: ' + $(if ($ep.Endpoint) { $ep.Endpoint } else { 'NOT FOUND (JS ' + $info.PlayerJs + ')' })
    throw ("Kodik: video info request failed ($src; tried " + ($errs -join ', ') + ')')
  }

  # decode links -> quality -> url
  $found = @{}; $okShift = -1
  if ($json.ContainsKey('links') -and $json['links']) {
    foreach ($q in $json['links'].Keys) {
      foreach ($item in @($json['links'][$q])) {
        if (-not $item -or -not $item.ContainsKey('src')) { continue }
        $d = ConvertFrom-KodikSrc ([string]$item['src']) $ep.Shift
        if ($d) { if ($script:KodikLastShift -ge 0) { $okShift = $script:KodikLastShift }; $d = ConvertTo-KodikAbsoluteUrl $d; if (-not $found.ContainsKey([string]$q)) { $found[[string]$q] = $d } }
      }
    }
  }
  if ($found.Count -eq 0 -and $json.ContainsKey('link') -and $json['link']) {
    $d = ConvertFrom-KodikSrc ([string]$json['link']) $ep.Shift
    if ($d) { if ($script:KodikLastShift -ge 0) { $okShift = $script:KodikLastShift }; $found['0'] = ConvertTo-KodikAbsoluteUrl $d }
  }
  if ($found.Count -eq 0) { throw 'Kodik: no playable links in response (blocked/removed video, or the src encoding changed)' }
  # remember the endpoint / shift that actually worked for this player JS build
  if ($info.PlayerJs -and ($usedEndpoint -ne $ep.Endpoint -or ($okShift -ge 0 -and $okShift -ne $ep.Shift))) {
    $jsName = ($info.PlayerJs -split '\?')[0]; $jsName = $jsName.Substring($jsName.LastIndexOf('/') + 1)
    $sh = $ep.Shift; if ($okShift -ge 0) { $sh = $okShift }
    $script:KodikEndpointCache[$jsName] = @{ Endpoint = $usedEndpoint; Shift = $sh; Js = $jsName }
  }

  # real renditions: url file quality (the "720" key often points to 480.mp4) + probe higher ones.
  # Probe every missing candidate above the listed top (1080 AND 720), so Qualities is complete and a cap can pick 720.
  $byQ = @{}
  foreach ($k in $found.Keys) {
    $fq = Get-KodikFileQuality $found[$k]
    if ($fq -le 0) { $fq = ConvertTo-KodikInt $k }
    if (-not $byQ.ContainsKey($fq)) { $byQ[$fq] = $found[$k] }
  }
  $listedTop = ($byQ.Keys | Sort-Object -Descending | Select-Object -First 1)
  $manifests = @{}
  $tmpl = $byQ[$listedTop]
  if ((Get-KodikFileQuality $tmpl) -gt 0) {
    foreach ($cand in @(1080, 720)) {
      if ($cand -le $listedTop -or $byQ.ContainsKey($cand)) { continue }
      if ($maxQuality -gt 0 -and $cand -gt $maxQuality) { continue }
      $cu = [regex]::Replace($tmpl, '/\d{3,4}\.mp4', '/' + $cand + '.mp4')
      $mr = Test-KodikManifest $cu
      if ($mr) { $byQ[$cand] = $cu; $manifests[$cand] = $mr }
    }
  }
  $sortedQ = @($byQ.Keys | Sort-Object -Descending)
  $top = $sortedQ[0]
  if ($maxQuality -gt 0) {
    $capped = @($sortedQ | Where-Object { $_ -le $maxQuality })
    if ($capped.Count -gt 0) { $top = $capped[0] } else { $top = $sortedQ[$sortedQ.Count - 1] }
  }
  $bestUrl = $byQ[$top]
  $bestManifest = $manifests[$top]
  if (-not $bestManifest) { $bestManifest = Test-KodikManifest $bestUrl }
  if (-not $bestManifest) {
    # chosen rendition does not answer with a playlist -> step down to the next one that does
    foreach ($k in $sortedQ) {
      if ($k -ge $top) { continue }
      $mr = Test-KodikManifest $byQ[$k]
      if ($mr) { $top = $k; $bestUrl = $byQ[$k]; $bestManifest = $mr; break }
    }
  }
  $qualities = [ordered]@{}
  foreach ($k in $sortedQ) { $qualities[[string]$k] = $byQ[$k] }

  $duration = $null
  if ($bestManifest) {
    $sum = 0.0; $n = 0
    foreach ($m in [regex]::Matches($bestManifest.Text, '#EXTINF:\s*([0-9.]+)')) { $sum += [double]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture); $n++ }
    if ($n -gt 0) { $duration = [Math]::Round($sum, 1) }
  }
  $expires = $null
  $m = [regex]::Match($bestUrl, ':(\d{10})/')
  if ($m.Success) {
    try {
      $dt = [datetime]::ParseExact($m.Groups[1].Value, 'yyyyMMddHH', [Globalization.CultureInfo]::InvariantCulture)
      $expires = ([datetime]::SpecifyKind($dt.AddHours(-3), [DateTimeKind]::Utc)).ToLocalTime()   # stamp assumed MSK (UTC+3) = conservative
    } catch {}
  }

  $titleParts = New-Object System.Collections.Generic.List[string]
  if ($info.PageTitle) { $titleParts.Add($info.PageTitle) }
  if ($pickedEpisode -gt 0) {
    if ($pickedSeason -gt 0 -and $seasonTitle) { $titleParts.Add($seasonTitle) }
    if ($epTitle) { $titleParts.Add($epTitle) } else { $titleParts.Add("Episode $pickedEpisode") }
  }
  $title = ($titleParts -join ' - ')
  if ($info.TranslationTitle) { if ($title) { $title += ' [' + $info.TranslationTitle + ']' } else { $title = 'Kodik [' + $info.TranslationTitle + ']' } }
  if (-not $title) { $title = "Kodik $vType $vId" }

  return [pscustomobject]@{
    Url              = $bestUrl
    Qualities        = $qualities
    Quality          = [int]$top
    Headers          = @{ 'User-Agent' = $script:WebUA }
    Title            = $title
    Duration         = $duration
    Expires          = $expires
    Type             = $vType
    Id               = $vId
    Hash             = $vHash
    Season           = $pickedSeason
    Episode          = $pickedEpisode
    TranslationId    = $info.TranslationId
    TranslationTitle = $info.TranslationTitle
    PlayerUrl        = $pageUrl
    Endpoint         = $usedEndpoint
  }
}

# List seasons / episodes / translations of a Kodik player (serial pages; seria/video return one entry).
# Each episode has .Url = https://kodikplayer.com/seria/<id>/<hash>/720p that Resolve-Kodik accepts directly.
function Get-KodikEpisodes([string]$playerUrl, [string]$referer = '') {
  $url = ConvertTo-KodikAbsoluteUrl $playerUrl
  $u = [Uri]$url
  if ($u.AbsolutePath -match '(?i)^/find-player') {
    $q = ConvertFrom-KodikQuery $u.Query
    $fp = Resolve-KodikFindPlayer $url (ConvertTo-KodikInt $q['season']) (ConvertTo-KodikInt $q['episode'])
    $url = $fp.Link
  }
  # translations=false hides the translation selector -> drop it for listing
  $url = Set-KodikUrlQuery $url @{ translations = $null; only_translations = $null; hide_selectors = $null; only_season = $null; only_episode = $null }
  if (-not $referer) { $referer = 'https://' + $script:KodikDefaultHost + '/' }
  $page = Invoke-KodikGet $url $referer
  $origin = ([Uri]$page.Url).GetLeftPart([UriPartial]::Authority)
  $info = Get-KodikPageInfo $page.Text
  $panel = Get-KodikPanel $page.Text $origin
  $episodes = $panel.Episodes
  if ($episodes.Count -eq 0 -and $info.Type -and $info.Id) {
    $episodes = New-Object System.Collections.ArrayList
    [void]$episodes.Add([pscustomobject]@{ Season = 0; Episode = 0; Value = ''; Title = $info.PageTitle; Id = $info.Id; Hash = $info.Hash; OtherTranslation = $false
        Url = $origin + '/' + $info.Type + '/' + $info.Id + '/' + $info.Hash + '/720p' })
  }
  $pageType = 'unknown'
  $mm = [regex]::Match(([Uri]$page.Url).AbsolutePath, '^/(seria|serial|video)/')
  if ($mm.Success) { $pageType = $mm.Groups[1].Value }
  return [pscustomobject]@{
    Type             = $pageType
    Title            = $info.PageTitle
    PlayerUrl        = $page.Url
    TranslationId    = $info.TranslationId
    TranslationTitle = $info.TranslationTitle
    CurrentSeason    = $panel.CurrentSeason
    CurrentEpisode   = $panel.CurrentEpisode
    Seasons          = $panel.Seasons
    Episodes         = $episodes
    Translations     = $panel.Translations
  }
}

# ==================================================================================================
# AnimeGO (animego.me)
# ==================================================================================================
# AnimeGO (animego.me) extractor for Windows PowerShell 5.1 (.NET Framework 4.x).
# Dot-source http_helper.ps1 FIRST (Invoke-Web, ConvertFrom-JsonDict, ConvertFrom-HtmlText), then this file.
#
# Site API (all JSON endpoints REQUIRE the header "X-Requested-With: XMLHttpRequest", otherwise 404 HTML):
#   GET /player/<animeId>                         -> {status, data:{content: player HTML}}  (episode strip page(s), translations+providers of the ACTIVE episode)
#   GET /player/<animeId>/episodes?page=<n>       -> {status, data:{content: episode items HTML, page, pageSize, total, ranges[]}}  (100 per page; out-of-range page is clamped)
#   GET /player/<animeId>/episodes?number=<num>   -> same, the page that contains episode <num>
#   GET /player/videos/<episodeId>                -> {status, data:{numVideos, content: translations+providers HTML, content_online: message HTML when numVideos=0, episode_information: HTML}}
#   GET /player/<animeId>/continuation/1?catalog=1 -> {numbers:[episode numbers that have any video]}
#   GET /player/<animeId>/continuation/1?numbers=1,5,13 (max 30) -> {items:[{episode, poster, duration, alternatives:[{translation, title}]}]}
# Cookies / Referer are not required (ddos-guard lets plain requests through); a cookie jar is kept anyway by Invoke-Web.

$script:AnimegoBase = 'https://animego.me'
$script:AnimegoDelayMs = 300
# quote-aware start-tag matcher: '>' inside quoted attribute values (e.g. data-action="a->b#c") does not end the tag
$script:AnimegoTagRx = New-Object System.Text.RegularExpressions.Regex('<([a-zA-Z][\w:-]*)((?:[^>"'']|"[^"]*"|''[^'']*'')*)>', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:AnimegoAttrRx = New-Object System.Text.RegularExpressions.Regex('([^\s=/>"'']+)(?:\s*=\s*(?:"([^"]*)"|''([^'']*)''|([^\s>"'']+)))?', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:AnimegoSpanAfterRx = New-Object System.Text.RegularExpressions.Regex('\G\s*<span\b[^>]*>([^<]*)</span>')

# ---------------------------------------------------------------- small helpers

function Get-AnimegoDictValue($dict, [string]$key) {
  if ($null -eq $dict) { return $null }
  if ($dict -is [System.Collections.Generic.IDictionary[string, object]]) {
    $v = $null
    if ($dict.TryGetValue($key, [ref]$v)) { return , $v }
    return $null
  }
  if ($dict -is [System.Collections.IDictionary]) {
    if ($dict.ContainsKey($key)) { return , $dict[$key] }
    return $null
  }
  return $null
}

function ConvertFrom-AnimegoHtmlToText([string]$html) {
  if (-not $html) { return '' }
  $t = [regex]::Replace($html, '<[^>]*>', ' ')
  $t = ConvertFrom-HtmlText $t
  return ([regex]::Replace($t, '\s+', ' ')).Trim()
}

function ConvertFrom-AnimegoAttrs([string]$attrText) {
  $h = @{}   # case-insensitive keys
  foreach ($m in $script:AnimegoAttrRx.Matches($attrText)) {
    $name = $m.Groups[1].Value.ToLowerInvariant()
    if ($h.ContainsKey($name)) { continue }
    $val = ''
    if ($m.Groups[2].Success) { $val = $m.Groups[2].Value }
    elseif ($m.Groups[3].Success) { $val = $m.Groups[3].Value }
    elseif ($m.Groups[4].Success) { $val = $m.Groups[4].Value }
    $h[$name] = ConvertFrom-HtmlText $val
  }
  return $h
}

# All start tags whose attribute text contains $mustContain (cheap prefilter), with parsed attributes.
function Get-AnimegoTags([string]$html, [string]$mustContain) {
  $out = New-Object System.Collections.Generic.List[object]
  if (-not $html) { return , $out }
  foreach ($m in $script:AnimegoTagRx.Matches($html)) {
    $attrText = $m.Groups[2].Value
    if ($mustContain -and $attrText.IndexOf($mustContain, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
    $out.Add([pscustomobject]@{
        Tag   = $m.Groups[1].Value.ToLowerInvariant()
        Attrs = (ConvertFrom-AnimegoAttrs $attrText)
        Index = $m.Index
        End   = $m.Index + $m.Length
      })
  }
  return , $out
}

function ConvertTo-AnimegoAbsUrl([string]$u) {
  if (-not $u) { return $u }
  $u = $u.Trim()
  if ($u.StartsWith('//')) { return 'https:' + $u }
  if ($u.StartsWith('/')) { return $script:AnimegoBase + $u }
  return $u
}

function Get-AnimegoProviderSlugFromUrl([string]$u) {
  if ($u -match '(?i)kodik') { return 'kodik' }
  if ($u -match '(?i)aniboom') { return 'aniboom' }
  if ($u -match '(?i)sibnet\.ru') { return 'sibnet' }
  if ($u -match '(?i)/cdn-iframe/') { return 'cvh' }
  if ($u -match '(?i)(^|//|\.)vk\.(com|ru)/') { return 'vk' }
  if ($u -match '(?i)^(?:https?:)?//([^/:]+)') { return $Matches[1] }
  return 'unknown'
}

# Anime id from any AnimeGO anime URL: https://animego.me/anime/<slug>-<id>[/...][?...][#...]
# Slugs vary: 'povelitel-2026-02-19-101', 'van-pis-s1-65', 'povelitel-4-2057' -> the LAST '-<digits>' is the id.
# NOTE: /anime/<digits> (no slug) is the catalogue page N, not an anime, so a slug is required.
function Get-AnimegoIdFromUrl([string]$url) {
  $m = [regex]::Match($url, '(?i)^\s*(?:https?://)?(?:www\.)?animego\.[a-z]{2,10}/anime/[^/?#\s]*-(\d+)(?=[/?#]|\s*$)')
  if ($m.Success) { return $m.Groups[1].Value }
  $m = [regex]::Match($url, '(?i)^\s*(?:https?://)?(?:www\.)?animego\.[a-z]{2,10}/player/(\d+)(?=[/?#]|\s*$)')
  if ($m.Success) { return $m.Groups[1].Value }
  throw "AnimeGO: cannot find the anime id in URL '$url' (expected https://animego.me/anime/<slug>-<id>)"
}

function Test-AnimegoUrl([string]$url) {
  return [regex]::IsMatch($url, '(?i)^\s*(?:https?://)?(?:www\.)?animego\.(?:me|org|club|one|bz)/anime/[^/?#\s]*-\d+(?=[/?#]|\s*$)')
}

# GET a JSON endpoint as the site's JS does. Throws on 404 / non-JSON / network errors (one retry for transient errors).
function Invoke-AnimegoXhr([string]$pathOrUrl, [string]$referer) {
  $url = $pathOrUrl
  if ($url.StartsWith('/')) { $url = $script:AnimegoBase + $url }
  $h = @{ 'X-Requested-With' = 'XMLHttpRequest'; 'Accept' = 'application/json' }
  if ($referer) { $h['Referer'] = $referer }
  $r = $null
  for ($try = 1; $try -le 2; $try++) {
    try {
      $r = Invoke-Web -Url $url -Headers $h -TimeoutSec 25
      if ($r.Status -ge 500 -and $try -lt 2) { Start-Sleep -Milliseconds 1500; continue }
      break
    } catch {
      if ($try -ge 2) { throw "AnimeGO: request failed for ${url}: $($_.Exception.Message)" }
      Start-Sleep -Milliseconds 1500
    }
  }
  if ($r.Status -eq 404) { throw "AnimeGO: 404 Not Found: $url" }
  $t = $r.Text
  if ($null -eq $t) { $t = '' }
  $t2 = $t.TrimStart()
  if (-not ($t2.StartsWith('{') -or $t2.StartsWith('['))) {
    $srv = ''
    try { $srv = [string]$r.Headers['Server'] } catch {}
    if ($srv -match '(?i)ddos-guard' -and $r.Status -ne 200) { throw "AnimeGO: blocked by DDoS-Guard challenge (HTTP $($r.Status)) at $url" }
    throw "AnimeGO: unexpected non-JSON response (HTTP $($r.Status)) from $url"
  }
  if ($r.Status -ne 200) { throw "AnimeGO: HTTP $($r.Status) from ${url}: $($t.Substring(0, [Math]::Min(200, $t.Length)))" }
  return (ConvertFrom-JsonDict $t)
}

# ---------------------------------------------------------------- HTML parsers (player fragments)

# Provider buttons: <button data-player="//kodikplayer.com/..." data-provider="19" data-provider-slug="kodik"
#                    data-ptranslation="6" data-translation-id="6" data-provider-title="Kodik" data-translation-title="...">
function Get-AnimegoProvidersFromHtml([string]$html) {
  $list = New-Object System.Collections.Generic.List[object]
  $seen = @{}
  foreach ($t in (Get-AnimegoTags $html 'data-player')) {
    $a = $t.Attrs
    if (-not $a.ContainsKey('data-player')) { continue }
    $url = ConvertTo-AnimegoAbsUrl $a['data-player']
    if (-not $url) { continue }
    $trId = $a['data-translation-id']
    if (-not $trId) { $trId = $a['data-ptranslation'] }
    $slug = $a['data-provider-slug']
    if (-not $slug) { $slug = Get-AnimegoProviderSlugFromUrl $url }
    $key = "$trId|$url"
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $list.Add([pscustomobject]@{
        Provider        = $slug
        ProviderTitle   = $a['data-provider-title']
        ProviderId      = $a['data-provider']
        TranslationId   = $trId
        TranslationName = $a['data-translation-title']
        PlayerUrl       = $url
      })
  }
  return , $list
}

# Translation buttons: <button data-translation="6" data-translation-id="6"><span class="text-truncate">NAME</span>...
function Get-AnimegoTranslationsFromHtml([string]$html, $providers) {
  $names = @{}
  if ($providers) { foreach ($p in $providers) { if ($p.TranslationId -and $p.TranslationName -and -not $names.ContainsKey($p.TranslationId)) { $names[$p.TranslationId] = $p.TranslationName } } }
  $list = New-Object System.Collections.Generic.List[object]
  $seen = @{}
  foreach ($t in (Get-AnimegoTags $html 'data-translation')) {
    $a = $t.Attrs
    if ($a.ContainsKey('data-player')) { continue }
    if (-not ($a.ContainsKey('data-translation') -or $a.ContainsKey('data-translation-id'))) { continue }
    $id = $a['data-translation-id']
    if (-not $id) { $id = $a['data-translation'] }
    if (-not $id -or $seen.ContainsKey($id)) { continue }
    $name = $null
    $sm = $script:AnimegoSpanAfterRx.Match($html, $t.End)
    if ($sm.Success) { $name = (ConvertFrom-HtmlText $sm.Groups[1].Value).Trim() }
    if (-not $name -and $names.ContainsKey($id)) { $name = $names[$id] }
    $seen[$id] = $true
    $list.Add([pscustomobject]@{ Id = $id; Name = $name })
  }
  # translations that only appear on provider buttons
  if ($providers) {
    foreach ($p in $providers) {
      if ($p.TranslationId -and -not $seen.ContainsKey($p.TranslationId)) {
        $seen[$p.TranslationId] = $true
        $list.Add([pscustomobject]@{ Id = $p.TranslationId; Name = $p.TranslationName })
      }
    }
  }
  return , $list
}

# Episode items: <div data-episode-number="1" data-episode-page="0" data-episode-index="0" data-episode-type="1" data-episode="1385" ...>
# data-episode-type: 1 = normal, 2 = recap ("R" badge), 3 = filler ("F" badge)
function Get-AnimegoEpisodesFromHtml([string]$html) {
  $list = New-Object System.Collections.Generic.List[object]
  foreach ($t in (Get-AnimegoTags $html 'data-episode-number')) {
    $a = $t.Attrs
    if (-not ($a.ContainsKey('data-episode') -and $a.ContainsKey('data-episode-number'))) { continue }
    $numText = $a['data-episode-number']
    $n = 0
    $num = $numText
    if ([int]::TryParse($numText, [ref]$n)) { $num = $n }
    $typeCode = $a['data-episode-type']
    $type = 'episode'
    if ($typeCode -eq '2') { $type = 'recap' } elseif ($typeCode -eq '3') { $type = 'filler' }
    $page = $null
    $pn = 0
    if ([int]::TryParse([string]$a['data-episode-page'], [ref]$pn)) { $page = $pn }
    $isActive = $false
    if ($a.ContainsKey('class') -and (' ' + $a['class'] + ' ') -match '\sactive\s') { $isActive = $true }
    $list.Add([pscustomobject]@{
        Number    = $num
        EpisodeId = $a['data-episode']
        Title     = $null
        Released  = $null
        Type      = $type
        HasVideo  = $null
        Page      = $page
        IsActive  = $isActive
      })
  }
  return , $list
}

function Get-AnimegoSortKey($ep) {
  $d = 0.0
  if ([double]::TryParse([string]$ep.Number, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
  return [double]::MaxValue
}

# Series page metadata (title, original title, type, status...). $html = full page HTML.
function Get-AnimegoPageMeta([string]$html) {
  $meta = [ordered]@{ Title = $null; OriginalTitle = $null; Synonyms = @(); LdType = $null; Kind = $null; Status = $null; EpisodesText = $null; NumberOfEpisodes = $null; Dubbings = @(); Canonical = $null; LoaderUrl = $null; Poster = $null }
  foreach ($m in [regex]::Matches($html, '(?is)<script\b[^>]*application/ld\+json[^>]*>(.*?)</script>')) {
    try {
      $ld = ConvertFrom-JsonDict $m.Groups[1].Value
      $name = Get-AnimegoDictValue $ld 'name'
      if (-not $name) { continue }
      $meta.Title = ([string]$name).Trim()
      $meta.LdType = [string](Get-AnimegoDictValue $ld '@type')
      $alt = Get-AnimegoDictValue $ld 'alternateName'
      if ($alt -is [string]) { $meta.OriginalTitle = $alt.Trim() }
      elseif ($alt -is [System.Collections.IEnumerable]) { foreach ($x in $alt) { if ($x) { $meta.OriginalTitle = ([string]$x).Trim(); break } } }
      $ne = Get-AnimegoDictValue $ld 'numberOfEpisodes'
      if ($null -ne $ne) { $meta.NumberOfEpisodes = [int]$ne }
      $img = Get-AnimegoDictValue $ld 'image'
      if ($img -is [string]) { $meta.Poster = $img }
      break
    } catch {}
  }
  if (-not $meta.Title) {
    $h1 = [regex]::Match($html, '(?is)<h1\b[^>]*>(.*?)</h1>')
    if ($h1.Success) { $meta.Title = ConvertFrom-AnimegoHtmlToText $h1.Groups[1].Value }
  }
  $syn = [regex]::Match($html, '(?is)class\s*=\s*"[^"]*\bentity__title-synonyms\b[^"]*"(.*?)</ul>')
  if ($syn.Success) {
    $meta.Synonyms = @([regex]::Matches($syn.Groups[1].Value, '(?is)<li\b[^>]*>(.*?)</li>') | ForEach-Object { ConvertFrom-AnimegoHtmlToText $_.Groups[1].Value } | Where-Object { $_ })
  }
  # info grid: <div ...>LABEL</div> <div ...>VALUE</div>
  $field = {
    param([string]$label)
    $fm = [regex]::Match($html, '(?is)>\s*' + $label + '\s*</div>\s*<div\b[^>]*>(.*?)</div>')
    if ($fm.Success) { return $fm.Groups[1].Value }
    return $null
  }
  $v = & $field '\u0422\u0438\u043f'
  if ($null -ne $v) { $meta.Kind = ConvertFrom-AnimegoHtmlToText $v }
  $v = & $field '\u0421\u0442\u0430\u0442\u0443\u0441'
  if ($null -ne $v) { $meta.Status = ConvertFrom-AnimegoHtmlToText $v }
  $v = & $field '\u042d\u043f\u0438\u0437\u043e\u0434\u044b'
  if ($null -ne $v) { $meta.EpisodesText = ConvertFrom-AnimegoHtmlToText $v }
  $v = & $field '\u041e\u0437\u0432\u0443\u0447\u043a\u0430'
  if ($null -ne $v) {
    $meta.Dubbings = @([regex]::Matches($v, '(?is)<a\b[^>]*>(.*?)</a>') | ForEach-Object { ConvertFrom-AnimegoHtmlToText $_.Groups[1].Value } | Where-Object { $_ })
  }
  $c = [regex]::Match($html, '(?i)<link\b[^>]*\brel\s*=\s*"canonical"[^>]*>')
  if ($c.Success) { $h = [regex]::Match($c.Value, '(?i)\bhref\s*=\s*"([^"]+)"'); if ($h.Success) { $meta.Canonical = $h.Groups[1].Value } }
  $l = [regex]::Match($html, '(?i)data-anime-player-loader-url-value\s*=\s*"([^"]*)"')
  if ($l.Success) { $meta.LoaderUrl = ConvertFrom-HtmlText $l.Groups[1].Value }
  return [pscustomobject]$meta
}

# Parse /player/videos/<id> episode_information HTML -> Title, Released, IsFiller, IsRecap
function Get-AnimegoEpisodeInfoFromHtml([string]$html) {
  $r = [ordered]@{ Title = $null; Released = $null; IsFiller = $false; IsRecap = $false; Description = $null }
  if (-not $html) { return [pscustomobject]$r }
  $get = {
    param([string]$key)
    $m = [regex]::Match($html, '(?is)class\s*=\s*"episode-info__' + $key + '\b([^"]*)".*?class\s*=\s*"[^"]*\bepisode-info__value\b[^"]*"[^>]*>(.*?)</div>')
    if (-not $m.Success) { return $null }
    if ($m.Groups[1].Value -match '\bd-none\b') { return $null }
    $t = ConvertFrom-AnimegoHtmlToText $m.Groups[2].Value
    if ($t -and $t -notmatch '^[-\s]*$') { return $t }   # '---' = no title
    return $null
  }
  $r.Title = & $get 'name'
  $r.Released = & $get 'released'
  $f = [regex]::Match($html, '(?i)class\s*=\s*"episode-info__filler\b([^"]*)"')
  if ($f.Success -and $f.Groups[1].Value -notmatch '\bd-none\b') { $r.IsFiller = $true }
  $p = [regex]::Match($html, '(?i)class\s*=\s*"episode-info__recap\b([^"]*)"')
  if ($p.Success -and $p.Groups[1].Value -notmatch '\bd-none\b') { $r.IsRecap = $true }
  $d = [regex]::Match($html, '(?is)class\s*=\s*"episode-info__description\b([^"]*)"[^>]*>(.*?)</div>')
  if ($d.Success -and $d.Groups[1].Value -notmatch '\bd-none\b') { $t = ConvertFrom-AnimegoHtmlToText $d.Groups[2].Value; if ($t) { $r.Description = $t } }
  return [pscustomobject]$r
}

# ---------------------------------------------------------------- public API

# One episode: sources + info. EpisodeId = data-episode value (e.g. '1389').
# Returns: EpisodeId, NumVideos, Title, Released, IsFiller, IsRecap, Message (text shown instead of the player when there is no video,
#          e.g. '\u042d\u043f\u0438\u0437\u043e\u0434 \u0432\u044b\u0439\u0434\u0435\u0442 10 \u043e\u043a\u0442\u044f\u0431\u0440\u044f 2026 17:45 (\u041c\u043e\u0441\u043a\u0432\u0430)' / '\u041d\u0435\u0442 \u0432\u0438\u0434\u0435\u043e'), Sources[], Translations[]
function Get-AnimegoEpisode {
  param([Parameter(Mandatory = $true)][string]$EpisodeId, [string]$PageUrl)
  if ($EpisodeId -notmatch '^\d+$') { throw "AnimeGO: invalid episode id '$EpisodeId'" }
  $j = Invoke-AnimegoXhr "/player/videos/$EpisodeId" $PageUrl
  if ([string](Get-AnimegoDictValue $j 'status') -ne 'success') { throw "AnimeGO: /player/videos/$EpisodeId returned status '$(Get-AnimegoDictValue $j 'status')': $(Get-AnimegoDictValue $j 'message')" }
  $data = Get-AnimegoDictValue $j 'data'
  $num = 0
  $nv = Get-AnimegoDictValue $data 'numVideos'
  if ($null -ne $nv) { $num = [int]$nv }
  $content = [string](Get-AnimegoDictValue $data 'content')
  $sources = Get-AnimegoProvidersFromHtml $content
  $trs = Get-AnimegoTranslationsFromHtml $content $sources
  $info = Get-AnimegoEpisodeInfoFromHtml ([string](Get-AnimegoDictValue $data 'episode_information'))
  $msg = $null
  if ($num -eq 0 -or $sources.Count -eq 0) { $msg = ConvertFrom-AnimegoHtmlToText ([string](Get-AnimegoDictValue $data 'content_online')) }
  return [pscustomobject]@{
    EpisodeId    = $EpisodeId
    NumVideos    = $num
    Title        = $info.Title
    Released     = $info.Released
    IsFiller     = $info.IsFiller
    IsRecap      = $info.IsRecap
    Message      = $msg
    Sources      = $sources.ToArray()
    Translations = $trs.ToArray()
  }
}

# Video sources of one episode (or of the single video of a movie when $episodeId is empty).
# Returns (pipeline, wrap in @()): [pscustomobject]@{ Provider (slug: kodik|aniboom|cvh|sibnet|vk|...); ProviderTitle; ProviderId;
#                                   TranslationId; TranslationName; PlayerUrl (absolute https) }   -- in the site's menu order.
function Get-AnimegoSources {
  param([Parameter(Mandatory = $true)][string]$animeId, [string]$episodeId, [string]$pageUrl)
  if ($episodeId) {
    $e = Get-AnimegoEpisode -EpisodeId $episodeId -PageUrl $pageUrl
    return $e.Sources
  }
  if ($animeId -notmatch '^\d+$') { throw "AnimeGO: invalid anime id '$animeId'" }
  $j = Invoke-AnimegoXhr "/player/$animeId" $pageUrl
  $content = [string](Get-AnimegoDictValue (Get-AnimegoDictValue $j 'data') 'content')
  $list = Get-AnimegoProvidersFromHtml $content
  return $list.ToArray()
}

# Find one episode by its number without loading every page (uses /player/<id>/episodes?number=N).
function Get-AnimegoEpisodeByNumber {
  param([Parameter(Mandatory = $true)][string]$AnimeId, [Parameter(Mandatory = $true)]$Number, [string]$PageUrl)
  $j = Invoke-AnimegoXhr ("/player/$AnimeId/episodes?number=" + [Uri]::EscapeDataString([string]$Number)) $PageUrl
  $content = [string](Get-AnimegoDictValue (Get-AnimegoDictValue $j 'data') 'content')
  foreach ($e in (Get-AnimegoEpisodesFromHtml $content)) { if ([string]$e.Number -eq [string]$Number) { return $e } }
  return $null
}

# Everything about a title.
# Returns [pscustomobject]@{ Id; Title; OriginalTitle; Url; Episodes = @(Number; EpisodeId; Title; Released; Type; HasVideo; Page);
#   Translations = @(Id; Name); IsMovie; + Kind; Status; Synonyms; Dubbings; EpisodesTotal; EpisodesText; HasPlayer;
#   ActiveEpisodeId; InitialSources; PlayerMessage; Warnings }
# -MaxPages: max episode-list pages (100 episodes each) to load; -WithEpisodeDetails: one extra request per episode (Title/Released),
#  limited to -DetailsLimit episodes.
function Get-AnimegoInfo {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [int]$MaxPages = 30,
    [switch]$WithEpisodeDetails,
    [int]$DetailsLimit = 40
  )
  $warnings = New-Object System.Collections.Generic.List[string]
  $id = Get-AnimegoIdFromUrl $Url
  $pageUrl = $Url.Trim()
  if ($pageUrl -notmatch '^(?i)https?://') { $pageUrl = 'https://' + $pageUrl }
  $pageUrl = [regex]::Replace($pageUrl, '#.*$', '')

  # 1) series page (title etc.). Mirrors (animego.org/.club/.one/.bz) 301 -> animego.me; the final host becomes the API base.
  $meta = $null
  try {
    $r = Invoke-Web -Url $pageUrl -TimeoutSec 25
    try {
      $fu = [Uri]$r.Url
      if ($fu.Host -match '(?i)^(www\.)?animego\.') { $script:AnimegoBase = $fu.Scheme + '://' + $fu.Host }
    } catch {}
    if ($r.Status -eq 200) {
      $meta = Get-AnimegoPageMeta $r.Text
      if ($meta.Canonical) { $pageUrl = $meta.Canonical } else { $pageUrl = $r.Url }
      if ($meta.LoaderUrl -and $meta.LoaderUrl -match '/player/(\d+)') { $id = $Matches[1] }
    } else {
      $warnings.Add("series page returned HTTP $($r.Status) (old/renamed slug?); using /player/$id only")
    }
  } catch {
    $warnings.Add("series page failed: $($_.Exception.Message)")
  }

  # 2) player
  $hasPlayer = $true
  $content = ''
  try {
    $j = Invoke-AnimegoXhr "/player/$id" $pageUrl
    $content = [string](Get-AnimegoDictValue (Get-AnimegoDictValue $j 'data') 'content')
  } catch {
    $hasPlayer = $false
    if (-not $meta) { throw "AnimeGO: anime $id not found (page and /player/$id both failed): $($_.Exception.Message)" }
    $warnings.Add("player not available: $($_.Exception.Message)")
  }

  $episodes = New-Object System.Collections.Generic.List[object]
  $initialSources = New-Object System.Collections.Generic.List[object]
  $translations = New-Object System.Collections.Generic.List[object]
  $total = $null
  $activeId = $null
  $playerMsg = $null
  $stripCount = 0
  if ($hasPlayer -and $content) {
    $root = $null
    foreach ($t in (Get-AnimegoTags $content 'data-anime-player-episodes-url-value')) { $root = $t.Attrs; break }
    $episodesUrl = "/player/$id/episodes"
    $continuationUrl = "/player/$id/continuation/1"
    $pages = @()
    if ($root) {
      if ($root['data-anime-player-episodes-url-value']) { $episodesUrl = $root['data-anime-player-episodes-url-value'] }
      if ($root['data-anime-player-continuation-url-value']) { $continuationUrl = $root['data-anime-player-continuation-url-value'] }
      $tv = 0
      if ([int]::TryParse([string]$root['data-anime-player-episodes-total-value'], [ref]$tv)) { $total = $tv }
      $pj = $root['data-anime-player-episodes-pages-value']
      if ($pj) { try { $pages = @(ConvertFrom-JsonDict $pj) } catch { $warnings.Add('cannot parse episode pages JSON') } }
    }

    $seenEp = @{}
    $loadedPages = @{}
    foreach ($e in (Get-AnimegoEpisodesFromHtml $content)) {
      if ($seenEp.ContainsKey($e.EpisodeId)) { continue }
      $seenEp[$e.EpisodeId] = $true
      $episodes.Add($e)
      if ($null -ne $e.Page) { $loadedPages[[string]$e.Page] = $true }
      if ($e.IsActive) { $activeId = $e.EpisodeId }
    }
    $stripCount = $episodes.Count   # movies / single-video titles have no episode strip in /player/<id> (their one episode id is only on episodes?page=0)
    # 3) remaining episode pages (100 per page)
    $loadedCount = 0
    foreach ($pg in $pages) {
      $pn = [string](Get-AnimegoDictValue $pg 'page')
      if ($pn -eq '' -or $loadedPages.ContainsKey($pn)) { continue }
      if ($loadedCount -ge $MaxPages) { $warnings.Add("episode list truncated at $MaxPages extra pages"); break }
      Start-Sleep -Milliseconds $script:AnimegoDelayMs
      try {
        $sep = '?'
        if ($episodesUrl.Contains('?')) { $sep = '&' }
        $pjx = Invoke-AnimegoXhr ($episodesUrl + $sep + 'page=' + $pn) $pageUrl
        $pc = [string](Get-AnimegoDictValue (Get-AnimegoDictValue $pjx 'data') 'content')
        foreach ($e in (Get-AnimegoEpisodesFromHtml $pc)) {
          if ($seenEp.ContainsKey($e.EpisodeId)) { continue }
          $seenEp[$e.EpisodeId] = $true
          $e.IsActive = $false
          $episodes.Add($e)
        }
        $loadedPages[$pn] = $true
        $loadedCount++
      } catch {
        $warnings.Add("episode page $pn failed: $($_.Exception.Message)")
      }
    }

    $initialSources = Get-AnimegoProvidersFromHtml $content
    $translations = Get-AnimegoTranslationsFromHtml $content $initialSources
    # The .player-video__online block ALWAYS contains the static placeholder '\u041d\u0435\u0442 \u0432\u0438\u0434\u0435\u043e' (the site's JS replaces it with the
    # iframe), so it is only meaningful when the active episode / movie has no provider buttons.
    # [verifier fix: the original reported PlayerMessage='\u041d\u0435\u0442 \u0432\u0438\u0434\u0435\u043e' for every title WITH video, e.g. Overlord / Naruto / Re:Zero 4]
    if ($initialSources.Count -eq 0) {
      $om = [regex]::Match($content, '(?is)class\s*=\s*"[^"]*\bplayer-video__online\b[^"]*"[^>]*>(.*?)</div>\s*</div>')
      if ($om.Success) { $playerMsg = ConvertFrom-AnimegoHtmlToText $om.Groups[1].Value }
    }

    # 4) which episode numbers have any video (one cheap request)
    if ($episodes.Count -gt 0) {
      try {
        Start-Sleep -Milliseconds $script:AnimegoDelayMs
        $sep = '?'
        if ($continuationUrl.Contains('?')) { $sep = '&' }
        $cat = Invoke-AnimegoXhr ($continuationUrl + $sep + 'catalog=1') $pageUrl
        $nums = @{}
        $numList = Get-AnimegoDictValue $cat 'numbers'   # object[] (kept as one object, do not wrap in @())
        foreach ($n in $numList) { if ($null -ne $n) { $nums[[string]$n] = $true } }
        foreach ($e in $episodes) { $e.HasVideo = $nums.ContainsKey([string]$e.Number) }
      } catch { $warnings.Add("catalog request failed: $($_.Exception.Message)") }
    }
  }

  # 5) fallback title: the aniboom embed URL carries the canonical page URL in its 'parent' parameter
  if ((-not $meta -or -not $meta.Title) -and $initialSources.Count -gt 0) {
    foreach ($s in $initialSources) {
      $pm = [regex]::Match([string]$s.PlayerUrl, '[?&]parent=([^&#]+)')
      if (-not $pm.Success) { continue }
      $parent = [Uri]::UnescapeDataString($pm.Groups[1].Value)
      if ($parent -notmatch '(?i)^https?://(www\.)?animego\.' -or $parent -eq $pageUrl) { continue }
      try {
        $r2 = Invoke-Web -Url $parent -TimeoutSec 25
        if ($r2.Status -eq 200) { $meta = Get-AnimegoPageMeta $r2.Text; $pageUrl = $parent }
      } catch {}
      break
    }
  }

  $sorted = @($episodes | Sort-Object { Get-AnimegoSortKey $_ })
  $isSingleVideo = ($sorted.Count -eq 0 -and $initialSources.Count -gt 0)
  $isMovie = ($isSingleVideo -or ($hasPlayer -and $stripCount -eq 0 -and $sorted.Count -eq 1 -and $initialSources.Count -gt 0))
  if ($meta) {
    if ($meta.LdType -eq 'Movie') { $isMovie = $true }
    if ($meta.Kind -and $meta.Kind -match '^(?i)\u0424\u0438\u043b\u044c\u043c') { $isMovie = $true }
  }
  $title = $null; $orig = $null
  if ($meta) { $title = $meta.Title; $orig = $meta.OriginalTitle }

  if ($isSingleVideo) {
    # movies (and some single-video titles) have no episode strip: their sources come from /player/<id> itself
    $sorted = @([pscustomobject]@{ Number = 1; EpisodeId = $null; Title = $title; Released = $null; Type = 'movie'; HasVideo = $true; Page = 0; IsActive = $true })
  } elseif ($isMovie -and $sorted.Count -eq 1) {
    # [verifier fix] movie with its hidden episode id (from episodes?page=0): mark it as documented (Type='movie', title = movie title)
    $sorted[0].Type = 'movie'
    if (-not $sorted[0].Title) { $sorted[0].Title = $title }
  }

  # 6) optional per-episode details (1 request each)
  if ($WithEpisodeDetails) {
    $done = 0
    foreach ($e in $sorted) {
      if (-not $e.EpisodeId) { continue }
      if ($done -ge $DetailsLimit) { $warnings.Add("episode details limited to $DetailsLimit"); break }
      Start-Sleep -Milliseconds $script:AnimegoDelayMs
      try {
        $d = Get-AnimegoEpisode -EpisodeId $e.EpisodeId -PageUrl $pageUrl
        if ($d.Title) { $e.Title = $d.Title }
        $e.Released = $d.Released
        if ($null -eq $e.HasVideo) { $e.HasVideo = ($d.Sources.Count -gt 0) }
      } catch { $warnings.Add("details for episode $($e.Number) failed: $($_.Exception.Message)") }
      $done++
    }
  }

  $o = [pscustomobject]@{
    Id              = $id
    Title           = $title
    OriginalTitle   = $orig
    Url             = $pageUrl
    Episodes        = $sorted
    Translations    = $translations.ToArray()
    IsMovie         = [bool]$isMovie
    Kind            = $(if ($meta) { $meta.Kind } else { $null })
    Status          = $(if ($meta) { $meta.Status } else { $null })
    Synonyms        = $(if ($meta) { $meta.Synonyms } else { @() })
    Dubbings        = $(if ($meta) { $meta.Dubbings } else { @() })
    EpisodesText    = $(if ($meta) { $meta.EpisodesText } else { $null })
    EpisodesTotal   = $total
    HasPlayer       = $hasPlayer
    ActiveEpisodeId = $activeId
    InitialSources  = $initialSources.ToArray()
    PlayerMessage   = $playerMsg
    Warnings        = $warnings.ToArray()
  }
  return $o
}

# ==================================================================================================
# AniBoom (aniboom.one)
# ==================================================================================================
# AniBoom (aniboom.one) embed resolver - Windows PowerShell 5.1 / .NET Framework 4.x.
# Requires http_helper.ps1 to be dot-sourced first (Invoke-Web, ConvertFrom-JsonDict, ConvertFrom-HtmlText, $script:WebUA).
#
# How AniBoom works (verified 2026-09-27):
#   GET https://aniboom.one/embed/<animeId>?episode=<n>&translation=<aniboomTrId>   (any non-empty Referer header REQUIRED, else 404)
#     -> HTML with <div data-parameters="{html-escaped JSON}">; JSON fields hls / dash (/ fallbackHls / fallbackDash) are
#        themselves JSON strings: {"src":"https://<host>.ya-ligh123.site/8r/8rVX6kRVdl4/master.m3u8","type":"application/x-mpegURL"}
#   The CDN (nginx, static fMP4 HLS + DASH sharing the same .m4s files) needs no headers and has no expiring token;
#   we still send what a browser sends (Referer https://aniboom.one/, Origin https://aniboom.one) in case that gets enforced.
#   <animeId> is per anime (+ AniBoom's own translation id); change ?episode= to get another episode. Films have no episode param.
#   episodePicker.endpoint (signed, valid 24 h) accepts POST JSON {"action":"catalog"} | {"action":"details","numbers":[..]} |
#   {"action":"play","episode":n}.

#
# Verifier changes vs research\aniboom\aniboom.ps1 (same function names / return shapes):
#   - Get-AniboomDashVariants now always returns an array (was $null / bare PSCustomObject for 0 / 1 renditions in PS 5.1,
#     making Resolve-Aniboom report MaxHeight=$null and a non-array Qualities on a DASH fallback with one rendition).
#   - Resolve-Aniboom forces Qualities / AudioUrls to arrays.
#   - The 404 message adds a hint when the URL lacks ?episode= or &translation= (multi-dub series 404 without translation).

$script:AniboomOrigin = 'https://aniboom.one'

function Get-AbValue($dict, [string]$key) {
  if ($null -eq $dict) { return $null }
  if ($dict -is [System.Collections.Generic.IDictionary[string, object]]) { if ($dict.ContainsKey($key)) { return $dict[$key] } ; return $null }
  if ($dict -is [hashtable]) { if ($dict.ContainsKey($key)) { return $dict[$key] } ; return $null }
  return $null
}

# '//aniboom.one/embed/X?episode=1&amp;translation=1' -> 'https://aniboom.one/embed/X?episode=1&translation=1'
function ConvertTo-AniboomEmbedUrl([string]$url) {
  $u = [System.Net.WebUtility]::HtmlDecode(([string]$url).Trim())
  if ($u.StartsWith('//')) { $u = 'https:' + $u }
  elseif ($u -notmatch '^(?i)https?://') { $u = 'https://' + $u.TrimStart('/') }
  $u = $u -replace '^(?i)http://', 'https://'
  if ($u -notmatch '^(?i)https://(www\.)?aniboom\.one/embed/[A-Za-z0-9_-]+') { throw "AniBoom: not an AniBoom embed URL: $url" }
  return $u
}

function Test-AniboomUrl([string]$url) { return ([string]$url -match '(?i)(^|//|\.)aniboom\.one/embed/[A-Za-z0-9_-]+') }

function Get-AniboomQueryValue([string]$url, [string]$name) {
  $m = [regex]::Match($url, '[?&]' + [regex]::Escape($name) + '=([^&#]*)')
  if ($m.Success) { return [Uri]::UnescapeDataString($m.Groups[1].Value.Replace('+', ' ')) }
  return $null
}

# Returns the embed URL with ?episode=<n> set (added if missing). Same anime id + translation, other episode.
function Set-AniboomEmbedEpisode([string]$embedUrl, [int]$episode) {
  $u = ConvertTo-AniboomEmbedUrl $embedUrl
  if ($u -match '[?&]episode=[^&#]*') { return [regex]::Replace($u, '([?&])episode=[^&#]*', ('${1}episode=' + $episode)) }
  $hash = ''
  $hi = $u.IndexOf('#'); if ($hi -ge 0) { $hash = $u.Substring($hi); $u = $u.Substring(0, $hi) }
  if ($u.Contains('?')) { return ($u + '&episode=' + $episode + $hash) }
  return ($u + '?episode=' + $episode + $hash)
}

# The embed 404s without a Referer. Prefer the page that embeds the player (animego anime page); else ?parent=; else animego.
function Get-AniboomReferer([string]$embedUrl, [string]$referer) {
  if ($referer) { return $referer }
  $p = Get-AniboomQueryValue $embedUrl 'parent'
  if ($p -and $p -match '^(?i)https?://') { return $p }
  return 'https://animego.me/'
}

# Headers ffmpeg should send to the AniBoom CDN (not required today, but exactly what the browser player sends).
function Get-AniboomCdnHeaders {
  return @{ 'User-Agent' = $script:WebUA; 'Referer' = ($script:AniboomOrigin + '/'); 'Origin' = $script:AniboomOrigin }
}

# hashtable -> @('-user_agent', UA, '-headers', "Referer: ...`r`nOrigin: ...`r`n") for ffmpeg/ffprobe (put before -i).
function ConvertTo-FfmpegHeaderArgs([hashtable]$headers) {
  $a = @(); $lines = ''
  foreach ($k in $headers.Keys) {
    if ($k -ieq 'User-Agent') { $a += '-user_agent'; $a += [string]$headers[$k] }
    else { $lines += ([string]$k + ': ' + [string]$headers[$k] + "`r`n") }
  }
  if ($lines) { $a += '-headers'; $a += $lines }
  return , $a
}

# "hls"/"dash" fields: JSON string '{"src":"...","type":"..."}', the string 'null', null, or (defensively) an object.
function ConvertFrom-AniboomSource($v) {
  if ($null -eq $v) { return $null }
  $o = $v
  if ($v -is [string]) {
    $s = $v.Trim()
    if (-not $s -or $s -eq 'null') { return $null }
    if ($s -match '^(?i)https?://') { return $s }
    try { $o = ConvertFrom-JsonDict $s } catch { return $null }
  }
  $src = Get-AbValue $o 'src'
  if ($src) { return [string]$src }
  return $null
}

# Downloads the embed page and returns the decoded player parameters.
# Returns: [pscustomobject]@{ Parameters (Dictionary); Title; EmbedUrl; Referer }
# Throws: 'AniBoom: video not found (HTTP 404) ...' | 'AniBoom: embed page returned HTTP n' | 'AniBoom: player parameters not found ...'
function Get-AniboomEmbedParameters([string]$embedUrl, [string]$referer) {
  $u = ConvertTo-AniboomEmbedUrl $embedUrl
  $ref = Get-AniboomReferer $u $referer
  $r = Invoke-Web -Url $u -Headers @{ 'Referer' = $ref; 'Accept' = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' } -TimeoutSec 25
  if ($r.Status -eq 404) {
    # (verify) Series with several AniBoom dubs (e.g. Re:Zero 4, Liar Game) 404 when &translation= is missing;
    # single-dub series (Overlord, One Piece) and films accept a URL without it.
    $hint = ''
    if (-not (Get-AniboomQueryValue $u 'episode')) { $hint = ' [the URL has no ?episode= - required for series, only films omit it]' }
    elseif (-not (Get-AniboomQueryValue $u 'translation')) { $hint = ' [the URL has no &translation= - required when the anime has several AniBoom dubs]' }
    throw "AniBoom: video not found (HTTP 404) - this episode/translation is not on AniBoom (or no Referer was sent)${hint}: $u"
  }
  if ($r.Status -ne 200) { throw "AniBoom: embed page returned HTTP $($r.Status): $u" }
  $m = [regex]::Match($r.Text, 'data-parameters="([^"]*)"')
  if (-not $m.Success) {
    if ($r.Text -match '(?i)ddos-guard|ddg-captcha|check\.ddos') { throw "AniBoom: blocked by a DDoS-Guard challenge page: $u" }
    throw "AniBoom: player parameters (data-parameters) not found in the embed page - site layout changed? $u"
  }
  $p = ConvertFrom-JsonDict (ConvertFrom-HtmlText $m.Groups[1].Value)
  $t = [regex]::Match($r.Text, '<title>\s*([\s\S]*?)\s*</title>')
  $title = ''
  if ($t.Success) { $title = ((ConvertFrom-HtmlText $t.Groups[1].Value) -replace '\s+', ' ').Trim() }
  return [pscustomobject]@{ Parameters = $p; Title = $title; EmbedUrl = $u; Referer = $ref }
}

# Parses an HLS master playlist. Returns @{ Variants = [pscustomobject[]] (Width, Height, Bandwidth, Url; best first); AudioUrls = string[] }
function Get-AniboomHlsVariants([string]$masterUrl, [string]$text) {
  $base = New-Object System.Uri($masterUrl)
  $lines = $text -split "`r?`n"
  $vars = @(); $audio = @()
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if ($l.StartsWith('#EXT-X-MEDIA:') -and $l -match 'TYPE=AUDIO' -and $l -match 'URI="([^"]+)"') {
      $audio += (New-Object System.Uri($base, $Matches[1])).AbsoluteUri
    }
    elseif ($l.StartsWith('#EXT-X-STREAM-INF:')) {
      $w = 0; $h = 0; $bw = [int64]0
      $rm = [regex]::Match($l, 'RESOLUTION=(\d+)x(\d+)'); if ($rm.Success) { $w = [int]$rm.Groups[1].Value; $h = [int]$rm.Groups[2].Value }
      $bm = [regex]::Match($l, '[:,]BANDWIDTH=(\d+)'); if ($bm.Success) { $bw = [int64]$bm.Groups[1].Value }
      $j = $i + 1
      while ($j -lt $lines.Count -and ($lines[$j].Trim() -eq '' -or $lines[$j].StartsWith('#'))) { $j++ }
      if ($j -lt $lines.Count) {
        $vars += [pscustomobject]@{ Width = $w; Height = $h; Bandwidth = $bw; Url = (New-Object System.Uri($base, $lines[$j].Trim())).AbsoluteUri }
      }
    }
  }
  $sorted = @($vars | Sort-Object -Property @{ Expression = 'Height'; Descending = $true }, @{ Expression = 'Bandwidth'; Descending = $true })
  return [pscustomobject]@{ Variants = $sorted; AudioUrls = $audio }
}

function Get-AniboomDashVariants([string]$text) {
  $vars = @()
  foreach ($m in [regex]::Matches($text, '<Representation\b[^>]*>')) {
    $tag = $m.Value
    if ($tag -notmatch 'height="(\d+)"') { continue }
    $h = [int]$Matches[1]; $w = 0; $bw = [int64]0
    if ($tag -match 'width="(\d+)"') { $w = [int]$Matches[1] }
    if ($tag -match 'bandwidth="(\d+)"') { $bw = [int64]$Matches[1] }
    $vars += [pscustomobject]@{ Width = $w; Height = $h; Bandwidth = $bw; Url = $null }
  }
  # FIX (verify): the leading comma keeps a 0/1-element result an array; without it PS 5.1 unrolls it to $null / a bare
  # PSCustomObject, whose .Count is empty in 5.1, so Resolve-Aniboom returned MaxHeight=$null for a single-rendition MPD.
  return , @($vars | Sort-Object -Property @{ Expression = 'Height'; Descending = $true }, @{ Expression = 'Bandwidth'; Descending = $true })
}

# Resolve-Aniboom: AniBoom embed URL -> direct stream for ffmpeg.
#   $embedUrl : '//aniboom.one/embed/N9QdKWmdwz1?episode=1&translation=1&episodes=1&parent=...' (as found in animego's data-player)
#   $referer  : page that embeds the player (e.g. https://animego.me/anime/povelitel-2026-02-19-101); optional
#   -Episode  : override ?episode= (same anime + translation)
#   -NoValidate : skip the manifest GET (no Qualities; no fallback check)
# Returns [pscustomobject]: Url, Headers (hashtable), Kind ('hls'|'dash'), Qualities (Width/Height/Bandwidth/Url, best first),
#   MaxHeight, Duration (sec), Title, AnimeId, MediaId, Episode, Translation, TranslationTitle, HlsUrl, DashUrl, AudioUrls,
#   Poster, EpisodesEndpoint, EmbedUrl, Referer, Expires ($null: CDN URLs are static)
# Throws on: bad URL, 404 (episode/translation missing), no parameters, no reachable stream.
function Resolve-Aniboom {
  param(
    [Parameter(Mandatory = $true)][string]$embedUrl,
    [string]$referer = '',
    [int]$Episode = 0,
    [switch]$NoValidate
  )
  $u = ConvertTo-AniboomEmbedUrl $embedUrl
  if ($Episode -gt 0) { $u = Set-AniboomEmbedEpisode $u $Episode }
  $e = Get-AniboomEmbedParameters $u $referer
  $p = $e.Parameters
  $picker = Get-AbValue $p 'episodePicker'

  $cands = @()
  foreach ($pair in @(@('hls', 'hls'), @('fallbackHls', 'hls'), @('dash', 'dash'), @('fallbackDash', 'dash'))) {
    $src = ConvertFrom-AniboomSource (Get-AbValue $p $pair[0])
    if ($src) { $cands += [pscustomobject]@{ Url = $src; Kind = $pair[1] } }
  }
  if ($cands.Count -eq 0) { throw "AniBoom: the embed has no HLS/DASH source (video removed or blocked in this region?): $u" }

  $headers = Get-AniboomCdnHeaders
  $chosen = $null; $qual = @(); $audio = @(); $errs = @()
  if ($NoValidate) { $chosen = $cands[0] }
  else {
    foreach ($c in $cands) {
      try {
        $r = Invoke-Web -Url $c.Url -Headers @{ 'Referer' = $headers['Referer']; 'Origin' = $headers['Origin'] } -TimeoutSec 20
        if ($r.Status -ne 200) { $errs += "$($c.Kind) HTTP $($r.Status)"; continue }
        if ($c.Kind -eq 'hls') {
          if ($r.Text -notmatch '#EXTM3U') { $errs += 'hls: not a playlist'; continue }
          $hv = Get-AniboomHlsVariants $c.Url $r.Text
          $qual = @($hv.Variants); $audio = @($hv.AudioUrls)
        } else {
          if ($r.Text -notmatch '<MPD') { $errs += 'dash: not an MPD'; continue }
          $qual = Get-AniboomDashVariants $r.Text   # returns , @(...) - do not wrap in @() again (would nest)
        }
        $chosen = $c; break
      } catch { $errs += "$($c.Kind): $($_.Exception.Message)" }
    }
    if (-not $chosen) { throw ("AniBoom: no stream reachable (" + ($errs -join '; ') + "): $u") }
  }

  $hls = $null; $dash = $null
  foreach ($c in $cands) { if ($c.Kind -eq 'hls' -and -not $hls) { $hls = $c.Url }; if ($c.Kind -eq 'dash' -and -not $dash) { $dash = $c.Url } }
  $dur = $null; $dv = Get-AbValue $p 'duration'; if ($null -ne $dv) { try { $dur = [double]$dv } catch {} }
  $ep = $null; $tr = $null; $trTitle = $null; $animeId = $null; $endpoint = $null
  if ($picker) {
    $ep = Get-AbValue $picker 'episode'; $tr = Get-AbValue $picker 'translation'; $trTitle = Get-AbValue $picker 'translationTitle'
    $animeId = Get-AbValue $picker 'animeId'; $endpoint = Get-AbValue $picker 'endpoint'
  }
  if ($null -eq $ep) { $q = Get-AniboomQueryValue $u 'episode'; if ($q) { $ep = [int]$q } }
  if ($null -eq $tr) { $q = Get-AniboomQueryValue $u 'translation'; if ($q) { $tr = [int]$q } }
  if (-not $animeId) { $animeId = [regex]::Match($u, '/embed/([A-Za-z0-9_-]+)').Groups[1].Value }
  $qual = @($qual); $audio = @($audio)
  $maxH = $null; if ($qual.Count -gt 0) { $maxH = $qual[0].Height }

  return [pscustomobject]@{
    Url              = $chosen.Url
    Headers          = $headers
    Kind             = $chosen.Kind
    Qualities        = $qual
    MaxHeight        = $maxH
    Duration         = $dur
    Title            = $e.Title
    AnimeId          = $animeId
    MediaId          = [string](Get-AbValue $p 'id')
    Episode          = $ep
    Translation      = $tr
    TranslationTitle = $trTitle
    HlsUrl           = $hls
    DashUrl          = $dash
    AudioUrls        = $audio
    Poster           = [string](Get-AbValue $p 'poster')
    EpisodesEndpoint = $endpoint
    EmbedUrl         = $u
    Referer          = $e.Referer
    Expires          = $null
  }
}

# POST to the signed episodePicker endpoint (read-only actions: catalog / details / play). Returns the parsed JSON dictionary.
function Invoke-AniboomEpisodePicker([string]$endpoint, [string]$bodyJson, [string]$embedUrl) {
  $ref = $script:AniboomOrigin + '/'
  if ($embedUrl) { $ref = $embedUrl }
  $r = Invoke-Web -Url $endpoint -Method 'POST' -Body $bodyJson -ContentType 'application/json' -TimeoutSec 20 `
    -Headers @{ 'Accept' = 'application/json'; 'Origin' = $script:AniboomOrigin; 'Referer' = $ref }
  if ($r.Status -ne 200) { throw "AniBoom: episode list endpoint returned HTTP $($r.Status)" }
  return (ConvertFrom-JsonDict $r.Text)
}

# Episode numbers available in this embed's translation, e.g. 1..13. Empty array for films. Throws on HTTP errors.
function Get-AniboomEpisodes([string]$embedUrl, [string]$referer = '') {
  $e = Get-AniboomEmbedParameters $embedUrl $referer
  $picker = Get-AbValue $e.Parameters 'episodePicker'
  if (-not $picker) { return , @() }
  $j = Invoke-AniboomEpisodePicker (Get-AbValue $picker 'endpoint') '{"action":"catalog"}' $e.EmbedUrl
  $nums = @()
  foreach ($n in @(Get-AbValue $j 'numbers')) { if ($null -ne $n) { $nums += [int]$n } }
  return , @($nums | Sort-Object)
}

# ==================================================================================================
# Sibnet (video.sibnet.ru) and CVH (cdnvideohub, used by AnimeGO)
# ==================================================================================================
# Sibnet + CVH (cdnvideohub) resolvers for Windows PowerShell 5.1.
# Requires http_helper.ps1 to be dot-sourced first (Invoke-Web, ConvertFrom-JsonDict, ConvertFrom-HtmlText, $script:WebUA).
#
#   Resolve-Sibnet '//video.sibnet.ru/shell.php?videoid=2991569' 'https://animego.me/anime/povelitel-2026-02-19-101'
#   Resolve-Cvh    '//animego.me/cdn-iframe/29803/1/5?dubbing=AniDUB' 'https://animego.me/anime/povelitel-2026-02-19-101'
#
# Both return [pscustomobject]@{ Url; Headers (hashtable name->value, pass to ffmpeg as -user_agent / -headers);
#   Quality ('720p', '1080p', ...); Duration (seconds, double); Expires (DateTime UTC or $null) } plus a few
#   informational extras (Title, Dub, Source, ...). They throw a descriptive error on failure.

# ---------- small shared helpers ----------

function ConvertFrom-UnixTimeUtc([double]$seconds) {
  $epoch = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
  return $epoch.AddSeconds($seconds)
}

function Get-QueryParam([string]$url, [string]$name) {
  $m = [regex]::Match($url, '[?&]' + [regex]::Escape($name) + '=([^&#]*)')
  if (-not $m.Success) { return $null }
  return [Uri]::UnescapeDataString($m.Groups[1].Value.Replace('+', ' '))
}

function ConvertTo-AbsoluteUrl([string]$url, [string]$base) {
  if ([string]::IsNullOrEmpty($url)) { return $url }
  if ($url.StartsWith('//')) { return 'https:' + $url }
  if ($url -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') { return $url }
  return (New-Object Uri((New-Object Uri($base)), $url)).AbsoluteUri
}

# Height of the first video stream via ffprobe (only if ffprobe is on PATH). Returns 0 when unknown.
function Get-ProbeHeight([string]$url, [hashtable]$headers, [int]$timeoutSec = 25) {
  $cmd = Get-Command ffprobe -ErrorAction SilentlyContinue
  if (-not $cmd) { return 0 }
  $argList = @('-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=height', '-of', 'csv=p=0')
  $hdr = ''
  foreach ($k in $headers.Keys) {
    if ($k -ieq 'User-Agent') { $argList += @('-user_agent', ('"' + $headers[$k] + '"')) }
    else { $hdr += ($k + ': ' + $headers[$k] + "`r`n") }
  }
  if ($hdr) { $argList += @('-headers', ('"' + $hdr + '"')) }
  $argList += ('"' + $url + '"')
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $cmd.Path
    $psi.Arguments = ($argList -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi); if (Get-Command Add-ChildToJob -CommandType Function -ErrorAction SilentlyContinue) { Add-ChildToJob $p }
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $null = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($timeoutSec * 1000)) { try { $p.Kill() } catch {}; return 0 }
    $h = 0
    if ([int]::TryParse(($outTask.Result.Trim() -split "`n")[0].Trim(), [ref]$h)) { return $h }
  } catch {}
  return 0
}

# Ranged GET of the first bytes of a media URL. Returns the HTTP status (0 = unreachable).
function Test-MediaUrl([string]$url, [hashtable]$headers, [int]$timeoutSec = 15) {
  try {
    $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($url)
    $req.Method = 'GET'
    $req.Timeout = $timeoutSec * 1000
    $req.ReadWriteTimeout = $timeoutSec * 1000
    $req.AllowAutoRedirect = $true
    $req.UserAgent = $script:WebUA
    foreach ($k in $headers.Keys) {
      if ($k -ieq 'User-Agent') { $req.UserAgent = [string]$headers[$k] }
      elseif ($k -ieq 'Referer') { $req.Referer = [string]$headers[$k] }
      else { $req.Headers[$k] = [string]$headers[$k] }
    }
    $req.AddRange(0, 1023)
    $resp = $null
    try { $resp = $req.GetResponse() }
    catch [System.Net.WebException] { if ($_.Exception.Response) { $resp = $_.Exception.Response } else { return 0 } }
    try { return [int]$resp.StatusCode } finally { $resp.Close() }
  } catch { return 0 }
}

# ---------- Sibnet ----------
# Accepts //video.sibnet.ru/shell.php?videoid=N, https://video.sibnet.ru/videoN-..., or just N.
# The shell page (windows-1251) contains  player.src([{src: "/v/<hash>/<id>.mp4", type: "video/mp4"},]).
# GET of that /v/ URL needs Referer: https://video.sibnet.ru/shell.php?videoid=N (403 without it) and answers
# 302 -> //dvNN.sibnet.ru/<a>/<b>/<c>/<file>.mp4?st=<sig>&e=<unix expiry>&stor=NN&noip=1 which works WITHOUT
# referer/cookies (noip=1: not IP-bound) and 302s once more to cvsNNN-1.sibnet.ru. We return that dvNN URL.
# Note: sibnet's CDN stalls on curl's default User-Agent; send a browser UA (ffmpeg's default Lavf UA also works).
# Verifier additions: shell.php gets IP-blocked (HTTP 403 "Request forbidden by administrative rules") for 10+ minutes
# after a burst of requests, so the resolver caches id -> /v/ URL, spaces shell.php hits >= 1.5 s apart and falls back
# to https://video.sibnet.ru/shell_config_xml.php?videoid=N  (<file>http://video.sibnet.ru/v/<hash>/<id>.mp4</file>,
# <counter.cliptime>seconds</..>, <share_sibnet.sharename>url-encoded title</..>; HTTP 404 = no such video).
if ($null -eq (Get-Variable -Name SibnetCache -Scope Script -ErrorAction SilentlyContinue)) { $script:SibnetCache = @{} }
if ($null -eq (Get-Variable -Name SibnetLastShell -Scope Script -ErrorAction SilentlyContinue)) { $script:SibnetLastShell = $null }
function Resolve-Sibnet {
  param(
    [string]$playerUrl,
    [string]$referer,
    [switch]$NoProbe    # skip the ffprobe call that fills Quality (saves ~2-5 s; Quality is then '')
  )
  if ([string]::IsNullOrWhiteSpace($playerUrl)) { throw 'Sibnet: empty player URL' }
  $id = $null
  $m = [regex]::Match($playerUrl, '(?i)videoid=(\d+)')
  if ($m.Success) { $id = $m.Groups[1].Value }
  else {
    $m = [regex]::Match($playerUrl, '(?i)sibnet\.ru/(?:video|v/[0-9a-f]+/)(\d+)')
    if ($m.Success) { $id = $m.Groups[1].Value }
    elseif ($playerUrl.Trim() -match '^\d+$') { $id = $playerUrl.Trim() }
  }
  if (-not $id) { throw "Sibnet: cannot find a video id in '$playerUrl'" }

  $shellUrl = 'https://video.sibnet.ru/shell.php?videoid=' + $id
  if ($null -eq $script:SibnetCache) { $script:SibnetCache = @{} }

  # FIX (verifier): shell.php is behind a WAF that answers 403 "Request forbidden by administrative rules" to the whole IP
  # for many minutes after a short burst of requests, while /v/, the dvNN CDN and the legacy flash config endpoint
  # shell_config_xml.php keep working. So: (1) reuse a cached /v/ URL (its hash is stable) and skip shell.php,
  # (2) space shell.php requests out, (3) fall back to shell_config_xml.php when shell.php fails.
  $vUrl = $null; $duration = 0.0; $title = ''
  $cached = $script:SibnetCache[$id]
  if ($cached) { $vUrl = $cached.VUrl; $duration = $cached.Duration; $title = $cached.Title }

  for ($pass = 0; $pass -lt 2; $pass++) {
    if (-not $vUrl) {
      $shellStatus = 0; $shellMissing = $false; $netErr = $null
      # (2) at least 1.5 s between shell.php hits from this process
      if ($script:SibnetLastShell) {
        $wait = 1500 - [int]([DateTime]::UtcNow - $script:SibnetLastShell).TotalMilliseconds
        if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
      }
      $h = @{}
      if ($referer) { $h['Referer'] = $referer }
      $page = $null
      try { $page = Invoke-Web -Url $shellUrl -Headers $h -TimeoutSec 20 } catch { $netErr = $_.Exception.Message }
      $script:SibnetLastShell = [DateTime]::UtcNow
      if ($page) {
        $shellStatus = $page.Status
        if ($page.Status -eq 200) {
          $m = [regex]::Match($page.Text, 'player\.src\(\s*\[\s*\{\s*src\s*:\s*["'']([^"'']+)["'']')
          if ($m.Success) {
            $vUrl = ConvertTo-AbsoluteUrl $m.Groups[1].Value 'https://video.sibnet.ru/'
            $dm = [regex]::Match($page.Text, 'og:duration"\s+content="(\d+)"')
            if (-not $dm.Success) { $dm = [regex]::Match($page.Text, '[?&]duration=(\d+)') }
            if ($dm.Success) { $duration = [double]$dm.Groups[1].Value }
            $tm = [regex]::Match($page.Text, 'og:title"\s+content="([^"]*)"')
            if ($tm.Success) { $title = ConvertFrom-HtmlText $tm.Groups[1].Value }
          } else { $shellMissing = $true }   # "Net takogo video" page (or the page layout changed)
        }
      }
      if (-not $vUrl) {
        # (3) legacy player config: <file>http://video.sibnet.ru/v/<hash>/<id>.mp4</file>, 404 for a missing video
        $x = $null
        try { $x = Invoke-Web -Url ('https://video.sibnet.ru/shell_config_xml.php?videoid=' + $id) -Headers $h -TimeoutSec 20 } catch {}
        if ($x -and $x.Status -eq 200) {
          $fm = [regex]::Match($x.Text, '<file>\s*([^<\s]+/v/[^<\s]+)\s*</file>')
          if ($fm.Success) {
            $vUrl = ConvertTo-AbsoluteUrl ($fm.Groups[1].Value -replace '^http://', 'https://') 'https://video.sibnet.ru/'
            $dm = [regex]::Match($x.Text, '<counter\.cliptime>(\d+)<')
            if ($dm.Success) { $duration = [double]$dm.Groups[1].Value }
            $tm = [regex]::Match($x.Text, '<share_sibnet\.sharename>([^<]*)<')
            if ($tm.Success) { try { $title = [Uri]::UnescapeDataString($tm.Groups[1].Value) } catch {} }
          }
        }
        if (-not $vUrl) {
          if ($shellMissing -or ($x -and $x.Status -eq 404)) { throw "Sibnet: video $id not found or removed (no player source on the shell page)" }
          if ($netErr -and -not $x) { throw "Sibnet: cannot reach video.sibnet.ru ($netErr)" }
          if ($shellStatus -eq 403) { throw "Sibnet: video.sibnet.ru refuses requests from this IP (HTTP 403 'Request forbidden by administrative rules' - a temporary rate-limit block after too many requests); try again in a few minutes or use another provider" }
          throw "Sibnet: shell page returned HTTP $shellStatus for video $id"
        }
      }
    }

    $finalUrl = $null
    $expires = $null
    $r = $null
    try { $r = Invoke-Web -Url $vUrl -Headers @{ 'Referer' = $shellUrl } -NoRedirect -TimeoutSec 20 }
    catch { throw "Sibnet: cannot reach the /v/ redirector ($($_.Exception.Message))" }
    if ($r.Status -ge 300 -and $r.Status -lt 400 -and $r.Location) {
      $finalUrl = ConvertTo-AbsoluteUrl $r.Location $vUrl
    } elseif (($r.Status -eq 200 -or $r.Status -eq 206) -and ([string]$r.Headers['Content-Type']) -match '(?i)^(video/|application/octet-stream)') {
      $finalUrl = $vUrl   # served directly (never seen in tests): keep the /v/ URL, the Referer below is then required
    }
    # FIX (verifier): a wrong/stale /v/ hash answers "200 text/html" with an EMPTY body (not 403/404), which the original
    # code accepted as "served directly" and returned as the media URL. Only a video content type counts now.
    if ($finalUrl) { break }
    if ($cached -and $pass -eq 0) { $script:SibnetCache.Remove($id); $cached = $null; $vUrl = $null; continue }   # stale cached hash: go back to shell.php once
    throw "Sibnet: media redirector returned HTTP $($r.Status) for video $id (Referer rejected or video blocked)"
  }
  $script:SibnetCache[$id] = [pscustomobject]@{ VUrl = $vUrl; Duration = $duration; Title = $title }
  $em = [regex]::Match($finalUrl, '[?&]e=(\d{9,11})')
  if ($em.Success) { $expires = ConvertFrom-UnixTimeUtc ([double]$em.Groups[1].Value) }

  $headers = @{ 'User-Agent' = $script:WebUA; 'Referer' = $shellUrl }
  $height = 0
  if (-not $NoProbe) { $height = Get-ProbeHeight $finalUrl $headers }
  $quality = ''
  if ($height -gt 0) { $quality = "$($height)p" }

  return [pscustomobject]@{
    Url      = $finalUrl
    Headers  = $headers
    Quality  = $quality
    Duration = $duration
    Expires  = $expires
    Title    = $title
    Source   = 'sibnet'
    VideoId  = $id
    PageUrl  = $vUrl        # /v/ URL: re-usable with the Referer header if the final URL ever expires
  }
}

# ---------- CVH (cdnvideohub, AnimeGO provider slug "cvh") ----------
# AnimeGO iframe  //animego.me/cdn-iframe/<shikimoriId>/<season>/<episode>?dubbing=<CVH voice studio name>
# renders <video-player data-title-id=29803 data-publisher-id=747 data-aggregator="mali" episode=5 priority-voice=...>
# from https://player.cdnvideohub.com/s2/stable/video-player.umd.js. That component calls
#   GET https://plapi.cdnvideohub.com/api/v1/player/sv/playlist?pub=747&aggr=mali&id=29803&ep=5&sn=1
#       -> {titleName,isSerial,items:[{cvhId,vkId,voiceStudio,voiceType,season,episode}],tags?,ads,vast}  (204 = no content)
#   GET https://plapi.cdnvideohub.com/api/v1/player/sv/video/<vkId>
#       -> {duration, failoverHost, sources:{hlsUrl,dashUrl,mpeg4kUrl,mpeg2kUrl,mpegQhdUrl,mpegFullHdUrl,mpegHighUrl,
#           mpegMediumUrl,mpegLowUrl,mpegLowestUrl,mpegTinyUrl}}    (OK.ru / okcdn.ru signed URLs, expires=<ms>, srcAg=CHROME)
# The okcdn URLs must be fetched with a Chrome-like User-Agent (the one used for the API call); Lavf/Firefox UA -> 400.
# okcdn.ru's HTTPS chain (HARICA ECC root) is not trusted by the gnutls ffmpeg build here, so http:// is returned
# (the same signed URL works over plain HTTP); the https form is in UrlHttps (needs ffmpeg -tls_verify 0).
function Resolve-Cvh {
  param(
    [string]$playerUrl,
    [string]$referer,
    [int]$Episode = 0,         # override the episode from the URL
    [int]$Season = 0,          # override the season from the URL
    [string]$Dub = $null,      # override ?dubbing= (CVH voiceStudio name, fuzzy match)
    [int]$MaxHeight = 1080,    # highest MP4 rendition to pick
    [switch]$PreferHls,        # return the HLS master playlist instead of an MP4 rendition
    [switch]$NoPage            # don't read the iframe page (a link made by Get-CvhPlayerUrl: AnimeGO's publisher values)
  )
  if ([string]::IsNullOrWhiteSpace($playerUrl)) { throw 'CVH: empty player URL' }
  $pUrl = ConvertTo-AbsoluteUrl $playerUrl.Trim() 'https://animego.me/'

  $titleId = $null; $sn = 0; $ep = 0; $voice = $null
  # FIX (verifier): newer AnimeGO titles use a path style  /cdn-iframe/<id>/<dubbing>/<season>/<episode>
  # (e.g. //animego.me/cdn-iframe/61316/Dream Cast/4/1, no ?dubbing=); the old regex only got the id from those.
  $m = [regex]::Match($pUrl, '(?i)/cdn-iframe/(\d+)/([^/?#]*[^/?#\d][^/?#]*)/(\d+)/(\d+)')
  if ($m.Success) {
    $titleId = $m.Groups[1].Value
    try { $voice = [Uri]::UnescapeDataString($m.Groups[2].Value) } catch { $voice = $m.Groups[2].Value }
    $sn = [int]$m.Groups[3].Value; $ep = [int]$m.Groups[4].Value
  } else {
    $m = [regex]::Match($pUrl, '(?i)/cdn-iframe/(\d+)(?:/(\d+))?(?:/(\d+))?')
    if ($m.Success) {
      $titleId = $m.Groups[1].Value
      if ($m.Groups[3].Success) { $sn = [int]$m.Groups[2].Value; $ep = [int]$m.Groups[3].Value }
      elseif ($m.Groups[2].Success) { $ep = [int]$m.Groups[2].Value }
    }
  }
  $q = Get-QueryParam $pUrl 'dubbing'
  if ($q) { $voice = $q }
  $pub = '747'; $aggr = 'mali'

  # Read the iframe for the real publisher/aggregator/title/episode (falls back to AnimeGO's known values).
  $origin = 'https://animego.me'
  try {
    $u = New-Object Uri($pUrl)
    $origin = $u.Scheme + '://' + $u.Host
    if ($NoPage) { throw 'no page' }
    $h = @{}
    if ($referer) { $h['Referer'] = $referer }
    $page = Invoke-Web -Url $pUrl -Headers $h -TimeoutSec 20
    if ($page.Status -eq 200 -and $page.Text -match '<video-player') {
      $tag = [regex]::Match($page.Text, '(?s)<video-player\b[^>]*>').Value
      $a = [regex]::Match($tag, 'data-title-id="([^"]+)"'); if ($a.Success) { $titleId = $a.Groups[1].Value }
      $a = [regex]::Match($tag, 'data-publisher-id="([^"]+)"'); if ($a.Success) { $pub = $a.Groups[1].Value }
      $a = [regex]::Match($tag, 'data-aggregator="([^"]+)"'); if ($a.Success) { $aggr = $a.Groups[1].Value }
      $a = [regex]::Match($tag, '\sepisode="(\d+)"'); if ($a.Success -and $ep -le 0) { $ep = [int]$a.Groups[1].Value }
      $a = [regex]::Match($tag, '\sseason="(\d+)"'); if ($a.Success -and $sn -le 0) { $sn = [int]$a.Groups[1].Value }
      $a = [regex]::Match($tag, 'priority-voice="([^"]*)"'); if ($a.Success -and -not $voice) { $voice = ConvertFrom-HtmlText $a.Groups[1].Value }
    }
  } catch {}
  if ($Episode -gt 0) { $ep = $Episode }
  if ($Season -gt 0) { $sn = $Season }
  if ($Dub) { $voice = $Dub }
  if (-not $titleId) { throw "CVH: cannot find the title id in '$playerUrl'" }
  if ($ep -le 0) { $ep = 1 }

  $api = 'https://plapi.cdnvideohub.com/api/v1/player/sv'
  $apiHeaders = @{ 'Accept' = 'application/json'; 'Origin' = $origin; 'Referer' = $origin + '/' }
  $q = 'pub=' + [Uri]::EscapeDataString($pub) + '&aggr=' + [Uri]::EscapeDataString($aggr) + '&id=' + [Uri]::EscapeDataString($titleId) + '&ep=' + $ep
  if ($sn -gt 0) { $q += '&sn=' + $sn }
  $pl = $null
  for ($try = 0; $try -lt 3; $try++) {
    try { $pl = Invoke-Web -Url ($api + '/playlist?' + $q) -Headers $apiHeaders -TimeoutSec 20 } catch { $pl = $null }
    if ($pl -and ($pl.Status -eq 200 -or $pl.Status -eq 204)) { break }
    Start-Sleep -Seconds 2
  }
  if (-not $pl) { throw 'CVH: plapi.cdnvideohub.com is unreachable' }
  if ($pl.Status -eq 204) { throw "CVH: no content for title $titleId (publisher $pub, aggregator $aggr)" }
  if ($pl.Status -ne 200) { throw "CVH: playlist API returned HTTP $($pl.Status) for title $titleId" }
  $data = ConvertFrom-JsonDict $pl.Text
  if ($data -isnot [System.Collections.IDictionary]) { throw 'CVH: unexpected playlist response' }
  if ($data.ContainsKey('tags') -and $data['tags'] -and (@($data['tags']) -contains 5)) { throw "CVH: title $titleId is blocked (tag Blocked)" }

  $items = @()
  foreach ($it in @($data['items'])) {
    if ($it -isnot [System.Collections.IDictionary]) { continue }
    $vk = 0.0
    if (-not ($it.ContainsKey('vkId') -and [double]::TryParse([string]$it['vkId'], [ref]$vk) -and $vk -gt 0)) { continue }
    $items += $it
  }
  if ($items.Count -eq 0) { throw "CVH: playlist for title $titleId has no playable items" }

  $epItems = @($items | Where-Object { [int]$_['episode'] -eq $ep -or (-not $_.ContainsKey('episode') -and $ep -eq 1) })
  if ($sn -gt 0) {
    $bySeason = @($epItems | Where-Object { [int]$_['season'] -eq $sn })
    if ($bySeason.Count -gt 0) { $epItems = $bySeason }
    else {
      $seasons = @($epItems | ForEach-Object { [int]$_['season'] } | Select-Object -Unique)
      if ($seasons.Count -gt 1) { throw "CVH: season $sn episode $ep not found (title $titleId has seasons $($seasons -join ', '))" }
    }
  }
  if ($epItems.Count -eq 0) {
    $eps = @($items | ForEach-Object { [int]$_['episode'] } | Sort-Object -Unique)
    throw "CVH: episode $ep not found for title $titleId (available near it: $($eps -join ', '))"
  }

  $pick = $null
  if ($voice) {
    $pick = Find-CvhItem $epItems $voice
    if (-not $pick) {
      $names = @($epItems | ForEach-Object { if ($_['voiceStudio']) { $_['voiceStudio'] } else { '(' + $_['voiceType'] + ')' } })
      throw "CVH: dub '$voice' not available for episode $ep; available: $($names -join ', ')"
    }
  } else {
    $pick = $epItems | Where-Object { $_['voiceStudio'] } | Select-Object -First 1
    if (-not $pick) { $pick = $epItems[0] }
  }

  $vkId = [string]$pick['vkId']
  $v = $null
  try { $v = Invoke-Web -Url ($api + '/video/' + $vkId) -Headers $apiHeaders -TimeoutSec 20 }
  catch { throw "CVH: video API unreachable ($($_.Exception.Message))" }
  if ($v.Status -eq 204 -or $v.Status -eq 404) { throw "CVH: video $vkId is missing (HTTP $($v.Status))" }
  if ($v.Status -ne 200) { throw "CVH: video API returned HTTP $($v.Status) for vkId $vkId" }
  $vd = ConvertFrom-JsonDict $v.Text
  if ($vd -isnot [System.Collections.IDictionary] -or -not $vd.ContainsKey('sources') -or -not $vd['sources']) { throw "CVH: no sources for vkId $vkId" }
  $src = $vd['sources']

  $renditions = @(
    @{ k = 'mpeg4kUrl'; h = 2160 }, @{ k = 'mpeg2kUrl'; h = 1440 }, @{ k = 'mpegQhdUrl'; h = 1440 },
    @{ k = 'mpegFullHdUrl'; h = 1080 }, @{ k = 'mpegHighUrl'; h = 720 }, @{ k = 'mpegMediumUrl'; h = 480 },
    @{ k = 'mpegLowUrl'; h = 360 }, @{ k = 'mpegLowestUrl'; h = 240 }, @{ k = 'mpegTinyUrl'; h = 144 })
  $cands = @()
  foreach ($r in $renditions) {
    if ($src.ContainsKey($r.k) -and $src[$r.k] -and $r.h -le $MaxHeight) { $cands += [pscustomobject]@{ Url = [string]$src[$r.k]; Quality = "$($r.h)p" } }
  }
  $hls = $null
  if ($src.ContainsKey('hlsUrl') -and $src['hlsUrl']) { $hls = [string]$src['hlsUrl'] }
  if ($hls) {
    $hlsCand = [pscustomobject]@{ Url = $hls; Quality = 'auto (HLS)' }
    if ($PreferHls) { $cands = @($hlsCand) + $cands } else { $cands += $hlsCand }
  }
  if ($src.ContainsKey('dashUrl') -and $src['dashUrl']) { $cands += [pscustomobject]@{ Url = [string]$src['dashUrl']; Quality = 'auto (DASH)' } }
  if ($cands.Count -eq 0) { throw "CVH: vkId $vkId has no playable renditions" }

  $headers = @{ 'User-Agent' = $script:WebUA }   # must stay a Chrome UA (srcAg=CHROME in the signed URL)
  $failoverHost = $null
  if ($vd.ContainsKey('failoverHost') -and $vd['failoverHost']) { $failoverHost = [string]$vd['failoverHost'] }

  $chosen = $null; $chosenHttp = $null
  foreach ($c in $cands) {
    $httpUrl = $c.Url -replace '^https://', 'http://'
    $tries = @($httpUrl)
    if ($failoverHost) { $tries += ([regex]::Replace($httpUrl, '^http://[^/?#]+', 'http://' + $failoverHost)) }
    foreach ($t in $tries) {
      $st = Test-MediaUrl $t $headers
      if ($st -eq 200 -or $st -eq 206) { $chosen = $c; $chosenHttp = $t; break }
    }
    if ($chosen) { break }
  }
  if (-not $chosen) { throw "CVH: every rendition of vkId $vkId was rejected by the CDN (geo-block or expired signature)" }

  $expires = $null
  $em = [regex]::Match($chosenHttp, '(?:[?&]|/)expires[=/](\d{10,13})')
  if ($em.Success) {
    $n = [double]$em.Groups[1].Value
    if ($n -gt 100000000000) { $n = $n / 1000 }
    $expires = ConvertFrom-UnixTimeUtc $n
  }
  $duration = 0.0
  if ($vd.ContainsKey('duration')) { $duration = [double]$vd['duration'] }

  return [pscustomobject]@{
    Url       = $chosenHttp
    Headers   = $headers
    Quality   = $chosen.Quality
    Duration  = $duration
    Expires   = $expires
    Title     = [string]$data['titleName']
    Dub       = [string]$pick['voiceStudio']
    DubType   = [string]$pick['voiceType']
    Season    = [int]$pick['season']
    Episode   = [int]$pick['episode']
    Source    = 'cvh'
    VkId      = $vkId
    UrlHttps  = ($chosenHttp -replace '^http://', 'https://')   # needs ffmpeg -tls_verify 0 with the gnutls build
    HlsUrl    = $(if ($hls) { $hls -replace '^https://', 'http://' } else { $null })
    Voices    = @($epItems | ForEach-Object { [string]$_['voiceStudio'] } | Where-Object { $_ })
  }
}

# The playlist item of voice-over $voice among one episode's CVH items ($null when it isn't there).
function Find-CvhItem($epItems, [string]$voice) {
  $norm = { param($s) if (-not $s) { return '' }; return ([regex]::Replace(([string]$s).ToLowerInvariant(), '[^\p{L}\p{N}]', '')) }
  $want = & $norm $voice
  if (-not $want) { return $null }
  $pick = $epItems | Where-Object { (& $norm $_['voiceStudio']) -eq $want } | Select-Object -First 1
  if (-not $pick) { $pick = $epItems | Where-Object { $_['voiceStudio'] -and (Test-SameDub ([string]$_['voiceStudio']) $voice) } | Select-Object -First 1 }
  if (-not $pick -and $want.Length -ge 3) {
    # FIX (verifier): among partial matches take the closest in length (e.g. 'AniLibria' -> 'AnilibriaTV'), not just the first one
    $pick = $epItems | Where-Object { $n = & $norm $_['voiceStudio']; $n -and ($n.Contains($want) -or $want.Contains($n)) } |
      Sort-Object { [math]::Abs((& $norm $_['voiceStudio']).Length - $want.Length) } | Select-Object -First 1
  }
  return $pick
}

# CVH's name for voice-over $dub in one episode of Shikimori title $sid (AnimeGO's publisher values), $null when CVH
# doesn't have that episode in that voice-over (or doesn't answer). $episode 0 = a film.
function Find-CvhVoice([string]$sid, [int]$season, [int]$episode, [string]$dub) {
  if ($sid -notmatch '^\d+$' -or -not $dub) { return $null }
  if ($episode -le 0) { $episode = 1 }
  $q = 'pub=747&aggr=mali&id=' + $sid + '&ep=' + $episode
  if ($season -gt 0) { $q += '&sn=' + $season }
  $r = Invoke-Web -Url ('https://plapi.cdnvideohub.com/api/v1/player/sv/playlist?' + $q) -Headers @{ 'Accept' = 'application/json'; 'Origin' = 'https://animego.me'; 'Referer' = 'https://animego.me/' } -TimeoutSec 10
  if ($r.Status -ne 200) { return $null }
  $data = ConvertFrom-JsonDict $r.Text
  if ($data -isnot [System.Collections.IDictionary]) { return $null }
  if ($data.ContainsKey('tags') -and $data['tags'] -and (@($data['tags']) -contains 5)) { return $null }
  $items = @(@($data['items']) | Where-Object { $_ -is [System.Collections.IDictionary] -and [int]$_['episode'] -eq $episode -and $_['vkId'] })
  if ($season -gt 0) {
    $bySeason = @($items | Where-Object { [int]$_['season'] -eq $season })
    if ($bySeason.Count -gt 0) { $items = $bySeason }
    elseif (@($items | ForEach-Object { [int]$_['season'] } | Select-Object -Unique).Count -gt 1) { return $null }
  }
  $pick = Find-CvhItem $items $dub
  if ($pick) { return [string]$pick['voiceStudio'] }
  return $null
}

# A CVH link Resolve-Cvh understands (with -NoPage): AnimeGO's iframe path for a Shikimori id, voice-over, season, episode.
function Get-CvhPlayerUrl([string]$sid, [string]$voice, [int]$season, [int]$episode) {
  return ('https://animego.me/cdn-iframe/' + $sid + '/' + [Uri]::EscapeDataString($voice) + '/' + [Math]::Max(0, $season) + '/' + [Math]::Max(1, $episode))
}

# ==================================================================================================
# Alloha (the player WPARTY uses for many shows)
# ==================================================================================================
# Alloha player resolver (Windows PowerShell 5.1). Needs http_helper.ps1 dot-sourced first (Invoke-Web, ConvertTo-FormBody, ConvertFrom-JsonDict).
#
# Flow (all plain HTTP, no JS engine):
#   1. GET <iframeUrl> with any Referer (without a Referer / valid token the host answers 404).
#      The HTML carries: <meta name="viewporti" content="LY">  (one-shot key),  userParam.token,  fileList = JSON.parse('...') (active file id + all files).
#   2. POST <origin>/bnsi/movies/<fileId>   (form: token, av1=false, autoplay=0, audio=, subtitle=)
#      header  Borth: <any-hex-id>|<z9(zZ(zy(LY)))>   (three fixed string permutations of the meta value; wrong value -> 404)
#   3. JSON answer: hlsSource[] = one entry per audio track {label, audioId, quality:{"720":master.m3u8,...}}, tracks[] (VTT), time (link expiry, ms).
#   4. The m3u8 / segments only need  Origin: <iframe origin>  (exact scheme+host of the player, otherwise 403 "X-VD: origin_mismatch").
#      Plain fMP4 HLS (EXT-X-MAP init + .m4s), no EXT-X-KEY, no DRM. The WebSocket "edge_hash" / Accepts-Controls token of the web
#      player was not required.
#   ANTI-LEECH: the vkvideo.cloud edge kills a session that is read much faster than real time. Measured:
#      full speed (3.4x-4.3x): "X-VD: session_blocked" after 54-74 segments (75-130 s wall clock), with or without the WebSocket
#      token; afterwards that edge answered "client_blocked" for a few minutes and /bnsi handed out URLs failing with
#      "X-VD: token_decrypt" (cleared by itself after ~10 min).  -re (1x): 420 s OK.  -readrate 2: 720 s in 363 s OK.
#      => always read with ffmpeg "-readrate 2" (download) or "-re" (direct restream); never a full-speed download.

function ConvertTo-AllohaZy([string]$s) {
  # JS zy(): chars are dealt into buckets by bit-length of the output index, buckets taken from the input highest-bucket-first
  $n = $s.Length
  if ($n -le 1) { return $s }
  $b = 0; while ((1 -shl $b) -lt $n) { $b++ }
  $key = New-Object int[] $n
  $cnt = New-Object int[] ($b + 1)
  for ($i = 0; $i -lt $n; $i++) { $q = $i; $bl = 0; while ($q -gt 0) { $bl++; $q = $q -shr 1 }; $key[$i] = $bl; $cnt[$bl]++ }
  $start = New-Object int[] ($b + 1); $f = 0
  for ($h = $b; $h -ge 0; $h--) { $start[$h] = $f; $f += $cnt[$h] }
  $pos = New-Object int[] ($b + 1)
  $out = New-Object char[] $n
  for ($i = 0; $i -lt $n; $i++) { $k = $key[$i]; $out[$i] = $s[$start[$k] + $pos[$k]]; $pos[$k]++ }
  return (New-Object string (, $out))
}

function ConvertTo-AllohaZZ([string]$s) {
  # JS zZ(): bucket = number of trailing zero bits of the output index (index 0 -> bucket b), buckets taken lowest-first
  $n = $s.Length
  if ($n -le 1) { return $s }
  $b = 0; while ((1 -shl $b) -lt $n) { $b++ }
  $key = New-Object int[] $n
  $cnt = New-Object int[] ($b + 1)
  for ($i = 0; $i -lt $n; $i++) {
    if ($i -eq 0) { $tz = $b } else { $q = $i; $tz = 0; while (($q -band 1) -eq 0) { $tz++; $q = $q -shr 1 } }
    $key[$i] = $tz; $cnt[$tz]++
  }
  $start = New-Object int[] ($b + 1); $f = 0
  for ($h = 0; $h -le $b; $h++) { $start[$h] = $f; $f += $cnt[$h] }
  $pos = New-Object int[] ($b + 1)
  $out = New-Object char[] $n
  for ($i = 0; $i -lt $n; $i++) { $k = $key[$i]; $out[$i] = $s[$start[$k] + $pos[$k]]; $pos[$k]++ }
  return (New-Object string (, $out))
}

function ConvertTo-AllohaZ9([string]$s) {
  # JS z9(): positions visited as (p+2) mod P, P = smallest prime >= n+1; input char i goes to the i-th visited position
  $n = $s.Length
  if ($n -le 1) { return $s }
  $p = [Math]::Max(2, $n + 1)
  while ($true) {
    $isPrime = $true
    if ($p -lt 2) { $isPrime = $false } elseif ($p % 2 -eq 0) { $isPrime = ($p -eq 2) } else { for ($d = 3; $d * $d -le $p; $d += 2) { if ($p % $d -eq 0) { $isPrime = $false; break } } }
    if ($isPrime) { break }
    $p++
  }
  $seen = New-Object bool[] $n
  $order = New-Object System.Collections.Generic.List[int]
  $z = 0
  $guard = 0
  while ($order.Count -lt $n) {
    $z = ($z + 2) % $p
    if ($z -lt $n -and -not $seen[$z]) { $order.Add($z); $seen[$z] = $true }
    $guard++; if ($guard -gt (4 * $p + 16)) { throw 'Alloha: z9 permutation did not converge' }
  }
  $out = New-Object char[] $n
  for ($i = 0; $i -lt $n; $i++) { $out[$order[$i]] = $s[$i] }
  return (New-Object string (, $out))
}

function Get-AllohaBorthKey([string]$viewporti) {
  return (ConvertTo-AllohaZ9 (ConvertTo-AllohaZZ (ConvertTo-AllohaZy $viewporti)))
}

function Get-AllohaQueryParam([string]$url, [string]$name) {
  $m = [regex]::Match($url, '[?&]' + [regex]::Escape($name) + '=([^&#]*)')
  if ($m.Success) { return [Uri]::UnescapeDataString($m.Groups[1].Value.Replace('+', ' ')) }
  return $null
}

# Reads the fileList JSON literal embedded in the iframe HTML. Returns a Dictionary tree or $null.
function Get-AllohaFileList([string]$html) {
  $m = [regex]::Match($html, "const\s+fileList\s*=\s*JSON\.parse\('((?:[^'\\]|\\.)*)'\)")
  if (-not $m.Success) { return $null }
  $lit = $m.Groups[1].Value.Replace("\'", "'")
  try { return (ConvertFrom-JsonDict $lit) } catch { return $null }
}

# Finds the file entry for season/episode/translation (serial, selector type 2 layout: all["t<tr>"].file[season][episode]).
function Find-AllohaFile($fileList, [string]$season, [string]$episode, [string]$translation) {
  if ($null -eq $fileList -or -not $fileList.ContainsKey('all')) { return $null }
  $all = $fileList['all']
  if ($all -isnot [System.Collections.IDictionary]) { return $null }
  $tKey = 't' + $translation
  if ($translation -and $all.ContainsKey($tKey)) {
    $t = $all[$tKey]
    if ($t -is [System.Collections.IDictionary] -and $t.ContainsKey('file')) {
      $files = $t['file']
      if ($files -is [System.Collections.IDictionary] -and $files.ContainsKey($season)) {
        $eps = $files[$season]
        if ($eps -is [System.Collections.IDictionary] -and $eps.ContainsKey($episode)) { return $eps[$episode] }
      }
    }
  }
  # alternative layout (selector type 1): all[season][episode]["t<tr>"]
  if ($all.ContainsKey($season)) {
    $s = $all[$season]
    if ($s -is [System.Collections.IDictionary] -and $s.ContainsKey($episode)) {
      $e = $s[$episode]
      if ($e -is [System.Collections.IDictionary] -and $e.ContainsKey($tKey)) { return $e[$tKey] }
    }
  }
  return $null
}

# Lists the translations available in an Alloha fileList: id, name, seasons present.
function Get-AllohaTranslations($fileList) {
  $res = @()
  if ($null -eq $fileList -or -not $fileList.ContainsKey('all')) { return $res }
  foreach ($k in $fileList['all'].Keys) {
    $t = $fileList['all'][$k]
    if ($k -like 't*' -and $t -is [System.Collections.IDictionary]) {
      $seasons = @(); if ($t.ContainsKey('file') -and $t['file'] -is [System.Collections.IDictionary]) { $seasons = @($t['file'].Keys) }
      $res += [pscustomobject]@{ Id = $k.Substring(1); Name = [string]$t['name']; Seasons = $seasons }
    }
  }
  return $res
}

<#
.SYNOPSIS
  Resolves an Alloha iframe URL (e.g. the WPARTY movieSourceURL + "&kp=..&translation=..&season=..&episode=..") to a direct HLS URL.
.PARAMETER IframeUrl   full player URL, e.g. https://akmeism-as.stloadi.live/?token=...&kp=923115&translation=10&season=1&episode=2
.PARAMETER Referer     page that embeds the player (any non-empty value works; https://wparty.net/ for WPARTY)
.PARAMETER MaxHeight   pick the best quality <= this height (0 = best available)
.PARAMETER AudioPattern regex matched against the audio labels (e.g. 'rus', 'jpn|Original'); default = server default / first track (the dub)
.PARAMETER NoCheck     skip the one GET of the master playlist that verifies the CDN accepts the URL
.OUTPUTS [pscustomobject] Url (master .m3u8 of the chosen audio track/quality), Headers (ordered: Origin, Referer, User-Agent),
         FfmpegHeaders ("Origin: ..`r`nReferer: ..`r`n" for ffmpeg -headers), UserAgent, FfmpegInputArgs (@('-readrate','2')),
         Quality, Qualities (ordered height->url), AudioTrack, AudioTracks (Label, AudioId, Default, Qualities),
         Subtitles (Label, Language, Kind, Url of a WebVTT file - same Origin header), SkipTime ("131-218,1271-1362" = intro/outro),
         ExpiresAt (UTC; links die ~6 h after resolving), Title, Season, Episode, TranslationId, Translation, FileId, Origin,
         Warning, ClientId, WsUrl, CdnStatus, CdnReason, MaxReadRate
.NOTES   Throws on: player page not 200 (bad/expired token, missing Referer, or kp/season/episode unknown to Alloha),
         missing viewporti/token/file id, requested season/episode absent from fileList, /bnsi error (e.g. 404 when the Borth
         key is wrong = player JS changed), empty hlsSource, CDN probe not 200 (message contains X-VD reason).
#>
function Resolve-Alloha {
  param(
    [Parameter(Mandatory = $true)][string]$IframeUrl,
    [string]$Referer = 'https://wparty.net/',
    [int]$MaxHeight = 0,
    [string]$AudioPattern = $null,
    [switch]$NoCheck
  )
  if ($IframeUrl.StartsWith('//')) { $IframeUrl = 'https:' + $IframeUrl }
  if (-not $Referer) { $Referer = 'https://wparty.net/' }
  $u = [Uri]$IframeUrl
  $origin = $u.Scheme + '://' + $u.Authority

  # 1. player page
  $page = Invoke-Web -Url $IframeUrl -Headers @{ Referer = $Referer; Accept = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' }
  # 404 = token unknown/expired, no Referer, or kp/season/episode not in Alloha's catalogue (e.g. episode=99)
  if ($page.Status -ne 200) { throw ("Alloha: player page HTTP {0} (bad/expired token, missing Referer, or this kp/season/episode does not exist): {1}" -f $page.Status, $IframeUrl) }
  $html = $page.Text
  $mLY = [regex]::Match($html, '<meta[^>]*name="viewporti"[^>]*content="([^"]+)"')
  if (-not $mLY.Success) { $mLY = [regex]::Match($html, '<meta[^>]*content="([^"]+)"[^>]*name="viewporti"') }
  if (-not $mLY.Success) { throw 'Alloha: viewporti key not found in player HTML (player layout changed)' }
  $ly = $mLY.Groups[1].Value
  $token = $null
  $mTok = [regex]::Match($html, "userParam\s*=\s*\{[^}]*?token:\s*'([^']+)'")
  if ($mTok.Success) { $token = $mTok.Groups[1].Value } else { $token = Get-AllohaQueryParam $IframeUrl 'token' }
  if (-not $token) { throw 'Alloha: token not found' }

  $fileList = Get-AllohaFileList $html
  $active = $null
  $listType = 'serial'
  if ($fileList -and $fileList.ContainsKey('active')) { $active = $fileList['active']; $listType = [string]$fileList['type'] }
  $fileId = $null
  if ($active) { $fileId = [string]$active['id'] }
  if (-not $fileId) {
    $mId = [regex]::Match($html, '"active":\{"id":(\d+)')
    if ($mId.Success) { $fileId = $mId.Groups[1].Value } else { throw 'Alloha: active file id not found in player HTML' }
  }

  # Make sure we got the requested episode (Alloha silently falls back to another file when the combination does not exist)
  $wantS = Get-AllohaQueryParam $IframeUrl 'season'
  $wantE = Get-AllohaQueryParam $IframeUrl 'episode'
  $wantT = Get-AllohaQueryParam $IframeUrl 'translation'
  $warning = $null
  if ($active -and $listType -eq 'serial' -and $wantS -and $wantE) {
    $haveS = [string]$active['seasons']; $haveE = [string]$active['episode']; $haveT = [string]$active['id_translation']
    if ($haveS -ne $wantS -or $haveE -ne $wantE -or ($wantT -and $haveT -ne $wantT)) {
      $exact = Find-AllohaFile $fileList $wantS $wantE $wantT
      if ($exact) { $active = $exact; $fileId = [string]$exact['id'] }
      elseif ($haveS -ne $wantS -or $haveE -ne $wantE) { throw ("Alloha: season {0} episode {1} not available (player offers S{2}E{3})" -f $wantS, $wantE, $haveS, $haveE) }
      else { $warning = (T 'translation {0} not available for S{1}E{2}; using {3} ({4})' $wantT $wantS $wantE $haveT ([string]$active['translation'])) }
    }
  }

  # 2. source request
  $rnd = New-Object byte[] 32
  (New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($rnd)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $clientId = (($sha.ComputeHash($rnd) | ForEach-Object { $_.ToString('x2') }) -join '')
  $borth = $clientId + '|' + (Get-AllohaBorthKey $ly)
  $kind = 'movies'; if ($listType -eq 'trailer') { $kind = 'trailers' }
  $form = [ordered]@{ token = $token; av1 = 'false'; autoplay = '0'; audio = ''; subtitle = '' }
  $resp = Invoke-Web -Url ("{0}/bnsi/{1}/{2}" -f $origin, $kind, $fileId) -Method POST -Body (ConvertTo-FormBody $form) `
    -ContentType 'application/x-www-form-urlencoded; charset=UTF-8' `
    -Headers @{ Referer = $IframeUrl; Origin = $origin; 'X-Requested-With' = 'XMLHttpRequest'; Accept = '*/*'; Borth = $borth }
  if ($resp.Status -ne 200) {
    $msg = $resp.Text; try { $j = ConvertFrom-JsonDict $resp.Text; if ($j -and $j['error']) { $msg = [string]$j['error'] } } catch {}
    throw ("Alloha: /bnsi/{0}/{1} HTTP {2}: {3}" -f $kind, $fileId, $resp.Status, $msg)
  }
  $data = ConvertFrom-JsonDict $resp.Text
  if ($null -eq $data) { throw 'Alloha: empty /bnsi answer' }

  # 3. audio tracks / qualities
  $tracks = @()
  if ($data.ContainsKey('hlsSource') -and $data['hlsSource']) {
    foreach ($src in $data['hlsSource']) {
      $q = [ordered]@{}
      $keys = @($src['quality'].Keys | Sort-Object { [int]([regex]::Match([string]$_, '\d+').Value) } -Descending)
      foreach ($k in $keys) { $q[[string]$k] = [string]$src['quality'][$k] }
      $def = -1; if ($src.ContainsKey('default') -and $src['default']) { try { $def = [double]$src['default'] } catch { $def = 1 } }
      $tracks += [pscustomobject]@{ Label = [string]$src['label']; AudioId = [string]$src['audioId']; Default = $def; Qualities = $q }
    }
  }
  if ($tracks.Count -eq 0) { throw ('Alloha: answer has no hlsSource (keys: ' + (($data.Keys) -join ',') + ')') }

  $chosen = $null
  if ($AudioPattern) { $chosen = $tracks | Where-Object { $_.Label -match $AudioPattern } | Select-Object -First 1 }
  if (-not $chosen) {
    $best = ($tracks | Measure-Object -Property Default -Maximum).Maximum
    $chosen = $tracks | Where-Object { $_.Default -eq $best } | Select-Object -First 1
  }
  $qKey = $null
  foreach ($k in $chosen.Qualities.Keys) {
    $h = [int]([regex]::Match($k, '\d+').Value)
    if ($MaxHeight -le 0 -or $h -le $MaxHeight) { $qKey = $k; break }
  }
  if (-not $qKey) { $qKey = @($chosen.Qualities.Keys)[-1] }

  $subs = @()
  if ($data.ContainsKey('tracks') -and $data['tracks']) {
    foreach ($t in $data['tracks']) { $subs += [pscustomobject]@{ Label = [string]$t['label']; Language = [string]$t['language']; Kind = [string]$t['kind']; Url = [string]$t['src'] } }
  }
  $expires = $null
  if ($data.ContainsKey('time') -and $data['time']) { try { $expires = ([DateTime]'1970-01-01Z').ToUniversalTime().AddMilliseconds([double]$data['time']) } catch {} }
  $title = $null; $mt = [regex]::Match($html, '"mediaMetadata":\{"title":"((?:[^"\\]|\\.)*)"'); if ($mt.Success) { try { $title = ConvertFrom-JsonDict ('"' + $mt.Groups[1].Value + '"') } catch {} }

  $hdr = [ordered]@{ 'Origin' = $origin; 'Referer' = $origin + '/'; 'User-Agent' = $script:WebUA }
  $ff = ''; foreach ($k in @('Origin', 'Referer')) { $ff += $k + ': ' + $hdr[$k] + "`r`n" }
  $wsUrl = $null
  if ($data['pnr'] -and $data['pnk']) { $wsUrl = [string]$data['pnr'] + '?sid=' + [Uri]::EscapeDataString([string]$data['pnk']) + '&v=2.1' }

  # 4. one cheap probe of the master playlist: the CDN answers 403 with an "X-VD" reason header
  #    origin_mismatch = wrong Origin; session_blocked = this URL was used too aggressively (re-resolve);
  #    client_blocked / token_decrypt = this IP is temporarily flagged (fall back to another source for a while)
  $cdnStatus = $null; $cdnReason = $null
  if (-not $NoCheck) {
    $chk = $null
    try { $chk = Invoke-Web -Url $chosen.Qualities[$qKey] -Headers @{ Origin = $origin; Referer = $origin + '/' } -TimeoutSec 15 } catch { $chk = $null }
    if ($chk) {
      $cdnStatus = $chk.Status; $cdnReason = $chk.Headers['X-VD']
      if ($chk.Status -ne 200 -or $chk.Text -notmatch '#EXTM3U') {
        throw ("Alloha: CDN refused the stream (HTTP {0}, X-VD={1}) for {2}" -f $chk.Status, $cdnReason, $chosen.Qualities[$qKey])
      }
    }
  }

  $o = [pscustomobject]@{
    Url           = $chosen.Qualities[$qKey]
    Headers       = $hdr
    FfmpegHeaders = $ff
    UserAgent     = $script:WebUA
    Quality       = $qKey
    Qualities     = $chosen.Qualities
    AudioTrack    = $chosen.Label
    AudioTracks   = $tracks
    Subtitles     = $subs
    SkipTime      = [string]$data['skipTime']
    ExpiresAt     = $expires
    Title         = $title
    Season        = $(if ($active) { [string]$active['seasons'] } else { $wantS })
    Episode       = $(if ($active) { [string]$active['episode'] } else { $wantE })
    TranslationId = $(if ($active) { [string]$active['id_translation'] } else { $wantT })
    Translation   = $(if ($active) { [string]$active['translation'] } else { $null })
    FileId        = $fileId
    Origin        = $origin
    Warning       = $warning
    ClientId      = $clientId      # the id sent in Borth; the web player also sends it as "Accepts-Controls" (not required so far)
    WsUrl         = $wsUrl         # player telemetry socket (sends edge_hash tokens); NOT needed for playback in tests
    CdnStatus     = $cdnStatus
    CdnReason     = $cdnReason
    # The CDN blocks bulk downloads: put these before -i (2x real time was tested OK; full speed gets the session killed)
    FfmpegInputArgs = @('-readrate', '2')
    MaxReadRate   = 2
  }
  return $o
}

# Builds the Alloha iframe URL the way WPARTY does (function uS in its bundle) from a room state.
#   movieSourceURL = "https://<host>/?token=<token>" (take it fresh from REC:host each time: host/token are per-site and can rotate)
function Get-AllohaIframeUrlFromWparty([string]$movieSourceURL, [string]$kinopoiskId, [string]$translation, [string]$season, [string]$episode) {
  return ('{0}&kp={1}&hidden=season,episode,translation&translation={2}&season={3}&episode={4}' -f $movieSourceURL, $kinopoiskId, $translation, $season, $episode)
}

# The Alloha link WPARTY gives its rooms (the same for every show; seen 2026-10-02). A WPARTY room that plays Alloha
# updates it (Expand-Wparty); when it stops working, Resolve-Candidate asks WPARTY for the current one.
$script:AllohaBase = 'https://akmeism-as.stloadi.live/?token=a98d0caef52525b02dae4480a95c39'
$script:AllohaBaseRenewed = $false
$script:AllohaCatalogs = @{}   # Kinopoisk id -> Get-AllohaCatalog answer (this session)

# Alloha's voice-over for $dub among the ones WPARTY's movieCheck lists for a show: Id, Title ($null when it hasn't it).
function Find-AllohaTranslation($Sources, [string]$dub) {
  foreach ($src in @($Sources)) {
    if ((Get-WpVal $src 'name') -ne 'alloha') { continue }
    $trs = @(Get-WpVal $src 'translations' | Where-Object { $_ })
    $i = Find-DubIndex @($trs | ForEach-Object { [string](Get-WpVal $_ 'title') }) $dub
    if ($i -ge 0) { return [pscustomobject]@{ Id = [string](Get-WpVal $trs[$i] 'id'); Title = [string](Get-WpVal $trs[$i] 'title') } }
  }
  return $null
}

# An Alloha candidate for Kinopoisk id $kp, Alloha voice-over $trId, season/episode (episode 0 = a film).
function New-AllohaCand([string]$kp, [string]$trId, [string]$dub, [int]$season, [int]$episode) {
  $a = [pscustomobject]@{ Source = 'alloha'; SourceUrl = $script:AllohaBase; KpId = $kp; Translation = $trId; Season = $null; Episode = $null; ShikimoriId = $null }
  if ($episode -gt 0) { $a.Season = [Math]::Max(1, $season); $a.Episode = $episode }
  $c = New-Cand 'alloha' (Get-WpartyPlayerUrl $a) 'https://wparty.net/' $dub
  $c.Season = $season; $c.Episode = $episode
  $c | Add-Member -NotePropertyName AllohaArgs -NotePropertyValue $a
  return $c
}

# What Alloha has of Kinopoisk id $kp (one player page, kept for the session): Type ('serial' / 'movie') and
# Translations (Id, Name, Seasons = season -> episode numbers). $null when Alloha doesn't have it or doesn't answer.
function Get-AllohaCatalog([string]$kp) {
  if ($script:AllohaCatalogs.ContainsKey($kp)) { return $script:AllohaCatalogs[$kp] }
  $cat = $null
  try {
    $a = [pscustomobject]@{ Source = 'alloha'; SourceUrl = $script:AllohaBase; KpId = $kp; Translation = ''; Season = $null; Episode = $null; ShikimoriId = $null }
    $page = Invoke-Web -Url (Get-WpartyPlayerUrl $a) -Headers @{ Referer = 'https://wparty.net/' } -TimeoutSec 15
    if ($page.Status -ge 500) { return $null }   # (not remembered: may answer next time)
    $fl = $null
    if ($page.Status -eq 200) { $fl = Get-AllohaFileList $page.Text }
    if ($fl -and $fl.ContainsKey('all')) {
      $trs = @()
      foreach ($k in @($fl['all'].Keys)) {
        $t = $fl['all'][$k]
        if ($k -notmatch '^t\d+$' -or $t -isnot [System.Collections.IDictionary]) { continue }   # (films: all = directors / theatrical)
        $seasons = [ordered]@{}
        if ($t['file'] -is [System.Collections.IDictionary]) {
          foreach ($s in @($t['file'].Keys | Sort-Object { ConvertTo-KodikInt $_ })) {
            $e = $t['file'][$s]
            if ($e -is [System.Collections.IDictionary]) { $seasons[[string]$s] = @($e.Keys | Where-Object { [string]$_ -match '^\d+$' } | Sort-Object { [int]$_ } | ForEach-Object { [string]$_ }) }
          }
        }
        $trs += [pscustomobject]@{ Id = $k.Substring(1); Name = [string]$t['name']; Seasons = $seasons }
      }
      $cat = [pscustomobject]@{ Type = [string]$fl['type']; Translations = $trs }
    }
  } catch { return $null }
  $script:AllohaCatalogs[$kp] = $cat
  return $cat
}

# OPTIONAL: keeps the player's telemetry WebSocket alive like the web player does (connect -> "playback_start" -> "playing" every 30 s,
# server answers {"type":"config_update","edge_hash":"<32 hex>","ttl":120}). Not needed in the tests (1x reads worked without it),
# kept for the case the CDN starts enforcing it. Runs in a background runspace; State.EdgeHash holds the newest token
# (the web player sends it as header "Accepts-Controls: <edge_hash>" on every HLS request).
# Usage: $k = Start-AllohaSessionKeeper -WsUrl $r.WsUrl -Origin $r.Origin -Quality $r.Quality -AudioId $r.AudioTracks[0].AudioId ; ... ; Stop-AllohaSessionKeeper $k
function Start-AllohaSessionKeeper {
  param([Parameter(Mandatory = $true)][string]$WsUrl, [Parameter(Mandatory = $true)][string]$Origin, [string]$Quality = '720', [string]$AudioId = '1', [int]$StartTime = 0)
  $state = [hashtable]::Synchronized(@{ EdgeHash = $null; Stop = $false; Error = $null; Received = 0; Sent = 0; Connected = $false })
  $ps = [PowerShell]::Create()
  [void]$ps.AddScript({
      param($WsUrl, $Origin, $Quality, $AudioId, $StartTime, $state)
      Add-Type -AssemblyName System.Web.Extensions
      $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
      $epoch = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
      $t0 = [DateTime]::UtcNow
      $attempt = 0
      while (-not $state.Stop -and $attempt -lt 10) {
        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        try {
          $ws.Options.SetRequestHeader('Origin', $Origin)
          $ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(25)
          $u = $WsUrl + '&t=' + [long](([DateTime]::UtcNow - $epoch).TotalMilliseconds)
          if (-not $ws.ConnectAsync([Uri]$u, [Threading.CancellationToken]::None).Wait(15000)) { throw 'connect timeout' }
          $state.Connected = $true; $attempt = 0
          $send = {
            param($type)
            $msg = @{ type = $type; current_time = [int]($StartTime + ([DateTime]::UtcNow - $t0).TotalSeconds); resolution = $Quality; track_id = $AudioId; speed = 1; subtitle = -1; ts = [long](([DateTime]::UtcNow - $epoch).TotalMilliseconds) }
            $bytes = [Text.Encoding]::UTF8.GetBytes($ser.Serialize($msg))
            [void]$ws.SendAsync((New-Object ArraySegment[byte] (, $bytes)), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait(10000)
            $state.Sent++
          }
          & $send 'playback_start'
          $lastPlay = [DateTime]::UtcNow
          $buf = New-Object byte[] 65536
          $sb = New-Object System.Text.StringBuilder
          $rx = $null
          while (-not $state.Stop -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            if ($null -eq $rx) { $rx = $ws.ReceiveAsync((New-Object ArraySegment[byte] (, $buf)), [Threading.CancellationToken]::None) }
            if ($rx.Wait(1000)) {
              $res = $rx.Result; $rx = $null
              if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { break }
              [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $res.Count))
              if ($res.EndOfMessage) {
                $txt = $sb.ToString(); [void]$sb.Clear(); $state.Received++
                try { $j = $ser.DeserializeObject($txt); if ($j['type'] -eq 'config_update' -and $j['edge_hash']) { $state.EdgeHash = [string]$j['edge_hash'] } } catch {}
              }
            }
            if (([DateTime]::UtcNow - $lastPlay).TotalSeconds -ge 30) { & $send 'playing'; $lastPlay = [DateTime]::UtcNow }
          }
        } catch { $state.Error = $_.Exception.Message }
        finally { $state.Connected = $false; try { $ws.Dispose() } catch {} }
        if (-not $state.Stop) { $attempt++; Start-Sleep -Seconds ([Math]::Min(15, [Math]::Pow(2, $attempt))) }
      }
    }).AddArgument($WsUrl).AddArgument($Origin).AddArgument($Quality).AddArgument($AudioId).AddArgument($StartTime).AddArgument($state)
  $handle = $ps.BeginInvoke()
  return [pscustomobject]@{ PowerShell = $ps; Handle = $handle; State = $state }
}

function Stop-AllohaSessionKeeper($keeper) {
  if ($null -eq $keeper) { return }
  $keeper.State.Stop = $true
  try { [void]$keeper.Handle.AsyncWaitHandle.WaitOne(5000) } catch {}
  try { $keeper.PowerShell.Stop(); $keeper.PowerShell.Dispose() } catch {}
}

# ==================================================================================================
# WPARTY rooms (wparty.net)
# ==================================================================================================
# wparty.ps1 - WPARTY (wparty.net) room reader for Windows PowerShell 5.1 (.NET Framework 4.5+, Windows 8/10/11).
# Dot-source http_helper.ps1 FIRST (Invoke-Web, $script:WebUA, $script:WebCookies), then this file.
# The file is pure ASCII on purpose (Cyrillic literals are written as \uXXXX and unescaped at load time).
#
# READ-ONLY CONTRACT: the socket reader only ever sends two things to the server:
#   "40/<roomId>,"  (socket.io namespace connect, i.e. "join the room as a silent viewer")
#   "3"             (engine.io pong, answer to the server's "2" ping)
# It never emits CMD:* events, chat, names, or anything else, so it cannot change anyone's room.
#
# Public functions:
#   ConvertFrom-WpartyUrl      parse https://wparty.net/s/<id>, /r/<vanity>, bare ids, ?kp=
#   Test-WpartyUrl             $true when a string looks like a WPARTY room link
#   Get-WpartyRoom             connect, read REC:host (+ room state), close; returns a pscustomobject
#   Get-WpartyPlayerUrl        the iframe URL the web app builds for the room's movie source (function uS in the bundle)
#   Get-WpartyNextEpisode      next (season, episode) after the room's current one, from PlaylistData
#   Get-WpartyMovieSources     POST /api/movieCheck {id:kp} (what the source picker shows; read-only)
#   Get-WpartyMovieName        POST /api/getMovieName {id:kp}
#   Get-WpartyTranslationTitle translation id -> title for a source, from movieCheck data
#   Find-WpartyKodikTranslation map a (season, translation title) to a Kodik translation id / shikimori material
#   Get-WpartyKodikFallback    build the Kodik find-player URL (+ optional kodik-api get-player lookup) for a room
#   Get-WpartyUrlPlayHint      how the tool should fetch a plain-URL room video (yt-dlp vs ffmpeg + headers)

$script:WpartyBase = 'https://wparty.net'

# ---------------------------------------------------------------- small helpers
function ConvertFrom-WpJson([string]$json) {
  # Like ConvertFrom-JsonDict but never unrolls a top-level array (callers get object[] even for 0/1 items).
  $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
  $ser.MaxJsonLength = [int]::MaxValue
  $ser.RecursionLimit = 256
  $o = $ser.DeserializeObject($json)
  return , $o
}

function Get-WpVal($dict, [string]$key) {
  if ($null -eq $dict) { return $null }
  if ($dict -is [System.Collections.IDictionary]) {
    # Dictionary[string,object] (JavaScriptSerializer) and Hashtable have ContainsKey; OrderedDictionary only Contains.
    if ($null -ne $dict.PSObject.Methods['ContainsKey']) { if ($dict.ContainsKey($key)) { return $dict[$key] } }
    elseif ($dict.Contains($key)) { return $dict[$key] }
    return $null
  }
  return $null
}

function Get-WpStr($v) {
  if ($null -eq $v) { return $null }
  $s = [string]$v
  if ($s -eq '') { return $null }
  return $s
}

function Get-WpInnerMessage($err) {
  $ex = $err
  if ($err -is [System.Management.Automation.ErrorRecord]) { $ex = $err.Exception }
  while ($null -ne $ex.InnerException) { $ex = $ex.InnerException }
  return $ex.Message
}

function Wait-WpTask($task, [int]$ms) {
  # Task.Wait with timeout; returns $true when finished, $false on timeout, throws the innermost error on fault.
  if ($ms -lt 1) { $ms = 1 }
  try { return $task.Wait($ms) }
  catch { throw (Get-WpInnerMessage $_) }
}

function Send-WpText($ws, [string]$text) {
  $b = [System.Text.Encoding]::UTF8.GetBytes($text)
  $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList (, $b)
  $t = $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None)
  if (-not (Wait-WpTask $t 5000)) { throw 'WPARTY: websocket send timed out' }
}

# Parse one socket.io v4 packet (the text after the engine.io "4" message prefix).
# Format: <type>[<attachments>-][/<nsp>,][<ackId>][<json>]
function ConvertFrom-WpSioPacket([string]$p) {
  $type = [int][string]$p[0]
  $i = 1
  if ($type -eq 5 -or $type -eq 6) {
    $dash = $p.IndexOf('-', $i)
    if ($dash -gt 0) { $i = $dash + 1 }
  }
  $nsp = '/'
  if ($i -lt $p.Length -and $p[$i] -eq [char]'/') {
    $comma = $p.IndexOf(',', $i)
    if ($comma -lt 0) { $nsp = $p.Substring($i); $i = $p.Length }
    else { $nsp = $p.Substring($i, $comma - $i); $i = $comma + 1 }
  }
  $ackStart = $i
  while ($i -lt $p.Length -and [char]::IsDigit($p[$i])) { $i++ }
  $ack = $null
  if ($i -gt $ackStart) { $ack = [long]$p.Substring($ackStart, $i - $ackStart) }
  $data = $null
  if ($i -lt $p.Length) {
    try { $data = ConvertFrom-WpJson $p.Substring($i) } catch { $data = $null }
  }
  return [pscustomobject]@{ Type = $type; Nsp = $nsp; Ack = $ack; Data = $data }
}

# ---------------------------------------------------------------- URL parsing
# Accepts: https://wparty.net/s/<roomId>[?kp=N], https://wparty.net/r/<vanity>, wparty.net/s/<id>,
#          "/<roomId>", "<roomId>", "s/<id>", "r/<vanity>". Returns $null when it is not a WPARTY room reference.
function ConvertFrom-WpartyUrl([string]$Url) {
  if (-not $Url) { return $null }
  $u = $Url.Trim().Trim('"', "'", '<', '>')
  $base = $script:WpartyBase
  $path = $null; $query = ''
  $m = [regex]::Match($u, '^(?i)(?:https?://)?((?:www\.)?wparty\.[a-z]{2,10})(/[^?#]*)?(\?[^#]*)?')
  $isUrl = $false
  if ($m.Success) {
    $isUrl = $true
    # www.wparty.net has no DNS record (NXDOMAIN), so always talk to the bare domain.
    $base = 'https://' + ($m.Groups[1].Value.ToLowerInvariant() -replace '^www\.', '')
    $path = $m.Groups[2].Value
    $query = $m.Groups[3].Value
  }
  elseif ($u -match '^(?i)[a-z][a-z0-9+.-]*://') {
    return $null   # some other site
  }
  else {
    $path = $u
    $qi = $u.IndexOf('?')
    if ($qi -ge 0) { $path = $u.Substring(0, $qi); $query = $u.Substring($qi) }
    $hi = $path.IndexOf('#'); if ($hi -ge 0) { $path = $path.Substring(0, $hi) }
    if (-not $path.StartsWith('/')) { $path = '/' + $path }
  }
  $roomId = $null; $vanity = $null
  $ms = [regex]::Match($path, '^/s/([A-Za-z0-9_-]+)/*$')
  $mr = [regex]::Match($path, '^/r/([A-Za-z0-9_-]+)/*$')
  if ($ms.Success) { $roomId = $ms.Groups[1].Value }
  elseif ($mr.Success) { $vanity = $mr.Groups[1].Value }
  elseif (-not $isUrl) {
    $mb = [regex]::Match($path, '^/([A-Za-z0-9_-]{3,64})/*$')
    if ($mb.Success) { $roomId = $mb.Groups[1].Value }
  }
  if (-not $roomId -and -not $vanity) { return $null }
  $kp = $null
  $mk = [regex]::Match($query, '[?&]kp=(\d+)')
  if ($mk.Success) { $kp = $mk.Groups[1].Value }
  return [pscustomobject]@{ Base = $base; RoomId = $roomId; Vanity = $vanity; QueryKpId = $kp }
}

function Test-WpartyUrl([string]$Url) {
  if (-not $Url) { return $false }
  if ($Url.Trim() -notmatch '^(?i)(https?://)?(www\.)?wparty\.[a-z]{2,10}/[sr]/') { return $false }
  return ($null -ne (ConvertFrom-WpartyUrl $Url))
}

# /api/resolveRoom/<vanity> -> {"roomId":"/cllr047eg1","vanity":"test"} ; empty body when the vanity does not exist.
function Resolve-WpartyVanity([string]$Base, [string]$Vanity, [int]$TimeoutSec = 15) {
  $r = Invoke-Web -Url ($Base + '/api/resolveRoom/' + [Uri]::EscapeDataString($Vanity)) -Headers @{ 'Referer' = $Base + '/r/' + $Vanity } -TimeoutSec $TimeoutSec
  if ($r.Status -ne 200) { throw ('WPARTY: could not resolve room link /r/' + $Vanity + ' (HTTP ' + $r.Status + ')') }
  $id = $null
  if ($r.Text -and $r.Text.Trim().StartsWith('{')) { $id = Get-WpStr (Get-WpVal (ConvertFrom-WpJson $r.Text) 'roomId') }
  if (-not $id) { throw ('WPARTY: room link /r/' + $Vanity + ' does not exist') }
  return $id.TrimStart('/')
}

# /api/resolveShard/<roomId> -> "4" (plain text). The web client uses Number(text)||"" as the shard query value.
function Get-WpartyShard([string]$Base, [string]$RoomId, [int]$TimeoutSec = 15) {
  $shard = ''
  try {
    $r = Invoke-Web -Url ($Base + '/api/resolveShard/' + $RoomId) -Headers @{ 'Referer' = $Base + '/s/' + $RoomId } -TimeoutSec $TimeoutSec
    $t = ('' + $r.Text).Trim().Trim('"')
    if ($r.Status -eq 200 -and $t -match '^\d{1,4}$' -and [int]$t -ne 0) { $shard = $t }
  } catch {}
  return $shard
}

# ---------------------------------------------------------------- socket read
# Connects to the room over socket.io v4 (websocket transport only), collects the initial state burst and closes.
# Returns a hashtable of the raw event payloads. Throws with a readable message on connect errors.
function Read-WpartySocket {
  param(
    [Parameter(Mandatory = $true)][string]$Base,
    [Parameter(Mandatory = $true)][string]$RoomId,
    [string]$Shard = '',
    [string]$Password = '',
    [int]$TimeoutSec = 10,
    [int]$GraceMs = 1500,
    [int]$BufferSize = 65536
  )
  $nsp = '/' + $RoomId
  $wsBase = $Base -replace '^(?i)http', 'ws'
  $q = 'clientId=' + [guid]::NewGuid().ToString() + '&shard=' + [Uri]::EscapeDataString($Shard)
  if ($Password) { $q += '&password=' + [Uri]::EscapeDataString($Password) }
  $q += '&EIO=4&transport=websocket'
  $uri = New-Object System.Uri ($wsBase + '/socket.io/?' + $q)

  $st = @{
    Host = $null; RoomState = $null; Roster = $null; TsMap = $null; Chat = $null; Playlist = $null; NameMap = $null
    Error = $null; Connected = $false; Opened = $false; Messages = 0; Frames = 0; MaxFrames = 0; Log = New-Object System.Collections.ArrayList
    Uri = $null; HeaderNotes = @(); Timeline = New-Object System.Collections.ArrayList   # Timeline: 'step@ms' for diagnosing slow reads
  }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  try { $ws.Options.SetRequestHeader('Origin', $Base) } catch { $st.HeaderNotes += ('Origin: ' + $_.Exception.Message) }
  try { $ws.Options.SetRequestHeader('User-Agent', $script:WebUA) } catch { $st.HeaderNotes += ('User-Agent: ' + (Get-WpInnerMessage $_)) }   # optional; the server does not need it
  try { $ws.Options.Cookies = $script:WebCookies } catch {}
  $st.Uri = $uri.AbsoluteUri -replace 'password=[^&]*', 'password=***'
  $none = [System.Threading.CancellationToken]::None
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $deadline = [long]($TimeoutSec * 1000)
  $pending = $null
  try {
    $ct = $ws.ConnectAsync($uri, $none)
    $ok = $false
    try { $ok = Wait-WpTask $ct ([int]$deadline) }
    catch { throw ('WPARTY: websocket connect failed: ' + $_.Exception.Message) }
    if (-not $ok) { throw ('WPARTY: websocket connect timed out after ' + $TimeoutSec + ' s') }
    [void]$st.Timeline.Add('connected@' + $sw.ElapsedMilliseconds)

    $buf = New-Object byte[] $BufferSize
    $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList (, $buf)
    $acc = New-Object System.IO.MemoryStream
    $frames = 0
    $hostAt = -1
    $done = $false
    while (-not $done) {
      $elapsed = $sw.ElapsedMilliseconds
      if ($elapsed -ge $deadline) { break }
      if ($hostAt -ge 0 -and ($elapsed - $hostAt) -ge $GraceMs) { break }
      if ($null -eq $pending) { $pending = $ws.ReceiveAsync($seg, $none) }
      $slice = [int][Math]::Min(250, $deadline - $elapsed)
      $fin = $false
      try { $fin = Wait-WpTask $pending $slice }
      catch {
        $pending = $null
        if ($st.Host) { break }
        throw ('WPARTY: websocket receive failed: ' + $_.Exception.Message)
      }
      if (-not $fin) { continue }
      $r = $pending.Result
      $pending = $null
      if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { [void]$st.Log.Add('server closed websocket'); break }
      $acc.Write($buf, 0, $r.Count)
      $frames++
      if (-not $r.EndOfMessage) { continue }
      $bytes = $acc.ToArray()
      $acc.SetLength(0)
      $st.Frames += $frames
      if ($frames -gt $st.MaxFrames) { $st.MaxFrames = $frames }
      $frames = 0
      if ($r.MessageType -ne [System.Net.WebSockets.WebSocketMessageType]::Text) { continue }   # binary attachments: not used by this app
      $msg = [System.Text.Encoding]::UTF8.GetString($bytes)
      $st.Messages++
      if ($msg.Length -eq 0) { continue }
      $kind = $msg.Substring(0, 1)
      if ($kind -eq '0') {
        # engine.io open -> join the room namespace (the ONLY request we make)
        $st.Opened = $true
        [void]$st.Timeline.Add('open@' + $sw.ElapsedMilliseconds)
        Send-WpText $ws ('40' + $nsp + ',')
      }
      elseif ($kind -eq '2') {
        Send-WpText $ws '3'   # pong
      }
      elseif ($kind -eq '1') {
        [void]$st.Log.Add('engine.io close'); break
      }
      elseif ($kind -eq '4' -and $msg.Length -gt 1) {
        $pk = ConvertFrom-WpSioPacket $msg.Substring(1)
        if ($pk.Nsp -ne $nsp) { continue }
        if ($pk.Type -eq 0) { $st.Connected = $true; [void]$st.Timeline.Add('joined@' + $sw.ElapsedMilliseconds) }
        elseif ($pk.Type -eq 4) {
          $st.Error = Get-WpStr (Get-WpVal $pk.Data 'message')
          if (-not $st.Error) { $st.Error = 'connect_error' }
          $done = $true
        }
        elseif ($pk.Type -eq 1) { $st.Error = 'io server disconnect'; $done = $true }
        elseif ($pk.Type -eq 2 -and $pk.Data -is [object[]] -and $pk.Data.Count -ge 1) {
          $ev = [string]$pk.Data[0]
          $arg = $null
          if ($pk.Data.Count -ge 2) { $arg = $pk.Data[1] }
          [void]$st.Log.Add($ev)
          if ($ev -eq 'REC:host') { $st.Host = $arg; if ($hostAt -lt 0) { $hostAt = $sw.ElapsedMilliseconds; [void]$st.Timeline.Add('host@' + $hostAt) } }
          elseif ($ev -eq 'REC:getRoomState') { $st.RoomState = $arg; [void]$st.Timeline.Add('roomstate@' + $sw.ElapsedMilliseconds) }
          elseif ($ev -eq 'roster') { $st.Roster = $arg }
          elseif ($ev -eq 'REC:tsMap') { $st.TsMap = $arg }
          elseif ($ev -eq 'chatinit') { $st.Chat = $arg }
          elseif ($ev -eq 'playlist') { $st.Playlist = $arg }
          elseif ($ev -eq 'REC:nameMap') { $st.NameMap = $arg }
          elseif ($ev -eq 'REC:moviePlaylistId' -and $st.Host -is [System.Collections.IDictionary]) { $st.Host['moviePlaylistId'] = $arg }
          elseif ($ev -eq 'REC:pause' -and $st.Host -is [System.Collections.IDictionary]) { $st.Host['paused'] = $true }
          elseif ($ev -eq 'REC:play' -and $st.Host -is [System.Collections.IDictionary]) { $st.Host['paused'] = $false }
          elseif ($ev -eq 'REC:seek' -and $st.Host -is [System.Collections.IDictionary]) { $st.Host['videoTS'] = $arg }
          if ($st.Host -and $st.RoomState) { $done = $true }
        }
      }
    }
  }
  finally {
    # Polite close, but bounded: a silent/broken server must not add seconds on top of TimeoutSec
    # (was 2 s + 2 s; with a server that never answers the close frame every timeout took TimeoutSec + 2 s).
    try {
      if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        $c = $ws.CloseOutputAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, '', $none)
        [void](Wait-WpTask $c 1000)
        if ($null -ne $pending) { try { [void]$pending.Wait(500) } catch {} }
      }
    } catch {}
    try { $ws.Dispose() } catch {}   # aborts the TCP connection (and a still-pending ConnectAsync/ReceiveAsync)
  }
  [void]$st.Timeline.Add('closed@' + $sw.ElapsedMilliseconds)
  $st.ElapsedMs = $sw.ElapsedMilliseconds
  return $st
}

# ---------------------------------------------------------------- room model
# Classifier copied from the site bundle (function sS): youtube | vk | rutube | movie | video | error
function Get-WpartyUrlType([string]$Video) {
  if (-not $Video) { return '' }
  if ($Video.StartsWith('https://www.youtube.com/') -or $Video.StartsWith('https://m.youtube.com/') -or $Video.StartsWith('https://youtu.be/')) { return 'youtube' }
  if ($Video.StartsWith('https://vk.com/') -or $Video.StartsWith('https://m.vk.com/') -or $Video.StartsWith('https://vkvideo.ru/') -or $Video.StartsWith('https://m.vkvideo.ru/')) { return 'vk' }
  if ($Video.StartsWith('https://rutube.ru/video')) { return 'rutube' }
  if ($Video.StartsWith('moviecdn://')) { return 'movie' }
  $p = $Video.Split('?')[0].Split('#')[0].ToLowerInvariant()
  foreach ($ext in @('.mp4', '.webm', '.ogv', '.m4v', '.m3u8')) { if ($p.Contains($ext)) { return 'video' } }
  return 'error'
}

function ConvertTo-WpSeasonEpisode($playlistId) {
  # alloha / lumex / videocdn / PlayerJS sources: "1_2" (season_episode). kodik: {season:1, episode:2, ...}.
  $res = @{ Season = $null; Episode = $null }
  if ($null -eq $playlistId) { return $res }
  if ($playlistId -is [System.Collections.IDictionary]) {
    $s = Get-WpStr (Get-WpVal $playlistId 'season'); $e = Get-WpStr (Get-WpVal $playlistId 'episode')
    if ($s -match '^-?\d+$') { $res.Season = [int]$s }
    if ($e -match '^-?\d+$') { $res.Episode = [int]$e }
    return $res
  }
  $t = [string]$playlistId
  $m = [regex]::Match($t, '(\d+)\D+(\d+)')
  if ($m.Success) { $res.Season = [int]$m.Groups[1].Value; $res.Episode = [int]$m.Groups[2].Value }
  elseif ($t -match '^\d+$') { $res.Episode = [int]$t }
  return $res
}

function ConvertTo-WpPlaylistData($pd) {
  # season -> string[] of episode numbers, seasons in numeric order. $null when the room has no episode list.
  if (-not ($pd -is [System.Collections.IDictionary]) -or $pd.Count -eq 0) { return $null }
  $out = [ordered]@{}
  $keys = @($pd.Keys | Sort-Object { $n = 0; if ([int]::TryParse([string]$_, [ref]$n)) { $n } else { [int]::MaxValue } }, { [string]$_ })
  foreach ($k in $keys) {
    $eps = @()
    $v = $pd[$k]
    if ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) { foreach ($x in $v) { $eps += [string]$x } }
    elseif ($null -ne $v) { $eps += [string]$v }
    $out[[string]$k] = [string[]]$eps
  }
  return $out
}

# Get-WpartyRoom: read what a WPARTY room is showing right now.
#   $url      : https://wparty.net/s/<id> | https://wparty.net/r/<vanity> | <id> | /<id>
#   -Password : room password (sent in the connect query as password=..., exactly like the web client)
# Returns [pscustomobject] with:
#   RoomId, Vanity, RoomUrl, Shard, Video, Kind ('movie'|'url'|'unsupported'|'empty'), UrlType (site classifier),
#   KpId, Name, Source, SourceUrl, Translation, PlaylistId, Season, Episode, EpisodeGuessed, PlaylistData,
#   ShikimoriId, VideoTS, Paused, LeaderTS, SubtitleUrl, PlayerUrl, RoomTitle, HasPassword, Viewers, Queue, QueryKpId, Raw
# Throws: 'WPARTY: not a WPARTY room link', 'WPARTY: room not found', 'WPARTY: room is password-protected...',
#         'WPARTY: wrong password', 'WPARTY: room is full', 'WPARTY: disconnected by server', 'WPARTY: no room state...',
#         'WPARTY: could not look up the server of room ...' (resolveShard failed twice; transient, retry later),
#         and websocket connect/receive errors (message prefixed with 'WPARTY:').
#   -TimeoutSec : budget for the whole call (HTTP lookups + socket); worst case about TimeoutSec + 3 s (the socket always gets >= 3 s, closing <= 1.5 s).
function Get-WpartyRoom {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [string]$Password = '',
    [int]$TimeoutSec = 10
  )
  # While a flow asks its questions, a Back gets the room as read before (for up to 120 s: it is live data).
  if ($script:Nav -and -not $script:Nav.Sealed -and -not $script:WpRoomMemoIn -and (Get-Command Use-NavMemo -CommandType Function -ErrorAction SilentlyContinue)) {
    $script:WpRoomMemoIn = $true
    try { return (Use-NavMemo ('wparty-room|' + $Url + '|' + $Password) { Get-WpartyRoom -Url $Url -Password $Password -TimeoutSec $TimeoutSec } -Seconds 120) }
    finally { $script:WpRoomMemoIn = $false }
  }
  $ref = ConvertFrom-WpartyUrl $Url
  if ($null -eq $ref) { throw ('WPARTY: not a WPARTY room link: ' + $Url) }
  # -TimeoutSec is the budget for the WHOLE call (vanity lookup + shard lookup + socket read), not only the socket:
  # the HTTP lookups used a fixed 15 s each, so a slow site could make the call take TimeoutSec + 30 s.
  $total = [Diagnostics.Stopwatch]::StartNew()
  $budgetMs = [long]$TimeoutSec * 1000
  $base = $ref.Base
  $roomId = $ref.RoomId
  if (-not $roomId) { $roomId = Resolve-WpartyVanity $base $ref.Vanity ([int][Math]::Max(2, [Math]::Min(15, [Math]::Ceiling(($budgetMs - $total.ElapsedMilliseconds) / 2000.0)))) }
  $shard = Get-WpartyShard $base $roomId ([int][Math]::Max(2, [Math]::Min(15, [Math]::Ceiling(($budgetMs - $total.ElapsedMilliseconds) / 2000.0))))
  if (-not $shard -and ($budgetMs - $total.ElapsedMilliseconds) -gt 4000) {
    # The shard is REQUIRED: with shard='' (or a wrong one) the server answers "Invalid namespace" even for a live room
    # (tested: spfrn3nlho7 joins only with shard=4; '', 1, 2, 3, 5 all give Invalid namespace). Retry the lookup once.
    Start-Sleep -Milliseconds 300
    $shard = Get-WpartyShard $base $roomId ([int][Math]::Max(2, [Math]::Min(15, [Math]::Ceiling(($budgetMs - $total.ElapsedMilliseconds) / 2000.0))))
  }
  $sockSec = [int][Math]::Max(3, [Math]::Ceiling(($budgetMs - $total.ElapsedMilliseconds) / 1000.0))
  $st = Read-WpartySocket -Base $base -RoomId $roomId -Shard $shard -Password $Password -TimeoutSec $sockSec
  if ($st.Error) {
    if ($st.Error -eq 'Invalid namespace') {
      if (-not $shard) { throw ('WPARTY: could not look up the server of room ' + $roomId + ' (/api/resolveShard failed or timed out); the site may be slow or down, try again') }
      throw ('WPARTY: room not found: ' + $roomId)
    }
    if ($st.Error -eq 'not authorized') {
      if ($Password) { throw ('WPARTY: wrong password for room ' + $roomId) }
      throw ('WPARTY: room ' + $roomId + ' is password-protected; pass -Password')
    }
    if ($st.Error -eq 'room full') { throw ('WPARTY: room is full: ' + $roomId) }
    if ($st.Error -eq 'io server disconnect') { throw ('WPARTY: disconnected by server (kicked/banned?): ' + $roomId) }
    throw ('WPARTY: connect error "' + $st.Error + '" for room ' + $roomId)
  }
  if (-not ($st.Host -is [System.Collections.IDictionary])) {
    throw ('WPARTY: no room state received within ' + $TimeoutSec + ' s (connected=' + $st.Connected + ', messages=' + $st.Messages + ')')
  }
  return (ConvertTo-WpartyRoom -State $st -Base $base -RoomId $roomId -Shard $shard -Ref $ref)
}

# Builds the room object from the raw socket state (split out so it can be tested offline with synthetic payloads).
#   $State: hashtable from Read-WpartySocket (Host = REC:host payload, RoomState, Roster, TsMap, Playlist, ElapsedMs)
function ConvertTo-WpartyRoom($State, [string]$Base = $script:WpartyBase, [string]$RoomId, [string]$Shard = '', $Ref = $null) {
  $st = $State; $base = $Base; $roomId = $RoomId; $shard = $Shard
  $ref = $Ref
  if ($null -eq $ref) { $ref = [pscustomobject]@{ Vanity = $null; QueryKpId = $null } }
  $h = $st.Host
  $video = Get-WpStr (Get-WpVal $h 'video')
  if (-not $video) { $video = '' }
  $kind = 'unsupported'
  if ($video -eq '') { $kind = 'empty' }
  elseif ($video.StartsWith('moviecdn://')) { $kind = 'movie' }
  elseif ($video -match '^(?i)(screenshare|fileshare|vbrowser)://') { $kind = 'unsupported' }
  elseif ($video -match '^(?i)https?://') { $kind = 'url' }

  $kp = $null
  if ($kind -eq 'movie') { $kp = $video.Substring(11) }
  $playlistId = Get-WpVal $h 'moviePlaylistId'
  if ($playlistId -is [string] -and $playlistId -eq '') { $playlistId = $null }
  $pdata = ConvertTo-WpPlaylistData (Get-WpVal $h 'moviePlaylistData')
  $se = ConvertTo-WpSeasonEpisode $playlistId
  $guessed = $false
  if ($null -eq $se.Episode -and $null -ne $pdata) {
    # The web client (alloha) jumps to the first season/first episode when no episode is selected yet.
    foreach ($k in $pdata.Keys) { $eps = $pdata[$k]; if ($eps.Count -gt 0) { $se.Season = [int]$k; $se.Episode = [int]$eps[0]; $guessed = $true; break } }
  }
  $sub = Get-WpStr (Get-WpVal $h 'subtitle')
  $subUrl = $null
  if ($sub) { $subUrl = $base + '/api/subtitle/' + $sub }

  $leader = $null
  if ($st.TsMap -is [System.Collections.IDictionary] -and $st.TsMap.Count -gt 0) {
    foreach ($v in $st.TsMap.Values) { try { $d = [double]$v; if ($null -eq $leader -or $d -gt $leader) { $leader = $d } } catch {} }
  }
  $videoTS = $null
  try { $videoTS = [double](Get-WpVal $h 'videoTS') } catch {}
  $pausedRaw = Get-WpVal $h 'paused'
  $paused = $false
  if ($pausedRaw -is [bool]) { $paused = $pausedRaw } elseif ($pausedRaw) { $paused = $true }

  $rs = $st.RoomState
  $vanity = Get-WpStr (Get-WpVal $rs 'vanity')
  if (-not $vanity) { $vanity = $ref.Vanity }
  $roomUrl = $base + '/s/' + $roomId
  if ($vanity) { $roomUrl = $base + '/r/' + $vanity }
  $viewers = $null
  if ($st.Roster -is [object[]]) { $viewers = [Math]::Max(0, $st.Roster.Count - 1) }   # minus ourselves
  $queue = @()
  if ($st.Playlist -is [object[]]) {
    foreach ($it in $st.Playlist) { $queue += [pscustomobject]@{ Url = Get-WpStr (Get-WpVal $it 'url'); Name = Get-WpStr (Get-WpVal $it 'name') } }
  }

  $room = [pscustomobject]@{
    RoomId         = $roomId
    Vanity         = $vanity
    RoomUrl        = $roomUrl
    Shard          = $shard
    Video          = $video
    Kind           = $kind
    UrlType        = (Get-WpartyUrlType $video)
    KpId           = $kp
    Name           = Get-WpStr (Get-WpVal $h 'movieName')
    Source         = Get-WpStr (Get-WpVal $h 'movieSource')
    SourceUrl      = Get-WpStr (Get-WpVal $h 'movieSourceURL')
    Translation    = Get-WpStr (Get-WpVal $h 'movieTranslation')
    PlaylistId     = $playlistId
    Season         = $se.Season
    Episode        = $se.Episode
    EpisodeGuessed = $guessed
    PlaylistData   = $pdata
    ShikimoriId    = Get-WpStr (Get-WpVal $h 'shikimoriID')
    VideoTS        = $videoTS
    Paused         = $paused
    LeaderTS       = $leader
    SubtitleUrl    = $subUrl
    PlayerUrl      = $null
    RoomTitle      = Get-WpStr (Get-WpVal $rs 'roomTitle')
    HasPassword    = [bool](Get-WpStr (Get-WpVal $rs 'password'))
    Viewers        = $viewers
    Queue          = $queue
    QueryKpId      = $ref.QueryKpId
    ReadMs         = $st.ElapsedMs
    Raw            = $h
  }
  if ($kind -eq 'movie') { $room.PlayerUrl = Get-WpartyPlayerUrl $room }
  return $room
}

# The iframe src the web app builds for a movie room (port of function uS / fe in the bundle).
# vibix is special: the live client does NOT use this URL; it injects https://graphicslab.io/sdk/v2/rendex-sdk.min.js with
#   <ins data-publisher-id="{SourceUrl}" data-type="kp" data-id="{kp}" data-voiceover="{translation}" data-voiceover-only="true">
function Get-WpartyPlayerUrl($Room, [int]$Season = 0, [int]$Episode = 0) {
  $e = $Room.SourceUrl
  if (-not $e -or -not $Room.KpId) { return $null }
  if ($e.StartsWith('//')) { $e = 'https:' + $e }
  $kp = $Room.KpId
  $r = $Room.Translation
  $s = $Room.Season; $ep = $Room.Episode
  if ($Season -gt 0) { $s = $Season }
  if ($Episode -gt 0) { $ep = $Episode }
  $hasEp = ($null -ne $s -and $null -ne $ep)
  switch ($Room.Source) {
    { $_ -eq 'videocdn' -or $_ -eq 'lumex' } { return ($e + '?kp_id=' + $kp + '&start_time=0') }
    'turbo' { return ($e + '/kinopoisk/' + $kp + '?api=1') }
    'vibix' { return ($e + '/embed-kp/' + $kp + '?voiceover=' + $r + '!') }
    'cdnmovies' { return ($e + '/kinopoisk/' + $kp + '/iframe?translation_id=' + $r) }
    'kodik' {
      $id = 'kinopoiskID=' + $kp
      if ($Room.ShikimoriId) { $id = 'shikimoriID=' + $Room.ShikimoriId }
      $u = $e + '/find-player?' + $id + '&translations=false&onlyTranslationID=[' + $r + ']'
      if ($hasEp) { $u += '&season=' + $s + '&episode=' + $ep }
      return $u
    }
    'alloha' {
      if ($hasEp) { return ($e + '&kp=' + $kp + '&hidden=season,episode,translation&translation=' + $r + '&season=' + $s + '&episode=' + $ep) }
      return ($e + '&kp=' + $kp + '&hidden=translation&translation=' + $r)
    }
    default { return ($e + '?kp_id=' + $kp + '&start_time=0&translation=' + $r) }
  }
}

# Next episode after the room's current one (walks into the next season). Returns $null at the end / for films.
function Get-WpartyNextEpisode($Room) {
  $pd = $Room.PlaylistData
  if ($null -eq $pd -or $null -eq $Room.Episode) { return $null }
  $seasons = @($pd.Keys)
  $cur = [string]$Room.Season
  for ($i = 0; $i -lt $seasons.Count; $i++) {
    if ($seasons[$i] -ne $cur) { continue }
    $eps = @($pd[$seasons[$i]])
    $j = [Array]::IndexOf([string[]]$eps, [string]$Room.Episode)
    if ($j -ge 0 -and $j + 1 -lt $eps.Count) { return [pscustomobject]@{ Season = [int]$cur; Episode = [int]$eps[$j + 1] } }
    for ($k = $i + 1; $k -lt $seasons.Count; $k++) {
      $n = @($pd[$seasons[$k]])
      if ($n.Count -gt 0) { return [pscustomobject]@{ Season = [int]$seasons[$k]; Episode = [int]$n[0] } }
    }
    return $null
  }
  return $null
}

# ---------------------------------------------------------------- read-only REST APIs used by the source picker
# POST /api/movieCheck {"id":kp} -> [{name:"turbo",translations:[{id,title}]}, {name:"alloha",translations:[...]},
#                                    {name:"kodik",materials:[{sid,title,translations:[{id,title}]}]}, {name:"vibix",...}]
function Get-WpartyMovieSources([string]$KpId, [string]$Base = $script:WpartyBase) {
  $r = Invoke-Web -Url ($Base + '/api/movieCheck') -Method POST -Body ('{"id":' + [long]$KpId + '}') -ContentType 'application/json' -Headers @{ 'Referer' = $Base + '/'; 'Origin' = $Base } -TimeoutSec 20
  if ($r.Status -ne 200) { throw ('WPARTY: movieCheck HTTP ' + $r.Status) }
  $d = ConvertFrom-WpJson $r.Text
  if ($d -is [object[]]) { return , $d }
  return , @()
}

function Get-WpartyMovieName([string]$KpId, [string]$Base = $script:WpartyBase) {
  $r = Invoke-Web -Url ($Base + '/api/getMovieName') -Method POST -Body ('{"id":' + [long]$KpId + '}') -ContentType 'application/json' -Headers @{ 'Referer' = $Base + '/'; 'Origin' = $Base } -TimeoutSec 20
  if ($r.Status -ne 200) { return $null }
  return Get-WpStr (Get-WpVal (ConvertFrom-WpJson $r.Text) 'name')
}

# The player link WPARTY gives a room for source $Source (e.g. Alloha: "https://<host>/?token=<WPARTY's token>").
# A room only shows it once a show is put on, so this opens a NEW, empty room of its own (what opening
# wparty.net/?kp=<id> does), puts Kinopoisk id $KpId on there with that source and reads the answer.
# It never joins or changes anyone else's room. Returns the link, or $null.
function Get-WpartyOwnSourceUrl([string]$Source, [string]$KpId, [string]$Translation = '', [int]$TimeoutSec = 15) {
  if ($Source -notmatch '^[a-z0-9_-]+$' -or $KpId -notmatch '^\d+$' -or $Translation -notmatch '^[0-9A-Za-z_-]*$') { return $null }
  $base = $script:WpartyBase
  $r = Invoke-Web -Url ($base + '/api/createRoom') -Method POST -Body '{}' -ContentType 'application/json' -Headers @{ 'Referer' = $base + '/'; 'Origin' = $base } -TimeoutSec $TimeoutSec
  if ($r.Status -ne 200) { return $null }
  $roomId = Get-WpStr (Get-WpVal (ConvertFrom-WpJson $r.Text) 'name')
  if (-not $roomId -or $roomId.TrimStart('/') -notmatch '^[A-Za-z0-9]+$') { return $null }
  $roomId = $roomId.TrimStart('/')
  $shard = Get-WpartyShard $base $roomId 10
  $nsp = '/' + $roomId
  $uri = New-Object System.Uri (($base -replace '^(?i)http', 'ws') + '/socket.io/?clientId=' + [guid]::NewGuid().ToString() + '&shard=' + [Uri]::EscapeDataString($shard) + '&EIO=4&transport=websocket')
  $cmd = '42' + $nsp + ',["CMD:host",{"video":"moviecdn://' + $KpId + '","name":null,"source":"' + $Source + '","translation":"' + $Translation + '","shikimoriID":null}]'
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  try { $ws.Options.SetRequestHeader('Origin', $base) } catch {}
  $none = [System.Threading.CancellationToken]::None
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $deadline = [long]$TimeoutSec * 1000
  $found = $null
  try {
    if (-not (Wait-WpTask $ws.ConnectAsync($uri, $none) ([int]$deadline))) { return $null }
    $buf = New-Object byte[] 65536
    $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList (, $buf)
    $acc = New-Object System.IO.MemoryStream
    $pending = $null
    while (-not $found -and $sw.ElapsedMilliseconds -lt $deadline) {
      if ($null -eq $pending) { $pending = $ws.ReceiveAsync($seg, $none) }
      if (-not (Wait-WpTask $pending 250)) { continue }
      $res = $pending.Result; $pending = $null
      if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { break }
      $acc.Write($buf, 0, $res.Count)
      if (-not $res.EndOfMessage) { continue }
      $msg = [System.Text.Encoding]::UTF8.GetString($acc.ToArray()); $acc.SetLength(0)
      if ($msg.StartsWith('0')) { Send-WpText $ws ('40' + $nsp + ',') }
      elseif ($msg -eq '2') { Send-WpText $ws '3' }
      elseif ($msg.StartsWith('4') -and $msg.Length -gt 1) {
        $pk = ConvertFrom-WpSioPacket $msg.Substring(1)
        if ($pk.Nsp -ne $nsp) { continue }
        if ($pk.Type -eq 0) { Send-WpText $ws $cmd }   # joined our room: put the show on
        elseif ($pk.Type -eq 4 -or $pk.Type -eq 1) { break }
        elseif ($pk.Type -eq 2 -and $pk.Data -is [object[]] -and $pk.Data.Count -ge 2 -and [string]$pk.Data[0] -eq 'REC:host') {
          $h = $pk.Data[1]
          if ((Get-WpStr (Get-WpVal $h 'movieSource')) -eq $Source) { $found = Get-WpStr (Get-WpVal $h 'movieSourceURL') }
        }
      }
    }
  } catch { $found = $null }
  finally {
    try { if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) { [void](Wait-WpTask $ws.CloseOutputAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, '', $none) 1000) } } catch {}
    try { $ws.Dispose() } catch {}
  }
  return $found
}

function Get-WpartyTranslationTitle($Sources, [string]$Source, [string]$TranslationId, [string]$ShikimoriId = '') {
  foreach ($src in $Sources) {
    if ((Get-WpVal $src 'name') -ne $Source) { continue }
    $lists = @()
    $tr = Get-WpVal $src 'translations'
    if ($tr) { $lists += , $tr }
    $mats = Get-WpVal $src 'materials'
    if ($mats) { foreach ($m in $mats) { if (-not $ShikimoriId -or [string](Get-WpVal $m 'sid') -eq $ShikimoriId) { $lists += , (Get-WpVal $m 'translations') } } }
    foreach ($l in $lists) { foreach ($t in $l) { if ([string](Get-WpVal $t 'id') -eq $TranslationId) { return [string](Get-WpVal $t 'title') } } }
  }
  return $null
}

# ---------------------------------------------------------------- translation matching (alloha/turbo/vibix title -> kodik id)
$script:WpTitleAliases = @{
  # Cyrillic names written as \u escapes -> canonical latin key (after lower-casing and stripping non-letters)
  ([regex]::Unescape('\u0441\u0442\u0443\u0434\u0438\u0439\u043d\u0430\u044f\u0431\u0430\u043d\u0434\u0430')) = 'studioband'   # Studiynaya Banda
  ([regex]::Unescape('\u0430\u043d\u0438\u043b\u0438\u0431\u0440\u0438\u044f')) = 'anilibria'                                    # AniLibria
  ([regex]::Unescape('\u0430\u043d\u0438\u043c\u0435\u0432\u043e\u0441\u0442')) = 'animevost'                                    # AnimeVost
  ([regex]::Unescape('\u0448\u0438\u0437\u0430')) = 'shiza'                                                                        # SHIZA
  ([regex]::Unescape('\u0430\u043d\u0438\u0434\u0430\u0431')) = 'anidub'                                                          # AniDUB
  ([regex]::Unescape('\u0430\u043d\u0438\u0441\u0442\u0430\u0440')) = 'anistar'                                                   # AniStar
  ([regex]::Unescape('\u0430\u043d\u0438\u043c\u0435\u0434\u0438\u0430')) = 'animedia'                                           # Animedia
  ([regex]::Unescape('\u0441\u0432\u0434\u0443\u0431\u043b\u044c')) = 'svdubl'                                                   # SV-Dubl
}
$script:WpStopWords = @('tv', 'project', 'studio', 'studios', 'team', 'dub', 'dubbing', 'subtitles', 'subs', 'sub', 'voice', 'online')
$script:WpSubsRx = '(?i)subtitle|\u0441\u0443\u0431\u0442\u0438\u0442\u0440'   # "subtitle" / "subtitr" (Cyrillic)
$script:WpGenericDubRx = '(?i)^\s*(\u0434\u0443\u0431\u043b\u0438\u0440\u043e\u0432\u0430\u043d\u043d\u044b\u0439|\u0434\u0443\u0431\u043b\u044f\u0436|\u043f\u0440\u043e\u0444\u0435\u0441\u0441\u0438\u043e\u043d\u0430\u043b\u044c\u043d\u044b\u0439.*)\s*$'   # generic "dubbed"
$script:WpSeasonRx = '\[(?:\u0422\u0412|TV)-(\d+)\]'   # "[TV-2]" in kodik material titles (Cyrillic TV)

function ConvertTo-WpTitleKey([string]$Title) {
  $t = $Title.ToLowerInvariant()
  $tokens = @([regex]::Split($t, '[^\p{L}\p{Nd}]+') | Where-Object { $_ -ne '' })
  $full = ($tokens -join '')
  if ($script:WpTitleAliases.ContainsKey($full)) { $full = $script:WpTitleAliases[$full] }
  $coreTokens = @($tokens | Where-Object { $script:WpStopWords -notcontains $_ })
  $core = ($coreTokens -join '')
  if ($script:WpTitleAliases.ContainsKey($core)) { $core = $script:WpTitleAliases[$core] }
  if (-not $core) { $core = $full }
  return [pscustomobject]@{ Full = $full; Core = $core; Subs = [bool]($Title -match $script:WpSubsRx) }
}

# Find the Kodik translation for a (season, translation title) using movieCheck data.
# Returns @{ TranslationId; Title; ShikimoriId; MaterialTitle; Match ('exact'|'core'|'prefix'|'subs-any'|'none') } or $null.
function Find-WpartyKodikTranslation($Sources, [string]$Title, [int]$Season = 0) {
  $kodik = $null
  foreach ($s in $Sources) { if ((Get-WpVal $s 'name') -eq 'kodik') { $kodik = $s } }
  if ($null -eq $kodik) { return $null }
  $mats = @(Get-WpVal $kodik 'materials')
  $cands = @()
  foreach ($m in $mats) {
    $mt = [string](Get-WpVal $m 'title')
    $ms = [regex]::Match($mt, $script:WpSeasonRx)
    $mSeason = $null
    if ($ms.Success) { $mSeason = [int]$ms.Groups[1].Value }
    if ($Season -gt 0 -and $mats.Count -gt 1 -and $null -ne $mSeason -and $mSeason -ne $Season) { continue }
    foreach ($t in @(Get-WpVal $m 'translations')) {
      $cands += [pscustomobject]@{ Id = [string](Get-WpVal $t 'id'); Title = [string](Get-WpVal $t 'title'); Sid = [string](Get-WpVal $m 'sid'); MaterialTitle = $mt }
    }
  }
  $trs = Get-WpVal $kodik 'translations'   # kodik entries without materials (films)
  if ($trs) { foreach ($t in $trs) { $cands += [pscustomobject]@{ Id = [string](Get-WpVal $t 'id'); Title = [string](Get-WpVal $t 'title'); Sid = $null; MaterialTitle = $null } } }
  if ($cands.Count -eq 0) { return $null }
  $sid = $null
  if ($cands.Count -gt 0) { $sid = $cands[0].Sid }
  $want = ConvertTo-WpTitleKey $Title
  $best = $null; $how = 'none'
  foreach ($level in @('exact', 'core', 'prefix')) {
    foreach ($c in $cands) {
      $k = ConvertTo-WpTitleKey $c.Title
      if ($k.Subs -ne $want.Subs) { continue }
      $hit = $false
      if ($level -eq 'exact') { $hit = ($k.Full -eq $want.Full) }
      elseif ($level -eq 'core') { $hit = ($k.Core -eq $want.Core -and $k.Core.Length -ge 3) }
      else { $hit = ($k.Core.Length -ge 4 -and $want.Core.Length -ge 4 -and ($k.Core.StartsWith($want.Core) -or $want.Core.StartsWith($k.Core))) }
      if ($hit) { $best = $c; $how = $level; break }
    }
    if ($best) { break }
  }
  if (-not $best -and $want.Subs) {
    foreach ($c in $cands) { if ((ConvertTo-WpTitleKey $c.Title).Subs) { $best = $c; $how = 'subs-any'; break } }
  }
  if (-not $best) { return [pscustomobject]@{ TranslationId = $null; Title = $null; ShikimoriId = $sid; MaterialTitle = $cands[0].MaterialTitle; Match = 'none' } }
  return [pscustomobject]@{ TranslationId = $best.Id; Title = $best.Title; ShikimoriId = $best.Sid; MaterialTitle = $best.MaterialTitle; Match = $how }
}

# Kodik fallback for a movie room (any source): same kp/season/episode, closest Kodik translation.
# Returns @{ TranslationTitle; KodikTranslationId; KodikTitle; Match; ShikimoriId; FindPlayerUrl; GetPlayerQuery; Link }
#   FindPlayerUrl : https://kodikplayer.com/find-player?kinopoiskID=...&translations=false&onlyTranslationID=[id]&season=S&episode=E
#   Link          : (only with -Resolve) //kodikplayer.com/serial/<id>/<hash>/720p?season=S&episode=E from https://kodik-api.com/get-player
# Kodik uses the REAL season number (season=2 for Overlord TV-2), with kinopoiskID or with that season's shikimoriID.
function Get-WpartyKodikFallback($Room, $Sources = $null, [switch]$Resolve) {
  if ($Room.Kind -ne 'movie') { return $null }
  if ($null -eq $Sources) { $Sources = Get-WpartyMovieSources $Room.KpId }
  $title = $null
  if ($Room.Source) { $title = Get-WpartyTranslationTitle $Sources $Room.Source $Room.Translation $Room.ShikimoriId }
  $season = 0; if ($null -ne $Room.Season) { $season = [int]$Room.Season }
  $tr = $null
  if ($Room.Source -eq 'kodik') {
    $tr = [pscustomobject]@{ TranslationId = $Room.Translation; Title = $title; ShikimoriId = $Room.ShikimoriId; Match = 'same-source' }
  }
  elseif ($title) { $tr = Find-WpartyKodikTranslation $Sources $title $season }
  $kid = $null; $ktitle = $null; $match = 'none'; $sid = $null
  if ($tr) { $kid = $tr.TranslationId; $ktitle = $tr.Title; $match = $tr.Match; $sid = $tr.ShikimoriId }
  $idPart = 'kinopoiskID=' + $Room.KpId
  $u = 'https://kodikplayer.com/find-player?' + $idPart + '&translations=false'
  if ($kid) { $u += '&onlyTranslationID=[' + $kid + ']' }
  if ($null -ne $Room.Episode) {
    $s = 1; if ($null -ne $Room.Season) { $s = $Room.Season }
    $u += '&season=' + $s + '&episode=' + $Room.Episode
  }
  $q = 'title=Player&hasPlayer=false&url=' + [Uri]::EscapeDataString($u) + '&token=447d179e875efe44217f20d1ee2146be&' + $idPart
  if ($kid) { $q += '&translationID=' + $kid }
  if ($null -ne $Room.Episode) { $q += '&season=' + $s + '&episode=' + $Room.Episode }
  $link = $null; $found = $null
  if ($Resolve) {
    $r = Invoke-Web -Url ('https://kodik-api.com/get-player?' + $q) -Headers @{ 'Referer' = 'https://kodikplayer.com/'; 'Origin' = 'https://kodikplayer.com' } -TimeoutSec 20
    if ($r.Status -eq 200 -and $r.Text.Trim().StartsWith('{')) {
      $j = ConvertFrom-WpJson $r.Text
      $found = Get-WpVal $j 'found'
      $l = Get-WpStr (Get-WpVal $j 'link')
      if ($l) {
        $link = 'https:' + ($l -replace '^https?:', '')
        if ($null -ne $Room.Episode) { $link += '?season=' + $s + '&episode=' + $Room.Episode }
      }
    }
  }
  return [pscustomobject]@{
    TranslationTitle   = $title
    KodikTranslationId = $kid
    KodikTitle         = $ktitle
    Match              = $match
    ShikimoriId        = $sid
    FindPlayerUrl      = $u
    GetPlayerQuery     = $q
    Found              = $found
    Link               = $link
  }
}

# How the tool should fetch a plain-URL room video (Kind 'url').
# Returns @{ Tool ('yt-dlp'|'ffmpeg'); Url; Referer; Origin; Note }
function Get-WpartyUrlPlayHint($Room) {
  if ($Room.Kind -ne 'url') { return $null }
  $t = $Room.UrlType
  if ($t -eq 'youtube' -or $t -eq 'vk' -or $t -eq 'rutube') {
    return [pscustomobject]@{ Tool = 'yt-dlp'; Url = $Room.Video; Referer = $null; Origin = $null; Note = 'page URL; the site embeds the official ' + $t + ' player' }
  }
  if ($t -eq 'video') {
    return [pscustomobject]@{ Tool = 'ffmpeg'; Url = $Room.Video; Referer = 'https://wparty.net/'; Origin = 'https://wparty.net'; Note = 'direct file/HLS played by PlayerJS in the browser; try without headers first, then with Referer/Origin of wparty.net' }
  }
  return [pscustomobject]@{ Tool = 'yt-dlp'; Url = $Room.Video; Referer = $null; Origin = $null; Note = 'the site itself cannot play this URL (classifier "error"); try yt-dlp generic extractor' }
}

# ==================================================================================================
# AnimeLib (anilib.me / animelib.org)
# ==================================================================================================
# AnimeLib (anilib.me / animelib.org, LibSocial "site 5") resolver for VRChat Link Maker - Windows PowerShell 5.1.
# Requires the shared helper to be dot-sourced first (Invoke-Web, ConvertFrom-JsonDict, $script:WebUA).
# Optional: dot-source research\kodik\kodik.ps1 too, then Resolve-AnimelibVideo also resolves Kodik entries.
#
# Public functions:
#   Test-AnimelibUrl       [string]$url                       -> bool
#   Get-AnimelibInfo       [string]$url                       -> SlugUrl, Title, OriginalTitle, Url, Episodes[], StartEpisodeId, ...
#   Get-AnimelibSources    [string]$episodeId                 -> list of sources (Provider, Team, TranslationType, PlayerUrl, Videos, Subtitles, Headers, ...)
#   Resolve-AnimelibVideo  $source, [int]$targetHeight = 720  -> Url, Kind ('file'|'hls'), Headers, Quality, SubtitleUrl, SubtitleFormat, ...
#   Save-AnimelibSubtitle  [string]$url, [string]$path        -> path of the saved UTF-8 subtitle file
#   Select-AnimelibSource  $sources, [int]$teamId, [int]$translationTypeId, [string]$player -> the source the site would pick
#
# How the site works (verified 2026-09-27 from the live Vite bundle common-CWWu5HcZ.js / video-player-1zU23arx.js):
#   JSON API base  https://hapi.hentaicdn.org/api   (hard-coded baseUrl of the SPA; 403 unless a Referer is sent)
#                  https://api.cdnlibs.org/api      (same backend, answers without Referer; used as fallback)
#   request headers: Site-Id: 5 (AnimeLib), Referer/Origin of the site, optional "Authorization: Bearer <token>"
#   GET /anime/<slug_url>                  -> data.{id,name,rus_name,eng_name,slug_url,ageRestriction,is_licensed,...}
#   GET /episodes?anime_id=<slug_url>      -> data[] {id,number,number_secondary,season,name,item_number,status.id}  (no paging; One Piece = 1179 rows)
#   GET /episodes/<episodeId>              -> data.players[] {id,player,team{id,name},translation_type{id 1=subtitles,2=voice},
#                                             src (iframe players, "//kodikplayer.com/seria/..."), video_domain,
#                                             video.quality[]{quality,href} + subtitles[]{format,src,language} (own "Animelib" player only)}
#   GET /constants?fields[]=videoServers   -> videoServers[] {id main|secondary_1|secondary_2, url}
#   own-player URL = videoServers[id == player.video_domain (default "main")].url + quality.href   (plain string concat, like the site)
#   The own "Animelib" player entries are only returned to logged-in users (Bearer token); anonymous requests get iframe players (Kodik).
#   CDN (video1.cdnlibs.org/.<U+0430>s/, video2.cdnlibs.org, video1.imglib.info) requires ANY Referer header (403 without), no cookies/auth.

$script:AnimelibApiHosts = @('https://hapi.hentaicdn.org/api', 'https://api.cdnlibs.org/api')
$script:AnimelibSiteOrigin = 'https://anilib.me'
$script:AnimelibSiteId = '5'
$script:AnimelibToken = $null          # optional OAuth access token of the user's own AnimeLib account; else $env:ANIMELIB_TOKEN is used
$script:AnimelibServers = $null        # cached videoServers: list of @{ Id; Url }
$script:AnimelibHostRe = '(?i)^(?:https?://)?(?:[a-z0-9-]+\.)*(?:anilib\.me|animelib\.org|animelib\.me)(?::\d+)?(?=[/?#]|$)'
$script:AnimelibProviderMap = @{ 'animelib' = 'animelib'; 'kodik' = 'kodik'; 'sibnet' = 'sibnet'; 'sovetromantica' = 'sovetromantica'; 'allohatv' = 'alloha'; 'vkontakte' = 'vk' }

# ---------------------------------------------------------------- small helpers

function Get-AnimelibToken {
  $t = $script:AnimelibToken
  if (-not $t) { $t = $env:ANIMELIB_TOKEN }
  if (-not $t) { return $null }
  $t = ([string]$t).Trim()
  if ($t -match '(?i)^bearer\s+(.+)$') { $t = $Matches[1] }
  return $t
}

function Get-AnimelibApiHeaders([switch]$NoAuth) {
  $h = @{
    'Site-Id' = $script:AnimelibSiteId
    'Referer' = $script:AnimelibSiteOrigin + '/'
    'Origin'  = $script:AnimelibSiteOrigin
    'Accept'  = 'application/json, text/plain, */*'
  }
  if (-not $NoAuth) { $tok = Get-AnimelibToken; if ($tok) { $h['Authorization'] = 'Bearer ' + $tok } }
  return $h
}

# Media request headers the CDN needs (Referer is the gate; UA only for politeness).
function Get-AnimelibMediaHeaders { return @{ 'User-Agent' = $script:WebUA; 'Referer' = $script:AnimelibSiteOrigin + '/' } }

function Get-AnimelibVal($d, [string]$key) {
  if ($null -eq $d) { return $null }
  if ($d -is [System.Collections.Generic.IDictionary[string, object]]) { if ($d.ContainsKey($key)) { return $d[$key] } else { return $null } }
  if ($d -is [System.Collections.IDictionary]) { foreach ($k in $d.Keys) { if ($k -eq $key) { return $d[$k] } } }
  return $null
}

function ConvertTo-AnimelibInt($v) { $n = 0; if ([int]::TryParse([string]$v, [ref]$n)) { return $n } else { return 0 } }

# Percent-encode everything outside printable ASCII (the "main" server path contains U+0430) without any other normalisation.
function ConvertTo-AnimelibAsciiUrl([string]$u) {
  if (-not $u) { return $u }
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $u.ToCharArray()) {
    $c = [int]$ch
    if ($c -gt 32 -and $c -lt 127) { [void]$sb.Append($ch) }
    else { foreach ($b in [System.Text.Encoding]::UTF8.GetBytes([string]$ch)) { [void]$sb.Append('%' + $b.ToString('X2')) } }
  }
  return $sb.ToString()
}

function ConvertTo-AnimelibAbsoluteUrl([string]$u, [string]$base) {
  if (-not $u) { return $null }
  $u = $u.Trim()
  if ($u -match '^(?i)https?://') { return $u }
  if ($u.StartsWith('//')) { return 'https:' + $u }
  if (-not $base) { $base = $script:AnimelibSiteOrigin }
  if ($u.StartsWith('/')) { return $base.TrimEnd('/') + $u }
  return $base.TrimEnd('/') + '/' + $u
}

# One API call with host fallback. Returns the parsed JSON (Dictionary) or $null when the object does not exist (404).
$script:AnimelibApiGoodHost = $null   # [verify fix] last host that answered; tried first next time
function Invoke-AnimelibApi([string]$path) {
  $lastErr = ''
  $hosts = @($script:AnimelibApiHosts)
  if ($script:AnimelibApiGoodHost) { $hosts = @($script:AnimelibApiGoodHost) + @($hosts | Where-Object { $_ -ne $script:AnimelibApiGoodHost }) }
  foreach ($apiHost in $hosts) {
    $url = $apiHost + $path
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
      try { $r = Invoke-Web -Url $url -Headers (Get-AnimelibApiHeaders) -TimeoutSec 20 }
      catch { $lastErr = "$url -> $($_.Exception.Message)"; break }
      if ($r.Status -eq 200) {
        $parsed = $null
        try { $parsed = ConvertFrom-JsonDict $r.Text } catch { $lastErr = "$url -> bad JSON"; break }
        $script:AnimelibApiGoodHost = $apiHost
        return $parsed
      }
      if ($r.Status -eq 404) { return $null }
      if ($r.Status -eq 401 -and (Get-AnimelibToken)) {
        throw 'AnimeLib: the API rejected the access token (HTTP 401) - it has probably expired; copy a fresh one or clear ANIMELIB_TOKEN.'
      }
      if ($r.Status -eq 429 -and $attempt -eq 0) { Start-Sleep -Seconds 3; continue }
      $lastErr = "$url -> HTTP $($r.Status)"
      break
    }
  }
  throw "AnimeLib API request failed ($lastErr)"
}

function Get-AnimelibServers {
  if ($script:AnimelibServers) { return $script:AnimelibServers }
  $list = New-Object System.Collections.Generic.List[object]
  try {
    $j = Invoke-AnimelibApi '/constants?fields[]=videoServers'
    foreach ($s in @(Get-AnimelibVal (Get-AnimelibVal $j 'data') 'videoServers')) {
      $id = [string](Get-AnimelibVal $s 'id'); $u = [string](Get-AnimelibVal $s 'url')
      if ($id -and $u) { $list.Add([pscustomobject]@{ Id = $id; Url = $u }) }
    }
  } catch {}
  if ($list.Count -eq 0) {
    # last known values (2026-09-27); the main path really contains CYRILLIC SMALL LETTER A
    $list.Add([pscustomobject]@{ Id = 'main'; Url = 'https://video1.cdnlibs.org/.' + [char]0x0430 + 's/' })
    $list.Add([pscustomobject]@{ Id = 'secondary_1'; Url = 'https://video2.cdnlibs.org/' })
    $list.Add([pscustomobject]@{ Id = 'secondary_2'; Url = 'https://video1.imglib.info/' })
  }
  $script:AnimelibServers = $list
  return $list
}

# Parse any AnimeLib page URL. Returns $null when it is not an AnimeLib title URL.
function ConvertFrom-AnimelibUrl([string]$url) {
  if (-not $url) { return $null }
  $url = $url.Trim()
  if ($url -notmatch $script:AnimelibHostRe) { return $null }
  $rest = $url.Substring($Matches[0].Length)
  $path = $rest; $query = ''
  $qi = $rest.IndexOfAny([char[]]'?#')
  if ($qi -ge 0) { $path = $rest.Substring(0, $qi); $query = $rest.Substring($qi) }
  $slug = $null
  if ($path -match '(?i)^/(?:[a-z]{2}/)?anime/([^/?#]+)') { $slug = $Matches[1] }                  # /ru/anime/<slug_url>[/watch]
  elseif ($path -match '(?i)^/(?:[a-z]{2}/)?(\d+--[^/?#]+)/?$') { $slug = $Matches[1] }           # /ru/<slug_url> (short form, site redirects)
  if (-not $slug) { return $null }
  try { $slug = [Uri]::UnescapeDataString($slug) } catch {}
  # [verify fix] slugs are lower-case; the API answers 404 for "9991--OVERLORD-ANIME"
  $slug = $slug.ToLowerInvariant()
  $q = @{}
  if ($query -match '\?([^#]*)') {
    foreach ($pair in ($Matches[1] -split '&')) {
      if (-not $pair) { continue }
      $kv = $pair -split '=', 2
      $k = [Uri]::UnescapeDataString($kv[0]); $v = ''
      if ($kv.Count -gt 1) { $v = [Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) }
      $q[$k.ToLowerInvariant()] = $v
    }
  }
  $ep = $null; if ($q['episode'] -match '^\d+$') { $ep = [int64]$q['episode'] }
  $team = $null; if ($q['team'] -match '^\d+$') { $team = [int]$q['team'] }
  $tt = $null; if ($q['translation_type'] -match '^\d+$') { $tt = [int]$q['translation_type'] }
  $t = $null; if ($q['t'] -match '^\d+(\.\d+)?$') { $t = [double]$q['t'] }
  return [pscustomobject]@{
    Slug = $slug; EpisodeId = $ep; TeamId = $team; TranslationTypeId = $tt; Player = $q['player']; Time = $t
    IsWatch = ($path -match '(?i)/watch/?$')
  }
}

function Test-AnimelibUrl([string]$url) { return ($null -ne (ConvertFrom-AnimelibUrl $url)) }

# ---------------------------------------------------------------- title + episodes

function Get-AnimelibInfo([string]$url) {
  $p = ConvertFrom-AnimelibUrl $url
  if (-not $p) { throw "Not an AnimeLib title URL: $url" }
  $slugEsc = [Uri]::EscapeDataString($p.Slug)
  $j = Invoke-AnimelibApi ('/anime/' + $slugEsc + '?fields[]=episodes_count')
  if (-not $j) { throw "AnimeLib: title '$($p.Slug)' not found (deleted, hidden from anonymous users, or wrong slug)" }
  $d = Get-AnimelibVal $j 'data'
  $slugUrl = [string](Get-AnimelibVal $d 'slug_url'); if (-not $slugUrl) { $slugUrl = $p.Slug }
  $rus = [string](Get-AnimelibVal $d 'rus_name'); $name = [string](Get-AnimelibVal $d 'name'); $eng = [string](Get-AnimelibVal $d 'eng_name')
  $title = $rus; if (-not $title) { $title = $name }; if (-not $title) { $title = $eng }
  $orig = $name; if (-not $orig) { $orig = $eng }
  $age = [string](Get-AnimelibVal (Get-AnimelibVal $d 'ageRestriction') 'label')
  $licensed = [bool](Get-AnimelibVal $d 'is_licensed')

  $episodes = New-Object System.Collections.Generic.List[object]
  $ej = Invoke-AnimelibApi ('/episodes?anime_id=' + [Uri]::EscapeDataString($slugUrl))
  foreach ($e in @(Get-AnimelibVal $ej 'data')) {
    if ($null -eq $e) { continue }
    $episodes.Add([pscustomobject]@{
        Id         = [int64](Get-AnimelibVal $e 'id')
        Number     = [string](Get-AnimelibVal $e 'number')          # string: can be "12.5"
        Season     = [string](Get-AnimelibVal $e 'season')
        Name       = [string](Get-AnimelibVal $e 'name')
        ItemNumber = ConvertTo-AnimelibInt (Get-AnimelibVal $e 'item_number')
        Status     = [string](Get-AnimelibVal (Get-AnimelibVal $e 'status') 'id')   # default | filler | special | recap
      })
  }
  $start = $null
  if ($p.EpisodeId) { foreach ($e in $episodes) { if ($e.Id -eq $p.EpisodeId) { $start = $e.Id; break } } }
  $warning = $null
  if ($licensed) { $warning = 'Title is licensed: the site says it is unavailable in your region (episodes removed at the right holder''s request).' }
  elseif ($episodes.Count -eq 0) { $warning = 'Title has no episodes yet (announcement or nothing uploaded).' }
  elseif ($p.EpisodeId -and -not $start) { $warning = "Episode id $($p.EpisodeId) from the URL is not in this title's episode list." }

  return [pscustomobject]@{
    SlugUrl            = $slugUrl
    AnimeId            = ConvertTo-AnimelibInt (Get-AnimelibVal $d 'id')
    Title              = $title
    OriginalTitle      = $orig
    ShikimoriId        = [regex]::Match([string](Get-AnimelibVal $d 'shikimori_href'), '/animes/[a-z]*(\d+)').Groups[1].Value
    Url                = $script:AnimelibSiteOrigin + '/ru/anime/' + $slugUrl
    AgeRestriction     = $age
    IsLicensed         = $licensed
    Episodes           = $episodes.ToArray()
    StartEpisodeId     = $start
    StartTeamId        = $p.TeamId
    StartTranslationId = $p.TranslationTypeId
    StartPlayer        = $p.Player
    StartTime          = $p.Time
    Warning            = $warning
  }
}

# ---------------------------------------------------------------- sources of one episode

function ConvertTo-AnimelibSource($pl, $servers) {
  $playerName = [string](Get-AnimelibVal $pl 'player')
  $prov = $script:AnimelibProviderMap[$playerName.ToLowerInvariant()]
  if (-not $prov) { $prov = $playerName.ToLowerInvariant() }
  $team = Get-AnimelibVal $pl 'team'
  $ttId = ConvertTo-AnimelibInt (Get-AnimelibVal (Get-AnimelibVal $pl 'translation_type') 'id')
  $tt = 'voice'; if ($ttId -eq 1) { $tt = 'subtitles' }
  $domain = [string](Get-AnimelibVal $pl 'video_domain')

  $videos = New-Object System.Collections.Generic.List[object]
  $mirrors = New-Object System.Collections.Generic.List[string]
  $video = Get-AnimelibVal $pl 'video'
  $qual = @(Get-AnimelibVal $video 'quality')
  if ($qual.Count -gt 0 -and $null -ne $qual[0]) {
    # server exactly like the site: the player's video_domain, else the user's setting (default "main")
    $primary = $null
    foreach ($s in $servers) { if ($s.Id -eq $domain) { $primary = $s } }
    if (-not $primary) { foreach ($s in $servers) { if ($s.Id -eq 'main') { $primary = $s } } }
    if (-not $primary -and $servers.Count -gt 0) { $primary = $servers[0] }
    $ordered = @($primary) + @($servers | Where-Object { $_.Id -ne $primary.Id })
    foreach ($s in $ordered) { $mirrors.Add($s.Id) }
    $rows = @(foreach ($q in $qual) {
      $href = [string](Get-AnimelibVal $q 'href')
      if (-not $href) { continue }
      $alts = @(foreach ($s in $ordered) { ConvertTo-AnimelibAsciiUrl ($s.Url + $href) })
      [pscustomobject]@{
        Quality = ConvertTo-AnimelibInt (Get-AnimelibVal $q 'quality')
        Url     = $alts[0]
        Href    = $href
        Bitrate = ConvertTo-AnimelibInt (Get-AnimelibVal $q 'bitrate')
        Mirrors = @($alts)
      }
    })
    foreach ($r in @($rows | Sort-Object -Property Quality -Descending)) { $videos.Add($r) }
  }

  $subs = New-Object System.Collections.Generic.List[object]
  foreach ($s in @(Get-AnimelibVal $pl 'subtitles')) {
    if ($null -eq $s) { continue }
    $src = [string](Get-AnimelibVal $s 'src'); if (-not $src) { $src = [string](Get-AnimelibVal $s 'url') }
    if (-not $src) { continue }
    $fmt = ([string](Get-AnimelibVal $s 'format')).ToLowerInvariant()
    if (-not $fmt -and $src -match '\.([a-z0-9]{2,4})(?:[?#]|$)') { $fmt = $Matches[1].ToLowerInvariant() }
    $lang = [string](Get-AnimelibVal $s 'language'); if (-not $lang) { $lang = [string](Get-AnimelibVal $s 'lang') }
    $subs.Add([pscustomobject]@{ Url = ConvertTo-AnimelibAsciiUrl (ConvertTo-AnimelibAbsoluteUrl $src $script:AnimelibSiteOrigin); Format = $fmt; Lang = $lang; Label = [string](Get-AnimelibVal $s 'label') })
  }

  $playerUrl = $null
  $src = [string](Get-AnimelibVal $pl 'src')
  if ($src) {
    $playerUrl = ConvertTo-AnimelibAbsoluteUrl $src 'https://'
    if ($prov -eq 'kodik' -and $playerUrl -notmatch '[?&]translations=') {
      # the site's iframe component appends translations=false
      if ($playerUrl.Contains('?')) { $playerUrl += '&translations=false' } else { $playerUrl += '?translations=false' }
    }
  }

  $headers = @{ 'Referer' = $script:AnimelibSiteOrigin + '/' }
  if ($prov -eq 'animelib') { $headers = Get-AnimelibMediaHeaders }

  return [pscustomobject]@{
    Provider          = $prov
    Player            = $playerName
    PlayerId          = ConvertTo-AnimelibInt (Get-AnimelibVal $pl 'id')
    EpisodeId         = ConvertTo-AnimelibInt (Get-AnimelibVal $pl 'episode_id')
    Team              = [string](Get-AnimelibVal $team 'name')
    TeamId            = ConvertTo-AnimelibInt (Get-AnimelibVal $team 'id')
    TranslationType   = $tt
    TranslationTypeId = $ttId
    PlayerUrl         = $playerUrl
    Videos            = $videos.ToArray()
    Subtitles         = $subs.ToArray()
    Headers           = $headers
    VideoDomain       = $domain
    Servers           = $mirrors.ToArray()
    Views             = ConvertTo-AnimelibInt (Get-AnimelibVal $pl 'views')
  }
}

function Get-AnimelibSources([string]$episodeId) {
  if ($episodeId -notmatch '^\d+$') { throw "AnimeLib: bad episode id '$episodeId'" }
  $j = Invoke-AnimelibApi ('/episodes/' + $episodeId)
  if (-not $j) { throw "AnimeLib: episode $episodeId not found" }
  $players = @(Get-AnimelibVal (Get-AnimelibVal $j 'data') 'players')
  $needServers = $false
  foreach ($pl in $players) { if ($null -ne (Get-AnimelibVal (Get-AnimelibVal $pl 'video') 'quality')) { $needServers = $true } }
  $servers = @(); if ($needServers) { $servers = @(Get-AnimelibServers) }
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($pl in $players) { if ($null -ne $pl) { $out.Add((ConvertTo-AnimelibSource $pl $servers)) } }
  return , $out.ToArray()
}

# The entry the site would open: wanted team + translation type (default voice), player "Animelib" preferred, else the first one.
function Select-AnimelibSource($sources, [int]$teamId = 0, [int]$translationTypeId = 0, [string]$player = '') {
  $list = @($sources)
  if ($list.Count -eq 0) { return $null }
  if ($translationTypeId -le 0) { $translationTypeId = 2 }
  if ($teamId -gt 0 -and @($list | Where-Object { $_.TeamId -eq $teamId }).Count -gt 0) { $list = @($list | Where-Object { $_.TeamId -eq $teamId }) }
  if (@($list | Where-Object { $_.TranslationTypeId -eq $translationTypeId }).Count -gt 0) { $list = @($list | Where-Object { $_.TranslationTypeId -eq $translationTypeId }) }
  if ($player) { $m = @($list | Where-Object { $_.Player -eq $player }); if ($m.Count -gt 0) { return $m[0] } }
  $m = @($list | Where-Object { $_.Provider -eq 'animelib' -and $_.Videos.Count -gt 0 }); if ($m.Count -gt 0) { return $m[0] }
  return $list[0]
}

# ---------------------------------------------------------------- media probing / resolving

# Ranged GET of 2 bytes. Returns the HTTP status, or -1 when the request could not be made
# (e.g. .NET/schannel cannot handshake with video2.cdnlibs.org although ffmpeg/gnutls can).
function Test-AnimelibMedia([string]$url, [hashtable]$headers) {
  try {
    $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($url)
    $req.Method = 'GET'; $req.Timeout = 15000; $req.ReadWriteTimeout = 15000; $req.AllowAutoRedirect = $true
    $req.UserAgent = $script:WebUA
    foreach ($k in $headers.Keys) {
      switch ($k.ToLowerInvariant()) { 'referer' { $req.Referer = [string]$headers[$k] } 'user-agent' { $req.UserAgent = [string]$headers[$k] } default { $req.Headers[$k] = [string]$headers[$k] } }
    }
    $req.AddRange(0, 1)
    $resp = $null
    try { $resp = $req.GetResponse() } catch [System.Net.WebException] { if ($_.Exception.Response) { $resp = $_.Exception.Response } else { return -1 } }
    try { return [int]$resp.StatusCode } finally { $resp.Close() }
  } catch { return -1 }
}

function Select-AnimelibQuality($videos, [int]$targetHeight) {
  $v = @($videos | Sort-Object -Property Quality -Descending)
  if ($v.Count -eq 0) { return $null }
  if ($targetHeight -le 0) { return $v[0] }
  foreach ($x in $v) { if ($x.Quality -le $targetHeight) { return $x } }
  return $v[$v.Count - 1]
}

function Select-AnimelibSubtitle($subs) {
  $order = @('ass', 'ssa', 'srt', 'vtt')
  foreach ($f in $order) { foreach ($s in @($subs)) { if ($s -and $s.Format -eq $f) { return $s } } }
  $all = @($subs); if ($all.Count -gt 0) { return $all[0] }
  return $null
}

function Resolve-AnimelibVideo($source, [int]$targetHeight = 720, [switch]$NoProbe) {
  if (-not $source) { throw 'AnimeLib: no source given' }
  if ($source.Provider -ne 'animelib') {
    if ($source.Provider -eq 'kodik' -and (Get-Command Resolve-Kodik -ErrorAction SilentlyContinue)) {
      $k = Resolve-Kodik $source.PlayerUrl ($script:AnimelibSiteOrigin + '/')
      $kq = [int]$k.Quality; $kUrl = $k.Url
      $kqs = @(); if ($k.Qualities -is [System.Collections.IDictionary]) { $kqs = @($k.Qualities.Keys | ForEach-Object { [int]$_ } | Sort-Object -Descending) }
      # [verify fix] honour $targetHeight for Kodik too (Resolve-Kodik returns its best rendition, e.g. 1080 for a movie)
      if ($targetHeight -gt 0 -and $kqs.Count -gt 0) {
        $want = $null
        foreach ($q in $kqs) { if ($q -le $targetHeight) { $want = $q; break } }
        if ($null -eq $want) { $want = $kqs[$kqs.Count - 1] }
        $u = $k.Qualities[[string]$want]
        if ($u -and $want -ne $kq) { $kq = $want; $kUrl = [string]$u }
      }
      return [pscustomobject]@{ Url = $kUrl; Kind = 'hls'; Headers = $k.Headers; Quality = $kq; Qualities = $kqs; SubtitleUrl = $null; SubtitleFormat = $null
        Subtitles = @(); Team = $source.Team; TranslationType = $source.TranslationType; Provider = 'kodik'; Server = $null; Verified = $true; Duration = $k.Duration }
    }
    throw "AnimeLib: provider '$($source.Provider)' is an external iframe player - resolve PlayerUrl ($($source.PlayerUrl)) with its own resolver"
  }
  if (@($source.Videos).Count -eq 0) { throw 'AnimeLib: this Animelib player entry has no video qualities' }

  $headers = Get-AnimelibMediaHeaders
  $sub = Select-AnimelibSubtitle $source.Subtitles
  $subUrl = $null; $subFmt = $null; if ($sub) { $subUrl = $sub.Url; $subFmt = $sub.Format }

  $cands = @($source.Videos | Sort-Object -Property Quality -Descending)
  $pick = Select-AnimelibQuality $cands $targetHeight
  # try the wanted quality first, then the others from high to low
  $tryOrder = @($pick) + @($cands | Where-Object { $_.Href -ne $pick.Href })
  $chosenUrl = $null; $chosen = $null; $server = $null; $verified = $false; $firstUnknown = $null
  if ($NoProbe) { $chosen = $pick; $chosenUrl = $pick.Url; $server = @($source.Servers)[0] }
  else {
    foreach ($v in $tryOrder) {
      $mir = @($v.Mirrors); if ($mir.Count -eq 0) { $mir = @($v.Url) }
      for ($i = 0; $i -lt $mir.Count; $i++) {
        $st = Test-AnimelibMedia $mir[$i] $headers
        if ($st -eq 200 -or $st -eq 206) { $chosen = $v; $chosenUrl = $mir[$i]; $server = @($source.Servers)[$i]; $verified = $true; break }
        if ($st -eq -1 -and -not $firstUnknown) { $firstUnknown = [pscustomobject]@{ V = $v; Url = $mir[$i]; Server = @($source.Servers)[$i] } }
      }
      if ($chosen) { break }
    }
    if (-not $chosen -and $firstUnknown) { $chosen = $firstUnknown.V; $chosenUrl = $firstUnknown.Url; $server = $firstUnknown.Server }
    if (-not $chosen) { throw 'AnimeLib: none of the video files answered on any video server (HTTP 403/404)' }
  }
  return [pscustomobject]@{
    Url             = $chosenUrl
    Kind            = 'file'
    Headers         = $headers
    Quality         = $chosen.Quality
    Qualities       = @($cands | ForEach-Object { $_.Quality })
    SubtitleUrl     = $subUrl
    SubtitleFormat  = $subFmt
    Subtitles       = $source.Subtitles
    Team            = $source.Team
    TranslationType = $source.TranslationType
    Provider        = 'animelib'
    Server          = $server
    Verified        = $verified
    Duration        = $null
  }
}

# Download a subtitle file (Referer as the site sends it) and store it as UTF-8 (no BOM) for ffmpeg's subtitles filter.
function Save-AnimelibSubtitle([string]$url, [string]$path) {
  $r = Invoke-Web -Url $url -Headers @{ 'Referer' = $script:AnimelibSiteOrigin + '/'; 'Origin' = $script:AnimelibSiteOrigin } -TimeoutSec 30
  if ($r.Status -ne 200) { throw "AnimeLib: subtitle download failed (HTTP $($r.Status))" }
  $text = $r.Text
  if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
  [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
  return $path
}

# ==================================================================================================
# Collaps (fallback for WPARTY rooms, by Kinopoisk id)
# ==================================================================================================
# Collaps (api.nextembed.ws): finds a show or film by its Kinopoisk id, like WPARTY does. Used as a fallback for
# WPARTY rooms whose player can't be read here (turbo, vibix, lumex) or when Kodik doesn't have the title.
# Returns a 720p H.264 video playlist (VideoUrl) plus the chosen voice-over as a separate audio playlist (AudioUrl).
# The User-Agent is part of the token: ffmpeg must send exactly Headers['User-Agent'].

$script:CollapsEmbedHost = 'api.nextembed.ws'

# ---------------------------------------------------------------- shared helpers

# Returns the balanced JSON/JS literal ([...] or {...}) that starts at $Start (string-aware).
function Get-BalancedLiteral([string]$Text, [int]$Start) {
  $depth = 0; $inStr = $false; $esc = $false; $q = [char]0
  for ($i = $Start; $i -lt $Text.Length; $i++) {
    $c = $Text[$i]
    if ($inStr) {
      if ($esc) { $esc = $false } elseif ($c -eq [char]'\') { $esc = $true } elseif ($c -eq $q) { $inStr = $false }
      continue
    }
    if ($c -eq [char]'"' -or $c -eq [char]"'") { $inStr = $true; $q = $c; continue }
    if ($c -eq [char]'[' -or $c -eq [char]'{') { $depth++ }
    elseif ($c -eq [char]']' -or $c -eq [char]'}') { $depth--; if ($depth -eq 0) { return $Text.Substring($Start, $i - $Start + 1) } }
  }
  return $null
}

function Get-LeadingInt([string]$s) {
  $m = [regex]::Match([string]$s, '\d+')
  if ($m.Success) { return [int]$m.Value }
  return -1
}

# Unix "t=" expiry parameter of a signed URL -> DateTime UTC (or $null).
function Get-UrlExpiryUtc([string]$Url) {
  $m = [regex]::Match($Url, '[?&]t=(\d{9,11})(?:&|$)')
  if (-not $m.Success) { return $null }
  return (New-Object DateTime(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).AddSeconds([double]$m.Groups[1].Value)
}

# Fetches and parses an HLS master playlist.
# Returns @{ Variants = video variants (best first, one per resolution; the first-listed one wins, the
#                       duplicate "failover" variant is kept as FailoverProgram);
#            Audio    = EXT-X-MEDIA audio renditions per GROUP-ID: @{ 'audio0' = @(@{Pos;Name;Lang;Default;Url}, ...) } }
# Program = position of the #EXT-X-STREAM-INF in the master = ffmpeg's program index for that variant, so
#   ffmpeg -i <master> -map 0:p:<Program>:v:0 -map 0:p:<Program>:a:<AudioIndex>
# selects exactly one quality + one dub (audio streams inside a program are in EXT-X-MEDIA order).
function Get-HlsMaster {
  param([Parameter(Mandatory = $true)][string]$Url, [hashtable]$Headers = @{})
  $r = Invoke-Web -Url $Url -Headers $Headers -TimeoutSec 20
  if ($r.Status -ne 200 -or $r.Text -notmatch '#EXTM3U') { throw "HLS master not reachable (HTTP $($r.Status)): $Url" }
  $lines = $r.Text -split "`r?`n"
  $list = New-Object System.Collections.ArrayList
  $audio = @{}
  $byHeight = @{}
  $pos = 0
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if ($l -like '#EXT-X-MEDIA:*' -and $l -match 'TYPE=AUDIO') {
      $g = ''; $n = ''; $lang = ''; $au = $null
      $m = [regex]::Match($l, 'GROUP-ID="([^"]*)"'); if ($m.Success) { $g = $m.Groups[1].Value }
      $m = [regex]::Match($l, '[:,]NAME="([^"]*)"'); if ($m.Success) { $n = $m.Groups[1].Value }
      $m = [regex]::Match($l, 'LANGUAGE="([^"]*)"'); if ($m.Success) { $lang = $m.Groups[1].Value }
      $m = [regex]::Match($l, 'URI="([^"]*)"'); if ($m.Success) { $au = ([Uri]::new([Uri]$Url, $m.Groups[1].Value)).AbsoluteUri }
      if (-not $audio.ContainsKey($g)) { $audio[$g] = New-Object System.Collections.ArrayList }
      [void]$audio[$g].Add([pscustomobject]@{ Pos = $audio[$g].Count; Name = $n; Lang = $lang; Default = ($l -match 'DEFAULT=YES'); Url = $au })
    }
    elseif ($l -like '#EXT-X-STREAM-INF:*') {
      $w = 0; $h = 0; $bw = 0; $ag = $null
      $m = [regex]::Match($l, 'RESOLUTION=(\d+)x(\d+)'); if ($m.Success) { $w = [int]$m.Groups[1].Value; $h = [int]$m.Groups[2].Value }
      $m = [regex]::Match($l, '[:,]BANDWIDTH=(\d+)'); if ($m.Success) { $bw = [int64]$m.Groups[1].Value }
      $m = [regex]::Match($l, 'AUDIO="([^"]*)"'); if ($m.Success) { $ag = $m.Groups[1].Value }
      $u = $null
      for ($j = $i + 1; $j -lt $lines.Count; $j++) { if ($lines[$j] -and -not $lines[$j].StartsWith('#')) { $u = $lines[$j].Trim(); break } }
      if ($u) {
        $abs = ([Uri]::new([Uri]$Url, $u)).AbsoluteUri
        if (-not $byHeight.ContainsKey("$h")) {
          $v = [pscustomobject]@{ Height = $h; Width = $w; Bandwidth = $bw; Url = $abs; Program = $pos; AudioGroup = $ag; Host = ([Uri]$abs).Host; FailoverProgram = -1; FailoverHost = $null }
          $byHeight["$h"] = $v
          [void]$list.Add($v)
        }
        elseif ($byHeight["$h"].FailoverProgram -lt 0) { $byHeight["$h"].FailoverProgram = $pos; $byHeight["$h"].FailoverHost = ([Uri]$abs).Host }
        $pos++
      }
    }
  }
  return @{ Variants = @($list | Sort-Object -Property Height, Bandwidth -Descending); Audio = $audio }
}

# Back-compat wrapper: video variants only (best first, one per resolution).
function Get-HlsVariants {
  param([Parameter(Mandatory = $true)][string]$Url, [hashtable]$Headers = @{})
  return (Get-HlsMaster -Url $Url -Headers $Headers).Variants
}

# Picks the audio position for a preferred dub name. Returns -1 when nothing matches.
# Matching ignores case, spaces, dots, dashes and a trailing ".TV" ('AniLibria.TV' = 'Anilibria', '\u0421\u0412-\u0414\u0443\u0431\u043b\u044c' ~ '\u0421\u0442\u0443\u0434\u0438\u044f \u0421\u0412-\u0414\u0443\u0431\u043b\u044c').
function Find-AudioIndex([string[]]$Names, [string]$Prefer) {
  if (-not $Prefer -or -not $Names) { return -1 }
  $norm = { param($s) (([string]$s).ToLowerInvariant() -replace '\.tv\b', '' -replace '[\s\.\-_|()]', '') }
  $p = & $norm $Prefer
  if (-not $p) { return -1 }
  for ($i = 0; $i -lt $Names.Count; $i++) { if ((& $norm $Names[$i]) -eq $p) { return $i } }
  for ($i = 0; $i -lt $Names.Count; $i++) { $n = & $norm $Names[$i]; if ($n -and ($n.Contains($p) -or $p.Contains($n))) { return $i } }
  return -1
}

# ---------------------------------------------------------------- Collaps (api.nextembed.ws)

# Resolve-Collaps: kinopoisk id (+ season/episode for series) -> 720p H.264/AAC HLS.
#   -KinopoiskId  e.g. 923115 (wparty REC:host .video = "moviecdn://923115")
#   -Season/-Episode  series only (wparty moviePlaylistId "1_2" = season 1, episode 2); omit for movies
#   -PreferAudio  dub name (substring/normalised match against audio.names, e.g. 'AniLibria', '\u0421\u0412-\u0414\u0443\u0431\u043b\u044c').
#                 [verifier fix] The HLS master carries ALL dubs as separate audio renditions; the result's
#                 AudioIndex/AudioTracks/FfmpegMap say which one to map:  ffmpeg ... -i Url <FfmpegMap> -c copy
#                 (0:p:<Program>:a:<AudioIndex>). Without a match the first 'ru' track is chosen (+ .Warning).
#                 Do NOT use '-map 0:p:N:a?' - it downloads every dub (25 audio tracks for some movies).
#                 FASTEST (recommended): two inputs, video variant + chosen audio rendition, same headers on both:
#                   ffmpeg <hdrs> -i VideoUrl <hdrs> -i AudioUrl -map 0:v:0 -map 1:a:0 -c copy out.mkv
#                 (master+map probes every rendition: 75 s startup for a 25-dub movie vs 3 s; 300 s of video in 7 s).
#   Wrong User-Agent / changed token => every segment answers 410 Gone and ffmpeg keeps skipping segments
#   (no error exit) - watch download progress and re-resolve.
# Throws: not found (HTTP 404/no player), blocked by rights holder, season/episode missing, master unreachable.
function Resolve-Collaps {
  param(
    [Parameter(Mandatory = $true)][string]$KinopoiskId,
    [int]$Season = 0,
    [int]$Episode = 0,
    [string]$PreferAudio = $null,
    [string]$EmbedHost = $script:CollapsEmbedHost
  )
  $embedUrl = "https://$EmbedHost/embed/kp/$KinopoiskId"
  $r = Invoke-Web -Url $embedUrl -TimeoutSec 20
  if ($r.Status -ne 200 -or $r.Text -notmatch 'makePlayer\(') { throw "Collaps: no player for kp $KinopoiskId (HTTP $($r.Status))" }
  $html = $r.Text

  # The page appends '&' + <random var> to every hls/dash URL: add(o,k){... o[k]+='&'+NAME}; NAME= "hex";
  # (there is also a decoy string  lol = ', NAME="xxxx"'  which is NOT followed by ';')
  $tok = $null
  $mName = [regex]::Match($html, "o\[k\]\+='&'\+([A-Za-z_\$][\w\$]*)")
  if ($mName.Success) {
    $ms = [regex]::Matches($html, '(?:\bvar\s+|,\s*)' + [regex]::Escape($mName.Groups[1].Value) + '\s*=\s*"([^"]*)"\s*;')
    if ($ms.Count -gt 0) { $tok = $ms[$ms.Count - 1].Groups[1].Value }
  }

  $hls = $null; $dash = $null; $audioNames = @(); $title = $null; $duration = $null; $subs = @()
  $iSeasons = $html.IndexOf('seasons:[')
  if ($iSeasons -ge 0) {
    if ($Season -le 0 -or $Episode -le 0) { throw "Collaps: kp $KinopoiskId is a series - pass -Season and -Episode" }
    $json = Get-BalancedLiteral $html ($iSeasons + 8)
    $seasons = ConvertFrom-JsonDict $json
    $se = $null
    foreach ($s in $seasons) { if ([int]$s['season'] -eq $Season) { $se = $s; break } }
    if (-not $se) { throw "Collaps: season $Season not found (have: $((@($seasons | ForEach-Object { $_['season'] }) | Sort-Object) -join ','))" }
    if ($se['blocked']) { throw "Collaps: season $Season is blocked by the rights holder" }
    $ep = $null
    foreach ($e in $se['episodes']) { if ((Get-LeadingInt $e['episode']) -eq $Episode) { $ep = $e; break } }
    if (-not $ep) { throw "Collaps: season $Season episode $Episode not found" }
    $hls = [string]$ep['hls']; $dash = [string]$ep['dash']; $title = [string]$ep['title']; $duration = $ep['duration']
    if ($ep['audio'] -and $ep['audio']['names']) { $audioNames = @($ep['audio']['names']) }
    if ($ep['cc']) { $subs = @($ep['cc'] | ForEach-Object { [pscustomobject]@{ Name = $_['name']; Url = $_['url'] } }) }
  }
  else {
    if ($html -match 'blocked:\s*true') { throw "Collaps: kp $KinopoiskId is blocked by the rights holder" }
    $iSrc = $html.IndexOf('source:')
    if ($iSrc -lt 0) { throw 'Collaps: player source not found' }
    $src = Get-BalancedLiteral $html ($html.IndexOf('{', $iSrc))
    $m = [regex]::Match($src, '\bhls:\s*"([^"]+)"'); if ($m.Success) { $hls = $m.Groups[1].Value }
    $m = [regex]::Match($src, '\bdash:\s*"([^"]+)"'); if ($m.Success) { $dash = $m.Groups[1].Value }
    $iA = $src.IndexOf('audio:'); if ($iA -ge 0) { $a = ConvertFrom-JsonDict (Get-BalancedLiteral $src ($src.IndexOf('{', $iA))); if ($a['names']) { $audioNames = @($a['names']) } }
    $iC = $src.IndexOf('cc:'); if ($iC -ge 0) { try { $subs = @((ConvertFrom-JsonDict (Get-BalancedLiteral $src ($src.IndexOf('[', $iC)))) | ForEach-Object { [pscustomobject]@{ Name = $_['name']; Url = $_['url'] } }) } catch {} }
    $m = [regex]::Match($html, 'title:\s*"([^"]*)"'); if ($m.Success) { $title = $m.Groups[1].Value }
  }
  if (-not $hls) { throw 'Collaps: no HLS url in player config' }
  if ($tok) { $hls = $hls + '&' + $tok; if ($dash) { $dash = $dash + '&' + $tok } }

  # CDN tokens: hu = hash(User-Agent), hi = hash(IP), t = expiry (~10 days). ffmpeg MUST use the same UA.
  $headers = [ordered]@{ 'User-Agent' = $script:WebUA; 'Referer' = "https://$EmbedHost/"; 'Origin' = "https://$EmbedHost" }
  $hdr = @{}; foreach ($k in $headers.Keys) { $hdr[$k] = $headers[$k] }
  $master = Get-HlsMaster -Url $hls -Headers $hdr
  $q = $master.Variants
  if (@($q).Count -eq 0) { throw 'Collaps: HLS master has no video variants' }

  # EVERY dub is in the HLS master as an EXT-X-MEDIA audio rendition (group "audio0", plus a duplicate
  # "failover-audio-0" group). Rendition k is labelled audio.names[k] (player-venom transformAudioList:
  # names label tracks in manifest order; audio.order is only the menu order).
  $rend = @()
  $grp = $q[0].AudioGroup
  if ($grp -and $master.Audio.ContainsKey($grp)) { $rend = @($master.Audio[$grp]) }
  $tracks = New-Object System.Collections.ArrayList
  $nTracks = [Math]::Max($rend.Count, $audioNames.Count)
  if ($rend.Count -eq 0) { $nTracks = [Math]::Min(1, $audioNames.Count) }   # muxed audio: only the first dub
  for ($k = 0; $k -lt $nTracks; $k++) {
    $nm = $null; if ($k -lt $audioNames.Count) { $nm = [string]$audioNames[$k] }
    $lg = $null; $hn = $null; $tu = $null; if ($k -lt $rend.Count) { $lg = $rend[$k].Lang; $hn = $rend[$k].Name; $tu = $rend[$k].Url }
    if (-not $nm) { $nm = $hn }
    [void]$tracks.Add([pscustomobject]@{ Index = $k; Name = $nm; Lang = $lg; HlsName = $hn; Url = $tu })
  }
  $warn = $null
  if ($rend.Count -gt 0 -and $audioNames.Count -gt 0 -and $rend.Count -ne $audioNames.Count) {
    $warn = (T 'audio name list ({0}) and HLS renditions ({1}) differ - labels may be off' $audioNames.Count $rend.Count)
  }
  # Choice: -PreferAudio match, else the first Russian track (some anime list 'Japan Original' first), else 0.
  $ai = -1
  if ($tracks.Count -gt 0) {
    $ai = Find-AudioIndex @($tracks | ForEach-Object { [string]$_.Name }) $PreferAudio
    if ($ai -lt 0) {
      if ($PreferAudio) { $w2 = (T 'dub ''{0}'' not offered by Collaps (has: {1})' $PreferAudio ((@($tracks | ForEach-Object { $_.Name })) -join ', ')); if ($warn) { $warn += '; ' + $w2 } else { $warn = $w2 } }
      foreach ($t in $tracks) { if ($t.Lang -eq 'ru') { $ai = $t.Index; break } }
      if ($ai -lt 0) { $ai = 0 }
    }
  }
  $audio = $null; if ($ai -ge 0) { $audio = [string]$tracks[$ai].Name }
  $best = $q[0]
  $map = @('-map', "0:p:$($best.Program):v:0")
  if ($ai -ge 0 -and $rend.Count -gt 0) { $map += @('-map', "0:p:$($best.Program):a:$ai") } else { $map += @('-map', "0:p:$($best.Program):a?") }
  return [pscustomobject]@{
    Source      = 'collaps'
    Url         = $hls
    Headers     = $headers
    Qualities   = $q
    Audio       = $audio
    AudioNames  = $audioNames
    AudioIndex  = $ai
    AudioTracks = @($tracks)
    FfmpegMap   = $map
    VideoUrl    = $best.Url
    AudioUrl    = $(if ($ai -ge 0 -and $rend.Count -gt 0) { $tracks[$ai].Url } else { $null })
    Subtitles   = $subs
    Title       = $title
    Duration    = $duration
    ExpiresUtc  = (Get-UrlExpiryUtc $hls)
    DashUrl     = $dash
    Warning     = $warn
    EmbedUrl    = $embedUrl
  }
}

# ==================================================================================================
# Dream Cast (dreamerscast.com): a voice-over team with its own site, catalogue and player
# ==================================================================================================
# Release page  https://dreamerscast.com/home/release/<id>-<slug>   (verified 2026-10-02)
#   <title>Russian title / Original title - Dream Cast</title>
#   function vlc() { ... atob("<plain base64>") ... }  -> the HLS master playlists of all its episodes, joined by "||||"
#   new Playerjs("#2<base64 with '//<junk base64>==' pieces mixed in>") -> {"file": "<dash> or <hls>"} for one video, or
#     {"file": [{"title": "Seriya 1", "file": "<dash> or <hls>", ...}, ...]}, in the same order as the vlc() list
#   HLS  https://play.dreamerscast.com/hls/<guid>/<guid>_,1080,720,low,aac,.mp4.urlset/master.m3u8
#        AV1 1080p / 720p / 480p + AAC in fMP4 segments; no Referer, cookies or tokens needed, the links don't expire.
# Catalogue search  POST https://dreamerscast.com/home   form: search=<text>&pageNumber=1&pageSize=16
#   -> {"releases":[{id, russian, original, type ("TV", "OVA/ONA", "Film" in Russian, "Special"), dateissue (year),
#       series (episodes out), currentSeries (episodes planned), url ("/home/release/88-povelitel-4-overlord-iv")}], "count"}
$script:DreamcastBase = 'https://dreamerscast.com'
$script:DreamcastPages = @{}      # release URL -> @{ At; Release } (pages read this session, kept 30 minutes)
$script:DreamcastMatch = @{}      # title key -> release URL ('' = not on Dream Cast)

function Test-DreamcastUrl([string]$u) { return ([string]$u -match '^(?i)https?://(?:www\.)?dreamerscast\.com/home/release/\d+') }

# PlayerJS "#2..." text -> its JSON (a Dictionary), $null when it can't be read.
function ConvertFrom-PlayerjsText([string]$s) {
  if (-not $s -or -not $s.StartsWith('#2')) { return $null }
  $b = [regex]::Replace($s.Substring(2), '//[A-Za-z0-9+/]{16,}?==', '')
  $b = $b.Replace('-', '+').Replace('_', '/')
  while ($b.Length % 4) { $b += '=' }
  try { return (ConvertFrom-JsonDict ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b)))) } catch { return $null }
}

# One release: Id, Url, Title (Russian), Original, Episodes (Number, Title, Url = its HLS master playlist).
function Get-DreamcastRelease([string]$url) {
  $m = [regex]::Match($url, '^(?i)https?://(?:www\.)?dreamerscast\.com(/home/release/\d+[^?#]*)')
  if (-not $m.Success) { throw "Dream Cast: not a release link: $url" }
  $url = $script:DreamcastBase + $m.Groups[1].Value
  $hit = $script:DreamcastPages[$url]
  if ($hit -and ((Get-Date) - $hit.At).TotalMinutes -lt 30) { return $hit.Release }
  $r = Invoke-Web -Url $url -Headers @{ 'Referer' = $script:DreamcastBase + '/home' } -TimeoutSec 20
  if ($r.Status -eq 404) { throw 'Dream Cast: 404 (no such release)' }
  if ($r.Status -ne 200) { throw "Dream Cast: the release page answered HTTP $($r.Status)" }
  $html = $r.Text
  $title = $null; $orig = $null
  $mt = [regex]::Match($html, '(?is)<title>(.*?)</title>')
  if ($mt.Success) {
    $t = (ConvertFrom-HtmlText $mt.Groups[1].Value).Trim() -replace '\s*-\s*Dream Cast\s*$', ''
    $i = $t.IndexOf(' / ')
    if ($i -gt 0) { $title = $t.Substring(0, $i).Trim(); $orig = $t.Substring($i + 3).Trim() } else { $title = $t }
  }
  # The playlists: vlc()'s plain list, else the PlayerJS config.
  $hls = @()
  $mv = [regex]::Match($html, 'function\s+vlc\s*\(\)\s*\{[^}]*?atob\("([A-Za-z0-9+/=]+)"\)')
  if ($mv.Success) {
    try { $hls = @(([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($mv.Groups[1].Value))) -split '\|\|\|\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^https?://' }) } catch {}
  }
  $files = @()
  $mp = [regex]::Match($html, 'new\s+Playerjs\(\s*"(#2[^"]+)"')
  if ($mp.Success) {
    $cfg = ConvertFrom-PlayerjsText $mp.Groups[1].Value
    if ($cfg -is [System.Collections.IDictionary] -and $cfg.ContainsKey('file')) {
      $f = $cfg['file']
      if ($f -is [string]) { $files = @(@{ title = ''; file = $f }) } else { $files = @($f | Where-Object { $_ -is [System.Collections.IDictionary] }) }
    }
  }
  $eps = New-Object System.Collections.ArrayList
  $n = [Math]::Max($hls.Count, $files.Count)
  for ($i = 0; $i -lt $n; $i++) {
    $u = $null; $et = ''
    if ($i -lt $hls.Count) { $u = $hls[$i] }
    if ($i -lt $files.Count) {
      $et = [string]$files[$i]['title']
      if (-not $u) { foreach ($p in ([string]$files[$i]['file'] -split '\s+or\s+')) { if ($p.Trim() -match '^https?://\S+\.m3u8') { $u = $p.Trim() } } }
    }
    if (-not $u) { continue }
    $num = [string]($eps.Count + 1)
    $me = [regex]::Match($et, '(\d+)')
    if ($me.Success -and $files.Count -gt 1) { $num = [string][int]$me.Groups[1].Value }
    [void]$eps.Add([pscustomobject]@{ Number = $num; Title = $et; Url = $u })
  }
  $rel = [pscustomobject]@{ Id = [regex]::Match($url, '/release/(\d+)').Groups[1].Value; Url = $url; Title = $title; Original = $orig; Episodes = $eps.ToArray() }
  $script:DreamcastPages[$url] = @{ At = (Get-Date); Release = $rel }
  return $rel
}

# The catalogue search's answer -> search rows (see Find-SiteContent), closest titles first.
function ConvertFrom-DreamcastSearch([string]$text, [string]$query) {
  $rows = @()
  $j = ConvertFrom-JsonDict $text
  if ($j -isnot [System.Collections.IDictionary]) { throw 'bad answer' }
  $qk = ConvertTo-SearchKey $query
  $scored = @()
  foreach ($x in @($j['releases'])) {
    if ($x -isnot [System.Collections.IDictionary]) { continue }
    $path = [string]$x['url']
    if ($path -notmatch '^/home/release/\d+') { continue }
    $rus = ([string]$x['russian']).Trim(); $orig = ([string]$x['original']).Trim()
    $title = $rus; if (-not $title) { $title = $orig }
    $type = [string]$x['type']
    $kind = $type
    if ($type -eq 'TV') { $kind = T 'series' }
    elseif ($type -match '^\u0424\u0438\u043b\u044c\u043c|(?i)^movie') { $kind = T 'film' }   # "Film" in Russian
    elseif ($type -match '(?i)special') { $kind = T 'special' }
    $out = ConvertTo-KodikInt $x['series']; $all = ConvertTo-KodikInt $x['currentSeries']
    $extra = ''
    if ($all -gt $out -and $out -gt 0) { $extra = T '{0} of {1} ep.' $out $all } elseif ($out -gt 1) { $extra = T '{0} ep.' $out }
    $r = New-SearchRow 'dreamcast' ([string]$x['id']) $title ([string]$x['dateissue']) $kind $extra ($script:DreamcastBase + $path) @($rus, $orig)
    # closest first: the same title, then one starting with what was typed, then the rest; shorter before longer
    $score = 3
    foreach ($k in @((ConvertTo-SearchKey $rus), (ConvertTo-SearchKey $orig))) {
      if (-not $k -or -not $qk) { continue }
      if ($k -eq $qk) { $score = [Math]::Min($score, 0) } elseif ($k.StartsWith($qk)) { $score = [Math]::Min($score, 1) } elseif ($k.Contains($qk)) { $score = [Math]::Min($score, 2) }
    }
    $scored += [pscustomobject]@{ Row = $r; Score = $score; Len = (ConvertTo-SearchKey $title).Length; Pos = $scored.Count }
  }
  foreach ($s in @($scored | Sort-Object Score, Len, Pos)) { $rows += $s.Row }
  return $rows
}

function Get-DreamcastSearchRequest([string]$query, [int]$timeoutSec) {
  return @{ Url = $script:DreamcastBase + '/home'; Method = 'POST'; Body = ('search=' + [Uri]::EscapeDataString($query) + '&pageNumber=1&pageSize=16')
    ContentType = 'application/x-www-form-urlencoded; charset=UTF-8'; Headers = @{ 'Referer' = $script:DreamcastBase + '/home'; 'X-Requested-With' = 'XMLHttpRequest'; 'Accept' = 'application/json' }
    TimeoutSec = $timeoutSec }
}

# The Dream Cast release of a show, by one of its titles (Russian or original, exactly). Returns its URL or $null.
function Find-DreamcastRelease($names) {
  foreach ($n in @($names)) {
    $key = ConvertTo-SearchKey ([string]$n)
    if ($key.Length -lt 2) { continue }
    if (-not $script:DreamcastMatch.ContainsKey($key)) {
      $found = ''
      try {
        $q = Get-DreamcastSearchRequest ([string]$n).Trim() 10
        $r = Invoke-Web @q
        if ($r.Status -eq 200) {
          foreach ($row in @(ConvertFrom-DreamcastSearch $r.Text ([string]$n))) {
            if (@($row.Names | Where-Object { (ConvertTo-SearchKey $_) -eq $key }).Count -gt 0) { $found = $row.Link; break }
          }
        } else { continue }   # (not remembered: it may answer next time)
      } catch { continue }
      $script:DreamcastMatch[$key] = $found
    }
    if ($script:DreamcastMatch[$key]) { return $script:DreamcastMatch[$key] }
  }
  return $null
}

# The HLS playlist of episode $episode of a release (0 = a film / the only video), $null when it hasn't got it.
function Get-DreamcastEpisodeUrl([string]$releaseUrl, [int]$episode) {
  $eps = @((Get-DreamcastRelease $releaseUrl).Episodes)
  if ($episode -le 0) { if ($eps.Count -eq 1) { return $eps[0].Url }; return $null }
  foreach ($e in $eps) { if ([string]$e.Number -eq [string]$episode) { return $e.Url } }
  return $null
}

# "Overlord [TV-4]" (a Kodik part title) -> "Overlord 4", "Overlord [TV-1]" -> "Overlord": how Dream Cast names seasons.
function ConvertFrom-KodikPartTitle([string]$t) {
  $m = [regex]::Match([string]$t, '\s*' + $script:WpSeasonRx)
  if (-not $m.Success) { return ([string]$t).Trim() }
  $base = $t.Remove($m.Index, $m.Length).Trim()
  if ([int]$m.Groups[1].Value -le 1) { return $base }
  return ($base + ' ' + $m.Groups[1].Value)
}

# ------------------------------------------------------------------ APIs with several addresses (mirrors)
# One API call on a list of hosts: the one that answered last first, then the others in order. A host counts as
# answering when it sends JSON (404 included: the host works, the thing isn't there). $state: a hashtable that keeps
# .Good (the host that answered last). $skip: a host already tried. Returns Invoke-Web's answer; throws when none answers.
function Invoke-MirrorApi($hosts, $state, [string]$path, [string]$method = 'GET', [string]$body = $null, [int]$timeoutSec = 15, [string]$skip = $null) {
  $list = @($hosts)
  if ($state.Good) { $list = @($state.Good) + @($list | Where-Object { $_ -ne $state.Good }) }
  if ($skip) { $list = @($list | Where-Object { $_ -ne $skip }) }
  $last = 'no address to try'
  foreach ($h in $list) {
    try {
      $q = @{ Url = $h + $path; Method = $method; Headers = @{ 'Accept' = 'application/json' }; TimeoutSec = $timeoutSec }
      if ($method -ne 'GET') { $q.Body = $body; $q.ContentType = 'application/x-www-form-urlencoded; charset=UTF-8' }
      $r = Invoke-Web @q
      $t = ([string]$r.Text).TrimStart()
      if (($r.Status -eq 200 -or $r.Status -eq 404) -and ($t.StartsWith('{') -or $t.StartsWith('['))) { $state.Good = $h; return $r }
      $last = "HTTP $($r.Status)"
    } catch { $e = $_.Exception; if ($e.InnerException) { $e = $e.InnerException }; $last = $e.Message }
  }
  throw $last
}

function Get-MirrorHost($hosts, $state) { if ($state.Good) { return $state.Good }; return @($hosts)[0] }

# A JSON answer that is a list -> that list, kept whole (returned as is, PowerShell would turn a list of one into the
# item and an empty one into $null). $null when the answer isn't a list.
function ConvertFrom-JsonList([string]$text) {
  $t = ([string]$text).Trim()
  if (-not $t.StartsWith('[')) { return $null }
  $j = ConvertFrom-JsonDict ('{"list":' + $t + '}')
  if ($j -isnot [System.Collections.IDictionary]) { return $null }
  return , @($j['list'])
}

# Search rows of one source, closest titles first: the same title, then one starting with what was typed, then one
# containing it, then the rest; shorter before longer, else the source's order.
function Sort-SearchRows($rows, [string]$query) {
  $qk = ConvertTo-SearchKey $query
  $scored = @()
  foreach ($r in @($rows)) {
    $score = 3
    foreach ($k in @($r.Names | ForEach-Object { ConvertTo-SearchKey $_ })) {
      if (-not $k -or -not $qk) { continue }
      if ($k -eq $qk) { $score = [Math]::Min($score, 0) } elseif ($k.StartsWith($qk)) { $score = [Math]::Min($score, 1) } elseif ($k.Contains($qk)) { $score = [Math]::Min($score, 2) }
    }
    $scored += [pscustomobject]@{ Row = $r; Score = $score; Len = (ConvertTo-SearchKey ([string]$r.Title)).Length; Pos = $scored.Count }
  }
  return @($scored | Sort-Object Score, Len, Pos | ForEach-Object { $_.Row })
}

# ==================================================================================================
# AniLiberty (the former AniLibria): its own voice-overs, HLS up to 1080p, a free JSON API (checked 2026-10-03)
# ==================================================================================================
# Search   GET <api>/api/v1/app/search/releases?query=<text>  -> [{id, alias, year, type{value: TV|MOVIE|...},
#            name{main (Russian), english}, episodes_total (null = only announced), is_ongoing, shikimori{id}}]
#            (every hit: there is no limit parameter)
# Release  GET <api>/api/v1/anime/releases/<alias or id>  -> {id, alias, name, year, is_blocked_by_geo,
#            is_blocked_by_copyrights, external_player ("//aniqit.com/serial/..." = the same release on Kodik),
#            shikimori{id}, episodes:[{ordinal, name, duration (s), hls_480, hls_720, hls_1080}]}
#   Each hls_* is one quality's playlist (H.264 + AAC in MPEG-TS, 23.976 fps) on cache.libria.fun; no Referer, cookies
#   or tokens needed. The "isWithVideoAds" in their query adds nothing to the playlist (no ad segments, checked).
# The release link the tool hands out (search rows) and understands: https://anilibria.top/anime/releases/release/<alias>
# (aniliberty.top, the old anilibria.tv/release/<alias>.html links too). The API answers on all three hosts below.
$script:AnilibertyHosts = @('https://anilibria.top', 'https://aniliberty.top', 'https://api.anilibria.app')
$script:AnilibertyState = @{ Good = $null }
$script:AnilibertySite = 'https://anilibria.top'
$script:AnilibertyReleases = @{}   # alias -> @{ At; Release } (read this session, kept 30 minutes)
$script:AnilibertyLinkRe = '^(?i)https?://(?:www\.)?(?:anilibria\.(?:top|tv|wtf)|aniliberty\.top)/(?:anime/releases/release|release)/([a-z0-9][a-z0-9-]*)'

function Test-AnilibertyUrl([string]$u) { return ([string]$u -match $script:AnilibertyLinkRe) }

# One release: Id, Alias, Url, Title, English, Year, ShikiId, Kodik (the same release on Kodik, '' when none), Blocked,
# Episodes (Number, Title, Url = the playlist of the quality that fits best now, Hls = height -> playlist, Duration).
function Get-AnilibertyRelease([string]$alias) {
  $alias = $alias.ToLowerInvariant()
  $hit = $script:AnilibertyReleases[$alias]
  if ($hit -and ((Get-Date) - $hit.At).TotalMinutes -lt 30) { return $hit.Release }
  $r = Invoke-MirrorApi $script:AnilibertyHosts $script:AnilibertyState ('/api/v1/anime/releases/' + [Uri]::EscapeDataString($alias)) 'GET' $null 20
  if ($r.Status -eq 404) { throw 'AniLiberty: 404 (no such release)' }
  $j = ConvertFrom-JsonDict $r.Text
  if ($j -isnot [System.Collections.IDictionary]) { throw 'AniLiberty: unexpected answer' }
  $title = ''; $eng = ''
  $name = $j['name']
  if ($name -is [System.Collections.IDictionary]) { $title = ([string]$name['main']).Trim(); $eng = ([string]$name['english']).Trim() }
  $sid = ''
  if ($j['shikimori'] -is [System.Collections.IDictionary]) { $sid = [string]$j['shikimori']['id'] }
  $kodik = ''
  $ext = ([string]$j['external_player']).Trim()
  if ($ext.StartsWith('//')) { $ext = 'https:' + $ext }
  if ($ext -and (Test-KodikUrl $ext)) { $kodik = $ext }
  $eps = New-Object System.Collections.ArrayList
  foreach ($e in @($j['episodes'])) {
    if ($e -isnot [System.Collections.IDictionary]) { continue }
    $hls = @{}
    foreach ($h in @(480, 720, 1080)) { $u = [string]$e["hls_$h"]; if ($u -match '^https://') { $hls[$h] = $u } }
    if ($hls.Count -eq 0) { continue }
    $num = [string]$e['ordinal']   # 1, 2, ... (12.5 for a recap between two episodes)
    if ($num -notmatch '^\d+(\.\d+)?$') { $num = [string]($eps.Count + 1) }
    $dur = 0.0
    try { $dur = [double]$e['duration'] } catch {}
    [void]$eps.Add([pscustomobject]@{ Number = $num; Title = ([string]$e['name']).Trim(); Hls = $hls; Url = (Select-AnilibertyHls $hls (Get-QualityCap)); Duration = $dur })
  }
  $rel = [pscustomobject]@{
    Id = [string]$j['id']; Alias = $alias; Url = ($script:AnilibertySite + '/anime/releases/release/' + $alias)
    Title = $title; English = $eng; Year = [string]$j['year']; ShikiId = $sid; Kodik = $kodik
    Blocked = ([bool]$j['is_blocked_by_geo'] -or [bool]$j['is_blocked_by_copyrights']); Episodes = $eps.ToArray()
  }
  $script:AnilibertyReleases[$alias] = @{ At = (Get-Date); Release = $rel }
  return $rel
}

# The playlist to fetch: the tallest one not taller than $cap, else the smallest there is.
function Select-AnilibertyHls($hls, [int]$cap) {
  foreach ($h in @(1080, 720, 480)) { if ($h -le $cap -and $hls.ContainsKey($h)) { return $hls[$h] } }
  foreach ($h in @(480, 720, 1080)) { if ($hls.ContainsKey($h)) { return $hls[$h] } }
  return $null
}

function Expand-Aniliberty([string]$u) {
  $canAsk = Test-CanAsk
  $alias = [regex]::Match($u, $script:AnilibertyLinkRe).Groups[1].Value
  if ($canAsk) { Say (T 'Reading the AniLiberty release...') 'Gray' }
  $r = $null
  try { $r = Get-AnilibertyRelease $alias }
  catch {
    if ($_.Exception.Message -match '404') { throw (T 'AniLiberty has no such release (check the link)') }
    throw (T 'AniLiberty didn''t answer ({0})' (Get-ShortText $_.Exception.Message 100))
  }
  if ($r.Blocked) { throw (T 'AniLiberty has taken this release down (the right holder asked, or it is blocked in your country)') }
  $eps = @($r.Episodes)
  if ($eps.Count -eq 0) { throw (T 'AniLiberty hasn''t put up any episodes of it yet') }
  $title = $r.Title
  if (-not $title) { $title = $r.English }
  if (-not $title) { $title = "AniLiberty $($r.Alias)" }
  if ($canAsk) {
    Say ''
    if ($eps.Count -eq 1) { Say (T 'Found on AniLiberty: {0}' $title) 'White' } else { Say (T 'Found on AniLiberty: {0} ({1} episodes)' $title $eps.Count) 'White' }
  }
  $startPos = 0
  $want = [regex]::Match($u, '#episode=([\d.]+)')
  if ($want.Success) { for ($i = 0; $i -lt $eps.Count; $i++) { if ($eps[$i].Number -eq $want.Groups[1].Value) { $startPos = $i } } }
  $list = @(Select-SiteEpisodes $eps $startPos $canAsk)
  $kodikSerial = ($r.Kodik -match '(?i)//[^/]+/serial/')
  $items = New-Object System.Collections.ArrayList
  foreach ($e in $list) {
    $c = New-Cand 'aniliberty' $e.Url '' 'AniLibria'
    $c | Add-Member -NotePropertyName Hls -NotePropertyValue $e.Hls
    $c | Add-Member -NotePropertyName Duration -NotePropertyValue $e.Duration
    $cands = @($c)
    # The same release on Kodik (AniLiberty names it itself): a backup when its own server doesn't answer.
    if ($r.Kodik -and $kodikSerial -and $e.Number -match '^\d+$') {
      $k = New-Cand 'kodik' $r.Kodik '' 'AniLibria'
      $k.Episode = [int]$e.Number
      $cands += $k
    } elseif ($r.Kodik -and -not $kodikSerial -and $eps.Count -eq 1) {
      $cands += (New-Cand 'kodik' $r.Kodik '' 'AniLibria')
    }
    $site = [pscustomobject]@{ Type = 'player'; Cands = $cands }
    $name = $title
    if ($eps.Count -gt 1) { $name = (T '{0} - episode {1}' $title $e.Number) }
    [void]$items.Add((New-SiteItem ($r.Url + '#episode=' + $e.Number) $name $site))
  }
  if ($script:SiteChoice -and $items.Count -gt 0) { $items[0].ResumeAt = $script:SiteChoice.Start }
  return $items.ToArray()
}

function Get-AnilibertySearchRequest([string]$query, [int]$timeoutSec) {
  return @{ Url = (Get-MirrorHost $script:AnilibertyHosts $script:AnilibertyState) + (Get-AnilibertySearchPath $query); Headers = @{ 'Accept' = 'application/json' }; TimeoutSec = $timeoutSec }
}

function Get-AnilibertySearchPath([string]$query) { return '/api/v1/app/search/releases?query=' + [Uri]::EscapeDataString($query) }

function ConvertFrom-AnilibertySearch([string]$text, [string]$query) {
  $d = ConvertFrom-JsonList $text
  if ($null -eq $d) {
    $j = ConvertFrom-JsonDict $text
    if ($j -isnot [System.Collections.IDictionary] -or -not $j.ContainsKey('data')) { throw 'bad answer' }
    $d = @($j['data'])
  }
  $rows = @()
  foreach ($x in $d) {
    if ($x -isnot [System.Collections.IDictionary]) { continue }
    $alias = ([string]$x['alias']).ToLowerInvariant()
    if ($alias -notmatch '^[a-z0-9][a-z0-9-]*$') { continue }
    $total = $x['episodes_total']
    if ($null -eq $total -and -not $x['is_ongoing']) { continue }   # only announced: nothing to watch yet
    $rus = ''; $eng = ''
    if ($x['name'] -is [System.Collections.IDictionary]) { $rus = ([string]$x['name']['main']).Trim(); $eng = ([string]$x['name']['english']).Trim() }
    $title = $rus; if (-not $title) { $title = $eng }
    if (-not $title) { continue }
    $type = ''
    if ($x['type'] -is [System.Collections.IDictionary]) { $type = [string]$x['type']['value'] }
    $kind = $type
    if ($type -eq 'TV') { $kind = T 'series' } elseif ($type -eq 'MOVIE') { $kind = T 'film' } elseif ($type -match '(?i)special') { $kind = T 'special' }
    $n = ConvertTo-KodikInt $total
    $extra = ''
    if ($n -gt 1) { $extra = T '{0} ep.' $n }
    $r = New-SearchRow 'aniliberty' $alias $title ([string]$x['year']) $kind $extra ($script:AnilibertySite + '/anime/releases/release/' + $alias) @($rus, $eng)
    if ($x['shikimori'] -is [System.Collections.IDictionary]) { $sid = [string]$x['shikimori']['id']; if ($sid -match '^\d+$') { $r.ShikiId = $sid } }
    $rows += $r
  }
  return @(Sort-SearchRows $rows $query)
}

# ==================================================================================================
# AnimeVost: its own voice-overs, plain MP4 files, a free JSON API (checked 2026-10-03)
# ==================================================================================================
# Search    POST <api>/v1/search    form name=<text>  -> {state, data:[{id, title ("Russian / English [1-24 of 24]",
#             in Russian), year (text), type ("TV" in Russian, "OVA", ...)}]}; nothing found = HTTP 404 {"error": ...}
# Info      POST <api>/v1/info      form id=<id>      -> the same shape, one item
# Playlist  POST <api>/v1/playlist  form id=<id>      -> [{name ("1 seriya" in Russian), hd, std, preview}]
#   hd (http://video.animetop.info/720/<file>.mp4) is listed for every episode but not always there (404): then std
#   (http://video.animetop.info/<file>.mp4, 480p). Plain files: Range requests work, no headers needed.
# The link the tool hands out and understands: https://animevost.org/tip/tv/<id>-<slug>.html
$script:AnimevostHosts = @('https://api.animetop.info', 'https://api.animevost.org')
$script:AnimevostState = @{ Good = $null }
$script:AnimevostSite = 'https://animevost.org'
$script:AnimevostLinkRe = '^(?i)https?://(?:www\.)?(?:animevost\.(?:org|am)|v\d+\.vost\.pw)/tip/[a-z-]+/(\d+)-'

function Test-AnimevostUrl([string]$u) { return ([string]$u -match $script:AnimevostLinkRe) }

# "Naruto (Russian) / Naruto [1-220 of 220]" -> Rus, Eng, Out (episodes out), All (planned, 0 = not said)
function Split-AnimevostTitle([string]$t) {
  $t = ([string]$t).Trim()
  $out = 0; $all = 0
  $m = [regex]::Match($t, '\s*\[([^\]]*)\]\s*$')
  if ($m.Success) {
    $t = $t.Remove($m.Index).Trim()
    $b = $m.Groups[1].Value
    $nums = @([regex]::Matches($b, '\d+') | ForEach-Object { [int]$_.Value })
    $o = 0; if ($b -match '^\s*\d+\s*-\s*\d+') { $o = 1 }   # "1-12 of 24": 12 out; "1 of 12": 1 out
    if ($nums.Count -gt $o) { $out = $nums[$o] }
    if ($nums.Count -gt $o + 1) { $all = $nums[$o + 1] }
  }
  $rus = $t; $eng = ''
  $i = $t.IndexOf(' / ')
  if ($i -gt 0) { $rus = $t.Substring(0, $i).Trim(); $eng = $t.Substring($i + 3).Trim() }
  return [pscustomobject]@{ Rus = $rus; Eng = $eng; Out = $out; All = $all }
}

function Get-AnimevostLink([string]$id, [string]$eng) {
  $slug = ([regex]::Replace(([string]$eng).ToLowerInvariant(), '[^a-z0-9]+', '-')).Trim('-')
  if ($slug.Length -gt 60) { $slug = $slug.Substring(0, 60).Trim('-') }
  if (-not $slug) { $slug = 'anime' }
  return $script:AnimevostSite + '/tip/tv/' + $id + '-' + $slug + '.html'
}

function Get-AnimevostSearchRequest([string]$query, [int]$timeoutSec) {
  return @{ Url = (Get-MirrorHost $script:AnimevostHosts $script:AnimevostState) + '/v1/search'; Method = 'POST'; Body = ('name=' + [Uri]::EscapeDataString($query))
    ContentType = 'application/x-www-form-urlencoded; charset=UTF-8'; Headers = @{ 'Accept' = 'application/json' }; TimeoutSec = $timeoutSec }
}

function ConvertFrom-AnimevostSearch([string]$text, [string]$query) {
  $j = ConvertFrom-JsonDict $text
  if ($j -isnot [System.Collections.IDictionary]) { throw 'bad answer' }
  if (-not $j.ContainsKey('data')) { if ($j.ContainsKey('error')) { return @() }; throw 'bad answer' }   # (nothing found)
  $tv = [string][char]0x0422 + [char]0x0412   # "TV" in Russian
  $rows = @()
  foreach ($x in @($j['data'])) {
    if ($x -isnot [System.Collections.IDictionary]) { continue }
    $id = [string]$x['id']
    if ($id -notmatch '^\d+$') { continue }
    $t = Split-AnimevostTitle ([string]$x['title'])
    $title = $t.Rus; if (-not $title) { $title = $t.Eng }
    if (-not $title) { continue }
    $type = ([string]$x['type']).Trim()
    $kind = $type
    if ($type -eq $tv -or $type -eq 'TV') { $kind = T 'series' } elseif ($type -match '(?i)special') { $kind = T 'special' }
    $extra = ''
    if ($t.All -gt $t.Out -and $t.Out -gt 0) { $extra = T '{0} of {1} ep.' $t.Out $t.All } elseif ($t.Out -gt 1) { $extra = T '{0} ep.' $t.Out }
    $rows += New-SearchRow 'animevost' $id $title ([string]$x['year']) $kind $extra (Get-AnimevostLink $id $t.Eng) @($t.Rus, $t.Eng)
  }
  return @(Sort-SearchRows $rows $query)
}

# One title: Id, Title, Episodes (Number, Title, Hd, Std), in episode order.
function Get-AnimevostRelease([string]$id) {
  $info = Invoke-MirrorApi $script:AnimevostHosts $script:AnimevostState '/v1/info' 'POST' ('id=' + $id) 15
  $title = ''
  if ($info.Status -eq 200) {
    $j = ConvertFrom-JsonDict $info.Text
    if ($j -is [System.Collections.IDictionary] -and $j['data']) {
      $x = @($j['data'])[0]
      if ($x -is [System.Collections.IDictionary]) { $t = Split-AnimevostTitle ([string]$x['title']); $title = $t.Rus; if (-not $title) { $title = $t.Eng } }
    }
  }
  $pl = Invoke-MirrorApi $script:AnimevostHosts $script:AnimevostState '/v1/playlist' 'POST' ('id=' + $id) 15
  if ($pl.Status -eq 404) { throw 'AnimeVost: 404 (no such title)' }
  $d = ConvertFrom-JsonList $pl.Text
  if ($null -eq $d) { throw 'AnimeVost: unexpected answer' }
  $eps = @()
  foreach ($e in $d) {
    if ($e -isnot [System.Collections.IDictionary]) { continue }
    $hd = [string]$e['hd']; $std = [string]$e['std']
    if ($hd -notmatch '^https?://') { $hd = '' }
    if ($std -notmatch '^https?://') { $std = '' }
    if (-not $hd -and -not $std) { continue }
    $nm = ([string]$e['name']).Trim()
    $m = [regex]::Match($nm, '^\s*(\d+)')
    $n = 0; if ($m.Success) { $n = [int]$m.Groups[1].Value }
    $eps += [pscustomobject]@{ N = $n; Pos = $eps.Count; Title = $nm; Hd = $hd; Std = $std }
  }
  # Numbered episodes in order, then the rest (an OVA, a film) as listed; Number = the episode's own number when it has
  # one, else its place in the list.
  $sorted = @(@($eps | Where-Object { $_.N -gt 0 } | Sort-Object N, Pos) + @($eps | Where-Object { $_.N -le 0 } | Sort-Object Pos))
  $out = New-Object System.Collections.ArrayList
  $used = @{}
  foreach ($e in $sorted) {
    $num = [string]$e.N
    if ($e.N -le 0 -or $used.ContainsKey($num)) { $k = $out.Count + 1; while ($used.ContainsKey([string]$k)) { $k++ }; $num = [string]$k }
    $used[$num] = $true
    [void]$out.Add([pscustomobject]@{ Number = $num; Title = $e.Title; Hd = $e.Hd; Std = $e.Std })
  }
  return [pscustomobject]@{ Id = $id; Title = $title; Episodes = $out.ToArray() }
}

function Expand-Animevost([string]$u) {
  $canAsk = Test-CanAsk
  $id = [regex]::Match($u, $script:AnimevostLinkRe).Groups[1].Value
  if ($canAsk) { Say (T 'Reading AnimeVost...') 'Gray' }
  $r = $null
  try { $r = Get-AnimevostRelease $id }
  catch {
    if ($_.Exception.Message -match '404') { throw (T 'AnimeVost has no such title (check the link)') }
    throw (T 'AnimeVost didn''t answer ({0})' (Get-ShortText $_.Exception.Message 100))
  }
  $eps = @($r.Episodes)
  if ($eps.Count -eq 0) { throw (T 'AnimeVost hasn''t put up any episodes of it yet') }
  $title = $r.Title
  if (-not $title) { $title = "AnimeVost $id" }
  if ($canAsk) {
    Say ''
    if ($eps.Count -eq 1) { Say (T 'Found on AnimeVost: {0}' $title) 'White' } else { Say (T 'Found on AnimeVost: {0} ({1} episodes)' $title $eps.Count) 'White' }
  }
  $startPos = 0
  $want = [regex]::Match($u, '#episode=(\d+)')
  if ($want.Success) { for ($i = 0; $i -lt $eps.Count; $i++) { if ($eps[$i].Number -eq $want.Groups[1].Value) { $startPos = $i } } }
  $list = @(Select-SiteEpisodes $eps $startPos $canAsk)
  $base = $script:AnimevostSite + '/tip/tv/' + $id + '-anime.html'   # (the same key whichever link form was given)
  $items = New-Object System.Collections.ArrayList
  foreach ($e in $list) {
    $url = $e.Hd; if (-not $url) { $url = $e.Std }
    $c = New-Cand 'animevost' $url '' 'AnimeVost'
    $c | Add-Member -NotePropertyName Std -NotePropertyValue $e.Std
    $site = [pscustomobject]@{ Type = 'player'; Cands = @($c) }
    $name = $title
    if ($eps.Count -gt 1) { $name = (T '{0} - episode {1}' $title $e.Number) }
    [void]$items.Add((New-SiteItem ($base + '#episode=' + $e.Number) $name $site))
  }
  if ($script:SiteChoice -and $items.Count -gt 0) { $items[0].ResumeAt = $script:SiteChoice.Start }
  return $items.ToArray()
}

# Is a file there? (HEAD, so nothing is downloaded.) $false when it isn't or the server doesn't answer.
function Test-WebFileThere([string]$url) {
  try { $r = Invoke-Web -Url $url -Method 'HEAD' -TimeoutSec 8; return ($r.Status -eq 200 -or $r.Status -eq 206) } catch { return $false }
}

# ==================================================================================================
# Glue: links -> queue items -> possible sources -> a stream ffmpeg can open
# ==================================================================================================
# A queue item of kind 'site' carries .Site (what to play) and gets a list of "candidates" (player links
# that could play it, best first) when it is prepared. Start-NextSource in VRChatLinkMaker.ps1 tries them in
# order with Resolve-Candidate until one works.

$script:ProviderRank = @{ 'dreamcast' = 0; 'kodik' = 1; 'alloha' = 1; 'aniliberty' = 1; 'cvh' = 2; 'aniboom' = 3; 'animevost' = 3; 'sibnet' = 4 }
$script:ProviderNames = @{ 'kodik' = 'Kodik'; 'aniboom' = 'AniBoom'; 'cvh' = 'CVH'; 'sibnet' = 'Sibnet'; 'alloha' = 'Alloha'; 'collaps' = 'Collaps'; 'animelib' = 'AnimeLib'; 'dreamcast' = 'Dream Cast'; 'aniliberty' = 'AniLiberty'; 'animevost' = 'AnimeVost' }

function Get-ProviderRank([string]$p) { if ($script:ProviderRank.ContainsKey($p)) { return $script:ProviderRank[$p] } return 99 }
function Get-ProviderTitle([string]$p) { if ($script:ProviderNames.ContainsKey($p)) { return $script:ProviderNames[$p] } return $p }

function Test-SiteLink([string]$u) {
  $u = (Split-SiteChoice $u)[0]
  if ($u -match '^(?i)https?://(?:www\.)?animego\.[a-z]{2,10}/anime/') { return $true }
  if (Test-DreamcastUrl $u) { return $true }
  if (Test-AnilibertyUrl $u) { return $true }
  if (Test-AnimevostUrl $u) { return $true }
  if (Test-AnimelibUrl $u) { return $true }
  if (Test-WpartyUrl $u) { return $true }
  if (Test-KodikUrl $u) { return $true }
  if (Test-AniboomUrl $u) { return $true }
  if ($u -match '^(?i)https?://video\.sibnet\.ru/(?:shell\.php\?videoid=\d+|video\d+)') { return $true }
  if ($u -match $script:KinopoiskLinkRe) { return $true }   # also what the title search hands out
  if ($u -match $script:ShikimoriLinkRe) { return $true }
  return $false
}

function New-Cand([string]$provider, [string]$url, [string]$referer, [string]$dub) {
  $label = Get-ProviderTitle $provider
  if ($dub) { $label += ", $dub" }
  return [pscustomobject]@{ Provider = $provider; Url = $url; Referer = $referer; Dub = $dub; Label = $label; Note = $null; Season = 0; Episode = 0; LiveOnly = ($provider -eq 'alloha') }
}

# Two dub names mean the same group? ("AniLibria" / "AniLibria.TV" / "AnilibriaTV", "SV-Dubl" / "SV dubl", ...)
# A group's subtitled release is not the same as its voice-over.
function Test-SameDub([string]$a, [string]$b) {
  if (-not $a -or -not $b) { return $false }
  $ka = ConvertTo-WpTitleKey $a
  $kb = ConvertTo-WpTitleKey $b
  if ($ka.Subs -ne $kb.Subs) { return $false }
  if ($ka.Core -eq $kb.Core -or $ka.Full -eq $kb.Full) { return $true }
  # "AnilibriaTV" (CVH) = "Anilibria" (Alloha)
  $fa = $ka.Full -replace 'tv$', ''; $fb = $kb.Full -replace 'tv$', ''
  return ($fa.Length -ge 4 -and $fa -eq $fb)
}

# Position of voice-over $dub among $names (the same group under another spelling counts), -1 when it isn't there.
function Find-DubIndex($names, [string]$dub) {
  $names = @($names)
  if (-not $dub) { return -1 }
  for ($i = 0; $i -lt $names.Count; $i++) { if ([string]$names[$i] -eq $dub) { return $i } }
  for ($i = 0; $i -lt $names.Count; $i++) { if (Test-SameDub ([string]$names[$i]) $dub) { return $i } }
  return -1
}

# ------------------------------------------------------------------ which voice-over is taken without asking
# "DubPriority" in config.json: the preferred voice-overs, best first. The question lists them at the top, and the first
# one a show has is what just Enter (or a queue nobody is asked about) takes. "official" stands for any official (studio)
# dub. Default: Dream Cast, then AniLibria, then an official dub. [] = no preference (the site's order).
$script:DubPriorityDefault = @('Dream Cast', 'AniLibria', 'official')
# official dubs: "dubbed" / "dubbing" / "official" (Russian), and the studios that make the licensed Russian dubs
$script:OfficialDubRx = '(?i)\u0434\u0443\u0431\u043b\u0438\u0440|\u0434\u0443\u0431\u043b\u044f\u0436|\u043e\u0444\u0438\u0446\u0438\u0430\u043b\u044c\u043d|official|reanimedia|wakanim|\u043f\u0438\u0444\u0430\u0433\u043e\u0440|pifagor|sdi media|iyuno|\u043a\u0438\u0440\u0438\u043b\u043b\u0438\u0446\u0430|netflix|crunchyroll'

function Get-DubPriority {
  $p = $null
  if ($script:Cfg) { $p = $script:Cfg.PSObject.Properties['DubPriority'] }   # (not Get-Prop: it would turn [] into $null)
  if (-not $p -or $null -eq $p.Value) { return $script:DubPriorityDefault }
  $v = $p.Value
  if ($v -is [string]) { return @($v -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
  return @($v | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
}

# Is voice-over $name the one a DubPriority entry means? (Never a subtitled release.)
function Test-DubRule([string]$name, [string]$rule) {
  if (-not $name -or -not $rule) { return $false }
  $k = ConvertTo-WpTitleKey $name
  if ($k.Subs) { return $false }
  if ($rule -match '^(?i)official$') { return ($name -match $script:OfficialDubRx) }
  if (Test-SameDub $name $rule) { return $true }
  $r = (ConvertTo-WpTitleKey $rule).Full
  return ($r.Length -ge 5 -and $k.Full.Contains($r))
}

# The voice-over DubPriority picks among $names: its position, or -1 when none of them is in the list.
function Find-PriorityDub($names) {
  $names = @($names)
  foreach ($rule in @(Get-DubPriority)) {
    for ($i = 0; $i -lt $names.Count; $i++) { if (Test-DubRule ([string]$names[$i]) $rule) { return $i } }
  }
  return -1
}

# Adds a candidate to a list that gets sorted by: has the chosen voice-over (Same 0) first, then the player's rank,
# then the order they were added in.
function Add-RankedCand($list, $c, [int]$same = 0) {
  [void]$list.Add([pscustomobject]@{ C = $c; Same = $same; Rank = (Get-ProviderRank $c.Provider); Pos = $list.Count })
}

function Get-RankedCands($list) { return @($list | Sort-Object Same, Rank, Pos | ForEach-Object { $_.C }) }

# Alloha refused this PC (it blocks addresses that read too much): don't ask it again for a while.
$script:AllohaBlockedUntil = [datetime]::MinValue

function ConvertTo-HeaderTable($h) {
  $t = @{}
  if ($h) { foreach ($k in @($h.Keys)) { $t[[string]$k] = [string]$h[$k] } }
  return $t
}

# The highest quality worth fetching: the smallest common one at least as tall as what we send.
function Get-QualityCap {
  if ($script:OutH -le 480) { return 480 }
  if ($script:OutH -le 720) { return 720 }
  return 1080
}

# Asks a yes/no question (Enter = yes). Without a person to ask, the answer is yes.
function Read-YesNo([string]$q) {
  if (-not (Test-CanAsk)) { return $true }
  return (Read-YesNoUi (T '{0} [Y/n]' $q) $true)
}

# ------------------------------------------------------------------ choices (asked here, or handed over by a second window)
# While a stream runs, its window can't ask questions. A series link dropped on the .bat is set up in that second
# window instead (it can ask), then handed over with the answers attached:
#   <link>#vrclm=dub=<name>&eps=<1,2,3>&start=<seconds>&part=<season or part id>&player=<auto or a player's name>
$script:SiteChoice = $null
$script:LastDub = $null
$script:LastEps = $null
$script:LastPart = $null
$script:LastPlayer = $null
$script:MaxUnasked = 25

function Split-SiteChoice([string]$u) {
  $i = $u.IndexOf('#vrclm=')
  if ($i -lt 0) { return @($u, $null) }
  $c = [pscustomobject]@{ Dub = $null; Eps = $null; Start = 0.0; Part = $null; Player = $null }
  foreach ($kv in ($u.Substring($i + 7) -split '&')) {
    $p = $kv.Split([char[]]'=', 2)
    if ($p.Count -lt 2) { continue }
    $v = [Uri]::UnescapeDataString($p[1])
    if ($p[0] -eq 'dub') { $c.Dub = $v }
    elseif ($p[0] -eq 'eps') { $c.Eps = @($v -split ',' | Where-Object { $_ }) }
    elseif ($p[0] -eq 'part') { $c.Part = $v }
    elseif ($p[0] -eq 'player' -and $v -match '^[a-z]+$') { $c.Player = $v }
    elseif ($p[0] -eq 'start') { $n = 0.0; if ([double]::TryParse($v, [System.Globalization.NumberStyles]::Float, $script:Inv, [ref]$n)) { $c.Start = $n } }
  }
  return @($u.Substring(0, $i), $c)
}

# The answers given for the last link, as text to hand over (empty when nothing was chosen).
function Get-SiteChoiceText($items) {
  $parts = @()
  if ($script:LastDub) { $parts += 'dub=' + [Uri]::EscapeDataString($script:LastDub) }
  if ($script:LastEps) { $parts += 'eps=' + [Uri]::EscapeDataString((@($script:LastEps) -join ',')) }
  if ($script:LastPart) { $parts += 'part=' + [Uri]::EscapeDataString($script:LastPart) }
  if ($script:LastPlayer) { $parts += 'player=' + $script:LastPlayer }
  if (@($items).Count -gt 0 -and $items[0].ResumeAt -gt 0) { $parts += 'start=' + [int]$items[0].ResumeAt }
  return ($parts -join '&')
}

# The voice-overs in the order the list shows them: $first, then the DubPriority ones (in that order), then the rest
# as the site lists them. Returns their positions in $names.
function Get-DubOrder($names, [int]$first) {
  $names = @($names)
  $order = New-Object System.Collections.Generic.List[int]
  if ($first -ge 0 -and $first -lt $names.Count) { $order.Add($first) }
  foreach ($rule in @(Get-DubPriority)) {
    for ($i = 0; $i -lt $names.Count; $i++) { if (-not $order.Contains($i) -and (Test-DubRule ([string]$names[$i]) $rule)) { $order.Add($i) } }
  }
  for ($i = 0; $i -lt $names.Count; $i++) { if (-not $order.Contains($i)) { $order.Add($i) } }
  return $order.ToArray()
}

# Which voice-over: the one handed over, else ask (with a person to ask), else the automatic choice.
# The automatic choice: the one picked earlier this session or named by the link ($defPos), else the first DubPriority
# one the show has (Dream Cast, AniLibria, an official dub), else $defPos. When asking, that one is the first line (just
# Enter takes it), the other DubPriority ones follow, then the rest. $auto = $false skips DubPriority (the link itself
# named a voice-over: that one is the default).
function Select-SiteDub($names, [int]$defPos, [bool]$canAsk, [bool]$auto = $true) {
  $names = @($names)
  $pos = $defPos
  $want = $null
  if ($script:SiteChoice) { $want = $script:SiteChoice.Dub }
  if ($want) {
    $hit = Find-DubIndex $names $want
    if ($hit -ge 0) { $pos = $hit; $script:DubChoice = [string]$names[$hit] }
  } else {
    # Only a voice-over a person picked earlier (not an automatic pick, which the callers also remember in DubPref)
    # beats DubPriority.
    $kept = (-not $auto) -or ($script:DubChoice -and $defPos -ge 0 -and $defPos -lt $names.Count -and
      ([string]$names[$defPos] -eq $script:DubChoice -or (Test-SameDub ([string]$names[$defPos]) $script:DubChoice)))
    $hit = -1
    if (-not $kept -and $names.Count -gt 1) { $hit = Find-PriorityDub $names }
    if ($hit -ge 0) { $pos = $hit }
    if ($canAsk -and $names.Count -gt 1) {
      $order = @(Get-DubOrder $names $pos)
      $labels = @()
      for ($k = 0; $k -lt $order.Count; $k++) {
        $n = [string]$names[$order[$k]]
        $l = Format-DubName $n
        if ($k -eq 0) { $l = T '{0}   <- auto (just Enter)' $l }
        elseif (@(Get-DubPriority | Where-Object { Test-DubRule $n $_ }).Count -gt 0) { $l = T '{0}   (preferred)' $l }
        $labels += $l
      }
      $pick = Read-Choice (T 'Which voice-over (or subtitles)? Preferred ones are at the top ("DubPriority" in config.json).') $labels 0 $false -Key 'dub' -Values @($order | ForEach-Object { [string]$names[$_] })
      $pos = $order[$pick]
      $script:DubChoice = [string]$names[$pos]
    }
  }
  $script:LastDub = [string]$names[$pos]
  return $pos
}

# Which episodes: the ones handed over, else ask, else from $defPos on (at most $script:MaxUnasked of them).
function Select-SiteEpisodes($list, [int]$defPos, [bool]$canAsk) {
  $pick = @()
  if ($script:SiteChoice -and $script:SiteChoice.Eps) {
    $want = @($script:SiteChoice.Eps)
    $pick = @($list | Where-Object { $want -contains [string]$_.Number })
  }
  if ($pick.Count -eq 0) {
    if ($canAsk -and $list.Count -gt 1) { $pick = @(Read-EpisodeSelection $list $defPos -Key 'eps') }
    else {
      $pick = @($list[$defPos..($list.Count - 1)])
      if (-not $script:SiteChoice -and $pick.Count -gt $script:MaxUnasked) {
        Say (T '  (queued the next {0} of {1} episodes - drop the link on the .bat to choose others)' $script:MaxUnasked $pick.Count) 'Gray'
        $pick = @($pick[0..($script:MaxUnasked - 1)])
      }
    }
  }
  $script:LastEps = @($pick | ForEach-Object { [string]$_.Number })
  return $pick
}

function Expand-SiteLink([string]$u) {
  $parts = Split-SiteChoice $u
  $script:SiteChoice = $parts[1]
  $script:LastPart = $null   # only set by a link that has seasons / parts to pick from
  try {
    $items = @(Expand-SiteLinkNow $parts[0])
    # The player the window that searched for it was told to use (see Start-NextSource).
    if ($parts[1] -and $parts[1].Player) { foreach ($it in $items) { $it | Add-Member -Force -NotePropertyName PlayerChoice -NotePropertyValue $parts[1].Player } }
    return $items
  } finally { $script:SiteChoice = $null }
}

function Expand-SiteLinkNow([string]$u) {
  if ($u -match $script:KinopoiskLinkRe) { return @(Expand-Kinopoisk $u) }
  if ($u -match $script:ShikimoriLinkRe) { return @(Expand-Shikimori $u) }
  if ($u -match '^(?i)https?://(?:www\.)?animego\.') { return @(Expand-Animego $u) }
  if (Test-DreamcastUrl $u) { return @(Expand-Dreamcast $u) }
  if (Test-AnilibertyUrl $u) { return @(Expand-Aniliberty $u) }
  if (Test-AnimevostUrl $u) { return @(Expand-Animevost $u) }
  if (Test-AnimelibUrl $u) { return @(Expand-Animelib $u) }
  if (Test-WpartyUrl $u) { return @(Expand-Wparty $u) }
  if ((Test-KodikUrl $u) -and $u -match '(?i)/serial/') { return @(Expand-KodikSerial $u) }
  # A single player link.
  $prov = 'kodik'
  if (Test-AniboomUrl $u) { $prov = 'aniboom' } elseif ($u -match '(?i)sibnet\.ru') { $prov = 'sibnet' }
  $site = [pscustomobject]@{ Type = 'player'; Cands = @(New-Cand $prov $u '' '') }
  return @(New-SiteItem $u (T '{0} video' (Get-ProviderTitle $prov)) $site)
}

# ------------------------------------------------------------------ Dream Cast
function Expand-Dreamcast([string]$u) {
  $canAsk = Test-CanAsk
  if ($canAsk) { Say (T 'Reading the Dream Cast page...') 'Gray' }
  $r = $null
  try { $r = Get-DreamcastRelease $u }
  catch {
    if ($_.Exception.Message -match '404') { throw (T 'Dream Cast has no such release (check the link)') }
    throw (T 'Dream Cast didn''t open ({0})' (Get-ShortText $_.Exception.Message 100))
  }
  $eps = @($r.Episodes)
  if ($eps.Count -eq 0) { throw (T 'Dream Cast hasn''t put up any episodes of it yet') }
  $title = $r.Title
  if (-not $title) { $title = $r.Original }
  if (-not $title) { $title = "Dream Cast $($r.Id)" }
  if ($canAsk) {
    Say ''
    if ($eps.Count -eq 1) { Say (T 'Found on Dream Cast: {0}' $title) 'White' } else { Say (T 'Found on Dream Cast: {0} ({1} episodes)' $title $eps.Count) 'White' }
  }
  $startPos = 0
  $want = [regex]::Match($u, '#episode=(\d+)')
  if ($want.Success) { for ($i = 0; $i -lt $eps.Count; $i++) { if ($eps[$i].Number -eq $want.Groups[1].Value) { $startPos = $i } } }
  $list = @(Select-SiteEpisodes $eps $startPos $canAsk)
  $items = New-Object System.Collections.ArrayList
  foreach ($e in $list) {
    $site = [pscustomobject]@{ Type = 'player'; Cands = @(New-Cand 'dreamcast' $e.Url ($script:DreamcastBase + '/') 'Dream Cast') }
    $name = $title
    if ($eps.Count -gt 1) { $name = (T '{0} - episode {1}' $title $e.Number) }
    [void]$items.Add((New-SiteItem ($r.Url + '#episode=' + $e.Number) $name $site))
  }
  if ($script:SiteChoice -and $items.Count -gt 0) { $items[0].ResumeAt = $script:SiteChoice.Start }
  return $items.ToArray()
}

# ------------------------------------------------------------------ more players for the same voice-over
# Players that aren't on the page the link came from but have the same show:
#   Dream Cast's own site (1080p) when the voice-over is Dream Cast's and one of the show's titles is a release there,
#   CVH by the Shikimori id, Alloha by the Kinopoisk id (through the link WPARTY gives its rooms).
# Each one is only added when it really has that voice-over.
# $x: hashtable Dub; Names (the show's titles, for Dream Cast); Sid; Kp; Sources (WPARTY's movieCheck answer, for
#     Alloha's voice-overs); Season; Episode (0 = a film); Skip (players already in the list).
function Get-ExtraCands($x) {
  $out = New-Object System.Collections.ArrayList
  $dub = [string]$x.Dub
  if (-not $dub) { return @() }
  $skip = @($x.Skip)
  if ((ConvertTo-WpTitleKey $dub).Subs) { $skip += 'cvh' }   # (CVH's names don't say which releases are subtitled)
  $season = [int]$x.Season; $ep = [int]$x.Episode
  if ($skip -notcontains 'dreamcast' -and (Test-DubRule $dub 'Dream Cast')) {
    try {
      $rel = Find-DreamcastRelease @($x.Names)
      $u = $null
      if ($rel) { $u = Get-DreamcastEpisodeUrl $rel $ep }
      if ($u) {
        $c = New-Cand 'dreamcast' $u ($script:DreamcastBase + '/') $dub
        $c.Season = $season; $c.Episode = $ep
        [void]$out.Add($c)
      }
    } catch {}
  }
  if ($skip -notcontains 'cvh' -and $x.Sid) {
    try {
      $voice = Find-CvhVoice ([string]$x.Sid) $season $ep $dub
      if ($voice) {
        $c = New-Cand 'cvh' (Get-CvhPlayerUrl ([string]$x.Sid) $voice $season $ep) 'https://animego.me/' $dub
        $c.Season = $season; $c.Episode = $ep
        $c | Add-Member -NotePropertyName NoPage -NotePropertyValue $true
        [void]$out.Add($c)
      }
    } catch {}
  }
  if ($skip -notcontains 'alloha' -and $x.Kp -and $x.Sources -and (Get-Date) -ge $script:AllohaBlockedUntil) {
    $tr = Find-AllohaTranslation $x.Sources $dub
    if ($tr) { [void]$out.Add((New-AllohaCand ([string]$x.Kp) $tr.Id $dub $season $ep)) }
  }
  return $out.ToArray()
}

# ------------------------------------------------------------------ AnimeGO
function Expand-Animego([string]$u) {
  $canAsk = Test-CanAsk
  if ($canAsk) { Say (T 'Reading the AnimeGO page...') 'Gray' }
  $info = $null
  try { $info = Get-AnimegoInfo -Url $u }
  catch {
    # Its mirrors all lead to animego.me, so when that is blocked only the title search helps.
    if ($_.Exception.Message -match '404') { throw }
    throw (T 'AnimeGO didn''t open ({0}). If it''s blocked where you are, type the title instead of the link to search for it.' (Get-ShortText $_.Exception.Message 100))
  }
  $eps = @($info.Episodes | Where-Object { $_.HasVideo -ne $false })
  if ($eps.Count -eq 0) { throw (T 'none of its episodes can be watched on AnimeGO yet') }
  $title = $info.Title
  if (-not $title) { $title = $info.OriginalTitle }
  if (-not $title) { $title = "AnimeGO $($info.Id)" }
  $dubs = @($info.Translations)
  $dub = $null
  if ($canAsk) {
    Say ''
    if ($info.IsMovie) { Say (T 'Found on AnimeGO: {0}' $title) 'White' } else { Say (T 'Found on AnimeGO: {0} ({1} episodes)' $title $eps.Count) 'White' }
  }
  if ($dubs.Count -gt 0) {
    $pos = 0
    if ($script:DubPref) { for ($i = 0; $i -lt $dubs.Count; $i++) { if (Test-SameDub $dubs[$i].Name $script:DubPref) { $pos = $i; break } } }
    $pos = Select-SiteDub @($dubs | ForEach-Object { [string]$_.Name }) $pos $canAsk
    $dub = $dubs[$pos]
    $script:DubPref = [string]$dub.Name
  }
  $eps = @(Select-SiteEpisodes $eps 0 $canAsk)
  $items = New-Object System.Collections.ArrayList
  foreach ($e in $eps) {
    $name = $title
    if (-not $info.IsMovie) { $name = (T '{0} - episode {1}' $title $e.Number) }
    $site = [pscustomobject]@{ Type = 'animego'; AnimeId = [string]$info.Id; EpisodeId = [string]$e.EpisodeId; PageUrl = $info.Url; DubId = ''; DubName = ''
      Names = @($info.Title, $info.OriginalTitle | Where-Object { $_ }); Number = [string]$e.Number; IsMovie = [bool]$info.IsMovie }
    if ($dub) { $site.DubId = [string]$dub.Id; $site.DubName = [string]$dub.Name }
    [void]$items.Add((New-SiteItem ($info.Url + '#episode=' + $e.Number) $name $site))
  }
  return $items.ToArray()
}

function Get-AnimegoCands($s) {
  $srcs = @(Get-AnimegoSources $s.AnimeId $s.EpisodeId $s.PageUrl)
  if ($srcs.Count -eq 0) { throw (T 'AnimeGO has no video for this episode yet') }
  $list = New-Object System.Collections.ArrayList
  $i = 0
  foreach ($x in $srcs) {
    $i++
    if ($x.Provider -notin @('kodik', 'aniboom', 'cvh', 'sibnet')) { continue }
    $same = ((-not $s.DubId) -or [string]$x.TranslationId -eq $s.DubId -or (Test-SameDub $x.TranslationName $s.DubName))
    $ref = 'https://animego.me/'
    if ($x.Provider -eq 'cvh') { $ref = $s.PageUrl }
    $c = New-Cand $x.Provider $x.PlayerUrl $ref $x.TranslationName
    if (-not $same) { $c.Note = (T '{0} isn''t available for this episode, so it plays with {1}' $s.DubName $x.TranslationName) }
    [void]$list.Add([pscustomobject]@{ C = $c; Same = [int](-not $same); Rank = (Get-ProviderRank $x.Provider); Pos = $i })
  }
  # Dream Cast's own site for Dream Cast's voice-over (AnimeGO has CVH already, and no Kinopoisk id for Alloha).
  if ($s.PSObject.Properties['Names'] -and $s.DubName) {
    $ep = 0; if (-not $s.IsMovie) { $ep = ConvertTo-KodikInt $s.Number }
    if ($s.IsMovie -or $ep -gt 0) {
      foreach ($c in @(Get-ExtraCands @{ Dub = $s.DubName; Names = @($s.Names); Episode = $ep; Skip = @('cvh', 'alloha') })) { $i++; [void]$list.Add([pscustomobject]@{ C = $c; Same = 0; Rank = (Get-ProviderRank $c.Provider); Pos = $i }) }
    }
  }
  if ($list.Count -eq 0) { throw (T 'none of the players AnimeGO offers for this episode is supported') }
  return @($list | Sort-Object Same, Rank, Pos | ForEach-Object { $_.C })
}

# ------------------------------------------------------------------ AnimeLib
function Get-AnimelibDubName($x) {
  $n = [string]$x.Team
  if (-not $n) { $n = Get-ProviderTitle $x.Provider }
  if ($x.TranslationType -eq 'subtitles') { $n += ' (subtitles)' }   # stays English: see Format-DubName
  return $n
}

# How a dub name is shown. AnimeLib's " (subtitles)" stays English inside the name itself, because that name is also
# what gets matched (Test-SameDub, DubPref) and handed to another window (#vrclm=dub=...), which may use another language.
function Format-DubName([string]$n) {
  if ($n.EndsWith(' (subtitles)')) { return $n.Substring(0, $n.Length - 12) + (T ' (subtitles)') }
  return $n
}

function Expand-Animelib([string]$u) {
  $canAsk = Test-CanAsk
  if ($canAsk) { Say (T 'Reading the AnimeLib page...') 'Gray' }
  $info = $null
  try { $info = Get-AnimelibInfo $u }
  catch {
    if ($_.Exception.Message -notmatch 'API request failed') { throw }
    throw (T 'AnimeLib didn''t answer ({0}). If it''s blocked where you are, type the title instead of the link to search for it.' (Get-ShortText $_.Exception.Message 100))
  }
  $all = @($info.Episodes)
  if ($all.Count -eq 0) { throw (T 'AnimeLib has no episodes of it (yet)') }
  $title = $info.Title
  if (-not $title) { $title = $info.OriginalTitle }
  # Only the season of the linked episode (the first one otherwise): specials and other seasons reuse the numbers.
  $season = [string]$all[0].Season
  if ($info.StartEpisodeId) { foreach ($e in $all) { if ([string]$e.Id -eq [string]$info.StartEpisodeId) { $season = [string]$e.Season } } }
  $eps = @($all | Where-Object { [string]$_.Season -eq $season })
  $startPos = 0
  if ($info.StartEpisodeId) { for ($i = 0; $i -lt $eps.Count; $i++) { if ([string]$eps[$i].Id -eq [string]$info.StartEpisodeId) { $startPos = $i } } }
  # The voice-overs of the first episode to play stand in for the whole series.
  $dubs = New-Object System.Collections.ArrayList
  $linked = $null
  $first = Get-AnimelibSources ([string]$eps[$startPos].Id)   # (returns its list as one object)
  foreach ($x in @($first)) {
    if ($x.Provider -notin @('animelib', 'kodik', 'sibnet', 'alloha')) { continue }
    $n = Get-AnimelibDubName $x
    if (-not $dubs.Contains($n)) { [void]$dubs.Add($n) }
    # The link itself can name the voice-over (team=, translation_type=).
    if (-not $linked -and $info.StartTeamId -and [int]$x.TeamId -eq [int]$info.StartTeamId -and (-not $info.StartTranslationId -or [int]$x.TranslationTypeId -eq [int]$info.StartTranslationId)) { $linked = $n }
  }
  $dub = ''
  if ($canAsk) { Say ''; Say (T 'Found on AnimeLib: {0} ({1} episodes)' $title $eps.Count) 'White' }
  if ($dubs.Count -gt 0) {
    $pos = 0
    $want = $script:DubPref
    if ($linked) { $want = $linked }
    if ($want) { for ($i = 0; $i -lt $dubs.Count; $i++) { if ($dubs[$i] -eq $want -or (Test-SameDub $dubs[$i] $want)) { $pos = $i; break } } }
    $pos = Select-SiteDub @($dubs) $pos $canAsk (-not $linked)   # (a link that names its voice-over keeps it)
    $dub = [string]$dubs[$pos]
    $script:DubPref = $dub
  }
  $list = @($eps | ForEach-Object { [pscustomobject]@{ Number = [string]$_.Number; Ep = $_ } })
  $list = @(Select-SiteEpisodes $list $startPos $canAsk)
  $items = New-Object System.Collections.ArrayList
  foreach ($e in $list) {
    $site = [pscustomobject]@{ Type = 'animelib'; EpisodeId = [string]$e.Ep.Id; DubName = $dub
      Sid = [string]$info.ShikimoriId; Names = @($info.Title, $info.OriginalTitle | Where-Object { $_ }); Number = [string]$e.Number; Single = ($eps.Count -le 1) }
    $name = $title
    if ($eps.Count -gt 1) { $name = (T '{0} - episode {1}' $title $e.Number) }
    [void]$items.Add((New-SiteItem ($info.Url + '#episode=' + $e.Ep.Id) $name $site))
  }
  if ($script:SiteChoice) { if ($items.Count -gt 0) { $items[0].ResumeAt = $script:SiteChoice.Start } }
  elseif ($info.StartTime -and [double]$info.StartTime -gt 5 -and $items.Count -gt 0 -and [string]$list[0].Ep.Id -eq [string]$info.StartEpisodeId) { $items[0].ResumeAt = [double]$info.StartTime }
  return $items.ToArray()
}

function Get-AnimelibCands($s) {
  $srcs = Get-AnimelibSources $s.EpisodeId
  $srcs = @($srcs)
  if ($srcs.Count -eq 0) { throw (T 'AnimeLib has no video for this episode') }
  $list = New-Object System.Collections.ArrayList
  $i = 0
  foreach ($x in $srcs) {
    $i++
    if ($x.Provider -notin @('animelib', 'kodik', 'sibnet', 'alloha')) { continue }
    $n = Get-AnimelibDubName $x
    $same = ((-not $s.DubName) -or (Test-SameDub $n $s.DubName))
    $c = New-Cand $x.Provider ([string]$x.PlayerUrl) 'https://anilib.me/' $n
    $c.Label = (Get-ProviderTitle $x.Provider) + ', ' + (Format-DubName $n)
    if ($x.Provider -eq 'animelib') { $c | Add-Member -NotePropertyName Source -NotePropertyValue $x }
    if (-not $same) { $c.Note = (T '{0} isn''t available for this episode, so it plays with {1}' (Format-DubName $s.DubName) (Format-DubName $n)) }
    $rank = Get-ProviderRank $x.Provider
    if ($x.Provider -eq 'animelib') { $rank = 0 }
    [void]$list.Add([pscustomobject]@{ C = $c; Same = [int](-not $same); Rank = $rank; Pos = $i })
  }
  # The same voice-over on Dream Cast's own site and CVH (by the Shikimori id AnimeLib links to).
  if ($s.PSObject.Properties['Names'] -and $s.DubName) {
    $ep = ConvertTo-KodikInt $s.Number
    if ($s.Single -and $ep -le 1) { $ep = 0 }   # a film: its only video
    if ($ep -gt 0 -or $s.Single) {
      foreach ($c in @(Get-ExtraCands @{ Dub = $s.DubName; Names = @($s.Names); Sid = $s.Sid; Episode = $ep; Skip = @('alloha') })) {
        $i++
        [void]$list.Add([pscustomobject]@{ C = $c; Same = 0; Rank = (Get-ProviderRank $c.Provider); Pos = $i })
      }
    }
  }
  if ($list.Count -eq 0) { throw (T 'none of the players AnimeLib offers for this episode is supported') }
  return @($list | Sort-Object Same, Rank, Pos | ForEach-Object { $_.C })
}

# ------------------------------------------------------------------ WPARTY
function Expand-Wparty([string]$u) {
  $canAsk = Test-CanAsk
  if ($canAsk) { Say (T 'Looking at what the WPARTY room is playing...') 'Gray' }
  $room = $null
  try { $room = Get-WpartyRoom -Url $u -TimeoutSec 20 }
  catch {
    # The site is sometimes slow to answer; try once more unless the answer was final.
    if ($_.Exception.Message -match 'password') { throw (T 'that room has a password, which this tool can''t enter (ask the host to remove it, or paste what the room plays instead)') }
    if ($_.Exception.Message -match 'not a WPARTY') { throw (T 'that isn''t a link to a WPARTY room') }
    if ($_.Exception.Message -match 'room is full') { throw (T 'that WPARTY room is full') }
    if ($_.Exception.Message -match '^WPARTY: room not found|^WPARTY: room link \S+ does not exist') { throw (T 'that WPARTY room doesn''t exist (check the link)') }
    if ($_.Exception.Message -match 'not found|full|does not exist') { throw }   # other final answers (e.g. an HTTP 404 from the socket server): shown as they are
    $room = Get-WpartyRoom -Url $u -TimeoutSec 20
  }
  # (WPARTY's current Alloha link, for Alloha players of other shows: see New-AllohaCand)
  if ($room.Source -eq 'alloha' -and [string]$room.SourceUrl -match '^https://[^/?#]+/\?token=[A-Za-z0-9]+$') { $script:AllohaBase = [string]$room.SourceUrl }
  if ($room.Kind -eq 'empty' -or -not $room.Video) { throw (T 'nothing is playing in that room right now') }
  if ($room.Kind -eq 'unsupported') { throw (T 'the room is showing someone''s screen or a file from their PC, which can''t be picked up from here') }
  if ($room.Kind -eq 'url') {
    $v = [string]$room.Video
    if ($canAsk) { Say (T 'The room is playing: {0}' $v) 'Gray' }
    if ((Test-SiteLink $v) -and -not (Test-WpartyUrl $v)) { return @(Expand-SiteLink $v) }
    $it = New-QueueItem 'url' $v
    $uts = 0.0
    if ($null -ne $room.LeaderTS -and $room.LeaderTS -gt 0) { $uts = [double]$room.LeaderTS } elseif ($room.VideoTS) { $uts = [double]$room.VideoTS }
    if ($script:SiteChoice) { $it.ResumeAt = $script:SiteChoice.Start }
    elseif ($uts -gt 30 -and (Read-YesNo (T 'Start at {0}, where the room is?' (Format-Time $uts)))) { $it.ResumeAt = [Math]::Max(0.0, $uts - 3) }
    return @($it)
  }
  $sources = $null
  try { $sources = Get-WpartyMovieSources $room.KpId } catch {}
  $dubName = $null
  if ($sources) { $dubName = Get-WpartyTranslationTitle $sources $room.Source $room.Translation $room.ShikimoriId }
  $name = [string]$room.Name
  if (-not $name) { $name = "Kinopoisk $($room.KpId)" }
  $ts = 0.0
  if ($null -ne $room.LeaderTS -and $room.LeaderTS -gt 0) { $ts = [double]$room.LeaderTS } elseif ($room.VideoTS) { $ts = [double]$room.VideoTS }

  $picked = @()
  $season = 0
  $roomEp = $null
  if ($null -ne $room.Episode -and [int]$room.Episode -gt 0) {
    $season = 1
    if ($null -ne $room.Season) { $season = [int]$room.Season }
    $roomEp = [string]$room.Episode
    $numbers = @()
    $inSeason = $null
    if ($room.PlaylistData) { $inSeason = $room.PlaylistData[[string]$season] }
    if ($inSeason) { $numbers = @($inSeason | ForEach-Object { [string]$_ }) }
    if ($numbers.Count -eq 0 -and $room.KpId) {
      # Only Alloha rooms send the episode list; ask Kodik what the season has.
      try {
        $k = Get-KodikEpisodes "https://kodikplayer.com/find-player?kinopoiskID=$($room.KpId)&season=$season&episode=$roomEp"
        $numbers = @($k.Episodes | Where-Object { [int]$_.Season -eq $season } | ForEach-Object { [string]$_.Episode } | Select-Object -Unique)
      } catch {}
    }
    $numbers = @($numbers | Where-Object { $_ -match '^\d+$' })   # the players can't address "12.5"-style episodes
    if ($numbers -notcontains $roomEp) { $numbers = @($roomEp) }
    $list = @($numbers | ForEach-Object { [pscustomobject]@{ Number = $_ } })
    $pos = 0
    for ($i = 0; $i -lt $list.Count; $i++) { if ($list[$i].Number -eq $roomEp) { $pos = $i } }
    if ($canAsk) {
      $what = (T 'season {0}, episode {1}' $season $roomEp)
      if ($dubName) { $what += " ($dubName)" }
      Say ''
      Say (T 'The WPARTY room is playing: {0} - {1}' $name $what) 'White'
    }
    $picked = @(Select-SiteEpisodes $list $pos $canAsk)
  } else {
    if ($canAsk) { Say ''; Say (T 'The WPARTY room is playing: {0}' $name) 'White' }
    $picked = @([pscustomobject]@{ Number = '' })
  }

  $items = New-Object System.Collections.ArrayList
  foreach ($p in $picked) {
    $site = [pscustomobject]@{ Type = 'wparty'; Room = $room; Sources = $sources; DubName = $dubName; Season = $season; Episode = 0 }
    $iname = $name
    $key = "kinopoisk:$($room.KpId)"
    if ($p.Number) {
      $site.Episode = [int]$p.Number
      $iname = (T '{0} - season {1}, episode {2}' $name $season $p.Number)
      $key += ":s$($season)e$($p.Number)"
    }
    [void]$items.Add((New-SiteItem $key $iname $site))
  }
  # Join the room where it is, if the first video is the one it's on.
  if ($script:SiteChoice) { if ($items.Count -gt 0) { $items[0].ResumeAt = $script:SiteChoice.Start } }
  elseif ($ts -gt 30 -and $items.Count -gt 0 -and ((-not $roomEp) -or $picked[0].Number -eq $roomEp)) {
    if (Read-YesNo (T 'Start at {0}, where the room is?' (Format-Time $ts))) { $items[0].ResumeAt = [Math]::Max(0.0, $ts - 3) }
  }
  return $items.ToArray()
}

function Get-WpartyCands($s) {
  $room = $s.Room
  $list = New-Object System.Collections.ArrayList
  $dub = $s.DubName
  $roomOk = $false
  if (($room.Source -eq 'alloha' -and (Get-Date) -ge $script:AllohaBlockedUntil) -or $room.Source -eq 'kodik') {
    $url = Get-WpartyPlayerUrl $room -Season $s.Season -Episode $s.Episode
    if ($url) {
      $c = New-Cand $room.Source $url 'https://wparty.net/' $dub
      $c.Season = $s.Season; $c.Episode = $s.Episode
      Add-RankedCand $list $c 0
      $roomOk = $true
    }
  }
  $sid = [string]$room.ShikimoriId
  $hasKodik = (-not $s.Sources) -or @($s.Sources | Where-Object { (Get-WpVal $_ 'name') -eq 'kodik' }).Count -gt 0
  if ($room.Source -ne 'kodik' -and $room.KpId -and $hasKodik) {
    # Kodik usually has the same show; use the same dub when it has it.
    $tr = $null
    if ($s.Sources -and $dub) { try { $tr = Find-WpartyKodikTranslation $s.Sources $dub $s.Season } catch {} }
    if ($tr -and $tr.ShikimoriId -and -not $sid) { $sid = [string]$tr.ShikimoriId }
    $u = "https://kodikplayer.com/find-player?kinopoiskID=$($room.KpId)&translations=false"
    $kdub = $null
    if ($tr -and $tr.TranslationId) { $u += "&onlyTranslationID=[$($tr.TranslationId)]"; $kdub = $tr.Title }
    if ($s.Episode -gt 0) { $u += "&season=$($s.Season)&episode=$($s.Episode)" }
    $c = New-Cand 'kodik' $u 'https://wparty.net/' $kdub
    $c.Season = $s.Season; $c.Episode = $s.Episode
    if (-not $kdub -and $dub) { $c.Note = (T '{0} isn''t on Kodik, so it plays with Kodik''s default voice-over' $dub) }
    if (-not $roomOk -and $room.Source -and $dub) { $c.Note = $(if ($kdub) { T 'the room''s player ({0}) can''t be read, so it plays from Kodik' $room.Source } else { T 'the room''s player ({0}) can''t be read, so it plays from Kodik with its default voice-over' $room.Source }) }
    Add-RankedCand $list $c ([int]($dub -and -not $kdub))
  }
  # The same voice-over on Dream Cast's own site, CVH and Alloha.
  $names = @()
  if ($s.PSObject.Properties['Names'] -and $s.Names) { $names = @($s.Names) }
  if ($names.Count -eq 0 -and $room.Name) { $names = @($room.Name); if ($s.Season -gt 1) { $names = @("$($room.Name) $($s.Season)") } }
  $x = @{ Dub = $dub; Names = $names; Sid = $sid; Kp = $room.KpId; Sources = $s.Sources; Season = $s.Season; Episode = $s.Episode; Skip = @($room.Source) }
  foreach ($c in @(Get-ExtraCands $x)) { Add-RankedCand $list $c 0 }
  if ($room.KpId) {
    # Collaps finds most films and series by the same Kinopoisk id (and picks the voice-over by its name).
    $c = New-Cand 'collaps' ([string]$room.KpId) 'https://wparty.net/' $dub
    $c.Season = $s.Season; $c.Episode = $s.Episode
    Add-RankedCand $list $c 0
  }
  if ($list.Count -eq 0) { throw (T 'the room''s player ({0}) isn''t supported' $room.Source) }
  return (Get-RankedCands $list)
}

# ------------------------------------------------------------------ a Kodik series link
function Expand-KodikSerial([string]$u) {
  $canAsk = Test-CanAsk
  $k = Get-KodikEpisodes $u
  $eps = @($k.Episodes | Where-Object { $_.Season -eq $k.CurrentSeason })
  if ($eps.Count -eq 0) { $eps = @($k.Episodes) }
  if ($eps.Count -eq 0) { throw (T 'no episodes found in that Kodik link') }
  $list = @($eps | ForEach-Object { [pscustomobject]@{ Number = [string]$_.Episode; Ep = $_ } })
  $title = [string]$k.Title
  if (-not $title) { $title = 'Kodik' }
  $startPos = 0
  for ($i = 0; $i -lt $list.Count; $i++) { if ($null -ne $k.CurrentEpisode -and [string]$list[$i].Ep.Episode -eq [string]$k.CurrentEpisode -and $u -match '(?i)[?&]episode=') { $startPos = $i } }
  if ($canAsk) { Say ''; if ($k.TranslationTitle) { Say (T 'Found on Kodik: {0} ({1} episodes, {2})' $title $list.Count $k.TranslationTitle) 'White' } else { Say (T 'Found on Kodik: {0} ({1} episodes)' $title $list.Count) 'White' } }
  $list = @(Select-SiteEpisodes $list $startPos $canAsk)
  $items = New-Object System.Collections.ArrayList
  foreach ($e in $list) {
    $site = [pscustomobject]@{ Type = 'player'; Cands = @(New-Cand 'kodik' $e.Ep.Url '' ([string]$k.TranslationTitle)) }
    [void]$items.Add((New-SiteItem $e.Ep.Url (T '{0} - episode {1}' $title $e.Number) $site))
  }
  return $items.ToArray()
}

# ------------------------------------------------------------------ title search (type a name instead of pasting a link)
# For when AnimeGO / AnimeLib pages don't open (often blocked in Russia): none of these calls opens a site page.
#   WPARTY    POST https://wparty.net/api/movieSearch {"q":..}          -> [{id (Kinopoisk id), name, year, channel, rating}]
#   Shikimori GET  https://shikimori.io/api/animes?search=..&limit=..    -> [{id, name, russian, kind, status, episodes, episodes_aired, aired_on}]
#   AnimeLib  GET  https://api.cdnlibs.org/api/anime?q=..&site_id[]=5   -> {data:[{slug_url, name, rus_name, type{label}, releaseDateString, shikimori_href}]}
# Every result carries a .Link that Test-SiteLink / Expand-SiteLink understand, so it also survives the #vrclm= hand-over:
#   https://www.kinopoisk.ru/series/<kpId>/?name=<title>  -> WPARTY movieCheck -> Kodik (season/part, voice-over, episodes), else Collaps
#   https://shikimori.io/animes/<id>?name=<title>         -> Kodik by Shikimori id
#   https://anilib.me/ru/anime/<slug_url>                 -> Expand-Animelib (it only uses the API, never the page)
# AniLiberty, AnimeVost and Dream Cast (see their sections) search their own catalogues; their rows play only their own
# voice-over, so they are listed apart (after the others) and never merged with them.
$script:ShikimoriBase = 'https://shikimori.io'
$script:SearchTimeoutSec = 10
$script:SearchMaxRows = 20
$script:SearchQuota = @{ 'dreamcast' = 3; 'wparty' = 8; 'shikimori' = 3; 'animelib' = 2; 'aniliberty' = 2; 'animevost' = 2 }   # rows per source before the rest fills up
$script:SearchSourceNames = @{ 'dreamcast' = 'Dream Cast'; 'wparty' = 'WPARTY'; 'shikimori' = 'Shikimori'; 'animelib' = 'AnimeLib'; 'aniliberty' = 'AniLiberty'; 'animevost' = 'AnimeVost' }
$script:KinopoiskLinkRe = '^(?i)https?://(?:www\.)?kinopoisk\.ru/(film|series)/(\d+)'
$script:ShikimoriLinkRe = '^(?i)https?://(?:www\.)?(?:shikimori\.(?:io|one|me)|shiki\.one)/animes/[a-z]*(\d+)'
$script:MovieCheckCache = @{}     # Kinopoisk id -> movieCheck answer (this session)
$script:LastSearchLink = $null    # the picked result's link + '#vrclm=<answers>', ready to hand to a running window
$script:SearchMediaRx = '(?i)\.(mp4|mkv|avi|mov|webm|m4v|ts|flv|wmv|mp3|m4a|srt|ass|vtt)$'

# Does a typed line look like a title to search for (not a link, a file or a folder)?
function Test-SearchQuery([string]$text) {
  $t = ([string]$text).Trim()
  if ($t.Length -lt 2) { return $false }
  if ($t -notmatch '\p{L}') { return $false }
  if ($t -match '(?i)vrclm-vps\d*:') { return $false }   # a VPS connection code (a password): never searched for
  if ($t -match '^[A-Za-z0-9_-]{40,}$') { return $false }   # (nor a piece of one: no title is one 40-letter word)
  if ($t -match '^(?i)[a-z][a-z0-9+.-]*://' -or $t -match '^(?i)www\.') { return $false }
  if ($t -match '^(?i)[a-z0-9-]+(\.[a-z0-9-]+)+/' ) { return $false }   # animego.me/anime/... without https://
  if ($t -match '^[a-zA-Z]:' -or $t.StartsWith('\\') -or $t -match '^\.{1,2}[\\/]' -or $t.Contains('\')) { return $false }
  if ($t -match $script:SearchMediaRx) { return $false }
  $bare = $t.Trim('"').Trim("'").Trim()
  try { if ([System.IO.File]::Exists($bare) -or [System.IO.Directory]::Exists($bare)) { return $false } } catch {}
  return $true
}

# Several Invoke-Web calls at once (each in its own runspace). $reqs = hashtables of Invoke-Web parameters.
# Returns one object per request, in order: Status, Text, Error (the message when it couldn't be reached / timed out).
function Invoke-WebParallel($reqs) {
  $reqs = @($reqs)
  $out = New-Object object[] $reqs.Count
  $body = 'function Invoke-Web {' + ${function:Invoke-Web}.ToString() + '}'
  $work = {
    param($def, $ua, $q)
    $script:WebUA = $ua
    $script:WebCookies = New-Object System.Net.CookieContainer
    . ([scriptblock]::Create($def))
    try { $r = Invoke-Web @q; return [pscustomobject]@{ Status = $r.Status; Text = $r.Text; Error = $null } }
    catch { $e = $_.Exception; if ($e.InnerException) { $e = $e.InnerException }; return [pscustomobject]@{ Status = 0; Text = ''; Error = $e.Message } }
  }
  $pool = $null
  try {
    $pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max(1, $reqs.Count))
    $pool.Open()
  } catch {
    # No runspaces here: one after the other.
    for ($i = 0; $i -lt $reqs.Count; $i++) {
      $q = $reqs[$i]
      try { $r = Invoke-Web @q; $out[$i] = [pscustomobject]@{ Status = $r.Status; Text = $r.Text; Error = $null } }
      catch { $e = $_.Exception; if ($e.InnerException) { $e = $e.InnerException }; $out[$i] = [pscustomobject]@{ Status = 0; Text = ''; Error = $e.Message } }
    }
    return $out
  }
  $jobs = @()
  $wait = 5
  foreach ($q in $reqs) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($work).AddArgument($body).AddArgument($script:WebUA).AddArgument($q)
    $jobs += , @($ps, $ps.BeginInvoke())
    $t = 20; if ($q.ContainsKey('TimeoutSec')) { $t = [int]$q['TimeoutSec'] }
    $wait = [Math]::Max($wait, $t + 3)
  }
  $until = (Get-Date).AddSeconds($wait)
  $late = $false
  for ($i = 0; $i -lt $jobs.Count; $i++) {
    $ps = $jobs[$i][0]; $h = $jobs[$i][1]
    $ms = [int][Math]::Max(0, ($until - (Get-Date)).TotalMilliseconds)
    if ($h.IsCompleted -or $h.AsyncWaitHandle.WaitOne($ms)) {
      try { $res = @($ps.EndInvoke($h)); if ($res.Count -gt 0) { $out[$i] = $res[0] } } catch { $out[$i] = [pscustomobject]@{ Status = 0; Text = ''; Error = $_.Exception.Message } }
      $ps.Dispose()
    } else {
      $out[$i] = [pscustomobject]@{ Status = 0; Text = ''; Error = 'timed out' }
      [void]$ps.BeginStop($null, $null)
      $late = $true
    }
    if (-not $out[$i]) { $out[$i] = [pscustomobject]@{ Status = 0; Text = ''; Error = 'no answer' } }
  }
  # A request still hanging ends on its own timeout; don't wait for it here.
  if (-not $late) { $pool.Close(); $pool.Dispose() } else { [void]$pool.BeginClose($null, $null) }
  return $out
}

# Title -> comparison key ("Magicheskaya bitva!" and "magicheskaya  bitva" match; Cyrillic yo = ye).
function ConvertTo-SearchKey([string]$s) {
  $t = ([string]$s).ToLowerInvariant().Replace([char]0x0451, [char]0x0435)
  return ([regex]::Replace($t, '[^\p{L}\p{Nd}]+', ''))
}

function New-SearchRow([string]$source, [string]$id, [string]$title, [string]$year, [string]$kind, [string]$extra, [string]$link, $names) {
  return [pscustomobject]@{ Title = $title; Year = $year; Kind = $kind; Extra = $extra; Source = $source; Id = $id; Link = $link; Names = @($names | Where-Object { $_ }); ShikiId = $null }
}

# WPARTY answer -> rows. channel is "Serial" / "Film" in Russian (the only two values seen).
function ConvertFrom-WpartySearch([string]$text) {
  $rows = @()
  $d = ConvertFrom-WpJson $text
  if ($d -isnot [object[]]) { throw 'bad answer' }
  foreach ($x in $d) {
    $id = [string](Get-WpVal $x 'id')
    if ($id -notmatch '^\d+$') { continue }
    $name = [string](Get-WpVal $x 'name')
    $ch = [string](Get-WpVal $x 'channel')
    $kind = $ch; $path = 'series'
    if ($ch -match '(?i)\u0441\u0435\u0440\u0438\u0430\u043b') { $kind = T 'series' }   # also "mini-series"
    elseif ($ch -match '^\u0424\u0438\u043b\u044c\u043c') { $kind = T 'film'; $path = 'film' }
    $rt = [string](Get-WpVal $x 'rating')
    $extra = ''
    if ($rt -match '^\d+(\.\d+)?$' -and $rt -ne '0') { $extra = T 'rating {0}' $rt }
    $link = 'https://www.kinopoisk.ru/' + $path + '/' + $id + '/?name=' + [Uri]::EscapeDataString($name)
    $rows += New-SearchRow 'wparty' $id $name ([string](Get-WpVal $x 'year')) $kind $extra $link @($name)
  }
  return $rows
}

function ConvertFrom-ShikimoriSearch([string]$text) {
  $rows = @()
  $d = ConvertFrom-WpJson $text
  if ($d -isnot [object[]]) { throw 'bad answer' }
  foreach ($x in $d) {
    $kindId = [string](Get-WpVal $x 'kind')
    if ($kindId -in @('pv', 'cm', 'music')) { continue }
    $id = [string](Get-WpVal $x 'id')
    $name = [string](Get-WpVal $x 'name'); $rus = [string](Get-WpVal $x 'russian')
    $title = $rus; if (-not $title) { $title = $name }
    $year = ''; $m = [regex]::Match([string](Get-WpVal $x 'aired_on'), '^\d{4}'); if ($m.Success) { $year = $m.Value }
    $kind = $kindId.ToUpperInvariant()
    if ($kindId -eq 'tv') { $kind = T 'series' } elseif ($kindId -eq 'movie') { $kind = T 'film' } elseif ($kindId -match 'special') { $kind = T 'special' }
    $eps = ConvertTo-KodikInt (Get-WpVal $x 'episodes'); $aired = ConvertTo-KodikInt (Get-WpVal $x 'episodes_aired')
    $extra = ''
    if ([string](Get-WpVal $x 'status') -eq 'ongoing' -and $aired -gt 0) { if ($eps -gt 0) { $extra = T '{0} of {1} ep.' $aired $eps } else { $extra = T '{0} ep. so far' $aired } }
    elseif ($eps -gt 1) { $extra = T '{0} ep.' $eps }
    $link = $script:ShikimoriBase + '/animes/' + $id + '?name=' + [Uri]::EscapeDataString($title)
    $r = New-SearchRow 'shikimori' $id $title $year $kind $extra $link @($rus, $name)
    $r.ShikiId = $id
    $rows += $r
  }
  return $rows
}

function ConvertFrom-AnimelibSearch([string]$text) {
  $rows = @()
  $j = ConvertFrom-JsonDict $text
  foreach ($x in @(Get-AnimelibVal $j 'data')) {
    if ($null -eq $x) { continue }
    $slug = [string](Get-AnimelibVal $x 'slug_url')
    if (-not $slug) { continue }
    $name = [string](Get-AnimelibVal $x 'name'); $rus = [string](Get-AnimelibVal $x 'rus_name'); $eng = [string](Get-AnimelibVal $x 'eng_name')
    $title = $rus; if (-not $title) { $title = $name }; if (-not $title) { $title = $eng }
    $year = ''; $m = [regex]::Match([string](Get-AnimelibVal $x 'releaseDateString'), '\d{4}'); if ($m.Success) { $year = $m.Value }
    $label = [string](Get-AnimelibVal (Get-AnimelibVal $x 'type') 'label')
    $kind = $label
    if ($label -match '(?i)\u0441\u0435\u0440\u0438\u0430\u043b') { $kind = T 'series' }
    elseif ($label -match '(?i)\u0444\u0438\u043b\u044c\u043c|movie') { $kind = T 'film' }
    elseif ($label -match '(?i)\u0441\u043f\u0435\u0448\u043b|special') { $kind = T 'special' }
    elseif ($label -match '(?i)^\u043d\u0435\u0438\u0437\u0432') { $kind = '' }   # "unknown"
    $link = $script:AnimelibSiteOrigin + '/ru/anime/' + $slug
    $r = New-SearchRow 'animelib' $slug $title $year $kind '' $link @($rus, $name, $eng)
    $m = [regex]::Match([string](Get-AnimelibVal $x 'shikimori_href'), '/animes/[a-z]*(\d+)')
    if ($m.Success) { $r.ShikiId = $m.Groups[1].Value }
    $rows += $r
  }
  return $rows
}

# Searches WPARTY (films, series, anime by Kinopoisk id), Shikimori and AnimeLib (anime) for a title, and the
# catalogues of AniLiberty, AnimeVost and Dream Cast (their own voice-overs).
# Returns up to $script:SearchMaxRows rows: Title, Year, Kind, Extra, Source ('wparty'|'shikimori'|'animelib'|
# 'aniliberty'|'animevost'|'dreamcast'), Id, Link.
# A source that doesn't answer gets one short line; the others still show.
function Find-SiteContent([string]$query) {
  $q = ([string]$query).Trim()
  if (-not $q) { return @() }
  $esc = [Uri]::EscapeDataString($q)
  $alApi = 'https://api.cdnlibs.org/api'
  if ($script:AnimelibApiGoodHost) { $alApi = $script:AnimelibApiGoodHost }
  $sec = $script:SearchTimeoutSec
  $srcs = @('dreamcast', 'wparty', 'shikimori', 'animelib', 'aniliberty', 'animevost')
  $apart = @('dreamcast', 'aniliberty', 'animevost')   # (their own voice-over only: never merged with the others)
  $reqs = @(
    (Get-DreamcastSearchRequest $q $sec),
    @{ Url = $script:WpartyBase + '/api/movieSearch'; Method = 'POST'; Body = (ConvertTo-Json @{ q = $q } -Compress); ContentType = 'application/json'
      Headers = @{ 'Referer' = $script:WpartyBase + '/'; 'Origin' = $script:WpartyBase }; TimeoutSec = $sec },
    @{ Url = $script:ShikimoriBase + '/api/animes?search=' + $esc + '&limit=8'; Headers = @{ 'Accept' = 'application/json' }; TimeoutSec = $sec },
    @{ Url = $alApi + '/anime?q=' + $esc + '&site_id[]=' + $script:AnimelibSiteId; Headers = (Get-AnimelibApiHeaders -NoAuth); TimeoutSec = $sec },
    (Get-AnilibertySearchRequest $q $sec),
    (Get-AnimevostSearchRequest $q $sec)
  )
  $answers = @(Invoke-WebParallel $reqs)
  $found = @{}
  for ($i = 0; $i -lt $srcs.Count; $i++) {
    $a = $answers[$i]; $s = $srcs[$i]
    $found[$s] = @()
    # AnimeVost answers "nothing found" with HTTP 404.
    $ok = Test-SearchAnswer $s $a
    if (-not $ok -and ($s -eq 'aniliberty' -or $s -eq 'animevost')) {
      # Their other addresses, one after the other.
      $tried = ([Uri]$reqs[$i].Url).GetLeftPart([System.UriPartial]::Authority)
      try {
        if ($s -eq 'aniliberty') { $r2 = Invoke-MirrorApi $script:AnilibertyHosts $script:AnilibertyState (Get-AnilibertySearchPath $q) 'GET' $null 6 $tried }
        else { $r2 = Invoke-MirrorApi $script:AnimevostHosts $script:AnimevostState '/v1/search' 'POST' $reqs[$i].Body 6 $tried }
        $a = [pscustomobject]@{ Status = $r2.Status; Text = $r2.Text; Error = $null }
        $ok = Test-SearchAnswer $s $a
      } catch {}
    }
    $why = $null
    if ($a.Error) { $why = $a.Error }
    elseif (-not $ok) { $why = "HTTP $($a.Status)" }
    else {
      try {
        if ($s -eq 'wparty') { $found[$s] = @(ConvertFrom-WpartySearch $a.Text) }
        elseif ($s -eq 'dreamcast') { $found[$s] = @(ConvertFrom-DreamcastSearch $a.Text $q) }
        elseif ($s -eq 'shikimori') { $found[$s] = @(ConvertFrom-ShikimoriSearch $a.Text) }
        elseif ($s -eq 'aniliberty') { $found[$s] = @(ConvertFrom-AnilibertySearch $a.Text $q) }
        elseif ($s -eq 'animevost') { $found[$s] = @(ConvertFrom-AnimevostSearch $a.Text $q) }
        else { $found[$s] = @(ConvertFrom-AnimelibSearch $a.Text) }
      } catch { $why = T 'unexpected answer' }
    }
    if ($why) { Say (T '  {0} search isn''t answering ({1}).' $script:SearchSourceNames[$s] (Get-ShortText ([string]$why) 60)) 'DarkGray' }
  }
  # Drop what an earlier source already has (same title and year, or the same Shikimori id). Dream Cast's, AniLiberty's
  # and AnimeVost's rows stay apart: they play only their own voice-over, the others offer every voice-over (theirs
  # included).
  $seen = @{}; $shiki = @{}
  $kept = @{}
  foreach ($s in $srcs) {
    $kept[$s] = New-Object System.Collections.ArrayList
    foreach ($r in $found[$s]) {
      if ($apart -contains $s) { [void]$kept[$s].Add($r); continue }
      if ($r.ShikiId -and $shiki.ContainsKey($r.ShikiId)) { continue }
      $keys = @($r.Names | ForEach-Object { (ConvertTo-SearchKey $_) + '|' + $r.Year } | Where-Object { $_ -notmatch '^\|' })
      $dup = $false
      foreach ($k in $keys) { if ($seen.ContainsKey($k)) { $dup = $true } }
      if ($dup) { continue }
      foreach ($k in $keys) { $seen[$k] = $true }
      if ($r.ShikiId) { $shiki[$r.ShikiId] = $true }
      [void]$kept[$s].Add($r)
    }
  }
  # A few from each, then fill up with whatever is left (WPARTY's first, Dream Cast's last). The own-voice-over rows go
  # last too: Enter should take the show with every voice-over (picked by DubPriority), not "Overlord 4" from Dream Cast.
  $order = @($srcs | Where-Object { $apart -notcontains $_ }) + @($apart | Where-Object { $_ -ne 'dreamcast' }) + @('dreamcast')
  $take = @{}
  $n = 0
  foreach ($s in $srcs) { $take[$s] = [Math]::Min($kept[$s].Count, $script:SearchQuota[$s]); $n += $take[$s] }
  foreach ($s in $order) { while ($n -lt $script:SearchMaxRows -and $take[$s] -lt $kept[$s].Count) { $take[$s]++; $n++ } }
  $rows = @()
  foreach ($s in $order) { if ($take[$s] -gt 0) { $rows += @($kept[$s])[0..($take[$s] - 1)] } }
  # The exact title typed comes first (stable: the source order stays within each group), separately for the
  # own-voice-over rows, which stay after the others.
  $qk = ConvertTo-SearchKey $q
  $out = @()
  foreach ($grp in @(@($rows | Where-Object { $apart -notcontains $_.Source }), @($rows | Where-Object { $apart -contains $_.Source }))) {
    $exact = @($grp | Where-Object { @($_.Names | Where-Object { (ConvertTo-SearchKey $_) -eq $qk }).Count -gt 0 })
    $out += $exact
    $out += @($grp | Where-Object { $exact -notcontains $_ })
  }
  return $out
}

# A search answer worth reading: HTTP 200 with JSON (AnimeVost: also 404, its "nothing found"). Anything else (a block
# or challenge page, an error) makes the sources that have other addresses try those.
function Test-SearchAnswer([string]$source, $a) {
  if ($a.Error) { return $false }
  if (-not ($a.Status -eq 200 -or ($source -eq 'animevost' -and $a.Status -eq 404))) { return $false }
  if ($source -ne 'aniliberty' -and $source -ne 'animevost') { return $true }
  $t = ([string]$a.Text).TrimStart()
  return ($t.StartsWith('{') -or $t.StartsWith('['))
}

# One result as a line of the list: Title (Year) - kind - extra [source]
function Format-SearchRow($r) {
  $s = Get-ShortText ([string]$r.Title) 70
  if ($r.Year) { $s += " ($($r.Year))" }
  if ($r.Kind) { $s += " - $($r.Kind)" }
  if ($r.Extra) { $s += " - $($r.Extra)" }
  return $s + ' [' + $script:SearchSourceNames[$r.Source] + ']'
}

# Search -> pick -> questions -> queue items. Only when this window may ask; otherwise (and when cancelled) @().
# Afterwards $script:LastSearchLink holds the picked link with the answers attached (#vrclm=...), for a running window.
# -AskPlayer (a window that hands it to the streaming one): also which player, see Read-HandoverPlayer.
function Invoke-ContentSearch([string]$query, [switch]$AskPlayer) {
  $script:LastSearchLink = $null
  if (-not (Test-CanAsk)) { return @() }
  $q = ([string]$query).Trim().Trim('"').Trim()
  if (-not $q) { return @() }
  Say (T 'Searching for "{0}"...' $q) 'Gray'
  # (A Back to this list inside a flow shows the same rows again without searching again.)
  $rows = @(Use-NavMemo ('search|' + $q) { Find-SiteContent $q })
  if ($rows.Count -eq 0) {
    Say (T 'Nothing found for "{0}". Try another spelling, or the title in Russian or English.' $q) 'Yellow'
    return @()
  }
  Say ''
  $pick = Read-Choice (T 'Which one? (0 = none of these)') @($rows | ForEach-Object { Format-SearchRow $_ }) 0 $true -Key 'search' -Values @($rows | ForEach-Object { [string]$_.Link }) -NoneLabel (T '   0) None of these - back (or Esc)')
  if ($pick -lt 0) { Exit-NavFlow; return @() }   # (in a flow: back to where the title was typed, text kept)
  $row = $rows[$pick]
  $script:LastDub = $null; $script:LastEps = $null; $script:LastPart = $null; $script:LastPlayer = $null
  $items = @()
  try { $items = @(Expand-SiteLink $row.Link) }
  catch { if ($script:CtrlCQuit -or $script:NavSignal) { throw }; Say (T '  Couldn''t use {0}: {1}' (Get-ShortText ([string]$row.Title) 70) $_.Exception.Message) 'Yellow'; return @() }
  if ($items.Count -eq 0) { return @() }
  if ($AskPlayer) { Read-HandoverPlayer $items }
  $script:LastSearchLink = $row.Link
  $choice = Get-SiteChoiceText $items
  if ($choice) { $script:LastSearchLink += '#vrclm=' + $choice }
  return $items
}

# ------------------------------------------------------------------ a Kinopoisk id (WPARTY search result or kinopoisk.ru link)
function Get-SearchMovieSources([string]$kp) {
  if ($script:MovieCheckCache.ContainsKey($kp)) { return , $script:MovieCheckCache[$kp] }
  $src = $null
  try { $src = Get-WpartyMovieSources $kp } catch { return , $null }
  $script:MovieCheckCache[$kp] = $src
  return , $src
}

# Which season / part (several Kodik materials, several Collaps seasons): the one handed over, else ask, else $defPos.
function Select-SitePart($ids, $labels, [int]$defPos, [bool]$canAsk) {
  $pos = $defPos
  $want = $null
  if ($script:SiteChoice) { $want = $script:SiteChoice.Part }
  $hit = -1
  if ($want) { for ($i = 0; $i -lt $ids.Count; $i++) { if ([string]$ids[$i] -eq $want) { $hit = $i; break } } }
  if ($hit -ge 0) { $pos = $hit }
  elseif ($canAsk -and $ids.Count -gt 1) { $pos = Read-Choice (T 'Which season or part?') @($labels) $defPos $false -Key 'part' -Values @($ids | ForEach-Object { [string]$_ }) }
  $script:LastPart = [string]$ids[$pos]
  return $pos
}

# Seasons and episode numbers Collaps has for a Kinopoisk id: list of @{ Season; Numbers }, empty for a film.
function Get-CollapsEpisodes([string]$kp) {
  $r = Invoke-Web -Url "https://$($script:CollapsEmbedHost)/embed/kp/$kp" -TimeoutSec 20
  if ($r.Status -ne 200 -or $r.Text -notmatch 'makePlayer\(') { throw (T 'no player has it') }
  $i = $r.Text.IndexOf('seasons:[')
  if ($i -lt 0) { return @() }
  $list = @()
  foreach ($s in @(ConvertFrom-JsonDict (Get-BalancedLiteral $r.Text ($i + 8)))) {
    $nums = @(@($s['episodes']) | ForEach-Object { Get-LeadingInt $_['episode'] } | Where-Object { $_ -gt 0 } | Select-Object -Unique)
    if ($nums.Count -gt 0 -and -not $s['blocked']) { $list += [pscustomobject]@{ Season = [int]$s['season']; Numbers = $nums } }
  }
  return $list
}

# Queue items for a Kinopoisk id. They are 'wparty' items on a made-up Kodik room, so Get-WpartyCands tries
# Kodik first, then the same voice-over on Dream Cast / CVH / Alloha, and Collaps (same Kinopoisk id) after them.
# $names: the show's titles (for finding it on Dream Cast).
function New-KinopoiskItems([string]$kp, [string]$name, $sources, [string]$sid, [string]$trId, [string]$dub, [int]$season, $numbers, [string]$epTitle, $names = $null) {
  $room = [pscustomobject]@{ Kind = 'movie'; KpId = $kp; Source = $null; SourceUrl = $null; Translation = $trId; ShikimoriId = $sid; Season = $null; Episode = $null; Name = $name; PlaylistData = $null }
  if ($trId) { $room.Source = 'kodik'; $room.SourceUrl = 'https://kodikplayer.com' }
  $names = @($names | Where-Object { $_ })
  $items = New-Object System.Collections.ArrayList
  foreach ($n in @($numbers)) {
    $site = [pscustomobject]@{ Type = 'wparty'; Room = $room; Sources = $sources; DubName = $dub; Season = 0; Episode = 0; Names = $names }
    $key = "kinopoisk:$kp"
    $iname = $name
    if ([int]$n -gt 0) {
      $site.Season = $season; $site.Episode = [int]$n
      $key += ":s$($season)e$n"
      if ($epTitle) { $iname = (T '{0} - episode {1}' $epTitle $n) } else { $iname = (T '{0} - season {1}, episode {2}' $name $season $n) }
    }
    [void]$items.Add((New-SiteItem $key $iname $site))
  }
  if ($script:SiteChoice -and $items.Count -gt 0) { $items[0].ResumeAt = $script:SiteChoice.Start }
  return $items.ToArray()
}

function Test-WpSource($sources, [string]$name) { return (@(@($sources) | Where-Object { $_ -and (Get-WpVal $_ 'name') -eq $name }).Count -gt 0) }

# The voice-over names WPARTY's movieCheck lists for one of its sources (e.g. 'alloha').
function Get-WpSourceDubs($sources, [string]$name) {
  $out = @()
  foreach ($s in @($sources)) { if ($s -and (Get-WpVal $s 'name') -eq $name) { $out += @(Get-WpVal $s 'translations' | Where-Object { $_ } | ForEach-Object { [string](Get-WpVal $_ 'title') } | Where-Object { $_ }) } }
  return $out
}

# Kodik has nothing: Collaps and Alloha by the Kinopoisk id (a film, or a season and episodes). The voice-overs to
# pick from are Alloha's; Collaps then plays the one with the same name when it has it.
function Expand-KinopoiskCollaps([string]$kp, [string]$name, $sources, [bool]$canAsk) {
  $seasons = $null
  try { $seasons = @(Get-CollapsEpisodes $kp) } catch {}
  $al = $null
  if ((Test-WpSource $sources 'alloha') -and (Get-Date) -ge $script:AllohaBlockedUntil) { $al = Get-AllohaCatalog $kp }
  if ($null -eq $seasons -and -not $al) { throw (T 'no player has it') }
  $useAlloha = ($null -eq $seasons -or ($seasons.Count -eq 0 -and $al -and $al.Type -eq 'serial'))
  if ($useAlloha -and $al -and $al.Type -eq 'serial') {
    # Collaps doesn't have it: the seasons and episodes Alloha has.
    $seasons = @()
    $nums = @($al.Translations | ForEach-Object { @($_.Seasons.Keys) } | Select-Object -Unique | Sort-Object { [int]$_ })
    foreach ($sn in $nums) { $seasons += [pscustomobject]@{ Season = [int]$sn; Numbers = @($al.Translations | ForEach-Object { @($_.Seasons[[string]$sn]) } | Where-Object { $_ } | Select-Object -Unique | Sort-Object { [int]$_ }) } }
  }
  if ($null -eq $seasons) { $seasons = @() }
  $se = $null
  if ($seasons.Count -gt 0) {
    $pos = Select-SitePart @($seasons | ForEach-Object { 'S' + $_.Season }) @($seasons | ForEach-Object { T 'season {0} - {1} episodes' $_.Season $_.Numbers.Count }) 0 $canAsk
    $se = $seasons[$pos]
  }
  # Alloha's voice-overs (for that season), best first by DubPriority.
  $dubs = @()
  $alTrs = @()
  if ($al -and $al.Type -eq 'serial' -and $se) { $alTrs = @($al.Translations | Where-Object { $_.Seasons.Contains([string]$se.Season) }); $dubs = @($alTrs | ForEach-Object { $_.Name }) }
  elseif (-not $se) { $dubs = @(Get-WpSourceDubs $sources 'alloha') }
  $dub = ''
  $tr = $null
  if ($dubs.Count -gt 0) {
    $dpos = 0
    if ($script:DubPref) { $i = Find-DubIndex $dubs $script:DubPref; if ($i -ge 0) { $dpos = $i } }
    $dpos = Select-SiteDub $dubs $dpos $canAsk
    $dub = [string]$dubs[$dpos]
    $script:DubPref = $dub
    if ($alTrs.Count -gt 0) { $tr = $alTrs[$dpos] }
  }
  if (-not $se) {
    if ($canAsk) { Say ''; if ($dub) { Say (T 'Found: {0} ({1})' $name $dub) 'White' } else { Say (T 'Found: {0} (plays from Collaps)' $name) 'White' } }
    return @(New-KinopoiskItems $kp $name $sources '' '' $dub 0 @(0) '' @($name))
  }
  $numbers = @($se.Numbers)
  if ($useAlloha -and $tr) { $numbers = @($tr.Seasons[[string]$se.Season]) }   # (what that voice-over has)
  if ($canAsk) {
    Say ''
    if ($dub) { Say (T 'Found: {0}, season {1} ({2} episodes, {3})' $name $se.Season $numbers.Count $dub) 'White' }
    else { Say (T 'Found: {0}, season {1} ({2} episodes, plays from Collaps)' $name $se.Season $numbers.Count) 'White' }
  }
  $list = @($numbers | ForEach-Object { [pscustomobject]@{ Number = [string]$_ } })
  $list = @(Select-SiteEpisodes $list 0 $canAsk)
  $dcName = $name; if ($se.Season -gt 1) { $dcName = "$name $($se.Season)" }
  return @(New-KinopoiskItems $kp $name $sources '' '' $dub $se.Season @($list | ForEach-Object { $_.Number }) '' @($dcName))
}

# Kinopoisk id -> season/part (Kodik materials), voice-over, episodes -> queue items.
function Expand-Kinopoisk([string]$u) {
  $canAsk = Test-CanAsk
  $m = [regex]::Match($u, $script:KinopoiskLinkRe)
  $kp = $m.Groups[2].Value
  $name = Get-QueryParam $u 'name'
  if ($canAsk) { Say (T 'Looking up what can play it...') 'Gray' }
  if (-not $name) { try { $name = Get-WpartyMovieName $kp } catch {} }
  if (-not $name) { $name = "Kinopoisk $kp" }
  $sources = Get-SearchMovieSources $kp
  $kodik = $null
  if ($sources) { foreach ($s in $sources) { if ((Get-WpVal $s 'name') -eq 'kodik') { $kodik = $s } } }
  # Kodik splits a show into materials (one per Shikimori season / part), each with its own voice-overs.
  $mats = @()
  if ($kodik) {
    foreach ($x in @(Get-WpVal $kodik 'materials')) {
      if ($null -eq $x) { continue }
      $trs = @(Get-WpVal $x 'translations' | Where-Object { $_ })
      if ($trs.Count -gt 0) { $mats += [pscustomobject]@{ Sid = [string](Get-WpVal $x 'sid'); Title = [string](Get-WpVal $x 'title'); Trs = $trs } }
    }
    $trs = @(Get-WpVal $kodik 'translations' | Where-Object { $_ })   # films: no materials
    if ($mats.Count -eq 0 -and $trs.Count -gt 0) { $mats += [pscustomobject]@{ Sid = ''; Title = $name; Trs = $trs } }
  }
  if ($mats.Count -eq 0) {
    if ($canAsk) { Say (T '  Kodik doesn''t have it, trying Collaps.') 'Gray' }
    return @(Expand-KinopoiskCollaps $kp $name $sources $canAsk)
  }
  $pos = Select-SitePart @($mats | ForEach-Object { $_.Sid }) @($mats | ForEach-Object { T '{0} - {1} voice-overs' $_.Title $_.Trs.Count }) 0 $canAsk
  $mat = $mats[$pos]
  $names = @($mat.Trs | ForEach-Object { [string](Get-WpVal $_ 'title') })
  $kodikCount = $names.Count
  # The titles Dream Cast would use for this season / part.
  $dcNames = @(ConvertFrom-KodikPartTitle $mat.Title)
  if ($mats.Count -eq 1) { $dcNames += $name }
  # Alloha's voice-overs for this season that Kodik hasn't got (e.g. the official dub of Overlord 1-3) can be picked too.
  $alTrs = @(); $alSeason = 0
  if ((Test-WpSource $sources 'alloha') -and (Get-Date) -ge $script:AllohaBlockedUntil) {
    $al = Get-AllohaCatalog $kp
    if ($al -and $al.Type -eq 'movie' -and $mats.Count -eq 1) {
      # a film: the voice-overs WPARTY lists for Alloha
      foreach ($n in @(Get-WpSourceDubs $sources 'alloha')) { if ((Find-DubIndex $names $n) -lt 0) { $names += $n; $alTrs += [pscustomobject]@{ Id = ''; Name = $n; Seasons = $null } } }
    } else {
      if ($al -and $al.Type -eq 'serial') {
        $ms = [regex]::Match($mat.Title, $script:WpSeasonRx)
        if ($ms.Success) { $alSeason = [int]$ms.Groups[1].Value }
        elseif ($mats.Count -eq 1) {
          $all = @($al.Translations | ForEach-Object { @($_.Seasons.Keys) } | Select-Object -Unique)
          if ($all.Count -eq 1) { $alSeason = [int]$all[0] }   # (only when it can't be another season)
        }
        if ($alSeason -gt 0) {
          foreach ($t in $al.Translations) { if ($t.Seasons.Contains([string]$alSeason) -and (Find-DubIndex $names $t.Name) -lt 0) { $names += $t.Name; $alTrs += $t } }
        }
      }
    }
  }
  $dpos = 0
  if ($script:DubPref) { $i = Find-DubIndex $names $script:DubPref; if ($i -ge 0) { $dpos = $i } }
  $dpos = Select-SiteDub $names $dpos $canAsk
  $dub = $names[$dpos]
  $script:DubPref = $dub
  $epTitle = ''
  if ($mats.Count -gt 1) { $epTitle = $mat.Title }
  if ($dpos -ge $kodikCount) {
    # A voice-over only Alloha has.
    $t = $alTrs[$dpos - $kodikCount]
    if (-not $t.Seasons) {
      if ($canAsk) { Say ''; Say (T 'Found: {0} ({1})' $mat.Title $dub) 'White' }
      return @(New-KinopoiskItems $kp $name $sources $mat.Sid '' $dub 0 @(0) '' $dcNames)
    }
    $list = @(@($t.Seasons[[string]$alSeason]) | ForEach-Object { [pscustomobject]@{ Number = [string]$_ } })
    if ($canAsk) { Say ''; Say (T 'Found on Alloha: {0} ({1} episodes, {2})' $mat.Title $list.Count $dub) 'White' }
    $list = @(Select-SiteEpisodes $list 0 $canAsk)
    return @(New-KinopoiskItems $kp $name $sources $mat.Sid '' $dub $alSeason @($list | ForEach-Object { $_.Number }) $epTitle $dcNames)
  }
  $trId = [string](Get-WpVal $mat.Trs[$dpos] 'id')
  $idPart = 'kinopoiskID=' + $kp
  if ($mat.Sid) { $idPart = 'shikimoriID=' + $mat.Sid }
  $k = $null
  try { $k = Get-KodikEpisodes ('https://kodikplayer.com/find-player?' + $idPart + '&onlyTranslationID=[' + $trId + ']') }
  catch {
    if ($canAsk) { Say (T '  Kodik doesn''t have it, trying Collaps.') 'Gray' }
    return @(Expand-KinopoiskCollaps $kp $name $sources $canAsk)
  }
  $eps = @($k.Episodes | Where-Object { $_.Season -eq $k.CurrentSeason -and $_.Episode -gt 0 })
  if ($eps.Count -eq 0) { $eps = @($k.Episodes | Where-Object { $_.Episode -gt 0 }) }
  if ($k.Type -eq 'video' -or $eps.Count -eq 0) {
    if ($canAsk) { Say ''; Say (T 'Found: {0} ({1})' $mat.Title $dub) 'White' }
    return @(New-KinopoiskItems $kp $name $sources $mat.Sid $trId $dub 0 @(0) '' $dcNames)
  }
  $season = [int]$eps[0].Season
  if ($season -le 0) { $season = 1 }
  $list = @($eps | ForEach-Object { [string]$_.Episode } | Select-Object -Unique | ForEach-Object { [pscustomobject]@{ Number = $_ } })
  if ($canAsk) { Say ''; Say (T 'Found on Kodik: {0} ({1} episodes, {2})' $mat.Title $list.Count $dub) 'White' }
  $list = @(Select-SiteEpisodes $list 0 $canAsk)
  return @(New-KinopoiskItems $kp $name $sources $mat.Sid $trId $dub $season @($list | ForEach-Object { $_.Number }) $epTitle $dcNames)
}

# ------------------------------------------------------------------ a Shikimori anime (search result or shikimori link): Kodik by its id
function Expand-Shikimori([string]$u) {
  $canAsk = Test-CanAsk
  $sid = [regex]::Match($u, $script:ShikimoriLinkRe).Groups[1].Value
  if ($canAsk) { Say (T 'Looking up what can play it...') 'Gray' }
  $k = $null
  try { $k = Get-KodikEpisodes ('https://kodikplayer.com/find-player?shikimoriID=' + $sid) }
  catch { throw (T 'Kodik has no video of this anime (yet)') }
  $title = Get-QueryParam $u 'name'
  if (-not $title) { $title = [string]$k.Title }
  if (-not $title) { $title = "Shikimori $sid" }
  $trs = @($k.Translations | Where-Object { $_.Id -gt 0 })
  $dub = [string]$k.TranslationTitle
  if ($trs.Count -gt 0) {
    $names = @($trs | ForEach-Object { [string]$_.Title })
    $pos = 0
    for ($i = 0; $i -lt $trs.Count; $i++) { if ($trs[$i].Id -eq $k.TranslationId) { $pos = $i } }
    if ($script:DubPref) { for ($i = 0; $i -lt $names.Count; $i++) { if (Test-SameDub $names[$i] $script:DubPref) { $pos = $i; break } } }
    $pos = Select-SiteDub $names $pos $canAsk
    $dub = $names[$pos]
    $script:DubPref = $dub
    if ($trs[$pos].Id -ne $k.TranslationId -and $trs[$pos].MediaId) { $k = Get-KodikEpisodes $trs[$pos].Url }
  }
  $eps = @($k.Episodes | Where-Object { $_.Season -eq $k.CurrentSeason -and $_.Episode -gt 0 })
  if ($eps.Count -eq 0) { $eps = @($k.Episodes | Where-Object { $_.Episode -gt 0 }) }
  $items = New-Object System.Collections.ArrayList
  $names = @($title, [string]$k.Title | Where-Object { $_ } | Select-Object -Unique)
  if ($k.Type -eq 'video' -or $eps.Count -eq 0) {
    if ($canAsk) { Say ''; Say (T 'Found: {0} ({1})' $title $dub) 'White' }
    $site = [pscustomobject]@{ Type = 'shikimori'; Cand = (New-Cand 'kodik' ([string]$k.PlayerUrl) '' $dub); Sid = $sid; Names = $names; Season = 0; Episode = 0; DubName = $dub }
    [void]$items.Add((New-SiteItem ("shikimori:$sid") $title $site))
  } else {
    $list = @($eps | ForEach-Object { [pscustomobject]@{ Number = [string]$_.Episode; Ep = $_ } })
    if ($canAsk) { Say ''; Say (T 'Found on Kodik: {0} ({1} episodes, {2})' $title $list.Count $dub) 'White' }
    $list = @(Select-SiteEpisodes $list 0 $canAsk)
    foreach ($e in $list) {
      $site = [pscustomobject]@{ Type = 'shikimori'; Cand = (New-Cand 'kodik' $e.Ep.Url '' $dub); Sid = $sid; Names = $names; Season = [int]$e.Ep.Season; Episode = [int]$e.Ep.Episode; DubName = $dub }
      [void]$items.Add((New-SiteItem ("shikimori:$($sid):e$($e.Number)") (T '{0} - episode {1}' $title $e.Number) $site))
    }
  }
  if ($script:SiteChoice -and $items.Count -gt 0) { $items[0].ResumeAt = $script:SiteChoice.Start }
  return $items.ToArray()
}

# A Shikimori item: its Kodik episode, plus the same voice-over on Dream Cast's own site and CVH.
function Get-ShikimoriCands($s) {
  $list = New-Object System.Collections.ArrayList
  Add-RankedCand $list $s.Cand 0
  foreach ($c in @(Get-ExtraCands @{ Dub = $s.DubName; Names = @($s.Names); Sid = $s.Sid; Season = $s.Season; Episode = $s.Episode; Skip = @('alloha') })) { Add-RankedCand $list $c 0 }
  return (Get-RankedCands $list)
}

# ------------------------------------------------------------------ candidates and resolving
function Get-SiteCandidates($item) {
  $s = $item.Site
  if ($s.Type -eq 'animego') { return (Get-AnimegoCands $s) }
  if ($s.Type -eq 'animelib') { return (Get-AnimelibCands $s) }
  if ($s.Type -eq 'wparty') { return (Get-WpartyCands $s) }
  if ($s.Type -eq 'shikimori') { return (Get-ShikimoriCands $s) }
  return @($s.Cands)
}

# Turns one candidate (a player link) into a stream: Url, Kind, Headers, Duration, LiveOnly.
function Resolve-Candidate($c) {
  $cap = Get-QualityCap
  $st = $null
  switch ($c.Provider) {
    'kodik' {
      $r = Resolve-Kodik $c.Url $c.Referer $c.Season $c.Episode $cap
      $st = New-Stream $r.Url 'hls' (ConvertTo-HeaderTable $r.Headers)
      if ($r.Duration) { $st.Duration = [double]$r.Duration }
      if ($r.TranslationTitle -and -not $c.Dub) { $c.Label = "Kodik, $($r.TranslationTitle)" }
    }
    'aniboom' {
      $r = Resolve-Aniboom -embedUrl $c.Url -referer $c.Referer
      $kind = 'hls'
      if ($r.Kind -ne 'hls') { $kind = 'file' }
      $st = New-Stream $r.Url $kind (ConvertTo-HeaderTable $r.Headers)
      if ($r.Duration) { $st.Duration = [double]$r.Duration }
    }
    'sibnet' {
      $r = Resolve-Sibnet -playerUrl $c.Url -referer $c.Referer -NoProbe
      $st = New-Stream $r.Url 'file' (ConvertTo-HeaderTable $r.Headers)
      if ($r.Duration) { $st.Duration = [double]$r.Duration }
    }
    'cvh' {
      $np = [bool]($c.PSObject.Properties['NoPage'] -and $c.NoPage)
      $r = Resolve-Cvh -playerUrl $c.Url -referer $c.Referer -MaxHeight $cap -NoPage:$np
      $st = New-Stream $r.Url 'file' (ConvertTo-HeaderTable $r.Headers)
      if ($r.Duration) { $st.Duration = [double]$r.Duration }
    }
    'dreamcast' {
      # Dream Cast's own HLS (AV1 + AAC); Complete-HlsStream picks the quality and works out the length.
      $st = New-Stream $c.Url 'hls' @{ 'Referer' = $script:DreamcastBase + '/' }
    }
    'aniliberty' {
      # One playlist per quality: the tallest one not taller than what is sent.
      $u = $c.Url
      if ($c.PSObject.Properties['Hls'] -and $c.Hls) { $u = Select-AnilibertyHls $c.Hls $cap }
      $st = New-Stream $u 'hls' @{}
      if ($c.PSObject.Properties['Duration'] -and $c.Duration -gt 0) { $st.Duration = [double]$c.Duration }
    }
    'animevost' {
      # 720p when its file is there (the list names one for every episode, but some are missing), else 480p.
      $u = $c.Url; $alt = $null
      if ($c.PSObject.Properties['Std']) { $alt = [string]$c.Std }
      if ($alt -and $alt -ne $u -and ($cap -le 480 -or -not (Test-WebFileThere $u))) { $u = $alt }
      $st = New-Stream $u 'file' @{}
    }
    'animelib' {
      $r = Resolve-AnimelibVideo $c.Source $cap -NoProbe
      $st = New-Stream $r.Url $r.Kind (ConvertTo-HeaderTable $r.Headers)
      if ($r.Duration) { $st.Duration = [double]$r.Duration }
    }
    'collaps' {
      $r = Resolve-Collaps -KinopoiskId $c.Url -Season $c.Season -Episode $c.Episode -PreferAudio $c.Dub
      $st = New-Stream $r.VideoUrl 'hls' (ConvertTo-HeaderTable $r.Headers)
      if (-not $r.VideoUrl) { $st.Url = $r.Url }
      elseif ($r.AudioUrl) { $st.AudioUrl = $r.AudioUrl }
      if ($r.Duration) { $st.Duration = [double]$r.Duration }
      if ($r.Audio) { $c.Label = "Collaps, $($r.Audio)" }
      if ($r.Warning) { $c.Note = $r.Warning }
    }
    'alloha' {
      $r = $null
      try { $r = Resolve-Alloha -IframeUrl $c.Url -Referer $c.Referer -MaxHeight $cap }
      catch {
        $err = $_
        $msg = $err.Exception.Message
        if ($msg -match 'client_blocked|token_decrypt|session_blocked') { $script:AllohaBlockedUntil = (Get-Date).AddMinutes(30) }
        # A link made with WPARTY's Alloha token (New-AllohaCand): the token may have changed. Ask WPARTY once per session.
        $a = $null
        if ($c.PSObject.Properties['AllohaArgs']) { $a = $c.AllohaArgs }
        if (-not $a -or $msg -notmatch 'player page HTTP 40[134]' -or $script:AllohaBaseRenewed) { throw $err }
        $script:AllohaBaseRenewed = $true
        $nb = $null
        try { $nb = Get-WpartyOwnSourceUrl 'alloha' $a.KpId $a.Translation } catch {}
        if (-not $nb -or $nb -eq $a.SourceUrl) { throw $err }
        $script:AllohaBase = $nb
        $a.SourceUrl = $nb
        $c.Url = Get-WpartyPlayerUrl $a
        $r = Resolve-Alloha -IframeUrl $c.Url -Referer $c.Referer -MaxHeight $cap
      }
      $st = New-Stream $r.Url 'hls' (ConvertTo-HeaderTable $r.Headers)
      $st.LiveOnly = $true
      if ($r.Warning) { $c.Note = $r.Warning }
    }
    default { throw (T 'unknown player ''{0}''' $c.Provider) }
  }
  if (-not $st -or -not $st.Url) { throw (T 'no video address found') }
  return $st
}
