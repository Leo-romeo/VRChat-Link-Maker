# VRChat Link Maker
# ------------------
# Turns any video file (or a link to a video on a website) into a live stream
# on Topaz Chat, a free streaming server that VRChat trusts. The link it gives
# you plays in any world's video player (Stream / Live mode), for everyone,
# without anybody changing settings.
#
# Links to AnimeGO anime pages and WPARTY rooms work too: it finds the video
# the site's own player would show (Kodik, AniBoom, Alloha, Sibnet, ...).
#
# Start it with "Make VRChat Link.bat". Needs ffmpeg (it offers to install it).
# Settings live in config.json next to this file (created on first run).

$ErrorActionPreference = 'Stop'
$script:Version = '1.7'
$script:Args0 = @($args)

# ------------------------------------------------------------------ basics
$script:ToolDir = $PSScriptRoot
if (-not $script:ToolDir) { $script:ToolDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:DataDir = $script:ToolDir
if ($env:VRCLM_DATA) { $script:DataDir = $env:VRCLM_DATA }
$script:TempRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'VRCLinkMaker')
$script:IsWin = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
$script:Interactive = -not $env:VRCLM_AUTO
$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:IdleMinutes = 15.0
if ($env:VRCLM_IDLE_MIN) { $script:IdleMinutes = [double]$env:VRCLM_IDLE_MIN }

$script:Queue = New-Object System.Collections.ArrayList
$script:BgProcs = New-Object System.Collections.ArrayList
$script:Idx = 0
$script:Relay = $null
$script:RelayIn = $null
$script:Current = $null
$script:RelayFails = 0
$script:StopAll = $false
$script:TrackPref = $null
$script:TypeBuf = ''
$script:Armed = $null
$script:ArmedAt = [datetime]::MinValue
$script:StatusShown = $false
$script:MutexOwned = $false
$script:NoPause = $false
$script:YtDlp = $null
$script:YtDlpAsked = $false
$script:IdleAnnounced = $false
$script:CanSubs = $true
$script:LastEnd = -1.0
$script:RelayStartedAt = Get-Date
$script:SlateNoText = $false
$script:DubPref = $null
$script:DubChoice = $null   # (the voice-over a person picked this session; DubPref also holds automatic picks)
$script:Paused = $false
$script:PausedAt = 0.0
$script:PauseMaxMinutes = 120.0
$script:VideoKbps = 1350
$script:RateCapKbps = 0               # the video bitrate ceiling written into the H.264 header (fixed per connection)
$script:NeedResync = $false           # a change that alters the H.264 header: the players reconnect once
$script:KbpsSteps = 0
$script:CpuPreset = $null
$script:NvTier = 3
$script:EncoderProven = $false
$script:SlowSpeed = $null
$script:ScriptFile = $PSCommandPath
if (-not $script:ScriptFile) { $script:ScriptFile = $MyInvocation.MyCommand.Path }
$script:StreamFps = '24000/1001'      # one frame rate for everything a session streams (see Set-FpsPlan)
$script:StreamFpsNum = 24000.0 / 1001.0
$script:ViewerDelay = 5.0             # how far behind live viewers see the stream (measured from VRChat's log when it can)
$script:StartDelay = 3.0              # once the world's player shows the stream, give the other viewers' players this long
$script:ResumeBack = 2.0              # continue this many seconds before the point where it was paused
$script:HoldOn = $true                # a video waits until the world's player shows the stream
$script:HoldOnDrop = $true            # ...and waits again while that player lost the stream
$script:ResyncAfterPlayerPause = 3.0  # after the TV's own pause (this long or more) everyone reconnects when it plays again
$script:ClockOn = $false
$script:ClockFont = 'fonts/arialbd.ttf'
$script:PanelShown = $false
$script:ChoosingMode = $true          # nothing has streamed yet (or it was stopped): questions are fine
$script:PendingHold = $null
$script:RelayFresh = $false
$script:FpsLocked = $false            # a video started on this connection: its frame rate is fixed (Select-SessionFps)
$script:RelayErr = $null
$script:LastStatus = ''
$script:ControlsShown = $false
$script:DelayTipShown = $false
$script:ArmedChar = $null
$script:ShownLink = ''
$script:LogWriter = $null
$script:LastRefreshSrc = ''          # why ProTV's next load happens (_ChangeMedia, _PostDeserialization, AutoRetry, play)
$script:RenewedAt = [datetime]::MinValue
$script:ResyncedAt = [datetime]::MinValue
$script:ReconnectNote = $false
$script:QueueFinished = $false
$script:PanelState = $null

$script:HasConsole = $false
if ($script:Interactive) { try { [void][Console]::KeyAvailable; $script:HasConsole = $true } catch { $script:HasConsole = $false } }

# Python tools (yt-dlp) print UTF-8 when their output is captured.
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'

$script:MediaExts = @('.mkv', '.mp4', '.m4v', '.avi', '.mov', '.webm', '.ts', '.m2ts', '.mts', '.wmv', '.flv',
  '.mpg', '.mpeg', '.vob', '.ogv', '.3gp', '.f4v', '.rmvb', '.rm', '.divx', '.asf', '.mka',
  '.mp3', '.flac', '.m4a', '.aac', '.ogg', '.opus', '.wav', '.wma')
$script:SubExts = @('.ass', '.ssa', '.srt', '.vtt')
$script:TextSubCodecs = @('ass', 'ssa', 'subrip', 'srt', 'webvtt', 'mov_text', 'text', 'microdvd', 'mpl2',
  'jacosub', 'sami', 'realtext', 'subviewer', 'subviewer1', 'vplayer', 'pjs', 'stl')
$script:BitmapSubCodecs = @('hdmv_pgs_subtitle', 'dvd_subtitle', 'dvb_subtitle', 'xsub')
$script:LangNames = @{
  'jpn' = 'Japanese'; 'ja' = 'Japanese'; 'eng' = 'English'; 'en' = 'English'; 'spa' = 'Spanish'; 'es' = 'Spanish'
  'por' = 'Portuguese'; 'pt' = 'Portuguese'; 'fre' = 'French'; 'fra' = 'French'; 'fr' = 'French'
  'ger' = 'German'; 'deu' = 'German'; 'de' = 'German'; 'ita' = 'Italian'; 'it' = 'Italian'
  'rus' = 'Russian'; 'ru' = 'Russian'; 'ukr' = 'Ukrainian'; 'uk' = 'Ukrainian'; 'pol' = 'Polish'; 'pl' = 'Polish'
  'chi' = 'Chinese'; 'zho' = 'Chinese'; 'zh' = 'Chinese'; 'kor' = 'Korean'; 'ko' = 'Korean'
  'ara' = 'Arabic'; 'ar' = 'Arabic'; 'tur' = 'Turkish'; 'tr' = 'Turkish'; 'ind' = 'Indonesian'; 'id' = 'Indonesian'
  'tha' = 'Thai'; 'th' = 'Thai'; 'vie' = 'Vietnamese'; 'vi' = 'Vietnamese'; 'hin' = 'Hindi'
  'dut' = 'Dutch'; 'nld' = 'Dutch'; 'nl' = 'Dutch'; 'swe' = 'Swedish'; 'cze' = 'Czech'; 'ces' = 'Czech'; 'cs' = 'Czech'
  'hun' = 'Hungarian'; 'rum' = 'Romanian'; 'ron' = 'Romanian'; 'gre' = 'Greek'; 'ell' = 'Greek'
  'heb' = 'Hebrew'; 'fin' = 'Finnish'; 'nor' = 'Norwegian'; 'dan' = 'Danish'; 'bul' = 'Bulgarian'
  'hrv' = 'Croatian'; 'srp' = 'Serbian'; 'slo' = 'Slovak'; 'slk' = 'Slovak'; 'may' = 'Malay'; 'msa' = 'Malay'
  'fil' = 'Filipino'; 'tgl' = 'Tagalog'
}

# ------------------------------------------------------------------ small helpers
function PathJoin([string]$a, [string]$b) { return [System.IO.Path]::Combine($a, $b) }

function Format-Num([double]$x) { return $x.ToString('0.###', $script:Inv) }

function Format-Time([double]$sec) {
  if ([double]::IsNaN($sec) -or $sec -lt 0) { $sec = 0 }
  $t = [int64][Math]::Floor($sec)
  $h = [int64][Math]::Floor($t / 3600)
  $m = [int64][Math]::Floor(($t % 3600) / 60)
  $s = $t % 60
  if ($h -gt 0) { return ('{0}:{1:00}:{2:00}' -f $h, $m, $s) }
  return ('{0}:{1:00}' -f $m, $s)
}

function Get-ConsoleWidth {
  try { $w = [Console]::WindowWidth - 1; if ($w -ge 30) { return $w } } catch {}
  return 79
}

function Clear-StatusLine {
  try { if ($script:UiBus.Status) { $script:UiBus.Status = $null } } catch {}
  if ($script:StatusShown) {
    $w = Get-ConsoleWidth
    Write-Host ("`r" + (' ' * $w) + "`r") -NoNewline
    $script:StatusShown = $false
  }
}

function Say([string]$text, [string]$color = '') {
  # (While a flow re-runs its earlier answers after a Back, what it said before is only written to log.txt.)
  if ($script:Nav -and $script:Nav.Replaying) { Write-LogLine $text; return }
  Clear-StatusLine
  if ($color) { Write-Host $text -ForegroundColor $color } else { Write-Host $text }
  Write-LogLine $text
  Add-UiLogLine $text $color
}

# The control window's message pane gets every Say line: the window drains the queue, and the ring refills a reopened window.
$script:UiLog = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$script:UiLogRing = New-Object 'System.Collections.Generic.List[object]'
# The bus between this thread and the control window: made once, so it outlives the window (a language change or F2
# opens a new window on the same bus: no click, question or answer is lost). Log = the message lines (above); Cmds =
# the window's clicks ({Cmd; Arg}); Ask = the question open now (a copy for the window, see Publish-UiAsk) or $null;
# Answers = the window's answers ({Id; Nav; Text; Pick; Yes; Files}); Status = the console's status line
# ({Text; At}, while it shows one); QuitReq = End stream was clicked (Test-UiQuit).
$script:UiBus = [hashtable]::Synchronized(@{
    Log = $script:UiLog; Cmds = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Ask = $null
    Answers = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Status = $null; QuitReq = $false })
function Add-UiLogLine([string]$text, [string]$color) {
  try {
    $e = @($text, $color)
    $script:UiLogRing.Add($e)
    if ($script:UiLogRing.Count -gt 600) { $script:UiLogRing.RemoveRange(0, 100) }
    $script:UiLog.Enqueue($e)
    $drop = $null
    while ($script:UiLog.Count -gt 2000) { [void]$script:UiLog.TryDequeue([ref]$drop) }
  } catch {}
}

# Everything the window says also goes into log.txt next to the tool (the previous run's is log-previous.txt).
function Open-Log {
  try {
    $p = PathJoin $script:DataDir 'log.txt'
    if ([System.IO.File]::Exists($p)) { try { [System.IO.File]::Copy($p, (PathJoin $script:DataDir 'log-previous.txt'), $true) } catch {} }
    $script:LogWriter = New-Object System.IO.StreamWriter($p, $false, $script:Utf8NoBom)
    $script:LogWriter.AutoFlush = $true
  } catch { $script:LogWriter = $null }
}

function Write-LogLine([string]$text) {
  if (-not $script:LogWriter) { return }
  # Player links carry access tokens (Alloha's token= / token_movie=): not in the log file.
  if ($text.IndexOf('token', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $text = [regex]::Replace($text, '(?i)([?&](?:token|token_movie)=)[^&#\s''"]+', '$1***') }
  try { $script:LogWriter.WriteLine((Get-Date).ToString('HH:mm:ss', $script:Inv) + '  ' + $text) } catch {}
}

# Is the window scrolled up (someone reading what it said earlier)? Writing there would jump it back down.
function Test-ScrolledUp {
  try { return ([Console]::CursorTop -ge [Console]::WindowTop + [Console]::WindowHeight) } catch { return $false }
}

# A status line that ends in keys ("...   Q Q = end" + $more = "   M = menu"): when it is wider than the window, the
# text before the keys is cut ("...") instead of the keys (Show-Status cuts at the right edge). Console only: the
# control window gets the whole text.
function Join-StatusKeys([string]$s, [string]$more) {
  $w = Get-ConsoleWidth
  if ($s.Length -le $w -or -not $more -or -not $s.EndsWith($more)) { return $s }
  $main = $s.Substring(0, $s.Length - $more.Length)
  $cut = $main.LastIndexOf('   ')
  if ($cut -le 0) { return $s }
  $tail = $main.Substring($cut) + $more
  $room = $w - $tail.Length - 3
  if ($room -lt 20) { return $s }
  return ($main.Substring(0, $room).TrimEnd() + '...' + $tail)
}

# -NoWindow: a status the control window gets in its own way (Update-Panel); others (a download's %, the speed test)
# show in the window's status line too while they are fresh.
function Show-Status([string]$text, [switch]$NoWindow) {
  if (-not $NoWindow) { try { $script:UiBus.Status = @{ Text = $text.Trim(); At = [DateTime]::UtcNow } } catch {} }
  if (-not $script:HasConsole) { return }
  if (Test-ScrolledUp) { return }
  $w = Get-ConsoleWidth
  if ($text.Length -gt $w) { $text = $text.Substring(0, $w) }
  Write-Host ("`r" + $text.PadRight($w)) -NoNewline
  $script:StatusShown = $true
}

function Get-Prop($obj, [string]$name) {
  if ($null -eq $obj) { return $null }
  $p = $obj.PSObject.Properties[$name]
  if ($p) { return $p.Value }
  return $null
}

# ------------------------------------------------------------------ language
# Everything the window says is written in English in these files. T looks each text up in
# lang\<code>.json ("English text": "translation") and keeps the English when there's no translation.
# {0}, {1}, ... in a text are filled in with the values given after it:  T 'Queued {0} videos:' $n
# Adding a language: copy lang\ru.json to lang\<code>.json (<code> = the language's two-letter code,
# e.g. de, uk, ja), translate the values and set "_language" to the language's own name for itself.
# It then shows up in the language menu (type L on the start screen) and can be set in config.json.
$script:LangDir = PathJoin $script:ToolDir 'lang'
$script:Lang = 'en'
$script:LangSetting = 'auto'
$script:Tr = $null

function T([string]$text) {
  $s = $text
  if ($script:Tr) { $v = $null; if ($script:Tr.TryGetValue($text, [ref]$v) -and $v) { $s = $v } }
  if ($args.Count -eq 0) { return $s }
  try { return ($s -f $args) } catch { try { return ($text -f $args) } catch { return $s } }
}

# Is the answer to a "[Y/n]" question a no? "n" / "N" at the start means no; anything else, Enter included, is yes.
# In a translated window (the question then ends in Cyrillic "[D/n]") the Cyrillic "n" (U+043D / U+041D) means no too.
# Not in the English window: there that letter is what the Y key types while a Russian keyboard layout is on. There
# Russian "ne..." / "net" (U+043D U+0435 ...) is no, and a lone U+0442 (what the N key types on that layout).
# (These .ps1 files stay plain ASCII: Windows PowerShell misreads other characters in files without a BOM.)
function Test-AnswerNo([string]$ans) {
  if ($ans -match '^\s*[nN]') { return $true }
  if ($script:Lang -ne 'en') { return ($ans -match '^\s*[\u043d\u041d]') }
  return ($ans -match '^\s*(?:[\u043d\u041d][\u0435\u0415]|[\u0442\u0422]\s*$)')
}

function Get-ConfigPath {
  if ($env:VRCLM_CONFIG) { return $env:VRCLM_CONFIG }
  return (PathJoin $script:DataDir 'config.json')
}

function Get-LangPath([string]$code) { return (PathJoin $script:LangDir ($code + '.json')) }

# lang\<code>.json -> Dictionary (case-sensitive, so "Paused" and "paused" can differ). $null when there's no such file.
function Read-LangFile([string]$code) {
  $p = Get-LangPath $code
  if (-not [System.IO.File]::Exists($p)) { return $null }
  $raw = ConvertFrom-JsonDict ([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8))
  $d = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
  foreach ($k in @($raw.Keys)) { $v = $raw[$k]; if ($v -is [string] -and $v) { $d[[string]$k] = $v } }
  return $d
}

# English (built in) plus one entry per readable lang\<code>.json, named by its "_language".
# Ask = that language's "Which language should this window use?", so the menu can ask in every language.
function Get-Languages {
  $askKey = 'Which language should this window use?'
  $list = @([pscustomobject]@{ Code = 'en'; Name = 'English'; Ask = $askKey })
  $files = @()
  try { if ([System.IO.Directory]::Exists($script:LangDir)) { $files = @([System.IO.Directory]::GetFiles($script:LangDir, '*.json') | Sort-Object) } } catch {}
  foreach ($f in $files) {
    $code = [System.IO.Path]::GetFileNameWithoutExtension($f).ToLowerInvariant()
    if ($code -eq 'en') { continue }
    $name = $code
    $ask = $askKey
    try {
      $d = Read-LangFile $code
      if (-not $d) { continue }
      if ($d.ContainsKey('_language')) { $name = $d['_language'] }
      if ($d.ContainsKey($askKey)) { $ask = $d[$askKey] }
    } catch { continue }
    $list += [pscustomobject]@{ Code = $code; Name = $name; Ask = $ask }
  }
  return $list
}

# The "Language" setting, read before anything else (config.json may not exist yet).
function Get-LanguageSetting {
  if ($env:VRCLM_LANG) { return $env:VRCLM_LANG }
  try {
    $p = Get-ConfigPath
    if ([System.IO.File]::Exists($p)) {
      $l = [string](Get-Prop ([System.IO.File]::ReadAllText($p) | ConvertFrom-Json) 'Language')
      if ($l) { return $l }
    }
  } catch {}
  return 'auto'
}

# "auto" = Windows' display language when there's a translation for it, else English.
# (Its messages stay English: they're shown exactly when the translation can't be used.)
function Initialize-Language([string]$want) {
  $code = "$want".Trim().ToLowerInvariant()
  if (-not $code) { $code = 'auto' }
  $script:LangSetting = $code
  if ($code -eq 'auto') {
    $code = 'en'
    try { $ui = (Get-UICulture).TwoLetterISOLanguageName.ToLowerInvariant(); if ($ui -and [System.IO.File]::Exists((Get-LangPath $ui))) { $code = $ui } } catch {}
  }
  $script:Lang = 'en'
  $script:Tr = $null
  if ($code -eq 'en') { return }
  try {
    $d = Read-LangFile $code
    if ($d) { $script:Tr = $d; $script:Lang = $code }
    else { Say "There is no lang\$code.json, so the window stays in English." 'Yellow' }
  } catch { Say "lang\$code.json could not be read ($($_.Exception.Message)), so the window stays in English." 'Yellow' }
}

function Save-LanguageSetting([string]$code) {
  try {
    if ($script:Cfg -and $script:Cfg.PSObject.Properties['Language']) { $script:Cfg.Language = $code }
    $p = Get-ConfigPath
    if (-not [System.IO.File]::Exists($p)) { return }   # first run: Get-Config writes it with $script:LangSetting
    # Only "Language" changes, in the file as it is now. Not $script:Cfg: that also holds the defaults Get-Config filled
    # in, which must stay out of the file (a later version may change them, as happened with VideoKbps).
    $cfg = [System.IO.File]::ReadAllText($p) | ConvertFrom-Json
    if ([string](Get-Prop $cfg 'Language') -ceq $code) { return }
    if ($cfg.PSObject.Properties['Language']) { $cfg.Language = $code } else { $cfg | Add-Member -NotePropertyName 'Language' -NotePropertyValue $code }
    $script:ConfigPath = $p
    Save-Config $cfg
  } catch { Say (T 'Couldn''t save the language in config.json: {0}' $_.Exception.Message) 'Yellow' }
}

# Asks which language the window should use (Enter keeps the current one) and remembers it in config.json.
# -Pick: the language code already chosen (the control window's menu): no question.
function Select-Language([string]$Pick = '') {
  $langs = @(Get-Languages)
  if ($langs.Count -lt 2) { Say (T 'No translations found (the "lang" folder next to this tool is missing or empty).') 'Yellow'; return }
  $cur = 0
  $pos = -1
  for ($i = 0; $i -lt $langs.Count; $i++) {
    if ($langs[$i].Code -eq $script:Lang) { $cur = $i }
    if ($Pick -and $langs[$i].Code -eq $Pick) { $pos = $i }
  }
  if ($pos -lt 0) {
    Say ''
    # Asked in every language at once (the current one first), so it can be read whatever the window speaks now.
    $asks = @(@($langs[$cur].Ask) + @($langs | ForEach-Object { $_.Ask }) | Select-Object -Unique)
    $pos = Read-Choice ($asks -join ' / ') @($langs | ForEach-Object { $_.Name }) $cur $false -Key 'lang' -Values @($langs | ForEach-Object { $_.Code }) -Esc $cur
  }
  $code = $langs[$pos].Code
  Lock-NavStep
  Initialize-Language $code
  Save-LanguageSetting $code
  if ($script:SlateDir) { Initialize-Slate }   # the "Paused" / "Next video" screens viewers see
}

# Is there a language to switch to (a lang\*.json that can be read)?
function Test-HasTranslations {
  try { return (@(Get-Languages).Count -gt 1) } catch { return $false }
}

function Get-LastLines([string]$text, [int]$n) {
  if (-not $text) { return '' }
  $lines = @($text -split "[`r`n]+" | Where-Object { $_.Trim() })
  if ($lines.Count -eq 0) { return '' }
  $from = [Math]::Max(0, $lines.Count - $n)
  return (($lines[$from..($lines.Count - 1)]) -join ' / ')
}

function Get-NaturalKey([string]$s) {
  return [regex]::Replace($s.ToLowerInvariant(), '\d+', { param($m) $m.Value.PadLeft(12, '0') })
}

function Get-ShortText([string]$s, [int]$max) {
  if ($s.Length -le $max) { return $s }
  return $s.Substring(0, $max - 3) + '...'
}

# Quote one argument the way Windows programs (and ffmpeg) split command lines.
function ConvertTo-CmdArg([string]$a) {
  if ($null -eq $a) { $a = '' }
  if ($a.Length -gt 0 -and $a -notmatch '[\s"]') { return $a }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  $bs = 0
  foreach ($ch in $a.ToCharArray()) {
    if ($ch -eq [char]'\') { $bs++; continue }
    if ($ch -eq [char]'"') {
      [void]$sb.Append(('\' * ($bs * 2 + 1)))
      [void]$sb.Append('"')
      $bs = 0
      continue
    }
    if ($bs -gt 0) { [void]$sb.Append(('\' * $bs)); $bs = 0 }
    [void]$sb.Append($ch)
  }
  if ($bs -gt 0) { [void]$sb.Append(('\' * ($bs * 2))) }
  [void]$sb.Append('"')
  return $sb.ToString()
}

function Join-CmdArgs([string[]]$list) {
  $parts = @(foreach ($x in $list) { ConvertTo-CmdArg $x })
  return ($parts -join ' ')
}

# ------------------------------------------------------------------ child processes
# Every program this tool starts (ffmpeg, yt-dlp, MediaMTX, ffplay) goes into one Windows job that closes when this
# tool's process ends, however it ends (Q Q, the window's X button, a crash, Task Manager): nothing keeps streaming,
# downloading or serving after it. TailReader keeps only the end of a program's output (the relay's progress went to
# a file before, which grew by about 7 MB an hour). Compiled once, then loaded from a cached DLL (faster starts).
$script:HelperSource = @'
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
namespace VRCLinkMaker {
  public static class ChildJob {
    [StructLayout(LayoutKind.Sequential)] struct Basic { public long A; public long B; public uint LimitFlags; public UIntPtr C; public UIntPtr D; public uint E; public UIntPtr F; public uint G; public uint H; }
    [StructLayout(LayoutKind.Sequential)] struct Io { public ulong A; public ulong B; public ulong C; public ulong D; public ulong E; public ulong F; }
    [StructLayout(LayoutKind.Sequential)] struct Ext { public Basic B; public Io I; public UIntPtr C; public UIntPtr D; public UIntPtr E; public UIntPtr F; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr a, string n);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr j, int c, ref Ext i, uint l);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
    static IntPtr job = IntPtr.Zero;
    static readonly object gate = new object();
    public static bool Add(IntPtr process) {
      lock (gate) {
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
  public static class Power {
    // Keeps the PC awake while the stream is on the air or a torrent downloads (Update-KeepAwake).
    [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);
  }
  public sealed class TailReader {
    readonly object gate = new object();
    string text = "";
    public TailReader(Stream s, int keep) {
      Thread t = new Thread(() => Run(s, keep));
      t.IsBackground = true;
      t.Start();
    }
    void Run(Stream s, int keep) {
      byte[] buf = new byte[8192];
      StringBuilder sb = new StringBuilder();
      try {
        int n;
        while ((n = s.Read(buf, 0, buf.Length)) > 0) {
          sb.Append(Encoding.ASCII.GetString(buf, 0, n));
          if (sb.Length > keep * 2) sb.Remove(0, sb.Length - keep);
          lock (gate) { text = sb.ToString(); }
        }
      } catch { }
    }
    public string Text { get { lock (gate) { return text; } } }
  }
  // (The control window: the grey hint text in its input box, EM_SETCUEBANNER; a question flashes its taskbar button
  // until the window comes to the front, never taking the focus: Flash / StopFlash; is the console in front?)
  public static class Win {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, string l);
    [StructLayout(LayoutKind.Sequential)] struct FlashInfo { public uint Size; public IntPtr Hwnd; public uint Flags; public uint Count; public uint Timeout; }
    [DllImport("user32.dll")] static extern bool FlashWindowEx(ref FlashInfo f);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    static bool DoFlash(IntPtr h, uint flags) {
      FlashInfo f = new FlashInfo();
      f.Size = (uint)Marshal.SizeOf(typeof(FlashInfo));
      f.Hwnd = h;
      f.Flags = flags;
      return FlashWindowEx(ref f);
    }
    public static bool Flash(IntPtr h) { return DoFlash(h, 3 | 12); }   // FLASHW_ALL | FLASHW_TIMERNOFG
    public static bool StopFlash(IntPtr h) { return DoFlash(h, 0); }
    public static bool ConsoleInFront() { IntPtr c = GetConsoleWindow(); return c != IntPtr.Zero && c == GetForegroundWindow(); }
  }
}
'@

function Get-HelperDllName {
  $sha = [System.Security.Cryptography.SHA1]::Create()
  $h = ([BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($script:HelperSource))) -replace '-', '').Substring(0, 12)
  return "helper-$h.dll"
}

$script:HelperOk = $null
function Initialize-Helper {
  if ('VRCLinkMaker.ChildJob' -as [type]) { return $true }
  if ($script:HelperOk -eq $false) { return $false }   # (failed once: compiling again would only cost seconds each time)
  try {
    [void][System.IO.Directory]::CreateDirectory($script:TempRoot)
    $dll = PathJoin $script:TempRoot (Get-HelperDllName)
    if ([System.IO.File]::Exists($dll)) { try { Add-Type -Path $dll; return $true } catch {} }
    try { Add-Type -TypeDefinition $script:HelperSource -OutputAssembly $dll -OutputType Library; Add-Type -Path $dll; return $true } catch {}
    Add-Type -TypeDefinition $script:HelperSource
    return $true
  } catch { $script:HelperOk = $false; return $false }
}

# Puts a started program into the job (see above).
function Add-ChildToJob($proc) {
  if (-not $proc) { return }
  try { if (Initialize-Helper) { [void][VRCLinkMaker.ChildJob]::Add($proc.Handle) } } catch {}
}

function Start-Child($psi) {
  # A program whose output is all read by the tool needs no console of its own (with some terminals it would get a
  # window of its own otherwise).
  if ($psi.RedirectStandardOutput -and $psi.RedirectStandardError) { $psi.CreateNoWindow = $true }
  Write-StartLog $psi
  $p = [System.Diagnostics.Process]::Start($psi)
  Add-ChildToJob $p
  return $p
}

# VRCLM_DEBUG: one log.txt line per program started, to see which one could open a console window of its own.
function Write-StartLog($psi) {
  if (-not $env:VRCLM_DEBUG -or -not $psi) { return }
  try { Write-LogLine ('  (start: {0}  CreateNoWindow={1}  UseShellExecute={2})' -f [System.IO.Path]::GetFileName([string]$psi.FileName), $psi.CreateNoWindow, $psi.UseShellExecute) } catch {}
}

function New-StartInfo([string]$exe, [string[]]$argv, [string]$workDir) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe
  $psi.Arguments = Join-CmdArgs $argv
  $psi.UseShellExecute = $false
  if ($workDir) { $psi.WorkingDirectory = $workDir }
  return $psi
}

# Run a program, wait, and return its exit code + text output.
function Invoke-Capture([string]$exe, [string[]]$argv, [string]$workDir = '') {
  $psi = New-StartInfo $exe $argv $workDir
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.RedirectStandardInput = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  $p = Start-Child $psi
  try { $p.StandardInput.Close() } catch {}
  $errTask = $p.StandardError.ReadToEndAsync()
  $out = $p.StandardOutput.ReadToEnd()
  $p.WaitForExit()
  $err = ''
  try { $err = $errTask.Result } catch {}
  return [pscustomobject]@{ ExitCode = $p.ExitCode; Out = $out; Err = $err }
}

# Start a program in the background; its output is collected quietly.
function Start-Background([string]$exe, [string[]]$argv, [string]$workDir = '') {
  $psi = New-StartInfo $exe $argv $workDir
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.RedirectStandardInput = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  $p = Start-Child $psi
  try { $p.StandardInput.Close() } catch {}
  $bg = [pscustomobject]@{ Proc = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync(); Started = Get-Date }
  [void]$script:BgProcs.Add($bg)
  return $bg
}

function Get-BgText($bg) {
  $s = ''
  if (-not $bg) { return $s }
  try { if ($bg.Out -and $bg.Out.IsCompleted) { $s += $bg.Out.Result } } catch {}
  try { if ($bg.Err -and $bg.Err.IsCompleted) { $s += "`n" + $bg.Err.Result } } catch {}
  return $s
}

function Send-Key($proc, [string]$text) {
  try {
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($text)
    $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $proc.StandardInput.BaseStream.Flush()
  } catch {}
}

function Stop-Proc($proc) {
  if (-not $proc) { return }
  try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
}

# ------------------------------------------------------------------ finding / installing tools
function Update-PathFromRegistry {
  if (-not $script:IsWin) { return }
  try {
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($env:Path, $m, $u) | Where-Object { $_ }) -join ';'
  } catch {}
}

function Find-Exe([string]$name) {
  $exeName = $name
  if ($script:IsWin) { $exeName = "$name.exe" }
  $local = PathJoin (PathJoin $script:ToolDir 'bin') $exeName
  if ([System.IO.File]::Exists($local)) { return $local }
  $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd) { return $cmd.Path }
  if ($script:IsWin) {
    $roots = @()
    if ($env:LOCALAPPDATA) {
      $roots += PathJoin $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
      $roots += PathJoin $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    }
    if ($env:ProgramFiles) { $roots += PathJoin $env:ProgramFiles 'WinGet\Packages' }
    foreach ($r in $roots) {
      if (-not [System.IO.Directory]::Exists($r)) { continue }
      try {
        $f = [System.IO.Directory]::GetFiles($r, $exeName, [System.IO.SearchOption]::AllDirectories) | Select-Object -First 1
        if ($f) { return $f }
      } catch {}
    }
  }
  return $null
}

function Invoke-Winget([string]$id) {
  $wg = Get-Command winget -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $wg) { return $false }
  Say (T 'Installing {0} with winget (can take a minute)...' $id) 'Gray'
  $psi = New-StartInfo $wg.Path @('install', '-e', '--id', $id, '--accept-source-agreements', '--accept-package-agreements')
  Write-StartLog $psi
  $p = [System.Diagnostics.Process]::Start($psi)
  $p.WaitForExit()
  Update-PathFromRegistry
  return $true
}

function Initialize-Tools {
  $script:FFmpeg = Find-Exe 'ffmpeg'
  $script:FFprobe = $null
  if ($script:FFmpeg) {
    $probeName = 'ffprobe'
    if ($script:IsWin) { $probeName = 'ffprobe.exe' }
    $sib = PathJoin ([System.IO.Path]::GetDirectoryName($script:FFmpeg)) $probeName
    if ([System.IO.File]::Exists($sib)) { $script:FFprobe = $sib } else { $script:FFprobe = Find-Exe 'ffprobe' }
  }
  if ((-not $script:FFmpeg -or -not $script:FFprobe) -and $script:IsWin) {
    Say (T 'This tool needs ffmpeg (a free video toolkit) and it is not installed yet.') 'Yellow'
    if (Get-Command winget -ErrorAction SilentlyContinue) {
      $yes = $true
      if ($script:Interactive) { $yes = Read-YesNoUi (T 'Install it now? [Y/n]') $true -Esc $false }
      if ($yes) {
        [void](Invoke-Winget 'Gyan.FFmpeg')
        $script:FFmpeg = Find-Exe 'ffmpeg'
        $script:FFprobe = Find-Exe 'ffprobe'
      }
    }
  }
  if (-not $script:FFmpeg -or -not $script:FFprobe) {
    throw (T 'ffmpeg was not found. Install it (open PowerShell and run: winget install Gyan.FFmpeg), or download it from https://www.gyan.dev/ffmpeg/builds/ and put ffmpeg.exe and ffprobe.exe in a folder called ''bin'' next to this tool.')
  }
  $script:FFmpegDir = [System.IO.Path]::GetDirectoryName($script:FFmpeg)
  $f = Invoke-Capture $script:FFmpeg @('-hide_banner', '-nostdin', '-filters')
  $script:CanSubs = ($f.Out -match '(?m)^\s*\S+\s+subtitles\s')
  $script:HasBwdif = ($f.Out -match '(?m)^\s*\S+\s+bwdif\s')
  $script:HasSetparams = ($f.Out -match '(?m)^\s*\S+\s+setparams\s')
  $script:HasDrawtext = ($f.Out -match '(?m)^\s*\S+\s+drawtext\s')
  # The relay reports its progress 5 times a second where ffmpeg can (4.4 and newer): a resync must see the new
  # connection open within about a second (Restart-RelayForResync).
  $script:RelayStatArgs = @()
  $sp = Invoke-Capture $script:FFmpeg @('-hide_banner', '-nostdin', '-stats_period', '0.2', '-version')
  if ($sp.ExitCode -eq 0) { $script:RelayStatArgs = @('-stats_period', '0.2') }
  # The preview output keeps the stream's timestamps (Add-PreviewOutput): -fps_mode in 5.1 and newer, -vsync before.
  $fm = Invoke-Capture $script:FFmpeg @('-hide_banner', '-nostdin', '-fps_mode', 'passthrough', '-version')
  if ($fm.ExitCode -eq 0) { $script:PreviewSyncArgs = @('-fps_mode', 'passthrough') } else { $script:PreviewSyncArgs = @('-vsync', 'passthrough') }
  if (-not $script:CanSubs) { Say (T 'Note: this ffmpeg can''t draw subtitles (it was built without libass). Videos will play without them.') 'Yellow' }
}

function Get-YtDlp {
  if ($script:YtDlp) { return $script:YtDlp }
  $script:YtDlp = Find-Exe 'yt-dlp'
  if ($script:YtDlp) { return $script:YtDlp }
  $canAsk = (Test-CanAsk) -and $script:IsWin -and -not $script:YtDlpAsked
  if ($canAsk -and (Get-Command winget -ErrorAction SilentlyContinue)) {
    $script:YtDlpAsked = $true
    Say (T 'Links to web pages need yt-dlp (a free video downloader) and it is not installed yet.') 'Yellow'
    $tos = $script:AskTimeouts
    if (Read-YesNoUi (T 'Install it now? [Y/n]') $true -Esc $false) {
      [void](Invoke-Winget 'yt-dlp.yt-dlp')
      $script:YtDlp = Find-Exe 'yt-dlp'
    }
    # (A "no" that came from nobody answering asks again with the next link.)
    if ($script:AskTimeouts -ne $tos) { $script:YtDlpAsked = $false }
  }
  return $script:YtDlp
}

# ------------------------------------------------------------------ config / state
function New-StreamKey {
  $alphabet = 'abcdefghjkmnpqrstuvwxyz23456789'
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $bytes = New-Object byte[] 12
  $rng.GetBytes($bytes)
  $sb = New-Object System.Text.StringBuilder
  foreach ($b in $bytes) { [void]$sb.Append($alphabet[$b % $alphabet.Length]) }
  return 'vrc' + $sb.ToString()
}

# Settings Get-Config only filled in (they weren't in the file) stay out of it while unchanged, so a later version
# can still change their defaults (as happened with VideoKbps).
$script:CfgDefaulted = @{}
function Save-Config($cfg) {
  $out = $cfg
  if ($script:CfgDefaulted.Count -gt 0) {
    $out = New-Object psobject
    foreach ($pr in $cfg.PSObject.Properties) {
      if ($script:CfgDefaulted.ContainsKey($pr.Name) -and "$($pr.Value)" -eq "$($script:CfgDefaulted[$pr.Name])") { continue }
      $out | Add-Member -NotePropertyName $pr.Name -NotePropertyValue $pr.Value
    }
  }
  [System.IO.File]::WriteAllText($script:ConfigPath, ($out | ConvertTo-Json -Depth 5), $script:Utf8NoBom)
}

function Get-Config {
  $script:ConfigPath = Get-ConfigPath
  $cfg = $null
  if ([System.IO.File]::Exists($script:ConfigPath)) {
    try { $cfg = [System.IO.File]::ReadAllText($script:ConfigPath) | ConvertFrom-Json }
    catch { throw (T 'config.json could not be read ({0}). Fix it, or delete it to get a fresh one (that also gives you a new link).' $_.Exception.Message) }
  }
  $isNew = $false
  if (-not $cfg) {
    $key = New-StreamKey
    $cfg = [pscustomobject]@{
      Server    = 'Topaz Chat (free, trusted by VRChat)'
      IngestUrl = "rtmp://topaz.chat/live/$key"
      PcUrl     = "rtspt://topaz.chat/live/$key"
      QuestUrl  = "rtmp://topaz.chat/live/$key"
      VlcUrl    = "rtsp://topaz.chat/live/$key"
      VideoKbps = 1350
      AudioKbps = 128
      Bitrate   = 'auto'
      Height    = 'auto'
      MaxFps    = 30
      Encoder   = 'auto'
      CpuPreset = 'faster'
      CpuTune   = 'animation'
      Language  = $(if ($env:VRCLM_LANG) { 'auto' } else { $script:LangSetting })   # (VRCLM_LANG overrides, it isn't saved)
    }
    $isNew = $true
  }
  $defaults = [ordered]@{ Server = 'Custom'; QuestUrl = ''; VlcUrl = ''; VideoKbps = 1350; AudioKbps = 128; Bitrate = 'auto'; Height = 'auto'; MaxFps = 30; Encoder = 'auto'; CpuPreset = 'faster'; Language = 'auto' }
  foreach ($k in $defaults.Keys) {
    if (-not $cfg.PSObject.Properties[$k]) {
      $cfg | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k]
      if (-not $isNew) { $script:CfgDefaulted[$k] = $defaults[$k] }
    }
  }
  $hostId = "$(Get-Prop $cfg 'Host')"
  if ($hostId -ne 'pc' -and $hostId -ne 'vps' -and ((-not $cfg.PSObject.Properties['IngestUrl'] -or -not $cfg.IngestUrl -or -not $cfg.PSObject.Properties['PcUrl'] -or -not $cfg.PcUrl) -and -not (Test-HostModule))) {
    throw (T 'config.json needs IngestUrl (where the stream is sent) and PcUrl (the link for VRChat).')
  }
  if ($isNew) { Save-Config $cfg }
  return $cfg
}

function Get-StatePath { return (PathJoin $script:DataDir 'state.json') }

function Save-State([string]$src, [double]$pos) {
  try {
    $o = [pscustomobject]@{ Path = $src; Position = [Math]::Round($pos, 1) }
    [System.IO.File]::WriteAllText((Get-StatePath), ($o | ConvertTo-Json), $script:Utf8NoBom)
  } catch {}
}

function Clear-State { try { [System.IO.File]::Delete((Get-StatePath)) } catch {} }

function Get-State {
  try {
    $p = Get-StatePath
    if ([System.IO.File]::Exists($p)) { return ([System.IO.File]::ReadAllText($p) | ConvertFrom-Json) }
  } catch {}
  return $null
}

# ------------------------------------------------------------------ single instance + queue file
function Enter-SingleInstance {
  $sha = [System.Security.Cryptography.SHA1]::Create()
  $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($script:DataDir.ToLowerInvariant()))
  $hex = -join ($h[0..3] | ForEach-Object { $_.ToString('x2') })
  $script:Mutex = New-Object System.Threading.Mutex($false, "Local\VRCLinkMaker-$hex")
  try { $script:MutexOwned = $script:Mutex.WaitOne(0) }
  catch [System.Threading.AbandonedMutexException] { $script:MutexOwned = $true }
  return $script:MutexOwned
}

function Add-ToQueueFile([string[]]$entries) {
  $qf = PathJoin $script:DataDir 'queue.txt'
  $text = ($entries -join "`r`n") + "`r`n"
  for ($i = 0; $i -lt 40; $i++) {
    try { [System.IO.File]::AppendAllText($qf, $text, $script:Utf8NoBom); return $true } catch { Start-Sleep -Milliseconds 100 }
  }
  return $false
}

function Receive-QueueFile {
  $qf = PathJoin $script:DataDir 'queue.txt'
  $taking = $qf + '.taking'
  $lines = @()
  if ([System.IO.File]::Exists($taking)) {
    try { $lines += [System.IO.File]::ReadAllLines($taking, [System.Text.Encoding]::UTF8); [System.IO.File]::Delete($taking) } catch {}
  }
  if ([System.IO.File]::Exists($qf)) {
    $moved = $false
    try { [System.IO.File]::Move($qf, $taking); $moved = $true } catch {}
    if ($moved) {
      try { $lines += [System.IO.File]::ReadAllLines($taking, [System.Text.Encoding]::UTF8); [System.IO.File]::Delete($taking) } catch {}
    }
  }
  $lines = @($lines | Where-Object { $_ -and $_.Trim() })
  if ($lines.Count -eq 0) { return }
  # "#vrclm-now" from the second window: play these right away, instead of what plays now.
  $now = (@($lines | Where-Object { $_.Trim() -eq '#vrclm-now' }).Count -gt 0)
  $lines = @($lines | Where-Object { $_.Trim() -ne '#vrclm-now' })
  if ($lines.Count -eq 0) { return }
  $playing = ($script:Src -and $script:Src.Kind -ne 'waiting')
  if ($now -and $playing -and $script:Idx -lt $script:Queue.Count) {
    $n = Add-Entries $lines $true ($script:Idx + 1)
    if ($n -gt 0) { Add-Cmd (New-Cmd 'playnow' $null 'file') }
  } elseif ($now) { [void](Add-Entries $lines $true $script:Idx) }
  else { [void](Add-Entries $lines $true) }
}

# ------------------------------------------------------------------ fonts for subtitles
function New-AssText([string]$text, [int]$size) {
  $font = $script:FallbackFontName
  return @"
[Script Info]
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,$font,$size,&H00D0D0D0,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,5,20,20,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,9:59:59.00,Default,,0,0,0,,$text
"@
}

function Copy-FallbackFonts([string]$dir) {
  foreach ($f in $script:FallbackFonts) {
    try { [System.IO.File]::Copy($f, (PathJoin $dir ([System.IO.Path]::GetFileName($f))), $true) } catch {}
  }
}

function Initialize-Fonts {
  $conf = PathJoin $script:TempRoot 'fonts.conf'
  $cache = PathJoin $script:TempRoot 'fontcache'
  $dirs = @()
  $fallback = @()
  if ($script:IsWin) {
    $dirs += PathJoin $env:WINDIR 'Fonts'
    if ($env:LOCALAPPDATA) { $dirs += PathJoin $env:LOCALAPPDATA 'Microsoft\Windows\Fonts' }
    $fallback += PathJoin $env:WINDIR 'Fonts\arial.ttf'
    $fallback += PathJoin $env:WINDIR 'Fonts\arialbd.ttf'
    $script:FallbackFontName = 'Arial'
  } else {
    $dirs += '/usr/share/fonts'
    $dirs += '/usr/local/share/fonts'
    $fallback += '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'
    $fallback += '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
    $script:FallbackFontName = 'DejaVu Sans'
  }
  $script:FallbackFonts = @($fallback | Where-Object { [System.IO.File]::Exists($_) })
  # Our own fontconfig file: some Windows ffmpeg builds can't find system fonts without one.
  $esc = [System.Security.SecurityElement]
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('<?xml version="1.0"?>')
  [void]$sb.AppendLine('<!DOCTYPE fontconfig SYSTEM "fonts.dtd">')
  [void]$sb.AppendLine('<fontconfig>')
  foreach ($d in $dirs) {
    if ([System.IO.Directory]::Exists($d)) { [void]$sb.AppendLine('  <dir>' + $esc::Escape($d.Replace('\', '/')) + '</dir>') }
  }
  [void]$sb.AppendLine('  <cachedir>' + $esc::Escape($cache.Replace('\', '/')) + '</cachedir>')
  foreach ($fam in @('sans-serif', 'serif', 'monospace')) {
    [void]$sb.AppendLine("  <alias><family>$fam</family><prefer><family>" + $esc::Escape($script:FallbackFontName) + '</family></prefer></alias>')
  }
  [void]$sb.AppendLine('</fontconfig>')
  [System.IO.File]::WriteAllText($conf, $sb.ToString(), $script:Utf8NoBom)
  $env:FONTCONFIG_FILE = $conf
  # (Some ffmpeg builds keep their font cache elsewhere and never create $cache: a marker file says it was done, or
  # this ran - and said "first run only" - at every start.)
  $done = PathJoin $script:TempRoot 'fonts-ready.txt'
  if ($script:CanSubs -and -not [System.IO.Directory]::Exists($cache) -and -not [System.IO.File]::Exists($done)) {
    Say (T 'Setting up fonts for subtitles (first run only, can take a minute)...') 'Gray'
    $w = PathJoin $script:TempRoot 'warmup.ass'
    [System.IO.File]::WriteAllText($w, (New-AssText 'Warm up' 30), $script:Utf8NoBom)
    [void](Invoke-Capture $script:FFmpeg @('-hide_banner', '-nostdin', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=black:s=320x180:d=0.2',
        '-vf', 'subtitles=filename=warmup.ass', '-f', 'null', '-') $script:TempRoot)
    try { [System.IO.File]::Delete($w) } catch {}
    try { [System.IO.File]::WriteAllText($done, $script:FFmpeg, $script:Utf8NoBom) } catch {}
  }
}

function Initialize-Slate {
  $script:SlateDir = PathJoin $script:TempRoot 'slate'
  [void][System.IO.Directory]::CreateDirectory((PathJoin $script:SlateDir 'fonts'))
  [System.IO.File]::WriteAllText((PathJoin $script:SlateDir 'slate.ass'), (New-AssText (T 'Next video starting soon...') 40), $script:Utf8NoBom)
  [System.IO.File]::WriteAllText((PathJoin $script:SlateDir 'paused.ass'), (New-AssText (T 'Paused - back in a moment') 40), $script:Utf8NoBom)
  [System.IO.File]::WriteAllText((PathJoin $script:SlateDir 'hold.ass'), (New-AssText (T 'Starting in a moment...') 40), $script:Utf8NoBom)
  Copy-FallbackFonts (PathJoin $script:SlateDir 'fonts')
  try { [System.IO.File]::WriteAllText((Get-NoteFile), ' ', $script:Utf8NoBom); $script:NoteText = ' ' } catch {}
}

# Windows consoles pause a program when you click inside the window ("QuickEdit"). That would
# freeze the queue, so switch it off for this window only. Mouse input goes too: while a program
# takes it, the mouse wheel can't scroll the window back to what it said earlier.
function Disable-QuickEdit {
  if (-not $script:IsWin -or -not $script:HasConsole) { return }
  try {
    Add-Type -Namespace VRCLinkMaker -Name ConsoleMode -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@
    $h = [VRCLinkMaker.ConsoleMode]::GetStdHandle(-10)
    $mode = [uint32]0
    if ([VRCLinkMaker.ConsoleMode]::GetConsoleMode($h, [ref]$mode)) {
      $newMode = ($mode -band (-bnot [uint32]0x0050)) -bor [uint32]0x0080
      [void][VRCLinkMaker.ConsoleMode]::SetConsoleMode($h, [uint32]$newMode)
    }
  } catch {}
}

function Set-CtrlCAsKey([bool]$on) {
  if (-not $script:HasConsole) { return }
  try { [Console]::TreatControlCAsInput = $on } catch {}
}

# Removes what earlier runs left behind. A job folder whose lock file is still open belongs to a copy
# of the tool that is running right now (another folder / data directory): leave that one alone.
function Clear-OldTemp {
  try {
    foreach ($d in @([System.IO.Directory]::GetDirectories($script:TempRoot, 'job-*')) + @([System.IO.Directory]::GetDirectories($script:TempRoot, 'torrent-*'))) {
      try {
        $lf = PathJoin $d 'lock'
        if ([System.IO.File]::Exists($lf)) { [System.IO.File]::Delete($lf) }
      } catch { continue }
      try { [System.IO.Directory]::Delete($d, $true) } catch {}
    }
    foreach ($f in [System.IO.Directory]::GetFiles($script:TempRoot, 'relay-progress-*.txt')) { try { [System.IO.File]::Delete($f) } catch {} }
    # Left by a run that was closed abruptly: speed test progress, the firewall helper's status (of a process that is
    # gone), MediaMTX test configs / logs, older builds of the helper DLL. (Files still in use stay: they fail to delete.)
    foreach ($pat in @('speedtest-*.txt', 'mediamtx-test-*', 'warmup.ass')) {
      foreach ($f in [System.IO.Directory]::GetFiles($script:TempRoot, $pat)) { try { [System.IO.File]::Delete($f) } catch {} }
    }
    foreach ($f in [System.IO.Directory]::GetFiles($script:TempRoot, 'firewall-*.*')) {
      $m = [regex]::Match([System.IO.Path]::GetFileName($f), '^firewall-(\d+)\.')
      $alive = $false
      if ($m.Success) { try { $alive = -not (Get-Process -Id ([int]$m.Groups[1].Value) -ErrorAction Stop).HasExited } catch {} }
      if (-not $alive) { try { [System.IO.File]::Delete($f) } catch {} }
    }
    $sd = PathJoin $script:TempRoot 'slate'
    if ([System.IO.Directory]::Exists($sd)) {
      foreach ($f in [System.IO.Directory]::GetFiles($sd, 'next-*.txt*')) {
        $m = [regex]::Match([System.IO.Path]::GetFileName($f), '^next-(\d+)\.')
        $alive = $false
        if ($m.Success) { try { $alive = -not (Get-Process -Id ([int]$m.Groups[1].Value) -ErrorAction Stop).HasExited } catch {} }
        if (-not $alive) { try { [System.IO.File]::Delete($f) } catch {} }
      }
    }
    $keep = Get-HelperDllName
    foreach ($f in [System.IO.Directory]::GetFiles($script:TempRoot, 'helper-*.dll')) { if ([System.IO.Path]::GetFileName($f) -ne $keep) { try { [System.IO.File]::Delete($f) } catch {} } }
  } catch {}
}

# ------------------------------------------------------------------ encoders
function Test-Encoder([string]$enc) {
  # Same settings as the real stream at the most a session can ask of it (1080p at the highest frame rate it may run
  # at, with that level), so an old graphics card / driver fails here instead of mid-stream.
  $pix = 'yuv420p'
  if ($enc -eq 'h264_qsv') { $pix = 'nv12' }
  $fps = Get-TopStreamFps
  $argv = @('-hide_banner', '-nostdin', '-v', 'error', '-f', 'lavfi', '-i', "color=c=black:s=1920x1080:r=$(Format-Num $fps):d=1", '-vf', "format=$pix")
  $argv += Get-VideoEncArgs $enc 1700 $fps -Width 1920 -Height 1080
  $argv += @('-f', 'null', '-')
  $r = Invoke-Capture $script:FFmpeg $argv
  return ($r.ExitCode -eq 0)
}

function Select-VideoEncoder {
  $want = "$($script:Cfg.Encoder)".Trim().ToLowerInvariant()
  $map = @{ 'nvenc' = 'h264_nvenc'; 'nvidia' = 'h264_nvenc'; 'amf' = 'h264_amf'; 'amd' = 'h264_amf'; 'qsv' = 'h264_qsv'; 'intel' = 'h264_qsv'; 'cpu' = 'libx264'; 'x264' = 'libx264'; 'libx264' = 'libx264' }
  $cand = 'h264_nvenc'
  if ($map.ContainsKey($want)) { $cand = $map[$want] } elseif ($want -like 'h264_*') { $cand = $want }
  if ($cand -eq 'h264_nvenc') {
    # Best settings first; older graphics cards / drivers lack two-pass and temporal AQ.
    foreach ($tier in 3, 2, 1) { $script:NvTier = $tier; if (Test-Encoder $cand) { return $cand } }
  } elseif ($cand -ne 'libx264' -and (Test-Encoder $cand)) { return $cand }
  if ($want -ne 'auto' -and $cand -ne 'libx264') { Say (T 'The ''{0}'' encoder doesn''t work on this PC - using the CPU instead.' $want) 'Yellow' }
  return 'libx264'
}

function Get-EncoderName([string]$enc) {
  if ($enc -eq 'h264_nvenc') { return (T 'NVIDIA graphics card (NVENC)') }
  if ($enc -eq 'h264_amf') { return (T 'AMD graphics card (AMF)') }
  if ($enc -eq 'h264_qsv') { return (T 'Intel graphics (Quick Sync)') }
  return (T 'CPU (x264)')
}

# The rate never goes above a ceiling with a one-second buffer: Topaz Chat takes in only about 1.6 Mbps, so
# bursts above the average make the stream fall behind even when the average fits.
# The ceiling ($script:RateCapKbps) is set once per connection, and only the average (-b:v) drops when the stream can't
# keep up: the encoder writes the ceiling into the H.264 header (the average it used to write there too, with constant
# bitrate), and a header that changes while viewers are connected can freeze VRChat's player.
# A keyframe every second: VRChat's players need one to show a picture after joining or a resync.
# -ForTest (the upload speed test) and "EncoderArgs": "classic" in config.json: constant bitrate, as before.
function Get-VideoEncArgs([string]$venc, [int]$kbps, [double]$fps, [switch]$ForTest, [int]$Width = 0, [int]$Height = 0) {
  $g = [int][Math]::Round($fps)
  if ($g -lt 12) { $g = 24 }
  if ($Width -le 0) { $Width = $script:OutW }
  if ($Height -le 0) { $Height = $script:OutH }
  $lvl = Get-H264Level $Width $Height $fps
  $classic = $ForTest -or (Test-ClassicEncoder)
  $cap = $kbps
  if (-not $classic -and $script:RateCapKbps -ge $kbps) { $cap = [int]$script:RateCapKbps }
  $b = "$($kbps)k"
  $m = "$([int][Math]::Round($kbps * 1.06))k"
  $buf = "$($kbps)k"
  if (-not $classic) { $m = "$($cap)k"; $buf = "$($cap)k" }
  # MediaMTX accepts an SRT (MPEG-TS) stream only if it finds the audio within its first 1 MB, and the first keyframe
  # (up to the buffer size) comes before it: above ~7 Mbps a one-second buffer made the VPS refuse the connection.
  if ([int]$buf.TrimEnd('k') -gt 5000 -and (Get-IngestFormat) -eq 'mpegts') { $buf = '5000k' }
  # The colour tags the filters set (setparams), also told to the encoder: older ffmpeg builds don't pass them on.
  $col = @()
  if (-not $classic) { $col = @('-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-color_range', 'tv') }
  if ($venc -eq 'h264_nvenc') {
    $preset = 'p7'
    if ($script:NvTier -le 1) { $preset = 'p5' }
    $rc = @('-rc', 'vbr', '-b:v', $b, '-maxrate', $m, '-bufsize', $buf)
    if ($classic) { $rc = @('-rc', 'cbr', '-b:v', $b, '-maxrate', $b, '-bufsize', $buf) }
    $a = @('-c:v', 'h264_nvenc', '-preset', $preset, '-tune', 'hq', '-profile:v', 'high', '-level:v', $lvl) + $rc + @('-bf', '0', '-g', "$g", '-no-scenecut', '1')
    if ($script:NvTier -ge 3) { $a += @('-multipass', 'fullres') }
    if ($script:NvTier -ge 2) { $a += @('-temporal-aq', '1') }
    return $a + $col
  }
  if ($venc -eq 'h264_amf') {
    return @('-c:v', 'h264_amf', '-usage', 'transcoding', '-quality', 'quality', '-profile:v', 'high', '-level', $lvl, '-rc', 'vbr_peak', '-b:v', $b, '-maxrate', $m, '-bufsize', $buf,
      '-bf', '0', '-g', "$g") + $col
  }
  if ($venc -eq 'h264_qsv') {
    # (Quick Sync takes the level as a number: 41 = 4.1.)
    return @('-c:v', 'h264_qsv', '-preset', 'medium', '-profile:v', 'high', '-level', ($lvl -replace '\.', ''), '-b:v', $b, '-maxrate', $m, '-bufsize', $buf, '-bf', '0', '-g', "$g") + $col
  }
  $preset = "$($script:Cfg.CpuPreset)"
  if ($script:CpuPreset) { $preset = $script:CpuPreset }
  if (-not $preset) { $preset = 'faster' }
  $a = @('-c:v', 'libx264', '-preset', $preset)
  $tune = Get-Prop $script:Cfg 'CpuTune'
  if ($null -eq $tune) { $tune = 'animation' }
  if ("$tune".Trim()) { $a += @('-tune', "$tune".Trim()) }
  return $a + @('-profile:v', 'high', '-level:v', $lvl, '-b:v', $b, '-maxrate', $m, '-bufsize', $buf,
    '-bf', '0', '-g', "$g", '-keyint_min', "$g", '-sc_threshold', '0') + $col
}

# The H.264 level written into the header: 4.1 carries up to 1080p at 30 fps (every usual session), 4.2 1080p at
# 60 fps. Other sizes / rates get the lowest level whose limits (macroblocks per frame and per second, H.264 table A-1)
# they fit, never below 4.1.
function Get-H264Level([int]$w, [int]$h, [double]$fps) {
  if ($w -le 0 -or $h -le 0) { $w = 1920; $h = 1080 }
  if ($w -le 1920 -and $h -le 1080 -and $fps -le 30.5) { return '4.1' }
  $fs = [Math]::Ceiling($w / 16.0) * [Math]::Ceiling($h / 16.0)
  $mbps = $fs * [Math]::Max(1.0, $fps)
  foreach ($l in @(@('4.1', 8192, 245760), @('4.2', 8704, 522240), @('5.0', 22080, 589824), @('5.1', 36864, 983040), @('5.2', 36864, 2073600))) {
    if ($fs -le $l[1] -and $mbps -le $l[2]) { return $l[0] }
  }
  return '5.2'
}

# ------------------------------------------------------------------ media info + track choice
function ConvertFrom-Ratio($s, [string]$sep) {
  if (-not $s) { return 0.0 }
  $p = "$s".Split($sep)
  try {
    if ($p.Count -eq 2) {
      $n = [double]$p[0]; $d = [double]$p[1]
      if ($d -ne 0) { return ($n / $d) }
      return 0.0
    }
    return [double]$p[0]
  } catch { return 0.0 }
}

function ConvertFrom-FlatValue([string]$v) {
  if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) {
    $v = $v.Substring(1, $v.Length - 2)
    $v = [regex]::Replace($v, '\\(.)', {
        param($m)
        $c = $m.Groups[1].Value
        if ($c -ceq 'n') { return "`n" }
        if ($c -ceq 'r') { return "`r" }
        if ($c -ceq 't') { return "`t" }
        return $c
      })
  }
  if ($v -eq 'N/A') { return '' }
  return $v
}

function ConvertTo-IntSafe($v) {
  $n = 0
  if ([int]::TryParse("$v", [ref]$n)) { return $n }
  return 0
}

# Reads a file's tracks with ffprobe. Uses ffprobe's line-based "flat" output (not JSON),
# because tag names that differ only in upper/lower case make Windows PowerShell's JSON reader fail.
function Get-MediaInfoArgs([string]$src, [bool]$isUrl, $stream = $null) {
  $argv = @('-v', 'error', '-show_format', '-show_streams', '-of', 'flat')
  if ($stream) { $argv += @(Get-StreamInputArgs $stream) }
  elseif ($isUrl) { $argv += @('-rw_timeout', '20000000') }
  return ($argv + @($src))
}

function Get-MediaInfo([string]$src, [bool]$isUrl, $stream = $null) {
  $r = Invoke-Capture $script:FFprobe (Get-MediaInfoArgs $src $isUrl $stream)
  $info = ConvertFrom-ProbeOutput $r $stream
  if ($stream -and $stream.AudioUrl) {
    # A web stream whose sound is a separate playlist (played as a second input).
    $ai = Get-MediaInfo $stream.AudioUrl $true (New-Stream $stream.AudioUrl $stream.Kind $stream.Headers)
    $info.Audio = $ai.Audio
    $info.AudioInput = 1
    if ($info.Duration -le 0) { $info.Duration = $ai.Duration }
  }
  return $info
}

# ffprobe's answer ($r: ExitCode, Out, Err) -> Duration, BitRate, Video, Audio, Subs, Fonts.
# $stream with PickBw/PickH: an HLS master playlist read as it is, which lists every quality; the one Complete-HlsStream
# picked is taken (and only its own sound, when it has some), else the first one listed.
function ConvertFrom-ProbeOutput($r, $stream = $null) {
  if ($r.ExitCode -ne 0 -or -not $r.Out -or -not $r.Out.Trim()) {
    $why = Get-LastLines $r.Err 1
    if (-not $why) { $why = (T 'unknown format') }
    throw (T 'can''t read it ({0})' $why)
  }
  $streamMap = @{}
  $format = @{}
  foreach ($line in ($r.Out -split "`r?`n")) {
    if ($line -match '^streams\.stream\.(\d+)\.([^=]+)=(.*)$') {
      $n = [int]$matches[1]
      if (-not $streamMap.ContainsKey($n)) { $streamMap[$n] = @{} }
      $streamMap[$n][$matches[2].ToLowerInvariant()] = ConvertFrom-FlatValue $matches[3]
    } elseif ($line -match '^format\.([^=]+)=(.*)$') {
      $format[$matches[1].ToLowerInvariant()] = ConvertFrom-FlatValue $matches[2]
    }
  }
  $info = [pscustomobject]@{ Duration = 0.0; BitRate = 0; Video = $null; Audio = @(); Subs = @(); Fonts = @(); AudioInput = 0 }
  if ($format['duration']) { try { $info.Duration = [double]$format['duration'] } catch {} }
  $info.BitRate = ConvertTo-IntSafe $format['bit_rate']
  $fmtBr = $info.BitRate
  $wantBw = 0; $wantH = 0; $vRank = -1
  if ($stream -and $stream.PSObject.Properties['PickBw']) { $wantBw = [int]$stream.PickBw; $wantH = [int]$stream.PickH }
  $audio = New-Object System.Collections.ArrayList
  $ownAudio = New-Object System.Collections.ArrayList
  $subs = New-Object System.Collections.ArrayList
  $fonts = New-Object System.Collections.ArrayList
  foreach ($key in @($streamMap.Keys | Sort-Object)) {
    $s = $streamMap[$key]
    $type = "$($s['codec_type'])"
    $codec = "$($s['codec_name'])"
    $lang = "$($s['tags.language'])"
    $title = "$($s['tags.title'])"
    $isDef = ("$($s['disposition.default'])" -eq '1')
    $isForced = ("$($s['disposition.forced'])" -eq '1')
    $idx = $key
    if ($s['index']) { $idx = ConvertTo-IntSafe $s['index'] }
    $vbw = ConvertTo-IntSafe $s['tags.variant_bitrate']
    if ($type -eq 'video') {
      if ("$($s['disposition.attached_pic'])" -eq '1') { continue }
      $rank = 0
      if ($wantBw -gt 0 -and $vbw -eq $wantBw) { $rank = 2 } elseif ($wantH -gt 0 -and (ConvertTo-IntSafe $s['height']) -eq $wantH) { $rank = 1 }
      if ($info.Video -and $rank -le $vRank) { continue }
      $vRank = $rank
      $fpsStr = "$($s['avg_frame_rate'])"
      $fps = ConvertFrom-Ratio $fpsStr '/'
      if ($fps -le 0 -or $fps -gt 240) { $fpsStr = "$($s['r_frame_rate'])"; $fps = ConvertFrom-Ratio $fpsStr '/' }
      if ($fps -gt 240) { $fps = 0.0 }
      $sar = ConvertFrom-Ratio $s['sample_aspect_ratio'] ':'
      $fo = "$($s['field_order'])"
      $info.Video = [pscustomobject]@{
        Index = $idx; Codec = $codec; Width = (ConvertTo-IntSafe $s['width']); Height = (ConvertTo-IntSafe $s['height'])
        Sar = $sar; Fps = $fps; FpsStr = $fpsStr; Interlaced = (@('tt', 'bb', 'tb', 'bt') -contains $fo)
        ColorSpace = "$($s['color_space'])"; ColorRange = "$($s['color_range'])"; PixFmt = "$($s['pix_fmt'])"; ColorTransfer = "$($s['color_transfer'])"
      }
      if ($fmtBr -le 0) { $info.BitRate = $vbw }
    } elseif ($type -eq 'audio') {
      $a = [pscustomobject]@{ Index = $idx; Codec = $codec; Lang = $lang; Title = $title; Default = $isDef; Forced = $isForced; Kind = 'audio'; Path = $null; Channels = (ConvertTo-IntSafe $s['channels']) }
      [void]$audio.Add($a)
      if ($wantBw -gt 0 -and $vbw -eq $wantBw) { [void]$ownAudio.Add($a) }
    } elseif ($type -eq 'subtitle') {
      $kind = $null
      if ($script:TextSubCodecs -contains $codec) { $kind = 'text' } elseif ($script:BitmapSubCodecs -contains $codec) { $kind = 'bitmap' }
      if ($kind) {
        [void]$subs.Add([pscustomobject]@{ Index = $idx; Codec = $codec; Lang = $lang; Title = $title; Default = $isDef; Forced = $isForced; Kind = $kind; Path = $null; Channels = 0 })
      }
    } elseif ($type -eq 'attachment') {
      $fn = "$($s['tags.filename'])"
      $mt = "$($s['tags.mimetype'])"
      if (@('ttf', 'otf') -contains $codec -or $mt -match 'font' -or $fn -match '(?i)\.(ttf|otf|ttc)$') {
        $ext = '.ttf'
        if ($fn -match '(?i)\.(otf|ttc)$') { $ext = '.' + $matches[1].ToLowerInvariant() }
        [void]$fonts.Add([pscustomobject]@{ Index = $idx; Ext = $ext })
      }
    }
  }
  $info.Audio = $audio.ToArray()
  if ($vRank -eq 2 -and $ownAudio.Count -gt 0) { $info.Audio = $ownAudio.ToArray() }
  $info.Subs = $subs.ToArray()
  $info.Fonts = $fonts.ToArray()
  return $info
}

# HDR (PQ / HLG): the stream is plain HD (BT.709) and nothing maps the brightness down, so the colours look pale.
function Test-HdrVideo($v) {
  if (-not $v -or -not $v.PSObject.Properties['ColorTransfer']) { return $false }
  return ("$($v.ColorTransfer)" -match '^(?i)(smpte2084|arib-std-b67)$')
}

function New-ExternalSubTrack([string]$f) {
  $name = [System.IO.Path]::GetFileName($f)
  $lang = ''
  $parts = $name.Split('.')
  if ($parts.Count -ge 3) {
    $cand = $parts[$parts.Count - 2]
    if ($cand -match '^[A-Za-z]{2,3}$') { $lang = $cand.ToLowerInvariant() }
  }
  return [pscustomobject]@{ Index = -1; Codec = [System.IO.Path]::GetExtension($f).ToLowerInvariant(); Lang = $lang; Title = (T 'file: {0}' $name); Default = $true; Forced = $false; Kind = 'external'; Path = $f; Channels = 0 }
}

function Get-SidecarSubs([string]$videoPath) {
  $res = New-Object System.Collections.ArrayList
  try {
    $dir = [System.IO.Path]::GetDirectoryName($videoPath)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($videoPath)
    foreach ($f in @([System.IO.Directory]::GetFiles($dir) | Sort-Object)) {
      $ext = [System.IO.Path]::GetExtension($f).ToLowerInvariant()
      if ($script:SubExts -notcontains $ext) { continue }
      if (-not [System.IO.Path]::GetFileName($f).StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
      [void]$res.Add((New-ExternalSubTrack $f))
    }
  } catch {}
  return $res.ToArray()
}

function Get-TrackLabel($t, [bool]$short = $false) {
  $parts = @()
  $ln = $null
  if ($t.Lang) {
    $ln = $script:LangNames[$t.Lang]
    if (-not $ln -and $t.Lang -notmatch '^(?i)und$') { $ln = $t.Lang.ToUpperInvariant() }
  }
  if ($ln) { $parts += (T $ln) }
  if ($t.Title -and $t.Title -ne $ln -and $t.Title -ne (T $ln)) { $parts += $t.Title }
  if ($parts.Count -eq 0) { if ($t.Kind -eq 'audio') { $parts += (T 'Audio track') } else { $parts += (T 'Subtitle track') } }
  $s = $parts -join ' - '
  if (-not $short) {
    if ($t.Kind -eq 'audio' -and $t.Channels -gt 2) { $s += (T ' ({0} channels)' $t.Channels) }
    if ($t.Kind -eq 'bitmap') { $s += (T ' (picture subs)') }
    if ($t.Default -and $t.Kind -ne 'external') { $s += (T '   [default]') }
  }
  return $s
}

# Signs / songs only (not the whole dialogue): also Russian titles ("Nadpisi", "Znaki"; .NET regex escapes keep this file ASCII).
function Test-Signs($t) { return ($t.Forced -or ("$($t.Title)" -match ('(?i)sign|song|forced|karaoke|\u043d\u0430\u0434\u043f\u0438\u0441|\u0437\u043d\u0430\u043a\u0438'))) }
function Test-English([string]$lang) { return ($lang -match '^(?i)(en|eng)$') }

function Get-DefaultAudioPos($audio) {
  for ($i = 0; $i -lt $audio.Count; $i++) { if ($audio[$i].Default) { return $i } }
  if ($audio.Count -gt 0) { return 0 }
  return -1
}

# The subtitle languages taken without asking, best first: "SubLang" in config.json (e.g. "ru,en", the default, or "en").
function Get-SubLangOrder {
  $v = "$(Get-Prop $script:Cfg 'SubLang')"
  if (-not $v.Trim()) { $v = 'ru,en' }
  return @($v -split '[,; ]+' | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLowerInvariant() })
}

# Is a track tagged $lang in language $want ("ru" = "rus", "en" = "eng", ...)?
function Test-SubLang([string]$lang, [string]$want) {
  $l = "$lang".Trim().ToLowerInvariant(); $w = "$want".Trim().ToLowerInvariant()
  if (-not $l -or -not $w) { return $false }
  if ($l -eq $w) { return $true }
  $a = $script:LangNames[$l]; $b = $script:LangNames[$w]
  return ([bool]$a -and $a -eq $b)
}

function Get-DefaultSubPos($subs, $audioTrack) {
  if ($subs.Count -eq 0) { return -1 }
  $alang = ''
  if ($audioTrack) { $alang = "$($audioTrack.Lang)" }
  $order = @(Get-SubLangOrder)
  if ((Test-English $alang) -or ($alang -and @($order | Where-Object { Test-SubLang $alang $_ }).Count -gt 0)) {
    # English audio (or audio in a language the subtitles would be in): only signs/songs subtitles, if there are any
    for ($i = 0; $i -lt $subs.Count; $i++) { if (Test-Signs $subs[$i]) { return $i } }
    return -1
  }
  if ($alang -and $alang -notmatch '^(?i)(und|unk|zxx|mis)$') {
    # A release with subtitles in many languages: Russian first, else English ("SubLang").
    foreach ($w in $order) {
      for ($i = 0; $i -lt $subs.Count; $i++) { if ((Test-SubLang $subs[$i].Lang $w) -and -not (Test-Signs $subs[$i])) { return $i } }
    }
    for ($i = 0; $i -lt $subs.Count; $i++) { if ($subs[$i].Default -and -not (Test-Signs $subs[$i])) { return $i } }
    for ($i = 0; $i -lt $subs.Count; $i++) { if (-not (Test-Signs $subs[$i])) { return $i } }
    return 0
  }
  for ($i = 0; $i -lt $subs.Count; $i++) { if ($subs[$i].Default -and -not (Test-Signs $subs[$i])) { return $i } }
  for ($i = 0; $i -lt $subs.Count; $i++) { if ($subs[$i].Default) { return $i } }
  return -1
}

function Find-TrackMatch($tracks, [string]$lang, [string]$title, [bool]$signs, [int]$pos) {
  if ($tracks.Count -eq 0) { return -1 }
  for ($i = 0; $i -lt $tracks.Count; $i++) { if ($tracks[$i].Lang -eq $lang -and $tracks[$i].Title -eq $title) { return $i } }
  for ($i = 0; $i -lt $tracks.Count; $i++) { if ($tracks[$i].Lang -eq $lang -and (Test-Signs $tracks[$i]) -eq $signs) { return $i } }
  if ($pos -ge 0 -and $pos -lt $tracks.Count) { return $pos }
  return -2
}

# A numbered list -> the 0-based index, or -1 ("0) None" with $allowNone, or a -1 default). Asked through Invoke-Ask:
# inside a flow it gets a "0) Back / Cancel (or Esc)" line (when 0 isn't "None") and marks your earlier answer.
# -Key: the step's name; -Values: what each option stands for (kept instead of the position, so a re-run finds the
# same pick in a changed list); -Esc: the index Esc gives on a one-off question (marked "<- Esc"); -NoneLabel: the
# whole "0) ..." line instead of "0) None".
function Read-Choice {
  [CmdletBinding(PositionalBinding = $false)]
  param([Parameter(Position = 0)][string]$title, [Parameter(Position = 1)][string[]]$options, [Parameter(Position = 2)][int]$default,
    [Parameter(Position = 3)][bool]$allowNone, [string]$Key = '', [object[]]$Values = $null, [object]$Esc = $null, [string]$NoneLabel = '',
    [switch]$EnterDefault)
  $a = New-NavAsk 'choice' $title $Key
  $a.EnterDefault = [bool]$EnterDefault   # (just Enter = $default even when it was answered before: Right arrow = that)
  $a.Options = @($options)
  $a.Default = $default
  $a.AllowNone = $allowNone
  if ($null -ne $Values) {
    # (The same value twice, e.g. two voice-overs with one name: the later ones get a count, so each stays itself.)
    $seen = New-Object 'System.Collections.Generic.Dictionary[string,int]'
    $Values = @(foreach ($v in @($Values)) {
        $k = [string]$v
        if ($seen.ContainsKey($k)) { $seen[$k]++; $k + [string][char]31 + $seen[$k] } else { $seen[$k] = 1; $k }
      })
  }
  $a.Values = $Values
  $a.NoneLabel = $NoneLabel
  if ($PSBoundParameters.ContainsKey('Esc')) { $a.HasEsc = $true; $a.EscValue = [int]$Esc }
  return (Invoke-Ask $a)
}

# A yes / no question -> $true / $false. $defaultYes: "[Y/n]" (anything but a no is yes, Test-AnswerNo) or "[y/N]"
# (only a yes is yes, Test-AnswerYes). -Esc: what Esc gives on a one-off question (shown as "(Esc = no)").
function Read-YesNoUi {
  [CmdletBinding(PositionalBinding = $false)]
  param([Parameter(Position = 0)][string]$prompt, [Parameter(Position = 1)][bool]$defaultYes = $true, [string]$Key = '', [object]$Esc = $null)
  $a = New-NavAsk 'yesno' '' $Key
  $a.Prompt = $prompt
  $a.DefaultYes = $defaultYes
  if ($PSBoundParameters.ContainsKey('Esc')) { $a.HasEsc = $true; $a.EscValue = [bool]$Esc }
  return [bool](Invoke-Ask $a)
}

function Select-Tracks($item) {
  $audio = @($item.Info.Audio)
  $subs = @()
  if ($script:CanSubs -and -not $item.IsDirectUrl) { $subs = @($item.Info.Subs) + @($item.ExtraSubs) }
  else {
    $subs = @($item.Info.Subs | Where-Object { $_.Kind -eq 'bitmap' })  # text subs inside it would mean reading the whole file first
    # Subtitle files already on this PC are fine (a web video's own subtitle file, see Add-SiteSubtitle).
    if ($script:CanSubs) { $subs += @($item.ExtraSubs | Where-Object { $_ -and $_.Kind -eq 'external' -and $_.Path -and [System.IO.File]::Exists($_.Path) }) }
  }
  $subs = @($subs | Where-Object { $_ })
  # (A translation that is subtitles only: its subtitle file is the translation, see Add-SiteSubtitle.)
  $sitePos = -1
  for ($i = 0; $i -lt $subs.Count; $i++) { if ($subs[$i].PSObject.Properties['FromSite']) { $sitePos = $i; break } }
  $aPos = Get-DefaultAudioPos $audio
  $sPos = -1
  $noSubs = $false   # ("no subtitles" picked: this answer, or the session's)
  $canAsk = (Test-CanAsk) -and ($null -eq $script:TrackPref)
  if ($canAsk -and ($audio.Count -gt 1 -or $subs.Count -gt 0)) {
    Say ''
    Say (T 'Setting up: {0}' $item.Name) 'White'
    # (Preparation has started: no Back goes past the queue insert. The two questions are a flow of their own that
    # can't be left: Back at subtitles returns to the audio track; Esc at the audio track does nothing.)
    Lock-NavStep
    $tos = $script:AskTimeouts
    $tr = Invoke-NavFlow -Name 'tracks' -Own -Body {
      $ap = $aPos
      if ($audio.Count -gt 1) {
        $labels = @($audio | ForEach-Object { Get-TrackLabel $_ })
        $ap = Read-Choice (T 'Which audio track?') $labels $aPos $false -Key 'audio'
      }
      $at = $null
      if ($ap -ge 0) { $at = $audio[$ap] }
      $sp = Get-DefaultSubPos $subs $at
      if ($sp -lt 0) { $sp = $sitePos }
      if ($subs.Count -gt 0) {
        $labels = @($subs | ForEach-Object { Get-TrackLabel $_ })
        $sp = Read-Choice (T 'Which subtitles? (they get drawn into the picture)') $labels $sp $true -Key 'subs'
      }
      @{ A = $ap; S = $sp }
    }
    $aPos = [int]$tr.Value.A
    $sPos = [int]$tr.Value.S
    $p = [pscustomobject]@{ ALang = ''; ATitle = ''; APos = $aPos; SNone = ($sPos -lt 0); SLang = ''; STitle = ''; SSigns = $false; SPos = $sPos; SExternal = $false }
    if ($aPos -ge 0) { $p.ALang = $audio[$aPos].Lang; $p.ATitle = $audio[$aPos].Title }
    if ($sPos -ge 0) { $p.SLang = $subs[$sPos].Lang; $p.STitle = $subs[$sPos].Title; $p.SSigns = (Test-Signs $subs[$sPos]); $p.SExternal = ($subs[$sPos].Kind -eq 'external') }
    $noSubs = $p.SNone
    # (Kept for the next videos only when someone answered: a question that timed out asks again next time.)
    if ($script:AskTimeouts -eq $tos) { $script:TrackPref = $p }
  } elseif ($script:TrackPref) {
    $p = $script:TrackPref
    if ($audio.Count -gt 0) {
      $m = Find-TrackMatch $audio $p.ALang $p.ATitle $false $p.APos
      if ($m -ge 0) { $aPos = $m }
    }
    $aTrack = $null
    if ($aPos -ge 0) { $aTrack = $audio[$aPos] }
    $noSubs = $p.SNone
    if ($p.SNone) { $sPos = -1 }
    elseif ($p.SExternal) {
      $sPos = -1
      for ($i = 0; $i -lt $subs.Count; $i++) { if ($subs[$i].Kind -eq 'external') { $sPos = $i; break } }
      if ($sPos -lt 0) { $sPos = Get-DefaultSubPos $subs $aTrack }
    } else {
      $internal = @($subs | Where-Object { $_.Kind -ne 'external' })
      $m = Find-TrackMatch $internal $p.SLang $p.STitle $p.SSigns $p.SPos
      if ($m -ge 0) { $sPos = [array]::IndexOf($subs, $internal[$m]) } else { $sPos = Get-DefaultSubPos $subs $aTrack }
    }
  } else {
    $aTrack = $null
    if ($aPos -ge 0) { $aTrack = $audio[$aPos] }
    $sPos = Get-DefaultSubPos $subs $aTrack
  }
  # (Whatever language the sound is tagged with, unless "no subtitles" was picked.)
  if ($sPos -lt 0 -and $sitePos -ge 0 -and -not $noSubs) { $sPos = $sitePos }
  $item.AudioTrack = $null
  if ($aPos -ge 0 -and $aPos -lt $audio.Count) { $item.AudioTrack = $audio[$aPos] }
  $item.SubTrack = $null
  if ($sPos -ge 0 -and $sPos -lt $subs.Count) { $item.SubTrack = $subs[$sPos] }
}

# Everything goes out at one frame rate ($script:StreamFps, "StreamFps" in config.json): the stream's H.264 header
# holds the frame rate, and it must not change while viewers are connected.
function Set-FpsPlan($item) {
  $v = $item.Info.Video
  $item.FpsFilter = $script:StreamFps
  $item.OutFps = $script:StreamFpsNum
  $item.FpsNote = $null
  if ($v -and $v.Fps -gt 0 -and [Math]::Abs($v.Fps - $script:StreamFpsNum) -gt 0.6 -and [Math]::Abs($v.Fps / 2 - $script:StreamFpsNum) -gt 0.6) {
    $vf = Format-Num ([Math]::Round($v.Fps, 3))
    $sf = Format-Num ([Math]::Round($script:StreamFpsNum, 3))
    if ($script:FpsAuto) { $item.FpsNote = T 'this video is {0} fps, the stream runs at {1} fps (the first video on this connection set it)' $vf $sf }
    else { $item.FpsNote = T 'this video is {0} fps, the stream runs at {1} fps ("StreamFps" in config.json)' $vf $sf }
  }
}

# Without "StreamFps" in config.json the frame rate follows the first video of each new connection (Select-SessionFps):
# 23.976 / 24 / 25 / 29.97 / 30 as they are; faster videos at half their rate, unless "MaxFps" is 50 or more (then
# at their own rate up to MaxFps); unknown -> 23.976. Other rates take the nearest of these.
$script:FpsAuto = $false
$script:FpsLow = @(@('24000/1001', (24000.0 / 1001.0)), @('24', 24.0), @('25', 25.0), @('30000/1001', (30000.0 / 1001.0)), @('30', 30.0))
$script:FpsHigh = @(@('50', 50.0), @('60000/1001', (60000.0 / 1001.0)), @('60', 60.0))
function Get-MaxFpsSetting { return (Get-NumSetting 'MaxFps' 30 10 60) }

# The frame rate (@(text for ffmpeg, number)) a session that starts with $item runs at.
function Get-SessionFpsFor($item) {
  $f = 0.0
  if ($item -and $item.Info -and $item.Info.Video) { $f = [double]$item.Info.Video.Fps }
  if ($f -le 0) { return , $script:FpsLow[0] }
  $lim = 30.5
  $mx = Get-MaxFpsSetting
  if ($mx -ge 50) { $lim = $mx + 0.5 }
  while ($f -gt $lim) { $f = $f / 2.0 }
  $set = $script:FpsLow
  if ($f -gt 30.5) { $set = @($script:FpsHigh | Where-Object { $_[1] -le $lim }) }
  $best = $set[0]
  foreach ($c in $set) { if ([Math]::Abs($c[1] - $f) -lt [Math]::Abs($best[1] - $f)) { $best = $c } }
  return , $best
}

# The highest frame rate this session may run at (what the encoder check at the start tries).
function Get-TopStreamFps {
  $f = [Math]::Max(30.0, $script:StreamFpsNum)
  if ($script:FpsAuto -and (Get-MaxFpsSetting) -ge 50) { $f = [Math]::Max($f, (Get-MaxFpsSetting)) }
  return $f
}

# Sets the stream's frame rate (only for a new connection: it is in the H.264 header). Above 40 fps a picture size
# needs more bitrate (Get-FpsFactor), so size and bitrate are worked out again when that changes.
function Set-StreamFps([string]$str, [double]$num) {
  $before = Get-FpsFactor
  $script:StreamFps = $str
  $script:StreamFpsNum = $num
  if ((Get-FpsFactor) -ne $before) { Update-StreamQuality }
}

# The first video on a new connection decides the frame rate of everything on it. $true = it changed.
function Select-SessionFps($item) {
  if (-not $script:FpsAuto -or -not $item -or -not $item.Info) { return $false }
  $want = Get-SessionFpsFor $item
  if ([Math]::Abs($want[1] - $script:StreamFpsNum) -lt 0.001) { return $false }
  Set-StreamFps $want[0] $want[1]
  Say (T '  The stream now runs at {0} fps, the frame rate of this video.' (Format-Num ([Math]::Round($want[1], 3)))) 'DarkGray'
  Show-StreamQuality
  return $true
}

# ------------------------------------------------------------------ queue items
# Id: a number of its own for each item (the control window's Up next menu names items by it, see Invoke-QueueCommand).
$script:ItemSeq = 0
function New-QueueItem([string]$kind, [string]$src) {
  $name = $src
  $path = $null
  if ($kind -eq 'file') { $name = [System.IO.Path]::GetFileName($src); $path = $src } else { $name = Get-ShortText $src 70 }
  $script:ItemSeq++
  return [pscustomobject]@{
    Id = $script:ItemSeq; Kind = $kind; Source = $src; Path = $path; Name = $name; State = 'new'; Error = $null
    JobDir = $null; Info = $null; AudioTrack = $null; SubTrack = $null; SubFile = $null; SubIsSrt = $false; SubWarn = $null
    ExtraSubs = @(); Prep = @(); Dl = $null; DlDir = $null; IsDirectUrl = $false; IsLive = $false
    FpsFilter = $null; OutFps = 24.0; FpsNote = $null; ResumeAt = 0.0; Attempts = 0; Announced = $false
    Site = $null; Cands = $null; CandIdx = 0; Using = $null; Stream = $null; DlKind = $null; Errors = @(); Retried = $false; NoDirect = $false; DirectFails = 0; Reset = $false
    Torrent = $null
  }
}

# One video from a web page (an anime episode, a movie...). $key identifies it for "continue where you stopped".
function New-SiteItem([string]$key, [string]$name, $site) {
  $it = New-QueueItem 'site' $key
  $it.Name = $name
  $it.Site = $site
  return $it
}

function Get-MediaInFolder([string]$dir) {
  $pick = {
    param($files)
    @($files | Where-Object { $script:MediaExts -contains [System.IO.Path]::GetExtension($_).ToLowerInvariant() })
  }
  $media = @()
  try { $media = @(& $pick ([System.IO.Directory]::GetFiles($dir))) } catch {}
  if ($media.Count -eq 0) {
    try { $media = @(& $pick ([System.IO.Directory]::GetFiles($dir, '*', [System.IO.SearchOption]::AllDirectories))) } catch {}
  }
  return @($media | Sort-Object { Get-NaturalKey ([System.IO.Path]::GetFileName($_)) })
}

# A typed title (not a link, not a file) is searched for (VRChatLinkMaker.Sites.ps1: Find-SiteContent).
function Test-IsTitle([string]$text) {
  if (-not (Get-Command Test-SearchQuery -CommandType Function -ErrorAction SilentlyContinue)) { return $false }
  try { return [bool](Test-SearchQuery $text) } catch { return $false }
}

function Resolve-Entries([string[]]$entries) {
  $videos = New-Object System.Collections.ArrayList
  $subFiles = New-Object System.Collections.ArrayList
  $urls = New-Object System.Collections.ArrayList
  $found = New-Object System.Collections.ArrayList
  foreach ($raw in $entries) {
    if ($null -eq $raw) { continue }
    $e = "$raw".Trim().Trim('"').Trim()
    if (-not $e) { continue }
    # (A magnet link, a bare info hash or a .torrent file: not a title to search for, not a video file.)
    if (Test-TorrentLink $e) { [void]$urls.Add($e); continue }
    if ($e -match '^(?i)(https?|rtmps?|rtsp|rtspt|srt|udp)://') { [void]$urls.Add($e); continue }
    if (Test-IsTitle $e) {
      if (-not (Test-CanAsk)) { Say (T '  To search while a video plays, press + (it opens a second window): {0}' $e) 'Yellow'; continue }
      try { foreach ($it in @(Invoke-ContentSearch $e)) { if ($it) { [void]$found.Add($it) } } }
      catch { if ($script:CtrlCQuit -or $script:NavSignal) { throw }; Say (T '  The search didn''t work: {0}' $_.Exception.Message) 'Yellow' }
      continue
    }
    $full = $null
    try { $full = [System.IO.Path]::GetFullPath($e) } catch { Say (T '  Skipping (not a valid path): {0}' $e) 'Yellow'; continue }
    if ([System.IO.Directory]::Exists($full)) {
      $inDir = @(Get-MediaInFolder $full)
      if ($inDir.Count -eq 0) { Say (T '  No videos found in folder: {0}' $full) 'Yellow' }
      foreach ($f in $inDir) { if (-not $videos.Contains($f)) { [void]$videos.Add($f) } }
      continue
    }
    if ([System.IO.File]::Exists($full)) {
      $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()
      if ($script:SubExts -contains $ext) { [void]$subFiles.Add($full) }
      elseif (-not $videos.Contains($full)) { [void]$videos.Add($full) }
      continue
    }
    Say (T '  Not found: {0}' $e) 'Yellow'
  }
  $sorted = @($videos | Sort-Object { Get-NaturalKey ([System.IO.Path]::GetFileName($_)) })
  $items = New-Object System.Collections.ArrayList
  foreach ($v in $sorted) {
    $it = New-QueueItem 'file' $v
    $vb = [System.IO.Path]::GetFileNameWithoutExtension($v)
    foreach ($s in $subFiles) {
      if ($sorted.Count -eq 1 -or [System.IO.Path]::GetFileName($s).StartsWith($vb, [System.StringComparison]::OrdinalIgnoreCase)) {
        $it.ExtraSubs = @($it.ExtraSubs) + @(New-ExternalSubTrack $s)
      }
    }
    [void]$items.Add($it)
  }
  if ($subFiles.Count -gt 0 -and $sorted.Count -eq 0) { Say (T '  Subtitle files have to be dropped together with their video.') 'Yellow' }
  foreach ($u in $urls) {
    if (Test-TorrentLink $u) {
      try { foreach ($it in @(Expand-Torrent $u)) { if ($it) { [void]$items.Add($it) } } }
      catch { if ($script:CtrlCQuit -or $script:NavSignal) { throw }; Say (T '  Couldn''t use {0}: {1}' (Get-ShortText $u 70) $_.Exception.Message) 'Yellow' }
      continue
    }
    if (Test-SiteLink $u) {
      try { foreach ($it in @(Expand-SiteLink $u)) { if ($it) { [void]$items.Add($it) } } }
      catch { if ($script:CtrlCQuit -or $script:NavSignal) { throw }; Say (T '  Couldn''t use {0}: {1}' (Get-ShortText $u 70) $_.Exception.Message) 'Yellow' }
      continue
    }
    [void]$items.Add((New-QueueItem 'url' $u))
  }
  foreach ($it in $found) { [void]$items.Add($it) }
  return $items.ToArray()
}

function Add-Entries([string[]]$entries, [bool]$announce, [int]$insertAt = -1) {
  # (A VPS connection code is a password: it is never searched for or printed.)
  if (Test-HostModule) {
    $entries = @($entries | Where-Object { -not (Test-VpsCodeText "$_") -and -not ("$_" -match '^[A-Za-z0-9_-]{40,}$' -and -not [System.IO.File]::Exists("$_") -and -not (Test-TorrentLink "$_")) })
  }
  $items = @(Resolve-Entries $entries)
  $n = 0
  foreach ($it in $items) {
    if ($insertAt -ge 0 -and $insertAt + $n -le $script:Queue.Count) { $script:Queue.Insert($insertAt + $n, $it) } else { [void]$script:Queue.Add($it) }
    $n++
    if ($announce -and ($n -le 5 -or $items.Count -le 6)) { Say (T '  + Added to the queue: {0}' $it.Name) 'Green' }
  }
  if ($announce -and $items.Count -gt 6) { Say (T '  + ... and {0} more' ($items.Count - 5)) 'Green' }
  if ($items.Count -gt 0) { $script:QueueFinished = $false }
  return $items.Count
}

function Split-EntryLine([string]$line) {
  $t = $line.Trim()
  if (-not $t) { return @() }
  $bare = $t.Trim('"').Trim("'").Trim()
  if ([System.IO.File]::Exists($bare) -or [System.IO.Directory]::Exists($bare)) { return @($bare) }
  if (Test-IsTitle $bare) { return @($bare) }   # a title to search for, spaces and all
  $res = New-Object System.Collections.ArrayList
  foreach ($m in [regex]::Matches($t, '"([^"]+)"|''([^'']+)''|(\S+)')) {
    if ($m.Groups[1].Success) { [void]$res.Add($m.Groups[1].Value) }
    elseif ($m.Groups[2].Success) { [void]$res.Add($m.Groups[2].Value) }
    else { [void]$res.Add($m.Groups[3].Value) }
  }
  return $res.ToArray()
}

function Show-FilePicker {
  if (-not $script:IsWin) { return @() }
  try {
    Add-Type -AssemblyName System.Windows.Forms
    $owner = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = (T 'Pick the videos to stream (you can pick several)')
    $dlg.Multiselect = $true
    $exts = ($script:MediaExts | ForEach-Object { '*' + $_ }) -join ';'
    $dlg.Filter = (T 'Videos') + "|$exts|" + (T 'All files') + '|*.*'
    $res = $dlg.ShowDialog($owner)
    $owner.Dispose()
    if ($res -eq [System.Windows.Forms.DialogResult]::OK) { return @($dlg.FileNames) }
  } catch {
    Say (T 'Couldn''t open the file picker: {0}' $_.Exception.Message) 'Yellow'
  }
  return @()
}

# ------------------------------------------------------------------ the settings menu (M) and its letters
# One list for M, the letters on '>' and on the waiting screen, Resolve-Cmd and (later) the window's Settings button.
# Id = the command's name; Letter = its shortcut ('' = only in the menu); Re = what can be typed for it (the words,
# and the letter as a Russian keyboard layout types it); Need: host = a host to stream to, lang = translations.
function Get-MenuItems([switch]$WithMenu) {
  $items = @(
    @{ Id = 'host'; Label = (T 'Where to stream (server)...'); Letter = 'H'; Need = 'host'; Re = '^\s*(?:h|host|\u0440)\s*$' },
    @{ Id = 'res'; Label = (T 'Picture size...'); Letter = 'V'; Need = ''; Re = '^\s*(?:v|res|resolution|\u043c)\s*$' },
    @{ Id = 'speedtest'; Label = (T 'Upload speed test'); Letter = 'T'; Need = 'host'; Re = '^\s*(?:t|test|speed|\u0435)\s*$' },
    @{ Id = 'newlink'; Label = (T 'New link...'); Letter = 'N'; Need = 'host'; Re = '^\s*(?:n|new|\u0442)\s*$' },
    # ("yazyk" = U+044F U+0437 U+044B U+043A)
    @{ Id = 'lang'; Label = (T 'Language'); Letter = 'L'; Need = 'lang'; Re = '^\s*(?:l|lang|language|\u0434|\u044f\u0437\u044b\u043a)\s*$' },
    @{ Id = 'forget'; Label = (T 'Ask again: player, audio, subtitles'); Letter = ''; Need = ''; Re = '' }
  )
  if ($WithMenu) { $items += @{ Id = 'menu'; Label = (T 'Settings'); Letter = 'M'; Need = ''; Re = '^\s*(?:m|menu|\u044c)\s*$' } }
  return $items
}

# The item a typed line asks for (a letter or its word), or $null.
function Get-MenuItemFor([string]$line) {
  foreach ($it in @(Get-MenuItems -WithMenu)) { if ($it.Re -and $line -match $it.Re) { return $it } }
  return $null
}

# Can it be used in this window now?
function Test-MenuItemOn($it) {
  if ($it.Need -eq 'host') { return ((Test-HostModule) -and [bool]$script:HostP) }
  if ($it.Need -eq 'lang') { return (Test-HasTranslations) }
  return $true
}

# Runs a menu item (on '>', or on the waiting screen through Invoke-Queue: the waiting screen stays on meanwhile).
# $pick: the choice already made in the control window's Settings menu (host id, picture height, language code), so
# that question isn't asked again ($null = ask). Follow-up questions (a VPS code, a DuckDNS name...) still come here.
function Invoke-MenuAction([string]$id, $pick = $null) {
  switch ($id) {
    'host' { if ($null -ne $pick) { Invoke-HostMenu $pick } else { Invoke-HostMenu } }
    'res' { if ($null -ne $pick) { Invoke-ResolutionMenu $pick } else { Invoke-ResolutionMenu } }
    'speedtest' { Invoke-SpeedTestMenu }
    'newlink' { Invoke-NewLinkMenu }
    'lang' { if ($null -ne $pick) { Invoke-LanguageMenu $pick } else { Invoke-LanguageMenu } }
    'forget' { Clear-AskedPrefs }
    'menu' { Invoke-SettingsMenu }
  }
}

function Invoke-LanguageMenu($Pick = $null) {
  $was = $script:PromptOk
  $script:PromptOk = $true
  $before = $script:Lang
  try {
    if ($null -ne $Pick) { Select-Language -Pick ([string]$Pick) } else { Select-Language }
    if ($script:Cfg) { Show-Links }
  } finally { $script:PromptOk = $was }
  # The control window takes its texts when it opens: open it again in the new language (same place and size).
  if ($script:Lang -ne $before -and $script:PanelShown -and (Test-ControlPanelOpen)) {
    try { Close-ControlPanel; $script:PanelShown = [bool](Open-ControlPanel) } catch { $script:PanelShown = $false }
  }
}

# "Ask again": this session's answers to which player, which audio / subtitles and which voice-over are forgotten.
function Clear-AskedPrefs {
  $script:PlayerPref = $null
  $script:TrackPref = $null
  $script:DubChoice = $null
  $script:DubPref = $null
  $script:PinnedRefused = @{}
  Say (T '  OK: the next videos ask again which player, audio and subtitles.') 'Green'
}

# The settings menu (M): a numbered list, 0 / Esc / just Enter = back (also after a task: Right arrow = that task
# again). Its tasks run in the same flow, so Esc at a task's first question comes back to this list (nothing saved);
# once a task saved something it can't be undone. Home inside a task leaves the task, back to this list; Home at the
# list leaves the menu.
function Invoke-SettingsMenu {
  $items = @(Get-MenuItems | Where-Object { Test-MenuItemOn $_ })
  $labels = @($items | ForEach-Object { if ($_.Letter) { $_.Label + '   (' + $_.Letter + ')' } else { $_.Label } })
  $ids = @($items | ForEach-Object { $_.Id })
  $was = $script:PromptOk
  $script:PromptOk = $true
  try {
    while ($true) {
      $st = @{ Task = $false }
      $r = Invoke-NavFlow -Name 'settings' -Origin 'menu' -Cfg -Body {
        $st.Task = $false
        Say ''
        $i = Read-Choice (T 'Settings') $labels -1 $true -Key 'menu' -Values $ids -NoneLabel (T '   0) Back (or Esc)') -EnterDefault
        if ($i -ge 0) { $st.Task = $true; Invoke-MenuAction $ids[$i] }
      }
      if ($r.Nav -eq 'home' -and $st.Task) { continue }
      break
    }
  } finally { $script:PromptOk = $was }
}

# The start screen's question ('>'). It comes back here (no dead end) after a menu letter, a VPS code, a cancelled
# file picker or Esc. Returns the entries, or @($script:QuitMark) for Q + Enter (and in a second window for Esc on
# an empty line). -Prefill: text already typed (what a task that was left had). $script:EntryLine = the typed line.
$script:QuitMark = [string][char]0 + 'quit'
$script:EntryLine = ''
$script:AddMode = $false   # a second window that hands what it finds to the streaming one (see Main)
function Read-Entries([string]$Prefill = '') {
  if (-not $script:Interactive) { return @() }
  $keys = ($script:HasConsole -or $script:KeySource)
  $add = [bool]$script:AddMode
  while ($true) {
    $script:EntryLine = ''
    Say ''
    Say (T 'What do you want to stream?') 'Cyan'
    if (Get-Command Find-SiteContent -CommandType Function -ErrorAction SilentlyContinue) {
      Say (T '  - Type a title (anime, film, series - in Russian or English) and press Enter to search for it')
    }
    Say (T '  - or paste a link (a video, Dream Cast, AniLiberty, AnimeVost, AnimeGO, AnimeLib, WPARTY, Kodik...) and press Enter')
    Say (T '  - or paste a magnet link or a .torrent file (it downloads first, then plays)')
    Say (T '  - or drag video files (or a whole folder) into this window, then press Enter')
    Say (T '  - or just press Enter to pick files')
    if ((Test-HasTranslations) -and -not $add) { Say (T '  - or type L and press Enter to change the language') 'DarkGray' }
    $hostKeys = ((Test-HostModule) -and $script:HostP -and -not $add)
    if ($hostKeys) { Say (T '  - H = where to stream (Topaz / this PC / your VPS),  T = test your upload speed,  N = new link') 'DarkGray' }
    if (-not $add) { Say (T '  - V = picture size (resolution)') 'DarkGray' }
    if ($keys) { Say (T '  - In questions: Enter = the suggested answer, Esc or B = back, Right arrow = your earlier answer again, Home = cancel') 'DarkGray' }
    if ($add) { Say (T '  - Esc = close this window') 'DarkGray' } else { Say (T '  - M = menu (all settings),  Q + Enter = end') 'DarkGray' }
    $line = ''
    $picked = $null
    # (The control window's input box answers this question too: a line, or files picked / dropped there.)
    $la = $null
    if ($keys) {
      $script:NavAskSeq++
      $la = @{ Id = 'm' + $script:NavAskSeq; Kind = 'line'; Title = (T 'What do you want to stream?'); Deadline = $null }
      $b = $script:UiBus
      if ($b) { $x = $null; while ($b.Answers.TryDequeue([ref]$x)) {}; $b.Ask = $la }
    }
    try {
      while ($keys) {
        $r = Read-AskLine '>' $Prefill -Nav -Ask $la
        $Prefill = ''
        if ($r.From -and $null -ne $r.From.Files) { $picked = @($r.From.Files); break }
        if ($r.Nav -eq 'back') {
          # (Esc never ends the stream: Q + Enter does. A second window just closes.)
          if ($add) { return @($script:QuitMark) }
          Show-NavHint (T '  Q + Enter = end the stream.')
          continue
        }
        if ($r.Nav -eq 'forward') { Show-NavHint (T '  (Nothing to go forward to.)'); continue }
        if ($r.Nav) { continue }
        $line = [string]$r.Text
        break
      }
    } finally { if ($la) { Clear-UiAsk $la.Id } }
    if ($null -ne $picked) {
      if ($picked.Count -gt 0) { return $picked }
      continue
    }
    if (-not $keys) { $line = [string](Read-Host '>') }
    $script:EntryLine = $line
    # A VPS connection code (it is a password: never search for it or print it): set up "My VPS" with it. A code a chat
    # wrapped over several lines (pasted in the control window) is one code, as Read-PastedRest joins it in the console.
    if ((Test-HostModule) -and (Test-VpsCodeText $line)) {
      $script:EntryLine = ''
      $line = (@($line -split "`r?`n") | ForEach-Object { $_.Trim() }) -join ''
      $line += Read-PastedRest
      if ($hostKeys) { Use-VpsCode $line } else { Say (T '  That is a VPS connection code: paste it in the window that streams (H -> My VPS).') 'Yellow' }
      continue
    }
    # Several lines at once (a list of links pasted or dropped in the control window): each a link or a path; of the
    # titles among them only the first one is searched for.
    $lns = @(@($line -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($lns.Count -gt 1) {
      $script:EntryLine = ''
      $out = @()
      $titles = @()
      foreach ($ln in $lns) { if (Test-IsTitle $ln) { $titles += $ln } else { $out += @(Split-EntryLine $ln) } }
      if ($titles.Count -gt 1) { Say (T '  Only the first title is searched for ({0}); {1} more skipped.' $titles[0] ($titles.Count - 1)) 'Yellow' }
      if ($titles.Count -gt 0) { $out += $titles[0] }
      return $out
    }
    if (-not $line.Trim()) {
      $files = @(Show-FilePicker)
      if ($files.Count -gt 0 -or -not $keys) { return $files }
      continue   # (picker cancelled: ask again)
    }
    # Q + Enter (or "quit"; on a Russian keyboard layout the Q key types U+0439) = end.
    if ($line -match '^\s*(?:q|quit|\u0439)\s*$') { return @($script:QuitMark) }
    # The menu letters (Get-MenuItems): H / V / T / N / L, and M = the settings menu.
    $mi = Get-MenuItemFor $line
    if ($mi -and -not $add -and (Test-MenuItemOn $mi)) { Invoke-MenuAction $mi.Id; continue }
    if ($mi) {
      # (A second window only hands videos over: the settings belong to the window that streams, which owns config.json.)
      $msg = ''
      if ($add -and ($mi.Id -eq 'res' -or $mi.Id -eq 'lang') -and (Test-MenuItemOn $mi)) { $msg = T '  V and L work in the window that streams.' }
      elseif ($add -and $mi.Id -eq 'menu') { $msg = T '  {0} works in the window that streams.' $mi.Letter }
      elseif ($mi.Need -eq 'host' -and (Test-HostModule) -and $line -match '^\s*(?:h|t|n|\u0440|\u0435|\u0442)\s*$') { $msg = T '  H / T / N work in the window that streams.' }
      if ($msg) { Say $msg 'Yellow'; continue }
    }
    return @(Split-EntryLine $line)
  }
}

# A line typed / pasted / dropped into the window while it streams.
# The rest of a paste that came in as several lines (a chat window may have wrapped a long code).
function Read-PastedRest {
  $rest = ''
  try {
    Start-Sleep -Milliseconds 150
    while (($script:HasConsole -or $script:KeySource) -and (Test-NavKeyWaiting)) { $rest += (Read-AskLine).Text; Start-Sleep -Milliseconds 100 }
  } catch {}
  return $rest
}

# While it streams, lines arrive one by one: what comes right after a code is the rest of it (dropped as well).
$script:CodePasteUntil = $null
function Add-TypedLine([string]$line, [string]$kind = '') {
  if ($script:CodePasteUntil -and (Get-Date) -lt $script:CodePasteUntil) { return }
  if ((Test-HostModule) -and (Test-VpsCodeText $line)) {
    $script:CodePasteUntil = (Get-Date).AddSeconds(2)
    Say (T '  That is a VPS connection code: when nothing plays, type H, choose "My VPS" and paste it there.') 'Yellow'
    return
  }
  # The menu letters (H / V / T / N / L, M = the settings menu): asked while nothing plays (Invoke-Queue runs them
  # with the waiting screen on); while a video plays they only say when they work.
  $mi = Get-MenuItemFor $line
  if ($mi -and (Test-MenuItemOn $mi)) {
    if ($kind -eq 'waiting') { Add-Cmd (New-Cmd $mi.Id); return }
    Say (T '  {0} works while nothing plays (after Q Q = stop).' $mi.Letter) 'Yellow'
    return
  }
  $entries = @(Split-EntryLine $line)
  if ($entries.Count -eq 0) { return }
  # A title while something plays: search in a second window, so this one keeps streaming undisturbed.
  if ($kind -ne 'waiting' -and $entries.Count -eq 1 -and (Test-IsTitle $entries[0])) { Open-AddWindow $entries[0]; return }
  Invoke-AddEntries $entries $kind $line
}

# Adds entries to the queue. While nothing plays (the waiting screen is on), this window may ask questions (which
# voice-over, which episodes, continue where you stopped?); the waiting screen keeps running meanwhile. Those run as
# a flow (Back / Forward): leaving it adds nothing and puts $line back as the text being typed.
function Invoke-AddEntries([string[]]$entries, [string]$kind = '', [string]$line = '') {
  $ask = ($kind -eq 'waiting')
  if ($ask) { Clear-StatusLine; $script:PromptOk = $true }
  try {
    if ($ask) {
      $r = Invoke-NavFlow -Name 'add' -Origin 'waiting' -Snap $script:SiteAnswerVars -Body {
        $before = $script:Queue.Count
        $n = Add-Entries $entries $true
        if ($n -gt 0) { Invoke-ResumeOffer $before }
        $n
      }
      if ($r.Nav) { if ($line) { $script:TypeBuf = $line }; return }
      if ([int]$r.Value -eq 0) { Say (T '  Nothing added - couldn''t find: {0}' ($entries -join ' ')) 'Yellow' }
      return
    }
    $n = Add-Entries $entries $true
    if ($n -eq 0) { Say (T '  Nothing added - couldn''t find: {0}' ($entries -join ' ')) 'Yellow' }
  } finally { $script:PromptOk = $false }
}

# Deletes an item's temporary folder (its download, subtitles, fonts). A download still running is stopped first and
# given a moment to let go of its file; a folder that is still in use is tried again later (Remove-PendingDirs).
$script:PendingDirs = New-Object System.Collections.ArrayList
function Stop-ProcessTree($proc) {
  try { [void](& taskkill.exe /T /F /PID $proc.Id 2>&1) } catch {}
  try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
  try { [void]$proc.WaitForExit(3000) } catch {}
}

# A torrent episode leaves the queue (played, skipped, dropped): its file and its share of the torrent go (once).
function Remove-TorrentItemRef($item) {
  if (-not ($item -and $item.Kind -eq 'torrent' -and $item.Torrent -and -not $item.Torrent.Released)) { return }
  $item.Torrent.Released = $true
  try { Remove-TorrentEpisodeFile $item } catch {}
  try { Remove-TorrentRef $item.Torrent.G } catch {}
}

function Remove-ItemFiles($item) {
  Remove-TorrentItemRef $item
  if ($item -and $item.JobDir) {
    if ($item.PSObject.Properties['Dl'] -and $item.Dl -and $item.Dl.Proc) {
      # (The whole tree: yt-dlp's own ffmpeg would keep the files open.)
      try { if (-not $item.Dl.Proc.HasExited) { Stop-ProcessTree $item.Dl.Proc } } catch {}
    }
    if ($script:JobLocks.ContainsKey($item.JobDir)) {
      try { $script:JobLocks[$item.JobDir].Dispose() } catch {}
      $script:JobLocks.Remove($item.JobDir)
    }
    try { [System.IO.Directory]::Delete($item.JobDir, $true) } catch {}
    if ([System.IO.Directory]::Exists($item.JobDir)) { [void]$script:PendingDirs.Add($item.JobDir) }
    $item.JobDir = $null
  }
}

function Remove-PendingDirs {
  for ($i = $script:PendingDirs.Count - 1; $i -ge 0; $i--) {
    $d = $script:PendingDirs[$i]
    try { [System.IO.Directory]::Delete($d, $true) } catch {}
    if (-not [System.IO.Directory]::Exists($d)) { $script:PendingDirs.RemoveAt($i) }
  }
}

# ------------------------------------------------------------------ web pages (AnimeGO, WPARTY, Kodik, ...)
# Some sites don't link to a video file: their page embeds a player (Kodik, AniBoom, ...). The code in
# VRChatLinkMaker.Sites.ps1 reads such pages the way their player does and finds the actual stream. The
# first video then plays straight from the site; the next ones download with ffmpeg in the background.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
$script:WebUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36'
$script:WebCookies = New-Object System.Net.CookieContainer
$script:JsonSer = $null
try { Add-Type -AssemblyName System.Web.Extensions } catch {}

# One HTTP request. Never throws for HTTP error codes (check .Status); throws when the server can't be reached.
# While a flow asks questions (Invoke-NavFlow, until its Lock-NavStep), the same request gets the same answer (or the
# same error) again, so a Back re-runs without the network; WPARTY's live room requests are fetched again after 120 s.
# A failure (an error, HTTP 0 / 408 / 429 / 5xx) is handed back only on a re-run: a retry in the same run asks again.
# (Invoke-WebParallel copies this function into runspaces, where no flow is open: it then runs as it always did.)
function Invoke-Web {
  param([Parameter(Mandatory = $true)][string]$Url, [string]$Method = 'GET', [hashtable]$Headers = @{}, [string]$Body = $null,
    [string]$ContentType = $null, [int]$TimeoutSec = 20, [switch]$NoRedirect, [switch]$NoMemo)
  if ($script:Nav -and -not $script:Nav.Sealed -and -not $NoMemo) {
    $root = Get-NavRoot
    $mk = 'web|' + $Method + '|' + $Url + '|' + $Body + '|' + ((@($Headers.Keys) | Sort-Object | ForEach-Object { "$_=$($Headers[$_])" }) -join '&')
    $hit = $null
    if ($root.Memo.TryGetValue($mk, [ref]$hit) -and (Test-NavMemoUse $hit)) {
      if ($hit.Err) { throw $hit.Err }
      return $hit.Res
    }
    $until = $null
    if ($Url -match '(?i)^https?://(?:[^/]*[.])?wparty[.][a-z]+/api/') { $until = (Get-Date).AddSeconds(120) }
    try { $res = Invoke-Web @PSBoundParameters -NoMemo }
    catch {
      if (-not (Test-NavAbort)) { $root.Memo[$mk] = @{ Res = $null; Err = $_.Exception; Until = $until; Fail = $true; Pass = $script:NavPass } }
      throw
    }
    $fail = ($null -eq $res -or $res.Status -eq 0 -or $res.Status -eq 408 -or $res.Status -eq 429 -or $res.Status -ge 500)
    $root.Memo[$mk] = @{ Res = $res; Err = $null; Until = $until; Fail = $fail; Pass = $script:NavPass }
    return $res
  }
  $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($Url)
  $req.Method = $Method
  $req.UserAgent = $script:WebUA
  $req.Accept = '*/*'
  $req.CookieContainer = $script:WebCookies
  $req.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
  $req.Timeout = $TimeoutSec * 1000
  $req.ReadWriteTimeout = $TimeoutSec * 1000
  $req.AllowAutoRedirect = -not $NoRedirect
  $req.Headers['Accept-Language'] = 'ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7'
  foreach ($k in $Headers.Keys) {
    $v = [string]$Headers[$k]
    switch ($k.ToLowerInvariant()) {
      'referer' { $req.Referer = $v }
      'accept' { $req.Accept = $v }
      'user-agent' { $req.UserAgent = $v }
      'content-type' { $req.ContentType = $v }
      default { $req.Headers[$k] = $v }
    }
  }
  if ($ContentType) { $req.ContentType = $ContentType }
  if ($null -ne $Body -and $Method -ne 'GET' -and $Method -ne 'HEAD') {   # ([string] makes a missing body '', not `$null)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $req.ContentLength = $bytes.Length
    $rs = $req.GetRequestStream()
    try { $rs.Write($bytes, 0, $bytes.Length) } finally { $rs.Dispose() }
  }
  $resp = $null
  try { $resp = $req.GetResponse() }
  catch [System.Net.WebException] { if ($_.Exception.Response) { $resp = $_.Exception.Response } else { throw } }
  try {
    $enc = [System.Text.Encoding]::UTF8
    try { if ($resp.CharacterSet -and $resp.CharacterSet -notmatch '(?i)iso-8859-1') { $enc = [System.Text.Encoding]::GetEncoding($resp.CharacterSet) } } catch {}
    $ms = New-Object System.IO.MemoryStream
    $st = $resp.GetResponseStream()
    try { $st.CopyTo($ms) } finally { $st.Dispose() }
    return [pscustomobject]@{ Status = [int]$resp.StatusCode; Url = $resp.ResponseUri.AbsoluteUri; Text = $enc.GetString($ms.ToArray()); Headers = $resp.Headers; Location = $resp.Headers['Location'] }
  } finally { $resp.Close() }
}

function ConvertTo-FormBody($fields) {
  $parts = foreach ($k in $fields.Keys) { [Uri]::EscapeDataString([string]$k) + '=' + [Uri]::EscapeDataString([string]$fields[$k]) }
  return ($parts -join '&')
}

# JSON -> Dictionary/array trees. Unlike ConvertFrom-Json it copes with keys that differ only in case.
function ConvertFrom-JsonDict([string]$json) {
  if (-not $script:JsonSer) {
    try {
      Add-Type -AssemblyName System.Web.Extensions
      $script:JsonSer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
      $script:JsonSer.MaxJsonLength = [int]::MaxValue
      $script:JsonSer.RecursionLimit = 256
    } catch { $script:JsonSer = 'none' }
  }
  if ($script:JsonSer -eq 'none') { return ($json | ConvertFrom-Json -AsHashtable) }
  return $script:JsonSer.DeserializeObject($json)
}

function Get-AbsUrl([string]$base, [string]$rel) {
  if ($rel.StartsWith('//')) { return ([Uri]$base).Scheme + ':' + $rel }
  return (New-Object System.Uri((New-Object System.Uri($base)), $rel)).AbsoluteUri
}

# A "stream" is what a site resolver returns: Url, Kind ('hls' or 'file'), Headers (what the server wants to see),
# Program (HLS quality to take from a multi-quality playlist, -1 = the playlist has just one), Duration (0 = unknown),
# LiveOnly (the server blocks fast downloads, so it can only be played at normal speed, straight from the site),
# AudioUrl (the sound comes as a separate playlist; such streams are always downloaded).
function New-Stream([string]$url, [string]$kind, [hashtable]$headers) {
  if (-not $headers) { $headers = @{} }
  return [pscustomobject]@{ Url = $url; Kind = $kind; Headers = $headers; Program = -1; Duration = 0.0; LiveOnly = $false; AudioUrl = $null }
}

function ConvertFrom-HtmlText([string]$s) { return [System.Net.WebUtility]::HtmlDecode($s) }

function Get-M3u8Attr([string]$line, [string]$name) {
  $m = [regex]::Match($line, '(?i)[:,]' + $name + '=("([^"]*)"|[^,]*)')
  if (-not $m.Success) { return '' }
  if ($m.Groups[2].Success) { return $m.Groups[2].Value }
  return $m.Groups[1].Value
}

# Looks at an HLS playlist: picks one quality when it offers several (the smallest one that is at least as
# tall as the stream we send, else the tallest) and works out the length.
function Complete-HlsStream($stream) {
  $r = Invoke-Web $stream.Url -Headers $stream.Headers
  if ($r.Status -ne 200 -or $r.Text -notmatch '#EXTM3U') { throw (T 'the video playlist didn''t load (HTTP {0})' $r.Status) }
  $text = $r.Text
  $base = $r.Url
  if ($text -match '#EXT-X-STREAM-INF') {
    $vars = New-Object System.Collections.ArrayList
    $lines = @($text -split "`r?`n")
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -notmatch '^#EXT-X-STREAM-INF') { continue }
      $uri = $null
      for ($j = $i + 1; $j -lt $lines.Count; $j++) { $t = $lines[$j].Trim(); if ($t -and -not $t.StartsWith('#')) { $uri = $t; break } }
      if (-not $uri) { continue }
      $h = 0; $bw = 0
      $res = Get-M3u8Attr $lines[$i] 'RESOLUTION'
      if ($res -match '^\d+x(\d+)$') { $h = [int]$matches[1] }
      [void][int]::TryParse((Get-M3u8Attr $lines[$i] 'BANDWIDTH'), [ref]$bw)
      [void]$vars.Add([pscustomobject]@{ Pos = $vars.Count; Url = (Get-AbsUrl $base $uri); Height = $h; Bw = $bw; Audio = (Get-M3u8Attr $lines[$i] 'AUDIO') })
    }
    if ($vars.Count -eq 0) { throw (T 'the video playlist is empty') }
    $want = $script:OutH
    $pick = @($vars | Where-Object { $_.Height -ge $want } | Sort-Object Height, Bw | Select-Object -First 1)
    if ($pick.Count -eq 0) { $pick = @($vars | Sort-Object Height, Bw -Descending | Select-Object -First 1) }
    $v = $pick[0]
    $stream | Add-Member -Force -NotePropertyName PickBw -NotePropertyValue $v.Bw
    $stream | Add-Member -Force -NotePropertyName PickH -NotePropertyValue $v.Height
    $audioUri = $null
    if ($v.Audio) {
      # The sound comes as its own playlist: take the group's default one (else the first).
      foreach ($l in $lines) {
        if ($l -notmatch '^#EXT-X-MEDIA:' -or (Get-M3u8Attr $l 'TYPE') -ne 'AUDIO' -or (Get-M3u8Attr $l 'GROUP-ID') -ne $v.Audio) { continue }
        $u = Get-M3u8Attr $l 'URI'
        if (-not $u) { continue }
        if (-not $audioUri -or (Get-M3u8Attr $l 'DEFAULT') -eq 'YES') { $audioUri = $u }
        if ((Get-M3u8Attr $l 'DEFAULT') -eq 'YES') { break }
      }
    }
    if ($v.Audio -and -not $audioUri) {
      # Separate sound we can't pick out: keep the master playlist and tell ffmpeg which quality to take.
      $stream.Program = $v.Pos
      $r2 = Invoke-Web $v.Url -Headers $stream.Headers
      if ($r2.Status -eq 200) { $text = $r2.Text } else { $text = '' }
    } else {
      if ($audioUri) { $stream.AudioUrl = Get-AbsUrl $base $audioUri }
      $stream.Url = $v.Url
      $r2 = Invoke-Web $v.Url -Headers $stream.Headers
      if ($r2.Status -ne 200 -or $r2.Text -notmatch '#EXTM3U') { throw (T 'the video playlist didn''t load (HTTP {0})' $r2.Status) }
      $text = $r2.Text
    }
  } else {
    $stream.Url = $base
  }
  $sum = 0.0
  foreach ($m in [regex]::Matches($text, '#EXTINF:\s*([0-9.]+)')) { $sum += [double]::Parse($m.Groups[1].Value, $script:Inv) }
  $stream.Duration = $sum
  return $stream
}

# Complete-HlsStream in a runspace of its own (its playlists can take up to 20 s each to load). Poll .H.IsCompleted;
# .Ps.EndInvoke(.H) then gives the stream, or nothing when it didn't work out.
function Start-HlsPickBg($hls) {
  $defs = @(foreach ($n in @('Invoke-Web', 'Get-M3u8Attr', 'Get-AbsUrl', 'New-Stream', 'Complete-HlsStream')) {
      "function $n {`n" + (Get-Item "function:$n").ScriptBlock.ToString() + "`n}" }) -join "`n"
  $ps = [powershell]::Create()
  [void]$ps.AddScript({
      param($defs, $ua, $outH, $url, $headers)
      $script:WebUA = $ua; $script:WebCookies = New-Object System.Net.CookieContainer
      $script:OutH = $outH; $script:Inv = [System.Globalization.CultureInfo]::InvariantCulture
      function T { return [string]$args[0] }
      . ([scriptblock]::Create($defs))
      try { return (Complete-HlsStream (New-Stream $url 'hls' $headers)) } catch { return $null }
    }).AddArgument($defs).AddArgument($script:WebUA).AddArgument($script:OutH).AddArgument($hls.Url).AddArgument($hls.Headers)
  return [pscustomobject]@{ Ps = $ps; H = $ps.BeginInvoke(); Started = Get-Date }
}

$script:HlsOpts = $null
function Get-StreamInputArgs($stream) {
  if ($null -eq $script:HlsOpts) {
    $script:HlsOpts = ''
    try { $script:HlsOpts = (Invoke-Capture $script:FFmpeg @('-hide_banner', '-h', 'demuxer=hls')).Out } catch {}
  }
  $a = New-Object System.Collections.Generic.List[string]
  $ua = $script:WebUA
  $hdr = ''
  foreach ($k in $stream.Headers.Keys) {
    if ($k -eq 'User-Agent') { $ua = [string]$stream.Headers[$k] } else { $hdr += "$($k): $($stream.Headers[$k])`r`n" }
  }
  $a.Add('-user_agent'); $a.Add($ua)
  if ($hdr) { $a.Add('-headers'); $a.Add($hdr) }
  $a.Add('-rw_timeout'); $a.Add('30000000')
  if ($stream.Kind -eq 'hls') {
    if ($script:HlsOpts -match 'seg_max_retry') { $a.Add('-seg_max_retry'); $a.Add('5') }
    if ($script:HlsOpts -match 'extension_picky') { $a.Add('-extension_picky'); $a.Add('0') }
  } else {
    foreach ($x in @('-reconnect', '1', '-reconnect_streamed', '1', '-reconnect_on_network_error', '1', '-reconnect_delay_max', '10')) { $a.Add($x) }
  }
  return $a.ToArray()
}

# Downloads a resolved stream to <job>\dl\video.mkv with ffmpeg in the background.
function Start-StreamDownload($item, $stream) {
  $dl = PathJoin $item.JobDir 'dl'
  try { if ([System.IO.Directory]::Exists($dl)) { [System.IO.Directory]::Delete($dl, $true) } } catch {}
  [void][System.IO.Directory]::CreateDirectory($dl)
  $item.DlDir = $dl
  $item.Stream = $stream
  $argv = New-Object System.Collections.Generic.List[string]
  foreach ($x in @('-hide_banner', '-nostdin', '-v', 'error', '-nostats', '-progress', 'progress.txt', '-y')) { $argv.Add($x) }
  foreach ($x in (Get-StreamInputArgs $stream)) { $argv.Add($x) }
  $argv.Add('-i'); $argv.Add($stream.Url)
  if ($stream.AudioUrl) {
    foreach ($x in (Get-StreamInputArgs $stream)) { $argv.Add($x) }
    $argv.Add('-i'); $argv.Add($stream.AudioUrl)
    foreach ($x in @('-map', '0:v:0', '-map', '1:a:0')) { $argv.Add($x) }
  } elseif ($stream.Program -ge 0) { $p = $stream.Program; foreach ($x in @('-map', "0:p:$($p):v:0", '-map', "0:p:$($p):a?")) { $argv.Add($x) } }
  else { foreach ($x in @('-map', '0:v:0?', '-map', '0:a?')) { $argv.Add($x) } }
  foreach ($x in @('-c', 'copy', '-f', 'matroska', 'video.mkv')) { $argv.Add($x) }
  if ($env:VRCLM_DEBUG) { Say ("ffmpeg " + (Join-CmdArgs $argv.ToArray())) 'DarkGray' }
  $item.Dl = Start-Background $script:FFmpeg $argv.ToArray() $dl
  $item.DlKind = 'ffmpeg'
  $item.State = 'downloading'
}

# How much of a web video's download is done (0..1; 0 when unknown).
function Get-DownloadFraction($item) {
  if ($item.DlKind -eq 'torrent') {
    if ($item.Dl -and $item.Torrent -and $item.Torrent.Bytes -gt 0) { return [Math]::Min(1.0, $item.Dl.Done / $item.Torrent.Bytes) }
    return 0.0
  }
  if ($item.DlKind -ne 'ffmpeg' -or -not $item.DlDir -or -not $item.Stream -or $item.Stream.Duration -le 0) { return 0.0 }
  $pr = Read-Progress (PathJoin $item.DlDir 'progress.txt')
  if (-not $pr) { return 0.0 }
  return [Math]::Min(1.0, $pr.Time / $item.Stream.Duration)
}

function Get-DownloadText($item) {
  if ($item.DlKind -eq 'torrent') { return (Get-TorrentDownloadText $item) }
  if ($item.DlKind -eq 'ytdlp' -and $item.DlDir) {
    # yt-dlp runs quietly: what is on disk so far.
    $mb = (Get-DirBytes $item.DlDir) / 1MB
    if ($mb -lt 0.1) { return (T 'starting the download') }
    return (T 'downloaded {0} MB' ([Math]::Round($mb, 1).ToString('0.0', $script:Inv)))
  }
  if ($item.DlKind -ne 'ffmpeg' -or -not $item.DlDir) { return (T 'downloading') }
  $pr = Read-Progress (PathJoin $item.DlDir 'progress.txt')
  if (-not $pr -or $pr.Time -le 0) { return (T 'starting the download') }
  if ($item.Stream -and $item.Stream.Duration -gt 0) {
    $pct = [int][Math]::Min(99, [Math]::Floor(100 * $pr.Time / $item.Stream.Duration))
    return (T 'downloading {0}%' $pct)
  }
  return (T 'downloaded {0}' (Format-Time $pr.Time))
}

# Asks which episodes to play. $list = objects with a .Number (text). $defPos = where "just Enter" starts.
# -Key: the step's name in a flow (the tape keeps the typed text). Never returns an empty list.
function Read-EpisodeSelection {
  [CmdletBinding(PositionalBinding = $false)]
  param([Parameter(Position = 0)]$list, [Parameter(Position = 1)][int]$defPos, [string]$Key = '')
  if ($list.Count -le 1) { return @($list) }
  $a = New-NavAsk 'episodes' (T 'Which episodes? (1 to {0}; type e.g. 5, or 3-8, or 3- for 3 to the end)' ($list[$list.Count - 1].Number)) $Key
  $a.List = @($list)
  $a.DefPos = $defPos
  return @(Invoke-Ask $a)
}

# ------------------------------------------------------------------ which player (Kodik, AniBoom, ...) a web video comes from
# "Player" in config.json: "ask" (the default: asked once per session, the first time there is a choice), "auto" (the
# players that have the chosen voice-over are all checked and the sharpest real picture wins), or a player's name
# (kodik, aniboom, cvh, sibnet, collaps, animelib, alloha, dreamcast, aniliberty, animevost: that one first). The answer holds for the whole session.
$script:PlayerPref = $null
$script:AutoWinner = $null   # the player "auto" picked last (for videos that aren't part of a show)
$script:ShowWinners = @{}    # show -> the player "auto" picked for it ('' = nothing to compare): its next episodes try it first

# Which show (and voice-over) a web video belongs to, for remembering the player "auto" picked: $null for a lone video.
function Get-ShowKey($item) {
  $s = $item.Site
  if (-not $s) { return $null }
  switch ("$($s.Type)") {
    'wparty' { return "kp:$($s.Room.KpId):$($s.Season):$($s.DubName)" }
    'animego' { return "ag:$($s.AnimeId):$($s.DubName)" }
    'animelib' { return "al:$($s.Sid):$(@($s.Names)[0]):$($s.DubName)" }
    'shikimori' { return "sh:$($s.Sid):$($s.DubName)" }
    'yummy' { return "ym:$($s.Id):$($s.Dub)" }
    # A release with its own player and a backup (AniLiberty: its HLS + Kodik): one show per release.
    'player' { if (@($s.Cands | Where-Object { -not $_.PSObject.Properties['Backup'] }).Count -gt 1) { return "pl:$($item.Source -replace '#.*$', ''):$(@($s.Cands)[0].Dub)" } }
  }
  return $null
}

# The player "auto" picked for this video's show: a name, '' (checked, nothing to pick), or $null (not checked yet).
function Get-AutoWinner($item) {
  $k = Get-ShowKey $item
  if (-not $k) { if ($script:AutoWinner) { return $script:AutoWinner }; return '' }
  if ($script:ShowWinners.ContainsKey($k)) { return $script:ShowWinners[$k] }
  return $null
}

function Set-AutoWinner($item, [string]$prov) {
  if ($prov) { $script:AutoWinner = $prov }
  $k = Get-ShowKey $item
  if ($k) { $script:ShowWinners[$k] = $prov }
}

# The candidates left that have voice-over $dub (default: the first one left's; other voice-overs are a last resort).
function Get-SameDubCands($item, $dub = $null) {
  $left = @($item.Cands | Select-Object -Skip $item.CandIdx)
  if ($left.Count -eq 0) { return @() }
  $d = [string]$left[0].Dub
  if ($null -ne $dub) { $d = [string]$dub }
  return @($left | Where-Object { (-not $d -and -not $_.Dub) -or ($d -and $_.Dub -and ([string]$_.Dub -eq $d -or (Test-SameDub ([string]$_.Dub) $d))) })
}

function Get-PlayerPref($item) {
  if ($script:PlayerPref) { return $script:PlayerPref }
  $v = "$(Get-Prop $script:Cfg 'Player')".Trim().ToLowerInvariant()
  if ($v -and $v -ne 'ask') { return $v }
  $provs = @(Get-SameDubCands $item | ForEach-Object { $_.Provider } | Select-Object -Unique)
  if ($provs.Count -lt 2 -or -not (Test-CanAsk)) { return 'auto' }   # (not remembered: it asks once it can)
  $opts = @((T 'Auto - check them all and take the sharpest picture (takes a few seconds more)'))
  foreach ($p in $provs) { $opts += (Get-ProviderTitle $p) }
  Say ''
  # (Asked while preparing: a one-off question, Esc = Auto. No Back goes past the queue insert.)
  Lock-NavStep
  $tos = $script:AskTimeouts
  $i = Read-Choice (T 'Which player should the video come from?') $opts 0 $false -Key 'player' -Values (@('auto') + @($provs | ForEach-Object { [string]$_ })) -Esc 0
  $pick = 'auto'
  if ($i -gt 0) { $pick = [string]$provs[$i - 1] }
  # (Kept for the session only when someone answered: a question that timed out asks again next time.)
  if ($script:AskTimeouts -eq $tos) { $script:PlayerPref = $pick }
  return $pick
}

# A second window (it hands what it found to the streaming one, which can't ask while a video plays) asks here which
# player to take, like Get-PlayerPref, and the answer goes along with the link (player=...). Without it the streaming
# window took the first player in the list (Kodik) for videos added while one played. Not asked when config.json names a
# player, or when the streaming window already has an answer this session (VRCLM_PLAYER, set by Open-AddWindow).
function Read-HandoverPlayer($items) {
  $script:LastPlayer = $null
  $first = @($items | Where-Object { $_.Kind -eq 'site' }) | Select-Object -First 1
  if (-not $first -or -not (Test-CanAsk)) { return }
  $v = "$(Get-Prop $script:Cfg 'Player')".Trim().ToLowerInvariant()
  if ($v -and $v -ne 'ask') { return }
  $given = "$env:VRCLM_PLAYER".Trim().ToLowerInvariant()
  if ($given -match '^[a-z]+$') { $script:LastPlayer = $given; return }
  $cands = @()
  try { $cands = @(Get-SiteCandidates $first) } catch { return }
  $provs = @(Get-SameDubCands ([pscustomobject]@{ Cands = $cands; CandIdx = 0 }) | ForEach-Object { $_.Provider } | Select-Object -Unique)
  if ($provs.Count -lt 2) { return }
  $opts = @((T 'Auto - check them all and take the sharpest picture (takes a few seconds more)'))
  foreach ($p in $provs) { $opts += (Get-ProviderTitle $p) }
  Say ''
  $i = Read-Choice (T 'Which player should the video come from?') $opts 0 $false -Key 'player' -Values (@('auto') + @($provs | ForEach-Object { [string]$_ }))
  if ($i -le 0) { $script:LastPlayer = 'auto' } else { $script:LastPlayer = [string]$provs[$i - 1] }
}

# Puts the candidates of player $prov first among those with the same voice-over.
function Set-CandFirst($item, [string]$prov) {
  $same = @(Get-SameDubCands $item)
  $mine = @($same | Where-Object { $_.Provider -eq $prov })
  if ($mine.Count -eq 0) { return }
  $done = @($item.Cands | Select-Object -First $item.CandIdx)
  $rest = @($item.Cands | Select-Object -Skip $item.CandIdx | Where-Object { $mine -notcontains $_ })
  $item.Cands = @($done + $mine + $rest)
}

# A candidate's stream: the one looked up by the quality check (if it's fresh), else looked up now.
function Get-ResolvedStream($c) {
  if ($c.PSObject.Properties['Resolved'] -and $c.Resolved -and ((Get-Date) - $c.ResolvedAt).TotalMinutes -lt 20) {
    $st = $c.Resolved
    $c.Resolved = $null   # (used once: a second try gets a fresh link)
    return $st
  }
  $st = Resolve-Candidate $c
  if ($st.Kind -eq 'hls') { $st = Complete-HlsStream $st }
  return $st
}

# "auto": looks up every player with the chosen voice-over, reads the real picture size of each with ffprobe (all at
# once), then puts them in order: tallest real picture, then higher bitrate, then the usual order.
function Invoke-AutoPick($item) {
  # (A Backup candidate is the same player's file in another quality, see Expand-Animevost: nothing to compare.)
  $same = @(Get-SameDubCands $item | Where-Object { -not $_.LiveOnly -and -not $_.PSObject.Properties['Backup'] } | Select-Object -First 4)
  if ($same.Count -lt 2) { Set-AutoWinner $item ''; return }
  Say (T '  Checking {0} players for the sharpest picture...' $same.Count) 'Gray'
  $jobs = New-Object System.Collections.ArrayList
  $failed = New-Object System.Collections.ArrayList
  foreach ($c in $same) {
    $c | Add-Member -Force -NotePropertyName RealHeight -NotePropertyValue 0
    $c | Add-Member -Force -NotePropertyName RealKbps -NotePropertyValue 0
    try {
      $st = Resolve-Candidate $c
      if ($st.Kind -eq 'hls') { $st = Complete-HlsStream $st }
      $c | Add-Member -Force -NotePropertyName Resolved -NotePropertyValue $st
      $c | Add-Member -Force -NotePropertyName ResolvedAt -NotePropertyValue (Get-Date)
      # (A playlist whose sound can't be picked out has to be downloaded anyway: not checked, it goes after the checked ones.)
      if ($st.Program -lt 0) { [void]$jobs.Add([pscustomobject]@{ Cand = $c; Stream = $st; Bg = (Start-Background $script:FFprobe (Get-MediaInfoArgs $st.Url $true $st)) }) }
    } catch {
      $item.Errors = @($item.Errors) + @("$($c.Label): $($_.Exception.Message)")
      [void]$failed.Add($c)
    }
  }
  $until = (Get-Date).AddSeconds(20)
  while ((Get-Date) -lt $until -and @($jobs | Where-Object { -not $_.Bg.Proc.HasExited }).Count -gt 0) { Wait-Pump 0.1 }
  foreach ($j in $jobs) {
    if (-not $j.Bg.Proc.HasExited) { Stop-Proc $j.Bg.Proc; continue }
    try {
      $info = ConvertFrom-ProbeOutput ([pscustomobject]@{ ExitCode = $j.Bg.Proc.ExitCode; Out = $j.Bg.Out.Result; Err = $j.Bg.Err.Result })
      if ($info.Video) { $j.Cand.RealHeight = [int]$info.Video.Height }
      $j.Cand.RealKbps = [int]($info.BitRate / 1000)
      # Playing it straight from the site doesn't need to read it a second time.
      if (-not $j.Stream.AudioUrl) { $j.Stream | Add-Member -Force -NotePropertyName Probe -NotePropertyValue $info }
    } catch {}
  }
  $pos = @{}
  for ($i = 0; $i -lt $same.Count; $i++) { $pos[$same[$i]] = $i }
  $ranked = @($same | Where-Object { $failed -notcontains $_ } |
    Sort-Object -Property @{ Expression = { $_.RealHeight }; Descending = $true }, @{ Expression = { $_.RealKbps }; Descending = $true }, @{ Expression = { $pos[$_] } })
  $done = @($item.Cands | Select-Object -First $item.CandIdx)
  $rest = @($item.Cands | Select-Object -Skip $item.CandIdx | Where-Object { $same -notcontains $_ })
  $item.Cands = @($done + $ranked + $rest + @($failed))
  $txt = @($same | ForEach-Object {
      $q = '?'
      if ($failed -contains $_) { $q = T 'doesn''t work' } elseif ($_.RealHeight -gt 0) { $q = "$($_.RealHeight)p" }
      "$(Get-ProviderTitle $_.Provider) $q"
    }) -join ', '
  if ($ranked.Count -gt 0) {
    Set-AutoWinner $item $ranked[0].Provider
    Say (T '  Players: {0}  ->  {1}' $txt (Get-ProviderTitle $ranked[0].Provider)) 'Gray'
  } else { Set-AutoWinner $item '' }
}

# The stream from the site broke off (or can't be read): go on with the next player that has the same voice-over and
# the same length, from the same spot ($true), instead of first downloading the whole video from the broken one.
function Switch-ToBackup($item) {
  if ($item.Kind -ne 'site' -or -not $item.Cands) { return $false }
  $saved = $item.CandIdx
  $dur = 0.0
  if ($item.Info -and $item.Info.Duration -gt 0) { $dur = $item.Info.Duration } elseif ($item.Stream) { $dur = $item.Stream.Duration }
  $dub = ''
  if ($item.Using) { $dub = [string]$item.Using.Dub }
  foreach ($c in @(Get-SameDubCands $item $dub)) {
    $item.CandIdx = [array]::IndexOf($item.Cands, $c) + 1
    if ($c.LiveOnly) { continue }
    try {
      $st = Get-ResolvedStream $c
      if ($st.Program -ge 0 -or $st.LiveOnly) { continue }
      $d2 = $st.Duration
      if ($st.PSObject.Properties['Probe'] -and $st.Probe -and $st.Probe.Duration -gt 0) { $d2 = $st.Probe.Duration }
      if ($dur -gt 60 -and $d2 -gt 60 -and [Math]::Abs($d2 - $dur) -gt 5) {
        # Another cut of the episode: the same spot would be a different moment.
        $item.Errors = @($item.Errors) + @("$($c.Label): " + (T 'a different length ({0} instead of {1})' (Format-Time $d2) (Format-Time $dur)))
        continue
      }
      $item.Using = $c
      $item.Stream = $st
      $item.IsDirectUrl = $true
      $item.Path = $st.Url
      $item.State = 'probe'
      Say (T '  Going on from {0} with the backup player: {1}.' (Format-Time $item.ResumeAt) $c.Label) 'Yellow'
      return $true
    } catch {
      $item.Errors = @($item.Errors) + @("$($c.Label): $($_.Exception.Message)")
    }
  }
  $item.CandIdx = $saved
  return $false
}

# Tries the item's possible sources in order until one resolves, then streams it directly (first video,
# nothing live yet) or starts downloading it. Throws when none is left.
function Start-NextSource($item) {
  if ($null -eq $item.Cands) {
    $item.Cands = @(Get-SiteCandidates $item)
    $item.CandIdx = 0
  }
  $isCur = ($script:Idx -lt $script:Queue.Count -and [object]::ReferenceEquals($script:Queue[$script:Idx], $item))
  if (-not $item.PSObject.Properties['PlayerPicked'] -and $item.Cands.Count -gt 1) {
    # (The window that searched for it may have asked already, see Read-HandoverPlayer.)
    $pref = $null
    if ($item.PSObject.Properties['PlayerChoice'] -and $item.PlayerChoice) {
      $pref = [string]$item.PlayerChoice
      if (-not $script:PlayerPref) { $script:PlayerPref = $pref }   # (the answer holds for the session, as when asked here)
    } else { $pref = Get-PlayerPref $item }
    $won = $null
    if ($pref -eq 'auto' -and -not $isCur) {
      # No checking while a video streams (it would hold up this window). A show not checked yet waits for its turn:
      # getting it ready now meant taking the first player in the list (Kodik), whatever "auto" would have picked.
      $won = Get-AutoWinner $item
      if ($null -eq $won -and @(Get-SameDubCands $item | Where-Object { -not $_.LiveOnly -and -not $_.PSObject.Properties['Backup'] }).Count -ge 2) { return }
    }
    $item | Add-Member -NotePropertyName PlayerPicked -NotePropertyValue $true
    if ($pref -ne 'auto') { Set-CandFirst $item $pref }
    elseif ($isCur) { Invoke-AutoPick $item }
    elseif ($won) { Set-CandFirst $item $won }
  }
  while ($item.CandIdx -lt $item.Cands.Count) {
    $c = $item.Cands[$item.CandIdx]
    # Sources that can only be played live are looked up when it's this video's turn.
    if ($c.LiveOnly -and -not $isCur) { return }
    $item.CandIdx++
    try {
      $st = Get-ResolvedStream $c
      if ($st.LiveOnly -and $st.Program -ge 0) { throw (T 'this stream can only be played live, but it comes in a form that needs a download') }
      $item.Using = $c
      $item.Stream = $st
      if ($st.LiveOnly -or ($isCur -and $st.Program -lt 0 -and -not $item.NoDirect)) {
        # It's this video's turn: play it straight from the site instead of waiting for a download.
        $item.IsDirectUrl = $true
        $item.Path = $st.Url
        $item.State = 'probe'
      } else {
        Start-StreamDownload $item $st
      }
      return
    } catch {
      $item.Errors = @($item.Errors) + @("$($c.Label): $($_.Exception.Message)")
    }
  }
  if (@($item.Errors).Count -gt 0) { throw (T 'no source worked ({0})' (@($item.Errors) -join '; ')) }
  throw (T 'no video source found for it')
}

# A finished ffmpeg download: $true = file is ready, $false = it failed and the next source is downloading.
function Complete-StreamDownload($item) {
  $out = PathJoin $item.DlDir 'video.mkv'
  $exit = $null
  try { $exit = $item.Dl.Proc.ExitCode } catch {}
  $got = $null
  $pr = Read-Progress (PathJoin $item.DlDir 'progress.txt')
  if ($pr) { $got = $pr.Time }
  $short = ($item.Stream -and $item.Stream.Duration -gt 60 -and $null -ne $got -and $got -lt $item.Stream.Duration - 20)
  if ((Get-BgText $item.Dl) -match 'Stream ends prematurely|partial file') { $short = $true }
  if ($exit -eq 0 -and -not $short -and [System.IO.File]::Exists($out) -and (New-Object System.IO.FileInfo($out)).Length -gt 262144) {
    $item.Path = $out
    return $true
  }
  $why = Get-LastLines (Get-BgText $item.Dl) 2
  $stalled = [bool]($item.Dl.PSObject.Properties['Stalled'] -and $item.Dl.Stalled)
  if ($stalled) {
    $why = T 'no progress for {0} seconds' $script:DlStallSec
    $item.Retried = $true   # (not the same source once more: on to the next one)
  } elseif ($short -and $null -ne $got -and $item.Stream.Duration -gt 0) { $why = T 'it stopped at {0} of {1}' (Format-Time $got) (Format-Time $item.Stream.Duration) }
  elseif ($short) { $why = T 'the connection was cut off' }
  if (-not $why) { $why = T 'ffmpeg error {0}' $exit }
  $item.Errors = @($item.Errors) + @("$($item.Using.Label): " + (T 'download failed ({0})' $why))
  if (-not $item.Retried -and $why -notmatch '(?i)\b404\b') {
    # Try the same source once more (links can expire or a server can hiccup), then the others. (A file that isn't
    # there, HTTP 404, won't be there a second later.)
    $item.Retried = $true
    $item.CandIdx = [Math]::Max(0, $item.CandIdx - 1)
  }
  Start-NextSource $item
  return ($item.State -ne 'downloading')
}

# Can this window ask a question right now? Not while a video is streaming (the window is busy watching
# the stream); yes before the stream starts, and while viewers see the waiting screen and the window waits
# for something to play ($script:PromptOk, set around those questions).
$script:PromptOk = $false
function Test-CanAsk { return ($script:Interactive -and ($script:PromptOk -or -not (Test-RelayAlive))) }

$script:SitesFile = PathJoin $script:ToolDir 'VRChatLinkMaker.Sites.ps1'
if ([System.IO.File]::Exists($script:SitesFile)) { . $script:SitesFile }
if (-not (Get-Command Test-SiteLink -CommandType Function -ErrorAction SilentlyContinue)) {
  function Test-SiteLink([string]$u) { return $false }
}

# Where the stream goes: Topaz Chat, this PC, the user's own VPS, or custom links (host profiles, MediaMTX,
# network checks, the upload speed test). Without the file it's always Topaz / the links in config.json.
$script:HostP = $null
$script:HostsFile = PathJoin $script:ToolDir 'VRChatLinkMaker.Hosts.ps1'
if ([System.IO.File]::Exists($script:HostsFile)) { . $script:HostsFile }
function Test-HostModule { return [bool](Get-Command Get-HostProfile -CommandType Function -ErrorAction SilentlyContinue) }

# The control window (buttons + a small preview of what viewers get). Optional: without the file the
# window just isn't offered.
$script:PreviewFile = PathJoin $script:TempRoot 'preview.jpg'
$script:PanelFile = PathJoin $script:ToolDir 'VRChatLinkMaker.Panel.ps1'
if ([System.IO.File]::Exists($script:PanelFile)) { . $script:PanelFile }

# Updates from GitHub (asked about at start). Optional: without the file there are none.
$script:UpdateFile = PathJoin $script:ToolDir 'VRChatLinkMaker.Update.ps1'
if ([System.IO.File]::Exists($script:UpdateFile)) { . $script:UpdateFile }

# ------------------------------------------------------------------ torrents (each episode downloads completely, then plays)
# A magnet link, a bare info hash (40 hex or 32 base32 characters), a .torrent file or a link to one (also a Nyaa
# page) is downloaded with rqbit, a small free torrent program (github.com/ikatson/rqbit, Apache-2.0), fetched once
# after asking into bin\rqbit (one pinned, checksum-verified release, like MediaMTX). An episode plays once it is
# complete: from then on it is a video file on this PC (tracks, subtitles, the fonts inside it).
# While an episode downloads it also uploads to others, capped ("TorrentUploadKBps", default 32 KB/s); when the
# episode is complete the torrent is paused, so it stops uploading ("Torrents": "seed" keeps it going). Once its
# episodes have played, the files are deleted. "Torrents": "off" turns torrent links off.
# rqbit runs as a child of this tool (it ends with it, see ChildJob), without a window; its web API listens on
# 127.0.0.1 only, on a free port, with a random password (a web page could otherwise send it commands). A magnet
# link can take up to a minute or more to find the people sharing it: that runs in the background, never on the
# loop that feeds the stream.
$script:RqbitVersion = 'v9.0.1'
$script:RqbitUrl = 'https://github.com/ikatson/rqbit/releases/download/v9.0.1/rqbit.exe'
$script:RqbitBytes = 12706816
$script:RqbitSha256 = '2ed683203beca628e0c45f62f99feeef4242cecc3444c8422dfe5b1b6aa38cea'
$script:PinnedChecked = @{}     # tool -> exe path whose checksum was checked this run
$script:PinnedRefused = @{}     # tool -> the flow (or $true outside one) where the person said no (see Test-PinnedRefused)
$script:PinnedNoted = $false
$script:Rqbit = $null           # the running engine: Proc, Port, Auth, Dir, DlDir, Lock, Ready, Started, Torrents (id -> group)
$script:RqbitStarts = 0
$script:KeepAwake = $false
$script:NoteText = $null        # what the waiting screen's extra line says now (see Write-ScreenNote)
$script:NoteAt = [datetime]::MinValue

# 'magnet' | 'hash' | 'file' | 'url' when $s is a torrent link (a hand-over's #vrclm=... part ignored), else $null.
function Test-TorrentLink([string]$s) {
  $t = ([string]$s).Trim().Trim('"').Trim()
  $i = $t.IndexOf('#vrclm=')
  if ($i -ge 0) { $t = $t.Substring(0, $i) }
  if (-not $t) { return $null }
  if ($t -match '^(?i)magnet:\?') {
    # (A v2-only magnet, "btmh", isn't supported.)
    if ($t -match '(?i)[?&]xt=urn:btih:(?:[0-9a-f]{40}|[a-z2-7]{32})(?:&|$)') { return 'magnet' }
    return $null
  }
  # A bare hash: 40 hex, or 32 base32 in capitals (no title looks like that).
  if ($t -cmatch '^(?:[0-9a-fA-F]{40}|[A-Z2-7]{32})$') { return 'hash' }
  if ($t -match '^(?i)https?://') {
    $path = ($t -split '[?#]', 2)[0]
    if ($path -match '(?i)\.torrent$') { return 'url' }
    if ($path -match '^(?i)https?://(?:www\.)?nyaa\.si/(?:download|view)/\d+(?:\.torrent)?/?$') { return 'url' }
    return $null
  }
  if ($t -match '(?i)\.torrent$') { try { if ([System.IO.File]::Exists([System.IO.Path]::GetFullPath($t))) { return 'file' } } catch {} }
  return $null
}

function ConvertFrom-Base32Hash([string]$s) {
  $alpha = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
  $sb = New-Object System.Text.StringBuilder
  $bits = 0; $val = 0
  foreach ($c in $s.ToUpperInvariant().ToCharArray()) {
    $n = $alpha.IndexOf($c)
    if ($n -lt 0) { return $null }
    $val = (($val -shl 5) -bor $n) -band 0x1FFF
    $bits += 5
    if ($bits -ge 8) { $bits -= 8; [void]$sb.Append((($val -shr $bits) -band 0xFF).ToString('x2')) }
  }
  return $sb.ToString()
}

# The info hash (40 lowercase hex) of a magnet link or a bare hash.
function Get-TorrentHash([string]$s) {
  $v = ([string]$s).Trim()
  $m = [regex]::Match($v, '(?i)[?&]xt=urn:btih:([0-9a-z]+)')
  if ($m.Success) { $v = $m.Groups[1].Value }
  if ($v -match '^[0-9a-fA-F]{40}$') { return $v.ToLowerInvariant() }
  if ($v -match '^[A-Za-z2-7]{32}$') { return (ConvertFrom-Base32Hash $v) }
  return $null
}

function Get-MagnetName([string]$m) {
  $x = [regex]::Match($m, '(?i)[?&]dn=([^&#]+)')
  if (-not $x.Success) { return '' }
  try { return [Uri]::UnescapeDataString($x.Groups[1].Value.Replace('+', ' ')) } catch { return '' }
}

# A Nyaa page -> its .torrent file.
function Get-TorrentFileUrl([string]$u) {
  $m = [regex]::Match($u, '^(?i)(https?://(?:www\.)?nyaa\.si)/(?:view|download)/(\d+)')
  if ($m.Success) { return "$($m.Groups[1].Value)/download/$($m.Groups[2].Value).torrent" }
  return $u
}

function Get-TorrentsSetting {
  $v = "$(Get-Prop $script:Cfg 'Torrents')".Trim().ToLowerInvariant()
  if ($v -match '^(off|no|false|0)$') { return 'off' }
  if ($v -eq 'seed') { return 'seed' }
  return 'on'
}
function Get-TorrentUploadKBps { return [int](Get-NumSetting 'TorrentUploadKBps' 32 8 1000000) }
function Get-TorrentDownloadKBps { return [int](Get-NumSetting 'TorrentDownloadKBps' 0 0 10000000) }

function Get-JsonVal($o, [string]$k) {
  if ($o -is [System.Collections.Generic.IDictionary[string, object]]) { if ($o.ContainsKey($k)) { return $o[$k] }; return $null }
  if ($o -is [System.Collections.IDictionary]) { return $o[$k] }
  return $null
}

function Get-FileSha256([string]$path) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $fs = [System.IO.File]::OpenRead($path)
  try { $h = $sha.ComputeHash($fs) } finally { $fs.Dispose(); $sha.Dispose() }
  return (-join ($h | ForEach-Object { $_.ToString('x2') }))
}

# Downloads $url to $dest, showing "<$progress with {0} = percent>" on the status line (MediaMTX, rqbit).
function Save-WebFile([string]$url, [string]$dest, [string]$progress) {
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
  $req = [System.Net.WebRequest]::Create($url)
  $req.Timeout = 30000
  if ($req -is [System.Net.HttpWebRequest]) { $req.UserAgent = 'VRChatLinkMaker'; $req.ReadWriteTimeout = 30000; $req.AllowAutoRedirect = $true }
  $resp = $req.GetResponse()
  try {
    $total = [double]$resp.ContentLength
    $in = $resp.GetResponseStream()
    $out = [System.IO.File]::Create($dest)
    try {
      $buf = New-Object byte[] 262144
      $done = 0.0
      $last = [datetime]::MinValue
      while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
        $out.Write($buf, 0, $n)
        $done += $n
        if (((Get-Date) - $last).TotalMilliseconds -ge 400) {
          $last = Get-Date
          if ($total -gt 0 -and $progress) { Show-Status (T $progress ([int](100 * $done / $total))) }
        }
      }
    } finally { $out.Dispose(); $in.Dispose() }
  } finally { $resp.Close() }
  Clear-StatusLine
}

# Did the person say no to downloading $Name? A no holds for the flow it was given in (a Back re-run, or a second
# torrent on the same line, doesn't ask again) and for asks outside a flow (background preparation); a torrent
# submitted again (a new flow: '>' again, the second window, the waiting screen) asks again.
function Test-PinnedRefused([string]$Name) {
  $r = $script:PinnedRefused[$Name]
  if ($null -eq $r) { return $false }
  $root = Get-NavRoot
  if (-not $root) { return $true }
  return [object]::ReferenceEquals($r, $root)
}

# Path of a small helper program this tool downloads on demand (only 'rqbit' so far), or $null. It is downloaded only
# after asking ($CanAsk), and only the pinned release whose size and SHA-256 match.
function Get-PinnedTool([string]$Name, [bool]$CanAsk) {
  if ($Name -ne 'rqbit') { return $null }
  $dir = PathJoin (PathJoin $script:ToolDir 'bin') 'rqbit'
  $exe = PathJoin $dir 'rqbit.exe'
  if ([System.IO.File]::Exists($exe)) {
    if ($script:PinnedChecked[$Name] -eq $exe) { return $exe }
    $ok = $false
    try { $ok = ((New-Object System.IO.FileInfo($exe)).Length -eq $script:RqbitBytes -and (Get-FileSha256 $exe) -eq $script:RqbitSha256) } catch {}
    if ($ok) { $script:PinnedChecked[$Name] = $exe; return $exe }
    Say (T 'rqbit is missing or changed - your antivirus may have removed it.') 'Yellow'
  }
  $refused = ($CanAsk -and (Test-PinnedRefused $Name))
  if (-not $CanAsk -or $refused) {
    if (-not $CanAsk -and -not $script:PinnedNoted) {
      $script:PinnedNoted = $true
      Say (T 'Torrent links need rqbit - press + to set it up (a second window can ask).') 'Yellow'
    }
    if ($refused) { Say (T '  (You said no to rqbit: type the torrent link again to be asked again.)') 'DarkGray' }
    return $null
  }
  Say ''
  Say (T 'Torrents need rqbit, a free torrent program (12.7 MB, Apache-2.0, github.com/ikatson/rqbit). Nothing is installed.') 'Cyan'
  Say (T 'While an episode downloads it also uploads to other people, capped at {0} KB/s, and it stops uploading when the episode is complete. Only download what you are allowed to.' (Get-TorrentUploadKBps)) 'Gray'
  Say (T 'Windows may ask whether rqbit may use the network: Cancel is fine, it works either way.') 'Gray'
  # (Like MediaMTX's: a one-off question Esc = no; inside a flow Esc goes back as at any of its questions. Asked on the
  # waiting screen while live, no answer in time is a no too: Invoke-Ask's TimeoutEsc, never a yes nobody gave.)
  # (The question itself says that it uploads: the control window's strip shows only the question, not the lines above.)
  $tos = $script:AskTimeouts
  $yes = Read-YesNoUi (T 'Download rqbit {0} (12.7 MB) from github.com/ikatson/rqbit? While an episode downloads it also uploads to others (at most {1} KB/s). [Y/n]' $script:RqbitVersion (Get-TorrentUploadKBps)) $true -Key 'rqbit' -Esc $false
  # (Answered, it can't come again in this flow - rqbit is there, or the no holds - so a Back skips it.)
  Remove-NavTapeStep 'rqbit'
  if (-not $yes) {
    # (A "no" that came from nobody answering isn't held: the next torrent asks again, like the yt-dlp offer.)
    if ($script:AskTimeouts -ne $tos) { return $null }
    $root = Get-NavRoot
    if ($root) { $script:PinnedRefused[$Name] = $root } else { $script:PinnedRefused[$Name] = $true }
    return $null
  }
  $tmp = PathJoin $script:TempRoot 'rqbit-download.exe'
  try {
    if (-not [System.IO.Directory]::Exists($script:TempRoot)) { [void][System.IO.Directory]::CreateDirectory($script:TempRoot) }
    Save-WebFile $script:RqbitUrl $tmp 'Downloading rqbit... {0}%'
    $len = (New-Object System.IO.FileInfo($tmp)).Length
    if ($len -ne $script:RqbitBytes -or (Get-FileSha256 $tmp) -ne $script:RqbitSha256) {
      Say (T 'The download doesn''t match the expected checksum, so it was not used. Try again later.') 'Red'
      return $null
    }
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $new = $exe + '.new'
    if ([System.IO.File]::Exists($new)) { [System.IO.File]::Delete($new) }
    [System.IO.File]::Move($tmp, $new)
    if ([System.IO.File]::Exists($exe)) { [System.IO.File]::Delete($exe) }
    [System.IO.File]::Move($new, $exe)
    $script:PinnedChecked[$Name] = $exe
    Say (T 'rqbit {0} is ready.' $script:RqbitVersion) 'Green'
    return $exe
  } catch {
    Clear-StatusLine
    Say (T 'rqbit could not be downloaded: {0}' $_.Exception.Message) 'Red'
    return $null
  } finally { try { [System.IO.File]::Delete($tmp) } catch {} }
}

# One call to rqbit's web API (also run in background runspaces: it uses nothing else of this tool). The body can be
# text or bytes (a .torrent file). Never throws for HTTP error codes (check .Status).
function Invoke-RqbitHttp {
  param([int]$Port, [string]$Auth, [string]$Method, [string]$Path, $Body, [string]$ContentType, [int]$TimeoutSec)
  $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create("http://127.0.0.1:$Port$Path")
  $req.Method = $Method
  $req.Proxy = $null
  $req.KeepAlive = $false
  $req.Timeout = [Math]::Max(1, $TimeoutSec) * 1000
  $req.ReadWriteTimeout = $req.Timeout
  if ($Auth) { $req.Headers['Authorization'] = 'Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Auth)) }
  if ($Method -ne 'GET') {
    $bytes = New-Object byte[] 0
    if ($Body -is [byte[]]) { $bytes = $Body } elseif ($null -ne $Body) { $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Body) }
    if ($ContentType) { $req.ContentType = $ContentType }
    $req.ContentLength = $bytes.Length
    if ($bytes.Length -gt 0) {
      $rs = $req.GetRequestStream()
      try { $rs.Write($bytes, 0, $bytes.Length) } finally { $rs.Dispose() }
    }
  }
  $resp = $null
  try { $resp = $req.GetResponse() }
  catch [System.Net.WebException] { if ($_.Exception.Response) { $resp = $_.Exception.Response } else { throw } }
  try {
    $ms = New-Object System.IO.MemoryStream
    $st = $resp.GetResponseStream()
    try { $st.CopyTo($ms) } finally { $st.Dispose() }
    return [pscustomobject]@{ Status = [int]$resp.StatusCode; Text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray()) }
  } finally { $resp.Close() }
}

# GET -> the answer's bytes (a .torrent file from Nyaa): the browser user agent and the session's cookies, like Invoke-Web.
function Invoke-WebBytes {
  param([string]$Url, [string]$UA, $Cookies, [int]$TimeoutSec = 30)
  $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($Url)
  $req.UserAgent = $UA
  $req.Accept = '*/*'
  if ($Cookies) { $req.CookieContainer = $Cookies }
  $req.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
  $req.Timeout = $TimeoutSec * 1000
  $req.ReadWriteTimeout = $TimeoutSec * 1000
  $req.AllowAutoRedirect = $true
  $resp = $null
  try { $resp = $req.GetResponse() }
  catch [System.Net.WebException] { if ($_.Exception.Response) { $resp = $_.Exception.Response } else { throw } }
  try {
    $ms = New-Object System.IO.MemoryStream
    $st = $resp.GetResponseStream()
    try { $st.CopyTo($ms) } finally { $st.Dispose() }
    return [pscustomobject]@{ Status = [int]$resp.StatusCode; Bytes = $ms.ToArray() }
  } finally { $resp.Close() }
}

function Invoke-Rqbit([string]$Method, [string]$Path, $Body = $null, [string]$ContentType = '', [int]$TimeoutSec = 5) {
  $e = $script:Rqbit
  if (-not $e) { throw (T 'rqbit isn''t running') }
  return (Invoke-RqbitHttp -Port $e.Port -Auth $e.Auth -Method $Method -Path $Path -Body $Body -ContentType $ContentType -TimeoutSec $TimeoutSec)
}

# rqbit's error answer -> one short line.
function Get-RqbitError([string]$text) {
  $m = [regex]::Match([string]$text, '"(?:human_readable|error)"\s*:\s*"((?:[^"\\]|\\.)*)"')
  if ($m.Success) { return (Get-ShortText ($m.Groups[1].Value -replace '\\"', '"') 120) }
  return (Get-ShortText ([string]$text).Trim() 120)
}

# Starts rqbit (one per run of this tool) without waiting for it: Test-TorrentEngine says when its API answers.
function Start-TorrentEngine {
  if ($script:Rqbit) {
    $alive = $false
    try { $alive = -not $script:Rqbit.Proc.HasExited } catch {}
    if ($alive) { return $script:Rqbit }
    if ($script:Rqbit.Ready) { Remove-DeadTorrentEngine $script:Rqbit } else { Stop-TorrentEngine }
  }
  # (It ended by itself three times already: not again in this run.)
  if ($script:DeadRqbits.Count -ge 3) { throw (T 'rqbit stopped ({0})' (T 'three times')) }
  $exe = Get-PinnedTool 'rqbit' (Test-CanAsk)
  if (-not $exe) { throw (T 'torrents need rqbit, which isn''t set up') }
  $script:RqbitStarts++
  $dir = PathJoin $script:TempRoot "torrent-$PID"
  if ($script:DeadRqbits.Count -gt 0) { $dir += '-' + $script:RqbitStarts }
  try { if ([System.IO.Directory]::Exists($dir)) { [System.IO.Directory]::Delete($dir, $true) } } catch {}
  $dl = PathJoin $dir 'dl'
  [void][System.IO.Directory]::CreateDirectory($dl)
  # Held open while this copy of the tool runs, so another copy's clean-up (Clear-OldTemp) skips the folder.
  $lock = $null
  try { $lock = New-Object System.IO.FileStream((PathJoin $dir 'lock'), [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None) } catch {}
  $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
  $l.Start()
  $port = $l.LocalEndpoint.Port
  $l.Stop()
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $raw = New-Object byte[] 16
  $rng.GetBytes($raw)
  $secret = -join ($raw | ForEach-Object { $_.ToString('x2') })
  $argv = New-Object System.Collections.Generic.List[string]
  # (No listening port: outgoing connections only, nothing on the LAN or the router. Several copies of the tool can
  # each run one: no DHT state is kept.)
  foreach ($x in @('-v', 'warn', '-i', '300s', '--http-api-listen-addr', "127.0.0.1:$port", '--disable-tcp-listen', '--disable-upnp-port-forward',
      '--disable-lsd', '--disable-dht-persistence', '--ratelimit-upload', [string]((Get-TorrentUploadKBps) * 1024))) { $argv.Add($x) }
  $dk = Get-TorrentDownloadKBps
  if ($dk -gt 0) { $argv.Add('--ratelimit-download'); $argv.Add([string]($dk * 1024)) }
  foreach ($x in @('server', 'start', $dl, '--disable-persistence')) { $argv.Add($x) }
  $psi = New-StartInfo $exe $argv.ToArray() $dir
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.RedirectStandardInput = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  # (Only in rqbit's own environment: it has no command-line option for it, and this tool's other programs don't need it.)
  $psi.EnvironmentVariables['RQBIT_HTTP_BASIC_AUTH_USERPASS'] = "vrclm:$secret"
  $p = Start-Child $psi
  try { $p.StandardInput.Close() } catch {}
  $script:Rqbit = [pscustomobject]@{
    Proc = $p; Port = $port; Auth = "vrclm:$secret"; Dir = $dir; DlDir = $dl; Lock = $lock; Ready = $false; Started = (Get-Date)
    NextCheck = [datetime]::MinValue; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync(); Torrents = @{}
  }
  return $script:Rqbit
}

# $true once rqbit's API answers (and refuses a caller without the password), $false while it starts; throws when it
# can't be used.
function Test-TorrentEngine {
  $e = $script:Rqbit
  if (-not $e) { return $false }
  if ($e.Ready) {
    $dead = $false
    try { $dead = [bool]($e.Proc -and $e.Proc.HasExited) } catch {}
    if (-not $dead) { return $true }
    Remove-DeadTorrentEngine $e
    return $false
  }
  $dead = $true
  try { $dead = $e.Proc.HasExited } catch {}
  if ($dead) {
    $why = ''
    try { if ($e.Err.Wait(1000)) { $why = Get-LastLines ("$($e.Out.Result)`n$($e.Err.Result)") 1 } } catch {}
    $early = ((Get-Date) - $e.Started).TotalSeconds -lt 3
    Stop-TorrentEngine
    # (Another program took the port in the meantime: once more on another one.)
    if ($early -and $script:RqbitStarts -lt 3) { return $false }
    if (-not $why) { $why = '?' }
    throw (T 'rqbit stopped ({0})' (Get-ShortText $why 100))
  }
  if (((Get-Date) - $e.Started).TotalSeconds -gt 20) { Stop-TorrentEngine; throw (T 'rqbit didn''t start') }
  if ((Get-Date) -lt $e.NextCheck) { return $false }
  $e.NextCheck = (Get-Date).AddMilliseconds(200)
  # (Only once its port listens: a connection to a port nobody listens on can take a second to fail on Windows.)
  $up = $false
  try { $up = @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -eq $e.Port }).Count -gt 0 } catch { $up = $true }
  if (-not $up) { return $false }
  $r = $null
  try { $r = Invoke-Rqbit 'GET' '/' $null '' 1 } catch { return $false }
  if ($r.Status -ne 200 -or $r.Text -notmatch '"server"\s*:\s*"rqbit"') { return $false }
  $r2 = $null
  try { $r2 = Invoke-RqbitHttp -Port $e.Port -Auth '' -Method 'GET' -Path '/' -Body $null -ContentType '' -TimeoutSec 2 } catch {}
  if (-not $r2 -or $r2.Status -ne 401) { Stop-TorrentEngine; throw (T 'rqbit started without a password - not used') }
  $e.Ready = $true
  return $true
}

# The engine when it is ready, $null while it starts (started here when needed); throws when it can't be used.
function Get-TorrentEngine {
  if (-not $script:Rqbit) { [void](Start-TorrentEngine) }
  if (Test-TorrentEngine) { return $script:Rqbit }
  return $null
}

# rqbit ended by itself after it was ready (a crash, an antivirus): what it was downloading is lost (those episodes
# fail), the episodes it finished still play (its folder stays, locked, until this tool ends: Remove-DeadTorrentEngines),
# and the next torrent starts it again (in a folder of its own).
$script:DeadRqbits = New-Object System.Collections.ArrayList
function Remove-DeadTorrentEngine($e) {
  if ($script:Rqbit -eq $e) { $script:Rqbit = $null }
  if ($script:DeadRqbits.Contains($e)) { return }
  [void]$script:DeadRqbits.Add($e)
  $why = ''
  try { if ($e.Err.Wait(500)) { $why = Get-LastLines ("$($e.Out.Result)`n$($e.Err.Result)") 1 } } catch {}
  if (-not $why) { $why = '?' }
  $msg = T 'rqbit stopped ({0})' (Get-ShortText $why 100)
  foreach ($g in @($e.Torrents.Values)) { if (-not $g.Error) { $g.Error = $msg } }
  Say $msg 'Yellow'
}

function Remove-DeadTorrentEngines {
  foreach ($e in @($script:DeadRqbits)) {
    if ($e.Lock) { try { $e.Lock.Dispose() } catch {} }
    try { [System.IO.Directory]::Delete($e.Dir, $true) } catch {}
    if ([System.IO.Directory]::Exists($e.Dir)) { [void]$script:PendingDirs.Add($e.Dir) }
  }
  $script:DeadRqbits.Clear()
}

# Stops rqbit and deletes everything it downloaded (when this tool ends).
function Stop-TorrentEngine {
  $e = $script:Rqbit
  if (-not $e) { return }
  $script:Rqbit = $null
  if ($e.Ready) {
    foreach ($id in @($e.Torrents.Keys)) { try { [void](Invoke-RqbitHttp -Port $e.Port -Auth $e.Auth -Method 'POST' -Path "/torrents/$id/delete" -Body $null -ContentType '' -TimeoutSec 1) } catch {} }
  }
  try { if (-not $e.Proc.HasExited) { $e.Proc.Kill() } } catch {}
  try { [void]$e.Proc.WaitForExit(3000) } catch {}
  if ($e.Lock) { try { $e.Lock.Dispose() } catch {} }
  try { [System.IO.Directory]::Delete($e.Dir, $true) } catch {}
  if ([System.IO.Directory]::Exists($e.Dir)) { [void]$script:PendingDirs.Add($e.Dir) }
}

# One torrent (shared by the queue items of its episodes): what to send rqbit (Body: magnet text or .torrent bytes;
# BodyUrl: a .torrent still to fetch), its files once known, its id in rqbit once added, the files it downloads now.
function New-TorrentGroup([string]$link, [string]$kind) {
  $g = [pscustomobject]@{
    Link = $link; Kind = $kind; Body = $null; BodyUrl = $null; Hash = $null; Name = ''; Files = $null; Id = $null; OutDir = $null; Engine = $null
    Want = (New-Object System.Collections.Generic.List[int]); Job = $null; Error = $null; Refs = 0; Paused = $false; RetryAt = [datetime]::MinValue
  }
  if ($kind -eq 'magnet') { $g.Body = $link; $g.Hash = Get-TorrentHash $link; $g.Name = Get-MagnetName $link }
  elseif ($kind -eq 'hash') { $g.Hash = Get-TorrentHash $link; $g.Body = "magnet:?xt=urn:btih:$($g.Hash)" }
  elseif ($kind -eq 'file') {
    $full = [System.IO.Path]::GetFullPath($link)
    $g.Link = $full
    $g.Body = [System.IO.File]::ReadAllBytes($full)
    $g.Name = [System.IO.Path]::GetFileNameWithoutExtension($full)
  } else {
    $g.BodyUrl = Get-TorrentFileUrl $link
    # (Named after the file until its own name is known: "BigBuckBunny_124_archive", or "torrent 2115493" for a Nyaa id.)
    $n = [System.IO.Path]::GetFileNameWithoutExtension((($g.BodyUrl -split '[?#]', 2)[0]).TrimEnd('/'))
    if ($n -match '^\d+$') { $n = T 'torrent {0}' $n }
    $g.Name = $n
  }
  return $g
}

function New-TorrentItem($g, [string]$number) {
  $it = New-QueueItem 'torrent' $g.Link
  $it.Torrent = [pscustomobject]@{ G = $g; Number = $number; Idx = -1; Bytes = [long]0; Rel = $null; Subs = @(); Released = $false }
  $name = $g.Name
  if (-not $name -and $g.Hash) { $name = T 'torrent {0}' $g.Hash.Substring(0, 8) }
  if (-not $name) { $name = Get-ShortText $g.Link 70 }
  if ($number) { $name += ' - ' + $number }
  $it.Name = $name
  $g.Refs++
  return $it
}

# An episode number from a file name ("S01E05", "Show - 05 (720p)", "E05"), as text ("5", "12.5"), or $null.
function Get-FileEpisodeNumber([string]$name) {
  $b = [System.IO.Path]::GetFileNameWithoutExtension($name)
  foreach ($rx in @('(?i)\bS\d+\s*E(\d+)', ' - (\d+(?:\.\d+)?)(?:v\d+)?(?: |$|[\[(])', '(?i)\b(?:E|EP|Episode)\s?(\d+)\b')) {
    $m = [regex]::Match($b, $rx)
    if ($m.Success) { return (Format-Num ([double]::Parse($m.Groups[1].Value, $script:Inv))) }
  }
  return $null
}

# A torrent's video files, in natural order, each with .Idx (rqbit's file id), .Name, .Rel, .Length, .Number (from the
# file names; the ones without a number after them; by position when numbers repeat) and .Subs (its subtitle files:
# named like it, anywhere in the torrent; a torrent with one video: all of them). Audio-only files (an external dub
# track, a soundtrack) are no episodes.
$script:AudioOnlyExts = @('.mka', '.mp3', '.flac', '.m4a', '.aac', '.ogg', '.opus', '.wav', '.wma')
function Get-TorrentEpisodes($files) {
  $list = New-Object System.Collections.ArrayList
  $subs = New-Object System.Collections.ArrayList
  $i = 0
  foreach ($f in @($files)) {
    $comp = @(Get-JsonVal $f 'components' | ForEach-Object { [string]$_ })
    if ($comp.Count -eq 0) { $comp = @([string](Get-JsonVal $f 'name')) }
    $n = $comp[$comp.Count - 1]
    $x = [System.IO.Path]::GetExtension($n).ToLowerInvariant()
    $o = [pscustomobject]@{ Idx = $i; Name = $n; Rel = ($comp -join '\'); Length = [long](Get-JsonVal $f 'length'); Number = $null; Subs = @() }
    if ($script:MediaExts -contains $x -and $script:AudioOnlyExts -notcontains $x) { [void]$list.Add($o) }
    elseif ($script:SubExts -contains $x) { [void]$subs.Add($o) }
    $i++
  }
  $sorted = @($list | Sort-Object { Get-NaturalKey $_.Rel })
  $seen = @{}
  $byName = $true
  $max = 0.0
  foreach ($ep in $sorted) {
    $n = Get-FileEpisodeNumber $ep.Name
    if (-not $n) { continue }
    if ($seen.ContainsKey($n)) { $byName = $false; break }
    $seen[$n] = $true
    $ep.Number = $n
    $max = [Math]::Max($max, [Math]::Floor([double]::Parse($n, $script:Inv)))
  }
  if ($byName) {
    $num = @($sorted | Where-Object { $_.Number })
    $none = @($sorted | Where-Object { -not $_.Number })
    for ($k = 0; $k -lt $none.Count; $k++) { $none[$k].Number = [string]([int]$max + $k + 1) }
    $sorted = @($num) + @($none)
  } else { for ($k = 0; $k -lt $sorted.Count; $k++) { $sorted[$k].Number = [string]($k + 1) } }
  foreach ($ep in $sorted) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($ep.Name) + '.'
    $ep.Subs = @($subs | Where-Object { $_.Name.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase) })
  }
  if ($sorted.Count -eq 1 -and $sorted[0].Subs.Count -eq 0) { $sorted[0].Subs = @($subs | Select-Object -First 20) }
  return $sorted
}

# rqbit's ids of an episode's files: the video and its subtitle files.
function Get-TorrentItemFiles($it) { return @(@($it.Torrent.Idx) + @($it.Torrent.Subs | ForEach-Object { $_.Idx })) }

function Set-TorrentItemFile($it, $ep) {
  $it.Torrent.Idx = $ep.Idx
  $it.Torrent.Bytes = $ep.Length
  $it.Torrent.Rel = $ep.Rel
  $it.Torrent.Subs = @($ep.Subs)
  $it.Torrent.Number = $ep.Number
  $it.Name = [System.IO.Path]::GetFileNameWithoutExtension($ep.Name)
}

# Sends one request to rqbit in a runspace of its own (adding a magnet waits until the people sharing it sent its file
# list). $g.BodyUrl: the .torrent file is fetched first. Poll $g.Job.H.IsCompleted, then Complete-TorrentJob.
function Start-TorrentJob($g, [string]$path, [int]$sec, $want = $null) {
  $e = $script:Rqbit
  $defs = @(foreach ($n in @('Invoke-RqbitHttp', 'Invoke-WebBytes')) { "function $n {`n" + (Get-Item "function:$n").ScriptBlock.ToString() + "`n}" }) -join "`n"
  $ps = [powershell]::Create()
  [void]$ps.AddScript({
      param($defs, $port, $auth, $path, $body, $bodyUrl, $ua, $cookies, $sec)
      . ([scriptblock]::Create($defs))
      $fetched = $null
      try {
        if ($bodyUrl) {
          $w = Invoke-WebBytes -Url $bodyUrl -UA $ua -Cookies $cookies -TimeoutSec 30
          # (A .torrent file is a bencoded dictionary: it starts with "d".)
          if ($w.Status -ne 200 -or $w.Bytes.Length -lt 20 -or $w.Bytes[0] -ne 100) { return [pscustomobject]@{ Status = 0; Text = ''; Error = $null; Fetch = $w.Status; Body = $null } }
          $fetched = $w.Bytes
          $body = $fetched
        }
        $r = Invoke-RqbitHttp -Port $port -Auth $auth -Method 'POST' -Path $path -Body $body -ContentType '' -TimeoutSec $sec
        return [pscustomobject]@{ Status = $r.Status; Text = $r.Text; Error = $null; Fetch = 0; Body = $fetched }
      } catch {
        $x = $_.Exception
        if ($x.InnerException) { $x = $x.InnerException }
        return [pscustomobject]@{ Status = 0; Text = ''; Error = $x.Message; Fetch = 0; Body = $fetched }
      }
    }).AddArgument($defs).AddArgument($e.Port).AddArgument($e.Auth).AddArgument($path).AddArgument($g.Body).AddArgument($g.BodyUrl).AddArgument($script:WebUA).AddArgument($script:WebCookies).AddArgument($sec)
  $g.Job = [pscustomobject]@{ Ps = $ps; H = $ps.BeginInvoke(); Started = (Get-Date); Sec = $sec; Want = @($want) }
}

function Stop-TorrentJob($g) {
  if (-not $g.Job) { return }
  try { [void]$g.Job.Ps.BeginStop($null, $null) } catch {}
  $g.Job = $null
}

# Reads what rqbit answered: the file list, and the torrent's id when it was added (not just listed).
function Complete-TorrentJob($g) {
  $j = $g.Job
  $g.Job = $null
  $r = $null
  try { $res = @($j.Ps.EndInvoke($j.H)); if ($res.Count -gt 0) { $r = $res[0] } } catch {}
  try { $j.Ps.Dispose() } catch {}
  if (-not $r) { $g.Error = T 'rqbit didn''t answer'; return }
  if ($r.Body) { $g.Body = [byte[]]$r.Body; $g.BodyUrl = $null }
  if ($r.Fetch) { $g.Error = T 'the .torrent file didn''t download (HTTP {0})' $r.Fetch; return }
  if ($r.Error) {
    if ($r.Error -match '(?i)time') { $g.Error = T 'no one is sharing this torrent right now (no file list after {0} s)' $j.Sec }
    else { $g.Error = T 'rqbit: {0}' (Get-ShortText $r.Error 120) }
    return
  }
  if ($r.Status -ne 200) {
    $why = Get-RqbitError $r.Text
    if ($why -match '(?i)timed? ?out|timeout') { $g.Error = T 'no one is sharing this torrent right now (no file list after {0} s)' $j.Sec }
    else { $g.Error = T 'rqbit refused it: {0}' $why }
    return
  }
  $a = ConvertFrom-JsonDict $r.Text
  $d = Get-JsonVal $a 'details'
  $files = Get-JsonVal $d 'files'
  if ($null -eq $files) { $g.Error = T 'rqbit: {0}' (T 'unexpected answer'); return }
  $g.Files = @($files)
  $h = [string](Get-JsonVal $d 'info_hash')
  if ($h -match '^[0-9a-fA-F]{40}$') { $g.Hash = $h.ToLowerInvariant() }
  if (-not $g.Name) { $g.Name = [string](Get-JsonVal $d 'name') }
  $id = Get-JsonVal $a 'id'
  if ($null -ne $id) {
    $old = $null
    if ($script:Rqbit) { $old = $script:Rqbit.Torrents[[string]$id] }
    if ($old -and $old -ne $g) {
      # The same torrent queued again (another link to it, a later hand-over): rqbit has it once, so its episodes
      # become episodes of the group that has it (one list of files to download, deleted after the last one).
      foreach ($q in @($script:Queue)) { if ($q.Kind -eq 'torrent' -and $q.Torrent -and $q.Torrent.G -eq $g) { $q.Torrent.G = $old } }
      $old.Refs += [Math]::Max(0, $g.Refs)
      $g.Refs = 0
      return
    }
    $g.Id = [string]$id
    $g.Engine = $script:Rqbit
    $g.OutDir = [string](Get-JsonVal $d 'output_folder')
    if (-not $g.OutDir) { $g.OutDir = [string](Get-JsonVal $a 'output_folder') }
    if ($script:Rqbit) { $script:Rqbit.Torrents[$g.Id] = $g }
    $g.Want.Clear()
    foreach ($x in @($j.Want)) { if ($null -ne $x) { $g.Want.Add([int]$x) } }
    $g.Paused = $false
  }
}

# The file list right now (this window may ask, so it may wait): up to a minute for a magnet / hash.
function Get-TorrentFileList($g) {
  $t0 = Get-Date
  while (-not (Get-TorrentEngine)) {
    if (((Get-Date) - $t0).TotalSeconds -gt 25) { throw (T 'rqbit didn''t start') }
    Wait-Pump 0.2
  }
  $magnet = ($g.Body -is [string])
  $q = '/torrents?list_only=true&overwrite=true'
  if ($magnet) { $q += '&timeout_ms=60000' }
  Start-TorrentJob $g $q 65
  $said = $false
  while (-not $g.Job.H.IsCompleted) {
    $el = ((Get-Date) - $g.Job.Started).TotalSeconds
    if (-not $said -and $el -gt 1) {
      $said = $true
      if ($magnet) { Say (T 'Getting the file list from the people sharing it (up to a minute)...') 'Gray' }
    }
    if ($el -gt 75) { Stop-TorrentJob $g; throw (T 'no one is sharing this torrent right now (no file list after {0} s)' 60) }
    Wait-Pump 0.2
  }
  Complete-TorrentJob $g
  if ($g.Error) { $e = $g.Error; $g.Error = $null; throw $e }
}

# A torrent link -> queue items, one per episode (video file) chosen. A window that may ask gets the file list now
# and asks which episodes; otherwise the items are placeholders that find their files when it is their turn (the
# episodes handed over by a second window: #vrclm=eps=1,2; else every episode, at most 25).
function Expand-Torrent([string]$link) {
  $eps = $null
  $i = $link.IndexOf('#vrclm=')
  if ($i -ge 0) {
    $m = [regex]::Match($link.Substring($i), '[=&]eps=([^&]*)')
    if ($m.Success) { $eps = @(([Uri]::UnescapeDataString($m.Groups[1].Value)) -split ',' | Where-Object { $_ }) }
    $link = $link.Substring(0, $i)
  }
  if (-not $eps -and $script:SiteChoice -and $script:SiteChoice.Eps) { $eps = @($script:SiteChoice.Eps) }
  $link = $link.Trim().Trim('"').Trim()
  $kind = Test-TorrentLink $link
  if (-not $kind) { return @() }
  if ((Get-TorrentsSetting) -eq 'off') { Say (T '  Torrents are off ("Torrents": "off" in config.json): {0}' (Get-ShortText $link 70)) 'Yellow'; return @() }
  $g = New-TorrentGroup $link $kind
  if ($kind -eq 'hash') { Say (T '  A bare hash finds the people sharing it only through DHT: a magnet link or a .torrent file is faster.') 'DarkGray' }
  $items = New-Object System.Collections.ArrayList
  if (Test-CanAsk) {
    # (Inside a flow a Back re-runs this: the file list it got is used again, without another wait for the people
    # sharing it. Only the list is kept: nothing was added to rqbit yet.)
    $got = @(Use-NavMemo ('torrent|' + $link) {
        $null = Get-TorrentFileList $g
        [pscustomobject]@{ Files = @($g.Files); Hash = $g.Hash; Name = $g.Name; Body = $g.Body; BodyUrl = $g.BodyUrl }
      })
    if ($got.Count -gt 0 -and $got[0]) {
      $g.Files = @($got[0].Files); $g.Hash = $got[0].Hash; $g.Name = $got[0].Name; $g.Body = $got[0].Body; $g.BodyUrl = $got[0].BodyUrl
    }
    $list = @(Get-TorrentEpisodes $g.Files)
    if ($list.Count -eq 0) { throw (T 'there is no video in this torrent') }
    if ($g.Name) { Say (T 'Torrent: {0} ({1} videos)' $g.Name $list.Count) 'White' }
    $pick = @($list)
    if (Get-Command Select-SiteEpisodes -CommandType Function -ErrorAction SilentlyContinue) {
      $saved = $script:SiteChoice
      if ($eps) { $script:SiteChoice = [pscustomobject]@{ Dub = $null; Eps = $eps; Start = 0.0; Part = $null; Player = $null } }
      try { $pick = @(Select-SiteEpisodes $list 0 $true) } finally { $script:SiteChoice = $saved }
    }
    foreach ($ep in $pick) { $it = New-TorrentItem $g $null; Set-TorrentItemFile $it $ep; [void]$items.Add($it) }
  } elseif ($eps) {
    foreach ($n in $eps) { [void]$items.Add((New-TorrentItem $g ([string]$n))) }
  } else {
    [void]$items.Add((New-TorrentItem $g $null))
  }
  return $items.ToArray()
}

# What a second window hands over for torrent items: the link (a bare hash as a magnet link, a file with its full path)
# with the chosen episodes. Never anything secret: rqbit's password stays in each window.
function Get-TorrentHandover($items, [string]$link) {
  $i = $link.IndexOf('#vrclm=')
  if ($i -ge 0) { $link = $link.Substring(0, $i) }
  $link = $link.Trim().Trim('"').Trim()
  $kind = Test-TorrentLink $link
  if ($kind -eq 'hash') { $link = 'magnet:?xt=urn:btih:' + (Get-TorrentHash $link) }
  elseif ($kind -eq 'file') { $link = [System.IO.Path]::GetFullPath($link) }
  $nums = @($items | Where-Object { $_ -and $_.Torrent -and $_.Torrent.Number } | ForEach-Object { [string]$_.Torrent.Number })
  if ($nums.Count -gt 0) { $link += '#vrclm=eps=' + [Uri]::EscapeDataString(($nums -join ',')) }
  return $link
}

# A placeholder item finds its file now that the file list is known (more episodes become items of their own, right
# after it in the queue).
function Resolve-TorrentItem($item) {
  $t = $item.Torrent
  $g = $t.G
  $list = @(Get-TorrentEpisodes $g.Files)
  if ($list.Count -eq 0) { throw (T 'there is no video in this torrent') }
  if ($t.Number) {
    $ep = @($list | Where-Object { [string]$_.Number -eq [string]$t.Number }) | Select-Object -First 1
    if (-not $ep) { throw (T 'episode {0} isn''t in this torrent' $t.Number) }
    Set-TorrentItemFile $item $ep
    return
  }
  $max = 25
  if ($script:MaxUnasked) { $max = [int]$script:MaxUnasked }
  $pick = @($list)
  if ($pick.Count -gt $max) {
    Say (T '  (queued the next {0} of {1} episodes - drop the link on the .bat to choose others)' $max $pick.Count) 'Gray'
    $pick = @($pick[0..($max - 1)])
  }
  Set-TorrentItemFile $item $pick[0]
  if ($pick.Count -gt 1) {
    $pos = $script:Queue.IndexOf($item)
    for ($k = 1; $k -lt $pick.Count; $k++) {
      $it = New-TorrentItem $g $null
      Set-TorrentItemFile $it $pick[$k]
      if ($pos -ge 0) { $script:Queue.Insert($pos + $k, $it) }
    }
    if ($pos -ge 0) { Say (T '  + {0} more episodes of this torrent queued after it.' ($pick.Count - 1)) 'Green' }
  }
}

function Assert-TorrentSpace([long]$bytes) {
  $free = [long]-1
  try { $free = (New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($script:TempRoot))).AvailableFreeSpace } catch {}
  $need = [long]($bytes * 1.1) + 2GB
  if ($free -ge 0 -and $free -lt $need) { throw (T 'not enough disk space (needs {0} GB)' ([Math]::Ceiling($need / 1GB))) }
}

# Step-Prep for a torrent item: engine -> file list -> added (only this episode's file) -> downloading -> 'probe'
# (from there on it is a file on this PC). Never waits: every step that can take long runs in the background.
function Step-TorrentPrep($item) {
  $t = $item.Torrent
  $g = $t.G
  if ((Get-TorrentsSetting) -eq 'off') { throw (T 'torrents are off ("Torrents": "off" in config.json)') }
  if ($g.Error) { throw $g.Error }
  if ($item.State -eq 'downloading') { Update-TorrentDownload $item; return }
  $item.State = 'torrent-meta'
  if (-not (Get-TorrentEngine)) { return }
  if ($g.Job) {
    if (-not $g.Job.H.IsCompleted) {
      if (((Get-Date) - $g.Job.Started).TotalSeconds -lt $g.Job.Sec + 10) { return }
      $sec = $g.Job.Sec
      Stop-TorrentJob $g
      $g.Error = T 'no one is sharing this torrent right now (no file list after {0} s)' $sec
    } else { Complete-TorrentJob $g }
    if ($g.Error) { throw $g.Error }
    $g = $t.G   # (another group if this torrent was queued already)
  }
  $magnet = ($g.Body -is [string])
  if (-not $g.Files) {
    if ($magnet) {
      # (Added at once with just its first file: one wait for the people sharing it, then the right files.)
      Start-TorrentJob $g ('/torrents?overwrite=true&only_files=0&sub_folder=' + $g.Hash + '&timeout_ms=90000') 90 @(0)
    } else { Start-TorrentJob $g '/torrents?list_only=true&overwrite=true' 40 }
    return
  }
  if ($t.Idx -lt 0) { Resolve-TorrentItem $item }
  if (-not $g.Id) {
    Assert-TorrentSpace $t.Bytes
    $mine = @(Get-TorrentItemFiles $item)
    $q = '/torrents?overwrite=true&only_files=' + ($mine -join ',') + '&sub_folder=' + $g.Hash
    if ($magnet) { $q += '&timeout_ms=90000' }
    Start-TorrentJob $g $q 90 $mine
    return
  }
  # (Just added, rqbit still checks what is on disk: it takes no changes until then.)
  if ((Get-Date) -lt $g.RetryAt) { return }
  # Only the files being downloaded now (rqbit takes them in order); finished ones stay on disk until played.
  $want = @(Get-TorrentItemFiles $item) + @($script:Queue | Where-Object { $_ -ne $item -and $_.Kind -eq 'torrent' -and $_.Torrent -and $_.Torrent.G -eq $g -and $_.State -eq 'downloading' } | ForEach-Object { Get-TorrentItemFiles $_ })
  $want = @($want | Sort-Object -Unique)
  if (($want -join ',') -ne (@($g.Want | Sort-Object -Unique) -join ',')) {
    if (-not $g.Want.Contains($t.Idx)) { Assert-TorrentSpace $t.Bytes }
    $r = Invoke-Rqbit 'POST' "/torrents/$($g.Id)/update_only_files" ('{"only_files":[' + ($want -join ',') + ']}') 'application/json' 5
    if ($r.Status -ne 200 -and (Get-RqbitError $r.Text) -match '(?i)initiali') { $g.RetryAt = (Get-Date).AddSeconds(1); return }
    if ($r.Status -ne 200) { throw (T 'rqbit refused it: {0}' (Get-RqbitError $r.Text)) }
    $g.Want.Clear()
    foreach ($x in $want) { $g.Want.Add([int]$x) }
  }
  if ($g.Paused) {
    $r = Invoke-Rqbit 'POST' "/torrents/$($g.Id)/start" $null '' 5
    if ($r.Status -ne 200 -and (Get-RqbitError $r.Text) -match '(?i)initiali') { $g.RetryAt = (Get-Date).AddSeconds(1); return }
    if ($r.Status -ne 200) { throw (T 'rqbit refused it: {0}' (Get-RqbitError $r.Text)) }
    $g.Paused = $false
  }
  $now = Get-Date
  $item.Dl = [pscustomobject]@{ Started = $now; NextPoll = $now; LastPoll = $now; LastBytes = [long]-1; MovedAt = $now; Done = [long]0; Speed = 0.0; Peers = 0; Eta = -1.0; WokeAt = $null; Kicked = $false; Fails = 0; VidDoneAt = $null; Fp = @() }
  $item.DlKind = 'torrent'
  $item.State = 'downloading'
  Update-TorrentDownload $item
}

# Looks at a downloading episode every 2 s (rqbit's stats; a loopback call of a few ms).
function Update-TorrentDownload($item) {
  $dl = $item.Dl
  $t = $item.Torrent
  $g = $t.G
  $now = Get-Date
  if ($now -lt $dl.NextPoll) { return }
  # (A long gap = this PC was asleep: its connections are gone. Not the torrent's fault.)
  if (($now - $dl.LastPoll).TotalSeconds -gt 30) { $dl.WokeAt = $now; $dl.MovedAt = $now; $dl.Kicked = $false }
  $dl.LastPoll = $now
  $dl.NextPoll = $now.AddSeconds(2)
  # rqbit ended (a crash, an antivirus): this download is lost (no call to a port nobody listens on: ~2 s each).
  if ($g.Engine -and $g.Engine -eq $script:Rqbit) { [void](Test-TorrentEngine) }
  if ($g.Error) { throw $g.Error }
  if (-not $script:Rqbit -or ($g.Engine -and $g.Engine -ne $script:Rqbit)) { throw (T 'rqbit isn''t running') }
  # (A few failed looks in a row: rqbit doesn't answer, or no longer has this torrent.)
  $r = $null; $why = $null
  try { $r = Invoke-Rqbit 'GET' "/torrents/$($g.Id)/stats/v1" $null '' 3 } catch { $why = T 'rqbit didn''t answer' }
  if (-not $why -and $r.Status -ne 200) { $why = T 'rqbit: {0}' (Get-RqbitError $r.Text) }
  $j = $null
  if (-not $why) { try { $j = ConvertFrom-JsonDict $r.Text } catch { $why = T 'rqbit: {0}' (T 'unexpected answer') } }
  if ($why) {
    $dl.Fails++
    if ($dl.Fails -ge 3) { throw $why }
    return
  }
  $dl.Fails = 0
  if ([string](Get-JsonVal $j 'state') -eq 'error') { throw (T 'rqbit: {0}' (Get-ShortText ([string](Get-JsonVal $j 'error')) 120)) }
  $fp = @(Get-JsonVal $j 'file_progress')
  $dl.Fp = $fp
  $done = [long]0
  if ($t.Idx -lt $fp.Count) { $done = [long]$fp[$t.Idx] }
  $speed = 0.0; $peers = 0; $eta = -1.0
  $live = Get-JsonVal $j 'live'
  if ($live) {
    $ds = Get-JsonVal $live 'download_speed'
    if ($ds) { $speed = [double](Get-JsonVal $ds 'mbps') * 1MB }   # (mbps = MiB per second)
    $pst = Get-JsonVal (Get-JsonVal $live 'snapshot') 'peer_stats'
    if ($pst) { $peers = [int](Get-JsonVal $pst 'live') }
    $tr = Get-JsonVal $live 'time_remaining'
    if ($tr) { $du = Get-JsonVal $tr 'duration'; if ($du) { $eta = [double](Get-JsonVal $du 'secs') } }
  }
  if ($eta -lt 0 -and $speed -gt 0) { $eta = ($t.Bytes - $done) / $speed }
  $dl.Done = $done; $dl.Speed = $speed; $dl.Peers = $peers; $dl.Eta = $eta
  if ($done -ne $dl.LastBytes) { $dl.LastBytes = $done; $dl.MovedAt = $now }
  if ($t.Bytes -gt 0 -and $done -ge $t.Bytes) {
    # The video is complete; its subtitle files (small) are waited for up to a minute more.
    $subsLeft = @($t.Subs | Where-Object { $_.Idx -ge $fp.Count -or [long]$fp[$_.Idx] -lt $_.Length }).Count
    if (-not $dl.VidDoneAt) { $dl.VidDoneAt = $now }
    if ($subsLeft -eq 0 -or ($now - $dl.VidDoneAt).TotalSeconds -ge 60) { Complete-TorrentDownload $item }
    return
  }
  # Nothing came for a minute after the PC woke up: pause + start makes rqbit reconnect and ask the trackers again.
  if ($dl.WokeAt -and -not $dl.Kicked -and ($now - $dl.WokeAt).TotalSeconds -ge 60 -and $dl.MovedAt -le $dl.WokeAt) {
    $dl.Kicked = $true
    try { [void](Invoke-Rqbit 'POST' "/torrents/$($g.Id)/pause" $null '' 3); [void](Invoke-Rqbit 'POST' "/torrents/$($g.Id)/start" $null '' 3) } catch {}
  }
  # No progress: 5 minutes with nobody to download from, 15 with people who don't have the missing parts (S S on the
  # waiting screen gives it up sooner).
  $idle = ($now - $dl.MovedAt).TotalSeconds
  if ($idle -ge 300 -and $peers -eq 0) { throw (T 'stalled: nobody shared it for {0} minutes' 5) }
  if ($idle -ge 900) { throw (T 'stalled: the people sharing it had nothing new for {0} minutes' 15) }
}

function Complete-TorrentDownload($item) {
  $t = $item.Torrent
  $g = $t.G
  $p = $null
  if ($g.OutDir) { $p = PathJoin $g.OutDir $t.Rel }
  if (-not $p -or -not [System.IO.File]::Exists($p)) {
    # (Where rqbit put it after all: the file's name and size.)
    $p = $null
    $leaf = [System.IO.Path]::GetFileName($t.Rel)
    try {
      $root = $script:Rqbit.DlDir
      if ($g.Engine) { $root = $g.Engine.DlDir }
      foreach ($f in [System.IO.Directory]::GetFiles($root, $leaf, [System.IO.SearchOption]::AllDirectories)) {
        if ((New-Object System.IO.FileInfo($f)).Length -eq $t.Bytes) { $p = $f; break }
      }
    } catch {}
  }
  if (-not $p) { throw (T 'the downloaded file isn''t there') }
  $item.Path = $p
  # Its subtitle files that came complete.
  $fp = @()
  if ($item.Dl) { $fp = @($item.Dl.Fp) }
  foreach ($s in @($t.Subs)) {
    if (-not $g.OutDir -or $s.Idx -ge $fp.Count -or [long]$fp[$s.Idx] -lt $s.Length) { continue }
    $sp = $null
    try { $sp = [System.IO.Path]::GetFullPath((PathJoin $g.OutDir $s.Rel)) } catch {}
    if ($sp -and [System.IO.File]::Exists($sp)) { $item.ExtraSubs = @($item.ExtraSubs) + @(New-ExternalSubTrack $sp) }
  }
  # Complete: no more uploading (unless "Torrents": "seed", or another episode of it still downloads).
  $busy = @($script:Queue | Where-Object { $_ -ne $item -and $_.Kind -eq 'torrent' -and $_.Torrent -and $_.Torrent.G -eq $g -and $_.State -eq 'downloading' }).Count -gt 0
  if ((Get-TorrentsSetting) -ne 'seed' -and -not $busy -and -not $g.Paused) {
    try { $r = Invoke-Rqbit 'POST' "/torrents/$($g.Id)/pause" $null '' 5; if ($r.Status -eq 200) { $g.Paused = $true } } catch {}
  }
  $item.State = 'probe'
}

# An episode of a torrent whose other episodes are still queued (a batch): its own file goes now; the rest of the
# torrent goes after the last one (Remove-TorrentRef). Not while seeding ("Torrents": "seed").
function Remove-TorrentEpisodeFile($item) {
  $t = $item.Torrent
  $g = $t.G
  if ($g.Refs -le 1 -or -not $item.Path -or -not $g.OutDir -or (Get-TorrentsSetting) -eq 'seed') { return }
  if (-not ([string]$item.Path).StartsWith($g.OutDir, [System.StringComparison]::OrdinalIgnoreCase)) { return }
  if (@($script:Queue | Where-Object { $_ -ne $item -and $_.Kind -eq 'torrent' -and $_.Torrent -and $_.Torrent.G -eq $g -and -not $_.Torrent.Released -and $_.Torrent.Idx -eq $t.Idx }).Count -gt 0) { return }
  try { [System.IO.File]::Delete($item.Path) } catch {}
}

$script:TorrentDropped = New-Object System.Collections.ArrayList
# An episode played (or was skipped / dropped): when none of its torrent's episodes is left, rqbit deletes the files.
function Remove-TorrentRef($g) {
  $g.Refs--
  if ($g.Refs -gt 0) { return }
  # An add still waiting for rqbit's answer can't be called back: once rqbit answers, that torrent is deleted
  # (Clear-DroppedTorrents), so it neither downloads nor uploads for nobody.
  if ($g.Job -and -not $script:TorrentDropped.Contains($g)) { [void]$script:TorrentDropped.Add($g) }
  $e = $script:Rqbit
  if ($g.Id -and $e -and $e.Ready -and (-not $g.Engine -or $g.Engine -eq $e)) {
    try { [void](Invoke-Rqbit 'POST' "/torrents/$($g.Id)/delete" $null '' 5) } catch {}
    [void]$e.Torrents.Remove($g.Id)
  } elseif ($g.Id -and $g.Engine -and $g.Engine -ne $e -and $g.OutDir -and $g.OutDir.StartsWith($g.Engine.DlDir, [System.StringComparison]::OrdinalIgnoreCase)) {
    # (rqbit ended meanwhile: its files go from here.)
    try { [System.IO.Directory]::Delete($g.OutDir, $true) } catch {}
  }
  $g.Id = $null
}

# Released torrents whose add was still on its way (see Remove-TorrentRef): deleted in rqbit once it answered.
function Clear-DroppedTorrents {
  for ($i = $script:TorrentDropped.Count - 1; $i -ge 0; $i--) {
    $g = $script:TorrentDropped[$i]
    if ($g.Job -and -not $g.Job.H.IsCompleted) {
      if (((Get-Date) - $g.Job.Started).TotalSeconds -lt $g.Job.Sec + 30) { continue }
      Stop-TorrentJob $g
    } elseif ($g.Job) {
      Complete-TorrentJob $g
      $e = $script:Rqbit
      if ($g.Id -and $e -and $e.Ready -and $g.Engine -eq $e) {
        try { [void](Invoke-Rqbit 'POST' "/torrents/$($g.Id)/delete" $null '' 5) } catch {}
        [void]$e.Torrents.Remove($g.Id)
      }
      $g.Id = $null
    }
    $script:TorrentDropped.RemoveAt($i)
  }
}

function Format-Bytes([double]$b) {
  if ($b -ge 1GB) { return (T '{0} GB' ([Math]::Round($b / 1GB, 1).ToString('0.0', $script:Inv))) }
  if ($b -lt 10MB) { return (T '{0} MB' ([Math]::Round($b / 1MB, 1).ToString('0.0', $script:Inv))) }
  return (T '{0} MB' ([Math]::Round($b / 1MB).ToString('0', $script:Inv)))
}

function Format-Eta([double]$sec) {
  if ($sec -lt 90) { return (T '1 min') }
  if ($sec -lt 3600) { return (T '{0} min' ([Math]::Round($sec / 60))) }
  return (T '{0} h {1} min' ([Math]::Floor($sec / 3600)) ([Math]::Round(($sec % 3600) / 60)))
}

function Get-TorrentDownloadText($item) {
  $dl = $item.Dl
  if (-not $dl -or $dl.LastBytes -lt 0) { return (T 'starting the download') }
  $t = $item.Torrent
  $pct = 0
  if ($t.Bytes -gt 0) { $pct = [int][Math]::Min(99, [Math]::Floor(100.0 * $dl.Done / $t.Bytes)) }
  if ($dl.Eta -ge 0) { return (T 'downloading {0}% of {1}, {2}/s, {3} peers, about {4}' $pct (Format-Bytes $t.Bytes) (Format-Bytes $dl.Speed) $dl.Peers (Format-Eta $dl.Eta)) }
  return (T 'downloading {0}% of {1}, {2} peers' $pct (Format-Bytes $t.Bytes) $dl.Peers)
}

# The extra line under the waiting screen's text: how far the next episode's download is (viewers see it too).
function Get-ScreenNoteText {
  if ($script:Idx -ge $script:Queue.Count) { return '' }
  $nx = $script:Queue[$script:Idx]
  if ($nx.Kind -ne 'torrent') { return '' }
  if ($nx.State -eq 'downloading' -and $nx.Dl -and $nx.Dl.LastBytes -ge 0 -and $nx.Torrent.Bytes -gt 0) {
    $pct = [int][Math]::Min(99, [Math]::Floor(100.0 * $nx.Dl.Done / $nx.Torrent.Bytes))
    if ($nx.Dl.Eta -ge 0) { return (T 'Downloading the next episode: {0}% of {1}, about {2}' $pct (Format-Bytes $nx.Torrent.Bytes) (Format-Eta $nx.Dl.Eta)) }
    return (T 'Downloading the next episode: {0}% of {1}' $pct (Format-Bytes $nx.Torrent.Bytes))
  }
  if ($nx.State -eq 'new' -or $nx.State -eq 'torrent-meta' -or $nx.State -eq 'downloading') { return (T 'Looking for people sharing the next episode...') }
  return ''
}

# The waiting screen reads its extra line from this file (ffmpeg's drawtext, every frame). It is rewritten in place,
# sharing it with that reader, and never deleted or replaced: a read that failed (the file renamed away for a moment
# made ffmpeg's open fail with "Permission denied") would stop the waiting screen.
function Get-NoteFile { return (PathJoin $script:SlateDir "next-$PID.txt") }
function Write-ScreenNote([string]$text) {
  if (-not $script:SlateDir) { return }
  if (-not $text) { $text = ' ' }
  if ($text -eq $script:NoteText) { return }
  $b = $script:Utf8NoBom.GetBytes($text)
  try {
    $fs = New-Object System.IO.FileStream((Get-NoteFile), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try { $fs.Write($b, 0, $b.Length); $fs.SetLength($b.Length) } finally { $fs.Dispose() }
    $script:NoteText = $text
  } catch {}
}

# Called every 2 s while a screen or video plays: at most every 5 s.
function Update-ScreenNote {
  if (((Get-Date) - $script:NoteAt).TotalSeconds -lt 5) { return }
  $script:NoteAt = Get-Date
  Write-ScreenNote (Get-ScreenNoteText)
}

# Keeps this PC from going to sleep while the stream is on the air or a torrent downloads (the screen may still turn
# off). The setting belongs to the thread that made it: only this window's main thread calls this.
function Update-KeepAwake([bool]$off = $false) {
  $want = $false
  if (-not $off) {
    $want = (Test-RelayAlive) -or (@($script:Queue | Where-Object { $_.Kind -eq 'torrent' -and ($_.State -eq 'downloading' -or $_.State -eq 'torrent-meta') }).Count -gt 0)
  }
  if ($want -eq $script:KeepAwake) { return }
  try {
    if (Initialize-Helper) {
      $flags = [uint32]2147483648                  # ES_CONTINUOUS (alone: back to normal)
      if ($want) { $flags = [uint32]2147483649 }   # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
      [void][VRCLinkMaker.Power]::SetThreadExecutionState($flags)
      $script:KeepAwake = $want
    }
  } catch {}
}

# ------------------------------------------------------------------ preparing an item (probe, subtitles, downloads)
$script:JobLocks = @{}
function New-JobDir {
  $d = PathJoin $script:TempRoot ('job-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  [void][System.IO.Directory]::CreateDirectory((PathJoin $d 'fonts'))
  # Held open while this copy of the tool runs, so another copy's clean-up (Clear-OldTemp) skips the folder.
  try { $script:JobLocks[$d] = New-Object System.IO.FileStream((PathJoin $d 'lock'), [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None) } catch {}
  return $d
}

function Convert-TextFileToUtf8([string]$src, [string]$dst) {
  $bytes = [System.IO.File]::ReadAllBytes($src)
  $text = $null
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3) }
  elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2) }
  elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { $text = [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2) }
  else {
    try { $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes) }
    catch {
      # Old-style subtitle file. Use the PC's language setting, but spot Cyrillic (Windows-1251)
      # files on a Western PC: there, most letters are bytes 0xC0-0xFF instead of A-Z.
      $cp = 1252
      try { $cp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage } catch {}
      $hi = 0; $latin = 0
      foreach ($b in $bytes) {
        if ($b -ge 0xC0) { $hi++ } elseif (($b -ge 0x41 -and $b -le 0x5A) -or ($b -ge 0x61 -and $b -le 0x7A)) { $latin++ }
      }
      if ($cp -eq 1252 -and $hi -gt 20 -and $hi -gt $latin) { $cp = 1251 }
      $enc = $null
      try { $enc = [System.Text.Encoding]::GetEncoding($cp) } catch {}
      if (-not $enc) { $enc = [System.Text.Encoding]::GetEncoding(28591) }
      $text = $enc.GetString($bytes)
    }
  }
  [System.IO.File]::WriteAllText($dst, $text, $script:Utf8NoBom)
}

function Find-DownloadedFile([string]$dir) {
  $best = $null
  $bestLen = -1
  try {
    foreach ($f in [System.IO.Directory]::GetFiles($dir)) {
      $n = [System.IO.Path]::GetFileName($f)
      if ($n -match '(?i)\.(part|ytdl|temp|tmp)$' -or $n -match '\.f\d+\.') { continue }
      if ($script:MediaExts -notcontains [System.IO.Path]::GetExtension($f).ToLowerInvariant()) { continue }
      $len = (New-Object System.IO.FileInfo($f)).Length
      if ($len -gt $bestLen) { $best = $f; $bestLen = $len }
    }
  } catch {}
  return $best
}

# A link straight to a video file or an HLS playlist (by the end of its path; a ?query doesn't count): the extension
# ('mp4', 'm3u8', ...), else ''. Such links are played as they are, not handed to yt-dlp.
function Get-UrlMediaExt([string]$u) {
  if ($u -notmatch '^(?i)https?://') { return '' }
  $m = [regex]::Match(($u -split '[?#]', 2)[0], '(?i)\.(mp4|mkv|webm|m4v|mov|ts|m3u8)$')
  if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }
  return ''
}

# A link that was to be played as it is goes to yt-dlp after all (it can't be read as it is, or it needs the whole
# file), when yt-dlp is installed (or gets installed now). $true = its download started.
function Switch-UrlToDownload($item) {
  if ($item.Kind -ne 'url' -or $item.NoDirect -or $item.Source -notmatch '^(?i)https?://') { return $false }
  $yt = Get-YtDlp   # (asks to install it only when a question can be asked here)
  if (-not $yt) { return $false }
  $item.NoDirect = $true
  $item.IsDirectUrl = $false; $item.IsLive = $false; $item.Info = $null; $item.Path = $null
  Start-Download $item $yt
  return $true
}

# The bytes of video in a folder (a download's progress: yt-dlp's .part files, ffmpeg's video.mkv). Not progress.txt:
# ffmpeg adds to it every half second even while nothing arrives.
function Get-DirBytes([string]$dir) {
  $n = [long]0
  try {
    foreach ($f in [System.IO.Directory]::GetFiles($dir)) {
      if ([System.IO.Path]::GetFileName($f) -eq 'progress.txt') { continue }
      try { $n += (New-Object System.IO.FileInfo($f)).Length } catch {}
    }
  } catch {}
  return $n
}

# A download that hasn't moved for this long is given up (a server that stopped sending, a hung yt-dlp).
$script:DlStallSec = 120
function Test-DownloadStalled($item) {
  $dl = $item.Dl
  if (-not $dl -or -not $item.DlDir) { return $false }
  $now = Get-Date
  if (-not $dl.PSObject.Properties['MovedAt']) {
    $dl | Add-Member -Force -NotePropertyName Bytes -NotePropertyValue ([long]-1)
    $dl | Add-Member -Force -NotePropertyName MovedAt -NotePropertyValue $now
    $dl | Add-Member -Force -NotePropertyName CheckAt -NotePropertyValue $now
  }
  if ($now -lt $dl.CheckAt) { return $false }
  # (A look at the folder every 2 s. A long gap since the last look = this PC was asleep: not the download's fault.)
  if (($now - $dl.CheckAt).TotalSeconds -gt 30) { $dl.MovedAt = $now }
  $dl.CheckAt = $now.AddSeconds(2)
  $b = Get-DirBytes $item.DlDir
  if ($b -ne $dl.Bytes) { $dl.Bytes = $b; $dl.MovedAt = $now; return $false }
  return (($now - $dl.MovedAt).TotalSeconds -ge $script:DlStallSec)
}

# yt-dlp downloads in the background (also before the stream starts: Wait-Prep shows how far it got).
function Start-Download($item, [string]$yt) {
  $dl = PathJoin $item.JobDir 'dl'
  [void][System.IO.Directory]::CreateDirectory($dl)
  $item.DlDir = $dl
  $argv = @('--no-playlist', '--no-mtime', '--ffmpeg-location', $script:FFmpegDir,
    '-f', 'bv*[height<=1080]+ba/b[height<=1080]/bv*+ba/b', '--merge-output-format', 'mkv',
    '-P', $dl, '-o', '%(title).80B.%(ext)s', $item.Source)
  # (A link that wants its server's headers, a WPARTY room's video: yt-dlp sends them too.)
  if ($item.Stream -and $item.Stream.Headers) {
    foreach ($k in @($item.Stream.Headers.Keys)) { $argv = @('--add-header', "$($k):$($item.Stream.Headers[$k])") + $argv }
  }
  if (-not (Test-RelayAlive)) {
    Say ''
    Say (T 'Downloading: {0}' $item.Source) 'Cyan'
  }
  $item.Dl = Start-Background $yt (@('--no-progress') + $argv) $dl
  $item.DlKind = 'ytdlp'
  $item.State = 'downloading'
}

function Complete-Download($item) {
  $file = Find-DownloadedFile $item.DlDir
  if (-not $file) {
    $why = Get-LastLines (Get-BgText $item.Dl) 2
    if ($why) { throw (T 'download failed: {0}' $why) }
    throw (T 'download failed (the site may not be supported, or yt-dlp needs an update: winget upgrade yt-dlp.yt-dlp)')
  }
  $item.Path = $file
  $item.Name = [System.IO.Path]::GetFileNameWithoutExtension($file)
}

function Start-Extract($item) {
  $procs = New-Object System.Collections.ArrayList
  $fontsDir = PathJoin $item.JobDir 'fonts'
  $sub = $item.SubTrack
  if ($sub -and $sub.Kind -eq 'text') {
    $codec = 'ass'
    if ($sub.Codec -eq 'ass' -or $sub.Codec -eq 'ssa') { $codec = 'copy' }
    $item.SubIsSrt = ($codec -ne 'copy')
    [void]$procs.Add((Start-Background $script:FFmpeg @('-hide_banner', '-nostdin', '-v', 'error', '-y', '-i', $item.Path, '-map', "0:$($sub.Index)", '-c:s', $codec, 'sub.ass') $item.JobDir))
  } elseif ($sub -and $sub.Kind -eq 'external') {
    $ext = [System.IO.Path]::GetExtension($sub.Path).ToLowerInvariant()
    if ($ext -eq '.ass' -or $ext -eq '.ssa') {
      Convert-TextFileToUtf8 $sub.Path (PathJoin $item.JobDir 'sub.ass')
      $item.SubIsSrt = $false
    } else {
      Convert-TextFileToUtf8 $sub.Path (PathJoin $item.JobDir ('ext' + $ext))
      $item.SubIsSrt = $true
      [void]$procs.Add((Start-Background $script:FFmpeg @('-hide_banner', '-nostdin', '-v', 'error', '-y', '-i', ('ext' + $ext), '-c:s', 'ass', 'sub.ass') $item.JobDir))
    }
  }
  if ($sub -and $sub.Kind -ne 'bitmap' -and $item.Info.Fonts.Count -gt 0) {
    # Fonts that come inside the video file (common for anime). Saved under safe names.
    $argv = New-Object System.Collections.Generic.List[string]
    foreach ($x in @('-hide_banner', '-nostdin', '-v', 'quiet', '-y')) { $argv.Add($x) }
    foreach ($f in $item.Info.Fonts) { $argv.Add("-dump_attachment:$($f.Index)"); $argv.Add("font$($f.Index)$($f.Ext)") }
    $argv.Add('-i'); $argv.Add($item.Path)
    [void]$procs.Add((Start-Background $script:FFmpeg $argv.ToArray() $fontsDir))
  }
  Copy-FallbackFonts $fontsDir
  $item.Prep = $procs.ToArray()
  $item.State = 'extracting'
}

function Complete-Extract($item) {
  $sub = $item.SubTrack
  if ($sub -and $sub.Kind -ne 'bitmap') {
    $sf = PathJoin $item.JobDir 'sub.ass'
    if ([System.IO.File]::Exists($sf) -and (New-Object System.IO.FileInfo($sf)).Length -gt 0) { $item.SubFile = $sf }
    else { $item.SubWarn = (T 'couldn''t read the subtitles, playing without them'); $item.SubTrack = $null }
  }
}

# A web video whose subtitles come as a file of their own (an AnimeLib or Collaps translation with subtitles only: the
# stream's .Subtitle, see Resolve-Candidate). Saved into the job folder once and offered like a subtitle file next to a
# video, so it gets drawn into the picture. If it can't be fetched, the video plays without it (said once, as a note
# under "Now streaming").
function Add-SiteSubtitle($item) {
  $item.ExtraSubs = @($item.ExtraSubs | Where-Object { $_ -and -not $_.PSObject.Properties['FromSite'] })
  $st = $item.Stream
  if ($item.Kind -ne 'site' -or -not $st -or -not $st.PSObject.Properties['Subtitle'] -or -not $st.Subtitle -or -not $script:CanSubs) { return }
  $s = $st.Subtitle
  $failText = T 'the subtitles didn''t download, so it plays without them'
  if (-not $s.PSObject.Properties['Path']) {
    $s | Add-Member -Force -NotePropertyName Path -NotePropertyValue $null
    $ext = '.' + "$($s.Format)".ToLowerInvariant()
    if ($script:SubExts -notcontains $ext) { $ext = '.vtt' }
    $path = PathJoin $item.JobDir ('site-sub' + $ext)
    try {
      if ($s.Provider -eq 'collaps') { [void](Save-CollapsSubtitle $s.Url $path) } else { [void](Save-AnimelibSubtitle $s.Url $path) }
      # (Only a real subtitle file: a server can answer with an error page, and ffmpeg wouldn't start with that.)
      $txt = ''
      if ([System.IO.File]::Exists($path)) { $txt = ([System.IO.File]::ReadAllText($path)).TrimStart() }
      if ($txt -and -not $txt.StartsWith('<') -and $txt -match '(?m)^\[Script Info\]|^\[Events\]|^WEBVTT|-->') { $s.Path = $path }
    } catch {}
  }
  if (-not $s.Path) { $item.SubWarn = $failText; return }
  if ($item.SubWarn -eq $failText) { $item.SubWarn = $null }
  $t = New-ExternalSubTrack $s.Path
  if ("$($s.Lang)" -match '^[A-Za-z]{2,3}$') { $t.Lang = "$($s.Lang)".ToLowerInvariant() }
  if ($s.Label) { $t.Title = [string]$s.Label } else { $t.Title = T 'subtitles from the site' }
  $t | Add-Member -Force -NotePropertyName FromSite -NotePropertyValue $true
  $item.ExtraSubs = @($t) + @($item.ExtraSubs)
}

function Step-Prep($item) {
  if (-not $item) { return }
  if ($item.State -eq 'ready' -or $item.State -eq 'failed') { return }
  try {
    if ($item.Kind -eq 'torrent' -and ($item.State -eq 'new' -or $item.State -eq 'torrent-meta' -or $item.State -eq 'downloading')) {
      # (Downloaded completely first; then it is a file on this PC: probe, tracks, subtitles as for any file.)
      if (-not $item.JobDir) { $item.JobDir = New-JobDir }
      Step-TorrentPrep $item
      if ($item.State -ne 'probe') { return }
    }
    if ($item.State -eq 'new') {
      if (-not $item.JobDir) { $item.JobDir = New-JobDir }
      if ($item.Kind -eq 'site') {
        Start-NextSource $item
        if ($item.State -ne 'probe') { return }
      } elseif ($item.Kind -eq 'url') {
        # A link straight to a video file / playlist plays as it is (also with yt-dlp installed); a link with the
        # server's headers (a WPARTY room's video) too; any other web page goes to yt-dlp.
        $yt = $null
        $ext = Get-UrlMediaExt $item.Source
        if ($item.Source -match '^(?i)https?://' -and -not $ext -and -not $item.Stream) { $yt = Get-YtDlp }
        if ($yt) { Start-Download $item $yt; return }
        # An HLS playlist may list several qualities: the one that fits the picture we send (ffmpeg alone would take
        # the first one listed, often the smallest).
        $hls = $item.Stream
        if (-not $hls -and $ext -eq 'm3u8') { $hls = New-Stream $item.Source 'hls' @{} }
        if ($hls -and $hls.Kind -eq 'hls' -and -not $hls.PSObject.Properties['Checked']) {
          $st = $null
          $pk = $null
          if ($item.PSObject.Properties['PickBg']) { $pk = $item.PickBg }
          if ($pk -or (Test-RelayAlive)) {
            # While the stream is on, the playlists load in the background, so the window keeps answering meanwhile.
            if (-not $pk) { $item | Add-Member -Force -NotePropertyName PickBg -NotePropertyValue (Start-HlsPickBg $hls); return }
            if (-not $pk.H.IsCompleted -and ((Get-Date) - $pk.Started).TotalSeconds -lt 60) { return }
            $item.PickBg = $null
            if ($pk.H.IsCompleted) {
              try { $res = @($pk.Ps.EndInvoke($pk.H)); if ($res.Count -gt 0) { $st = $res[0] } } catch {}
              try { $pk.Ps.Dispose() } catch {}
            } else { try { [void]$pk.Ps.BeginStop($null, $null) } catch {} }
          } else {
            try { $st = Complete-HlsStream (New-Stream $hls.Url 'hls' $hls.Headers) } catch {}
          }
          # Only a quality that carries its own sound is taken. Else the master playlist plays as it is: ffmpeg reads
          # all of it, and the group's default sound is chosen (a separate sound playlist could be another language);
          # the picked quality is then looked for in what ffprobe lists (see ConvertFrom-ProbeOutput).
          if ($st -and $st.Program -lt 0 -and -not $st.AudioUrl) { $hls = $st }
          elseif ($st -and $st.PSObject.Properties['PickBw']) {
            $hls | Add-Member -Force -NotePropertyName PickBw -NotePropertyValue $st.PickBw
            $hls | Add-Member -Force -NotePropertyName PickH -NotePropertyValue $st.PickH
          }
          $hls | Add-Member -Force -NotePropertyName Checked -NotePropertyValue $true
          $item.Stream = $hls
        }
        $item.IsDirectUrl = $true
        $item.Path = $item.Source
        if ($item.Stream) { $item.Path = $item.Stream.Url }
      }
      $item.State = 'probe'
    }
    if ($item.State -eq 'downloading') {
      if (-not $item.Dl.Proc.HasExited) {
        if (-not (Test-DownloadStalled $item)) { return }
        # No progress for minutes: give it up (and go on with the next source, or the next video).
        Stop-ProcessTree $item.Dl.Proc   # (yt-dlp's own ffmpeg too)
        $item.Dl | Add-Member -Force -NotePropertyName Stalled -NotePropertyValue $true
        Say (T '  The download of {0} made no progress for {1} seconds, so it was stopped.' $item.Name $script:DlStallSec) 'Yellow'
        if ($item.DlKind -ne 'ffmpeg') { throw (T 'the download made no progress for {0} seconds' $script:DlStallSec) }
      }
      if ($item.DlKind -eq 'ffmpeg') {
        if (-not (Complete-StreamDownload $item)) { return }
      } else {
        Complete-Download $item
      }
      $item.State = 'probe'
    }
    if ($item.State -eq 'probe') {
      $st = $null
      if ($item.IsDirectUrl) { $st = $item.Stream }
      try {
        if ($st -and $st.PSObject.Properties['Probe'] -and $st.Probe) { $item.Info = $st.Probe; $st.Probe = $null }   # (read by the quality check)
        elseif ($item.Kind -eq 'url' -and $item.IsDirectUrl -and -not ($st -and $st.AudioUrl) -and (Test-RelayAlive)) {
          # A link read over the network while the stream is on (the next video, or this one behind the waiting
          # screen): ffprobe runs in the background, so the window keeps answering meanwhile.
          $pb = $null
          if ($item.PSObject.Properties['ProbeBg'] -and $item.ProbeBg -and $item.ProbeBg.Path -eq $item.Path) { $pb = $item.ProbeBg }
          if (-not $pb) {
            $bg = Start-Background $script:FFprobe (Get-MediaInfoArgs $item.Path $true $st)
            $item | Add-Member -Force -NotePropertyName ProbeBg -NotePropertyValue ([pscustomobject]@{ Bg = $bg; Path = $item.Path })
            return
          }
          if (-not $pb.Bg.Proc.HasExited) {
            if (((Get-Date) - $pb.Bg.Started).TotalSeconds -lt 90) { return }
            $item.ProbeBg = $null
            Stop-Proc $pb.Bg.Proc
            throw (T 'can''t read it ({0})' 'timeout')
          }
          $item.ProbeBg = $null
          $item.Info = ConvertFrom-ProbeOutput ([pscustomobject]@{ ExitCode = $pb.Bg.Proc.ExitCode; Out = $pb.Bg.Out.Result; Err = $pb.Bg.Err.Result }) $st
        }
        else { $item.Info = Get-MediaInfo $item.Path $item.IsDirectUrl $st }
      } catch {
        # A link to a video file that can't be read as it is (a share page, a server that wants a browser): yt-dlp
        # gets it instead, when it is installed.
        if ($item.Kind -eq 'url' -and $item.IsDirectUrl) {
          $why = $_.Exception.Message
          if (Switch-UrlToDownload $item) { $item.Errors = @($item.Errors) + @($why); return }
        }
        # Playing straight from the site didn't work out: another player, else download it (or try the next source).
        if (-not ($item.Kind -eq 'site' -and $item.IsDirectUrl)) { throw }
        $item.Errors = @($item.Errors) + @("$($item.Using.Label): $($_.Exception.Message)")
        $item.IsDirectUrl = $false
        if ($item.Stream.LiveOnly) { $item.State = 'new'; Start-NextSource $item; return }
        if (Switch-ToBackup $item) { return }
        $item.NoDirect = $true
        Start-StreamDownload $item $item.Stream
        return
      }
      if (-not $item.Info.Video -and $item.Info.Audio.Count -eq 0) { throw (T 'no video or audio found in it') }
      # A link to a live stream (an HLS playlist that keeps growing has no length): it plays from where the stream
      # is now, and can't be skipped back or forward. (Only HLS, an MPEG-TS link (IPTV) and rtmp/rtsp/srt/udp: another
      # file without a length is still a file.)
      $isHls = ((Get-UrlMediaExt $item.Source) -eq 'm3u8') -or ($item.Stream -and $item.Stream.Kind -eq 'hls')
      $liveForm = $isHls -or ((Get-UrlMediaExt $item.Source) -eq 'ts') -or ($item.Source -notmatch '^(?i)https?://')
      $item.IsLive = ($item.Kind -eq 'url' -and $item.IsDirectUrl -and $liveForm -and $item.Info.Duration -le 0)
      # Subtitles written as text inside the file can only be drawn in from a downloaded copy: yt-dlp downloads it.
      if ($item.Kind -eq 'url' -and $item.IsDirectUrl -and -not $item.IsLive -and $script:CanSubs -and
        @($item.Info.Subs | Where-Object { $_.Kind -eq 'text' }).Count -gt 0 -and (Switch-UrlToDownload $item)) { return }
      if (-not $item.IsDirectUrl) {
        $have = @($item.ExtraSubs | ForEach-Object { $_.Path })
        foreach ($sc in @(Get-SidecarSubs $item.Path)) { if ($have -notcontains $sc.Path) { $item.ExtraSubs = @($item.ExtraSubs) + @($sc) } }
      }
      Add-SiteSubtitle $item
      Select-Tracks $item
      Set-FpsPlan $item
      Start-Extract $item
    }
    if ($item.State -eq 'extracting') {
      foreach ($bg in $item.Prep) {
        if (-not $bg.Proc.HasExited) {
          if (((Get-Date) - $bg.Started).TotalSeconds -lt 240) { return }
          Stop-Proc $bg.Proc
        }
      }
      Complete-Extract $item
      $item.State = 'ready'
    }
  } catch {
    if ($script:CtrlCQuit) { throw }
    $item.State = 'failed'
    $item.Error = $_.Exception.Message
  }
}

function Wait-Prep($item) {
  $t0 = Get-Date
  $shown = $false
  while ($item.State -ne 'ready' -and $item.State -ne 'failed') {
    Step-Prep $item
    if ($item.State -eq 'ready' -or $item.State -eq 'failed') { break }
    if (-not $shown -and ((Get-Date) - $t0).TotalSeconds -gt 1.5) { Say (T 'Getting {0} ready...' $item.Name) 'Gray'; $shown = $true }
    if ($item.State -eq 'downloading') { Show-Status (T '  {0}   (Ctrl+C = stop)' (Get-DownloadText $item)) }
    Update-KeepAwake
    Wait-Pump 0.2
  }
  Clear-StatusLine
}

# Gets the next videos ready in the background. Downloads run one at a time, in queue order.
function Update-Prep {
  if ($script:TorrentDropped.Count -gt 0) { Clear-DroppedTorrents }
  # (Up next reordered while a download runs: the videos moved ahead of it wait until it is done, not a 2nd download.
  # A torrent episode still getting its file list counts as running too.)
  for ($i = $script:Idx + 1; $i -lt $script:Queue.Count; $i++) {
    if ($script:Queue[$i].State -ne 'downloading' -and $script:Queue[$i].State -ne 'torrent-meta') { continue }
    for ($j = $script:Idx + 1; $j -lt $i; $j++) { if ($script:Queue[$j].State -eq 'new') { Step-Prep $script:Queue[$i]; return } }
    break
  }
  $last = [Math]::Min($script:Queue.Count - 1, $script:Idx + 2)
  for ($i = $script:Idx; $i -le $last; $i++) {
    $it = $script:Queue[$i]
    if ($i -gt $script:Idx) { Step-Prep $it }
    if ($it.State -eq 'downloading' -or $it.State -eq 'torrent-meta' -or ($i -eq $script:Idx -and $it.State -eq 'new')) { break }
    # (A link still looked at in the background may turn into a download: the ones after it wait, to keep the order.)
    $bgBusy = ($it.PSObject.Properties['PickBg'] -and $it.PickBg) -or ($it.PSObject.Properties['ProbeBg'] -and $it.ProbeBg)
    if ($bgBusy -and ($it.State -eq 'new' -or $it.State -eq 'probe')) { break }
  }
}

# ------------------------------------------------------------------ building the ffmpeg commands
# Sources hand their audio to the relay (which encodes it once more, see Start-Relay) at a higher bitrate, so that
# second encoding loses nothing audible. It only travels through a pipe on this PC.
function Get-SourceAudioKbps { return [Math]::Max(256, [int]$script:Cfg.AudioKbps) }
function Get-OffsetFilter([string]$kind, [double]$off) {
  if ($off -le 0) { return $null }
  if ($kind -eq 'a') { return "asetpts=PTS+$(Format-Num $off)/TB" }
  return "setpts=PTS+$(Format-Num $off)/TB"
}

# Every picture leaves tagged the same way (HD colours, BT.709, limited range), whatever the video was tagged with.
# The tags are part of the H.264 header: the screens were untagged and most videos are tagged, so the header changed at
# every screen <-> video switch, and VRChat's player could freeze for up to a minute, falling that far behind the
# others (players that took it better ran ahead: "my friend sees it far ahead of me").
$script:ColourTags = 'setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv'
function Test-ClassicEncoder { return ("$(Get-Prop $script:Cfg 'EncoderArgs')".Trim() -match '^(?i)classic$') }
$script:HasSetparams = $true
function Get-ColourTagFilter { if ((Test-ClassicEncoder) -or -not $script:HasSetparams) { return $null }; return $script:ColourTags }

# What the main scale adds so the colours stay right once tagged BT.709 / limited range: SD videos (and untagged ones
# below 720 lines, which players treat as SD) use the BT.601 colour matrix, and some videos use the full range.
function Get-ColourScaleOpts($v) {
  if (-not $v -or (Test-ClassicEncoder)) { return '' }
  $cs = "$($v.ColorSpace)".ToLowerInvariant()
  $m = 'bt709'
  if ($cs -match '^(bt470bg|smpte170m|bt601)') { $m = 'bt601' }
  elseif ($cs -notmatch '^bt709' -and $v.Height -gt 0 -and $v.Height -lt 720) { $m = 'bt601' }
  $full = ("$($v.ColorRange)" -match '^(?i)(pc|full|jpeg)$') -or ("$($v.PixFmt)" -match '^yuvj')
  if ($m -eq 'bt709' -and -not $full) { return '' }
  $r = 'tv'
  if ($full) { $r = 'full' }
  return ":in_color_matrix=$($m):out_color_matrix=bt709:in_range=$($r):out_range=tv"
}

function Get-VideoGraph($item, [string]$inLabel, [double]$start, [string]$pix, [double]$off) {
  $W = $script:OutW; $H = $script:OutH
  $v = $item.Info.Video
  $pre = New-Object System.Collections.Generic.List[string]
  $post = New-Object System.Collections.Generic.List[string]
  if ($v -and $v.Interlaced -and $script:HasBwdif) { $pre.Add('bwdif=deint=interlaced') }
  if ($v -and $v.Sar -gt 0 -and [Math]::Abs($v.Sar - 1.0) -gt 0.01) { $post.Add('scale=trunc(iw*sar/2)*2:ih:flags=lanczos'); $post.Add('setsar=1') }
  $post.Add("scale=$($W):$($H):force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos$(Get-ColourScaleOpts $v)")
  # (The session's frame rate as it is now, not as it was when this video was got ready: Select-SessionFps may change it.)
  $post.Add("fps=$($script:StreamFps)")
  $sub = $item.SubTrack
  if ($sub -and $item.SubFile -and $sub.Kind -ne 'bitmap') {
    $sf = 'subtitles=filename=sub.ass:fontsdir=fonts'
    if ($item.SubIsSrt) { $sf += ":force_style='FontName=$($script:FallbackFontName),FontSize=20,Outline=1.6,Shadow=0.6,MarginV=18'" }
    if ($start -gt 0.5) {
      $post.Add("setpts=PTS+$(Format-Num $start)/TB")
      $post.Add($sf)
      $post.Add('setpts=PTS-STARTPTS')
    } else {
      $post.Add($sf)
    }
  }
  $post.Add("pad=$($W):$($H):(ow-iw)/2:(oh-ih)/2:color=black")
  $post.Add('setsar=1')
  if ($script:ClockOn -and $script:FallbackFonts.Count -gt 0) {
    # The video's own time, top right: viewers compare it to see who is behind.
    $post.Add("drawtext=fontfile=$($script:ClockFont):fontsize=22:fontcolor=white@0.85:box=1:boxcolor=black@0.45:boxborderw=6:x=w-tw-16:y=14:text='%{pts\:hms\:$(Format-Num $start)}'")
  }
  $post.Add("format=$pix")
  $ct = Get-ColourTagFilter
  if ($ct) { $post.Add($ct) }
  $of = Get-OffsetFilter 'v' $off
  if ($of) { $post.Add($of) }
  if ($sub -and $sub.Kind -eq 'bitmap') {
    $g = ''
    $vin = $inLabel
    if ($pre.Count -gt 0) { $g = $inLabel + ($pre -join ',') + '[vd];'; $vin = '[vd]' }
    return ($g + $vin + "[0:$($sub.Index)]overlay=eof_action=pass," + ($post -join ',') + '[v]')
  }
  $all = @($pre) + @($post)
  return ($inLabel + ($all -join ',') + '[v]')
}

# The small picture the control window shows (a second output of the same ffmpeg, twice a second).
# ffmpeg keeps the outputs of one run level: it holds back what feeds an output that is ahead of the one furthest
# behind. With two pictures a second this output was always up to half a second behind the stream, and ffmpeg kept
# holding the stream back for it whenever the picture and the sound come from two inputs (the waiting / paused /
# starting screens, and videos whose sound comes separately): they went out at about 14 of 24 frames a second
# (0.56x with ffmpeg 9), and every minute on such a screen put viewers' players ~25 s further behind live, for good.
# So its timestamps run 1 s ahead of the stream's: it is never the one behind. Apart from that it keeps the stream's
# own timestamps (passthrough): timed from 0, the stream itself seemed far ahead and its sound stopped.
function Add-PreviewOutput($a, [ref]$graph) {
  $graph.Value += ';[v]split=2[vo][pv0];[pv0]fps=2,scale=384:-2,format=yuvj420p,setpts=PTS+1/TB[pv]'
  return @('-map', '[pv]', '-an', '-c:v', 'mjpeg', '-q:v', '7') + $script:PreviewSyncArgs + @('-f', 'image2', '-update', '1', $script:PreviewFile)
}

# $off shifts all timestamps so each video continues exactly where the previous one ended.
function Get-ContentArgs($item, [double]$start, [double]$off, [bool]$preview = $false) {
  $W = $script:OutW; $H = $script:OutH
  $info = $item.Info
  if ($item.IsLive) { $start = 0.0 }   # (a live stream always goes on from where it is now)
  $a = New-Object System.Collections.Generic.List[string]
  foreach ($x in @('-hide_banner', '-y', '-v', 'error', '-nostats', '-progress', 'progress.txt')) { $a.Add($x) }
  if ($start -gt 0.5) { $a.Add('-ss'); $a.Add((Format-Num $start)) }
  $a.Add('-re')
  if ($item.IsDirectUrl -and $item.Stream) {
    foreach ($x in (Get-StreamInputArgs $item.Stream)) { $a.Add($x) }
  } elseif ($item.IsDirectUrl -and $item.Path -match '^(?i)https?://') {
    foreach ($x in @('-reconnect', '1', '-reconnect_streamed', '1', '-reconnect_delay_max', '5', '-rw_timeout', '20000000')) { $a.Add($x) }
  }
  $a.Add('-i'); $a.Add($item.Path)
  $ain = 0
  if ($item.IsDirectUrl -and $item.Stream -and $item.Stream.AudioUrl -and $info.AudioInput -eq 1) {
    if ($start -gt 0.5) { $a.Add('-ss'); $a.Add((Format-Num $start)) }
    $a.Add('-re')
    foreach ($x in (Get-StreamInputArgs $item.Stream)) { $a.Add($x) }
    $a.Add('-i'); $a.Add($item.Stream.AudioUrl)
    $ain = 1
  }
  $remaining = 0.0
  if ($info.Duration -gt 0) { $remaining = [Math]::Max(1.0, $info.Duration - $start) }
  $pix = 'yuv420p'
  if ($script:VEnc -eq 'h264_qsv') { $pix = 'nv12' }
  $aOff = Get-OffsetFilter 'a' $off
  $useShortest = $false
  if (-not $info.Video) {
    # Audio only: show a waveform, which also ends exactly when the audio ends.
    $vOff = Get-OffsetFilter 'v' $off
    $vChain = "showwaves=s=$($W)x$($H):mode=cline:rate=$($script:StreamFps):colors=white,format=$pix,setsar=1"
    $ct = Get-ColourTagFilter
    if ($ct) { $vChain += ",$ct" }
    if ($vOff) { $vChain += ",$vOff" }
    $aChain = 'anull'
    if ($aOff) { $aChain = $aOff }
    $graph = "[$($ain):$($item.AudioTrack.Index)]aresample=async=1,asplit=2[a0][w];[w]$vChain[v];[a0]$aChain[a]"
  } else {
    $graph = Get-VideoGraph $item "[0:$($info.Video.Index)]" $start $pix $off
    if ($item.AudioTrack) {
      $chain = 'aresample=async=1'
      if ($aOff) { $chain += ",$aOff" }
      $graph += ";[$($ain):$($item.AudioTrack.Index)]$chain[a]"
    } else {
      # No audio in the file: add silence of the same length (servers expect an audio track).
      foreach ($x in @('-re', '-f', 'lavfi')) { $a.Add($x) }
      if ($remaining -gt 0) { $a.Add('-t'); $a.Add((Format-Num ($remaining + 0.3))) } else { $useShortest = $true }
      foreach ($x in @('-i', 'anullsrc=r=48000:cl=stereo')) { $a.Add($x) }
      $chain = 'anull'
      if ($aOff) { $chain = $aOff }
      $graph += ";[$($ain + 1):a]$chain[a]"
    }
  }
  $vmap = '[v]'
  $pvArgs = @()
  if ($preview) { $pvArgs = @(Add-PreviewOutput $a ([ref]$graph)); $vmap = '[vo]' }
  $a.Add('-filter_complex'); $a.Add($graph)
  $a.Add('-map'); $a.Add($vmap)
  $a.Add('-map'); $a.Add('[a]')
  foreach ($x in (Get-VideoEncArgs $script:VEnc $script:VideoKbps $script:StreamFpsNum)) { $a.Add($x) }
  foreach ($x in @('-c:a', 'aac', '-b:a', "$(Get-SourceAudioKbps)k", '-ar', '48000', '-ac', '2')) { $a.Add($x) }
  if ($useShortest) { $a.Add('-shortest') }
  foreach ($x in @('-max_muxing_queue_size', '4096', '-f', 'mpegts', 'pipe:1')) { $a.Add($x) }
  foreach ($x in $pvArgs) { $a.Add($x) }
  return $a.ToArray()
}

# A screen viewers see instead of a video (waiting / paused / starting). Encoded exactly like the videos.
function Get-SlateArgs([double]$off, [string]$assFile = 'slate.ass', [bool]$preview = $false) {
  $W = $script:OutW; $H = $script:OutH
  $pix = 'yuv420p'
  if ($script:VEnc -eq 'h264_qsv') { $pix = 'nv12' }
  $a = New-Object System.Collections.Generic.List[string]
  foreach ($x in @('-hide_banner', '-y', '-v', 'error', '-nostats', '-progress', 'progress.txt', '-re', '-f', 'lavfi', '-i', "color=c=black:s=$($W)x$($H):r=$($script:StreamFps)",
      '-re', '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo')) { $a.Add($x) }
  $vChain = "format=$pix"
  if ($script:CanSubs -and -not $script:SlateNoText) {
    $vChain = "subtitles=filename=$($assFile):fontsdir=fonts"
    # The waiting screen gets one more line while the next episode downloads (how far it got, see Write-ScreenNote).
    # Only the picture changes: the encoder settings, and so the H.264 header, stay the same.
    $nf = Get-NoteFile
    if ($assFile -eq 'slate.ass' -and $script:HasDrawtext -and [System.IO.File]::Exists($nf) -and [System.IO.File]::Exists((PathJoin $script:SlateDir 'fonts\arialbd.ttf'))) {
      $fs = [Math]::Max(12, [int]($H / 26))
      $vChain += ",drawtext=fontfile=fonts/arialbd.ttf:textfile=$([System.IO.Path]::GetFileName($nf)):reload=1:expansion=none:fontsize=$($fs):fontcolor=white@0.8:x=(w-tw)/2:y=h*0.62"
    }
    $vChain += ",format=$pix"
  }
  $ct = Get-ColourTagFilter
  if ($ct) { $vChain += ",$ct" }
  $vOff = Get-OffsetFilter 'v' $off
  if ($vOff) { $vChain += ",$vOff" }
  $aChain = 'anull'
  $aOff = Get-OffsetFilter 'a' $off
  if ($aOff) { $aChain = $aOff }
  $g = "[0:v]$vChain[v];[1:a]$aChain[a]"
  $vmap = '[v]'
  $pvArgs = @()
  if ($preview) { $pvArgs = @(Add-PreviewOutput $a ([ref]$g)); $vmap = '[vo]' }
  foreach ($x in @('-filter_complex', $g, '-map', $vmap, '-map', '[a]')) { $a.Add($x) }
  foreach ($x in (Get-VideoEncArgs $script:VEnc $script:VideoKbps $script:StreamFpsNum)) { $a.Add($x) }
  foreach ($x in @('-c:a', 'aac', '-b:a', "$(Get-SourceAudioKbps)k", '-ar', '48000', '-ac', '2', '-f', 'mpegts', 'pipe:1')) { $a.Add($x) }
  foreach ($x in $pvArgs) { $a.Add($x) }
  return $a.ToArray()
}

# ------------------------------------------------------------------ the stream itself
# Every source (a video, and each screen viewers see instead: waiting / paused / starting) is encoded with exactly the
# same settings (frame rate, bitrate, keyframe interval, level), so the H.264 header viewers get never changes while
# they are connected. When it did change (the screens used to be 24 fps / 300 kbps), VRChat's player could stall for
# half a minute at every switch.
function Test-RelayAlive {
  if (-not $script:Relay) { return $false }
  try { return (-not $script:Relay.HasExited) } catch { return $false }
}

# The relay keeps ONE connection to the server open, and every source is fed into it one after another, so viewers
# don't have to reconnect between videos or around a pause.
function Start-Relay {
  # Our own MPEG-TS (headers on every keyframe): half a second of probing is plenty and makes (re)connecting quicker.
  # Its progress (bytes sent) tells when the server really takes the stream.
  # The audio is encoded here once more, with every gap between two sources filled with silence of exactly that length:
  # each source stops its audio and video at slightly different moments, and VRChat's player plays audio back to back
  # (skipping a gap) while the picture waits the gap out, so every pause / seek / next video left the sound a bit
  # further ahead of the picture. The picture is only copied.
  # (Each connection has its own progress file: during a resync the old one is still on while the new one opens.)
  $script:RelayGen++
  try { [System.IO.File]::Delete((Get-RelayProgPath)) } catch {}
  # The progress comes through a pipe and only its end is kept (TailReader); a file of it grew without end.
  $tail = Initialize-Helper
  $progTo = Get-RelayProgName
  if ($tail) { $progTo = 'pipe:1' }
  # MediaMTX (VPS, SRT) times each track by when its data arrives, and ffmpeg's MPEG-TS output held the sound back in
  # ~0.35 s chunks, sent after the picture of the same moment: players that line the tracks up by those times (RTSP's
  # RTCP) played the sound 0.2-0.65 s late. One audio frame per packet, at most 0.1 s held back: within ~0.07 s.
  $mux = @()
  if ((Get-IngestFormat) -eq 'mpegts') { $mux = @('-pes_payload_size', '0', '-muxdelay', '0.1') }
  $argv = @('-hide_banner', '-v', 'error', '-nostats') + $script:RelayStatArgs + @('-progress', $progTo, '-analyzeduration', '500000', '-probesize', '1000000',
    '-f', 'mpegts', '-i', 'pipe:0', '-map', '0:v', '-map', '0:a', '-c:v', 'copy',
    '-af', 'aresample=async=1:min_hard_comp=0.02:first_pts=0', '-c:a', 'aac', '-b:a', "$([int]$script:Cfg.AudioKbps)k", '-ar', '48000', '-ac', '2') + $mux + @(
    '-f', (Get-IngestFormat), '-flvflags', 'no_duration_filesize', (Get-IngestUrl))
  $psi = New-StartInfo $script:FFmpeg $argv $script:TempRoot
  $psi.RedirectStandardInput = $true
  # Its complaints are kept, not printed over the window: the last one is shown if the connection breaks.
  $psi.RedirectStandardError = $true
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  if ($tail) { $psi.RedirectStandardOutput = $true }
  $psi.CreateNoWindow = $true   # (also without the helper, when its progress goes to a file)
  $script:Relay = Start-Child $psi
  $script:RelayTail = $null
  if ($tail) { $script:RelayTail = New-Object VRCLinkMaker.TailReader($script:Relay.StandardOutput.BaseStream, 4096) }
  $script:RelayErr = $script:Relay.StandardError.ReadToEndAsync()
  $script:RelayIn = $script:Relay.StandardInput.BaseStream
  $script:RelayStartedAt = Get-Date
  $script:RelayKilled = $false
  $script:RelayHadSent = $false
  $script:LastEnd = -1.0
  # Nobody can be watching a connection that just opened: the next video waits for the players (Test-HoldReady).
  $script:RelayFresh = $true
  $script:FpsLocked = $false   # (a reconnect of the same session carries it over: Restart-RelayForResync, Invoke-Queue)
}

$script:RelayGen = 0
$script:RelayStatArgs = @()
$script:PreviewSyncArgs = @('-fps_mode', 'passthrough')
function Get-RelayProgName { return "relay-progress-$PID-$($script:RelayGen).txt" }
function Get-RelayProgPath { return (PathJoin $script:TempRoot (Get-RelayProgName)) }

# The last few KB of a file another program is still writing ('' if there's none).
function Read-FileTail([string]$file, [int]$bytes = 4096) {
  try {
    if (-not [System.IO.File]::Exists($file)) { return '' }
    $fs = New-Object System.IO.FileStream($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $len = $fs.Length
      $take = [int][Math]::Min($len, $bytes)
      if ($take -le 0) { return '' }
      [void]$fs.Seek($len - $take, [System.IO.SeekOrigin]::Begin)
      $buf = New-Object byte[] $take
      $n = $fs.Read($buf, 0, $take)
      return [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
    } finally { $fs.Dispose() }
  } catch { return '' }
}

# How many bytes the relay has sent to the server so far (0 = none yet: still connecting). -1 = no progress file.
function Read-RelaySize {
  if ($script:RelayTail) {
    $text = $script:RelayTail.Text
  } else {
    $f = Get-RelayProgPath
    if (-not [System.IO.File]::Exists($f)) { return -1 }
    $text = Read-FileTail $f
  }
  $ms = [regex]::Matches($text, 'total_size=(\d+)')
  if ($ms.Count -eq 0) { return 0 }
  return [long]$ms[$ms.Count - 1].Groups[1].Value
}

# Links as they may appear in ffmpeg's messages, without their passwords / passphrases.
function Hide-UrlSecrets([string]$s) {
  if (-not $s) { return $s }
  $s = $s -replace '(?i)((?:passphrase|password|pass)=)[^&\s''"]+', '$1***'
  $s = $s -replace '(?i)(streamid=[^&\s''"]*:)[^:&\s''"]+', '$1***'
  return $s
}

# Where the relay sends the stream (the host profile's ingest: rtmp:// as FLV, or srt:// as MPEG-TS for a VPS).
function Get-IngestUrl { if ($script:HostP -and $script:HostP.IngestUrl) { return $script:HostP.IngestUrl }; return [string]$script:Cfg.IngestUrl }
function Get-IngestFormat {
  if ($script:HostP -and $script:HostP.IngestFormat) { return $script:HostP.IngestFormat }
  if ((Get-IngestUrl) -match '^(?i)srt://') { return 'mpegts' }
  return 'flv'
}

# Where the next source's timestamps start: right after the previous one (never earlier).
function Get-NextOffset {
  if ($script:LastEnd -lt 0) { return 0.0 }
  $wall = ((Get-Date) - $script:RelayStartedAt).TotalSeconds
  return [Math]::Max($script:LastEnd + 0.1, $wall)
}

$script:RelayStuck = $false
function Get-RelayError {
  if ($script:RelayStuck) { $script:RelayStuck = $false; return (T 'the server stopped taking the stream') }
  $e = ''
  try { if ($script:RelayErr -and $script:RelayErr.IsCompleted) { $e = Get-LastLines $script:RelayErr.Result 1 } } catch {}
  if (-not $e) { return '' }
  # ffmpeg's network errors in plain words.
  if ($e -match '-10054|-104\b|reset by peer') { return (T 'the connection was reset') }
  if ($e -match '-10060|-138\b|-110\b|timed out') { return (T 'the connection timed out') }
  if ($e -match '-10061|-111\b|refused') { return (T 'the server refused the connection') }
  if ($e -match '-11001|-10065|resolve|getaddrinfo') { return (T 'the server''s address couldn''t be found (is the internet on?)') }
  if ($e -match 'Operation not permitted') { return (T 'the server refused the stream (wrong key or password?)') }
  if ($env:VRCLM_DEBUG) { return (Hide-UrlSecrets $e) }
  return ''
}

# $script:RelayKilled: this tool ended the relay while it was still connected (a stall, a resync...), as opposed to
# the server or the network ending it. (The server then still lists that connection for a few seconds.)
# $script:RelayHadSent: the relay had sent something before it was stopped (its progress file is gone after that).
$script:RelayKilled = $false
$script:RelayHadSent = $false
function Stop-Relay {
  if ($script:Src) { [void](Stop-Source $script:Src -Now) }
  if ($script:Relay) {
    try { if (-not $script:Relay.HasExited) { $script:RelayKilled = $true } } catch {}
    try { if ((Read-RelaySize) -gt 0) { $script:RelayHadSent = $true } } catch {}
    Remove-Relay $script:Relay (Get-RelayProgPath)
  }
  $script:Relay = $null
  $script:RelayIn = $null
}

# Ends a relay ffmpeg and removes its progress file.
function Remove-Relay($proc, [string]$progFile) {
  Stop-Proc $proc
  try { [void]$proc.WaitForExit(2000) } catch {}
  try { [System.IO.File]::Delete($progFile) } catch {}
}

function Close-Relay {
  if (Test-RelayAlive) {
    try { $script:Relay.StandardInput.Close() } catch {}
    try { if (-not $script:Relay.WaitForExit(8000)) { Stop-Proc $script:Relay } } catch {}
  }
  $script:Relay = $null
  $script:RelayIn = $null
}

# Waits a little and says so, after the connection to the server broke. $video: a video waits for it (else a screen).
function Wait-RelayRetry([bool]$video = $true) {
  $why = Get-RelayError
  $sent = $false
  try { $sent = ((Read-RelaySize) -gt 0) } catch {}
  Stop-Relay
  $sent = $sent -or $script:RelayHadSent
  $endedItself = -not $script:RelayKilled
  if ($script:HostP -and $script:HostP.Id -eq 'vps' -and (Get-Command Get-VpsRelayVerdict -CommandType Function -ErrorAction SilentlyContinue)) {
    # My VPS: the server says why (a link it doesn't know, a wrong password, another PC on the same link...).
    $verdict = $null
    try { $verdict = Get-VpsRelayVerdict $sent $endedItself } catch { if ($script:CtrlCQuit) { throw } }
    if ($verdict -and $verdict.Stop) { Say $verdict.Message 'Red'; return $false }
    if ($verdict -and $verdict.Why) { $why = $verdict.Why }
  }
  $script:RelayFails++
  if ($script:RelayFails -gt 7) {
    Say (T 'Can''t keep a connection to the stream server. Check your internet connection and try again later.') 'Red'
    if ($why) { Say "  ($(Get-ShortText $why 110))" 'DarkGray' }
    return $false
  }
  # Quick first: ProTV tries a lost stream again after about 6 seconds, once.
  $delays = @(1, 3, 5, 10, 15, 20, 30)
  $delay = $delays[[Math]::Min($script:RelayFails - 1, $delays.Count - 1)]
  if ($video) { Say (T 'Lost the connection to the stream server - reconnecting in {0} s. The video waits until the players are back.' $delay) 'Yellow' }
  else { Say (T 'Lost the connection to the stream server - reconnecting in {0} s.' $delay) 'Yellow' }
  if ($why) { Say "  ($why)" 'DarkGray' }
  $script:ReconnectNote = $true
  # The control window shows "Reconnecting" meanwhile, then what it showed before (until the next update).
  $before = $script:PanelState
  $rs = $null
  if ($script:PanelShown) {
    $rs = @{ Link = $script:ShownLink }
    if ($before) { $rs = $before.Clone() }
    $rs.Mode = 'reconnect'
    $rs.Status = T 'Lost the connection to the stream server - reconnecting in {0} s.' $delay
    $script:PanelState = $rs
  }
  try { Wait-Pump $delay } finally { if ($script:PanelShown -and $script:PanelState -eq $rs) { $script:PanelState = $before; Invoke-PanelPump } }
  return $true
}

# Sleeps, but keeps handing the control window its state meanwhile (the window itself runs on its own thread).
# End stream in the window ends the tool from here too (Test-UiQuit).
function Wait-Pump([double]$seconds) {
  $until = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $until) { Invoke-PanelPump; Test-UiQuit; Start-Sleep -Milliseconds 50 }
}

# While this thread waits (a question, a pause) the window gets its state from here.
function Invoke-PanelPump {
  if (-not $script:PanelShown) { return }
  try {
    # (While a question waits nothing else updates the window: on / off and the link follow here.)
    $s = $script:PanelState
    if ($s -and ($s.Mode -eq 'waiting' -or $s.Mode -eq 'off')) {
      $mode = 'off'
      if (Test-RelayAlive) { $mode = 'waiting' }
      if ($s.Mode -ne $mode -or $s.Link -ne $script:ShownLink) {
        $s = $s.Clone()
        $s.Mode = $mode
        $s.Link = $script:ShownLink
        $script:PanelState = $s
      }
    }
    Update-ControlPanel $script:PanelState
  } catch {}
}

# Questions in this window: the keys are read here (Read-AskLine), so the control window keeps getting its state,
# Back / Forward work, and Ctrl+C ends the tool cleanly.
$script:CtrlCQuit = $false
function Stop-ByCtrlC {
  $script:CtrlCQuit = $true
  $script:StopAll = $true
  Add-Cmd (New-Cmd 'quit')
  throw (New-Object System.OperationCanceledException (T 'Stopped (Ctrl+C).'))
}

# End stream clicked in the control window (bus.QuitReq) while this thread waits or asks: the same clean end as Ctrl+C
# (every catch that passes Ctrl+C on passes this on too). Outside questions and waits Receive-Commands takes it.
$script:QuitFromWindow = $false
function Test-UiQuit {
  $b = $script:UiBus
  if ($null -eq $b -or -not $b.QuitReq) { return }
  $b.QuitReq = $false
  $script:QuitFromWindow = $true
  $script:CtrlCQuit = $true
  $script:StopAll = $true
  Add-Cmd (New-Cmd 'quit' $null 'panel')
  throw (New-Object System.OperationCanceledException (T 'Ended from the control window.'))
}

# ------------------------------------------------------------------ the key reader
# Every question reads its answer line here. Navigation keys count only on an empty line and only where the question
# allows them (-Nav): Esc or Left = back, Right = your earlier answer again (forward), Home = leave the task.
# Esc on a line with text clears it, as always; an Esc within 400 ms of such a clear never goes back, and a held
# navigation key (auto-repeat) counts once. Backspace on an empty line does nothing.
# $script:KeySource: $null = the console. A test sets a scriptblock: & $KeySource 'avail' -> [bool] (a key waits),
# & $KeySource 'read' -> [ConsoleKeyInfo]; it throws System.IO.EndOfStreamException when it has no more keys.
$script:KeySource = $null
$script:NavKeyAhead = New-Object System.Collections.ArrayList   # keys read while dropping repeated navigation keys
$script:NavEscGuardMs = 400
$script:NavRepeatMs = 200
# A held key repeats first after the keyboard's repeat delay (Windows: 250-1000 ms, 500 by default), then every
# NavRepeatMs or less: the same navigation key again within that delay counts as held too, unless the key was seen
# let go meanwhile (Update-NavKeyUp, while the reader waits): then it is a new press.
$script:NavHoldMs = 650
try { $script:NavHoldMs = ([Math]::Min(3, [Math]::Max(0, [int](Get-ItemProperty 'HKCU:\Control Panel\Keyboard' -ErrorAction Stop).KeyboardDelay)) + 1) * 250 + 150 } catch {}
$script:NavRepeatKey = $null
$script:NavHeldUntil = [datetime]::MinValue
$script:NavKeyUp = $true
$script:NavKeyState = $null    # can the key's state be read ($null = not tried yet)

function Update-NavKeyUp {
  if ($script:NavKeyUp -or -not $script:NavRepeatKey) { return }
  if ($null -eq $script:NavKeyState) {
    $script:NavKeyState = $false
    try {
      Add-Type -Namespace VRCLinkMaker -Name KeyState -MemberDefinition '[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);'
      $script:NavKeyState = $true
    } catch {}
  }
  if (-not $script:NavKeyState) { return }
  try { if (([VRCLinkMaker.KeyState]::GetAsyncKeyState([int]$script:NavRepeatKey) -band 0x8000) -eq 0) { $script:NavKeyUp = $true } } catch {}
}

function Test-NavKeyWaiting {
  if ($script:NavKeyAhead.Count -gt 0) { return $true }
  if ($script:KeySource) { return [bool](& $script:KeySource 'avail') }
  return [Console]::KeyAvailable
}

function Read-NavKey {
  if ($script:NavKeyAhead.Count -gt 0) { $k = $script:NavKeyAhead[0]; $script:NavKeyAhead.RemoveAt(0); return $k }
  if ($script:KeySource) { return (& $script:KeySource 'read') }
  while (-not [Console]::KeyAvailable) { Invoke-PanelPump; Update-NavKeyUp; Update-AskLeases; Start-Sleep -Milliseconds 40 }
  return [Console]::ReadKey($true)
}

# Ctrl+C as a key. Not AltGr+C (Windows sends AltGr as Ctrl+Alt: e.g. a Polish c with an accent).
function Test-CtrlCKey($k) {
  return ($k.Key -eq [ConsoleKey]::C -and ($k.Modifiers -band [ConsoleModifiers]::Control) -and -not ($k.Modifiers -band [ConsoleModifiers]::Alt))
}

# Takes $n typed characters off the screen, also back over a wrapped line (a backspace stops at the row's start).
function Remove-AskEcho([int]$n) {
  if ($n -le 0) { return }
  if ($script:HasConsole -and -not $script:KeySource) {
    try {
      $w = [Console]::BufferWidth
      $pos = [Console]::CursorTop * $w + [Console]::CursorLeft - $n
      if ($w -gt 0 -and $pos -ge 0) {
        $l = $pos % $w
        $t = [int][Math]::Floor($pos / $w)
        [Console]::SetCursorPosition($l, $t)
        Write-Host (' ' * $n) -NoNewline
        [Console]::SetCursorPosition($l, $t)
        return
      }
    } catch {}
  }
  Write-Host (([string][char]8 + ' ' + [string][char]8) * $n) -NoNewline
}

# Writes the prompt or typed text. Text that ends exactly at the right edge leaves the cursor in the last column until
# the next character comes (VT consoles): it is put at the next row's start here, as older consoles do, so that
# Remove-AskEcho counts back from the right cell.
function Write-AskEcho([string]$s) {
  $l0 = -1
  if ($script:HasConsole -and -not $script:KeySource) { try { $l0 = [Console]::CursorLeft } catch {} }
  Write-Host $s -NoNewline
  if ($l0 -lt 0) { return }
  try {
    $nl = $s.LastIndexOf("`n")
    if ($nl -ge 0) { $l0 = 0; $s = $s.Substring($nl + 1) }
    $w = [Console]::BufferWidth
    if ($w -gt 0 -and $s.Length -gt 0 -and ($l0 + $s.Length) % $w -eq 0 -and [Console]::CursorLeft -ne 0) {
      if ([Console]::CursorTop + 1 -lt [Console]::BufferHeight) { [Console]::SetCursorPosition(0, [Console]::CursorTop + 1) }
      else { Write-Host '' }
    }
  } catch {}
}

function Test-NavKey($k) {
  $c = $k.Key
  return ($c -eq [ConsoleKey]::Escape -or $c -eq [ConsoleKey]::LeftArrow -or $c -eq [ConsoleKey]::RightArrow -or $c -eq [ConsoleKey]::Home)
}

# After a Back / Forward / Home: the Esc / Left / Right / Home presses still waiting (a held key) are thrown away.
function Clear-NavRepeat {
  try {
    while (Test-NavKeyWaiting) {
      $k = Read-NavKey
      if (Test-NavKey $k) {
        $t = (Get-Date).AddMilliseconds($script:NavRepeatMs)
        if ($t -gt $script:NavHeldUntil) { $script:NavHeldUntil = $t }
        continue
      }
      [void]$script:NavKeyAhead.Insert(0, $k)
      break
    }
  } catch {}
}

# Reads one answer line -> @{ Nav = '' | 'back' | 'forward' | 'home'; Text; From }. -Prefill: text already typed
# (editable). -Secret: the typed characters show as '*'. -Ask: the question as the control window has it (Publish-UiAsk):
# its answer there counts too, the first one wins (From = that answer, see Wait-AskInput; the typing here is dropped),
# and with a Deadline the time limit too (From.Timeout).
function Read-AskLine([string]$Prompt = '', [string]$Prefill = '', [switch]$Nav, [switch]$Secret, $Ask = $null) {
  $out = @{ Nav = ''; Text = ''; From = $null }
  $wait = ($null -ne $Ask -and (($script:PanelShown -and $null -ne $script:UiBus) -or $Ask.Deadline))
  $got = $null
  # Before the control window opens, Ctrl+C at a question works as usual (it ends the tool), also while the stream
  # reads keys itself. With the control window open it arrives here as a key: a clean stop.
  $ctrlKey = $false
  if (-not $script:PanelShown -and -not $script:KeySource) {
    try { $ctrlKey = ($script:HasConsole -and [Console]::TreatControlCAsInput) } catch {}
    if ($ctrlKey) { Set-CtrlCAsKey $false }
  } elseif ($script:CtrlCQuit) { throw (New-Object System.OperationCanceledException (T 'Stopped (Ctrl+C).')) }
  try {
    Clear-StatusLine
    if ($Prompt) { Write-AskEcho ($Prompt + ': ') }
    $sb = New-Object System.Text.StringBuilder
    if ($Prefill -and -not $Secret) { [void]$sb.Append($Prefill); Write-AskEcho $Prefill }
    $clearedAt = [datetime]::MinValue
    while ($true) {
      $k = $null
      if ($wait) {
        $got = Wait-AskInput $Ask
        if ($got) { break }
      }
      try { $k = Read-NavKey }
      catch [System.IO.EndOfStreamException] { throw }
      catch { break }
      if ($k.Key -eq [ConsoleKey]::Enter) { break }
      if (Test-CtrlCKey $k) { Write-Host ''; Stop-ByCtrlC }
      $now = Get-Date
      if ($Nav -and (Test-NavKey $k)) {
        $held = ($script:NavRepeatMs -gt 0 -and $k.Key -eq $script:NavRepeatKey -and $now -lt $script:NavHeldUntil -and -not $script:NavKeyUp)
        $script:NavRepeatKey = $k.Key
        $script:NavKeyUp = $false
        $script:NavHeldUntil = $now.AddMilliseconds($(if ($held) { $script:NavRepeatMs } else { $script:NavHoldMs }))
        if ($held) { continue }
      }
      if ($k.Key -eq [ConsoleKey]::Backspace) {
        if ($sb.Length -gt 0) { $sb.Length = $sb.Length - 1; Remove-AskEcho 1 }
        continue
      }
      if ($k.Key -eq [ConsoleKey]::Escape) {
        if ($sb.Length -gt 0) {
          Remove-AskEcho $sb.Length
          $sb.Length = 0
          $clearedAt = $now
          continue
        }
        if ($Nav -and ($now - $clearedAt).TotalMilliseconds -ge $script:NavEscGuardMs) { $out.Nav = 'back'; break }
        continue
      }
      if ($Nav -and $sb.Length -eq 0) {
        if ($k.Key -eq [ConsoleKey]::LeftArrow) { $out.Nav = 'back'; break }
        if ($k.Key -eq [ConsoleKey]::RightArrow) { $out.Nav = 'forward'; break }
        if ($k.Key -eq [ConsoleKey]::Home) { $out.Nav = 'home'; break }
      }
      if ([int]$k.KeyChar -ge 32) {
        # (A paste or dropped files arrive as many keys at once: they are echoed in one go.)
        $chunk = New-Object System.Text.StringBuilder
        [void]$chunk.Append($k.KeyChar)
        while (Test-NavKeyWaiting) {
          $k2 = Read-NavKey
          if ([int]$k2.KeyChar -lt 32 -or ($k2.Modifiers -band [ConsoleModifiers]::Control)) { [void]$script:NavKeyAhead.Insert(0, $k2); break }
          [void]$chunk.Append($k2.KeyChar)
        }
        [void]$sb.Append($chunk.ToString())
        if ($Secret) { Write-AskEcho ('*' * $chunk.Length) } else { Write-AskEcho $chunk.ToString() }
      }
    }
    if ($got) {
      # (Answered in the window, or no answer in time: what was typed here goes.)
      if ($sb.Length -gt 0) { Remove-AskEcho $sb.Length }
      if ($got.Timeout) { Write-Host (T '(no answer)') -ForegroundColor DarkGray } else { Write-Host (T '(answered in the window)') -ForegroundColor DarkGray }
      $out.Nav = [string]$got.Nav
      $out.Text = [string]$got.Text
      $out.From = $got
    } else {
      Write-Host ''
      $out.Text = $sb.ToString()
      if ($out.Nav) { $out.Text = ''; Clear-NavRepeat }
    }
  } finally { if ($ctrlKey) { Set-CtrlCAsKey $true } }
  return $out
}

# Until a key waits in the console: the control window's answer to $Ask (by its Id; answers to older questions are
# dropped), End stream in the window (Test-UiQuit), or the Ask's time limit -> that answer
# (@{ Window = $true; Nav; Text; Pick; Yes; Files; Prefilled }, or @{ Timeout = $true }), $null = a key waits.
# Meanwhile the window gets its state and the router keeps this PC's port forwards (Update-AskLeases).
function Wait-AskInput($Ask) {
  $win = ($script:PanelShown -and $null -ne $script:UiBus)
  while (-not (Test-NavKeyWaiting)) {
    if ($win) {
      $w = Receive-UiAnswer ([string]$Ask.Id)
      if ($w) { return $w }
    }
    Test-UiQuit
    if ($Ask.Deadline -and [DateTime]::UtcNow -ge [DateTime]$Ask.Deadline) { return @{ Timeout = $true; Nav = ''; Text = '' } }
    Invoke-PanelPump
    Update-NavKeyUp
    Update-AskLeases
    Start-Sleep -Milliseconds 40
  }
  return $null
}

# The window's answer to the question with this Id, or $null. Answers to other (older) questions are dropped.
function Receive-UiAnswer([string]$id) {
  $b = $script:UiBus
  if ($null -eq $b -or $null -eq $b.Answers) { return $null }
  $x = $null
  while ($b.Answers.TryDequeue([ref]$x)) {
    try {
      if ($null -eq $x -or [string]$x['Id'] -cne $id) { continue }
      $nav = [string]$x['Nav']
      if (@('', 'back', 'forward', 'home') -notcontains $nav) { continue }
      $files = $null
      if ($null -ne $x['Files']) { $files = [string[]]@(@($x['Files']) | ForEach-Object { [string]$_ } | Where-Object { $_ -and $_.Trim() }) }
      return @{ Window = $true; Nav = $nav; Text = [string]$x['Text']; Pick = $x['Pick']; Yes = $x['Yes']; Files = $files; Prefilled = [bool]$x['Prefilled'] }
    } catch {}
  }
  return $null
}

# The router's lease on this PC's port forwards (This PC) is renewed from a long question too (a look at most every 2 s).
$script:AskLeaseAt = [DateTime]::MinValue
function Update-AskLeases {
  $now = [DateTime]::UtcNow
  if ($now -lt $script:AskLeaseAt) { return }
  $script:AskLeaseAt = $now.AddSeconds(2)
  try { Update-UpnpLeases } catch {}
}

# The question the control window shows (bus.Ask), a copy of the Ask: Id, Kind, Title (a yes / no question without
# its "[Y/n]"), Options / AllowNone / NoneLabel (choice), Default (what Enter gives: an index, a bool), Prev (your
# earlier answer: index / bool; never a text), Crumb, BackMode ('back' | 'leave' | 'esc' | 'saved' | ''), CanBack,
# BackLabel, CanHome (Cancel leaves the task), EscLabel (what Esc gives on a one-off question), CanForward, Secret,
# Prefill (a text: your earlier one, never a secret; episodes: the suggested range; All = every episode) and Deadline
# (UTC, or $null). Answers still waiting from before are dropped. Returns the copy (Read-AskLine waits on it).
function Publish-UiAsk($a, [bool]$canHome = $false) {
  $kind = [string]$a.Kind
  $title = [string]$a.Title
  if (-not $title) { $title = [string]$a.Prompt }
  if ($kind -eq 'yesno') { $title = $title -replace '\s*\[[^\[\]]{1,8}/[^\[\]]{1,8}\]\s*:?\s*$', '' }
  $v = @{ Id = [string]$a.Id; Kind = $kind; Title = $title.Trim(); Options = [string[]]@(); AllowNone = $false; NoneLabel = ''; Default = $null
    Prev = $null; Crumb = ([string]$a.Crumb).Trim(); BackMode = [string]$a.BackMode; CanBack = [bool]$a.CanBack; BackLabel = [string]$a.BackLabel
    CanHome = $canHome; EscLabel = ''; CanForward = [bool]$a.CanForward; Secret = [bool]$a.Secret; Prefill = ''; All = ''; Deadline = $a.Deadline; TimeoutLabel = '' }
  if ($a.TimeoutEsc) { try { $v.TimeoutLabel = [string](Get-AskEscValue $a).Label } catch {} }
  if ($a.BackMode -eq 'esc') { try { $v.EscLabel = [string](Get-AskEscValue $a).Label } catch {} }
  if ($kind -eq 'choice') {
    $v.Options = [string[]]@(@($a.Options) | ForEach-Object { [string]$_ })
    $v.AllowNone = [bool]$a.AllowNone
    if ($a.AllowNone) {
      $l = T '   0) None'
      if ($a.NoneLabel) { $l = [string]$a.NoneLabel }
      $v.NoneLabel = ($l -replace '^\s*0\)\s*', '').Trim()
    }
    $v.Default = [int]$a.Default
    if ($a.Prev) {
      $v.Prev = [int]$a.Prev.Result
      if (-not $a.EnterDefault) { $v.Default = [int]$a.Prev.Result }
    }
  } elseif ($kind -eq 'yesno') {
    $v.Default = [bool]$a.DefaultYes
    if ($a.Prev) { $v.Prev = [bool]$a.Prev.Result; $v.Default = [bool]$a.Prev.Result }
  } elseif ($kind -eq 'text') {
    if ($a.Prev -and -not $a.Secret -and -not $a.Private) { $v.Prefill = [string]$a.Prev.Stored }
  } elseif ($kind -eq 'episodes') {
    $l = @($a.List)
    if ($l.Count -gt 0) {
      $last = [string]$l[$l.Count - 1].Number
      $dp = [int]$a.DefPos
      if ($dp -lt 0 -or $dp -ge $l.Count) { $dp = 0 }
      $v.All = ([string]$l[0].Number) + '-' + $last
      $v.Prefill = ([string]$l[$dp].Number) + '-' + $last
    }
    if ($a.Prev -and [string]$a.Prev.Stored) { $v.Prefill = [string]$a.Prev.Stored }
  }
  $b = $script:UiBus
  if ($b) {
    $x = $null
    while ($b.Answers.TryDequeue([ref]$x)) {}
    $b.Ask = $v
  }
  return $v
}

# The question with this Id ended (answered, Back, Ctrl+C, End stream): the window's strip closes.
function Clear-UiAsk([string]$id) {
  $b = $script:UiBus
  try { if ($b -and $b.Ask -and [string]$b.Ask.Id -ceq $id) { $b.Ask = $null } } catch {}
}

# A question from the waiting screen's preparation while the stream is on the air (Select-Tracks, the player, a yt-dlp
# install asked meanwhile: $script:PrepAsk) takes its suggested answer after "AskTimeoutSec" (config.json; 60, 0 = never)
# seconds: whoever is in VR isn't kept waiting. Startup and menu questions wait as long as it takes. -> seconds, 0 = none.
$script:PrepAsk = $false
$script:AskTimeouts = 0   # questions that took their answer by themselves (Read-AskAnswer)
function Get-AskTimeout {
  if (-not $script:PrepAsk -or -not (Test-RelayAlive)) { return 0 }
  return [int](Get-NumSetting 'AskTimeoutSec' 60 0 86400)
}

# Read-Host everywhere in the tool (also in Sites / Hosts / Update): the key reader above when there is a console, so
# the keys are the same before and after the control window opens and in a second window. Without a console
# (redirected input) the plain line reader.
function Read-Host {
  param([Parameter(Position = 0)][object]$Prompt)
  if ($script:HasConsole -or $script:KeySource) {
    $p = ''
    if ($null -ne $Prompt) { $p = "$Prompt" }
    return (Read-AskLine $p).Text
  }
  if ($null -ne $Prompt) { return (Microsoft.PowerShell.Utility\Read-Host -Prompt $Prompt) }
  return (Microsoft.PowerShell.Utility\Read-Host)
}

# ------------------------------------------------------------------ questions with Back / Forward (Ask, flows)
# Every question (Read-Choice, Read-EpisodeSelection, Read-YesNoUi, Read-HostLine) is an "Ask" (New-NavAsk) that
# Invoke-Ask draws and reads. The Ask is what the control window will show too (G4 bus.Ask): Id, Kind (choice |
# episodes | yesno | text), Title, Options, Values, Default, Prev (your earlier answer), Crumb, CanBack, BackLabel,
# EscValue, CanForward, Secret. A reply (a console line, later a window button) is @{ Nav = '' | 'back' | 'forward' |
# 'home'; Text }; Resolve-AskReply is the one place that turns it into an answer.
#
# A task with several questions runs as a flow (Invoke-NavFlow):
#   $r = Invoke-NavFlow -Name 'search' -Origin start -Snap DubChoice, DubPref -Body { ...questions... }
#   $r.Nav = '' (the body finished, $r.Value = what it returned), 'leave' (Back at its first question) or 'home'.
# Back re-runs the body from its start with the answers it already has (the tape): those questions answer themselves
# silently (Say only writes log.txt meanwhile) and the earlier question is asked again, your answer marked; Enter
# keeps it. Before every re-run the named $script: variables, the queue and (-Cfg) the config are put back as they
# were at the start, and Invoke-Web / Use-NavMemo hand back what they fetched before, so a re-run is instant.
# Lock-NavStep marks a step that can't be undone (saved, imported, written): no Back crosses it, and the questions
# after it act as one-off questions. A flow started inside an open (not locked) flow joins it; after a lock, or
# outside any flow, it gets its own frame. One-off questions (no flow): Esc gives the safe answer (-Esc) or nothing.
$script:Nav = $null            # the innermost open flow frame
$script:NavSignal = ''         # 'back' / 'leave' / 'home' while a navigation unwinds; sticky until its flow takes it
$script:NavSignalFrame = $null
$script:NavAskSeq = 0
$script:NavPass = 0          # counts the runs of flow bodies (Invoke-NavFlow): a re-run is a new pass
# The session answers the search / site questions set (Invoke-NavFlow -Snap): put back when a flow goes back or is left.
$script:SiteAnswerVars = @('DubChoice', 'DubPref', 'LastDub', 'LastEps', 'LastPart', 'LastPlayer', 'LastSearchLink', 'SiteChoice')

function New-NavCancel { return (New-Object System.OperationCanceledException 'vrclm-nav') }

# Leaves the open flow (like Esc at its first question), e.g. "0 = none of these" in the search list. Outside a flow,
# or after its Lock-NavStep, it does nothing (the caller then goes on as before).
function Exit-NavFlow {
  $f = $script:Nav
  if (-not $f -or $f.Sealed -or $f.Own) { return }
  Set-NavSignal 'leave' $f
  throw (New-NavCancel)
}

# Ctrl+C or a Back / Home on its way out: a catch around a question must pass these on (throw).
function Test-NavAbort { return ([bool]$script:CtrlCQuit -or [bool]$script:NavSignal) }

function Set-NavSignal([string]$sig, $frame) {
  $script:NavSignal = $sig
  $script:NavSignalFrame = $frame
}

function Test-NavSealed {
  $f = $script:Nav
  while ($f) { if ($f.Sealed) { return $true }; $f = $f.Parent }
  return $false
}

function Get-NavRoot {
  $f = $script:Nav
  if (-not $f) { return $null }
  while ($f.Parent) { $f = $f.Parent }
  return $f
}

# May a memo entry (Invoke-Web / Use-NavMemo) answer now? Not after its -Seconds, and a failure not in the run
# (pass) that got it: there the caller's own "try once more" must reach the network, as outside a flow.
function Test-NavMemoUse($hit) {
  if ($null -ne $hit.Until -and (Get-Date) -ge $hit.Until) { return $false }
  if ($hit.Fail -and $hit.Pass -eq $script:NavPass) { return $false }
  return $true
}

function New-NavAsk([string]$Kind, [string]$Title = '', [string]$Key = '') {
  return @{ Id = ''; Kind = $Kind; Key = $Key; CheckKey = ''; Title = $Title; Prompt = ''; Options = @(); Values = $null
    Default = $null; AllowNone = $false; NoneLabel = ''; List = $null; DefPos = 0; DefaultYes = $true; Secret = $false; Private = $false
    HasEsc = $false; EscValue = $null; Prev = $null; Crumb = ''; BackMode = ''; CanBack = $false; BackLabel = ''
    CanForward = $false; NavOn = $false; RedoHit = $false; EnterDefault = $false }
}

# The check key: replay gives a stored answer only to the same question (its title and its options; with -Values
# the stored value itself must still be among the values, wherever it is now).
function Get-AskCheckKey($a) {
  $k = [string]$a.Key + '|' + $a.Kind + '|' + [string]$a.Title
  if ($a.Kind -eq 'choice') {
    $k += '|' + [string]$a.AllowNone
    if ($null -eq $a.Values) { $k += '|' + (@($a.Options) -join [string][char]31) }
  }
  elseif ($a.Kind -eq 'episodes') { $k += '|' + (@($a.List | ForEach-Object { [string]$_.Number }) -join ',') }
  else { $k += '|' + [string]$a.Prompt }
  return $k
}

function Get-NavShort([string]$s, [int]$max = 40) {
  $s = ($s -replace '\s+', ' ').Trim()
  if ($s.Length -gt $max) { $s = $s.Substring(0, $max - 3) + '...' }
  return $s
}

function Get-NavRootLabel([string]$origin) {
  if ($origin -eq 'waiting') { return (T 'Waiting screen') }
  if ($origin -eq 'menu') { return (T 'Settings') }
  if ($origin -eq 'addwin') { return (T 'Add window') }
  return (T 'Start')
}

# "  Start > Frieren > Season 2 > AniLibria", cut from the left to the window's width; secrets show as ***.
function Get-NavCrumb($f, [int]$count = -1) {
  $parts = @(Get-NavRootLabel $f.Origin)
  if ($count -lt 0) { $count = $f.Tape.Count }
  for ($i = 0; $i -lt $count; $i++) {
    $e = $f.Tape[$i]
    if ($e.Secret) { $parts += '***' } else { $parts += (Get-NavShort ([string]$e.Label)) }
  }
  $s = '  ' + ($parts -join ' > ')
  $w = Get-ConsoleWidth
  if ($s.Length -gt $w) { $s = '  ...' + $s.Substring($s.Length - ($w - 5)) }
  return $s
}

function Show-NavHint([string]$text) { if ($text) { Say $text 'DarkGray' } }

# Episodes from typed text ('' = from $defPos to the end): "5", "3-8", "3-", "1,4 7", en / em dashes, decimals.
function ConvertFrom-EpisodeText($list, [int]$defPos, [string]$ans) {
  if (-not $ans -or -not $ans.Trim()) { return @($list[$defPos..($list.Count - 1)]) }
  $ans = $ans -replace '\s*[-\u2013\u2014]\s*', '-'   # "3 - 8" means 3-8
  $pick = New-Object System.Collections.ArrayList
  foreach ($part in ($ans -split '[,; ]+')) {
    if (-not $part) { continue }
    $lo = $null; $hi = $null
    if ($part -match '^(\d+(?:\.\d+)?)\s*-\s*(\d+(?:\.\d+)?)?$') {
      $lo = [double]::Parse($matches[1], $script:Inv)
      if ($matches[2]) { $hi = [double]::Parse($matches[2], $script:Inv) } else { $hi = [double]::MaxValue }
    } elseif ($part -match '^\d+(?:\.\d+)?$') { $lo = [double]::Parse($part, $script:Inv); $hi = $lo }
    else { continue }
    foreach ($e in $list) {
      $n = 0.0
      if ([double]::TryParse([string]$e.Number, [System.Globalization.NumberStyles]::Float, $script:Inv, [ref]$n) -and $n -ge $lo -and $n -le $hi -and -not $pick.Contains($e)) { [void]$pick.Add($e) }
    }
  }
  return $pick.ToArray()
}

function Get-EpisodeDefaultText($list, [int]$defPos) {
  if ($defPos -gt 0) { return "$($list[$defPos].Number)-$($list[$list.Count - 1].Number)" }
  return (T 'all {0}' $list.Count)
}

function Get-ChoiceLabel($a, [int]$i) {
  # (Without the markers after 3 spaces: '   <- auto (just Enter)', '   (preferred)', '   [default]'.)
  if ($i -ge 0 -and $i -lt @($a.Options).Count) { return ([string]@($a.Options)[$i] -replace ' {3,}\S.*$', '') }
  if ($a.NoneLabel) { return ([string]$a.NoneLabel -replace '^\s*0\)\s*', '') }
  return ((T '   0) None') -replace '^\s*0\)\s*', '')
}

# An answer -> @{ Act = 'value'; Result (what the question returns); Stored (what the tape keeps); Label (crumb) }.
function Get-AskValue($a, $result, [string]$typed = '') {
  $r = @{ Act = 'value'; Result = $result; Stored = $result; Label = '' }
  if ($a.Kind -eq 'choice') {
    $i = [int]$result
    $r.Result = $i
    $r.Stored = $i
    if ($null -ne $a.Values) { if ($i -ge 0) { $r.Stored = [string]@($a.Values)[$i] } else { $r.Stored = [string][char]0 + 'none' } }
    $r.Label = Get-ChoiceLabel $a $i
  } elseif ($a.Kind -eq 'episodes') {
    $r.Stored = $typed.Trim()
    $r.Label = $r.Stored
    if (-not $r.Label) { $r.Label = Get-EpisodeDefaultText $a.List $a.DefPos }
  } elseif ($a.Kind -eq 'yesno') {
    $r.Result = [bool]$result
    $r.Stored = [bool]$result
    if ($result) { $r.Label = T 'yes' } else { $r.Label = T 'no' }
  } else {
    $r.Result = [string]$result
    $r.Stored = [string]$result
    $r.Label = [string]$result
  }
  return $r
}

# A stored answer (tape / earlier answer) for this question -> @{ Ok; Result; Stored; Label }. Not Ok = it doesn't
# fit this question any more (the options changed): then it is asked.
function ConvertFrom-AskValue($a, $stored) {
  $bad = @{ Ok = $false }
  if ($a.Kind -eq 'choice') {
    $i = -2
    if ($null -ne $a.Values) {
      if ([string]$stored -ceq ([string][char]0 + 'none')) { $i = -1 }
      else { $vals = @($a.Values); for ($j = 0; $j -lt $vals.Count; $j++) { if ([string]$vals[$j] -ceq [string]$stored) { $i = $j; break } } }
    } else { $n = 0; if ([int]::TryParse([string]$stored, [ref]$n)) { $i = $n } }
    $ok = ($i -ge 0 -and $i -lt @($a.Options).Count) -or ($i -eq -1 -and ($a.AllowNone -or $a.Default -eq -1))
    if (-not $ok) { return $bad }
    $r = Get-AskValue $a $i
  } elseif ($a.Kind -eq 'episodes') {
    $p = @(ConvertFrom-EpisodeText $a.List $a.DefPos ([string]$stored))
    if ($p.Count -eq 0) { return $bad }
    $r = Get-AskValue $a $p ([string]$stored)
  } elseif ($a.Kind -eq 'yesno') {
    if ($stored -isnot [bool]) { return $bad }
    $r = Get-AskValue $a $stored
  } else {
    $r = Get-AskValue $a ([string]$stored)
  }
  $r.Ok = $true
  return $r
}

function Get-AskEscValue($a) {
  if ($a.Kind -eq 'episodes') { return (Get-AskValue $a @(ConvertFrom-EpisodeText $a.List $a.DefPos '') '') }
  return (Get-AskValue $a $a.EscValue)
}

# Does '0' mean Back / Cancel in this list (shown as its first line)? Only where 0 isn't an answer already.
function Test-AskZeroBack($a) {
  return ($a.Kind -eq 'choice' -and -not $a.AllowNone -and ($a.BackMode -eq 'back' -or $a.BackMode -eq 'leave'))
}

function Get-AskEscHint($a) {
  if ($a.BackMode -eq 'back') { return (T '  (Esc = back)') }
  if ($a.BackMode -eq 'leave') { return (T '  (Esc = cancel)') }
  return ''
}

function Get-AskMarks($a, [int]$i) {
  $s = ''
  if ($a.Prev -and [int]$a.Prev.Result -eq $i) { $s += T '   <- your answer' }
  if ($a.BackMode -eq 'esc' -and $null -ne $a.EscValue -and [int]$a.EscValue -eq $i) { $s += T '   <- Esc' }
  return $s
}

# Draws the question: the path so far, the title, the options (with "0) Back" and the markers) and the Esc hint.
function Show-AskBody($a) {
  if ($a.Crumb) { Show-NavHint $a.Crumb }
  $nav = ($a.BackMode -eq 'back' -or $a.BackMode -eq 'leave')
  if ($a.Kind -eq 'choice') {
    Say $a.Title 'Cyan'
    $zero = Test-AskZeroBack $a
    if ($zero) {
      if ($a.BackMode -eq 'back') { Say (T '   0) Back (or Esc)') } else { Say (T '   0) Cancel (or Esc)') }
    } elseif ($a.AllowNone) {
      $l = T '   0) None'
      if ($a.NoneLabel) { $l = [string]$a.NoneLabel }
      Say ($l + (Get-AskMarks $a -1))
    }
    $opts = @($a.Options)
    for ($i = 0; $i -lt $opts.Count; $i++) { Say (('   {0}) {1}' -f ($i + 1), $opts[$i]) + (Get-AskMarks $a $i)) }
    if ($nav -and -not $zero -and -not ($a.AllowNone -and $a.NoneLabel)) { Show-NavHint (Get-AskEscHint $a) }   # (a NoneLabel says it)
  } elseif ($a.Kind -eq 'episodes') {
    Say $a.Title 'Cyan'
    if ($nav) { Show-NavHint (Get-AskEscHint $a) }
  } elseif ($a.Kind -eq 'yesno') {
    if ($nav -and $a.Prev) {
      $yn = T 'no'
      if ($a.Prev.Result) { $yn = T 'yes' }
      Show-NavHint (T '  (Esc = back; just Enter = {0} as before)' $yn)
    } elseif ($nav) { Show-NavHint (Get-AskEscHint $a) }
    elseif ($a.BackMode -eq 'esc' -and $a.EscValue -eq $false) { Show-NavHint (T '  (Esc = no)') }
  } else {
    if ($nav -and $a.Prev -and ($a.Secret -or $a.Private)) { Show-NavHint (T '  (Esc = back; Right arrow = what you typed before)') }
    elseif ($nav) { Show-NavHint (Get-AskEscHint $a) }
    elseif ($a.BackMode -eq 'esc') { Show-NavHint (T '  (Esc = cancel)') }
  }
}

function Get-AskPrompt($a) {
  if ($a.Kind -eq 'choice') {
    $n = [int]$a.Default
    if ($a.Prev -and -not $a.EnterDefault) { $n = [int]$a.Prev.Result }
    $lab = '0'
    if ($n -ge 0) { $lab = "$($n + 1)" }
    return (T 'Type a number and press Enter (just Enter = {0})' $lab)
  }
  if ($a.Kind -eq 'episodes') {
    $d = Get-EpisodeDefaultText $a.List $a.DefPos
    if ($a.Prev) { $d = T '{0}, as before' $a.Prev.Label }
    return (T 'Type and press Enter (just Enter = {0})' $d)
  }
  return [string]$a.Prompt
}

# One reply: the console's key reader (where the control window's answer counts too: Window, with Pick / Yes), or (no
# console) the plain line reader, where a typed '<' / '>' means Back / Forward. Timeout: no answer in time (= Enter).
function Read-AskReply($a) {
  $prompt = Get-AskPrompt $a
  if ($script:HasConsole -or $script:KeySource) {
    $pre = ''
    if ($a.Kind -eq 'text' -and $a.Prev -and -not $a.Secret -and -not $a.Private) { $pre = [string]$a.Prev.Stored }
    $r = Read-AskLine $prompt $pre -Nav:([bool]$a.NavOn) -Secret:([bool]$a.Secret) -Ask $a.View
    $g = $r.From
    if ($g -and $g.Timeout) { return @{ Nav = ''; Text = ''; Typed = $false; Prefilled = $false; Timeout = $true } }
    if ($g) { return @{ Nav = $r.Nav; Text = $r.Text; Typed = $false; Prefilled = [bool]$g.Prefilled; Window = $true; Pick = $g.Pick; Yes = $g.Yes } }
    return @{ Nav = $r.Nav; Text = $r.Text; Typed = $false; Prefilled = [bool]$pre }
  }
  $t = Read-Host $prompt
  return @{ Nav = ''; Text = [string]$t; Typed = $true; Prefilled = $false }
}

# A reply -> @{ Act = 'value' | 'back' | 'forward' | 'home' | 'again'; ... }. Typed answers give exactly what they gave
# before; the typed back words (b, back, the Cyrillic i = the B key on a Russian layout, "nazad") count only in number,
# episode and yes/no questions where Back means something, and before the yes/no testers ("nazad" starts with "n").
function Resolve-AskReply($a, $reply) {
  if ($reply.Nav) { return @{ Act = [string]$reply.Nav } }
  # (The window says which one: an option's index, -1 = "0) None"; yes / no explicitly. Its texts come as typed.)
  if ($reply.Window -and $a.Kind -eq 'choice' -and $null -ne $reply.Pick) {
    $i = -2
    try { $i = [int]$reply.Pick } catch {}
    if (($i -ge 0 -and $i -lt @($a.Options).Count) -or ($i -eq -1 -and ($a.AllowNone -or $a.Default -eq -1))) { return (Get-AskValue $a $i) }
    return @{ Act = 'again'; Msg = '' }
  }
  if ($reply.Window -and $a.Kind -eq 'yesno' -and $null -ne $reply.Yes) { return (Get-AskValue $a ([bool]$reply.Yes)) }
  $t = [string]$reply.Text
  $tt = $t.Trim()
  if ($reply.Typed -and $a.NavOn) {
    if ($tt -eq '<') { return @{ Act = 'back' } }
    if ($tt -eq '>') { return @{ Act = 'forward' } }
  }
  if ($a.Kind -ne 'text' -and $a.BackMode -and $tt -match '^(?i)(?:b|back|\u0438|\u043d\u0430\u0437\u0430\u0434)$') { return @{ Act = 'back' } }
  # (Just Enter = the earlier answer, except where Enter has its own meaning: a hidden text answer's empty answer
  # ('keep the saved one' / 'skip'; Right arrow gives the earlier one) and -EnterDefault lists like the settings menu.)
  $hidden = ($a.Kind -eq 'text' -and ($a.Secret -or $a.Private))
  if (-not $tt -and $a.Prev -and -not $reply.Prefilled -and -not $hidden -and -not $a.EnterDefault) { $r = $a.Prev.Clone(); $r.Act = 'value'; return $r }
  if ($a.Kind -eq 'choice') {
    if (-not $tt) { return (Get-AskValue $a ([int]$a.Default)) }
    $n = 0
    if ([int]::TryParse($tt, [ref]$n)) {
      if ($n -eq 0 -and (Test-AskZeroBack $a)) { return @{ Act = 'back' } }
      if ($a.AllowNone -and $n -eq 0) { return (Get-AskValue $a (-1)) }
      if ($n -ge 1 -and $n -le @($a.Options).Count) { return (Get-AskValue $a ($n - 1)) }
    }
    return @{ Act = 'again'; Msg = (T '   Please type one of the numbers above.') }
  }
  if ($a.Kind -eq 'episodes') {
    $p = @(ConvertFrom-EpisodeText $a.List $a.DefPos $t)
    if ($p.Count -gt 0) { return (Get-AskValue $a $p $t) }
    return @{ Act = 'again'; Msg = (T '   Please type episode numbers from the list.') }
  }
  if ($a.Kind -eq 'yesno') {
    if ($a.DefaultYes) { return (Get-AskValue $a (-not (Test-AnswerNo $t))) }
    return (Get-AskValue $a ([bool](Test-AnswerYes $t)))
  }
  return (Get-AskValue $a $t)
}

function Add-NavTape($f, $a, $res) {
  $e = @{ Key = $a.CheckKey; Value = $res.Stored; Label = $res.Label; Secret = ([bool]$a.Secret -or [bool]$a.Private); Kind = $a.Kind }
  # The earlier answers ahead (Forward): this question's is used up, the later ones stay as suggestions even when this
  # answer changed (each is offered only to the same question with a value that still fits, see Invoke-Ask). A
  # question that had none ahead means the flow went another way: the rest is dropped.
  if ($f.Redo.Count -gt 0) {
    if ($a.RedoHit) { $f.Redo.RemoveAt(0) } else { $f.Redo.Clear() }
  }
  $n = $f.Tape.Count
  # A text question asked again right away (the answer didn't fit) keeps one entry.
  if ($a.Kind -eq 'text' -and $n -gt 0 -and $f.Tape[$n - 1].Kind -eq 'text' -and $f.Tape[$n - 1].Key -ceq $e.Key) { $f.Tape[$n - 1] = $e }
  else { [void]$f.Tape.Add($e) }
  $f.Pos = $f.Tape.Count
}

# A question that can't come again once answered (e.g. downloading rqbit): its answer, the last one on the open flow's
# tape, leaves it, so a Back skips it instead of stopping the replay there. (Not Lock-NavStep: the questions after it
# can still go back.)
function Remove-NavTapeStep([string]$Key) {
  $f = $script:Nav
  if (-not $f -or $f.Sealed) { return }
  $n = $f.Tape.Count
  if ($n -gt 0 -and ([string]$f.Tape[$n - 1].Key).StartsWith($Key + '|', [System.StringComparison]::Ordinal)) {
    $f.Tape.RemoveAt($n - 1)
    $f.Pos = $f.Tape.Count
  }
}

# The one place that asks. Returns the answer (choice: 0-based index or -1; episodes: the list items; yesno: bool;
# text: the string). Inside a flow: replays the tape, records the answer, and throws for Back / Home.
function Invoke-Ask($a) {
  if ($script:NavSignal) { throw (New-NavCancel) }
  $f = $script:Nav
  $step = ($null -ne $f -and -not $f.Sealed)
  $a.CheckKey = Get-AskCheckKey $a
  $script:NavAskSeq++
  $a.Id = 'm' + $script:NavAskSeq
  if ($step -and $f.Pos -lt $f.Target) {
    $e = $f.Tape[$f.Pos]
    if ($e.Key -ceq $a.CheckKey) {
      $r = ConvertFrom-AskValue $a $e.Value
      if ($r.Ok) { $f.Pos++; return $r.Result }
    }
    # This time the flow went another way (a page answered differently): stop replaying and ask from here on.
    Write-LogLine '  (replay stopped: the questions changed)'
    $f.Tape.RemoveRange($f.Pos, $f.Tape.Count - $f.Pos)
    $f.Redo.Clear()
    $f.Target = $f.Pos
  }
  if ($step) { $f.Replaying = $false }
  $sealed = Test-NavSealed
  $a.Prev = $null
  $a.RedoHit = $false
  if ($step -and $f.Redo.Count -gt 0 -and $f.Redo[0].Key -ceq $a.CheckKey) {
    $a.RedoHit = $true
    $r = ConvertFrom-AskValue $a $f.Redo[0].Value
    if ($r.Ok) { $a.Prev = $r }
  }
  # The same text question asked again right away (the caller said "try again"): the last tape entry is the answer
  # that didn't fit. Back skips it (it goes to the question before), and the path doesn't show it.
  $rej = $false
  $n = 0
  if ($step) {
    $n = $f.Tape.Count
    if ($a.Kind -eq 'text' -and $n -gt 0 -and $f.Tape[$n - 1].Kind -eq 'text' -and $f.Tape[$n - 1].Key -ceq $a.CheckKey) { $rej = $true; $n-- }
  }
  $a.BackMode = ''
  if ($step -and $n -gt 0) { $a.BackMode = 'back'; $a.BackLabel = T 'Back' }
  elseif ($step -and -not $f.Own) { $a.BackMode = 'leave'; $a.BackLabel = T 'Cancel' }
  elseif ($a.HasEsc) { $a.BackMode = 'esc'; $a.BackLabel = (Get-AskEscValue $a).Label }
  elseif ($f -and $sealed) { $a.BackMode = 'saved' }
  $a.CanBack = [bool]$a.BackMode
  $a.CanForward = [bool]$a.Prev
  $a.NavOn = ($a.CanBack -or $a.CanForward)
  $a.Crumb = ''
  if ($step -and $n -gt 0) { $a.Crumb = Get-NavCrumb $f $n }
  Show-AskBody $a
  $limit = Get-AskTimeout
  $a.Deadline = $null
  # (A yes / no with its own Esc answer - a consent: install, download - takes that one, never a yes nobody gave.)
  $a.TimeoutEsc = ($a.Kind -eq 'yesno' -and [bool]$a.HasEsc)
  if ($limit -gt 0) {
    $a.Deadline = [DateTime]::UtcNow.AddSeconds($limit)
    if ($a.TimeoutEsc) { Show-NavHint (T '  (No answer in {0} s = {1}.)' $limit (Get-AskEscValue $a).Label) }
    else { Show-NavHint (T '  (No answer in {0} s = the suggested answer.)' $limit) }
  }
  # (The control window shows it too, until it ends in any way: answered here or there, Back, Ctrl+C, End stream. Should
  # that copy fail, the console still asks: the window just doesn't show it.)
  try { $a.View = Publish-UiAsk $a ($step -and -not $sealed -and -not $f.Own) }
  catch { $a.View = @{ Id = ''; Deadline = $a.Deadline }; Write-LogLine ('  (control window: the question could not be shown: ' + $_.Exception.Message + ')') }
  try {
    $res = Read-AskAnswer $a $step $sealed $f $rej $limit
  } finally { Clear-UiAsk $a.Id }
  if ($step) { Add-NavTape $f $a $res }
  return $res.Result
}

# Invoke-Ask's reading part: replies until one is an answer (Back / Home throw, see Invoke-Ask).
function Read-AskAnswer($a, [bool]$step, [bool]$sealed, $f, [bool]$rej, [int]$limit) {
  $res = $null
  while ($true) {
    $reply = Read-AskReply $a
    $res = Resolve-AskReply $a $reply
    if ($reply.Timeout -and $a.TimeoutEsc) { $res = Get-AskEscValue $a }
    if ($res.Act -eq 'value' -and $reply.Timeout) {
      $script:AskTimeouts++   # (not a choice to keep for the session: Select-Tracks, Get-PlayerPref)
      $lab = [string]$res.Label
      if ($a.Secret -or $a.Private) { $lab = '***' }
      Say (T 'No answer in {0} s - used: {1}' $limit $lab) 'Yellow'
    } elseif ($res.Act -eq 'value' -and $reply.Window -and ($a.Kind -eq 'choice' -or $a.Kind -eq 'yesno')) {
      Write-LogLine ('  > ' + [string]$res.Label + ' ' + (T '(answered in the window)'))
    }
    if ($res.Act -eq 'again') { if ($res.Msg) { Say $res.Msg 'Yellow' }; continue }
    if ($res.Act -eq 'forward') {
      if (-not $a.Prev) { Show-NavHint (T '  (Nothing to go forward to.)'); continue }
      $res = $a.Prev.Clone()
      $res.Act = 'value'
    }
    if ($res.Act -eq 'home') {
      # (Not out of a locked task, nor out of one that can't be left: there Home is one step back.)
      if ($step -and -not $sealed -and -not $f.Own) { Set-NavSignal 'home' $f; throw (New-NavCancel) }
      $res = @{ Act = 'back' }
    }
    if ($res.Act -eq 'back') {
      if ($a.BackMode -eq 'back') {
        if ($rej) { $f.Tape.RemoveAt($f.Tape.Count - 1) }
        $last = $f.Tape[$f.Tape.Count - 1]
        $f.Tape.RemoveAt($f.Tape.Count - 1)
        $f.Redo.Insert(0, $last)
        $f.Target = $f.Tape.Count
        Set-NavSignal 'back' $f
        throw (New-NavCancel)
      }
      if ($a.BackMode -eq 'leave') { Set-NavSignal 'leave' $f; throw (New-NavCancel) }
      if ($a.BackMode -eq 'esc') { $res = Get-AskEscValue $a }
      else {
        if ($a.BackMode -eq 'saved') { Show-NavHint (T '  (Already saved - that step can''t be undone. M = menu to change it.)') }
        continue
      }
    }
    break
  }
  return $res
}

function Copy-NavValue($v) {
  if ($v -is [array] -or $v -is [hashtable]) { return , $v.Clone() }
  return , $v
}

# What a re-run starts from: the named $script: variables, the queue, and (-Cfg) the config as JSON.
function Save-NavSnap($f, [string[]]$names, [bool]$cfg) {
  foreach ($n in @($names)) {
    if (-not $n -or $f.SnapVars.ContainsKey($n)) { continue }
    $v = $null
    $var = Get-Variable -Name $n -Scope Script -ErrorAction SilentlyContinue
    if ($var) { $v = $var.Value }
    $f.SnapVars[$n] = (Copy-NavValue $v)
  }
  if ($cfg -and $null -eq $f.CfgJson -and $script:Cfg) { $f.CfgJson = ($script:Cfg | ConvertTo-Json -Depth 8 -Compress) }
  if ($null -eq $f.QueueSnap -and $null -ne $script:Queue) { $f.QueueSnap = @($script:Queue.ToArray()); $f.QueueFinished = $script:QueueFinished }
}

# The config back as it was, in the same object (other code holds $script:Cfg), property by property.
function Restore-NavCfg([string]$json) {
  if (-not $json -or -not $script:Cfg) { return }
  if (($script:Cfg | ConvertTo-Json -Depth 8 -Compress) -ceq $json) { return }
  $o = $json | ConvertFrom-Json
  $names = @($o.PSObject.Properties | ForEach-Object { $_.Name })
  foreach ($p in @($script:Cfg.PSObject.Properties)) { if ($names -notcontains $p.Name) { $script:Cfg.PSObject.Properties.Remove($p.Name) } }
  foreach ($p in $o.PSObject.Properties) {
    $q = $script:Cfg.PSObject.Properties[$p.Name]
    if ($q) { $q.Value = $p.Value } else { $script:Cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
  }
}

function Restore-NavSnap($f) {
  foreach ($n in @($f.SnapVars.Keys)) { Set-Variable -Name $n -Scope Script -Value (Copy-NavValue $f.SnapVars[$n]) }
  if ($null -ne $f.QueueSnap -and $null -ne $script:Queue) {
    $script:Queue.Clear()
    if ($f.QueueSnap.Count -gt 0) { $script:Queue.AddRange($f.QueueSnap) }
    $script:QueueFinished = $f.QueueFinished
  }
  if ($f.CfgJson) { Restore-NavCfg $f.CfgJson }
}

# Runs a task's questions as a flow (see above). -Origin: start | waiting | menu | addwin (the path's first word).
# -Snap: the $script: variable names the body sets as answers (site flows: DubChoice, DubPref, LastDub, LastEps,
# LastPart, LastPlayer, LastSearchLink, SiteChoice). -Cfg: the body changes $script:Cfg. -Own: Back at its first
# question doesn't leave it (Esc there = the question's -Esc answer, or nothing). Locals are $__af-prefixed: the body
# runs in a scope below this function and reads the caller's variables through it. Returns @{ Nav; Value }.
function Invoke-NavFlow {
  param([Alias('Name')][string]$__afName = 'flow', [Alias('Origin')][string]$__afOrigin = 'start', [Alias('Snap')][string[]]$__afSnap = @(),
    [Alias('Cfg')][switch]$__afCfg, [Alias('Own')][switch]$__afOwn, [Alias('Body')][scriptblock]$__afBody)
  $__afTop = $script:Nav
  if ($__afTop -and -not $__afTop.Sealed) {
    # Inside an open flow: one tape, so Back goes from this flow's first question to the one before it.
    Save-NavSnap $__afTop $__afSnap ([bool]$__afCfg)
    $__afV = & $__afBody
    return @{ Nav = ''; Value = $__afV }
  }
  $__afF = @{ Name = $__afName; Origin = $__afOrigin; Own = [bool]$__afOwn; Parent = $__afTop; Sealed = $false
    Tape = (New-Object System.Collections.ArrayList); Redo = (New-Object System.Collections.ArrayList); Pos = 0; Target = 0
    Replaying = $false; Memo = $null; SnapVars = @{}; CfgJson = $null; QueueSnap = $null; QueueFinished = $false }
  if (-not $__afTop) { $__afF.Memo = New-Object 'System.Collections.Generic.Dictionary[string,object]' }
  Save-NavSnap $__afF $__afSnap ([bool]$__afCfg)
  $script:Nav = $__afF
  try {
    while ($true) {
      $__afF.Pos = 0
      $script:NavPass++
      $__afV = $null
      try { $__afV = & $__afBody }
      catch { if ($script:CtrlCQuit -or -not $script:NavSignal) { throw } }
      $__afF.Replaying = $false
      $__afSig = $script:NavSignal
      if (-not $__afSig) { return @{ Nav = ''; Value = $__afV } }
      if (-not [object]::ReferenceEquals($script:NavSignalFrame, $__afF)) { throw (New-NavCancel) }
      Write-LogLine ('  (' + $__afSig + ': ' + $__afName + ')')
      Restore-NavSnap $__afF
      if ($__afSig -eq 'back') {
        $script:NavSignal = ''
        $script:NavSignalFrame = $null
        $__afF.Replaying = $true
        continue
      }
      if ($__afSig -eq 'home' -and $__afF.Parent) { $script:NavSignalFrame = $__afF.Parent; throw (New-NavCancel) }
      $script:NavSignal = ''
      $script:NavSignalFrame = $null
      return @{ Nav = $__afSig; Value = $null }
    }
  } finally {
    $script:Nav = $__afF.Parent
    if ([object]::ReferenceEquals($script:NavSignalFrame, $__afF)) { $script:NavSignal = ''; $script:NavSignalFrame = $null }
  }
}

# A step that can't be undone happened (config saved, code imported, files written, handed over): no Back crosses it.
function Lock-NavStep {
  $f = $script:Nav
  if ($f -and -not $f.Sealed) {
    $f.Sealed = $true
    $f.Replaying = $false
    $f.Redo.Clear()
    Write-LogLine ('  (saved: ' + $f.Name + ')')
  }
}

# Is a flow re-running its earlier answers (Say only writes log.txt then)?
function Test-NavReplaying { return ($null -ne $script:Nav -and [bool]$script:Nav.Replaying) }

# What a flow fetched once it gets again on a re-run (Back), with no network. Outside a flow it just runs.
# Errors are kept too, so a re-run takes the same way (e.g. the same fallback player); in the same run they are not
# (Test-NavMemoUse), so a site's own retry right after a failure goes to the network again. -Seconds: fetched again after
# that long (live data, e.g. a WPARTY room's position). Returns the items (callers wrap it in @()).
function Use-NavMemo {
  param([Parameter(Position = 0)][Alias('Key')][string]$__amKey, [Parameter(Position = 1)][Alias('Script')][scriptblock]$__amScript,
    [Alias('Seconds')][int]$__amTtl = 0)
  $__amRoot = Get-NavRoot
  if (-not $__amRoot) { return (& $__amScript) }
  $__amK = 'memo|' + $__amKey
  $__amHit = $null
  if ($__amRoot.Memo.TryGetValue($__amK, [ref]$__amHit) -and (Test-NavMemoUse $__amHit)) {
    if ($__amHit.Err) { throw $__amHit.Err }
    return $__amHit.Res
  }
  $__amUntil = $null
  if ($__amTtl -gt 0) { $__amUntil = (Get-Date).AddSeconds($__amTtl) }
  try { $__amRes = @(& $__amScript) }
  catch {
    if (-not (Test-NavAbort)) { $__amRoot.Memo[$__amK] = @{ Err = $_.Exception; Res = $null; Until = $__amUntil; Fail = $true; Pass = $script:NavPass } }
    throw
  }
  $__amRoot.Memo[$__amK] = @{ Err = $null; Res = $__amRes; Until = $__amUntil; Fail = $false; Pass = $script:NavPass }
  return $__amRes
}

function Read-Progress([string]$file) {
  try {
    if (-not [System.IO.File]::Exists($file)) { return $null }
    $fs = New-Object System.IO.FileStream($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $txt = ''
    try {
      $len = $fs.Length
      $take = [int][Math]::Min($len, 4096)
      if ($take -le 0) { return $null }
      [void]$fs.Seek($len - $take, [System.IO.SeekOrigin]::Begin)
      $buf = New-Object byte[] $take
      $n = $fs.Read($buf, 0, $take)
      $txt = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
    } finally { $fs.Dispose() }
    $ms = [regex]::Matches($txt, 'out_time_(?:us|ms)=(\d+)')
    if ($ms.Count -eq 0) { return $null }
    $t = ([double]$ms[$ms.Count - 1].Groups[1].Value) / 1000000.0
    return [pscustomobject]@{ Time = $t }
  } catch { return $null }
}

# ------------------------------------------------------------------ sources (what feeds the relay)
# $script:Src is the ffmpeg writing into the relay right now. Only one at a time: the next starts after it stopped.
$script:Src = $null

function Get-ScreenFile([string]$kind) {
  if ($kind -eq 'paused') { return 'paused.ass' }
  if ($kind -eq 'hold') { return 'hold.ass' }
  return 'slate.ass'
}

function Test-PreviewWanted {
  if (-not (Get-Command Test-ControlPanelOpen -CommandType Function -ErrorAction SilentlyContinue)) { return $false }
  try { return [bool](Test-ControlPanelOpen) } catch { return $false }
}

function Start-Source([string]$Kind, $Media = $null, [double]$Start = 0) {
  $off = Get-NextOffset
  $preview = Test-PreviewWanted
  if ($Kind -eq 'content') {
    $argv = Get-ContentArgs $Media $Start $off $preview
    $wd = $Media.JobDir
  } else {
    $argv = Get-SlateArgs $off (Get-ScreenFile $Kind) $preview
    $wd = $script:SlateDir
  }
  $progFile = PathJoin $wd 'progress.txt'
  try { [System.IO.File]::Delete($progFile) } catch {}
  if ($env:VRCLM_DEBUG) { Say ("ffmpeg " + (Join-CmdArgs $argv)) 'DarkGray' }
  if (-not [System.IO.Directory]::Exists($wd)) { [void][System.IO.Directory]::CreateDirectory($wd) }
  $psi = New-StartInfo $script:FFmpeg $argv $wd
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  # ffmpeg's complaints are kept (not printed): shown only if the video fails.
  $psi.RedirectStandardError = $true
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  $proc = Start-Child $psi
  $src = [pscustomobject]@{
    Kind = $Kind; Media = $Media; Start = $Start; Off = $off; Proc = $proc; T0 = (Get-Date); ProgFile = $progFile; Preview = $preview
    Err = $proc.StandardError.ReadToEndAsync(); Copy = $proc.StandardOutput.BaseStream.CopyToAsync($script:RelayIn, 65536); Adopt = $false
  }
  $script:Src = $src
  $script:Current = $proc
  return $src
}

# Stops a source (ffmpeg is asked to finish; -Now kills it) and notes where its timestamps ended.
# Returns how far it got (seconds from its start).
function Stop-Source($src, [switch]$Now) {
  if (-not $src) { return 0.0 }
  if ($script:Src -eq $src) { $script:Src = $null }
  $proc = $src.Proc
  $alive = $false
  try { $alive = -not $proc.HasExited } catch {}
  if ($alive -and -not $Now) { Send-Key $proc 'q'; try { [void]$proc.WaitForExit(1500) } catch {} }
  Stop-Proc $proc
  try { [void]$proc.WaitForExit(3000) } catch {}
  try { [void]$src.Copy.Wait(3000) } catch {}
  if ($script:Current -eq $proc) { $script:Current = $null }
  $pos = 0.0
  $pr = Read-Progress $src.ProgFile
  if ($pr) { $pos = [Math]::Max(0.0, $pr.Time - $src.Off) }
  if ($pr -and $pr.Time -gt $script:LastEnd) { $script:LastEnd = $pr.Time }
  elseif (-not $pr) { $script:LastEnd = [Math]::Max($script:LastEnd, $src.Off + ((Get-Date) - $src.T0).TotalSeconds) }
  return $pos
}

# Puts the stream on the air with the waiting screen while this window does something else (asks questions,
# gets a video ready): viewers can connect meanwhile, and it keeps running on its own until the next source.
function Start-Standby {
  if (-not $script:Cfg -or -not $script:FFmpeg -or $env:VRCLM_NO_STANDBY) { return }
  if ($script:Src) {
    $running = $false
    try { $running = -not $script:Src.Proc.HasExited } catch {}
    # (One still running into a relay that ended is stuck: both start again.)
    if ($running -and (Test-RelayAlive)) { return }
    [void](Stop-Source $script:Src -Now)
  }
  try {
    if (-not (Test-RelayAlive)) {
      if ($script:Relay) { Stop-Relay }
      Start-Relay
    }
    [void](Start-Source 'waiting')
  } catch {
    if ($env:VRCLM_DEBUG) { Say ("standby: " + $_.Exception.Message) 'DarkGray' }
  }
}

# ------------------------------------------------------------------ commands (keys, control window, the world's player)
# Every command goes into one queue and is carried out in order, so quick presses are never lost: a pause and a
# continue pressed right after each other both happen, and several "back 10 s" presses add up.
# A command: Cmd (toggle pause resume start seek seekto skip stop quit resync sync lost restart playnow),
# Arg (seconds for seek / seekto), From (key panel link button player file), At (when it came in).
$script:Cmds = New-Object System.Collections.ArrayList

function New-Cmd([string]$cmd, $arg = $null, [string]$from = 'key') {
  return [pscustomobject]@{ Cmd = $cmd; Arg = $arg; From = $from; At = (Get-Date) }
}

function Add-Cmd($c) { if ($c) { [void]$script:Cmds.Add($c) } }

function Get-CmdWord($c) {
  switch ($c.Cmd) {
    'pause' { return (T 'pause') }
    'resume' { return (T 'continue') }
    'skip' { return (T 'next video') }
    'resync' { return (T 'resync everyone') }
    'sync' { return (T 'resync everyone') }
    'seek' {
      $s = [int][Math]::Round([Math]::Abs([double]$c.Arg))
      if ([double]$c.Arg -lt 0) { return (T 'back {0} s' $s) }
      return (T 'forward {0} s' $s)
    }
    default { return $c.Cmd }
  }
}

# The torrent episode the waiting screen is downloading for its turn (the next queue item, read now: items may have
# been added in front of it meanwhile), or $null. S S on the waiting screen gives exactly this one up.
function Get-WaitingSkipItem {
  if ($script:Idx -ge $script:Queue.Count) { return $null }
  $nx = $script:Queue[$script:Idx]
  if ($nx -and $nx.Kind -eq 'torrent' -and @('new', 'torrent-meta', 'downloading') -contains $nx.State) { return $nx }
  return $null
}

# What a command means for the current source kind ($null = it doesn't apply here, with the reason in $why).
function Resolve-Cmd($c, [string]$kind, [ref]$why) {
  $why.Value = ''
  $cmd = $c.Cmd
  if ($cmd -eq 'toggle') {
    if ($kind -eq 'content') { $cmd = 'pause' } elseif ($kind -eq 'paused') { $cmd = 'resume' } elseif ($kind -eq 'hold') { $cmd = 'start' }
    else { $why.Value = (T 'nothing is playing right now'); return $null }
  }
  if ($cmd -eq 'resume' -and $kind -eq 'hold') { $cmd = 'start' }
  $fits = switch ($kind) {
    'content' { @('pause', 'seek', 'seekto', 'skip', 'stop', 'quit', 'resync', 'sync', 'lost', 'restart', 'playnow') }
    'paused' { @('resume', 'seek', 'seekto', 'skip', 'stop', 'quit', 'resync', 'playnow') }
    'hold' { @('start', 'pause', 'seek', 'seekto', 'skip', 'stop', 'quit', 'resync', 'playnow') }
    default { @('stop', 'quit', 'resync', 'host', 'newlink', 'res', 'speedtest', 'lang', 'forget', 'menu') }
  }
  # The waiting screen while a torrent episode downloads for its turn: S S gives that episode up.
  if ($kind -eq 'waiting' -and (Get-WaitingSkipItem)) { $fits = @($fits) + @('skip') }
  if ($fits -contains $cmd) {
    if ($cmd -eq $c.Cmd) { return $c }
    return [pscustomobject]@{ Cmd = $cmd; Arg = $c.Arg; From = $c.From; At = $c.At }
  }
  if ($cmd -eq 'pause' -and $kind -eq 'paused') { $why.Value = (T 'already paused') }
  elseif ($cmd -eq 'resume' -and $kind -eq 'content') { $why.Value = (T 'not paused') }
  else { $why.Value = (T 'nothing is playing right now') }
  return $null
}

# The next command that fits the current source, or $null. Ones that don't fit are dropped (with a note).
function Get-NextCmd([string]$kind) {
  while ($script:Cmds.Count -gt 0) {
    $c = $script:Cmds[0]
    $script:Cmds.RemoveAt(0)
    # The plain link put in again while paused: continue (the TV then shows the stream again, from live).
    if ($c.Cmd -eq 'sync' -and $c.From -eq 'link' -and $c.Arg -eq 'plain' -and $kind -eq 'paused') { $c = [pscustomobject]@{ Cmd = 'resume'; Arg = $null; From = 'link'; At = $c.At } }
    if ($c.Cmd -in @('lost', 'sync', 'restart') -and $kind -ne 'content') { continue }   # only matter while a video plays
    # A "Play now" from the window's Up next names its video: once that one plays (an earlier "Play now" switched to it)
    # or is no longer the next one, it is old and would skip what plays.
    if ($c.Cmd -eq 'playnow' -and $c.From -eq 'panel' -and $c.Arg -is [System.Collections.IDictionary]) {
      $nx = $script:Idx + 1
      if ($nx -ge $script:Queue.Count -or [int](Get-Prop $script:Queue[$nx] 'Id') -ne [int]$c.Arg['Id']) { continue }
    }
    $why = ''
    $r = Resolve-Cmd $c $kind ([ref]$why)
    $fromWorld = ($c.From -eq 'link' -or $c.From -eq 'button')
    if ($r) {
      if ($fromWorld) { Say (T '  From the world''s video player: {0}' (Get-CmdWord $r)) 'Cyan' }
      return $r
    }
    if ($fromWorld) { Say (T '  From the world''s video player: {0} (ignored: {1})' (Get-CmdWord $c) $why) 'DarkGray' }
  }
  return $null
}

# Takes the waiting "back 10 s" / "forward 10 s" commands off the queue (they add up) while a source is winding down.
function Get-QueuedSeek {
  $sum = 0.0
  for ($i = 0; $i -lt $script:Cmds.Count; ) {
    $c = $script:Cmds[$i]
    if ($c.Cmd -eq 'seek' -and $c.From -ne 'link') { $sum += [double]$c.Arg; $script:Cmds.RemoveAt($i) } else { break }
  }
  return $sum
}

# Keys and the control window. Things that don't change the stream (open a window...) happen right here.
function Receive-Commands([string]$kind) {
  Add-Cmd (Read-KeyCommand $kind)
  try { Update-UpnpLeases } catch {}   # (also while waiting for input, not only while a video plays)
  # End stream in the control window (the 'quit' it posts too may have gone with the start questions' clicks).
  try { if ($script:UiBus -and $script:UiBus.QuitReq) { $script:UiBus.QuitReq = $false; Add-Cmd (New-Cmd 'quit' $null 'panel') } } catch {}
  if ($script:PanelShown) {
    for ($i = 0; $i -lt 20; $i++) {
      $p = $null
      try { $p = Read-PanelCommand } catch {}
      if (-not $p) { break }
      switch ($p.Cmd) {
        'add' { Open-AddWindow '' }
        'viewer' { Open-ViewerPreview }
        'clock' { Switch-Clock }
        # The window's input box: each line as if typed here and Enter pressed; files / a folder as if dropped here.
        # (Several lines - a drop, a paste - are links / paths each; of the titles among them only the first one counts,
        # after the links: one search, one second window.)
        'line' {
          $lns = @(@(([string]$p.Arg) -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
          if ($lns.Count -gt 1) {
            $rest = @(); $titles = @()
            foreach ($ln in $lns) { if (Test-IsTitle $ln) { $titles += $ln } else { $rest += $ln } }
            if ($titles.Count -gt 0) { $lns = @($rest + $titles[0]) }
            if ($titles.Count -gt 1) { Say (T '  Only the first title is searched for ({0}); {1} more skipped.' $titles[0] ($titles.Count - 1)) 'Yellow' }
          }
          foreach ($ln in $lns) { Add-TypedLine $ln $kind }
        }
        'files' {
          $fs = @(@($p.Arg) | ForEach-Object { [string]$_ } | Where-Object { $_ -and $_.Trim() })
          if ($fs.Count -gt 0) { Invoke-AddEntries $fs $kind }
        }
        { $_ -in @('qplay', 'qup', 'qdown', 'qremove', 'qclear') } { Invoke-QueueCommand $p.Cmd $p.Arg $kind }
        'quit' {
          try { $script:UiBus.QuitReq = $false } catch {}
          Add-Cmd (New-Cmd 'quit' $p.Arg 'panel')
        }
        default { Add-Cmd (New-Cmd $p.Cmd $p.Arg 'panel') }
      }
    }
  }
  Receive-WorldCommands $kind
}

# The position of the queue item with this Id, or -1.
function Find-QueueIndex($id) {
  $n = 0
  if (-not [int]::TryParse("$id", [ref]$n) -or $n -le 0) { return -1 }
  for ($i = 0; $i -lt $script:Queue.Count; $i++) { if ([int](Get-Prop $script:Queue[$i] 'Id') -eq $n) { return $i } }
  return -1
}

# Takes an item out of the queue: its download / helper programs are stopped (taskkill runs on its own, so the loop
# never waits for it) and its folder is deleted (or later, once the programs let go of it: Remove-PendingDirs).
# A torrent episode releases its share of the torrent (rqbit itself keeps running for the other episodes and windows).
function Remove-QueueItemAt([int]$i) {
  $it = $script:Queue[$i]
  $script:Queue.RemoveAt($i)
  if ($it.Kind -eq 'torrent' -and $it.Torrent -and -not $it.Torrent.Released) {
    $g = $it.Torrent.G
    $wasDl = ($it.State -eq 'downloading')
    Remove-TorrentItemRef $it
    # (Other episodes of that torrent still queued: rqbit stops downloading (and uploading) it until the next one's
    # turn sets its files again, as when an episode completes. Not while seeding: "Torrents": "seed".)
    # (Others of it still downloading: rqbit gets just their files, so the removed one's stops - Step-TorrentPrep sets
    # them only when an episode starts.)
    $dls = @($script:Queue | Where-Object { $_.Kind -eq 'torrent' -and $_.Torrent -and $_.Torrent.G -eq $g -and $_.State -eq 'downloading' })
    $busy = $dls.Count -gt 0
    if ($wasDl -and $g.Id -and -not $g.Paused -and -not $busy -and (Get-TorrentsSetting) -ne 'seed') {
      try { $r = Invoke-Rqbit 'POST' "/torrents/$($g.Id)/pause" $null '' 3; if ($r.Status -eq 200) { $g.Paused = $true } } catch {}
    }
    if ($wasDl -and $g.Id -and $g.Refs -gt 0 -and $busy) {
      $want = @(@($dls | ForEach-Object { Get-TorrentItemFiles $_ }) | Sort-Object -Unique)
      if ($want.Count -gt 0 -and ($want -join ',') -ne (@($g.Want | Sort-Object -Unique) -join ',')) {
        try {
          $r = Invoke-Rqbit 'POST' "/torrents/$($g.Id)/update_only_files" ('{"only_files":[' + ($want -join ',') + ']}') 'application/json' 3
          if ($r.Status -eq 200) { $g.Want.Clear(); foreach ($x in $want) { $g.Want.Add([int]$x) } }
        } catch {}
      }
    }
  }
  $procs = @()
  if ($it.Dl -and $it.Dl.Proc) { $procs += $it.Dl.Proc }
  foreach ($bg in @($it.Prep)) { if ($bg -and $bg.Proc) { $procs += $bg.Proc } }
  $pb = Get-Prop $it 'ProbeBg'
  if ($pb -and $pb.Bg -and $pb.Bg.Proc) { $procs += $pb.Bg.Proc }
  $pk = Get-Prop $it 'PickBg'
  if ($pk -and $pk.Ps) { try { [void]$pk.Ps.BeginStop($null, $null) } catch {} }
  foreach ($p in $procs) {
    $alive = $false
    try { $alive = -not $p.HasExited } catch {}
    if (-not $alive) { continue }
    # (The whole tree: yt-dlp's own ffmpeg would keep the files open.)
    try { [void](Start-Background 'taskkill.exe' @('/T', '/F', '/PID', [string]$p.Id)) } catch { Stop-Proc $p }
  }
  $dir = $it.JobDir
  if ($dir) {
    if ($script:JobLocks.ContainsKey($dir)) {
      try { $script:JobLocks[$dir].Dispose() } catch {}
      $script:JobLocks.Remove($dir)
    }
    try { [System.IO.Directory]::Delete($dir, $true) } catch {}
    if ([System.IO.Directory]::Exists($dir)) { [void]$script:PendingDirs.Add($dir) }
    $it.JobDir = $null
  }
  return $it
}

# The control window's Up next menu (Arg = @{ Id }). Only items after the one that plays can change; while nothing
# plays, the one being got ready can too. Runs on this thread from Receive-Commands only (never inside a question).
#   qplay: while a video plays (or is paused / waits for the players) it moves right behind it and the video switches
#          to it (as "Now" from a second window); while nothing plays it becomes the next one.
#   qup / qdown: one place earlier / later.  qremove: out of the queue (its download stops).  qclear: all of them.
function Invoke-QueueCommand([string]$cmd, $arg, [string]$kind) {
  $first = $script:Idx
  if ($kind -ne 'waiting') { $first = $script:Idx + 1 }
  if ($cmd -eq 'qclear') {
    $n = 0
    for ($i = $script:Queue.Count - 1; $i -ge $first; $i--) { [void](Remove-QueueItemAt $i); $n++ }
    if ($n -gt 0) { Say (T '  Cleared the queue ({0} removed).' $n) 'Gray' }
    return
  }
  $id = $null
  if ($arg -is [System.Collections.IDictionary]) { $id = $arg['Id'] } else { $id = Get-Prop $arg 'Id' }
  $i = Find-QueueIndex $id
  if ($i -lt 0) { Say (T '  That video isn''t in the queue any more.') 'DarkGray'; return }
  $it = $script:Queue[$i]
  if ($i -lt $first) {
    if ($cmd -eq 'qremove' -and $i -eq $script:Idx) { Say (T '  {0} is playing now: to leave it, use Next or Stop.' $it.Name) 'Yellow' }
    return
  }
  switch ($cmd) {
    'qplay' {
      $to = $script:Idx
      if ($kind -ne 'waiting') { $to = $script:Idx + 1 }
      if ($i -ne $to) { $script:Queue.RemoveAt($i); $script:Queue.Insert($to, $it) }
      if ($kind -ne 'waiting') { Add-Cmd (New-Cmd 'playnow' @{ Id = (Get-Prop $it 'Id') } 'panel') }
      else { Say (T '  Next up: {0}' $it.Name) 'Gray' }
    }
    'qup' {
      if ($i - 1 -ge $first) { $script:Queue.RemoveAt($i); $script:Queue.Insert($i - 1, $it) }
    }
    'qdown' {
      if ($i + 1 -lt $script:Queue.Count) { $script:Queue.RemoveAt($i); $script:Queue.Insert($i + 1, $it) }
    }
    'qremove' {
      [void](Remove-QueueItemAt $i)
      Say (T '  Removed from the queue: {0}' $it.Name) 'Gray'
    }
  }
}

function Switch-Clock {
  $script:ClockOn = -not $script:ClockOn
  if ($script:ClockOn) { Say (T '  Clock on the stream: on (the video time, top right - compare it to spot who is behind).') 'Gray' }
  else { Say (T '  Clock on the stream: off.') 'Gray' }
  if ($script:Src -and $script:Src.Kind -eq 'content') { Add-Cmd (New-Cmd 'restart' $null 'key') }
}

# A second window of this tool: search for something / add videos without stopping this one (see Main).
function Open-AddWindow([string]$query) {
  try {
    $argv = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $script:ScriptFile)
    if ($query) { $argv += $query }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = Join-CmdArgs $argv
    $psi.UseShellExecute = $true
    # This session's answer to "which player", so the new window doesn't ask it again (Read-HandoverPlayer).
    [Environment]::SetEnvironmentVariable('VRCLM_PLAYER', $script:PlayerPref)
    Write-StartLog $psi
    [void][System.Diagnostics.Process]::Start($psi)
    Say (T '  Opened a second window: search or add videos there, this one keeps streaming.') 'Gray'
  } catch { Say (T '  Couldn''t open a second window: {0}' $_.Exception.Message) 'Yellow' }
}

function Open-ViewerPreview {
  $url = [string]$script:Cfg.VlcUrl
  if ($script:HostP -and $script:HostP.VlcUrl) { $url = [string]$script:HostP.VlcUrl }
  if (-not $url) { $url = [string]$script:Cfg.PcUrl -replace '^(?i)rtspt://', 'rtsp://' }
  $ok = $false
  if (Get-Command Start-ViewerPreview -CommandType Function -ErrorAction SilentlyContinue) { try { $ok = [bool](Start-ViewerPreview $url) } catch {} }
  if ($ok) { Say (T '  Opened the viewer preview: the real stream, with the delay viewers have.') 'Gray' }
  else { Say (T '  Couldn''t open the viewer preview (it needs ffplay, which comes with ffmpeg). Open {0} in VLC instead.' $url) 'Yellow' }
}

# Keyboard. Space = pause / continue (or start now), Left / Right = 10 s back / forward (with Shift: 30 s),
# S twice = next video, R twice = resync everyone, Q twice = stop, + = search / add in a second window,
# F2 = control window. Text dragged / pasted / typed into the window + Enter = add it (or search for it).
function Read-KeyCommand([string]$kind) {
  if (-not $script:HasConsole) { return $null }
  $keys = New-Object System.Collections.Generic.List[System.ConsoleKeyInfo]
  # (Keys the question reader took off the console but didn't use, e.g. an Enter right after the Esc that left a
  # flow: they belong to this screen now, not to a later question.)
  foreach ($k in $script:NavKeyAhead) { $keys.Add([System.ConsoleKeyInfo]$k) }
  $script:NavKeyAhead.Clear()
  try {
    if ($keys.Count -eq 0 -and -not [Console]::KeyAvailable) { return $null }
    $quietUntil = (Get-Date).AddMilliseconds(40)
    while ((Get-Date) -lt $quietUntil) {
      if ([Console]::KeyAvailable) { $keys.Add([Console]::ReadKey($true)); $quietUntil = (Get-Date).AddMilliseconds(40) }
      else { Start-Sleep -Milliseconds 5 }
    }
  } catch { if ($keys.Count -eq 0) { return $null } }
  foreach ($k in $keys) {
    if (Test-CtrlCKey $k) { $script:TypeBuf = ''; $script:Armed = $null; return (New-Cmd 'quit') }
  }
  if ($keys.Count -eq 1 -and $script:TypeBuf.Length -eq 0) {
    $k = $keys[0]
    $shift = [bool]($k.Modifiers -band [ConsoleModifiers]::Shift)
    $big = 10
    if ($shift) { $big = 30 }
    switch ($k.Key) {
      ([ConsoleKey]::Spacebar) { $script:Armed = $null; return (New-Cmd 'toggle') }
      ([ConsoleKey]::LeftArrow) { $script:Armed = $null; return (New-Cmd 'seek' (-$big)) }
      ([ConsoleKey]::RightArrow) { $script:Armed = $null; return (New-Cmd 'seek' $big) }
      ([ConsoleKey]::DownArrow) { $script:Armed = $null; return (New-Cmd 'seek' -30) }
      ([ConsoleKey]::UpArrow) { $script:Armed = $null; return (New-Cmd 'seek' 30) }
      ([ConsoleKey]::F2) { $script:Armed = $null; Show-Panel; return $null }
      ([ConsoleKey]::Add) { $script:Armed = $null; Open-AddWindow ''; return $null }
      ([ConsoleKey]::OemPlus) { $script:Armed = $null; Open-AddWindow ''; return $null }
      ([ConsoleKey]::Escape) { $script:Armed = $null; return $null }
      ([ConsoleKey]::Enter) {
        $script:Armed = $null
        # Enter alone while nothing plays: pick files.
        if ($kind -eq 'waiting') { $files = @(Show-FilePicker); if ($files.Count -gt 0) { Invoke-AddEntries $files $kind } }
        return $null
      }
    }
    # Letters by key, not by character, so they also work while a Russian (or other) keyboard layout is on.
    $name = $null
    if (-not ($k.Modifiers -band ([ConsoleModifiers]::Control -bor [ConsoleModifiers]::Alt))) {
      if ($k.Key -eq [ConsoleKey]::S) { $name = 'skip' } elseif ($k.Key -eq [ConsoleKey]::Q) { $name = 'stop' }
      elseif ($k.Key -eq [ConsoleKey]::P) { $name = 'toggle' } elseif ($k.Key -eq [ConsoleKey]::R) { $name = 'resync' }
    }
    if ($name) {
      if ($name -eq 'stop' -and $kind -eq 'waiting') { $name = 'quit' }
      $recent = ((Get-Date) - $script:ArmedAt).TotalSeconds -lt 4
      if ($script:Armed -eq $name -and $recent) { $script:Armed = $null; return (New-Cmd $name) }
      if ($script:Armed -and $recent -and $script:ArmedChar) {
        # Another letter after a letter that waited for its second press: someone is typing a word.
        $script:TypeBuf = [string]$script:ArmedChar + [string]$k.KeyChar
        $script:Armed = $null
        return $null
      }
      $script:Armed = $name
      $script:ArmedChar = $k.KeyChar
      $script:ArmedAt = Get-Date
      switch ($name) {
        'skip' { Say (T '  Press S again to skip to the next video.') 'Yellow' }
        'toggle' { Say (T '  Press P again (or Space) to pause / continue.') 'Yellow' }
        'resync' { Say (T '  Press R again to resync everyone: all players reconnect to the live picture (about 10 s) and the video waits for them.') 'Yellow' }
        'quit' { Say (T '  Press Q again to end the stream.') 'Yellow' }
        default { Say (T '  Press Q again to stop this (you can then pick something else to stream).') 'Yellow' }
      }
      return $null
    }
  }
  # Anything else is text. A letter that was waiting for its second press was the start of a word.
  if ($script:Armed -and $script:TypeBuf.Length -eq 0 -and $script:ArmedChar -and [int]$script:ArmedChar -ge 32 -and ((Get-Date) - $script:ArmedAt).TotalSeconds -lt 4) {
    $script:TypeBuf = [string]$script:ArmedChar
  }
  $script:Armed = $null
  foreach ($k in $keys) {
    if ($k.Key -eq [ConsoleKey]::Enter) {
      $line = $script:TypeBuf
      $script:TypeBuf = ''
      if ($line.Trim()) { Add-TypedLine $line $kind }
      continue
    }
    if ($k.Key -eq [ConsoleKey]::Escape) { $script:TypeBuf = ''; continue }
    if ($k.Key -eq [ConsoleKey]::Backspace) {
      if ($script:TypeBuf.Length -gt 0) { $script:TypeBuf = $script:TypeBuf.Substring(0, $script:TypeBuf.Length - 1) }
      continue
    }
    if ([int]$k.KeyChar -ge 32) { $script:TypeBuf += $k.KeyChar }
  }
  return $null
}

# When the stream can't keep up with real time (upload too slow, or PC too busy), lighten it a little.
function Get-KbpsFloor { if ($script:HostP -and $script:HostP.MinKbps -gt 0) { return [int]$script:HostP.MinKbps }; return 700 }
function Test-CanStepDown { return ($script:KbpsSteps -lt 2 -and $script:VideoKbps -gt (Get-KbpsFloor)) }

function Step-DownQuality {
  $script:KbpsSteps++
  $sp = ''
  if ($script:SlowSpeed) { $sp = T ' (it ran at {0}x)' ($script:SlowSpeed.ToString('0.00', $script:Inv)) }
  $faster = @{ 'veryslow' = 'slower'; 'slower' = 'slow'; 'slow' = 'medium'; 'medium' = 'fast'; 'fast' = 'faster'; 'faster' = 'veryfast'; 'veryfast' = 'superfast' }
  $cur = "$($script:Cfg.CpuPreset)"
  if ($script:CpuPreset) { $cur = $script:CpuPreset }
  $script:FastSecs = 0.0
  # (Slow again after going back up: wait twice as long before the next try.)
  if ($script:SteppedUp) { $script:StepUpWait = [Math]::Min(3600.0, $script:StepUpWait * 2); $script:SteppedUp = $false }
  if ($script:VEnc -eq 'libx264' -and $faster.ContainsKey($cur)) {
    $script:CpuPreset = $faster[$cur]
    # Another x264 preset writes a different H.264 header: the players reconnect once (Invoke-Queue).
    $script:NeedResync = $true
    Say (T '  The stream couldn''t keep up with real time{0} - encoding a bit lighter (x264 preset {1}) and carrying on.' $sp $script:CpuPreset) 'Yellow'
    return
  }
  # Only the average drops; the ceiling in the header stays (with "EncoderArgs": "classic" the players reconnect once,
  # and with AMD / Intel encoders too: that their header stays the same with another bitrate isn't proven).
  if ((Test-ClassicEncoder) -or $script:VEnc -eq 'h264_amf' -or $script:VEnc -eq 'h264_qsv') { $script:NeedResync = $true }
  [void]$script:KbpsDown.Add($script:VideoKbps)
  $script:VideoKbps = [int][Math]::Max((Get-KbpsFloor), [Math]::Round($script:VideoKbps * 0.8 / 50) * 50)
  Say (T '  The stream couldn''t keep up with real time{0} - lowering the video bitrate to {1} kbps and carrying on.' $sp $script:VideoKbps) 'Yellow'
  Say (T '  (If this happens every time, set "VideoKbps" in config.json to that number.)') 'DarkGray'
}

# Back up again: once videos kept up with real time for StepUpWait seconds after a lower bitrate, the next video
# (never one already playing) gets the bitrate from before the last step down, at most the connection's ceiling.
# Only where the H.264 header stays the same with another average: NVENC (variable bitrate) and x264 (a lighter
# x264 preset stays: going back would change the header). Not with "EncoderArgs": "classic", AMD or Intel.
$script:KbpsDown = New-Object System.Collections.ArrayList   # the bitrates before each step down (last = latest)
$script:FastSecs = 0.0
$script:StepUpWait = 300.0
$script:SteppedUp = $false
$script:LastStartedItem = $null
function Test-CanStepUp {
  if ($script:KbpsDown.Count -eq 0 -or $script:FastSecs -lt $script:StepUpWait -or (Test-ClassicEncoder)) { return $false }
  return ($script:VEnc -eq 'h264_nvenc' -or $script:VEnc -eq 'libx264')
}

function Step-UpQuality {
  $k = [int]$script:KbpsDown[$script:KbpsDown.Count - 1]
  $script:KbpsDown.RemoveAt($script:KbpsDown.Count - 1)
  if ($script:RateCapKbps -gt 0) { $k = [Math]::Min($k, [int]$script:RateCapKbps) }
  $script:FastSecs = 0.0
  if ($k -le $script:VideoKbps) { return }
  $script:VideoKbps = $k
  $script:KbpsSteps = [Math]::Max(0, $script:KbpsSteps - 1)
  $script:SteppedUp = $true
  Say (T '  The upload keeps up again - back to {0} kbps video.' $k) 'Green'
}

# ------------------------------------------------------------------ picture size and bitrate
# The sizes the resolution menu (V) offers, with the least video bitrate each looks good at (at up to 30 fps).
# "Auto" picks the biggest one the host's bitrate reaches.
$script:Resolutions = @(
  @{ H = 360; Min = 0 }, @{ H = 480; Min = 600 }, @{ H = 540; Min = 900 },
  @{ H = 720; Min = 1200 }, @{ H = 900; Min = 2500 }, @{ H = 1080; Min = 3500 }
)
$script:BaseKbps = 1350

# "Height" in config.json: a number, or "auto" (= 0).
function Get-HeightSetting {
  $v = "$(Get-Prop $script:Cfg 'Height')".Trim()
  if (-not $v -or $v -match '^(?i)auto$') { return 0 }
  $h = 0
  if (-not [int]::TryParse($v, [ref]$h) -or $h -lt 240) { return 720 }
  return [Math]::Min(2160, $h)
}

# "Bitrate" in config.json: "auto" (what the picture size needs, at most what the host takes) or "fixed" (always the host's VideoKbps).
function Test-AutoBitrate { return ("$(Get-Prop $script:Cfg 'Bitrate')".Trim() -notmatch '^(?i)(fixed|manual|host)$') }

function Get-FpsFactor { if ($script:StreamFpsNum -gt 40) { return 1.5 }; return 1.0 }

# The most video bitrate the host (or the line to it) takes: its VideoKbps / speed test result, within its limits.
function Get-KbpsCeiling {
  if ($script:HostP) { return [int](Get-HostKbps $script:HostP) }
  return [int]$script:BaseKbps
}

# The bitrate a picture size needs to look good (2800 kbps at 720p, growing with the picture's area).
function Get-ResolutionKbps([int]$h) {
  return [int]([Math]::Round(2800.0 * [Math]::Pow($h / 720.0, 1.5) * (Get-FpsFactor) / 50.0) * 50)
}

function Get-AutoHeight([int]$kbps) {
  $h = 360
  foreach ($r in $script:Resolutions) { if ($kbps -ge $r.Min * (Get-FpsFactor)) { $h = $r.H } }
  return $h
}

# The video bitrate for picture height $h on the current host.
function Get-QualityKbps([int]$h) {
  $ceil = Get-KbpsCeiling
  $k = $ceil
  if (Test-AutoBitrate) { $k = [Math]::Min($ceil, (Get-ResolutionKbps $h)) }
  return [int][Math]::Max([Math]::Min($ceil, (Get-KbpsFloor)), $k)
}

# Picture size and video bitrate for the current host (after the host, the resolution or the speed test changed).
function Update-StreamQuality {
  $h = Get-HeightSetting
  $script:HeightCappedFrom = 0
  if ($h -le 0) { $h = Get-AutoHeight (Get-KbpsCeiling) }
  elseif ("$(Get-Prop $script:Cfg 'HeightPolicy')".Trim() -notmatch '^(?i)exact$') {
    # A size the host's bitrate can't fill looks worse than a smaller sharp one (Topaz Chat: 720p at 1350 kbps measured
    # sharper than 1080p at 1350). "HeightPolicy": "exact" in config.json keeps the size as set.
    $need = 0
    foreach ($r in $script:Resolutions) { if ($r.H -ge $h) { $need = $r.Min; break } }
    if ($need -eq 0 -and @($script:Resolutions).Count -gt 0) { $need = @($script:Resolutions)[-1].Min }   # (above the largest listed size)
    $auto = Get-AutoHeight (Get-KbpsCeiling)
    if ($need -gt 0 -and (Get-KbpsCeiling) -lt $need * (Get-FpsFactor) -and $auto -lt $h) { $script:HeightCappedFrom = $h; $h = $auto }
  }
  $was = @($script:OutW, $script:OutH, $script:RateCapKbps, $script:VideoKbps, $script:KbpsSteps)
  $script:OutH = [int]([Math]::Round($h / 2.0) * 2)
  $script:OutW = [int]([Math]::Round($script:OutH * 16.0 / 9.0 / 2.0) * 2)
  $script:VideoKbps = Get-QualityKbps $script:OutH
  $script:RateCapKbps = $script:VideoKbps
  # Same size and ceiling after a step down: with "EncoderArgs": "classic", AMD or Intel the bitrate is in the H.264
  # header (or may be), and the stream may go on on this connection (the resolution menu): keep the lowered one.
  if ($was[4] -gt 0 -and $was[0] -eq $script:OutW -and $was[1] -eq $script:OutH -and $was[2] -eq $script:RateCapKbps -and $was[3] -lt $script:VideoKbps -and
      ((Test-ClassicEncoder) -or $script:VEnc -eq 'h264_amf' -or $script:VEnc -eq 'h264_qsv')) {
    $script:VideoKbps = $was[3]
    return
  }
  $script:KbpsSteps = 0
  $script:KbpsDown.Clear()
  $script:FastSecs = 0.0
}

function Show-StreamQuality {
  $how = T 'fixed'
  if (Test-AutoBitrate) { $how = T 'auto' }
  $name = ''
  if ($script:HostP) { $name = T ' on {0}' $script:HostP.Name }
  $size = "$($script:OutH)p"
  if ((Get-HeightSetting) -le 0) { $size = T '{0} (auto)' $size }
  $fps = Format-Num ([Math]::Round($script:StreamFpsNum, 2))
  Say (T '  Picture: {0}, {1} fps, {2} kbps video ({3}{4}).  V = change the resolution.' $size $fps $script:VideoKbps $how $name) 'DarkGray'
  if ($script:HeightCappedFrom -gt 0) {
    Say (T '  ({0}p instead of {1}p: at {2} kbps {0}p looks sharper. "HeightPolicy": "exact" in config.json keeps {1}p.)' $script:OutH $script:HeightCappedFrom $script:VideoKbps) 'DarkGray'
  }
  # (The control window shows this line orange with the advice; here it is said once.)
  if (-not $script:LowTipShown -and (Get-QualityLine).Low) {
    $script:LowTipShown = $true
    Say (T '  Too few bits for this picture size, so it looks blocky. A smaller picture size (V) looks sharper.') 'Yellow'
  }
}
$script:LowTipShown = $false

# The picture and bitrate in one short line for the control window, and whether it is too few bits for the size.
function Get-QualityLine {
  $fps = [Math]::Round($script:StreamFpsNum, 2)
  $bpp = 0.0
  if ($script:OutW -gt 0 -and $script:OutH -gt 0 -and $script:StreamFpsNum -gt 0) { $bpp = $script:VideoKbps * 1000.0 / ($script:OutW * $script:OutH * $script:StreamFpsNum) }
  # (The chip in the control window's title row: "<host> - <picture> <fps> fps <kbps> kbps".)
  if ($script:HostP) { $txt = T '{0} - {1}p {2} fps {3} kbps' $script:HostP.Name $script:OutH (Format-Num $fps) $script:VideoKbps }
  else { $txt = T '{0}p {1} fps {2} kbps' $script:OutH (Format-Num $fps) $script:VideoKbps }
  return [pscustomobject]@{ Text = $txt; Low = ($bpp -gt 0 -and $bpp -lt 0.04) }
}

# The picture sizes to choose from: Value = the height (0 = auto), Label (the resolution menu and the control window's).
function Get-ResolutionChoices {
  $ceil = Get-KbpsCeiling
  $autoH = Get-AutoHeight $ceil
  $list = @()
  foreach ($r in @(@{ H = 0; Min = 0 }) + $script:Resolutions) {
    $h = [int]$r.H
    if ($h -le 0) {
      $o = T 'Auto - the sharpest this host carries well (now {0}p, {1} kbps)' $autoH (Get-QualityKbps $autoH)
    } else {
      $o = T '{0}p - {1} kbps' $h (Get-QualityKbps $h)
      if ($ceil -lt $r.Min * (Get-FpsFactor)) { $o += ' ' + (T '(too big for {0} kbps: blurry when things move)' $ceil) }
    }
    $list += [pscustomobject]@{ Value = $h; Label = $o }
  }
  return $list
}

# The resolution menu. $true = the setting changed (saved in config.json). $Pick: the height already chosen (the
# control window's menu; 0 = auto): no question.
function Select-Resolution($Pick = $null) {
  if (-not $script:Interactive) { return $false }
  $cur = Get-HeightSetting
  $choices = @(Get-ResolutionChoices)
  $hs = @($choices | ForEach-Object { [int]$_.Value })
  $i = -1
  $pv = 0
  if ($null -ne $Pick -and [int]::TryParse("$Pick", [ref]$pv)) { $i = [array]::IndexOf($hs, $pv) }
  if ($i -lt 0) {
    $opts = @()
    foreach ($c in $choices) {
      $o = $c.Label
      if ([int]$c.Value -eq $cur) { $o = T '{0}  <- now' $o }
      $opts += $o
    }
    $ci = [array]::IndexOf($hs, $cur)
    if ($ci -lt 0) { $ci = 0; Say (T 'Now: {0}p (set in config.json).' $cur) 'Gray' }
    Say ''
    # (Esc = keep the size as it is: not offered when config.json's size isn't in the list, so Esc can't pick Auto.)
    if ([array]::IndexOf($hs, $cur) -ge 0) { $i = Read-Choice (T 'Which picture size should the stream have?') $opts $ci $false -Key 'res' -Values $hs -Esc $ci }
    else { $i = Read-Choice (T 'Which picture size should the stream have?') $opts $ci $false -Key 'res' -Values $hs }
  }
  $h = $hs[$i]
  if ($h -eq $cur) { return $false }
  Lock-NavStep
  $val = 'auto'
  if ($h -gt 0) { $val = $h }
  if ($script:Cfg.PSObject.Properties['Height']) { $script:Cfg.Height = $val } else { $script:Cfg | Add-Member -NotePropertyName Height -NotePropertyValue $val }
  try { Save-Config $script:Cfg } catch { Say (T 'Couldn''t update config.json: {0}' $_.Exception.Message) 'Yellow' }
  return $true
}

# ------------------------------------------------------------------ the VRChat world's video player (read from VRChat's log)
# VRChat writes what a world's video player does into its log file on this PC. From it this tool knows:
#  - whether the player here shows the stream right now (so a video starts only once the player shows it, and waits
#    again when the player lost the stream), and how far behind live viewers are (the player's buffer);
#  - commands: the stream link loaded with &pause / &play / &next / &back / &sync added (Topaz ignores that part),
#    and the pause / play / stop buttons of ProTV, iwaSync3 and YamaPlayer.
$script:VrcLog = $null
$script:RemoteNextPoll = [datetime]::MinValue
$script:WorldUrl = ''          # the last video address a player in the world loaded
$script:Players = @{}          # a world player (ProTV screen, iwaSync, YamaPlayer) -> @{ Url; Paused; Stopped; PausedAt; AutoPlayUntil }
$script:JoinGraceUntil = [datetime]::MinValue
$script:VrcRunning = $false
# The player here and our stream. State: none (not showing it), loading, playing, failed, stopped.
$script:Vrc = [pscustomobject]@{ State = 'none'; LoadAt = [datetime]::MinValue; PlayAt = [datetime]::MinValue; FailAt = [datetime]::MinValue
  PlayTs = $null; Opening = ''; Vp = ''; Sync = @{} }   # Sync: per ProTV TV, its last periodic position report @{ Ts; X }
$script:DriftResync = 8.0      # the player here this many seconds behind (froze): everyone reconnects (0 = off)
$script:LostHandled = [datetime]::MinValue
$script:LostMuted = $false
$script:VrcLastNow = [datetime]::MinValue

function Get-StreamKey {
  if ($script:HostP -and $script:HostP.Key) { return [string]$script:HostP.Key }
  $m = [regex]::Match([string]$script:Cfg.PcUrl, '/([^/?#]+)/?(?:[?#].*)?$')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}

function Find-VRChatLog {
  if (-not $env:USERPROFILE -and -not $env:VRCLM_VRCLOG_DIR) { return $null }
  $dir = ''
  if ($env:USERPROFILE) { $dir = PathJoin $env:USERPROFILE 'AppData\LocalLow\VRChat\VRChat' }
  if ($env:VRCLM_VRCLOG_DIR) { $dir = $env:VRCLM_VRCLOG_DIR }
  if (-not [System.IO.Directory]::Exists($dir)) { return $null }
  $f = @([System.IO.Directory]::GetFiles($dir, 'output_log_*.txt') | Sort-Object { [System.IO.File]::GetLastWriteTimeUtc($_) } -Descending | Select-Object -First 1)
  if ($f.Count -eq 0) { return $null }
  return $f[0]
}

function Test-VRChatRunning {
  if ($env:VRCLM_VRCLOG_DIR) { return $true }   # tests feed a fake log
  try { return (@([System.Diagnostics.Process]::GetProcessesByName('VRChat')).Count -gt 0) } catch { return $false }
}

function Start-WorldPlayerControl {
  $on = Get-Prop $script:Cfg 'WorldPlayerControl'
  if ($null -ne $on -and -not [bool]$on) { return }
  if (-not (Get-StreamKey)) { return }
  $f = Find-VRChatLog
  $pos = 0L
  if ($f) { $pos = (New-Object System.IO.FileInfo($f)).Length }   # only what happens from now on
  $script:VrcLog = [pscustomobject]@{ Path = $f; Pos = $pos; Rest = ''; NextScan = (Get-Date).AddSeconds(20) }
  $script:VrcRunning = Test-VRChatRunning
}

# Is VRChat running here with its log readable, so this tool can see what the world's player does?
function Test-VrcWatching { return ($script:VrcLog -and $script:VrcRunning) }

# New complete lines of VRChat's log since the last call. Follows VRChat to a new log file when it restarts.
function Read-VrcLogLines {
  $L = $script:VrcLog
  $now = Get-Date
  if ($now -ge $L.NextScan) {
    $L.NextScan = $now.AddSeconds(20)
    $f = Find-VRChatLog
    if ($f -and $f -ne $L.Path) { $L.Path = $f; $L.Pos = 0L; $L.Rest = '' }
    $was = $script:VrcRunning
    $script:VrcRunning = Test-VRChatRunning
    if ($was -and -not $script:VrcRunning) { $script:Vrc.State = 'none' }
  }
  if (-not $L.Path) { return @() }
  $text = ''
  try {
    $fs = New-Object System.IO.FileStream($L.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try {
      if ($fs.Length -lt $L.Pos) { $L.Pos = 0L }
      if ($fs.Length -eq $L.Pos) { return @() }
      [void]$fs.Seek($L.Pos, [System.IO.SeekOrigin]::Begin)
      $take = [int][Math]::Min(1048576, $fs.Length - $L.Pos)
      $buf = New-Object byte[] $take
      $n = $fs.Read($buf, 0, $take)
      $L.Pos += $n
      $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
    } finally { $fs.Dispose() }
  } catch { return @() }
  $text = $L.Rest + $text
  $parts = $text -split "`r?`n"
  $L.Rest = $parts[$parts.Count - 1]
  if ($parts.Count -le 1) { return @() }
  return @($parts[0..($parts.Count - 2)])
}

# The command in a control link (our own stream link + &pause / &play / &next / &back / &fwd / &sync), or $null.
# Accepts ?cmd as well as &cmd, and letters or a number after the word (so the same command can be sent twice in a
# row: &next, then &next2). For back / fwd the number is the seconds (&back30); plain &back is 10 s.
function Get-ControlLinkCommand([string]$url) {
  $key = [regex]::Escape((Get-StreamKey))
  $m = [regex]::Match($url, "^(?i)[a-z]+://[^/]+/(?:[^/?#]+/)*$key(?:/[^/?#]*)?\?([^#\s']*)$")
  if (-not $m.Success) { return $null }
  foreach ($part in ($m.Groups[1].Value -split '[&?]')) {
    $w = [regex]::Match($part, '^(?i)(?:(?:vrclm|cmd|c)=)?(pause|stop|hold|play|resume|continue|go|next|skip|back|rewind|rew|forward|fwd|ff|resync|sync)(\d{0,4})[\w.~-]*$')
    if (-not $w.Success) { continue }
    $n = 0
    [void][int]::TryParse($w.Groups[2].Value, [ref]$n)
    switch ($w.Groups[1].Value.ToLowerInvariant()) {
      { $_ -in @('pause', 'stop', 'hold') } { return (New-Cmd 'pause' $null 'link') }
      { $_ -in @('play', 'resume', 'continue', 'go') } { return (New-Cmd 'resume' $null 'link') }
      { $_ -in @('back', 'rew', 'rewind') } { if ($n -le 0) { $n = 10 }; return (New-Cmd 'seek' (-$n) 'link') }
      { $_ -in @('fwd', 'forward', 'ff') } { if ($n -le 0) { $n = 10 }; return (New-Cmd 'seek' $n 'link') }
      { $_ -in @('sync', 'resync') } { return (New-Cmd 'sync' $null 'link') }
      default { return (New-Cmd 'skip' $null 'link') }
    }
  }
  return $null
}

function Test-OwnStreamUrl([string]$url) {
  $key = Get-StreamKey
  return ($key -and $url -match ('/' + [regex]::Escape($key) + '(?:[?/#&]|$)'))
}

function Get-VrcLineTime([string]$t) {
  $m = [regex]::Match($t, '^(\d{4})\.(\d\d)\.(\d\d) (\d\d):(\d\d):(\d\d)')
  if (-not $m.Success) { return $null }
  try { return (New-Object DateTime ([int]$m.Groups[1].Value), ([int]$m.Groups[2].Value), ([int]$m.Groups[3].Value), ([int]$m.Groups[4].Value), ([int]$m.Groups[5].Value), ([int]$m.Groups[6].Value)) } catch { return $null }
}

# The player here started showing our stream.
function Set-VrcPlaying([datetime]$now, $ts) {
  $v = $script:Vrc
  if ($v.State -ne 'playing') { $v.PlayAt = $now; $v.PlayTs = $ts }
  $v.State = 'playing'
  $script:LostMuted = $false
}

# One log line: updates what the player here is doing, and returns a command (New-Cmd) or $null.
function Get-WorldPlayerCommand([string]$line) {
  # Quick check first: VRChat's log is busy and most lines are about other things.
  if ($line -notmatch '(?i)video|url|tv|opening|wrld|world|iwasync|yama|playing|livestream|texture|refresh') { return $null }
  $t = $line -replace '<[^>]*>', ''
  $now = Get-Date
  # Lines read in one go would all get the same time (a load and its start then look simultaneous): keep their order.
  if ($now -le $script:VrcLastNow) { $now = $script:VrcLastNow.AddTicks(1) }
  $script:VrcLastNow = $now
  $v = $script:Vrc
  # Joining a world replays the state of its players (a control link someone loaded, a paused TV): ignore that.
  if ($t -match 'Joining wrld_') { $script:JoinGraceUntil = [datetime]::MaxValue; $script:Players = @{}; $script:WorldUrl = ''; $v.State = 'none'; $v.Opening = ''; return $null }
  if ($t -match 'Finished entering world') { $script:JoinGraceUntil = $now.AddSeconds(20); return $null }
  $inGrace = ($now -lt $script:JoinGraceUntil)
  $ts = Get-VrcLineTime $t

  $pm = [regex]::Match($t, '\[ATA? ?\|?[^\]]*?\bTVManager\w* \(([^)]*)\)\] ?(.*)$')   # ProTV 2 and 3
  $pmsg = ''
  $ptv = $null
  if ($pm.Success) {
    $pmsg = $pm.Groups[2].Value; $ptv = 'protv:' + $pm.Groups[1].Value
    # Why ProTV loads next: someone entered / reloaded it (_ChangeMedia; _PostDeserialization = the TV's owner, for
    # everyone) or it retries by itself (AutoRetry) / plays after its stop (play).
    $m = [regex]::Match($pmsg, '^Refresh triggered for [\d.]+ seconds from now, from source: (.+)$')
    if ($m.Success) { $script:LastRefreshSrc = $m.Groups[1].Value.Trim() }
  }

  # --- is the player here showing our stream?
  $m = [regex]::Match($t, '\[AVProVideo\] Opening (\S+) \(offset')
  if ($m.Success) { $v.Opening = $m.Groups[1].Value }
  if ($t -match '\[AVProVideo\] Using playback path:' -and (Test-OwnStreamUrl $v.Opening)) { Set-VrcPlaying $now $ts }
  if ($t -match '\[AVProVideo\] Error: Loading failed' -and (Test-OwnStreamUrl $v.Opening)) { $v.State = 'failed'; $v.FailAt = $now }
  $m = [regex]::Match($t, '\[USharpVideo\] Started video: (\S+)')
  if ($m.Success -and (Test-OwnStreamUrl $m.Groups[1].Value)) { Set-VrcPlaying $now $ts }
  $m = [regex]::Match($t, '\(([^/)]+)[^)]*\)\] Media Started \[([^\]]+)\]')
  if ($m.Success -and (Test-OwnStreamUrl $m.Groups[2].Value)) {
    Set-VrcPlaying $now $ts
    $p = $script:Players['protv:' + $m.Groups[1].Value]
    if ($p) { $p.AutoPlayUntil = $now.AddSeconds(2.5) }   # ProTV sends a "play" right after every start: not a button
  }
  if ($pm.Success) {
    $m = [regex]::Match($pmsg, '^\[[^\]]+\] \([^)]*\) Now Playing: (\S+)')
    if ($m.Success -and (Test-OwnStreamUrl $m.Groups[1].Value)) {
      Set-VrcPlaying $now $ts
      $p = $script:Players[$ptv]
      if ($p) { $p.AutoPlayUntil = $now.AddSeconds(2.5) }
    }
    if ($pmsg -match '^Livestream has stopped\.' -and (Test-OwnStreamUrl $v.Opening)) { $v.State = 'failed'; $v.FailAt = $now; $v.Sync = @{} }
    # ProTV logs where its player is every 5 minutes. Less progress than the time that passed means the player here
    # froze for that long and is now that far behind the others (seen when the stream's H.264 header changed):
    # everyone reconnects to the live picture (Receive-WorldCommands, only while a video plays).
    $m = [regex]::Match($pmsg, '^Sync enforcement requested for live or local\. Updating to ([\d.]+)')
    if ($m.Success -and $ts -and $v.State -eq 'playing' -and (Test-OwnStreamUrl $v.Opening)) {
      $x = 0.0
      [void][double]::TryParse($m.Groups[1].Value, [System.Globalization.NumberStyles]::Float, $script:Inv, [ref]$x)
      # (Per TV: a world can have several, each with its own clock.)
      $prev = $v.Sync[$ptv]
      $v.Sync[$ptv] = @{ Ts = $ts; X = $x }
      if ($prev -and -not $inGrace -and $script:DriftResync -gt 0) {
        $dt = ($ts - $prev.Ts).TotalSeconds
        $lag = $dt - ($x - $prev.X)
        if ($dt -ge 200 -and $dt -le 400 -and $x -gt $prev.X -and $lag -ge $script:DriftResync) {
          $v.Sync = @{}
          $c = New-Cmd 'resync' $null 'player'
          $c | Add-Member -NotePropertyName Lag -NotePropertyValue $lag
          return $c
        }
      }
    }
    # How far behind live viewers are: ProTV shows the first real picture once the player's buffer is full.
    # Not for its low-latency player: it keeps almost no buffer (measured about 0.5-1 s behind live, steadily), so the
    # wait before its first picture is the connection opening, not a buffer.
    $m = [regex]::Match($pmsg, '^Texture updating to (\d+)x(\d+)')
    if ($m.Success -and $v.State -eq 'playing' -and $v.PlayTs -and $ts -and -not ($m.Groups[1].Value -eq '1024' -and $m.Groups[2].Value -eq '512') -and $m.Groups[1].Value -ne '16') {
      $d = ($ts - $v.PlayTs).TotalSeconds
      $v.PlayTs = $null
      if (Test-LowLatencyVp $v.Vp) { Set-ViewerDelay 2.0 }
      elseif ($d -ge 0 -and $d -le 20) { Set-ViewerDelay ($d + 1.0) }
    }
  }

  # --- a player loaded a video address
  $url = $null
  $player = $null
  $m = [regex]::Match($t, "\[Video Playback\] (?:Resolving|Attempting to resolve) URL '([^']+)'")
  if ($m.Success) { $url = $m.Groups[1].Value }
  if (-not $url) { $m = [regex]::Match($t, '\[AVProVideo\] Opening ((?:rtspt?|rtspu|rtmps?|https?)://\S+) \(offset'); if ($m.Success) { $url = $m.Groups[1].Value } }
  if (-not $url) { $m = [regex]::Match($t, '\[USharpVideo\] Started video load for URL: (\S+?)(?:, requested by|$)'); if ($m.Success) { $url = $m.Groups[1].Value; $player = 'usharp' } }
  if (-not $url -and $pm.Success) {
    $m = [regex]::Match($pmsg, '^\[([^\]]+)\] loading URL: (\S+)')
    if ($m.Success) { $url = $m.Groups[2].Value; $player = $ptv; $v.Vp = $m.Groups[1].Value }
  }
  if (-not $url) { $m = [regex]::Match($t, '\[iwaSync3\] (?:Load the video with the URL|The URL has changed to) `([^`]*)`'); if ($m.Success) { $url = $m.Groups[1].Value; $player = 'iwasync' } }
  if (-not $url) { $m = [regex]::Match($t, '\[YamaStream\] (?:Load url|Play track): (\S+?)\.?$'); if ($m.Success) { $url = $m.Groups[1].Value; $player = 'yama' } }
  if ($url) {
    $url = $url.Trim()
    $own = Test-OwnStreamUrl $url
    $why = ''
    if ($player -like 'protv:*') { $why = $script:LastRefreshSrc; $script:LastRefreshSrc = '' }
    # Entered or reloaded by a person (not a retry of the TV itself); USharpVideo logs only such loads.
    $deliberate = ($player -eq 'usharp') -or ($why -match '^(?:_ChangeMedia|_PostDeserialization)')
    $p = $null
    if ($player) {
      $p = $script:Players[$player]
      # The player that showed our stream switched to something else.
      if ($p -and -not $own -and (Test-OwnStreamUrl $p.Url)) { $v.State = 'none' }
      # A reload of the same address keeps what the player was doing (a paused TV stays paused).
      if (-not $p -or $p.Url -ne $url) { $p = @{ Url = $url; Paused = $false; Stopped = $false; PausedAt = [datetime]::MinValue; AutoPlayUntil = [datetime]::MinValue } }
      $p.Url = $url
      $script:Players[$player] = $p
    }
    if ($own) {
      # Every load of our stream is a new connection: the player shows it again only after this.
      $v.State = 'loading'
      $v.LoadAt = $now
      $v.Sync = @{}
    }
    $same = ($url -eq $script:WorldUrl)
    $script:WorldUrl = $url
    if ($inGrace -or -not $own) { return $null }
    # The TV's own stop, then the link put in again (instead of its play button): continue.
    if ($p -and $p.Stopped) { $p.Stopped = $false; $p.Paused = $false; return (New-Cmd 'resume' $null 'link') }
    # The same address again is the player reloading what it had (retries, several lines per load) - unless a person
    # entered it again or the TV's owner reloaded it (then every player in the world reconnects).
    if ($same -and -not $deliberate) { return $null }
    $c = Get-ControlLinkCommand $url
    # Our plain link loaded again: every player in the world reconnects, like &sync.
    if (-not $c) { $c = New-Cmd 'sync' 'plain' 'link' }
    return $c
  }

  # --- a player's own pause / play / stop buttons, while that player shows our stream
  $ev = $null
  if ($pm.Success) {
    $m = [regex]::Match($pmsg, '^Forwarding event _Tv(Pause|Play|Stop)\b')
    if ($m.Success) { $ev = $m.Groups[1].Value.ToLowerInvariant(); $player = $ptv }
    elseif ($pmsg -match '^Refresh video via Play') { $ev = 'replay'; $player = $ptv }
  }
  if (-not $ev) { $m = [regex]::Match($t, '\[iwaSync3\] Received a (pause|play) event'); if ($m.Success) { $ev = $m.Groups[1].Value; $player = 'iwasync' } }
  if (-not $ev) { $m = [regex]::Match($t, '\[YamaStream\] \w+: Video (pause|play)\.'); if ($m.Success) { $ev = $m.Groups[1].Value; $player = 'yama' } }
  if (-not $ev) { return $null }
  $p = $script:Players[$player]
  if (-not $p -or -not (Test-OwnStreamUrl $p.Url)) { return $null }
  $v.Sync = @{}   # (a pause stops the player's clock on purpose)
  if ($ev -eq 'stop') { $v.State = 'stopped' }
  if ($inGrace) { return $null }
  switch ($ev) {
    'pause' { if ($p.Paused) { return $null }; $p.Paused = $true; $p.PausedAt = $now; return (New-Cmd 'pause' $null 'button') }
    'stop' { if ($p.Stopped) { return $null }; $p.Stopped = $true; $p.Paused = $false; return (New-Cmd 'pause' $null 'button') }
    'replay' {
      # Play after the TV's own stop: it loads the stream again (for everyone); continue once it shows it.
      if (-not $p.Stopped) { return $null }
      $p.Stopped = $false; $p.Paused = $false
      if ($v.State -eq 'playing') { $v.State = 'loading'; $v.LoadAt = $now }
      $c = New-Cmd 'resume' $null 'link'
      return $c
    }
    'play' {
      # A play right after loading is the player starting by itself; only a play after its own pause means "continue".
      if (-not $p.Paused -or $now -lt $p.AutoPlayUntil) { return $null }
      $p.Paused = $false
      $c = New-Cmd 'resume' $null 'button'
      $c | Add-Member -NotePropertyName PausedFor -NotePropertyValue ($now - $p.PausedAt).TotalSeconds
      $c | Add-Member -NotePropertyName Player -NotePropertyValue $player
      return $c
    }
  }
  return $null
}

# ProTV's low-latency player (VP_AVProLL). Measured through Topaz over TCP with Windows' own player (the engine AVPro
# uses): the HQ mode (VP_AVProHQ) about 5.5 s behind live, the low-latency mode about 0.5-1 s.
function Test-LowLatencyVp([string]$vp) { return ($vp -match '(?i)LL$|low.?latency') }

function Set-ViewerDelay([double]$d) {
  $d = [Math]::Max(1.0, [Math]::Min(15.0, $d))
  $old = $script:ViewerDelay
  $script:ViewerDelay = $d
  if (-not $script:DelayTipShown -and $d -ge 4) {
    $script:DelayTipShown = $true
    Say (T '  The world''s player shows the stream about {0} s behind live (it buffers that much).' ([int][Math]::Round($d))) 'DarkGray'
    if ($script:Vrc.Vp -match '(?i)HQ') {
      Say (T '  Tip: the TV uses its HQ player, which buffers live streams (5 s and more). If the TV lets you pick a low-latency player ("LL"), switch to it: about 1 s behind, and pausing shows up at once.') 'DarkGray'
    }
  } elseif ($env:VRCLM_DEBUG -and [Math]::Abs($old - $d) -gt 0.5) { Say "viewer delay: $d s" 'DarkGray' }
}

# Commands from the world's player (read from VRChat's log), queued with the rest.
function Receive-WorldCommands([string]$kind) {
  if (-not $script:VrcLog) { return }
  $now = Get-Date
  if ($now -lt $script:RemoteNextPoll) { return }
  $script:RemoteNextPoll = $now.AddMilliseconds(400)
  foreach ($line in @(Read-VrcLogLines)) {
    $c = Get-WorldPlayerCommand $line
    if ($c -and $c.Cmd -eq 'resync' -and $c.From -eq 'player') {
      # The player here fell behind (a freeze): only worth a reconnect while a video plays.
      if ($kind -ne 'content' -or ((Get-Date) - $script:ResyncedAt).TotalSeconds -lt 60) { continue }
      Say (T '  Your VRChat player froze for about {0} s and is that far behind the others - reconnecting everyone to the live picture.' ([int][Math]::Round($c.Lag))) 'Yellow'
    }
    if ($c) { $c.At = $script:VrcLastNow; Add-Cmd $c }   # (the time of its own line)
  }
  # The player here lost the stream while a video plays: hold the video until it is back (so nothing is missed).
  $v = $script:Vrc
  if ($kind -eq 'content' -and $v.State -eq 'failed' -and $v.FailAt -gt $script:LostHandled -and $script:HoldOnDrop -and -not $script:LostMuted -and (Test-VrcWatching)) {
    $script:LostHandled = $v.FailAt
    Add-Cmd (New-Cmd 'lost' $null 'player')
  }
}

# ------------------------------------------------------------------ waiting for the players ("hold")
# A hold keeps viewers on the "Starting in a moment" screen until the world's player here shows the stream, so
# nobody misses the start of a video (or what came after a pause / a reconnect).
#  Reason start : a brand-new connection. Ready once the player here shows the stream.
#  Reason reload: the players are reconnecting (a control link, a resync, a lost connection). Ready once the player
#                 here shows the stream again, or after a while.
#  Reason button: the TV's own play after its pause. Ready right away unless the TV reloads the stream.
function New-Hold([string]$reason, [double]$maxWait = 60, $since = $null) {
  $now = Get-Date
  if (-not $since) { $since = $now }
  return [pscustomobject]@{ Reason = $reason; Since = $since; Deadline = $now.AddSeconds($maxWait); Restarted = $false; NextHint = $now.AddSeconds(60) }
}

# The hold after a command that made the world's players reload (a control link).
function New-CmdHold($c) {
  if ($c -and $c.From -eq 'link') { return (New-Hold 'reload' 60 $c.At) }
  return $null
}

function Test-HoldReady($h) {
  if (-not $h) { return $true }
  $now = Get-Date
  $v = $script:Vrc
  $lead = $script:StartDelay
  if (Test-VrcWatching) {
    if ($h.Reason -eq 'start') {
      # (Playing from before this connection opened is only believed after a while: its failure may not be logged.)
      if ($v.State -eq 'playing' -and ($v.PlayAt -ge $script:RelayStartedAt -or $now -ge $h.Since.AddSeconds(20))) { return ($now -ge $v.PlayAt.AddSeconds($lead)) }
      return $false
    }
    if ($v.State -eq 'playing' -and $v.PlayAt -gt $h.Since) { return ($now -ge $v.PlayAt.AddSeconds($lead)) }
    if ($h.Reason -eq 'button' -and $v.LoadAt -le $h.Since -and $now -ge $h.Since.AddSeconds(1.0)) { return $true }
    # While the player here can't show the stream, going on would only play the video to nobody (Space still starts it).
    if ($h.Reason -ne 'button' -and ($v.State -eq 'failed' -or $v.State -eq 'stopped')) { return $false }
    # (Nor while it retries: each retry is "loading" for a moment, then fails again.)
    if ($h.Reason -ne 'button' -and $v.State -ne 'playing' -and $v.FailAt -gt $v.PlayAt) { return $false }
    return ($now -ge $h.Deadline)
  }
  # VRChat doesn't run on this PC: the start waits for Space; after a reconnect players get a few seconds.
  if ($h.Reason -eq 'start') { return (-not $script:HasConsole) }
  if ($h.Reason -eq 'button') { return $true }
  return ($now -ge $h.Since.AddSeconds(8))
}

function Get-HoldText($h, $media, [double]$at) {
  $v = $script:Vrc
  $pos = ''
  if ($at -gt 1) { $pos = ' ' + (T 'at {0}' (Format-Time $at)) }
  if (-not (Test-VrcWatching)) {
    if ($h.Reason -eq 'start') { return (T '  Ready{0}. Viewers see "Starting in a moment". Press Space to start.' $pos) }
    return (T '  Waiting a few seconds for the players to reconnect...   Space = go on now')
  }
  if ($v.State -eq 'playing' -and ($h.Reason -eq 'start' -or $v.PlayAt -gt $h.Since)) {
    $left = [Math]::Max(0, [Math]::Ceiling(($v.PlayAt.AddSeconds($script:StartDelay) - (Get-Date)).TotalSeconds))
    return (T '  The world''s player shows the stream - starting{0} in {1} s...   Space = now' $pos $left)
  }
  if ($v.State -eq 'failed' -and ((Get-Date) - $v.FailAt).TotalSeconds -gt 10) {
    return (T '  The world''s player gave up on the stream: press Reload (or put the link in again) in the world.   Space = start anyway')
  }
  if ($h.Reason -eq 'start') { return (T '  Starting{0} as soon as the world''s player shows the stream (put the link in it).   Space = start now' $pos) }
  return (T '  Waiting for the players to reconnect before going on{0}...   Space = go on now' $pos)
}

# ------------------------------------------------------------------ the status line and the control window
function Get-StatusText([string]$kind, $src, $media, [double]$pos, $speed, $hold, [double]$holdAt) {
  if ($script:TypeBuf.Length -gt 0) {
    $what = T 'add'
    if ((Get-Command Test-SearchQuery -CommandType Function -ErrorAction SilentlyContinue) -and (Test-SearchQuery $script:TypeBuf)) { $what = T 'search' }
    return (T '  Type: {0}   (Enter = {1}, Esc = cancel)' $script:TypeBuf $what)
  }
  if ($kind -eq 'content') {
    $txt = '  > ' + (Format-Time $pos)
    if ($media.Info.Duration -gt 0) { $txt += ' / ' + (Format-Time $media.Info.Duration) }
    if ($null -ne $speed -and $speed -lt 0.97) { $txt += (T '   (slow: {0}x)' ($speed.ToString('0.00', $script:Inv))) }
    $txt += (T '   Space pause  <-/-> 10 s  S S next  Q Q stop  + add')
    $left = $script:Queue.Count - $script:Idx - 1
    if ($left -gt 0) { $txt += (T '   ({0} more queued)' $left) }
    return $txt
  }
  if ($kind -eq 'paused') { return (T '  || Paused at {0}. Viewers see "Paused".   Space continue  <-/-> move 10 s  S S next  Q Q stop' (Format-Time $script:PausedAt)) }
  if ($kind -eq 'hold') { return (Get-HoldText $hold $media $holdAt) }
  $nx = $null
  if ($script:Idx -lt $script:Queue.Count) { $nx = $script:Queue[$script:Idx] }
  if ($nx -and $nx.State -eq 'downloading') { return ((T '  Waiting screen is on. Next: {0}   Q Q = end' (Get-DownloadText $nx)) + (T '   M = menu')) }
  if ($nx) { return ((T '  Waiting screen is on. Getting {0} ready...   Q Q = end' $nx.Name) + (T '   M = menu')) }
  return ((T '  Waiting screen is on. Type a title or paste a link + Enter (Enter alone = pick files).   Q Q = end') + (T '   M = menu'))
}

function Show-Panel {
  if (-not (Get-Command Open-ControlPanel -CommandType Function -ErrorAction SilentlyContinue)) {
    Say (T '  The control window isn''t available (VRChatLinkMaker.Panel.ps1 is missing).') 'Yellow'
    return
  }
  $ok = $false
  try { $ok = [bool](Open-ControlPanel) } catch {}
  $script:PanelShown = $ok
  if (-not $ok) { Say (T '  The control window couldn''t open here.') 'Yellow' }
}

$script:PanelDlAt = [DateTime]::MinValue
$script:PanelDlTexts = @{}
function Update-Panel([string]$kind, $media, [double]$pos, [string]$status) {
  if (-not $script:PanelShown) { return }
  $script:PanelState = $null
  try {
    if (-not (Test-ControlPanelOpen)) { $script:PanelShown = $false; return }
    $title = ''
    if ($media) { $title = $media.Name }
    $dur = 0.0
    if ($media -and $media.Info -and $media.Info.Duration -gt 0) { $dur = $media.Info.Duration }
    # Up next: what comes after the video that plays; while nothing plays, from the one being got ready. The Ids go along
    # (the window's right-click menu names an item by its Id: Invoke-QueueCommand).
    $up = @()
    $upIds = @()
    $from = $script:Idx + 1
    if ($kind -eq 'waiting') { $from = $script:Idx }
    # (A download in progress - a torrent episode's too - says how far it is, as on the console's status line; looked at
    # once a second, not at every update of the window.)
    if (((Get-Date) - $script:PanelDlAt).TotalSeconds -ge 1) { $script:PanelDlAt = Get-Date; $script:PanelDlTexts = @{} }
    for ($i = $from; $i -lt [Math]::Min($script:Queue.Count, $from + 20); $i++) {
      $it = $script:Queue[$i]
      $nm = [string]$it.Name
      if ($it.State -eq 'downloading') {
        $dk = [int](Get-Prop $it 'Id')
        if (-not $script:PanelDlTexts.ContainsKey($dk)) { $dt = ''; try { $dt = [string](Get-DownloadText $it) } catch {}; $script:PanelDlTexts[$dk] = $dt }
        if ($script:PanelDlTexts[$dk]) { $nm += '  (' + $script:PanelDlTexts[$dk] + ')' }
      } elseif ($it.Kind -eq 'torrent' -and $it.State -eq 'torrent-meta') { $nm += '  (' + (T 'looking for people sharing it') + ')' }
      $up += $nm
      $upIds += [int](Get-Prop $it 'Id')
    }
    $mode = $kind
    if ($kind -eq 'waiting' -and -not (Test-RelayAlive)) { $mode = 'off' }
    $pl = ''
    if (Test-VrcWatching) {
      switch ($script:Vrc.State) {
        'playing' { $pl = T 'Your VRChat player shows the stream (about {0} s behind live).' ([int][Math]::Round($script:ViewerDelay)) }
        'loading' { $pl = T 'Your VRChat player is connecting to the stream...' }
        'failed' { $pl = T 'Your VRChat player lost the stream.' }
        'stopped' { $pl = T 'The TV is stopped.' }
        default { $pl = T 'Your VRChat player doesn''t show the stream.' }
      }
    }
    $ql = Get-QualityLine
    $qtip = T 'What the stream carries: picture size, frames per second, video bitrate, server.'
    if ($ql.Low) { $qtip += ' ' + (T 'Orange: too few bits for this picture size, so it looks blocky. A smaller picture size (Settings > Picture size) looks sharper.') }
    $quest = ''
    if ($script:HostP) { $quest = [string]$script:HostP.QuestUrl } elseif ($script:Cfg) { $quest = [string](Get-Prop $script:Cfg 'QuestUrl') }
    $s = @{ Mode = $mode; Title = $title; Position = $pos; Duration = $dur; Status = $status.Trim(); Player = $pl; Upcoming = $up; UpcomingIds = [int[]]$upIds
      Link = $script:ShownLink; QuestLink = $quest; Clock = $script:ClockOn; CanSeek = (($kind -eq 'content' -or $kind -eq 'paused' -or $kind -eq 'hold') -and -not ($media -and $media.IsLive))
      Quality = $ql.Text; QualityLow = $ql.Low; QualityTip = $qtip }
    $m = $null
    try { $m = Get-PanelMenuState } catch {}
    if ($m) { foreach ($k in $m.Keys) { $s[$k] = $m[$k] } }
    $script:PanelState = $s
    Update-ControlPanel $script:PanelState
  } catch { $script:PanelShown = $false }
}

# The Settings menu's items for the control window: the same list as M here (Get-MenuItems), with the choices of
# host, picture size and language (a pick there comes back with its choice, see Invoke-MenuAction). Made again only
# when something it shows changed (the languages are read from the lang folder once).
$script:PanelMenuCache = $null
$script:PanelLangs = $null
function Get-PanelMenuState {
  $hid = ''
  if ($script:HostP) { $hid = [string]$script:HostP.Id }
  $key = '{0}|{1}|{2}|{3}|{4}|{5}' -f $script:Lang, $hid, (Get-HeightSetting), (Get-KbpsCeiling), $script:StreamFpsNum, [bool](Test-HostModule)
  $c = $script:PanelMenuCache
  if ($c -and $c.Key -ceq $key) { return $c.Value }
  # (Made again e.g. when the first video sets the frame rate: no file reads then, the languages are kept from the first time.)
  if ($null -eq $script:PanelLangs) { $script:PanelLangs = @(); try { $script:PanelLangs = @(Get-Languages) } catch {} }
  $items = @()
  foreach ($it in @(Get-MenuItems)) {
    $on = $false
    if ($it.Need -eq 'lang') { $on = (@($script:PanelLangs).Count -gt 1) } else { $on = [bool](Test-MenuItemOn $it) }
    $items += @{ Id = [string]$it.Id; Label = [string]$it.Label; On = $on }
  }
  $hosts = @()
  if ((Test-HostModule) -and $script:HostIds) {
    $tips = @(Get-HostChoiceTexts)
    for ($i = 0; $i -lt $script:HostIds.Count; $i++) {
      $tip = ''
      if ($i -lt $tips.Count) { $tip = [string]$tips[$i] }
      $hosts += @{ Value = [string]$script:HostIds[$i]; Label = [string](Get-HostDisplayName $script:HostIds[$i]); Tip = $tip }
    }
  }
  $res = @()
  foreach ($r in @(Get-ResolutionChoices)) { $res += @{ Value = [string]$r.Value; Label = [string]$r.Label; Tip = '' } }
  $langs = @()
  foreach ($l in $script:PanelLangs) { $langs += @{ Value = [string]$l.Code; Label = [string]$l.Name; Tip = '' } }
  $v = @{ Menu = $items; Choices = @{ host = $hosts; res = $res; lang = $langs }
    Chosen = @{ host = $hid; res = [string](Get-HeightSetting); lang = [string]$script:Lang } }
  $script:PanelMenuCache = @{ Key = $key; Value = $v }
  return $v
}

# ------------------------------------------------------------------ running one source
# Runs one ffmpeg source (a video, the waiting / paused / starting screen) into the relay until it ends or a command
# ends it. Outcomes: done, skip, pause, resume, start, seek, sync, resync, lost, restart, stop, quit, ready, timeout,
# failed, relay, slow, playnow. .Cmd is the command that ended it, .Target the position to go on from (seek / pause).
function Invoke-Source {
  param([string]$Kind, $Media = $null, [double]$Start = 0, [switch]$UntilNextReady, $Hold = $null)
  # The screen a resync started with its new connection goes on (no gap in the picture right after players reconnect).
  $src = $script:Src
  $alive = $false
  if ($src -and $src.Adopt -and $src.Kind -eq $Kind) { try { $alive = -not $src.Proc.HasExited } catch {} }
  if (-not $alive) {
    if ($script:Src) { [void](Stop-Source $script:Src -Now) }
    if ($Kind -eq 'waiting') { $script:NoteAt = [datetime]::MinValue; Update-ScreenNote }
    $src = Start-Source $Kind $Media $Start
  }
  $src.Adopt = $false
  $off = $src.Off
  $proc = $src.Proc
  $copy = $src.Copy
  $progFile = $src.ProgFile
  $t0 = $src.T0
  $requested = $null
  $reqCmd = $null
  $target = $null
  $relayBroke = $false
  $stalled = $false
  $pos = 0.0
  $lastPos = -1.0
  $lastMove = $t0
  $speed = $null
  $markTime = $null
  $markPos = 0.0
  $slowCount = 0
  $slowWarned = $false
  $nextStatus = $t0
  $nextPanel = $t0
  $nextPoll = $t0.AddSeconds(2)
  $nextSave = $t0.AddSeconds(5)
  $quitSentAt = $null
  $idleSince = $t0
  $prevIter = $t0
  $holdAt = $Start
  if ($Kind -eq 'hold' -and $Media) { $holdAt = $Media.ResumeAt }
  # Only a failure of the player during THIS video counts as "lost" (not an old one, not the retries of a hold).
  if ($Kind -eq 'content' -and $script:Vrc.FailAt -gt $script:LostHandled) { $script:LostHandled = $script:Vrc.FailAt }
  Set-CtrlCAsKey $true
  while (-not $copy.IsCompleted) {
    $now = Get-Date
    # If this loop itself was paused (PC asleep, window frozen), don't mistake that for a stalled stream.
    if (($now - $prevIter).TotalSeconds -gt 3) { $lastMove = $now }
    $prevIter = $now
    if (-not (Test-RelayAlive)) { $relayBroke = $true; break }
    Receive-Commands $Kind
    if ($requested) {
      # Winding down: more "back / forward" presses add up.
      if ($requested -eq 'seek') { $target += (Get-QueuedSeek) }
    } else {
      $c = Get-NextCmd $Kind
      if ($c -and $Media -and $Media.IsLive -and ($c.Cmd -eq 'seek' -or $c.Cmd -eq 'seekto')) {
        [void](Get-QueuedSeek)
        Say (T '  This is a live stream: it can''t go back or forward.') 'Gray'
        $c = $null
      }
      if ($c) {
        $cur = $Start + $pos
        $pr = Read-Progress $progFile
        if ($pr) { $cur = $Start + [Math]::Max(0.0, $pr.Time - $off) }
        # Viewers see the stream this much later; a command from the world is about what they saw (and they can't
        # have seen anything from before this source started: they were still on the previous one).
        $seen = $cur
        $viewers = [Math]::Max($Start, $cur - $script:ViewerDelay - 1)
        if ($c.From -eq 'link' -or $c.From -eq 'button' -or $c.From -eq 'player') { $seen = $viewers }
        switch ($c.Cmd) {
          'seek' {
            if ($Kind -eq 'content') { $requested = 'seek'; $target = $seen + [double]$c.Arg + (Get-QueuedSeek) }
            elseif ($Kind -eq 'paused') {
              $script:PausedAt = Get-ClampedPos $Media ($script:PausedAt + [double]$c.Arg)
              Say (T '  Will continue from {0}.' (Format-Time $script:PausedAt)) 'Gray'
              if ($c.From -eq 'link') { $script:PendingHold = New-CmdHold $c }
            } else {
              if ($Media) { $Media.ResumeAt = Get-ClampedPos $Media ($Media.ResumeAt + [double]$c.Arg); $holdAt = $Media.ResumeAt; Say (T '  Will start from {0}.' (Format-Time $holdAt)) 'Gray' }
            }
          }
          'seekto' {
            if ($Kind -eq 'content') { $requested = 'seek'; $target = [double]$c.Arg }
            elseif ($Kind -eq 'paused') { $script:PausedAt = Get-ClampedPos $Media ([double]$c.Arg); Say (T '  Will continue from {0}.' (Format-Time $script:PausedAt)) 'Gray' }
            elseif ($Media) { $Media.ResumeAt = Get-ClampedPos $Media ([double]$c.Arg); $holdAt = $Media.ResumeAt; Say (T '  Will start from {0}.' (Format-Time $holdAt)) 'Gray' }
          }
          'pause' { $requested = 'pause'; $target = $cur - $script:ResumeBack; if ($seen -lt $cur) { $target = $seen } }
          'sync' { $requested = 'sync'; $target = $seen }
          'lost' { $requested = 'lost'; $target = $viewers }
          'resync' { $requested = 'resync'; $target = $viewers }
          'restart' { $requested = 'restart'; $target = $cur }
          default { $requested = $c.Cmd }
        }
        if ($requested) {
          $reqCmd = $c
          if ($Kind -eq 'content') { Send-Key $proc 'q' } else { Stop-Proc $proc }
          $quitSentAt = $now
          switch ($requested) {
            'skip' { Say (T '  Skipping...') 'Gray' }
            'playnow' { Say (T '  Switching to what you picked...') 'Gray' }
            'pause' { Say (T '  Pausing...') 'Gray' }
            'resume' { Say (T '  Continuing...') 'Gray' }
            'stop' { Say (T '  Stopping...') 'Gray' }
            'quit' { Say (T '  Ending the stream...') 'Gray' }
          }
        }
      }
    }
    if ($Kind -eq 'paused' -and -not $requested -and ($now - $t0).TotalMinutes -ge $script:PauseMaxMinutes) {
      $requested = 'timeout'; Stop-Proc $proc; $quitSentAt = $now
      Say (T 'The stream was paused for {0} minutes, so it is ending.' ($script:PauseMaxMinutes.ToString($script:Inv))) 'Gray'
    }
    if ($Kind -eq 'hold' -and -not $requested) {
      if (Test-HoldReady $Hold) { $requested = 'start'; Stop-Proc $proc; $quitSentAt = $now }
      elseif (Update-HoldHelpers $Hold) { $requested = 'renew'; Stop-Proc $proc; $quitSentAt = $now }
    }
    if (-not $requested -and $UntilNextReady) {
      $nx = $null
      if ($script:Idx -lt $script:Queue.Count) { $nx = $script:Queue[$script:Idx] }
      if ($nx) {
        $idleSince = $now
        $script:PromptOk = $script:Interactive
        $script:PrepAsk = -not $script:ChoosingMode   # (startup questions never time out)
        try { Step-Prep $nx } finally { $script:PromptOk = $false; $script:PrepAsk = $false }
        if ($nx.State -eq 'ready' -or $nx.State -eq 'failed') { $requested = 'ready'; Stop-Proc $proc; $quitSentAt = $now }
      } elseif (($now - $idleSince).TotalMinutes -ge $script:IdleMinutes) {
        $requested = 'timeout'; Stop-Proc $proc; $quitSentAt = $now
        Say (T 'Nothing new was added for {0} minutes, so the stream is ending.' ($script:IdleMinutes.ToString($script:Inv))) 'Gray'
      }
    }
    if ($quitSentAt -and ($now - $quitSentAt).TotalSeconds -gt 1.5) { Stop-Proc $proc; $quitSentAt = $null }
    if ($now -ge $nextStatus) {
      $nextStatus = $now.AddMilliseconds(500)
      $relayAge = ($now - $script:RelayStartedAt).TotalSeconds
      if ($script:RelayFails -gt 0 -and $relayAge -gt 60) { $script:RelayFails = 0 }
      if ($script:ReconnectNote -and $relayAge -gt 2) {
        # Only once the server takes the stream (bytes sent), not while it is still connecting.
        $rs = Read-RelaySize
        if ($rs -gt 0 -or ($rs -lt 0 -and $relayAge -gt 30)) { $script:ReconnectNote = $false; Say (T '  Connected to the stream server again.') 'Green' }
      }
      # The control window was opened meanwhile: start this source again with its preview.
      if (-not $requested -and -not $src.Preview -and (Test-PreviewWanted)) {
        $requested = 'restart'; $target = $Start + $pos
        if ($Kind -eq 'content') { Send-Key $proc 'q' } else { Stop-Proc $proc }
        $quitSentAt = $now
      }
      $pr = Read-Progress $progFile
      if ($pr) { $pos = [Math]::Max(0.0, $pr.Time - $off) }
      if ($pos -gt $lastPos + 0.05) { $lastPos = $pos; $lastMove = $now }
      # Real playback speed over the last ~10 s (1.00 = keeping up with real time).
      if (-not $markTime) { if ($pos -gt 0) { $markTime = $now; $markPos = $pos } }
      elseif (($now - $markTime).TotalSeconds -ge 10) {
        $span = ($now - $markTime).TotalSeconds
        $speed = ($pos - $markPos) / $span
        $markTime = $now; $markPos = $pos
        # Upload keeping up (for going back up after a step-down, Step-UpQuality). A video read straight from a server
        # that is slow says nothing about the upload.
        if ($Kind -eq 'content') {
          if ($speed -ge 0.97) { $script:FastSecs += $span }
          elseif ($speed -lt 0.93 -and -not $Media.IsDirectUrl) { $script:FastSecs = 0.0 }
        }
        # Which ones can be helped by a lighter stream:
        #  - a live stream (IsLive): comes at real time at best, a gap in it is the stream's (see the stall check
        #    below) - no check at all;
        #  - a site's stream or a plain link to a video file / playlist (IsDirectUrl): slow because of that server, a
        #    lighter stream wouldn't help - only a warning (a site's: the next ones download in advance);
        #  - a local file or a finished download: slow because of this PC or its upload - a notch lighter.
        if ($Kind -eq 'content' -and -not $slowWarned -and -not $Media.IsLive -and ($now - $t0).TotalSeconds -gt 20) {
          if ($speed -lt 0.93) { $slowCount++ } else { $slowCount = 0 }
          if ($slowCount -ge 2 -and -not $requested -and -not $Media.IsDirectUrl -and (Test-CanStepDown)) {
            # Falling behind real time means stutter for everyone: go a notch lighter and carry on from here.
            $script:SlowSpeed = $speed
            $requested = 'slow'; Send-Key $proc 'q'; $quitSentAt = $now
          } elseif ($slowCount -ge 2 -and $Media.IsDirectUrl) {
            $slowWarned = $true
            if ($Media.Kind -eq 'site') { Say (T '  The video site is sending this one slower than real time, so viewers may see stutter. The next videos download in advance, so they won''t have this problem.') 'Yellow' }
            else { Say (T '  The server this video comes from sends it slower than real time, so viewers may see stutter.') 'Yellow' }
          } elseif ($slowCount -ge 2) {
            $slowWarned = $true
            Say (T '  The stream is running slower than real time, so viewers will see stutter. Either your PC is too busy (close heavy programs, or set "Height" to 540 in config.json) or your internet upload is too slow (lower "VideoKbps" in config.json).') 'Yellow'
          }
        }
      }
      $st = Get-StatusText $Kind $src $Media ($Start + $pos) $speed $Hold $holdAt
      Show-Status (Join-StatusKeys $st (T '   M = menu')) -NoWindow
      $script:LastStatus = $st
    }
    if ($now -ge $nextPanel) {
      $nextPanel = $now.AddMilliseconds(200)
      $ppos = $Start + $pos
      if ($Kind -eq 'paused') { $ppos = $script:PausedAt } elseif ($Kind -eq 'hold') { $ppos = $holdAt }
      Update-Panel $Kind $Media $ppos $script:LastStatus
    }
    if ($now -ge $nextPoll) {
      $nextPoll = $now.AddSeconds(2)
      Receive-QueueFile
      Update-Prep
      Update-KeepAwake
      if ($Kind -eq 'waiting') { Update-ScreenNote }
      if ($script:PendingDirs.Count -gt 0) { Remove-PendingDirs }
      try { Update-UpnpLeases } catch {}
      # (Finished background programs: their handles and output aren't needed any more.)
      for ($i = $script:BgProcs.Count - 1; $i -ge 0; $i--) { try { if ($script:BgProcs[$i].Proc.HasExited -and $script:BgProcs[$i].Out.IsCompleted) { $script:BgProcs.RemoveAt($i) } } catch {} }
    }
    if ($Kind -eq 'content' -and $now -ge $nextSave) {
      $nextSave = $now.AddSeconds(5)
      if ($Media.Kind -eq 'file' -or $Media.Kind -eq 'site') { Save-State $Media.Source ($Start + $pos) }
    }
    if ($Kind -eq 'content' -and -not $requested) {
      if ($lastPos -gt 0 -and ($now - $lastMove).TotalSeconds -gt 20) { $stalled = $true; break }
      if ($lastPos -le 0 -and ($now - $t0).TotalSeconds -gt 90) { $stalled = $true; break }
    } elseif (-not $requested) {
      # A screen never waits for anything but the relay: when it stops moving, the server stopped taking the stream
      # (a connection that hangs instead of breaking).
      if (($lastPos -gt 0 -and ($now - $lastMove).TotalSeconds -gt 20) -or ($lastPos -le 0 -and ($now - $t0).TotalSeconds -gt 30)) {
        $stalled = $true; $script:RelayStuck = $true; break
      }
    }
    Start-Sleep -Milliseconds 60
  }
  Set-CtrlCAsKey $false
  if ($script:Src -eq $src) { $script:Src = $null }
  $sourceStalled = $false
  if ($relayBroke -or $stalled) {
    Stop-Proc $proc
    if ($stalled) {
      # A web stream that stalls is usually the site. If the relay takes the rest of the pipe once the
      # source is stopped, it's fine: keep it (and the viewers) connected and try the site again.
      if ($Kind -eq 'content' -and $Media.IsDirectUrl -and ($Media.Stream -or $Media.IsLive -or "$($Media.Path)" -match '^(?i)https?://')) {
        try { [void]$copy.Wait(4000) } catch {}
        $sourceStalled = ($copy.IsCompleted -and -not $copy.IsFaulted)
      }
      if (-not $sourceStalled) { Stop-Relay }
    }
  }
  try { [void]$proc.WaitForExit(6000) } catch {}
  Stop-Proc $proc
  try { [void]$copy.Wait(4000) } catch {}
  $copyFailed = $copy.IsFaulted
  $exit = $null
  try { $exit = $proc.ExitCode } catch {}
  if ($script:Current -eq $proc) { $script:Current = $null }
  $pr = Read-Progress $progFile
  if ($pr) { $pos = [Math]::Max(0.0, $pr.Time - $off) }
  if ($pr -and $pr.Time -gt $script:LastEnd) { $script:LastEnd = $pr.Time }
  elseif (-not $pr) { $script:LastEnd = [Math]::Max($script:LastEnd, $off + ((Get-Date) - $t0).TotalSeconds) }
  Clear-StatusLine
  $outcome = 'failed'
  if ($sourceStalled -and -not $relayBroke -and -not $copyFailed -and (Test-RelayAlive)) {
    $outcome = 'failed'
    # A live stream that stopped sending has ended (or is gone): on to the next video.
    if ($Media.IsLive) { $outcome = 'done'; Say (T '  The live stream stopped sending - going on.') 'Yellow' }
  }
  elseif ($relayBroke -or $stalled -or $copyFailed -or -not (Test-RelayAlive)) { $outcome = 'relay' }
  elseif ($requested) { $outcome = $requested }
  elseif ($exit -eq 0) { $outcome = 'done' }
  $errText = ''
  try { if ($src.Err.Wait(2000)) { $errText = Get-LastLines $src.Err.Result 1 } } catch {}
  if ($stalled -and -not $errText -and $Kind -eq 'content') { $errText = T 'the site stopped sending data' }
  $position = $Start + $pos
  if ($Kind -eq 'hold' -and $Media) { $position = $Media.ResumeAt }
  return [pscustomobject]@{ Outcome = $outcome; Position = $position; Target = $target; Cmd = $reqCmd; Elapsed = ((Get-Date) - $t0).TotalSeconds; ExitCode = $exit; Error = $errText }
}

# While a hold waits: a hint now and then, and one fresh connection when the player keeps failing on this one.
function Update-HoldHelpers($h) {
  if (-not $h) { return $false }
  $now = Get-Date
  $v = $script:Vrc
  # One new connection per failure episode: again only after the player showed the stream, or a few minutes later.
  $again = ($v.PlayAt -gt $script:RenewedAt) -or ((Get-Date) - $script:RenewedAt).TotalMinutes -ge 3
  if ((Test-VrcWatching) -and -not $h.Restarted -and $again -and $h.Reason -ne 'start' -and $v.State -eq 'failed' -and $v.FailAt -gt $h.Since.AddSeconds(3) -and
    ((Get-Date) - $script:RelayStartedAt).TotalSeconds -gt 15) {
    # The player keeps failing on a connection that looks fine from here: open a new one.
    $h.Restarted = $true
    $script:RenewedAt = Get-Date
    Say (T '  The world''s player can''t get the stream - opening a new connection to the server.') 'Yellow'
    return $true
  }
  if ($now -ge $h.NextHint -and $h.Reason -eq 'start' -and (Test-VrcWatching) -and $v.State -ne 'playing') {
    $h.NextHint = $now.AddSeconds(90)
    Say (T '  Still waiting for the world''s player to show the stream. Put your link in it, or press Space to start anyway.') 'DarkGray'
  }
  return $false
}

function Get-ClampedPos($media, [double]$p) {
  if ($p -lt 0) { $p = 0.0 }
  if ($media -and $media.Info -and $media.Info.Duration -gt 5 -and $p -gt $media.Info.Duration - 3) { $p = [Math]::Max(0.0, $media.Info.Duration - 3) }
  return $p
}

function Show-NowPlaying($item) {
  $n = $script:Idx + 1
  $total = $script:Queue.Count
  $dur = ''
  if ($item.Info -and $item.Info.Duration -gt 0) { $dur = ' (' + (Format-Time $item.Info.Duration) + ')' }
  Say ''
  Say (T '[{0}/{1}] Now streaming: {2}{3}' $n $total $item.Name $dur) 'Cyan'
  $bits = @()
  # A web video's only sound track is the voice-over shown under "From" (its language tag is often wrong).
  if ($item.AudioTrack -and -not ($item.Kind -eq 'site' -and @($item.Info.Audio).Count -le 1)) { $bits += (T 'Audio: {0}' (Get-TrackLabel $item.AudioTrack $true)) }
  if ($item.SubTrack) { $bits += (T 'Subtitles: {0}' (Get-TrackLabel $item.SubTrack $true)) } else { $bits += (T 'Subtitles: none') }
  Say ('  ' + ($bits -join '   |   ')) 'Gray'
  if ($item.Using) {
    $q = ''
    if ($item.Info -and $item.Info.Video -and $item.Info.Video.Height -gt 0) { $q = " ($($item.Info.Video.Height)p)" }
    Say (T '  From: {0}' ($item.Using.Label + $q)) 'Gray'
    if ($item.Using.Note) { Say (T '  Note: {0}' $item.Using.Note) 'Yellow' }
    foreach ($e in @($item.Errors | Select-Object -First 3)) { Say (T '  (skipped {0})' (Get-ShortText $e 110)) 'DarkGray' }
  }
  if ($item.SubWarn) { Say (T '  Note: {0}' $item.SubWarn) 'Yellow' }
  if ($item.FpsNote) { Say (T '  Note: {0}' $item.FpsNote) 'DarkGray' }
  if ($item.Info -and (Test-HdrVideo $item.Info.Video)) { Say (T '  Note: {0}' (T 'this is an HDR video: its colours may look washed out on the stream')) 'DarkGray' }
  if ($item.ResumeAt -gt 0) { Say (T '  Starting from {0}' (Format-Time $item.ResumeAt)) 'Gray' }
}

function Show-Controls {
  if ($script:ControlsShown) { return }
  $script:ControlsShown = $true
  Say ''
  Say (T '  Controls:  Space = pause / continue    Left / Right = 10 s back / forward (Shift: 30 s)') 'DarkCyan'
  Say (T '             S S = next video    Q Q = stop (then pick something else)    R R = resync everyone') 'DarkCyan'
  Say (T '             + = search / add in a second window    F2 = control window with preview') 'DarkCyan'
  Say (T '             M + Enter = settings menu (while nothing plays)') 'DarkCyan'
}

# Stops what plays and empties the queue; the stream stays on the air with the waiting screen, and the window
# waits for something else to stream (typed, pasted, dropped or searched).
function Clear-QueueForStop {
  if ($script:Idx -lt $script:Queue.Count) {
    for ($i = $script:Idx; $i -lt $script:Queue.Count; $i++) {
      $it = $script:Queue[$i]
      # (A download still running stops as a whole tree: yt-dlp's own ffmpeg too.)
      if ($it.Dl -and $it.Dl.Proc) { try { if (-not $it.Dl.Proc.HasExited) { Stop-ProcessTree $it.Dl.Proc } } catch {} }
      Remove-ItemFiles $it
    }
  }
  $script:Queue.Clear()
  $script:Idx = 0
  $script:QueueFinished = $false
  $script:Paused = $false
  # A start wait stays: nobody has the stream on their screen yet, so the next video waits for them too.
  if (-not ($script:PendingHold -and $script:PendingHold.Reason -eq 'start')) { $script:PendingHold = $null }
  $script:ChoosingMode = $true
  $script:IdleAnnounced = $true
  Say ''
  Say (T 'Stopped. Viewers see the waiting screen and stay connected.') 'Cyan'
  Say (T 'What next? Type a title to search, paste a link, or drag files into this window, then press Enter.') 'White'
  Say (T '  (Enter alone = pick files, Q Q = end the stream. The next time you pick the same video, it offers to continue where you stopped.)') 'Gray'
}

# Resync everyone: a new connection to the server makes every player in the world reconnect to the live picture.
# $next: the screen that comes next (hold, waiting or paused).
# Players are cut off the moment the old connection closes. ProTV with the plain link (no retry=-1) then tries again
# only once, about 6 s later, and gives up if the stream isn't back by then. Closing the old connection first and then
# opening a new one took about 6 s (most of it opening the connection to Topaz in Japan), so some players gave up.
# So the new connection opens while the old one is still on, and the old one closes as soon as the new one sends:
# the server then switches straight over (Topaz holds a second connection on the same link for about a second, waiting
# for the first to go, before it refuses it; MediaMTX switches to the newest one by itself). The stream is back within
# about a second of the cut.
function Restart-RelayForResync([string]$next = 'hold') {
  Say (T '  Resyncing: the stream reconnects, so every player jumps to the live picture (about 10 s). The video waits for them.') 'Cyan'
  if (-not (Test-VrcWatching) -or $script:Vrc.Vp -eq '') {
    Say (T '  (ProTV worlds reconnect by themselves. Other players may need Reload / Resync pressed once.)') 'DarkGray'
  }
  if ($script:Src) { [void](Stop-Source $script:Src -Now) }
  $locked = $script:FpsLocked
  $old = $script:Relay
  $oldProg = Get-RelayProgPath
  Start-ResyncRelay $next
  $scr = $script:Src
  $until = (Get-Date).AddSeconds(15)
  while ((Get-Date) -lt $until -and (Test-RelayAlive) -and (Read-RelaySize) -le 0 -and $scr -and -not $scr.Proc.HasExited) { Start-Sleep -Milliseconds 40 }
  if ($old) { Remove-Relay $old $oldProg }
  # Make sure the server kept the new one (it refuses it about a second after it began sending, if the old one stayed).
  $until = (Get-Date).AddSeconds(2)
  while ((Get-Date) -lt $until -and (Test-RelayAlive)) { Start-Sleep -Milliseconds 100 }
  if (-not (Test-RelayAlive) -or (Read-RelaySize) -le 0) {
    # Refused after all: open a new connection now that the old one is closed.
    Stop-Relay
    Start-ResyncRelay $next
  }
  $script:RelayFresh = $false
  $script:FpsLocked = $locked   # (a resync before any video leaves the frame rate to the first video)
  $script:ResyncedAt = Get-Date
  $script:RenewedAt = Get-Date      # the players' failure this causes is expected: no extra new connection for it
  $script:PendingHold = New-Hold 'reload' 45
}

# A new relay with the next screen already feeding it (Invoke-Source goes on with that screen instead of starting it again).
function Start-ResyncRelay([string]$next) {
  Start-Relay
  try { $s = Start-Source $next; $s.Adopt = $true } catch {}
}

function Invoke-Queue {
  $script:Idx = 0
  while (-not $script:StopAll) {
    Receive-QueueFile
    $cur = $null
    if ($script:Idx -lt $script:Queue.Count) { $cur = $script:Queue[$script:Idx] }
    if ($script:Paused -and $cur) {
      # Keep the viewers connected with a "Paused" screen until someone continues (or skips / stops).
      if (-not (Test-RelayAlive)) { $locked = $script:FpsLocked; Start-Relay; $script:FpsLocked = $locked; $script:RelayFresh = $false; $script:PendingHold = New-Hold 'reload' }
      $r = Invoke-Source -Kind 'paused' -Media $cur
      if ($r.Outcome -eq 'quit' -or $r.Outcome -eq 'timeout') { $script:StopAll = $true; break }
      if ($r.Outcome -eq 'relay') { if (-not (Wait-RelayRetry)) { break }; continue }
      if ($r.Outcome -eq 'failed') { if (-not $script:SlateNoText) { $script:SlateNoText = $true; continue }; Say (T 'The paused screen couldn''t start (ffmpeg error {0}).' $r.ExitCode) 'Red'; break }
      if ($r.Outcome -eq 'stop') { Save-ItemState $cur $script:PausedAt; Clear-QueueForStop; continue }
      if ($r.Outcome -eq 'resync') { Restart-RelayForResync 'paused'; continue }
      if ($r.Outcome -eq 'restart' -or $r.Outcome -eq 'done') { continue }
      $script:Paused = $false
      if ($r.Outcome -eq 'skip' -or $r.Outcome -eq 'playnow') {
        Say (T '  Skipped {0}.' $cur.Name) 'Gray'
        Remove-ItemFiles $cur
        Clear-State
        $script:Idx++
        $h = New-CmdHold $r.Cmd; if ($h) { $script:PendingHold = $h }
        continue
      }
      # Continue.
      $cur.ResumeAt = $script:PausedAt
      if ($r.Cmd -and $r.Cmd.From -eq 'link') { $script:PendingHold = New-CmdHold $r.Cmd }
      elseif ($r.Cmd -and $r.Cmd.From -eq 'button') {
        $pf = 0.0
        if ($r.Cmd.PSObject.Properties['PausedFor']) { $pf = [double]$r.Cmd.PausedFor }
        $recent = ((Get-Date) - $script:ResyncedAt).TotalSeconds -lt 30
        if ($script:ResyncAfterPlayerPause -gt 0 -and $pf -ge $script:ResyncAfterPlayerPause -and "$($r.Cmd.Player)" -like 'protv:*' -and (Test-VrcWatching) -and -not $recent) {
          # The TV's own pause stops only its player (its buffer), so on play it goes on from that buffer, behind live
          # (and behind the players that didn't pause). Everyone reconnects to the live picture instead, and the video
          # waits for them: it goes on for everybody at the same moment. (The new connection opens before the old one
          # closes, so this works with the plain link too: ProTV's one retry finds the stream back.)
          Restart-RelayForResync
        } else { $script:PendingHold = New-Hold 'button' 20 $r.Cmd.At }
      }
      Say (T '  > Continuing from {0}.' (Format-Time $cur.ResumeAt)) 'Cyan'
      continue
    }
    $script:Paused = $false
    $curDone = ($cur -and ($cur.State -eq 'ready' -or $cur.State -eq 'failed'))
    if ($cur -and $cur.Kind -eq 'site' -and $cur.State -eq 'downloading' -and $cur.DlKind -eq 'ffmpeg' -and (Test-RelayAlive) -and
      $cur.Stream -and $cur.Stream.Program -lt 0 -and -not $cur.Stream.LiveOnly -and -not $cur.NoDirect -and
      -not $cur.Dl.Proc.HasExited -and (Get-DownloadFraction $cur) -lt 0.9) {
      # Its turn came before the download finished: play it straight from the site instead of making viewers wait.
      Stop-Proc $cur.Dl.Proc
      $cur.IsDirectUrl = $true
      $cur.Path = $cur.Stream.Url
      $cur.State = 'probe'
      Say (T '  {0} isn''t downloaded yet - playing it straight from the site.' $cur.Name) 'Gray'
    }
    # A web video that still has to be looked up gets that done behind the waiting screen (Invoke-Source
    # -UntilNextReady below), so viewers don't stare at a frozen picture meanwhile.
    $lookUpLater = ($cur -and $cur.Kind -eq 'site' -and ($cur.State -eq 'new' -or $cur.State -eq 'probe') -and (Test-RelayAlive))
    if ($cur -and -not $curDone -and -not $lookUpLater) {
      # Questions about it (audio / subtitle track) only while choosing what to stream; the waiting screen keeps viewers company.
      $ask = $script:ChoosingMode -and $script:Interactive
      if ($ask -and (Test-RelayAlive)) { Start-Standby }
      $script:PromptOk = $ask
      $script:PrepAsk = -not $script:ChoosingMode   # (startup questions never time out)
      try { Step-Prep $cur } finally { $script:PromptOk = $false; $script:PrepAsk = $false }
      $curDone = ($cur.State -eq 'ready' -or $cur.State -eq 'failed')
    }
    if (-not $curDone) {
      if (-not (Test-RelayAlive)) {
        if (-not $cur) { break }
        Wait-Prep $cur
        continue
      }
      if (-not $cur -and -not $script:IdleAnnounced) {
        $script:IdleAnnounced = $true
        Say ''
        Say (T 'Queue finished. The stream stays live with a "Next video starting soon" screen,') 'Cyan'
        Say (T 'so viewers stay connected. To keep going, type a title or paste a link here and press') 'Gray'
        Say (T 'Enter (or drop videos on the .bat file). Q Q = end. It ends by itself after {0} idle minutes.' ($script:IdleMinutes.ToString($script:Inv))) 'Gray'
        Say (T 'M + Enter = the settings menu (where to stream, picture size, speed test, new link, language).') 'Gray'
      }
      $r = Invoke-Source -Kind 'waiting' -UntilNextReady
      if ($r.Outcome -eq 'quit' -or $r.Outcome -eq 'timeout') { break }
      if ($r.Outcome -eq 'stop') { Say (T '  Nothing is playing. Q Q ends the stream.') 'Gray'; continue }
      if ($r.Outcome -eq 'skip') {
        # (The torrent episode that was still downloading for its turn: given up.)
        $sk = Get-WaitingSkipItem
        if ($sk) { $sk.State = 'failed'; $sk.Error = T 'skipped before its download finished' }
        $h = New-CmdHold $r.Cmd; if ($h) { $script:PendingHold = $h }
        continue
      }
      if ($r.Outcome -eq 'resync') { Restart-RelayForResync 'waiting'; continue }
      # The Settings menus ask in this window: the waiting screen goes on meanwhile (a server drops viewers of a
      # stream that stops sending). A menu that changes the stream stops / restarts it itself.
      $lost = ($r.Outcome -eq 'relay')
      if (@(Get-MenuItems -WithMenu | ForEach-Object { $_.Id }) -contains $r.Outcome) {
        $alive = Test-RelayAlive
        if ($alive) { Start-Standby }
        # (A pick in the control window's Settings menu comes with its choice: that question isn't asked again.)
        $pick = $null
        if ($r.Cmd -and $r.Cmd.From -eq 'panel') { $pick = $r.Cmd.Arg }
        Invoke-MenuAction $r.Outcome $pick
        # (The connection broke while the menu waited: reconnect as below, instead of ending the stream.)
        $lost = $alive -and -not (Test-RelayAlive)
        if (-not $lost) { continue }
      }
      if ($lost) {
        # Back on the air with the waiting screen; the next video waits until the players are back (or, if no video
        # played on this connection yet, until they show the stream at all).
        $fresh = $script:RelayFresh
        $locked = $script:FpsLocked
        if (-not (Wait-RelayRetry $false)) { break }
        Start-Relay
        $script:RelayFresh = $fresh
        $script:FpsLocked = $locked
        if (-not $fresh -and -not ($script:PendingHold -and $script:PendingHold.Reason -eq 'start')) { $script:PendingHold = New-Hold 'reload' }
        continue
      }
      if ($r.Outcome -eq 'failed') {
        if ($script:SlateNoText) { Say (T 'The waiting screen couldn''t start (ffmpeg error {0}), so the stream is ending.' $r.ExitCode) 'Red'; break }
        $script:SlateNoText = $true
      }
      continue
    }
    $script:IdleAnnounced = $false
    if ($cur.State -eq 'failed' -and $cur.Kind -eq 'site' -and -not $cur.Reset) {
      $cur.Reset = $true
      $cur.Cands = $null; $cur.CandIdx = 0; $cur.Retried = $false; $cur.NoDirect = $false; $cur.Errors = @()
      $cur.State = 'new'; $cur.IsDirectUrl = $false; $cur.Stream = $null; $cur.Using = $null
      continue
    }
    if ($cur.State -eq 'failed') {
      Say (T 'Skipping {0}: {1}' $cur.Name $cur.Error) 'Red'
      Remove-ItemFiles $cur
      $script:Idx++
      continue
    }
    if ($cur.ResumeAt -gt 0 -and $cur.Info.Duration -gt 0 -and $cur.ResumeAt -gt $cur.Info.Duration - 3) {
      # We were already at the very end of this one.
      Remove-ItemFiles $cur
      $script:Idx++
      continue
    }
    # The first video on a new connection sets the frame rate of everything on it (without "StreamFps" in config.json).
    # The H.264 header holds it, so a change needs a new connection. Once the stream sent anything, or VRChat runs here,
    # someone may be watching: the new connection opens before the old one closes (a resync). Else simply a new one.
    # Either way the video then waits for the players as on a new connection.
    if (-not (Test-RelayAlive)) { [void](Select-SessionFps $cur); Start-Relay }
    elseif ($script:FpsAuto -and -not $script:FpsLocked) {
      # (The log isn't read while questions wait or a video gets ready: what does the world's player here do now?)
      if ($script:VrcLog) { $script:RemoteNextPoll = [datetime]::MinValue; Receive-WorldCommands 'waiting' }
      $start = $script:HoldOn -and ($script:RelayFresh -or ($script:PendingHold -and $script:PendingHold.Reason -eq 'start'))
      if (Select-SessionFps $cur) {
        $sent = $false
        try { $sent = ((Read-RelaySize) -gt 0) } catch {}
        if ((Test-VrcWatching) -or $sent) {
          Restart-RelayForResync
          if ($start) { $script:PendingHold = New-Hold 'start' }
        }
        else { Stop-Relay; Start-Relay }
      }
    }
    Set-FpsPlan $cur
    # Wait for the players first when they can't be watching yet (a new connection) or are reconnecting.
    $hold = $script:PendingHold
    if (-not $hold -and $script:RelayFresh -and $script:HoldOn) { $hold = New-Hold 'start' }
    $script:RelayFresh = $false
    $script:PendingHold = $hold   # kept until the video really starts (a screen restart or a skip doesn't end it)
    if ($hold -and -not (Test-HoldReady $hold)) {
      if (-not $cur.Announced) { Show-NowPlaying $cur; $cur.Announced = $true }
      $r = Invoke-Source -Kind 'hold' -Media $cur -Hold $hold
      if ($r.Outcome -eq 'renew') { $locked = $script:FpsLocked; Stop-Relay; Start-Relay; $script:FpsLocked = $locked; $script:RelayFresh = $false; $script:PendingHold = $hold; continue }
      if ($r.Outcome -eq 'quit' -or $r.Outcome -eq 'timeout') { $script:StopAll = $true; break }
      if ($r.Outcome -eq 'stop') { Save-ItemState $cur $cur.ResumeAt; Clear-QueueForStop; continue }
      if ($r.Outcome -eq 'relay') {
        if (-not (Wait-RelayRetry $false)) { break }
        if ($hold.Reason -ne 'start') { $script:PendingHold = New-Hold 'reload' }
        continue
      }
      if ($r.Outcome -eq 'resync') { Restart-RelayForResync; continue }
      if ($r.Outcome -eq 'restart' -or $r.Outcome -eq 'done') { continue }
      if ($r.Outcome -eq 'failed') {
        if (-not $script:SlateNoText) { $script:SlateNoText = $true; continue }
        $script:PendingHold = $null
      }
      if ($r.Outcome -eq 'skip' -or $r.Outcome -eq 'playnow') {
        Say (T '  Skipped {0}.' $cur.Name) 'Gray'
        Remove-ItemFiles $cur
        Clear-State
        $script:Idx++
        continue
      }
      if ($r.Outcome -eq 'pause') {
        $script:PausedAt = $cur.ResumeAt
        $script:Paused = $true
        Say (T '  || Paused at {0}. Space = continue.' (Format-Time $cur.ResumeAt)) 'Cyan'
        continue
      }
      # start. Started by hand (Space) while the player here still can't show the stream: its retries failing
      # again don't make the video wait again, until it has shown the stream once.
      if ($r.Cmd -and (Test-VrcWatching) -and $script:Vrc.State -ne 'playing') { $script:LostMuted = $true }
    }
    $script:PendingHold = $null
    $script:ChoosingMode = $false
    if (-not $cur.Announced) { Show-NowPlaying $cur }
    $cur.Announced = $true
    Show-Controls
    # A video starting (not one going on after a pause, seek or reconnect): the bitrate may go back up (Step-UpQuality).
    if (-not [object]::ReferenceEquals($script:LastStartedItem, $cur)) {
      $script:LastStartedItem = $cur
      if (Test-CanStepUp) { Step-UpQuality }
    }
    $script:FpsLocked = $true   # (a video started on this connection: later ones go at its frame rate)
    $r = Invoke-Source -Kind 'content' -Media $cur -Start $cur.ResumeAt
    if ($r.Elapsed -gt 60) { $script:RelayFails = 0 }
    if (($r.Position - $cur.ResumeAt) -gt 2) { $script:EncoderProven = $true }
    # A web stream that ends well before the episode does was cut off, not finished (also a link played as it is).
    if ($r.Outcome -eq 'done' -and ($cur.Kind -eq 'site' -or ($cur.Kind -eq 'url' -and -not $cur.IsLive)) -and $cur.IsDirectUrl -and
      $cur.Info.Duration -gt 60 -and $r.Position -lt $cur.Info.Duration - 20) { $r.Outcome = 'failed' }
    # (A link whose server failed it at once is the server's doing, not the encoder's.)
    $inputErr = ($cur.Kind -eq 'url' -and $cur.IsDirectUrl -and "$($r.Error)" -match '(?i)HTTP error|Server returned|Input/output error|I/O error|Connection (refused|reset|timed out)|Failed to resolve|Error opening input|Invalid data found')
    $fromLink = ($r.Cmd -and $r.Cmd.From -eq 'link')
    if ($r.Outcome -eq 'done' -or $r.Outcome -eq 'skip' -or $r.Outcome -eq 'playnow') {
      Remove-ItemFiles $cur
      Clear-State
      $script:Idx++
      $script:QueueFinished = ($script:Idx -ge $script:Queue.Count)
      if ($fromLink) { $script:PendingHold = New-CmdHold $r.Cmd }
      continue
    }
    if ($r.Outcome -eq 'quit') { Save-ItemState $cur $r.Position; $script:StopAll = $true; break }
    if ($r.Outcome -eq 'stop') { Save-ItemState $cur $r.Position; Clear-QueueForStop; continue }
    if ($r.Outcome -eq 'slow') {
      $cur.ResumeAt = [Math]::Max(0.0, $r.Position - 1)
      Step-DownQuality
      if ($script:NeedResync) {
        $script:NeedResync = $false
        $cur.ResumeAt = Get-ClampedPos $cur ([Math]::Max($cur.ResumeAt - $script:ViewerDelay, 0.0))
        Restart-RelayForResync
      }
      continue
    }
    if ($r.Outcome -eq 'pause') {
      $cur.ResumeAt = Get-ClampedPos $cur $r.Target
      $script:PausedAt = $cur.ResumeAt
      $script:Paused = $true
      Save-ItemState $cur $cur.ResumeAt
      Say (T '  || Paused at {0}. Viewers see a "Paused" screen until you continue (Space).' (Format-Time $cur.ResumeAt)) 'Cyan'
      continue
    }
    if ($r.Outcome -eq 'seek') {
      $cur.ResumeAt = Get-ClampedPos $cur $r.Target
      $d = $cur.ResumeAt - $r.Position
      if ($d -lt 0) { Say (T '  << Back to {0}' (Format-Time $cur.ResumeAt)) 'Gray' } else { Say (T '  >> Forward to {0}' (Format-Time $cur.ResumeAt)) 'Gray' }
      if ($fromLink) { $script:PendingHold = New-CmdHold $r.Cmd }
      continue
    }
    if ($r.Outcome -eq 'restart') { $cur.ResumeAt = Get-ClampedPos $cur $r.Target; continue }
    if ($r.Outcome -eq 'sync') {
      $cur.ResumeAt = Get-ClampedPos $cur $r.Target
      Say (T '  Everyone''s player is reconnecting - the video waits for them and goes on from {0}.' (Format-Time $cur.ResumeAt)) 'Cyan'
      $script:PendingHold = New-Hold 'reload' 60 $r.Cmd.At
      continue
    }
    if ($r.Outcome -eq 'resync') {
      $cur.ResumeAt = Get-ClampedPos $cur $r.Target
      Restart-RelayForResync
      continue
    }
    if ($r.Outcome -eq 'lost') {
      $cur.ResumeAt = Get-ClampedPos $cur $r.Target
      Say (T '  The world''s player lost the stream - the video waits at {0} until it is back.' (Format-Time $cur.ResumeAt)) 'Yellow'
      $script:PendingHold = New-Hold 'reload' 45 $r.Cmd.At
      continue
    }
    if ($r.Outcome -eq 'relay') {
      # Viewers lost it about ViewerDelay before what was sent (plus what was still on its way), but never before this run began.
      $cur.ResumeAt = Get-ClampedPos $cur ([Math]::Max($cur.ResumeAt, $r.Position - $script:ViewerDelay - 3))
      if (-not (Wait-RelayRetry $true)) { break }
      Say (T '  The video waits at {0} until the players are back.' (Format-Time $cur.ResumeAt)) 'Gray'
      $script:PendingHold = New-Hold 'reload'
      continue
    }
    if ($cur.Kind -eq 'site' -and $cur.IsDirectUrl -and $cur.Stream -and $cur.DirectFails -lt 3) {
      $cur.DirectFails++
      $cur.IsDirectUrl = $false
      $cur.ResumeAt = [Math]::Max(0.0, $r.Position - 2)
      if ($cur.Stream.LiveOnly) {
        # Ask the site for a fresh link (the old one may have been cut off), or go on to the next source.
        Say (T 'The stream from the site stopped - getting a fresh link.') 'Yellow'
        if ($r.Error) { Say "  ($(Get-ShortText $r.Error 110))" 'DarkGray' }
        if (-not $cur.Retried) { $cur.Retried = $true; $cur.CandIdx = [Math]::Max(0, $cur.CandIdx - 1) }
        $cur.State = 'new'
      } else {
        Say (T 'The stream from {0} stopped.' $cur.Using.Label) 'Yellow'
        if ($r.Error) { Say "  ($(Get-ShortText $r.Error 110))" 'DarkGray' }
        if (Switch-ToBackup $cur) { continue }
        Say (T '  No other player has it - downloading it first instead.') 'Yellow'
        $cur.NoDirect = $true
        try { Start-StreamDownload $cur $cur.Stream } catch { $cur.State = 'failed'; $cur.Error = $_.Exception.Message }
      }
      continue
    }
    if (-not $script:EncoderProven -and -not $inputErr -and $r.Elapsed -lt 20 -and ($r.Position - $cur.ResumeAt) -lt 1 -and $script:VEnc -ne 'libx264' -and $cur.Attempts -lt 3) {
      $resync = $false
      if ($script:VEnc -eq 'h264_nvenc' -and $script:NvTier -gt 1) {
        $script:NvTier--
        # (Simpler NVENC settings write the same H.264 header; only with constant bitrate it may differ.)
        $resync = Test-ClassicEncoder
        Say (T 'The graphics card encoder had trouble - trying it with simpler settings.') 'Yellow'
      } else {
        Say (T 'The graphics card encoder failed - switching to CPU encoding.') 'Yellow'
        $script:VEnc = 'libx264'
        $resync = $true
      }
      $cur.Attempts++
      $cur.ResumeAt = [Math]::Max(0.0, $r.Position - 2)
      # Another encoder means another H.264 header: the players reconnect once, so none of them freezes on it.
      if ($resync -and (Test-RelayAlive)) { Restart-RelayForResync }
      continue
    }
    if ($cur.Kind -eq 'url' -and $cur.IsDirectUrl -and -not $cur.IsLive -and "$($cur.Path)" -match '^(?i)https?://' -and $cur.DirectFails -lt 3) {
      # A link played straight from its server that stopped (the server hiccuped): again from where it was.
      $cur.DirectFails++
      $cur.ResumeAt = Get-ClampedPos $cur ([Math]::Max($cur.ResumeAt, $r.Position - 2))
      Say (T 'The stream from the server stopped - trying again from {0}.' (Format-Time $cur.ResumeAt)) 'Yellow'
      if ($r.Error) { Say "  ($(Get-ShortText $r.Error 110))" 'DarkGray' }
      continue
    }
    $why = (T 'ffmpeg stopped with error {0}' $r.ExitCode)
    if ($r.Error) { $why += ': ' + (Get-ShortText $r.Error 120) }
    Say (T 'Couldn''t stream {0} ({1}). Skipping it.' $cur.Name $why) 'Red'
    Remove-ItemFiles $cur
    $script:Idx++
  }
}

function Save-ItemState($item, [double]$pos) {
  if ($item -and ($item.Kind -eq 'file' -or $item.Kind -eq 'site') -and $pos -gt 0) { Save-State $item.Source $pos }
}

# ------------------------------------------------------------------ startup
# The link to put in the world's player: the plain one. It used to end in ?retry=-1 (ProTV then keeps retrying a
# lost stream), but VRChat's player sends that part to the server too, and with it the picture never came (seen
# 2026-10-02: ProTV "Now Playing", then no picture for over a minute; the plain link showed it after 13 s). It isn't
# needed any more: a resync opens the new connection before the old one closes, so ProTV's own retry finds the stream.
# "LinkRetry": true in config.json brings the old link back.
function Get-ShownLink {
  $u = [string]$script:Cfg.PcUrl
  $ours = ($u -match '^(?i)rtspt?://(?:[^/]+\.)?topaz\.chat/')
  if ($script:HostP) { $u = [string]$script:HostP.PcUrl; $ours = ($script:HostP.Id -ne 'custom') -or $ours }
  if ((Get-BoolSetting 'LinkRetry' $false) -and $ours -and $u -match '^(?i)rtspt?://' -and $u -notmatch '\?') { $u += '?retry=-1' }
  return $u
}

function Get-BoolSetting([string]$name, [bool]$default) {
  $v = Get-Prop $script:Cfg $name
  if ($null -eq $v) { return $default }
  if ($v -is [bool]) { return $v }
  return ("$v" -match '^(?i)\s*(true|yes|on|1)\s*$')
}

function Get-NumSetting([string]$name, [double]$default, [double]$min, [double]$max) {
  $v = Get-Prop $script:Cfg $name
  if ($null -eq $v) { return $default }
  $n = 0.0
  if (-not [double]::TryParse("$v", [System.Globalization.NumberStyles]::Float, $script:Inv, [ref]$n)) { return $default }
  return [Math]::Max($min, [Math]::Min($max, $n))
}

function Initialize-StreamSettings {
  $f = "$(Get-Prop $script:Cfg 'StreamFps')".Trim()
  # Not set: 23.976 until the first video of a connection sets it (Select-SessionFps). Set: always that ("auto" =
  # 23.976, as before).
  $script:FpsAuto = (-not $f)
  if ($script:FpsAuto -or $f -match '^(?i)auto$') { $f = '24000/1001' }
  $num = 0.0
  if ($f -match '^(\d+)/(\d+)$' -and [double]$matches[2] -gt 0) { $num = [double]$matches[1] / [double]$matches[2] }
  elseif (-not [double]::TryParse($f, [System.Globalization.NumberStyles]::Float, $script:Inv, [ref]$num)) { $num = 0.0 }
  if ($num -lt 10 -or $num -gt 60) { $f = '24000/1001'; $num = 24000.0 / 1001.0 }
  $script:StreamFps = $f
  $script:StreamFpsNum = $num
  $script:StartDelay = Get-NumSetting 'StartDelaySeconds' 3 0 30
  $script:ResyncAfterPlayerPause = Get-NumSetting 'ResyncAfterTvPause' 3 0 3600
  $script:DriftResync = Get-NumSetting 'ResyncWhenBehindSeconds' 8 0 600
  $script:ViewerDelay = Get-NumSetting 'ViewerDelaySeconds' 5 1 15
  $script:HoldOn = Get-BoolSetting 'WaitForPlayers' $true
  $script:HoldOnDrop = $script:HoldOn
  $script:ClockOn = Get-BoolSetting 'Clock' $false
  if (-not $script:Interactive -and -not $env:VRCLM_VRCLOG_DIR) { $script:HoldOn = $false; $script:HoldOnDrop = $false }
  $script:ShownLink = Get-ShownLink
}

function Show-Links {
  $c = $script:Cfg
  Say ''
  Say ('=' * 70) 'DarkCyan'
  if ($script:HostP) {
    Show-HostLinks $script:HostP $script:ShownLink
  } else {
    Say (T '  YOUR VRCHAT LINK  (via {0})' (T $c.Server)) 'White'
    Say ''
    Say "      $($script:ShownLink)" 'Green'
    Say ''
    if ($c.QuestUrl) { Say (T '  Quest / Android viewers use:  {0}' $c.QuestUrl) 'Gray' }
    if ($c.VlcUrl) { Say (T '  To test it on your PC in VLC: {0}' $c.VlcUrl) 'Gray' }
  }
  Say (T '  Put the world''s video player in Stream / Live mode and paste the link.') 'Gray'
  Say (T '  The link stays the same every time you use this tool.') 'Gray'
  if ($script:VrcLog) {
    $sep = '?'
    if ($script:ShownLink -match '\?') { $sep = '&' }
    Say ''
    Say (T '  Control it from the world''s player: put the link in again with one of these added') 'Gray'
    Say (T '  at the end:  {0}pause  {0}play  {0}back (10 s back)  {0}next  {0}sync (everyone reconnects)' $sep) 'Gray'
    Say (T '  The TV''s own pause / play buttons work too (ProTV, iwaSync3, YamaPlayer).') 'Gray'
  }
  Show-StreamQuality
  Say ('=' * 70) 'DarkCyan'
  if ($script:IsWin -and -not $env:VRCLM_AUTO) {
    try { Set-Clipboard -Value $script:ShownLink; Say (T '  (The link is copied to your clipboard.)') 'DarkGray' } catch {}
  }
}

# Streaming from this PC: MediaMTX (with the locked-down config), the Windows firewall rule, optionally the router's
# port forwarding (UPnP, only if the user agreed) and the DuckDNS name. $false = it can't run (the caller falls back to Topaz).
$script:UpnpAdded = $false
$script:HostIpv6Only = $false
# The IPv4 address can't be reached from outside (CGNAT): the IPv6 links become the ones shown and copied.
function Use-Ipv6Links($p) {
  if (-not $p -or -not $p.Ipv6PcUrl) { return }
  $p.PcUrl = $p.Ipv6PcUrl
  if ($p.Ipv6QuestUrl) { $p.QuestUrl = $p.Ipv6QuestUrl }
  $p.QuestAltUrl = ($p.Ipv6PcUrl -replace '^(?i)rtspt://', 'rtsp://')
  $p.Ipv6PcUrl = ''; $p.Ipv6QuestUrl = ''
}

function Start-HostServer {
  $p = $script:HostP
  # My VPS: ask the server first (does it answer, know this PC's link and take its password; is anyone else on it?).
  if ($p -and $p.Id -eq 'vps' -and (Get-Command Test-VpsReady -CommandType Function -ErrorAction SilentlyContinue)) {
    try { return (Test-VpsReady $p) } catch { if ($script:CtrlCQuit -or $script:NavSignal) { throw }; return $true }
  }
  if (-not $p -or -not $p.UsesMediaMtx) { return $true }
  $s = Get-Prop $script:Cfg 'SelfHost'
  $exe = $null
  try { $exe = Get-MediaMtxExe (Test-CanAsk) } catch { if ($script:CtrlCQuit -or $script:NavSignal) { throw }; Say $_.Exception.Message 'Yellow' }
  if (-not $exe) { Say (T 'Streaming from this PC needs MediaMTX, so this time it streams through Topaz Chat (H on the start screen = change).') 'Yellow'; return $false }
  $ports = @([int]$s.RtspPort, [int]$s.RtmpPort)
  # (Not the HLS port: on this PC HLS listens on 127.0.0.1 only, for Tailscale Funnel, so nothing outside needs it.)
  Say (T 'Checking whether viewers can reach this PC...') 'Gray'
  $cg = $null
  try { $cg = Test-Cgnat } catch {}
  if ($cg) {
    $col = 'Gray'
    if ($cg.Verdict -ne 'ok') { $col = 'Yellow' }
    foreach ($l in ("$($cg.Text)" -split "`n")) { if ($l) { Say ('  ' + $l) $col } }
  }
  if ($cg -and $cg.Verdict -eq 'cgnat' -and (Test-CanAsk)) {
    $pick = Read-Choice (T 'Stream from this PC anyway?') @((T 'No - stream through Topaz Chat this time'), (T 'No - always stream through Topaz Chat (don''t ask again; H = change the host)'),
      (T 'Yes - only the IPv6 link can work'), (T 'Choose another host')) 0 $false -Esc 0
    if ($pick -eq 0) { return $false }
    if ($pick -eq 1) {
      # Remembered: the next starts skip this check (and its few seconds) and go straight to Topaz Chat.
      try { $script:Cfg.Host = 'topaz'; Save-Config $script:Cfg; Say (T '  Saved: from now on it streams through Topaz Chat. (H on the start screen switches back.)') 'DarkGray' } catch {}
      return $false
    }
    if ($pick -eq 3) { return 'menu' }
    if ($p.Ipv6PcUrl) {
      $script:HostIpv6Only = $true
      Use-Ipv6Links $p
      Say (T '  Your link uses this PC''s IPv6 address now: only viewers whose internet has IPv6 can connect.') 'Yellow'
    } else {
      Say (T '  This PC has no IPv6 internet address either, so only devices on your home network can connect.') 'Yellow'
    }
  }
  try { $r = Update-DuckDns $s; if ($r) { Say ('  ' + $r) 'Gray' } } catch {}
  if ([bool](Get-Prop $s 'Firewall') -or $null -eq (Get-Prop $s 'Firewall')) {
    try { [void](Enable-SelfHostFirewall $exe $ports) } catch { if ($script:CtrlCQuit) { throw }; Say $_.Exception.Message 'Yellow' }
  }
  $up = Get-Prop $s 'Upnp'
  if (-not ($cg -and $cg.Verdict -eq 'cgnat')) {
    if ($null -eq $up -and (Test-CanAsk)) {
      $up = Read-YesNoUi (T 'Open the port(s) {0} on your router automatically (UPnP)? They are closed again when you stop. [y/N]' (($ports | ForEach-Object { "$_" }) -join ', ')) $false -Esc $false
      $s.Upnp = $up
      try { Save-Config $script:Cfg } catch {}
    }
    if ($up -eq $true) {
      try { $script:UpnpAdded = [bool](Add-UpnpPortMappings $ports) } catch { Say $_.Exception.Message 'Yellow' }
    } elseif ($cg -and $cg.Verdict -ne 'ok') { Show-PortForwardHelp $ports }
  }
  try {
    $yml = New-MediaMtxConfig 'pc' $s ([string]$env:VRCLM_MTX_BIND)   # (tests bind it to 127.0.0.1)
    [void](Start-MediaMtx $exe $yml)
    Say (T '  MediaMTX is running (only your link''s path can be watched; only this PC can send).') 'DarkGray'
  } catch {
    Say $_.Exception.Message 'Red'
    Stop-HostServer
    return $false
  }
  return $true
}

function Stop-HostServer {
  if (Get-Command Stop-MediaMtx -CommandType Function -ErrorAction SilentlyContinue) { try { Stop-MediaMtx } catch {} }
  $mapped = 0
  try { $mapped = @($script:UpnpMapped).Count } catch {}
  if ($script:UpnpAdded -or $mapped -gt 0) { try { [void](Remove-UpnpPortMappings) } catch {}; $script:UpnpAdded = $false }
  if (Get-Command Disable-SelfHostFirewall -CommandType Function -ErrorAction SilentlyContinue) { try { [void](Disable-SelfHostFirewall) } catch {} }
}

# Makes the host in config.json the active one: its links, bitrate and (for this PC) its server.
$script:HostFallback = $false
function Set-ActiveHost {
  Lock-NavStep   # (starting a host can't be undone: its questions are one-off ones, Esc = their safe answer)
  if (-not (Test-HostModule)) { Update-StreamQuality; $script:ShownLink = Get-ShownLink; return }
  $script:HostP = Get-HostProfile
  $script:HostFallback = $false
  $script:HostIpv6Only = $false
  $ok = Start-HostServer
  # (Compared as a string: in PowerShell $true -eq 'menu' is true.)
  if ($ok -is [string] -and $ok -eq 'menu') {
    Stop-HostServer
    if (Invoke-HostChoice) { Set-ActiveHost; return }
    $ok = Start-HostServer
  }
  if (-not ($ok -is [bool] -and $ok)) {
    Stop-HostServer
    $script:HostFallback = ($script:HostP.Id -ne 'topaz')
    $script:HostP = Get-HostProfile 'topaz'
  }
  Update-StreamQuality
  $script:ShownLink = Get-ShownLink
}

# A new link (another host or a new key): what the world's player did with the old one doesn't count any more.
function Reset-VrcPlayer {
  $v = $script:Vrc
  if ($v) { $v.State = 'none'; $v.Opening = '' }
  $script:WorldUrl = ''
  $script:Players = @{}
}

# The host menu as a flow: Back inside its questions; Esc (or 0) at "Where should the stream go?" leaves it with
# nothing saved and nothing restarted (the config goes back to how it was). $true = the host or its links changed.
# $Pick: the host already chosen in the control window (its follow-up questions are still asked here).
function Invoke-HostChoice([string]$Pick = '') {
  $r = Invoke-NavFlow -Name 'host' -Origin 'menu' -Cfg -Body { if ($Pick) { Select-Host -Pick $Pick } else { Select-Host } }
  if ($r.Nav) { return $false }
  return [bool](@($r.Value) | Select-Object -Last 1)
}

# The host menu (H): another host means another link; viewers get the new one.
function Invoke-HostMenu([string]$Pick = '') {
  if (-not (Test-HostModule) -or -not $script:HostP) { return }
  $was = $script:PromptOk
  $script:PromptOk = $true
  try {
    $changed = Invoke-HostChoice $Pick
    if ($changed) {
      # (A restart can't be undone: no Back crosses it, so the server's questions below are one-off ones with their Esc
      # answers, also when the same host was picked again after a fallback to Topaz and nothing was saved.)
      Lock-NavStep
      Stop-Relay
      Stop-HostServer
      Set-ActiveHost
      Reset-VrcPlayer
      Show-Links
      Start-Standby
    }
  } finally { $script:PromptOk = $was }
}

# A connection code pasted on the start screen: "My VPS" with it, like H -> My VPS -> paste (another host = another link).
function Use-VpsCode([string]$line) {
  $was = $script:PromptOk
  $script:PromptOk = $true
  try {
    [void](Initialize-HostConfig)
    $before = $script:HostP
    if (-not (Invoke-VpsCodeImport $script:Cfg.Vps $line)) { return }
    $chg = $false
    if ("$(Get-Prop $script:Cfg 'Host')" -eq 'custom') {
      # (The typed-in custom links are kept, as when the host menu leaves "custom".)
      $keep = [pscustomobject][ordered]@{ IngestUrl = "$(Get-Prop $script:Cfg 'IngestUrl')"; PcUrl = "$(Get-Prop $script:Cfg 'PcUrl')"; QuestUrl = "$(Get-Prop $script:Cfg 'QuestUrl')"; VlcUrl = "$(Get-Prop $script:Cfg 'VlcUrl')" }
      Set-HostField $script:Cfg 'CustomLinks' $keep ([ref]$chg)
    }
    $script:Cfg.Host = 'vps'
    Sync-HostServerName $script:Cfg 'vps' ([ref]$chg)
    [void](Initialize-HostConfig)
    try { Save-Config $script:Cfg } catch { Say (T '  Couldn''t save config.json: {0}' $_.Exception.Message) 'Red' }
    $after = Get-HostProfile 'vps'
    if ($before -and $before.Id -eq 'vps' -and $before.IngestUrl -eq $after.IngestUrl -and $before.PcUrl -eq $after.PcUrl) { return }   # (nothing changed)
    Stop-Relay
    Stop-HostServer
    Set-ActiveHost
    Reset-VrcPlayer
    Show-Links
    Start-Standby
  } finally { $script:PromptOk = $was }
}

# The upload speed test (T): nothing else may use the upload meanwhile, so the stream goes off for it (only once the
# answer is yes: until then the waiting screen stays on).
function Invoke-SpeedTestMenu {
  if (-not (Test-HostModule) -or -not $script:HostP) { return }
  $was = $script:PromptOk
  $script:PromptOk = $true
  try {
    $wasOn = Test-RelayAlive
    $fresh = $script:RelayFresh
    # Someone may be watching whenever the stream is on (the link may be in a player already: the log here isn't
    # read during questions), so the question warns and just Enter keeps the stream on.
    $watched = $wasOn
    $testRan = @{ Yes = $false }
    $r = $null
    try { $r = Invoke-SpeedTest $script:HostP -BeforeRun { Lock-NavStep; $testRan.Yes = $true; Stop-Relay } -ViewersWatch:$watched } catch { if ($script:CtrlCQuit -or $script:NavSignal) { throw }; Say (T '  The speed test didn''t work: {0}' $_.Exception.Message) 'Yellow' }
    # (Also a relay that ended by itself while the question waited: Start-Standby below starts a new one.)
    $stopped = $wasOn -and -not (Test-RelayAlive)
    if ($testRan.Yes) {
      # (Only after a test: on "no" the stream's settings stay as they are on this connection.)
      $script:HostP = Get-HostProfile $script:HostP.Id
      if ($script:HostIpv6Only) { Use-Ipv6Links $script:HostP }
      Update-StreamQuality
      Show-StreamQuality
    }
    if ($wasOn) { Start-Standby }
    if ($stopped) {
      # A new connection: the next video waits until the players are back (as after a lost connection).
      $script:RelayFresh = $fresh
      if (-not $fresh -and -not ($script:PendingHold -and $script:PendingHold.Reason -eq 'start')) { $script:PendingHold = New-Hold 'reload' }
    }
  } finally { $script:PromptOk = $was }
}

# The resolution menu (V). Another picture size means a new stream, so it reconnects (players follow, as after a resync).
function Invoke-ResolutionMenu($Pick = $null) {
  $was = $script:PromptOk
  $script:PromptOk = $true
  try {
    if ($null -ne $Pick) { $chg = Select-Resolution $Pick } else { $chg = Select-Resolution }
    if (-not $chg) { return }
    $oldW = $script:OutW; $oldH = $script:OutH; $oldCap = $script:RateCapKbps
    Update-StreamQuality
    Show-StreamQuality
    # (The bitrate ceiling is in the H.264 header too.)
    if (($script:OutW -ne $oldW -or $script:OutH -ne $oldH -or $script:RateCapKbps -ne $oldCap) -and (Test-RelayAlive)) {
      Restart-RelayForResync 'waiting'
      Start-Standby
    }
  } finally { $script:PromptOk = $was }
}

# New link (N): a new secret token / Topaz key; the old link stops working.
function Invoke-NewLinkMenu {
  if (-not (Test-HostModule) -or -not $script:HostP) { return }
  $was = $script:PromptOk
  $script:PromptOk = $true
  try {
    if (Reset-StreamLink) {
      Stop-Relay
      if ($script:HostFallback) {
        # Topaz streams because the configured host couldn't: the new key is Topaz's (no second try of the other host).
        $script:HostP = Get-HostProfile 'topaz'
        $script:ShownLink = Get-ShownLink
      } else {
        Stop-HostServer
        Set-ActiveHost
      }
      Reset-VrcPlayer
      Show-Links
      Start-Standby
    }
  } finally { $script:PromptOk = $was }
}

function Show-Queue {
  Say ''
  if ($script:Queue.Count -eq 1) { Say (T 'Queued: {0}' ($script:Queue[0].Name)) 'White'; return }
  Say (T 'Queued {0} videos:' $script:Queue.Count) 'White'
  $i = 1
  foreach ($it in $script:Queue) {
    if ($i -gt 12) { Say (T '   ... and {0} more' ($script:Queue.Count - 12)) 'Gray'; break }
    Say ("   {0}. {1}" -f $i, $it.Name) 'Gray'
    $i++
  }
}

# Offers to continue where the last stream stopped, when that video is queued (from queue position $from on).
function Invoke-ResumeOffer([int]$from = 0) {
  $st = Get-State
  if (-not $st -or -not (Get-Prop $st 'Path')) { return }
  $pos = 0.0
  try { $pos = [double]$st.Position } catch {}
  if ($pos -lt 30) { return }
  for ($i = $from; $i -lt $script:Queue.Count; $i++) {
    $it = $script:Queue[$i]
    if (($it.Kind -eq 'file' -or $it.Kind -eq 'site') -and [string]::Equals($it.Source, [string]$st.Path, [System.StringComparison]::OrdinalIgnoreCase)) {
      $yes = $false
      if ($env:VRCLM_RESUME) { $yes = -not (Test-AnswerNo $env:VRCLM_RESUME) }
      elseif ($script:Interactive) {
        Say ''
        $yes = Read-YesNoUi (T 'Last time you stopped ''{0}'' at {1}. Continue from there? [Y/n]' $it.Name (Format-Time $pos)) $true -Esc $false
      }
      if ($yes) {
        if ($i -gt $from) { $script:Queue.RemoveRange($from, $i - $from) }
        $it.ResumeAt = [Math]::Max(0.0, $pos - 5)
      }
      return
    }
  }
}

function Stop-Everything {
  Set-CtrlCAsKey $false
  Clear-StatusLine
  if ($script:Src) { Stop-Proc $script:Src.Proc }
  if ($script:Current) { Stop-Proc $script:Current }
  Stop-HostServer
  if (Get-Command Stop-ViewerPreview -CommandType Function -ErrorAction SilentlyContinue) { try { Stop-ViewerPreview } catch {} }
  if ($script:PanelShown) { try { Close-ControlPanel } catch {} }
  $script:PanelShown = $false
  # Downloads first, as whole trees (yt-dlp's own ffmpeg would go on recording once yt-dlp is gone).
  foreach ($it in $script:Queue) { if ($it.Dl -and $it.Dl.Proc) { try { if (-not $it.Dl.Proc.HasExited) { Stop-ProcessTree $it.Dl.Proc } } catch {} } }
  foreach ($bg in $script:BgProcs) { Stop-Proc $bg.Proc }
  # rqbit deletes what it downloaded, then ends (before the item folders go).
  try { Stop-TorrentEngine } catch {}
  try { Remove-DeadTorrentEngines } catch {}
  Close-Relay
  Start-Sleep -Milliseconds 300
  try { [System.IO.File]::Delete((Get-RelayProgPath)) } catch {}
  foreach ($it in $script:Queue) { Remove-ItemFiles $it }
  if ($script:PendingDirs.Count -gt 0) { Start-Sleep -Milliseconds 500; Remove-PendingDirs }
  Update-KeepAwake $true
  if ($script:SlateDir) { try { [System.IO.File]::Delete((Get-NoteFile)) } catch {} }
  if ($script:MutexOwned) { try { $script:Mutex.ReleaseMutex() } catch {} }
  if ($script:LogWriter) { try { $script:LogWriter.Dispose() } catch {}; $script:LogWriter = $null }
}

function Main {
  try { $Host.UI.RawUI.WindowTitle = 'VRChat Link Maker' } catch {}
  Initialize-Language (Get-LanguageSetting)
  Say "VRChat Link Maker $($script:Version)" 'Cyan'
  [void][System.IO.Directory]::CreateDirectory($script:TempRoot)
  $entries = @($script:Args0 | Where-Object { $_ -and "$_".Trim() })

  if (-not (Enter-SingleInstance)) {
    # Already streaming in another window: add these videos to its queue (this window asks the questions).
    try { $Host.UI.RawUI.WindowTitle = (T 'VRChat Link Maker - add to the stream') } catch {}
    # config.json's "DubPriority" and "Player" count here too (only read: the streaming window owns the file).
    if ([System.IO.File]::Exists((Get-ConfigPath))) { try { $script:Cfg = Get-Config } catch {} }
    $script:AddMode = $true
    # The questions (search, voice-over, episodes, player, now or after) run as one flow: Esc goes back, Esc at the
    # first one returns to '>' with the text kept, and nothing found asks again. Esc on an empty '>' closes the window.
    # Only what the flow ends with is handed over (Add-ToQueueFile, after it).
    $prefill = ''
    if ($entries.Count -eq 1) { $prefill = [string]$entries[0] }
    $again = ($script:Interactive -and ($script:HasConsole -or $script:KeySource))
    $abs = @()
    while ($true) {
      if ($entries.Count -eq 0) {
        $entries = @(Read-Entries $prefill)
        $prefill = $script:EntryLine
      }
      if ($entries -contains $script:QuitMark) { $script:NoPause = $true; return }
      if ($entries.Count -eq 1 -and (Test-IsTitle ([string]$entries[0]))) { $entries = @([string]$entries[0]) }
      $r = Invoke-NavFlow -Name 'add' -Origin 'addwin' -Snap $script:SiteAnswerVars -Body {
        $abs = @()
        foreach ($e in $entries) {
          $t = "$e".Trim().Trim('"')
          if (Test-TorrentLink $t) {
            # A torrent (magnet, bare hash, .torrent file or link): its file list and which episodes are asked here; the
            # streaming window gets the link with the episodes (a bare hash as a magnet link, a file with its full path).
            if ($script:Interactive) {
              try {
                $its = @(Expand-Torrent $t)
                if ($its.Count -gt 0) { $abs += (Get-TorrentHandover $its $t) }
              } catch { if ($script:CtrlCQuit -or $script:NavSignal) { throw }; Say (T '  Couldn''t use {0}: {1}' (Get-ShortText $t 70) $_.Exception.Message) 'Yellow' }
            } else { $abs += (Get-TorrentHandover @() $t) }
            continue
          }
          if ($script:Interactive -and $t -notmatch '^(?i)[a-z][a-z0-9+.-]*://' -and (Test-IsTitle $t)) {
            # A title: search, pick, answer the questions here; the streaming window gets the link with the answers.
            $script:LastSearchLink = $null
            try { [void](Invoke-ContentSearch $t -AskPlayer) } catch { if ($script:CtrlCQuit -or $script:NavSignal) { throw }; Say (T '  The search didn''t work: {0}' $_.Exception.Message) 'Yellow' }
            if ($script:LastSearchLink) { $abs += $script:LastSearchLink }
            continue
          }
          if ($t -match '^(?i)[a-z][a-z0-9+.-]*://') {
            if ($script:Interactive -and (Test-SiteLink $t)) {
              # The running window can't ask which voice-over / episodes: ask here and hand the answers over.
              try {
                $script:LastDub = $null; $script:LastEps = $null; $script:LastPlayer = $null
                $its = @(Expand-SiteLink $t)
                if ($its.Count -eq 0) { continue }
                Read-HandoverPlayer $its
                $choice = Get-SiteChoiceText $its
                if ($choice) { $t = $t + '#vrclm=' + $choice }
              } catch { if ($script:CtrlCQuit -or $script:NavSignal) { throw }; Say (T '  Couldn''t use {0}: {1}' (Get-ShortText $t 70) $_.Exception.Message) 'Yellow'; continue }
            }
            $abs += $t
          } else { try { $abs += [System.IO.Path]::GetFullPath($t) } catch {} }
        }
        if ($abs.Count -gt 0 -and $script:Interactive) {
          $when = Read-Choice (T 'Play it now, or after what is queued?') @((T 'After what is queued'), (T 'Now (instead of what plays now)')) 0 $false -Key 'when'
          if ($when -eq 1) { $abs = @('#vrclm-now') + $abs }
        }
        $abs
      }
      $abs = @($r.Value | Where-Object { $_ })
      if ($abs.Count -gt 0 -or -not $again) { break }
      $entries = @()   # (left, or nothing found: ask again, with the text kept)
    }
    if ($abs.Count -gt 0 -and (Add-ToQueueFile $abs)) {
      Say (T 'Added to the stream that is already running:') 'Green'
      foreach ($e in $abs) { if ($e -ne '#vrclm-now') { Say "  $(Get-ShortText $e 110)" 'Gray' } }
    } elseif ($abs.Count -gt 0) {
      Say (T 'Couldn''t reach the stream that is already running.') 'Red'
    }
    Start-Sleep -Seconds 3
    $script:NoPause = $true
    return
  }

  Open-Log
  Clear-OldTemp
  Disable-QuickEdit
  if ($script:Interactive -and -not $env:VRCLM_LANG -and -not [System.IO.File]::Exists((Get-ConfigPath)) -and (Test-HasTranslations)) {
    # First run: ask which language to use (just Enter keeps the one matching Windows). Get-Config saves it.
    Select-Language
  }
  $script:Cfg = Get-Config
  if ((Get-Command Invoke-UpdateCheck -CommandType Function -ErrorAction SilentlyContinue) -and (Invoke-UpdateCheck)) { return }
  if (Test-HostModule) {
    # Older config.json files get "Host" / "StreamKey" (same link as before) and the self-host settings.
    try { if (Initialize-HostConfig) { Save-Config $script:Cfg } } catch { Say (T 'Couldn''t update config.json: {0}' $_.Exception.Message) 'Yellow' }
  }
  Initialize-Tools
  $script:VideoKbps = [int]$script:Cfg.VideoKbps
  if ($script:VideoKbps -lt 200) { $script:VideoKbps = 1350 }
  if (-not (Test-HostModule) -and $script:Cfg.IngestUrl -match '(?i)topaz\.chat' -and $script:VideoKbps -eq 1700 -and [int]$script:Cfg.AudioKbps -eq 128) {
    # 1700 was the old default, but Topaz Chat only takes in about 1.6 Mbps in all, so that stuttered.
    $script:VideoKbps = 1350
    Say (T 'Using 1350 kbps video (Topaz Chat only takes about 1.6 Mbps in total; the old 1700 made it stutter).') 'DarkGray'
  }
  $script:BaseKbps = $script:VideoKbps
  Initialize-StreamSettings
  Update-StreamQuality
  Initialize-Fonts
  Initialize-Slate
  $script:VEnc = Select-VideoEncoder
  Say (T 'Encoding with: {0}' (Get-EncoderName $script:VEnc)) 'DarkGray'
  Set-ActiveHost
  Start-WorldPlayerControl
  Show-Links
  if ($script:Interactive -and (Get-BoolSetting 'ControlWindow' $true) -and (Get-Command Open-ControlPanel -CommandType Function -ErrorAction SilentlyContinue)) {
    $script:PanelShown = $false
    try { $script:PanelShown = [bool](Open-ControlPanel) } catch {}
  }
  if ($script:Interactive -or $env:VRCLM_STANDBY) {
    # On the air right away (with the waiting screen), so the link works in the world's player from now on.
    Start-Standby
    if (Test-RelayAlive) { Say (T '  The stream is on the air (waiting screen), so you can put the link in the world''s player now.') 'DarkGray' }
  }
  # The control window shows the link and the waiting screen (or 'Off') during the questions below too, with Next /
  # Stop / Resync / Settings off until the first source updates it (they'd be about nothing playing yet).
  if ($script:PanelShown) {
    Update-Panel 'waiting' $null 0 ''
    if ($script:PanelState) { $script:PanelState.Prompt = $true; try { Update-ControlPanel $script:PanelState } catch {} }
  }

  $script:PromptOk = $true
  try {
    # The start screen: what to stream, then its questions as one flow (Back / Forward). Leaving the flow, or nothing
    # to add (a typo, nothing found, "none of these"), returns to '>' with the text kept. Only Q + Enter ends here.
    $prefill = ''
    if ($entries.Count -eq 1) { $prefill = [string]$entries[0] }
    $again = ($script:Interactive -and ($script:HasConsole -or $script:KeySource))
    while ($true) {
      if ($entries.Count -eq 0) {
        $entries = @(Read-Entries $prefill)
        $prefill = $script:EntryLine
      }
      if ($entries -contains $script:QuitMark) { Say (T 'Nothing to stream.') 'Yellow'; return }
      [void](Invoke-NavFlow -Name 'start' -Origin 'start' -Snap $script:SiteAnswerVars -Body {
          [void](Add-Entries $entries $false)
          if ($script:Queue.Count -gt 0) { Show-Queue; Invoke-ResumeOffer }
        })
      # (What a second window handed over meanwhile: after the flow, so a Back never takes it away.)
      $before = $script:Queue.Count
      Receive-QueueFile
      if ($script:Queue.Count -gt $before) { Show-Queue; Invoke-ResumeOffer $before }
      if ($script:Queue.Count -gt 0) { break }
      if (-not $again) { Say (T 'Nothing to stream.') 'Yellow'; return }
      $entries = @()
    }
  } finally { $script:PromptOk = $false }
  # Next / Stop / Resync / Settings clicked in the control window during those questions were about nothing playing
  # yet: dropped, so they don't hit the first video. Add, viewer preview and clock still happen.
  if ($script:PanelShown) {
    $keep = @()
    for ($i = 0; $i -lt 200; $i++) {
      $p = $null
      try { $p = Read-PanelCommand } catch {}
      if (-not $p) { break }
      if (@('add', 'viewer', 'clock') -contains $p.Cmd) { $keep += $p }
    }
    foreach ($p in $keep) { try { Add-PanelCommand $p.Cmd $p.Arg } catch {} }
  }
  Invoke-Queue
  if ($script:QueueFinished -and $script:Idx -ge $script:Queue.Count) { Clear-State }
  Say ''
  Say (T 'Stream ended.') 'Cyan'
}

if ($env:VRCLM_NO_MAIN) { return }   # test harnesses dot-source this file for its functions only
try {
  Main
} catch {
  Say ''
  if ($script:CtrlCQuit) {
    if ($script:QuitFromWindow) { Say (T 'Ended from the control window.') 'Gray' } else { Say (T 'Stopped (Ctrl+C).') 'Gray' }
  }
  else {
    Say (T 'Error: {0}' $_.Exception.Message) 'Red'
    if ($env:VRCLM_DEBUG) { Say ($_.ScriptStackTrace) 'DarkGray' }
  }
} finally {
  Stop-Everything
}
if ($script:RestartAfterUpdate -and (Restart-AfterUpdate)) { exit 0 }
if ($script:Interactive -and -not $script:NoPause) {
  Say ''
  [void](Read-Host (T 'Press Enter to close this window'))
}
exit 0
