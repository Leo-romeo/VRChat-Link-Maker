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
$script:Version = '1.4.2'
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
  if ($script:StatusShown) {
    $w = Get-ConsoleWidth
    Write-Host ("`r" + (' ' * $w) + "`r") -NoNewline
    $script:StatusShown = $false
  }
}

function Say([string]$text, [string]$color = '') {
  Clear-StatusLine
  if ($color) { Write-Host $text -ForegroundColor $color } else { Write-Host $text }
  Write-LogLine $text
  Add-UiLogLine $text $color
}

# The control window's message pane gets every Say line: the window drains the queue, and the ring refills a reopened window.
$script:UiLog = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$script:UiLogRing = New-Object 'System.Collections.Generic.List[object]'
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
  try { $script:LogWriter.WriteLine((Get-Date).ToString('HH:mm:ss', $script:Inv) + '  ' + $text) } catch {}
}

# Is the window scrolled up (someone reading what it said earlier)? Writing there would jump it back down.
function Test-ScrolledUp {
  try { return ([Console]::CursorTop -ge [Console]::WindowTop + [Console]::WindowHeight) } catch { return $false }
}

function Show-Status([string]$text) {
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
function Select-Language {
  $langs = @(Get-Languages)
  if ($langs.Count -lt 2) { Say (T 'No translations found (the "lang" folder next to this tool is missing or empty).') 'Yellow'; return }
  $cur = 0
  for ($i = 0; $i -lt $langs.Count; $i++) { if ($langs[$i].Code -eq $script:Lang) { $cur = $i } }
  Say ''
  # Asked in every language at once (the current one first), so it can be read whatever the window speaks now.
  $asks = @(@($langs[$cur].Ask) + @($langs | ForEach-Object { $_.Ask }) | Select-Object -Unique)
  $pos = Read-Choice ($asks -join ' / ') @($langs | ForEach-Object { $_.Name }) $cur $false
  $code = $langs[$pos].Code
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
      $ans = 'y'
      if ($script:Interactive) { $ans = Read-Host (T 'Install it now? [Y/n]') }
      if (-not (Test-AnswerNo $ans)) {
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
    $ans = Read-Host (T 'Install it now? [Y/n]')
    if (-not (Test-AnswerNo $ans)) {
      [void](Invoke-Winget 'yt-dlp.yt-dlp')
      $script:YtDlp = Find-Exe 'yt-dlp'
    }
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
    foreach ($d in [System.IO.Directory]::GetDirectories($script:TempRoot, 'job-*')) {
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
  $info = ConvertFrom-ProbeOutput $r
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
function ConvertFrom-ProbeOutput($r) {
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
  $audio = New-Object System.Collections.ArrayList
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
    if ($type -eq 'video') {
      if ("$($s['disposition.attached_pic'])" -eq '1') { continue }
      if ($info.Video) { continue }
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
      if ($info.BitRate -le 0) { $info.BitRate = ConvertTo-IntSafe $s['tags.variant_bitrate'] }
    } elseif ($type -eq 'audio') {
      [void]$audio.Add([pscustomobject]@{ Index = $idx; Codec = $codec; Lang = $lang; Title = $title; Default = $isDef; Forced = $isForced; Kind = 'audio'; Path = $null; Channels = (ConvertTo-IntSafe $s['channels']) })
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

function Test-Signs($t) { return ($t.Forced -or ("$($t.Title)" -match '(?i)sign|song|forced|karaoke')) }
function Test-English([string]$lang) { return ($lang -match '^(?i)(en|eng)$') }

function Get-DefaultAudioPos($audio) {
  for ($i = 0; $i -lt $audio.Count; $i++) { if ($audio[$i].Default) { return $i } }
  if ($audio.Count -gt 0) { return 0 }
  return -1
}

function Get-DefaultSubPos($subs, $audioTrack) {
  if ($subs.Count -eq 0) { return -1 }
  $alang = ''
  if ($audioTrack) { $alang = "$($audioTrack.Lang)" }
  if (Test-English $alang) {
    # English audio: only signs/songs subtitles, if there are any
    for ($i = 0; $i -lt $subs.Count; $i++) { if (Test-Signs $subs[$i]) { return $i } }
    return -1
  }
  if ($alang -and $alang -notmatch '^(?i)(und|unk|zxx|mis)$') {
    for ($i = 0; $i -lt $subs.Count; $i++) { if ((Test-English $subs[$i].Lang) -and -not (Test-Signs $subs[$i])) { return $i } }
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

function Read-Choice([string]$title, [string[]]$options, [int]$default, [bool]$allowNone) {
  Say $title 'Cyan'
  if ($allowNone) { Say (T '   0) None') }
  for ($i = 0; $i -lt $options.Count; $i++) { Say ('   {0}) {1}' -f ($i + 1), $options[$i]) }
  $defLabel = '0'
  if ($default -ge 0) { $defLabel = "$($default + 1)" }
  while ($true) {
    $ans = Read-Host (T 'Type a number and press Enter (just Enter = {0})' $defLabel)
    if (-not $ans -or -not $ans.Trim()) { return $default }
    $n = 0
    if ([int]::TryParse($ans.Trim(), [ref]$n)) {
      if ($allowNone -and $n -eq 0) { return -1 }
      if ($n -ge 1 -and $n -le $options.Count) { return ($n - 1) }
    }
    Say (T '   Please type one of the numbers above.') 'Yellow'
  }
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
  $canAsk = (Test-CanAsk) -and ($null -eq $script:TrackPref)
  if ($canAsk -and ($audio.Count -gt 1 -or $subs.Count -gt 0)) {
    Say ''
    Say (T 'Setting up: {0}' $item.Name) 'White'
    if ($audio.Count -gt 1) {
      $labels = @($audio | ForEach-Object { Get-TrackLabel $_ })
      $aPos = Read-Choice (T 'Which audio track?') $labels $aPos $false
    }
    $aTrack = $null
    if ($aPos -ge 0) { $aTrack = $audio[$aPos] }
    $sPos = Get-DefaultSubPos $subs $aTrack
    if ($sPos -lt 0) { $sPos = $sitePos }
    if ($subs.Count -gt 0) {
      $labels = @($subs | ForEach-Object { Get-TrackLabel $_ })
      $sPos = Read-Choice (T 'Which subtitles? (they get drawn into the picture)') $labels $sPos $true
    }
    $p = [pscustomobject]@{ ALang = ''; ATitle = ''; APos = $aPos; SNone = ($sPos -lt 0); SLang = ''; STitle = ''; SSigns = $false; SPos = $sPos; SExternal = $false }
    if ($aPos -ge 0) { $p.ALang = $audio[$aPos].Lang; $p.ATitle = $audio[$aPos].Title }
    if ($sPos -ge 0) { $p.SLang = $subs[$sPos].Lang; $p.STitle = $subs[$sPos].Title; $p.SSigns = (Test-Signs $subs[$sPos]); $p.SExternal = ($subs[$sPos].Kind -eq 'external') }
    $script:TrackPref = $p
  } elseif ($script:TrackPref) {
    $p = $script:TrackPref
    if ($audio.Count -gt 0) {
      $m = Find-TrackMatch $audio $p.ALang $p.ATitle $false $p.APos
      if ($m -ge 0) { $aPos = $m }
    }
    $aTrack = $null
    if ($aPos -ge 0) { $aTrack = $audio[$aPos] }
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
  if ($sPos -lt 0 -and $sitePos -ge 0 -and -not ($script:TrackPref -and $script:TrackPref.SNone)) { $sPos = $sitePos }
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
function New-QueueItem([string]$kind, [string]$src) {
  $name = $src
  $path = $null
  if ($kind -eq 'file') { $name = [System.IO.Path]::GetFileName($src); $path = $src } else { $name = Get-ShortText $src 70 }
  return [pscustomobject]@{
    Kind = $kind; Source = $src; Path = $path; Name = $name; State = 'new'; Error = $null
    JobDir = $null; Info = $null; AudioTrack = $null; SubTrack = $null; SubFile = $null; SubIsSrt = $false; SubWarn = $null
    ExtraSubs = @(); Prep = @(); Dl = $null; DlDir = $null; IsDirectUrl = $false; IsLive = $false
    FpsFilter = $null; OutFps = 24.0; FpsNote = $null; ResumeAt = 0.0; Attempts = 0; Announced = $false
    Site = $null; Cands = $null; CandIdx = 0; Using = $null; Stream = $null; DlKind = $null; Errors = @(); Retried = $false; NoDirect = $false; DirectFails = 0; Reset = $false
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
    if ($e -match '^(?i)(https?|rtmps?|rtsp|rtspt|srt|udp)://') { [void]$urls.Add($e); continue }
    if (Test-IsTitle $e) {
      if (-not (Test-CanAsk)) { Say (T '  To search while a video plays, press + (it opens a second window): {0}' $e) 'Yellow'; continue }
      try { foreach ($it in @(Invoke-ContentSearch $e)) { if ($it) { [void]$found.Add($it) } } }
      catch { if ($script:CtrlCQuit) { throw }; Say (T '  The search didn''t work: {0}' $_.Exception.Message) 'Yellow' }
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
    if (Test-SiteLink $u) {
      try { foreach ($it in @(Expand-SiteLink $u)) { if ($it) { [void]$items.Add($it) } } }
      catch { if ($script:CtrlCQuit) { throw }; Say (T '  Couldn''t use {0}: {1}' (Get-ShortText $u 70) $_.Exception.Message) 'Yellow' }
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
    $entries = @($entries | Where-Object { -not (Test-VpsCodeText "$_") -and -not ("$_" -match '^[A-Za-z0-9_-]{40,}$' -and -not [System.IO.File]::Exists("$_")) })
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

function Read-Entries {
  if (-not $script:Interactive) { return @() }
  Say ''
  Say (T 'What do you want to stream?') 'Cyan'
  if (Get-Command Find-SiteContent -CommandType Function -ErrorAction SilentlyContinue) {
    Say (T '  - Type a title (anime, film, series - in Russian or English) and press Enter to search for it')
  }
  Say (T '  - or paste a link (a video, Dream Cast, AniLiberty, AnimeVost, AnimeGO, AnimeLib, WPARTY, Kodik...) and press Enter')
  Say (T '  - or drag video files (or a whole folder) into this window, then press Enter')
  Say (T '  - or just press Enter to pick files')
  if (Test-HasTranslations) { Say (T '  - or type L and press Enter to change the language') 'DarkGray' }
  $hostKeys = ((Test-HostModule) -and $script:HostP)
  if ($hostKeys) { Say (T '  - H = where to stream (Topaz / this PC / your VPS),  T = test your upload speed,  N = new link') 'DarkGray' }
  Say (T '  - V = picture size (resolution)') 'DarkGray'
  $line = Read-Host '>'
  if (-not $line -or -not $line.Trim()) { return @(Show-FilePicker) }
  # A VPS connection code (it is a password: never search for it or print it): set up "My VPS" with it.
  if ((Test-HostModule) -and (Test-VpsCodeText $line)) {
    $line += Read-PastedRest
    if ($hostKeys) { Use-VpsCode $line } else { Say (T '  That is a VPS connection code: paste it in the window that streams (H -> My VPS).') 'Yellow' }
    return @(Read-Entries)
  }
  # V = picture size (on a Russian keyboard layout the V key types U+043C)
  if ($line -match '^\s*(?:v|res|resolution|\u043c)\s*$') { Invoke-ResolutionMenu; return @(Read-Entries) }
  # H / T / N (on a Russian keyboard layout those keys type U+0440, U+0435, U+0442)
  if ($hostKeys -and $line -match '^\s*(?:h|host|\u0440)\s*$') { Invoke-HostMenu; return @(Read-Entries) }
  if ($hostKeys -and $line -match '^\s*(?:t|test|speed|\u0435)\s*$') { Invoke-SpeedTestMenu; return @(Read-Entries) }
  if ($hostKeys -and $line -match '^\s*(?:n|new|\u0442)\s*$') { Invoke-NewLinkMenu; return @(Read-Entries) }
  if (-not $hostKeys -and (Test-HostModule) -and $line -match '^\s*(?:h|t|n|\u0440|\u0435|\u0442)\s*$') {
    Say (T '  H / T / N work in the window that streams.') 'Yellow'
    return @(Read-Entries)
  }
  # L (or "lang"; on a Russian keyboard layout the L key types U+0434, "yazyk" = U+044F U+0437 U+044B U+043A)
  if ($line -match '^\s*(?:l|lang|language|\u0434|\u044f\u0437\u044b\u043a)\s*$' -and (Test-HasTranslations)) {
    Select-Language
    if ($script:Cfg) { Show-Links }
    return @(Read-Entries)
  }
  return @(Split-EntryLine $line)
}

# A line typed / pasted / dropped into the window while it streams.
# The rest of a paste that came in as several lines (a chat window may have wrapped a long code).
function Read-PastedRest {
  $rest = ''
  try {
    Start-Sleep -Milliseconds 150
    while ($script:HasConsole -and [Console]::KeyAvailable) { $rest += "$(Read-Host)"; Start-Sleep -Milliseconds 100 }
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
  if ($kind -eq 'waiting' -and (Test-HostModule) -and $script:HostP -and $line -match '^\s*(?:h|host|\u0440)\s*$') { Add-Cmd (New-Cmd 'host'); return }
  if ($kind -eq 'waiting' -and (Test-HostModule) -and $script:HostP -and $line -match '^\s*(?:n|new|\u0442)\s*$') { Add-Cmd (New-Cmd 'newlink'); return }
  if ($line -match '^\s*(?:v|res|resolution|\u043c)\s*$') {
    if ($kind -eq 'waiting') { Add-Cmd (New-Cmd 'res') } else { Say (T '  The resolution can be changed while nothing plays (when the queue is done, or after S = stop).') 'Yellow' }
    return
  }
  $entries = @(Split-EntryLine $line)
  if ($entries.Count -eq 0) { return }
  # A title while something plays: search in a second window, so this one keeps streaming undisturbed.
  if ($kind -ne 'waiting' -and $entries.Count -eq 1 -and (Test-IsTitle $entries[0])) { Open-AddWindow $entries[0]; return }
  Invoke-AddEntries $entries $kind
}

# Adds entries to the queue. While nothing plays (the waiting screen is on), this window may ask questions (which
# voice-over, which episodes, continue where you stopped?); the waiting screen keeps running meanwhile.
function Invoke-AddEntries([string[]]$entries, [string]$kind = '') {
  $ask = ($kind -eq 'waiting')
  if ($ask) { Clear-StatusLine; $script:PromptOk = $true }
  try {
    $before = $script:Queue.Count
    $n = Add-Entries $entries $true
    if ($n -eq 0) { Say (T '  Nothing added - couldn''t find: {0}' ($entries -join ' ')) 'Yellow' }
    elseif ($ask) { Invoke-ResumeOffer $before }
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

function Remove-ItemFiles($item) {
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
function Invoke-Web {
  param([Parameter(Mandatory = $true)][string]$Url, [string]$Method = 'GET', [hashtable]$Headers = @{}, [string]$Body = $null,
    [string]$ContentType = $null, [int]$TimeoutSec = 20, [switch]$NoRedirect)
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
  if ($item.DlKind -ne 'ffmpeg' -or -not $item.DlDir -or -not $item.Stream -or $item.Stream.Duration -le 0) { return 0.0 }
  $pr = Read-Progress (PathJoin $item.DlDir 'progress.txt')
  if (-not $pr) { return 0.0 }
  return [Math]::Min(1.0, $pr.Time / $item.Stream.Duration)
}

function Get-DownloadText($item) {
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
function Read-EpisodeSelection($list, [int]$defPos) {
  if ($list.Count -le 1) { return @($list) }
  $defText = T 'all {0}' $list.Count
  if ($defPos -gt 0) { $defText = "$($list[$defPos].Number)-$($list[$list.Count - 1].Number)" }
  Say (T 'Which episodes? (1 to {0}; type e.g. 5, or 3-8, or 3- for 3 to the end)' ($list[$list.Count - 1].Number)) 'Cyan'
  while ($true) {
    $ans = Read-Host (T 'Type and press Enter (just Enter = {0})' $defText)
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
    if ($pick.Count -gt 0) { return $pick.ToArray() }
    Say (T '   Please type episode numbers from the list.') 'Yellow'
  }
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
  $i = Read-Choice (T 'Which player should the video come from?') $opts 0 $false
  if ($i -le 0) { $script:PlayerPref = 'auto' } else { $script:PlayerPref = [string]$provs[$i - 1] }
  return $script:PlayerPref
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
  $i = Read-Choice (T 'Which player should the video come from?') $opts 0 $false
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
# file), when yt-dlp is installed (no question about installing it here). $true = its download started.
function Switch-UrlToDownload($item) {
  if ($item.Kind -ne 'url' -or $item.NoDirect -or $item.Source -notmatch '^(?i)https?://') { return $false }
  $yt = $script:YtDlp
  if (-not $yt) { $yt = Find-Exe 'yt-dlp'; $script:YtDlp = $yt }
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
          try { $st = Complete-HlsStream (New-Stream $hls.Url 'hls' $hls.Headers) } catch {}
          if ($st -and $st.Program -ge 0 -and (Switch-UrlToDownload $item)) { return }   # (its sound can't be picked out)
          if ($st -and $st.Program -lt 0) { $hls = $st }
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
          $item.Info = ConvertFrom-ProbeOutput ([pscustomobject]@{ ExitCode = $pb.Bg.Proc.ExitCode; Out = $pb.Bg.Out.Result; Err = $pb.Bg.Err.Result })
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
      # is now, and can't be skipped back or forward. (Only HLS: another file without a length is still a file.)
      $isHls = ((Get-UrlMediaExt $item.Source) -eq 'm3u8') -or ($item.Stream -and $item.Stream.Kind -eq 'hls')
      $item.IsLive = ($item.Kind -eq 'url' -and $item.IsDirectUrl -and $isHls -and $item.Info.Duration -le 0)
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
    Wait-Pump 0.2
  }
  Clear-StatusLine
}

# Gets the next videos ready in the background. Downloads run one at a time, in queue order.
function Update-Prep {
  $last = [Math]::Min($script:Queue.Count - 1, $script:Idx + 2)
  for ($i = $script:Idx; $i -le $last; $i++) {
    $it = $script:Queue[$i]
    if ($i -gt $script:Idx) { Step-Prep $it }
    if ($it.State -eq 'downloading' -or ($i -eq $script:Idx -and $it.State -eq 'new')) { break }
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
# It keeps the stream's own timestamps (passthrough). By default ffmpeg timed it from 0, so once the stream was a few
# minutes in, this output seemed far behind the stream and ffmpeg held the stream back for it: the waiting / paused
# screens went out at about 14 of 24 frames a second, and every minute on them put viewers' players ~25 s further
# behind live. (Starting its timestamps at 0 instead stops the audio: then the stream itself seems far ahead.)
function Add-PreviewOutput($a, [ref]$graph) {
  $graph.Value += ';[v]split=2[vo][pv0];[pv0]fps=2,scale=384:-2,format=yuvj420p[pv]'
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
  if ($script:CanSubs -and -not $script:SlateNoText) { $vChain = "subtitles=filename=$($assFile):fontsdir=fonts,format=$pix" }
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
function Wait-Pump([double]$seconds) {
  $until = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $until) { Invoke-PanelPump; Start-Sleep -Milliseconds 50 }
}

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

# Questions in this window (Read-Host) while the control window is open: the keys are read here, so the control
# window keeps getting its state, and Ctrl+C ends the tool cleanly.
$script:CtrlCQuit = $false
function Stop-ByCtrlC {
  $script:CtrlCQuit = $true
  $script:StopAll = $true
  Add-Cmd (New-Cmd 'quit')
  throw (New-Object System.OperationCanceledException (T 'Stopped (Ctrl+C).'))
}

function Read-Host {
  param([Parameter(Position = 0)][object]$Prompt)
  if (-not $script:PanelShown -or -not $script:HasConsole) {
    # Ctrl+C at a question works as usual (it ends the tool), also while the stream reads keys itself.
    $ctrlKey = $false
    try { $ctrlKey = ($script:HasConsole -and [Console]::TreatControlCAsInput) } catch {}
    if ($ctrlKey) { Set-CtrlCAsKey $false }
    try {
      if ($null -ne $Prompt) { return (Microsoft.PowerShell.Utility\Read-Host -Prompt $Prompt) }
      return (Microsoft.PowerShell.Utility\Read-Host)
    } finally { if ($ctrlKey) { Set-CtrlCAsKey $true } }
  }
  if ($script:CtrlCQuit) { throw (New-Object System.OperationCanceledException (T 'Stopped (Ctrl+C).')) }
  Clear-StatusLine
  if ($null -ne $Prompt -and "$Prompt") { Write-Host ("$Prompt" + ': ') -NoNewline }
  $sb = New-Object System.Text.StringBuilder
  while ($true) {
    $k = $null
    try {
      while (-not [Console]::KeyAvailable) { Invoke-PanelPump; Start-Sleep -Milliseconds 40 }
      $k = [Console]::ReadKey($true)
    } catch { break }
    if ($k.Key -eq [ConsoleKey]::Enter) { break }
    if ($k.Key -eq [ConsoleKey]::C -and ($k.Modifiers -band [ConsoleModifiers]::Control)) { Write-Host ''; Stop-ByCtrlC }
    if ($k.Key -eq [ConsoleKey]::Backspace) {
      if ($sb.Length -gt 0) { $sb.Length = $sb.Length - 1; Write-Host ([string][char]8 + ' ' + [string][char]8) -NoNewline }
      continue
    }
    if ($k.Key -eq [ConsoleKey]::Escape) {
      while ($sb.Length -gt 0) { $sb.Length = $sb.Length - 1; Write-Host ([string][char]8 + ' ' + [string][char]8) -NoNewline }
      continue
    }
    if ([int]$k.KeyChar -ge 32) { [void]$sb.Append($k.KeyChar); Write-Host ([string]$k.KeyChar) -NoNewline }
  }
  Write-Host ''
  return $sb.ToString()
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
    default { @('stop', 'quit', 'resync', 'host', 'newlink', 'res', 'speedtest') }
  }
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
  if ($script:PanelShown) {
    for ($i = 0; $i -lt 20; $i++) {
      $p = $null
      try { $p = Read-PanelCommand } catch {}
      if (-not $p) { break }
      switch ($p.Cmd) {
        'add' { Open-AddWindow '' }
        'viewer' { Open-ViewerPreview }
        'clock' { Switch-Clock }
        default { Add-Cmd (New-Cmd $p.Cmd $p.Arg 'panel') }
      }
    }
  }
  Receive-WorldCommands $kind
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
  try {
    if (-not [Console]::KeyAvailable) { return $null }
    $quietUntil = (Get-Date).AddMilliseconds(40)
    while ((Get-Date) -lt $quietUntil) {
      if ([Console]::KeyAvailable) { $keys.Add([Console]::ReadKey($true)); $quietUntil = (Get-Date).AddMilliseconds(40) }
      else { Start-Sleep -Milliseconds 5 }
    }
  } catch { return $null }
  foreach ($k in $keys) {
    if ($k.Key -eq [ConsoleKey]::C -and ($k.Modifiers -band [ConsoleModifiers]::Control)) { $script:TypeBuf = ''; $script:Armed = $null; return (New-Cmd 'quit') }
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
  $txt = T '{0}p - {1} fps - {2} kbps' $script:OutH (Format-Num $fps) $script:VideoKbps
  if ($script:HostP) { $txt += ' - ' + $script:HostP.Name }
  return [pscustomobject]@{ Text = $txt; Low = ($bpp -gt 0 -and $bpp -lt 0.04) }
}

# The resolution menu. $true = the setting changed (saved in config.json).
function Select-Resolution {
  if (-not $script:Interactive) { return $false }
  $ceil = Get-KbpsCeiling
  $autoH = Get-AutoHeight $ceil
  $cur = Get-HeightSetting
  $hs = @(0) + @($script:Resolutions | ForEach-Object { [int]$_.H })
  $opts = @()
  foreach ($r in @(@{ H = 0; Min = 0 }) + $script:Resolutions) {
    $h = [int]$r.H
    if ($h -le 0) {
      $o = T 'Auto - the sharpest this host carries well (now {0}p, {1} kbps)' $autoH (Get-QualityKbps $autoH)
    } else {
      $o = T '{0}p - {1} kbps' $h (Get-QualityKbps $h)
      if ($ceil -lt $r.Min * (Get-FpsFactor)) { $o += ' ' + (T '(too big for {0} kbps: blurry when things move)' $ceil) }
    }
    if ($h -eq $cur) { $o = T '{0}  <- now' $o }
    $opts += $o
  }
  $ci = [array]::IndexOf($hs, $cur)
  if ($ci -lt 0) { $ci = 0; Say (T 'Now: {0}p (set in config.json).' $cur) 'Gray' }
  Say ''
  $i = Read-Choice (T 'Which picture size should the stream have?') $opts $ci $false
  $h = $hs[$i]
  if ($h -eq $cur) { return $false }
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
  if ($nx -and $nx.State -eq 'downloading') { return (T '  Waiting screen is on. Next: {0}   Q Q = end' (Get-DownloadText $nx)) }
  if ($nx) { return (T '  Waiting screen is on. Getting {0} ready...   Q Q = end' $nx.Name) }
  return (T '  Waiting screen is on. Type a title or paste a link + Enter (Enter alone = pick files).   Q Q = end')
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

function Update-Panel([string]$kind, $media, [double]$pos, [string]$status) {
  if (-not $script:PanelShown) { return }
  $script:PanelState = $null
  try {
    if (-not (Test-ControlPanelOpen)) { $script:PanelShown = $false; return }
    $title = ''
    if ($media) { $title = $media.Name }
    $dur = 0.0
    if ($media -and $media.Info -and $media.Info.Duration -gt 0) { $dur = $media.Info.Duration }
    $up = @()
    for ($i = $script:Idx + 1; $i -lt [Math]::Min($script:Queue.Count, $script:Idx + 21); $i++) { $up += $script:Queue[$i].Name }
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
    $script:PanelState = @{ Mode = $mode; Title = $title; Position = $pos; Duration = $dur; Status = $status.Trim(); Player = $pl; Upcoming = $up
      Link = $script:ShownLink; Clock = $script:ClockOn; CanSeek = (($kind -eq 'content' -or $kind -eq 'paused' -or $kind -eq 'hold') -and -not ($media -and $media.IsLive))
      Quality = $ql.Text; QualityLow = $ql.Low; QualityTip = $qtip }
    Update-ControlPanel $script:PanelState
  } catch { $script:PanelShown = $false }
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
        try { Step-Prep $nx } finally { $script:PromptOk = $false }
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
      Show-Status $st
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
}

# Stops what plays and empties the queue; the stream stays on the air with the waiting screen, and the window
# waits for something else to stream (typed, pasted, dropped or searched).
function Clear-QueueForStop {
  if ($script:Idx -lt $script:Queue.Count) {
    for ($i = $script:Idx; $i -lt $script:Queue.Count; $i++) {
      $it = $script:Queue[$i]
      if ($it.Dl) { Stop-Proc $it.Dl.Proc }
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
      try { Step-Prep $cur } finally { $script:PromptOk = $false }
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
      }
      $r = Invoke-Source -Kind 'waiting' -UntilNextReady
      if ($r.Outcome -eq 'quit' -or $r.Outcome -eq 'timeout') { break }
      if ($r.Outcome -eq 'stop') { Say (T '  Nothing is playing. Q Q ends the stream.') 'Gray'; continue }
      if ($r.Outcome -eq 'resync') { Restart-RelayForResync 'waiting'; continue }
      # The Settings menus ask in this window: the waiting screen goes on meanwhile (a server drops viewers of a
      # stream that stops sending). A menu that changes the stream stops / restarts it itself.
      $lost = ($r.Outcome -eq 'relay')
      if (@('host', 'newlink', 'res', 'speedtest') -contains $r.Outcome) {
        $alive = Test-RelayAlive
        if ($alive) { Start-Standby }
        if ($r.Outcome -eq 'host') { Invoke-HostMenu }
        elseif ($r.Outcome -eq 'newlink') { Invoke-NewLinkMenu }
        elseif ($r.Outcome -eq 'res') { Invoke-ResolutionMenu }
        else { Invoke-SpeedTestMenu }
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
    # A web stream that ends well before the episode does was cut off, not finished.
    if ($r.Outcome -eq 'done' -and $cur.Kind -eq 'site' -and $cur.IsDirectUrl -and $cur.Info.Duration -gt 60 -and $r.Position -lt $cur.Info.Duration - 20) { $r.Outcome = 'failed' }
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
    if (-not $script:EncoderProven -and $r.Elapsed -lt 20 -and ($r.Position - $cur.ResumeAt) -lt 1 -and $script:VEnc -ne 'libx264' -and $cur.Attempts -lt 3) {
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
    try { return (Test-VpsReady $p) } catch { if ($script:CtrlCQuit) { throw }; return $true }
  }
  if (-not $p -or -not $p.UsesMediaMtx) { return $true }
  $s = Get-Prop $script:Cfg 'SelfHost'
  $exe = $null
  try { $exe = Get-MediaMtxExe (Test-CanAsk) } catch { Say $_.Exception.Message 'Yellow' }
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
      (T 'Yes - only the IPv6 link can work'), (T 'Choose another host')) 0 $false
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
    try { [void](Enable-SelfHostFirewall $exe $ports) } catch { Say $_.Exception.Message 'Yellow' }
  }
  $up = Get-Prop $s 'Upnp'
  if (-not ($cg -and $cg.Verdict -eq 'cgnat')) {
    if ($null -eq $up -and (Test-CanAsk)) {
      $ans = Read-Host (T 'Open the port(s) {0} on your router automatically (UPnP)? They are closed again when you stop. [y/N]' (($ports | ForEach-Object { "$_" }) -join ', '))
      $up = (Test-AnswerYes $ans)
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
  if (-not (Test-HostModule)) { Update-StreamQuality; $script:ShownLink = Get-ShownLink; return }
  $script:HostP = Get-HostProfile
  $script:HostFallback = $false
  $script:HostIpv6Only = $false
  $ok = Start-HostServer
  # (Compared as a string: in PowerShell $true -eq 'menu' is true.)
  if ($ok -is [string] -and $ok -eq 'menu') {
    Stop-HostServer
    if (Select-Host) { Set-ActiveHost; return }
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

# The host menu (H): another host means another link; viewers get the new one.
function Invoke-HostMenu {
  if (-not (Test-HostModule) -or -not $script:HostP) { return }
  $was = $script:PromptOk
  $script:PromptOk = $true
  try {
    $changed = Select-Host
    if ($changed) {
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
    try { $r = Invoke-SpeedTest $script:HostP -BeforeRun { $testRan.Yes = $true; Stop-Relay } -ViewersWatch:$watched } catch { if ($script:CtrlCQuit) { throw }; Say (T '  The speed test didn''t work: {0}' $_.Exception.Message) 'Yellow' }
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
function Invoke-ResolutionMenu {
  $was = $script:PromptOk
  $script:PromptOk = $true
  try {
    if (-not (Select-Resolution)) { return }
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
      $ans = 'n'
      if ($env:VRCLM_RESUME) { $ans = $env:VRCLM_RESUME }
      elseif ($script:Interactive) {
        Say ''
        $ans = Read-Host (T 'Last time you stopped ''{0}'' at {1}. Continue from there? [Y/n]' $it.Name (Format-Time $pos))
      }
      if (-not (Test-AnswerNo $ans)) {
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
  foreach ($bg in $script:BgProcs) { Stop-Proc $bg.Proc }
  foreach ($it in $script:Queue) { if ($it.Dl) { Stop-Proc $it.Dl.Proc } }
  Close-Relay
  Start-Sleep -Milliseconds 300
  try { [System.IO.File]::Delete((Get-RelayProgPath)) } catch {}
  foreach ($it in $script:Queue) { Remove-ItemFiles $it }
  if ($script:PendingDirs.Count -gt 0) { Start-Sleep -Milliseconds 500; Remove-PendingDirs }
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
    if ($entries.Count -eq 0) { $entries = @(Read-Entries) }
    if ($entries.Count -eq 1 -and (Test-IsTitle ([string]$entries[0]))) { $entries = @([string]$entries[0]) }
    $abs = @()
    foreach ($e in $entries) {
      $t = "$e".Trim().Trim('"')
      if ($script:Interactive -and $t -notmatch '^(?i)[a-z][a-z0-9+.-]*://' -and (Test-IsTitle $t)) {
        # A title: search, pick, answer the questions here; the streaming window gets the link with the answers.
        $script:LastSearchLink = $null
        try { [void](Invoke-ContentSearch $t -AskPlayer) } catch { if ($script:CtrlCQuit) { throw }; Say (T '  The search didn''t work: {0}' $_.Exception.Message) 'Yellow' }
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
          } catch { if ($script:CtrlCQuit) { throw }; Say (T '  Couldn''t use {0}: {1}' (Get-ShortText $t 70) $_.Exception.Message) 'Yellow'; continue }
        }
        $abs += $t
      } else { try { $abs += [System.IO.Path]::GetFullPath($t) } catch {} }
    }
    if ($abs.Count -gt 0 -and $script:Interactive) {
      $when = Read-Choice (T 'Play it now, or after what is queued?') @((T 'After what is queued'), (T 'Now (instead of what plays now)')) 0 $false
      if ($when -eq 1) { $abs = @('#vrclm-now') + $abs }
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
    if ($entries.Count -eq 0) { $entries = @(Read-Entries) }
    [void](Add-Entries $entries $false)
    Receive-QueueFile
    if ($script:Queue.Count -eq 0) { Say (T 'Nothing to stream.') 'Yellow'; return }
    Show-Queue
    Invoke-ResumeOffer
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
  if ($script:CtrlCQuit) { Say (T 'Stopped (Ctrl+C).') 'Gray' }
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
