# VRChat Link Maker - the control window
# --------------------------------------
# A window next to the console. Left: a live preview of the stream and its buttons (pause / continue, jump back and
# forward, next video, stop, resync, the viewers' preview). Right: the input box (search, links, files), and as tabs
# Up next, Messages, and the question the console asks (it opens by itself). On top: what plays, the link to copy, and
# Settings. A narrow window puts the right side under the left one. The main script
# dot-sources this file and drives it from its own loop:
#   Open-ControlPanel             show it (or bring it to the front)
#   Update-ControlPanel $state    every ~200 ms: hands over what to show (the window picks it up itself)
#   Read-PanelCommand             the clicks, one at a time, in order ($null when none are left)
#   Test-ControlPanelOpen         false after the user closed the window (the stream keeps going)
#   Close-ControlPanel
#   Start-ViewerPreview $rtspUrl  ffplay watching the real stream, the way viewers get it
#   Stop-ViewerPreview
# The window runs on its own thread: a second runspace (STA) dot-sources this same file and runs the
# window's message loop there, so it keeps responding while the main loop is busy (looking up the next
# episode on a site, ffprobe, waiting for ffmpeg). The two threads share only $script:PanelSync, a
# synchronized hashtable: State (what to show), Cmds (the clicks), Ready, Closed, ShowReq, CloseReq, Error, and Bus:
# the main script's $script:UiBus, made once, so it outlives every window (Log, Cmds, Ask, Answers, Status, QuitReq;
# PanelSync.Cmds / .Log are the bus's own). A question open in the console (bus.Ask) shows in the window's question
# card too; its answer goes into bus.Answers, and the first answer (console or window) wins.
# Nothing on the window's side may throw: every handler is wrapped, and an internal error only closes the
# window (the reason goes to $script:PanelError and log.txt).
# What the window posts (Cmds, {Cmd; Arg}): the stream's commands (toggle, seek, seekto, skip, stop, resync, quit),
# viewer / clock, the Settings menu's item Ids (host / res / lang with the choice as Arg), 'line' (the input box's
# text), 'files' (paths: picked, dropped or pasted), and qplay / qup / qdown / qremove / qclear (Arg = @{ Id }, the
# Up next rows' buttons and menu). The main thread carries them out in Receive-Commands only, never inside a question.
# (This file stays plain ASCII: symbols are built from [char] codes.)

$script:Panel = $null         # (window thread) the window and its controls
$script:PanelSync = $null     # shared by both threads, see above
$script:PanelRs = $null       # (main thread) the window's runspace, kept for opening it again
$script:PanelPs = $null
$script:PanelRun = $null
$script:PanelSelf = $PSCommandPath
$script:PanelLast = @{}
$script:PanelError = $null
$script:PanelStyled = $false
$script:ViewerProc = $null
$script:PanelBounds = $null   # (main thread) where the last window was: @{ X; Y; W; H; Top }

# ------------------------------------------------------------------ commands (clicks and keys)
function Add-PanelCommand([string]$cmd, $arg = $null) {
  $script:PanelSync.Cmds.Enqueue([pscustomobject]@{ Cmd = $cmd; Arg = $arg })
}

function Read-PanelCommand {
  try {
    $c = $null
    # (The window's Cmds are the bus's: clicks made just before a window closed are still there after it.)
    $cq = $null
    if ($script:PanelSync) { $cq = $script:PanelSync.Cmds } elseif ($script:UiBus) { $cq = $script:UiBus.Cmds }
    if ($cq -and $cq.TryDequeue([ref]$c)) { return $c }
  } catch {}
  return $null
}

function Test-ControlPanelOpen {
  try {
    $s = $script:PanelSync
    if ($null -eq $s) { return $false }
    if ($s.Error -and -not $s.Logged) { $s.Logged = $true; Write-PanelError ([string]$s.Error) }
    if ($s.Warn) { $w = [string]$s.Warn; $s.Warn = $null; Write-PanelError $w }
    if ($s.Closed) { return $false }
    return (-not ($script:PanelRun -and $script:PanelRun.IsCompleted))
  } catch { return $false }
}

function Write-PanelError([string]$text) {
  $script:PanelError = $text
  if (Get-Command Write-LogLine -CommandType Function -ErrorAction SilentlyContinue) { Write-LogLine ('  (control window: ' + $text + ')') }
}

# A non-fatal error on the window's thread (the window stays): the main thread writes it to log.txt
# (Test-ControlPanelOpen -> Write-PanelError). Only the first few per window.
function Write-PanelWarning($err) {
  try {
    $sync = $script:PanelSync
    $q = $script:Panel
    if ($null -eq $sync -or $sync.Warn -or ($q -and $q.Warned -ge 3)) { return }
    $why = [string]$err
    if ($err -is [System.Management.Automation.ErrorRecord]) { $why = $err.Exception.Message + ' (line ' + $err.InvocationInfo.ScriptLineNumber + ')' }
    elseif ($err -is [System.Exception]) { $why = $err.Message }
    if ($q) { $q.Warned++ }
    $sync.Warn = $why
  } catch {}
}

# The control that has the keyboard focus (inside nested containers too).
function Get-PanelFocus {
  $c = $script:Panel.Form.ActiveControl
  while ($c -is [System.Windows.Forms.ContainerControl] -and $c.ActiveControl) { $c = $c.ActiveControl }
  return $c
}

# Are Space / Left / Right the window's shortcuts right now? Not while typing in a text box or a drop-down;
# in a list Left / Right scroll it (Space still pauses).
function Test-PanelKeyOurs([System.Windows.Forms.Keys]$code) {
  # (A question shown in its card: Space / the arrows are the card's own keys, see Invoke-PanelAskKey. Not while
  # another tab is looked at meanwhile, nor on the search's "Searching..." card: it has no use for them.)
  try { if ($script:Panel.AskId -and $script:Panel.Ask.Visible -and [string]$script:Panel.AskView['Kind'] -ne 'busy') { return $false } } catch {}
  $K = [System.Windows.Forms.Keys]
  $fc = $null
  try { $fc = Get-PanelFocus } catch {}
  if ($fc -is [System.Windows.Forms.TextBoxBase] -or $fc -is [System.Windows.Forms.ComboBox]) { return $false }
  if (($fc -is [System.Windows.Forms.ListBox] -or $fc -is [System.Windows.Forms.ListView]) -and ($code -eq $K::Left -or $code -eq $K::Right)) { return $false }
  return $true
}

# Space / Left / Right / Shift+Left / Shift+Right while the window has focus. $true = the key was ours.
function Invoke-PanelKey([System.Windows.Forms.Keys]$keyData) {
  $p = $script:Panel
  if ($null -eq $p) { return $false }
  $K = [System.Windows.Forms.Keys]
  $code = $keyData -band $K::KeyCode
  $mods = $keyData -band $K::Modifiers
  if (($code -eq $K::Space -or $code -eq $K::Left -or $code -eq $K::Right) -and -not (Test-PanelKeyOurs $code)) { return $false }
  if ($code -eq $K::Space -and $mods -eq $K::None) {
    if ($p.Big.Enabled) { Add-PanelCommand 'toggle' }
    return $true
  }
  if (($code -eq $K::Left -or $code -eq $K::Right) -and ($mods -eq $K::None -or $mods -eq $K::Shift)) {
    if ($p.Back10.Enabled) {
      $step = 10
      if ($mods -eq $K::Shift) { $step = 30 }
      if ($code -eq $K::Left) { $step = -$step }
      Add-PanelCommand 'seek' $step
    }
    return $true
  }
  return $false
}

# Buttons and lists treat arrows / Space as their own keys; this makes them reach the window's KeyDown.
function Add-PanelKeyHook($ctrl) {
  $ctrl.Add_PreviewKeyDown({
    param($sender, $e)
    try {
      $kc = $e.KeyCode
      if ($kc -eq [System.Windows.Forms.Keys]::Left -or $kc -eq [System.Windows.Forms.Keys]::Right -or $kc -eq [System.Windows.Forms.Keys]::Space) { $e.IsInputKey = $true }
    } catch {}
  })
  foreach ($ch in $ctrl.Controls) { Add-PanelKeyHook $ch }
}

# ------------------------------------------------------------------ building the window
function New-PanelColor([int]$r, [int]$g, [int]$b) { return [System.Drawing.Color]::FromArgb($r, $g, $b) }

function New-PanelLabel([string]$text, [int]$height, $font, $color) {
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $text
  $l.AutoSize = $false
  $l.AutoEllipsis = $true
  $l.Dock = [System.Windows.Forms.DockStyle]::Fill
  $l.Height = $height
  $l.Margin = New-Object System.Windows.Forms.Padding(2, 1, 2, 1)
  $l.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
  if ($font) { $l.Font = $font }
  if ($color) { $l.ForeColor = $color }
  return $l
}

# A flat dark button. $cmd: what a click queues (nothing when empty; the caller adds its own handler).
function New-PanelButton([string]$text, [string]$tip, [string]$cmd, $arg, $font) {
  $c = $script:Panel.Colors
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $text
  $b.Dock = [System.Windows.Forms.DockStyle]::Fill
  $b.Margin = New-Object System.Windows.Forms.Padding(2)
  $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $b.FlatAppearance.BorderColor = $c.Border
  $b.FlatAppearance.MouseOverBackColor = $c.Hover
  $b.UseVisualStyleBackColor = $false
  $b.BackColor = $c.Button
  $b.ForeColor = $c.Text
  $b.AutoEllipsis = $true
  if ($font) { $b.Font = $font }
  if ($cmd) {
    $b.Tag = [pscustomobject]@{ Cmd = $cmd; Arg = $arg }
    $b.Add_Click({ try { Add-PanelCommand ([string]$this.Tag.Cmd) $this.Tag.Arg } catch {} })
  }
  if ($tip) { $script:Panel.Tips.SetToolTip($b, $tip) }
  return $b
}

function New-PanelGrid([int]$cols, [int]$height) {
  $t = New-Object System.Windows.Forms.TableLayoutPanel
  $t.ColumnCount = $cols
  $t.RowCount = 1
  $t.Dock = [System.Windows.Forms.DockStyle]::Fill
  $t.Height = $height
  $t.Margin = New-Object System.Windows.Forms.Padding(0)
  $t.Padding = New-Object System.Windows.Forms.Padding(0)
  [void]$t.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  return $t
}


function New-ControlPanel {
  $WF = 'System.Windows.Forms'
  $p = @{
    Closed = $false; Link = ''; QuestLink = ''; Mode = ''; Warned = 0; LogWidest = 0; RealPos = 0.0; PosText = ''; SeekDur = 0.0; SeekShown = 0.0; SeekOn = $false; SeekPx = -1
    Drag = $false; DragPos = 0.0; HoldPos = 0.0; HoldUntil = [DateTime]::MinValue
    StopArmedUntil = [DateTime]::MinValue; CopiedUntil = [DateTime]::MinValue; CopiedBtn = $null
    PrevCheck = [DateTime]::MinValue; PrevTime = [DateTime]::MinValue; PrevMissing = [DateTime]::MinValue
    InputOn = $false; CmdOn = $false; ListIds = @(); BannerUntil = [DateTime]::MinValue; CueSet = $false; CueTries = 0; InputParked = $false; InRows = $false; Timer = $null
    AskId = ''; AskSent = ''; AskSentAt = [DateTime]::MinValue; AskView = $null; AskFocus = $null; AskFocusPending = $false; AskFlashing = $false
    AskInfoText = ''; AskList = $null; AskPicks = @(); AskText = $null; AskDigits = ''; AskDigitsAt = [DateTime]::MinValue
    Wide = $null; Page = 'queue'; PageBack = 'queue'; ClockOn = $false; ListNames = @(); ListInfo = @(); QHot = -1; QHotBtn = ''; QOn = $false
    AskRows = @(); AskHot = -1; AskTags = $false; LogAtEnd = $true; Icon = $null; ListTotal = 0; QPress = $null; AskCtxLines = @()
    WarmAt = [DateTime]::MinValue
  }
  $script:Panel = $p
  $script:PanelLast = @{}
  $p.Colors = @{
    Back = (New-PanelColor 30 30 32); Box = (New-PanelColor 40 40 44); Button = (New-PanelColor 52 52 58)
    Hover = (New-PanelColor 70 70 80); Border = (New-PanelColor 80 80 90); Text = (New-PanelColor 232 232 236)
    Dim = (New-PanelColor 160 160 170); Accent = (New-PanelColor 64 156 255); Track = (New-PanelColor 75 75 85)
    Red = (New-PanelColor 190 55 55); Black = [System.Drawing.Color]::Black
    Card = (New-PanelColor 34 46 66); Sel = (New-PanelColor 40 72 116); Hot = (New-PanelColor 50 50 58); Faint = (New-PanelColor 110 110 120)
    Pick = (New-PanelColor 40 90 150); Warn = (New-PanelColor 232 200 90); Tag = (New-PanelColor 51 64 90); TagText = (New-PanelColor 185 207 245)
  }
  $c = $p.Colors
  $p.Brushes = @{
    Track = (New-Object System.Drawing.SolidBrush($c.Track)); Fill = (New-Object System.Drawing.SolidBrush($c.Accent))
    Thumb = (New-Object System.Drawing.SolidBrush($c.Text)); Off = (New-Object System.Drawing.SolidBrush((New-PanelColor 60 60 66)))
    Dim = (New-Object System.Drawing.SolidBrush($c.Dim)); Row = (New-Object System.Drawing.SolidBrush($c.Box))
  }
  $p.Font = New-Object System.Drawing.Font('Segoe UI', [single]9)
  $p.Bold = New-Object System.Drawing.Font('Segoe UI', [single]10.5, [System.Drawing.FontStyle]::Bold)
  $p.Small = New-Object System.Drawing.Font('Segoe UI', [single]8.25, [System.Drawing.FontStyle]::Bold)
  $p.Sym = New-Object System.Drawing.Font('Segoe UI Symbol', [single]9.75)
  $p.SymS = New-Object System.Drawing.Font('Segoe UI Symbol', [single]9)   # (a symbol among normal-sized text: Resync)
  $p.BigFont = New-Object System.Drawing.Font('Segoe UI Symbol', [single]11, [System.Drawing.FontStyle]::Bold)
  $p.Mono = New-Object System.Drawing.Font('Consolas', [single]9)
  $fh = $p.Font.Height
  $k = $fh / 15.0
  $p.K = $k
  $p.NumW = [System.Windows.Forms.TextRenderer]::MeasureText('00', $p.Font).Width
  $p.Tips = New-Object "$WF.ToolTip"
  $p.Tips.AutoPopDelay = 15000
  $p.Tips.InitialDelay = 400

  $f = New-Object "$WF.Form"
  $p.Form = $f
  $f.Text = 'VRChat Link Maker'
  $f.Font = $p.Font
  $f.BackColor = $c.Back
  $f.ForeColor = $c.Text
  $f.KeyPreview = $true
  $f.ShowInTaskbar = $true
  $f.AllowDrop = $true
  try { $p.Icon = New-PanelIcon; if ($p.Icon) { $f.Icon = $p.Icon } } catch {}
  $f.Add_HandleCreated({ try { Set-PanelDarkTitle $this } catch {} })
  $f.StartPosition = [System.Windows.Forms.FormStartPosition]::WindowsDefaultLocation
  $f.MinimumSize = New-Object System.Drawing.Size([int](560 * $k), [int](620 * $k))
  # Wide by default (the player left, the queue / messages / questions right); a narrow window stacks them instead.
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $f.Size = New-Object System.Drawing.Size([int]([Math]::Min(1120 * $k, [Math]::Max(560 * $k, $wa.Width - 40))), [int]([Math]::Min(720 * $k, [Math]::Max(620 * $k, $wa.Height - 60))))
  # The same place and size as the window before it (opened again, e.g. after a language change), if still on a screen.
  $sb = $null
  try { $sb = $script:PanelSync.StartBounds } catch {}
  if ($sb) {
    try {
      $r = New-Object System.Drawing.Rectangle([int]$sb.X, [int]$sb.Y, [int]$sb.W, [int]$sb.H)
      $seen = $false
      foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) { if ($scr.WorkingArea.IntersectsWith($r)) { $seen = $true } }
      if ($seen -and $r.Width -gt 0 -and $r.Height -gt 0) { $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual; $f.Bounds = $r }
    } catch {}
  }
  $f.SuspendLayout()

  $root = New-Object "$WF.TableLayoutPanel"
  $root.Dock = [System.Windows.Forms.DockStyle]::Fill
  $root.ColumnCount = 1
  $root.Padding = New-Object System.Windows.Forms.Padding([int](8 * $k))
  [void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  # Rows: 0 what plays + Settings, 1 link bar, 2 warnings banner, 3 the two sides (Update-PanelLayout puts them side by
  # side, or one above the other in a narrow window). Left: the preview (it takes what is left, so it is what shrinks),
  # seek bar, transport, status, VRChat player, viewer preview + resync. Right: the input box, the tabs, and the page
  # of the tab: Up next, Messages, or the open question (it takes this side, so the player never moves).
  foreach ($r in @('Auto', 'Auto', 'Auto', 'P100')) {
    if ($r -eq 'Auto') { [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) }
    else { [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) }
  }
  $root.RowCount = 4
  $p.Root = $root

  # Row 0: what the stream is doing + the title, what the stream carries (a dim chip: host - picture fps kbps; orange
  # when it is too few bits for the picture size), and [Settings]. The chip is as wide as its text: the title gives way.
  $top = New-PanelGrid 4 ($p.Bold.Height + [int](12 * $k))
  [void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
  [void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  [void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
  $p.Badge = New-Object "$WF.Label"
  $p.Badge.AutoSize = $true
  $p.Badge.Font = $p.Small
  $p.Badge.Anchor = [System.Windows.Forms.AnchorStyles]::Left
  $p.Badge.Padding = New-Object System.Windows.Forms.Padding([int](6 * $k), [int](2 * $k), [int](6 * $k), [int](2 * $k))
  $p.Badge.Margin = New-Object System.Windows.Forms.Padding(2, 2, [int](6 * $k), 2)
  $p.Title = New-PanelLabel (T 'Nothing is playing') ($p.Bold.Height + 6) $p.Bold $null
  $top.Controls.Add($p.Badge, 0, 0)
  $top.Controls.Add($p.Title, 1, 0)
  $p.Quality = New-Object "$WF.Label"
  $p.Quality.AutoSize = $true
  $p.Quality.ForeColor = $c.Dim
  $p.Quality.Anchor = [System.Windows.Forms.AnchorStyles]::Right
  $p.Quality.Margin = New-Object System.Windows.Forms.Padding([int](6 * $k), 1, [int](6 * $k), 1)
  $top.Controls.Add($p.Quality, 2, 0)
  # Settings: the same list as M in the console (the main thread sends it, see Update-PanelMenu), then the clock, always
  # on top, log.txt and End stream. What changes the link or the picture works only while nothing plays.
  $p.More = New-PanelButton ((T 'Settings') + ' ' + [char]0x25BE) (T 'Where to stream, picture size, speed test, new link, language, the clock on the stream, always on top, log.txt and End stream. The stream settings work while nothing plays; their questions show here and in the console window.') '' $null $null
  $p.More.AutoEllipsis = $false
  $menu = New-Object "$WF.ContextMenuStrip"
  $menu.ShowItemToolTips = $true
  $menu.Add_Opening({ try { Update-PanelMenu } catch { Write-PanelWarning $_ } })
  $p.Menu = $menu
  Update-PanelMenu
  $p.More.Add_Click({ try { $q = $script:Panel; $q.Menu.Show($q.More, 0, $q.More.Height) } catch {} })
  $mw = [System.Windows.Forms.TextRenderer]::MeasureText([string]$p.More.Text, $p.Font).Width + [int](26 * $k)
  [void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, [single]$mw)))
  $top.Controls.Add($p.More, 3, 0)
  $root.Controls.Add($top, 0, 0)

  # Row 1: the link for the world's player, [Copy], [Quest link] (when the host has one).
  $lk = New-PanelGrid 4 ([int]($fh * 2.1))
  $p.LinkLabel = New-Object "$WF.Label"
  $p.LinkLabel.Text = T 'Link for VRChat:'
  $p.LinkLabel.AutoSize = $true
  $p.LinkLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Left
  $p.LinkLabel.ForeColor = $c.Dim
  $p.LinkLabel.Margin = New-Object System.Windows.Forms.Padding(2, 1, [int](4 * $k), 1)
  $lb0 = New-Object "$WF.TextBox"
  $lb0.ReadOnly = $true
  $lb0.Font = $p.Mono
  $lb0.BackColor = $c.Box
  $lb0.ForeColor = $c.Text
  $lb0.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $lb0.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $lb0.Margin = New-Object System.Windows.Forms.Padding(2, 1, 2, 1)
  $lb0.Add_Click({ try { $this.SelectAll() } catch {} })
  $p.LinkBox = $lb0
  $p.Copy = New-PanelButton (T 'Copy') '' '' $null $null
  $p.Copy.Add_Click({ try { $q = $script:Panel; if ($q.Link) { Set-PanelClipboard $q.Copy ([string]$q.Link) } } catch {} })
  $p.CopyText = $p.Copy.Text
  $p.Quest = New-PanelButton (T 'Quest link') '' '' $null $null
  $p.Quest.Add_Click({ try { $q = $script:Panel; if ($q.QuestLink) { Set-PanelClipboard $q.Quest ([string]$q.QuestLink) } } catch {} })
  $p.QuestText = $p.Quest.Text
  $bw = [Math]::Max([System.Windows.Forms.TextRenderer]::MeasureText($p.CopyText, $p.Font).Width, [System.Windows.Forms.TextRenderer]::MeasureText((T 'Copied!'), $p.Font).Width) + [int](22 * $k)
  $p.QuestW = [Math]::Max([System.Windows.Forms.TextRenderer]::MeasureText($p.QuestText, $p.Font).Width, [System.Windows.Forms.TextRenderer]::MeasureText((T 'Copied!'), $p.Font).Width) + [int](22 * $k)
  [void]$lk.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
  [void]$lk.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  [void]$lk.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, [single]$bw)))
  [void]$lk.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 0)))
  $p.Quest.Visible = $false
  $lk.Controls.Add($p.LinkLabel, 0, 0)
  $lk.Controls.Add($lb0, 1, 0)
  $lk.Controls.Add($p.Copy, 2, 0)
  $lk.Controls.Add($p.Quest, 3, 0)
  $p.LinkBar = $lk
  $root.Controls.Add($lk, 0, 1)

  # Row 2: the latest warning (a yellow or red line of the messages) for about 15 s; a click hides it.
  $bn = New-PanelLabel '' ($fh + [int](10 * $k)) $null $null
  $bn.Padding = New-Object System.Windows.Forms.Padding([int](6 * $k), 0, [int](6 * $k), 0)
  $bn.Margin = New-Object System.Windows.Forms.Padding(2, [int](3 * $k), 2, [int](2 * $k))
  $bn.Cursor = [System.Windows.Forms.Cursors]::Hand
  $bn.Visible = $false
  $bn.Add_Click({ try { Hide-PanelBanner } catch {} })
  $p.Banner = $bn
  $root.Controls.Add($bn, 0, 2)

  # Row 3: the two sides (cells and sizes: Update-PanelLayout).
  $body = New-Object "$WF.TableLayoutPanel"
  $body.Dock = [System.Windows.Forms.DockStyle]::Fill
  $body.ColumnCount = 2
  $body.RowCount = 2
  $body.Margin = New-Object System.Windows.Forms.Padding(0, [int](4 * $k), 0, 0)
  $body.Padding = New-Object System.Windows.Forms.Padding(0)
  [void]$body.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  [void]$body.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, [single](440 * $k))))
  [void]$body.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  [void]$body.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 0)))
  $p.Body = $body
  $left = New-Object "$WF.TableLayoutPanel"
  $left.Dock = [System.Windows.Forms.DockStyle]::Fill
  $left.ColumnCount = 1
  $left.Margin = New-Object System.Windows.Forms.Padding(0)
  $left.Padding = New-Object System.Windows.Forms.Padding(0)
  [void]$left.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  [void]$left.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  for ($i = 0; $i -lt 5; $i++) { [void]$left.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) }
  $left.RowCount = 6
  # (The status line is one or two lines high, as its text needs at this width: Set-PanelStatusHeight.)
  $left.Add_SizeChanged({ try { Set-PanelStatusHeight } catch {} })
  $p.LeftPane = $left
  $right = New-Object "$WF.TableLayoutPanel"
  $right.Dock = [System.Windows.Forms.DockStyle]::Fill
  $right.ColumnCount = 1
  $right.Margin = New-Object System.Windows.Forms.Padding(0)
  $right.Padding = New-Object System.Windows.Forms.Padding(0)
  [void]$right.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  [void]$right.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
  [void]$right.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
  [void]$right.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  $right.RowCount = 3
  $p.RightPane = $right
  $body.Controls.Add($left, 0, 0)
  $body.Controls.Add($right, 1, 0)
  $root.Controls.Add($body, 0, 3)

  # Left 0: the preview picture (what ffmpeg sends, refreshed about twice a second)
  $pv = New-Object "$WF.PictureBox"
  $pv.Dock = [System.Windows.Forms.DockStyle]::Fill
  $pv.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
  $pv.BackColor = $c.Black
  $pv.Margin = New-Object System.Windows.Forms.Padding(2, 0, 2, [int](4 * $k))
  # (No minimum height: a control taller than its row would spill over the seek bar below it.)
  $pv.Add_Paint({
    param($sender, $e)
    try {
      if ($null -eq $sender.Image) {
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = [System.Drawing.StringAlignment]::Center
        $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $rect = New-Object System.Drawing.RectangleF(0, 0, $sender.ClientSize.Width, $sender.ClientSize.Height)
        $e.Graphics.DrawString((T 'No preview yet'), $script:Panel.Font, $script:Panel.Brushes.Dim, $rect, $fmt)
        $fmt.Dispose()
      }
    } catch {}
  })
  $p.Preview = $pv
  $left.Controls.Add($pv, 0, 0)

  # Left 1: position, seek bar, duration
  $tw = [System.Windows.Forms.TextRenderer]::MeasureText('00:00:00', $p.Font).Width + [int](6 * $k)
  $time = New-PanelGrid 3 ([int]($fh * 1.7))
  [void]$time.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, [single]$tw)))
  [void]$time.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  [void]$time.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, [single]$tw)))
  $p.Pos = New-PanelLabel '0:00' $time.Height $null $null
  $p.Dur = New-PanelLabel '--:--' $time.Height $null $c.Dim
  $p.Dur.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
  # The seek bar is drawn by hand (a PictureBox is double-buffered): click or drag anywhere to jump.
  $bar = New-Object "$WF.PictureBox"
  $bar.Dock = [System.Windows.Forms.DockStyle]::Fill
  $bar.Margin = New-Object System.Windows.Forms.Padding(2, 0, 2, 0)
  $bar.BackColor = $c.Back
  $bar.Cursor = [System.Windows.Forms.Cursors]::Hand
  $bar.Add_Paint({ param($sender, $e) try { Show-PanelSeekBar $e.Graphics $sender } catch {} })
  $bar.Add_MouseDown({
    param($sender, $e)
    try {
      $q = $script:Panel
      if ($q.SeekOn -and $e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $q.Drag = $true
        $q.DragPos = Get-PanelBarValue $sender $e.X
        Update-PanelSeekShown
      }
    } catch {}
  })
  $bar.Add_MouseMove({
    param($sender, $e)
    try { $q = $script:Panel; if ($q.Drag) { $q.DragPos = Get-PanelBarValue $sender $e.X; Update-PanelSeekShown } } catch {}
  })
  $bar.Add_MouseUp({
    param($sender, $e)
    try {
      $q = $script:Panel
      if ($q.Drag) {
        $q.Drag = $false
        $q.DragPos = Get-PanelBarValue $sender $e.X
        $q.HoldPos = $q.DragPos
        $q.HoldUntil = [DateTime]::UtcNow.AddSeconds(2.5)
        Add-PanelCommand 'seekto' ([Math]::Round($q.DragPos, 1))
        Update-PanelSeekShown
      }
    } catch {}
  })
  # Capture lost in the middle of a drag (Alt+Tab, another window): no jump.
  $bar.Add_MouseCaptureChanged({ try { $q = $script:Panel; if ($q.Drag) { $q.Drag = $false; Update-PanelSeekShown } } catch {} })
  $p.Bar = $bar
  $p.Tips.SetToolTip($bar, (T 'Click or drag to jump to a moment in the video.'))
  $time.Controls.Add($p.Pos, 0, 0)
  $time.Controls.Add($bar, 1, 0)
  $time.Controls.Add($p.Dur, 2, 0)
  $left.Controls.Add($time, 0, 1)

  # Left 2: transport buttons
  $rew = [string][char]0x23EA
  $fwd = [string][char]0x23E9
  $tr = New-PanelGrid 7 ([int]($fh * 2.5))
  $p.Back30 = New-PanelButton ($rew + ' ' + (T '{0}s' 30)) (T 'Back 30 seconds (Shift+Left)') 'seek' (-30) $p.Sym
  $p.Back10 = New-PanelButton ($rew + ' ' + (T '{0}s' 10)) (T 'Back 10 seconds (Left arrow)') 'seek' (-10) $p.Sym
  $p.Big = New-PanelButton '' (T 'Space pauses and continues') 'toggle' $null $p.BigFont
  $p.Big.BackColor = $c.Pick
  $p.Fwd10 = New-PanelButton ((T '{0}s' 10) + ' ' + $fwd) (T 'Forward 10 seconds (Right arrow)') 'seek' 10 $p.Sym
  $p.Fwd30 = New-PanelButton ((T '{0}s' 30) + ' ' + $fwd) (T 'Forward 30 seconds (Shift+Right)') 'seek' 30 $p.Sym
  $p.Next = New-PanelButton ((T 'Next') + ' ' + [char]0x23ED) (T 'Skip to the next video in the list.') 'skip' $null $p.Sym
  $p.StopText = [string][char]0x25A0 + ' ' + (T 'Stop')
  $p.Stop = New-PanelButton $p.StopText (T 'Stop this video and pick something else (click twice). Viewers see the waiting screen meanwhile.') '' $null $p.Sym
  $p.Stop.Add_Click({
    try {
      $q = $script:Panel
      if ([DateTime]::UtcNow -lt $q.StopArmedUntil) {
        $q.StopArmedUntil = [DateTime]::MinValue
        Reset-PanelStop
        Add-PanelCommand 'stop'
      } else {
        $q.StopArmedUntil = [DateTime]::UtcNow.AddSeconds(3)
        # (wraps onto two lines in a smaller font instead of being cut off)
        $q.Stop.AutoEllipsis = $false
        $q.Stop.Font = $q.Font
        $q.Stop.Text = T 'Click again to stop'
        $q.Stop.BackColor = $q.Colors.Red
      }
    } catch {}
  })
  # Column widths follow the texts; the middle button gets room for its longest text and a bit more.
  $bigW = 0
  foreach ($x in @((T 'Pause'), (T 'Continue'), (T 'Start now'))) { $bigW = [Math]::Max($bigW, [System.Windows.Forms.TextRenderer]::MeasureText(([string][char]0x25B6 + ' ' + $x), $p.BigFont).Width) }
  $tr.ColumnStyles.Clear()
  foreach ($b in @($p.Back30, $p.Back10, $p.Big, $p.Fwd10, $p.Fwd30, $p.Next, $p.Stop)) {
    $w = [System.Windows.Forms.TextRenderer]::MeasureText([string]$b.Text, $b.Font).Width + [int](18 * $k)
    if ($b -eq $p.Big) { $w = $bigW + [int](24 * $k) }
    if ($b -eq $p.Stop) { $w = [System.Windows.Forms.TextRenderer]::MeasureText($p.StopText, $b.Font).Width + [int](18 * $k) }
    [void]$tr.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, [single]$w)))
  }
  $i = 0
  foreach ($b in @($p.Back30, $p.Back10, $p.Big, $p.Fwd10, $p.Fwd30, $p.Next, $p.Stop)) { $b.AutoEllipsis = $false; $tr.Controls.Add($b, $i, 0); $i++ }
  $left.Controls.Add($tr, 0, 2)

  # Left 3-4: status, the VRChat player (what the stream carries is the chip right of the title)
  $p.Status = New-PanelLabel '' ($fh + 6) $null $null
  $p.Status.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
  $p.Status.Margin = New-Object System.Windows.Forms.Padding(2, [int](6 * $k), 2, 1)
  $left.Controls.Add($p.Status, 0, 3)
  $p.Player = New-PanelLabel '' ($fh + 6) $null $c.Dim
  $left.Controls.Add($p.Player, 0, 4)

  # Left 5: the viewer preview and resync (as wide as their texts, on the left)
  $act = New-Object "$WF.FlowLayoutPanel"
  $act.Dock = [System.Windows.Forms.DockStyle]::Fill
  $act.AutoSize = $true
  $act.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
  $act.WrapContents = $false
  $act.Margin = New-Object System.Windows.Forms.Padding(0, [int](2 * $k), 0, 0)
  $p.Viewer = New-PanelButton (T 'Watch as viewers see it') (T 'Opens the real stream in a small player window, the way viewers get it (with their delay). Close it any time.') 'viewer' $null $null
  $p.Resync = New-PanelButton ([string][char]0x21BB + ' ' + (T 'Resync everyone')) (T 'Everyone''s player reconnects to the live picture, so all viewers are in sync again. The video waits for them.') 'resync' $null $p.SymS
  foreach ($b in @($p.Viewer, $p.Resync)) { Set-PanelAutoButton $b; $act.Controls.Add($b) }
  $p.Actions = $act
  $left.Controls.Add($act, 0, 5)

  # Right 0: the input box (a title, a link, a file path; Enter = Add), [Files...], [Folder...]. Files and folders can be
  # dropped anywhere on the window, links and text too.
  $in = New-PanelGrid 4 ([int]($fh * 2.3))
  $ib = New-Object "$WF.TextBox"
  $ib.BackColor = $c.Box
  $ib.ForeColor = $c.Text
  $ib.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $ib.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $ib.Margin = New-Object System.Windows.Forms.Padding(2, 1, 2, 1)
  $ib.Add_KeyDown({
    param($sender, $e)
    try { if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { $e.Handled = $true; $e.SuppressKeyPress = $true; Submit-PanelInput } } catch {}
  })
  $ib.Add_HandleCreated({ try { Set-PanelCue } catch {} })
  $ib.Add_TextChanged({ try { Request-PanelWarm } catch {} })
  $p.Input = $ib
  $p.AddLine = New-PanelButton (T 'Add') (T 'Add what you typed (Enter): a link or a file is queued, a title is searched for.') '' $null $null
  $p.AddLine.Add_Click({ try { Submit-PanelInput } catch {} })
  $p.Files = New-PanelButton (T 'Files...') (T 'Pick video files to add.') '' $null $null
  $p.Files.Add_Click({ try { Show-PanelFileDialog } catch { Write-PanelWarning $_ } })
  $p.Folder = New-PanelButton (T 'Folder...') (T 'Add every video in a folder.') '' $null $null
  $p.Folder.Add_Click({ try { Show-PanelFolderDialog } catch { Write-PanelWarning $_ } })
  [void]$in.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  foreach ($b in @($p.AddLine, $p.Files, $p.Folder)) {
    $w = [System.Windows.Forms.TextRenderer]::MeasureText([string]$b.Text, $b.Font).Width + [int](22 * $k)
    [void]$in.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, [single]$w)))
  }
  $in.Controls.Add($ib, 0, 0)
  $in.Controls.Add($p.AddLine, 1, 0)
  $in.Controls.Add($p.Files, 2, 0)
  $in.Controls.Add($p.Folder, 3, 0)
  $p.InputRow = $in
  $right.Controls.Add($in, 0, 0)

  # Right 1: the tabs. [Question] shows only while a question is open (it opens by itself; the other tabs can still be
  # looked at meanwhile).
  $tabs = New-Object "$WF.FlowLayoutPanel"
  $tabs.Dock = [System.Windows.Forms.DockStyle]::Fill
  $tabs.AutoSize = $true
  $tabs.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
  $tabs.WrapContents = $false
  $tabs.Margin = New-Object System.Windows.Forms.Padding(2, [int](6 * $k), 2, 0)
  $p.TabAsk = New-PanelTab (T 'Question') 'ask'
  $p.TabAsk.Visible = $false
  $p.TabQueue = New-PanelTab (T 'Up next') 'queue'
  $p.TabLog = New-PanelTab (T 'Messages') 'log'
  foreach ($b in @($p.TabAsk, $p.TabQueue, $p.TabLog)) { $tabs.Controls.Add($b) }
  $p.Tabs = $tabs
  $right.Controls.Add($tabs, 0, 1)

  # Right 2: the pages (one shows at a time, Select-PanelPage).
  $pages = New-Object "$WF.Panel"
  $pages.Dock = [System.Windows.Forms.DockStyle]::Fill
  $pages.Margin = New-Object System.Windows.Forms.Padding(2, 0, 2, 2)
  $pages.Padding = New-Object System.Windows.Forms.Padding(0)
  $p.Pages = $pages

  # Up next: one row per video (drawn here: Show-PanelQueueRow), with Play now / Move up / Move down / Remove on the row
  # under the mouse and in its right-click menu (by the item's Id: the main thread may have changed the queue meanwhile).
  $lb = New-Object "$WF.ListBox"
  $lb.Dock = [System.Windows.Forms.DockStyle]::Fill
  $lb.IntegralHeight = $false
  $lb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $lb.BackColor = $c.Box
  $lb.ForeColor = $c.Text
  $lb.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
  $lb.ItemHeight = $fh + [int](12 * $k)
  $lb.Visible = $false
  $lb.Add_DrawItem({ param($sender, $e) try { Show-PanelQueueRow $sender $e } catch {} })
  $lb.Add_MouseMove({ param($sender, $e) try { Update-PanelQueueHot $sender $e.Location } catch {} })
  $lb.Add_MouseLeave({ param($sender, $e) try { Update-PanelQueueHot $sender $null } catch {} })
  # (A row's button acts on the item it was pressed on, Invoke-PanelQueueIcon. A quick second click arrives as a double
  # click: it counts as a click too.)
  $lb.Add_MouseClick({
    param($sender, $e)
    try { if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Invoke-PanelQueueIcon $sender $e.Location } } catch { Write-PanelWarning $_ }
  })
  $lb.Add_MouseDoubleClick({
    param($sender, $e)
    try { if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Invoke-PanelQueueIcon $sender $e.Location } } catch { Write-PanelWarning $_ }
  })
  $lb.Add_MouseDown({
    param($sender, $e)
    try {
      if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        $ix = $sender.IndexFromPoint($e.Location)
        if ($ix -ge 0) { $sender.SelectedIndex = $ix }
      } elseif ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $script:Panel.QPress = Get-PanelQueueHit $sender $e.Location }
    } catch {}
  })
  $qm = New-Object "$WF.ContextMenuStrip"
  $p.QPlay = New-PanelMenuItem (T 'Play now') 'qplay'
  $p.QUp = New-PanelMenuItem (T 'Move up') 'qup'
  $p.QDown = New-PanelMenuItem (T 'Move down') 'qdown'
  $p.QRemove = New-PanelMenuItem (T 'Remove') 'qremove'
  $p.QClear = New-PanelMenuItem (T 'Clear the queue') 'qclear'
  foreach ($mi in @($p.QPlay, $p.QUp, $p.QDown, $p.QRemove)) {
    $mi.Add_Click({ try { $id = Get-PanelListId; if ($id -gt 0) { Add-PanelCommand ([string]$this.Tag.Cmd) @{ Id = $id } } } catch {} })
  }
  $p.QClear.Add_Click({ try { if (Confirm-Panel (T 'Remove everything from Up next?')) { Add-PanelCommand 'qclear' @{ Id = (Get-PanelListId) } } } catch { Write-PanelWarning $_ } })
  foreach ($mi in @($p.QPlay, $p.QUp, $p.QDown, $p.QRemove)) { [void]$qm.Items.Add($mi) }
  [void]$qm.Items.Add((New-Object "$WF.ToolStripSeparator"))
  [void]$qm.Items.Add($p.QClear)
  $qm.Add_Opening({ try { Update-PanelQueueMenu } catch { Write-PanelWarning $_ } })
  $lb.ContextMenuStrip = $qm
  $p.List = $lb
  # (Nothing queued: what to do instead of an empty list.)
  $le = New-Object "$WF.Label"
  $le.Dock = [System.Windows.Forms.DockStyle]::Fill
  $le.AutoSize = $false
  $le.UseMnemonic = $false
  $le.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
  $le.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $le.BackColor = $c.Box
  $le.ForeColor = $c.Dim
  $le.Padding = New-Object System.Windows.Forms.Padding([int](16 * $k))
  $le.Text = (T 'Nothing queued yet') + "`r`n`r`n" + (T 'Type a title or paste a link above and press Enter, or drop videos anywhere on this window.')
  $p.ListEmpty = $le

  # Messages (everything the console window shows; right-click copies)
  $lg = New-Object "$WF.ListBox"
  $lg.Dock = [System.Windows.Forms.DockStyle]::Fill
  $lg.IntegralHeight = $false
  $lg.HorizontalScrollbar = $true
  $lg.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $lg.BackColor = $c.Box
  $lg.ForeColor = $c.Text
  $lg.Font = New-Object System.Drawing.Font('Consolas', [single]8.25)
  $lg.Margin = New-Object System.Windows.Forms.Padding(0)
  $lg.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
  $lg.ItemHeight = $lg.Font.Height + 1
  $lg.SelectionMode = [System.Windows.Forms.SelectionMode]::MultiExtended
  $lg.Visible = $false
  $p.LogColors = New-Object 'System.Collections.Generic.List[string]'
  $p.LogPal = @{
    Red = (New-PanelColor 240 110 110); DarkRed = (New-PanelColor 240 110 110); Yellow = (New-PanelColor 232 200 90); DarkYellow = (New-PanelColor 232 200 90)
    Green = (New-PanelColor 110 205 125); DarkGreen = (New-PanelColor 110 205 125); Cyan = (New-PanelColor 100 190 235); DarkCyan = (New-PanelColor 100 190 235)
    Gray = $c.Dim; DarkGray = $c.Dim; Magenta = (New-PanelColor 210 140 230)
  }
  $lg.Add_DrawItem({
    param($sender, $e)
    try {
      if ($e.Index -lt 0) { return }
      $q = $script:Panel
      $e.DrawBackground()
      $col = $q.Colors.Text
      if ($e.Index -lt $q.LogColors.Count) { $n = $q.LogColors[$e.Index]; if ($n -and $q.LogPal.ContainsKey($n)) { $col = $q.LogPal[$n] } }
      if (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0) { $col = [System.Drawing.SystemColors]::HighlightText }
      # (as wide as the widest line, so a line scrolled sideways isn't cut off at the list's edge)
      $b = $e.Bounds
      $rect = New-Object System.Drawing.Rectangle($b.X, $b.Y, [Math]::Max($b.Width, $sender.HorizontalExtent), $b.Height)
      [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$sender.Items[$e.Index], $e.Font, $rect, $col, [System.Windows.Forms.TextFormatFlags]::NoPrefix -bor [System.Windows.Forms.TextFormatFlags]::SingleLine -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter)
    } catch {}
  })
  # Right-click: copy the selected lines or all of them, or open log.txt (the whole session).
  $lcm = New-Object "$WF.ContextMenuStrip"
  $p.LogCopy = New-Object "$WF.ToolStripMenuItem"
  $p.LogCopy.Text = T 'Copy'
  $p.LogCopy.Add_Click({
    try {
      $t = (@($script:Panel.Log.SelectedItems) | ForEach-Object { [string]$_ }) -join "`r`n"
      if ($t) { [System.Windows.Forms.Clipboard]::SetDataObject($t, $true, 5, 100) }
    } catch {}
  })
  $lmi = New-Object "$WF.ToolStripMenuItem"
  $lmi.Text = T 'Copy all'
  $lmi.Add_Click({
    try {
      $t = (@($script:Panel.Log.Items) | ForEach-Object { [string]$_ }) -join "`r`n"
      if ($t) { [System.Windows.Forms.Clipboard]::SetDataObject($t, $true, 5, 100) }
    } catch {}
  })
  $p.LogOpen = New-Object "$WF.ToolStripMenuItem"
  $p.LogOpen.Text = T 'Open log.txt'
  $p.LogOpen.Add_Click({ try { Open-PanelLogFile } catch { Write-PanelWarning $_ } })
  [void]$lcm.Items.Add($p.LogCopy)
  [void]$lcm.Items.Add($lmi)
  [void]$lcm.Items.Add($p.LogOpen)
  $lcm.Add_Opening({
    try {
      $q = $script:Panel
      $q.LogCopy.Enabled = ($q.Log.SelectedIndices.Count -gt 0)
      $q.LogOpen.Enabled = (Test-PanelLogFile)
    } catch {}
  })
  $lg.ContextMenuStrip = $lcm
  $p.Log = $lg

  foreach ($x in @($lb, $le, $lg, (New-PanelAskStrip))) { $pages.Controls.Add($x) }
  $right.Controls.Add($pages, 0, 2)

  $f.Controls.Add($root)
  $f.Add_KeyDown({
    param($sender, $e)
    try {
      if (Invoke-PanelAskKey $e.KeyData) { $e.Handled = $true; $e.SuppressKeyPress = $true; return }
      if (Invoke-PanelPaste $e.KeyData) { $e.Handled = $true; $e.SuppressKeyPress = $true; return }
      if (Invoke-PanelKey $e.KeyData) { $e.Handled = $true; $e.SuppressKeyPress = $true }
    } catch {}
  })
  $f.Add_KeyUp({
    param($sender, $e)
    try { if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Space -and (Test-PanelKeyOurs $e.KeyCode)) { $e.Handled = $true; $e.SuppressKeyPress = $true } } catch {}
  })
  $f.Add_Resize({ try { Update-PanelLayout; Set-PanelAskWidths } catch {} })
  # (A question that came while the window was behind: its answer box gets the focus once the window is in front.)
  # (Not while another tab shows: the focus goes into the question when its tab is clicked, Set-PanelPageFocus.)
  $f.Add_Activated({ try { $q = $script:Panel; if ($q.AskFocusPending -and $q.Ask.Visible) { $q.AskFocusPending = $false; Move-PanelAskFocus } } catch {} })
  $f.Add_FormClosing({ try { Save-PanelBounds } catch {} })
  $f.Add_FormClosed({ try { $script:Panel.Closed = $true; $script:PanelSync.Closed = $true; Remove-PanelImage } catch {} })
  Add-PanelKeyHook $f
  Add-PanelDropHook $f
  if ($sb -and $sb.Top) { $f.TopMost = $true }
  Select-PanelPage 'queue'
  Update-PanelLayout
  $f.ResumeLayout($true)
  $f.ActiveControl = $p.Big
  Set-PanelMode 'off'
}

# A button as wide as its text (in a flow of buttons: the actions under the transport, the question's bar).
function Set-PanelAutoButton($b) {
  $q = $script:Panel
  $k = $q.K
  $b.Dock = [System.Windows.Forms.DockStyle]::None
  $b.AutoSize = $true
  $b.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
  $b.AutoEllipsis = $false
  $b.MinimumSize = New-Object System.Drawing.Size([int](84 * $k), [int]($q.Font.Height * 1.9))
  $b.Padding = New-Object System.Windows.Forms.Padding([int](8 * $k), 0, [int](8 * $k), 0)
}

# A tab of the right side ($page: 'ask' | 'queue' | 'log'); the shown one is lighter and underlined.
function New-PanelTab([string]$text, [string]$page) {
  $q = $script:Panel
  $k = $q.K
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $text
  $b.Tag = $page
  $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $b.FlatAppearance.BorderSize = 0
  $b.FlatAppearance.MouseOverBackColor = $q.Colors.Hot
  $b.FlatAppearance.MouseDownBackColor = $q.Colors.Hot
  $b.UseVisualStyleBackColor = $false
  $b.BackColor = $q.Colors.Back
  $b.ForeColor = $q.Colors.Dim
  $b.AutoSize = $true
  $b.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
  $b.MinimumSize = New-Object System.Drawing.Size([int](60 * $k), [int]($q.Font.Height * 1.9))
  $b.Padding = New-Object System.Windows.Forms.Padding([int](8 * $k), 0, [int](8 * $k), 0)
  $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, [int](2 * $k), 0)
  $b.Add_Click({ try { $pg = [string]$this.Tag; Select-PanelPage $pg; Set-PanelPageFocus $pg } catch { Write-PanelWarning $_ } })
  $b.Add_Paint({
    param($sender, $e)
    try {
      $q2 = $script:Panel
      if ([string]$sender.Tag -ceq $q2.Page) { $h = [Math]::Max(2, [int](2 * $q2.K)); $e.Graphics.FillRectangle($q2.Brushes.Fill, 0, $sender.Height - $h, $sender.Width, $h) }
    } catch {}
  })
  return $b
}

# After a tab click the focus goes into its page: the question's answer (so Enter answers it), else the list (the
# read-only link box when there is none). Never left on the tab button: Enter there would only click the tab again.
function Set-PanelPageFocus([string]$page) {
  $q = $script:Panel
  if ($page -eq 'ask' -and $q.AskId -and $q.Ask.Visible) { $q.AskFocusPending = $false; Move-PanelAskFocus; return }
  $c = $q.LinkBox
  if ($page -eq 'queue' -and $q.List.Visible) { $c = $q.List } elseif ($page -eq 'log' -and $q.Log.Visible) { $c = $q.Log }
  $q.Form.ActiveControl = $c
}

# A Settings / Up next menu item; Tag.Cmd = what a click queues (the click handler is the caller's).
function New-PanelMenuItem([string]$text, [string]$cmd, $arg = $null) {
  $mi = New-Object System.Windows.Forms.ToolStripMenuItem
  $mi.Text = $text
  $mi.Tag = [pscustomobject]@{ Cmd = $cmd; Arg = $arg }
  return $mi
}

# Every control takes dropped files / links / text (a control that doesn't allow it would refuse the drop).
function Add-PanelDropHook($ctrl) {
  $ctrl.AllowDrop = $true
  $ctrl.Add_DragEnter({ param($sender, $e) try { $e.Effect = Get-PanelDropEffect $e.Data } catch {} })
  $ctrl.Add_DragOver({ param($sender, $e) try { $e.Effect = Get-PanelDropEffect $e.Data } catch {} })
  $ctrl.Add_DragDrop({ param($sender, $e) try { [void](Receive-PanelDrop $e.Data) } catch { Write-PanelWarning $_ } })
  foreach ($ch in $ctrl.Controls) { Add-PanelDropHook $ch }
}

# What a drop / paste carries: @{ Kind = 'files'; Files } or @{ Kind = 'line'; Text }, or $null.
function Get-PanelDropData($data) {
  if ($null -eq $data) { return $null }
  $DF = [System.Windows.Forms.DataFormats]
  if ($data.GetDataPresent($DF::FileDrop)) {
    $fs = @(@($data.GetData($DF::FileDrop)) | ForEach-Object { [string]$_ } | Where-Object { $_ })
    if ($fs.Count -gt 0) { return @{ Kind = 'files'; Files = [string[]]$fs } }
  }
  $t = ''
  if ($data.GetDataPresent('UniformResourceLocatorW')) {
    $o = $data.GetData('UniformResourceLocatorW')
    if ($o -is [System.IO.MemoryStream]) { $t = [System.Text.Encoding]::Unicode.GetString($o.ToArray()) }
    elseif ($null -ne $o) { $t = [string]$o }
    $t = $t.Trim([char]0).Trim()
  }
  if (-not $t -and $data.GetDataPresent($DF::UnicodeText)) { $t = [string]$data.GetData($DF::UnicodeText) }
  if (-not $t -and $data.GetDataPresent($DF::Text)) { $t = [string]$data.GetData($DF::Text) }
  if ($t -and $t.Trim()) { return @{ Kind = 'line'; Text = $t.Trim() } }
  return $null
}

function Get-PanelDropEffect($data) {
  if (-not $script:Panel.InputOn) { return [System.Windows.Forms.DragDropEffects]::None }
  $DF = [System.Windows.Forms.DataFormats]
  foreach ($fm in @($DF::FileDrop, 'UniformResourceLocatorW', $DF::UnicodeText, $DF::Text)) {
    if ($data.GetDataPresent($fm)) { return [System.Windows.Forms.DragDropEffects]::Copy }
  }
  return [System.Windows.Forms.DragDropEffects]::None
}

# A drop: files / a folder -> 'files', a link or text -> 'line' (as typed into the box and Enter). $true = posted.
function Receive-PanelDrop($data) {
  if (-not $script:Panel.InputOn) { return $false }
  $d = Get-PanelDropData $data
  if ($null -eq $d) { return $false }
  if ($d.Kind -eq 'files') { [void](Submit-PanelFiles $d.Files) } else { [void](Submit-PanelLine $d.Text) }
  return $true
}

# A title being typed while a video plays: the main thread loads its search (Start-AddWorker), so it is ready by Enter.
# Not for a link or a path (they are added without one); at most every 30 s.
function Request-PanelWarm {
  $q = $script:Panel
  $t = ([string]$q.Input.Text).Trim()
  if ($t.Length -lt 2 -or @('', 'off', 'waiting') -contains [string]$q.Mode) { return }
  if ($t -match '^(?i)([a-z][a-z0-9+.-]*://|magnet:|[a-z]:[\\/]|[\\/"])') { return }
  if (([DateTime]::UtcNow - $q.WarmAt).TotalSeconds -lt 30) { return }
  $q.WarmAt = [DateTime]::UtcNow
  Add-PanelCommand 'warm' ''
}

# Enter / [Add]: what the box holds goes to the main thread as a typed line.
function Submit-PanelInput {
  $q = $script:Panel
  if (-not $q.InputOn) { return }
  $t = [string]$q.Input.Text
  if (-not $t.Trim()) { return }
  if (Submit-PanelLine $t.Trim()) { $q.Input.Clear() }
}

# A typed / dropped line and picked / dropped files: the answer to the start screen's '>' while it waits (bus.Ask of
# kind 'line'), else a command (Receive-Commands: as typed into the console while it streams).
function Submit-PanelLine([string]$text) {
  $a = Get-PanelAsk
  if ($a -and [string]$a['Kind'] -eq 'line') { return (Send-PanelAnswer @{ Text = $text } -Line) }
  Add-PanelCommand 'line' $text
  return $true
}

function Submit-PanelFiles([string[]]$files) {
  $a = Get-PanelAsk
  if ($a -and [string]$a['Kind'] -eq 'line') { return (Send-PanelAnswer @{ Files = [string[]]@($files) } -Line) }
  Add-PanelCommand 'files' $files
  return $true
}

# Ctrl+V outside a text box: copied files are added, text goes into the input box (focused). Text of several lines
# (a list of links) is added as it is, like a drop, also from inside the input box: the one-line box would keep only
# its first line. $true = handled.
function Invoke-PanelPaste([System.Windows.Forms.Keys]$keyData) {
  $K = [System.Windows.Forms.Keys]
  if ($keyData -ne ($K::Control -bor $K::V)) { return $false }
  $q = $script:Panel
  $fc = $null
  try { $fc = Get-PanelFocus } catch {}
  $inBox = ($fc -is [System.Windows.Forms.TextBoxBase] -or $fc -is [System.Windows.Forms.ComboBox])
  if ($inBox -and -not ($fc -eq $q.Input -and $q.InputOn)) { return $false }
  if (-not $q.InputOn) { return $true }
  $do = $null
  try { $do = [System.Windows.Forms.Clipboard]::GetDataObject() } catch {}
  if ($do -and -not $inBox -and $do.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { [void](Receive-PanelDrop $do); return $true }
  $txt = ''
  try { $txt = [string][System.Windows.Forms.Clipboard]::GetText() } catch {}
  if ($txt.Trim() -match "[`r`n]") { [void](Submit-PanelLine $txt.Trim()); return $true }
  if ($inBox) { return $false }
  $q.Input.Focus() | Out-Null
  $q.Input.SelectionStart = $q.Input.TextLength
  $q.Input.Paste()
  return $true
}

# The grey hint in the empty input box (EM_SETCUEBANNER through the tool's helper DLL; without it, no hint).
function Set-PanelCue {
  $q = $script:Panel
  if ($q.CueSet -or -not $q.Input.IsHandleCreated) { return }
  if (-not ('VRCLinkMaker.Win' -as [type])) { return }
  [void][VRCLinkMaker.Win]::SendMessage($q.Input.Handle, 0x1501, [IntPtr]1, (T 'Search for a title or paste a link'))
  $q.CueSet = $true
}

# A modal dialog / message from a click: the window's timer stops meanwhile (no state updates under the dialog).
function Stop-PanelTimer { $q = $script:Panel; if ($q.Timer) { $q.Timer.Stop() } }
function Start-PanelTimer { $q = $script:Panel; if ($q.Timer -and -not $q.Closed) { $q.Timer.Start() } }

function Confirm-Panel([string]$text) {
  $q = $script:Panel
  Stop-PanelTimer
  try {
    $r = [System.Windows.Forms.MessageBox]::Show($q.Form, $text, 'VRChat Link Maker', [System.Windows.Forms.MessageBoxButtons]::YesNo,
      [System.Windows.Forms.MessageBoxIcon]::Question, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
  } finally { Start-PanelTimer }
}

function Show-PanelFileDialog {
  $q = $script:Panel
  if (-not $q.InputOn) { return }
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $files = @()
  try {
    $dlg.Title = T 'Pick the videos to stream (you can pick several)'
    $dlg.Multiselect = $true
    $exts = [string]$script:PanelSync.MediaExts
    if (-not $exts) { $exts = '*.*' }
    $dlg.Filter = (T 'Videos') + '|' + $exts + '|' + (T 'All files') + '|*.*'
    Stop-PanelTimer
    try { if ($dlg.ShowDialog($q.Form) -eq [System.Windows.Forms.DialogResult]::OK) { $files = @($dlg.FileNames) } } finally { Start-PanelTimer }
  } finally { $dlg.Dispose() }
  if ($files.Count -gt 0) { [void](Submit-PanelFiles ([string[]]$files)) }
}

function Show-PanelFolderDialog {
  $q = $script:Panel
  if (-not $q.InputOn) { return }
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dir = ''
  try {
    $dlg.Description = T 'Pick a folder with videos'
    $dlg.ShowNewFolderButton = $false
    Stop-PanelTimer
    try { if ($dlg.ShowDialog($q.Form) -eq [System.Windows.Forms.DialogResult]::OK) { $dir = [string]$dlg.SelectedPath } } finally { Start-PanelTimer }
  } finally { $dlg.Dispose() }
  if ($dir) { [void](Submit-PanelFiles ([string[]]@($dir))) }
}

# Copies a link and shows "Copied!" on its button for a moment.
function Set-PanelClipboard($btn, [string]$text) {
  $q = $script:Panel
  [System.Windows.Forms.Clipboard]::SetDataObject($text, $true, 5, 100)
  Reset-PanelCopied
  $btn.Text = T 'Copied!'
  $q.CopiedBtn = $btn
  $q.CopiedUntil = [DateTime]::UtcNow.AddSeconds(1.5)
}

function Reset-PanelCopied {
  $q = $script:Panel
  $q.CopiedUntil = [DateTime]::MinValue
  $q.Copy.Text = $q.CopyText
  $q.Quest.Text = $q.QuestText
  $q.CopiedBtn = $null
}

function Test-PanelLogFile {
  $f = [string]$script:PanelSync.LogPath
  return [bool]($f -and [System.IO.File]::Exists($f))
}

function Open-PanelLogFile {
  $f = [string]$script:PanelSync.LogPath
  if ($f -and [System.IO.File]::Exists($f)) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $f
    $psi.UseShellExecute = $true
    [void][System.Diagnostics.Process]::Start($psi)
  }
}

# The Settings menu, made again each time it opens from what the main thread sent last (State.Menu = Get-MenuItems:
# Id, Label, On; State.Choices.<id> = the choices of host / res / lang with State.Chosen.<id> checked). A click queues
# the item's Id (with the choice as Arg); the main thread runs it on the waiting screen (Invoke-Queue).
function Update-PanelMenu {
  $q = $script:Panel
  $m = $q.Menu
  $s = $null
  try { $s = $script:PanelSync.State } catch {}
  $old = @($m.Items)
  $m.Items.Clear()
  foreach ($x in $old) { try { $x.Dispose() } catch {} }
  $prompt = ($s -and [bool]$s['Prompt'])
  $mode = ''
  if ($s) { $mode = [string]$s['Mode'] }
  # (Not while the main thread asks: the item would only run after it. The search's questions don't hold it.)
  $asking = Test-PanelMainAsk
  $waitOk = ($mode -eq 'waiting' -and -not $prompt -and -not $asking)
  $tip = T 'Available while nothing plays (press Stop first).'
  $n = 0
  if ($s -and $null -ne $s['Menu']) {
    $choices = $s['Choices']
    $chosen = $s['Chosen']
    foreach ($it in @($s['Menu'])) {
      $id = [string]$it['Id']
      $list = @()
      if ($choices -and $null -ne $choices[$id]) { $list = @($choices[$id]) }
      $label = [string]$it['Label']
      if ($list.Count -gt 0) { $label = $label.TrimEnd('.', [char]0x2026).TrimEnd() }
      $mi = New-PanelMenuItem $label $id
      if ($list.Count -gt 0) {
        $cur = ''
        if ($chosen) { $cur = [string]$chosen[$id] }
        foreach ($ch in $list) {
          $sub = New-PanelMenuItem ([string]$ch['Label']) $id ([string]$ch['Value'])
          $sub.Checked = ([string]$ch['Value'] -ceq $cur)
          if ($ch['Tip']) { $sub.ToolTipText = [string]$ch['Tip'] }
          $sub.Add_Click({ try { Add-PanelCommand ([string]$this.Tag.Cmd) ([string]$this.Tag.Arg) } catch {} })
          [void]$mi.DropDownItems.Add($sub)
        }
        try { $mi.DropDown.ShowItemToolTips = $true } catch {}
      } else {
        $mi.Add_Click({ try { Add-PanelCommand ([string]$this.Tag.Cmd) } catch {} })
      }
      $mi.Enabled = ($waitOk -and [bool]$it['On'])
      if (-not $waitOk) { $mi.ToolTipText = $tip }
      [void]$m.Items.Add($mi)
      $n++
    }
  }
  if ($n -gt 0) { [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) }
  # The clock on the stream (ticked as the stream has it: the main thread flips it after the command) and always on top.
  $ck = New-PanelMenuItem (T 'Clock on the stream') 'clock'
  $ck.Checked = [bool]$q.ClockOn
  $ck.ToolTipText = T 'The video time in a corner of the picture: compare it to spot who is behind.'
  $ck.Add_Click({ try { Add-PanelCommand 'clock' } catch {} })
  [void]$m.Items.Add($ck)
  $ot = New-PanelMenuItem (T 'Always on top') 'ontop'
  $ot.Checked = [bool]$q.Form.TopMost
  $ot.Add_Click({ try { $f = $script:Panel.Form; $f.TopMost = -not $f.TopMost } catch {} })
  [void]$m.Items.Add($ot)
  [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  $lo = New-PanelMenuItem (T 'Open log.txt') 'openlog'
  $lo.Enabled = (Test-PanelLogFile)
  $lo.Add_Click({ try { Open-PanelLogFile } catch { Write-PanelWarning $_ } })
  [void]$m.Items.Add($lo)
  [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  $en = New-PanelMenuItem (T 'End stream...') 'quit'
  # (Also while a question waits, the start screen's '>' included: QuitReq ends the tool from there, see Test-UiQuit.)
  $en.Enabled = [bool]($s -and (($mode -and $mode -ne 'off' -and -not $prompt) -or $null -ne (Get-PanelAsk)))
  $en.Add_Click({
    try {
      if (Confirm-Panel (T 'End the stream now? Viewers lose the picture.')) {
        $b = Get-PanelBus
        if ($b) { $b.QuitReq = $true }
        Add-PanelCommand 'quit'
      }
    } catch { Write-PanelWarning $_ }
  })
  [void]$m.Items.Add($en)
}

# The Id of the selected Up next line (0 = none).
function Get-PanelListId {
  $q = $script:Panel
  $ix = $q.List.SelectedIndex
  $ids = @($q.ListIds)
  if ($ix -ge 0 -and $ix -lt $ids.Count) { return [int]$ids[$ix] }
  return 0
}

function Update-PanelQueueMenu {
  $q = $script:Panel
  $s = $null
  try { $s = $script:PanelSync.State } catch {}
  $ok = ($null -ne $s -and -not [bool]$s['Prompt'] -and -not (Test-PanelMainAsk))
  $ids = @($q.ListIds)
  $ix = $q.List.SelectedIndex
  $has = ($ok -and (Get-PanelListId) -gt 0)
  $q.QPlay.Enabled = $has
  $q.QRemove.Enabled = $has
  $q.QUp.Enabled = ($has -and $ix -gt 0)
  $q.QDown.Enabled = ($has -and $ix -lt [Math]::Max($ids.Count, [int]$q.ListTotal) - 1)
  $q.QClear.Enabled = ($ok -and $ids.Count -gt 0)
}

# The two sides: next to each other (the player left, a column of 400-560 px right), or in a narrow window one above
# the other (the player above; while a question is open its side gets more of the height). Called on every resize;
# it switches at 940 / 980 px, not at one width, so a window dragged around that width doesn't flip back and forth.
function Update-PanelLayout {
  $q = $script:Panel
  if ($null -eq $q -or $q.InRows -or $null -eq $q.Body) { return }
  $q.InRows = $true
  try {
    # (Minimized, the client area is 0 x 0: that is no reason to stack the sides.)
    if ($q.Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized -or $q.Form.ClientSize.Width -le 0) { return }
    $k = $q.K
    $body = $q.Body
    $w = $q.Form.ClientSize.Width - $q.Root.Padding.Horizontal
    $wide = $q.Wide
    if ($null -eq $wide) { $wide = ($w -ge [int](960 * $k)) }
    elseif ($wide -and $w -lt [int](940 * $k)) { $wide = $false }
    elseif (-not $wide -and $w -ge [int](980 * $k)) { $wide = $true }
    $cs = $body.ColumnStyles
    $rs = $body.RowStyles
    if ($wide) {
      $rw = [single][int][Math]::Min(560 * $k, [Math]::Max(400 * $k, $w * 0.4))
      if ($q.Wide -ne $true) {
        $body.SuspendLayout()
        try {
          $body.SetCellPosition($q.RightPane, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(1, 0)))
          $rs[0].SizeType = [System.Windows.Forms.SizeType]::Percent; $rs[0].Height = 100
          $rs[1].SizeType = [System.Windows.Forms.SizeType]::Absolute; $rs[1].Height = 0
          $cs[1].SizeType = [System.Windows.Forms.SizeType]::Absolute; $cs[1].Width = $rw
          $q.LeftPane.Margin = New-Object System.Windows.Forms.Padding(0, 0, [int](8 * $k), 0)
        } finally { $body.ResumeLayout($true) }
      } elseif ($cs[1].Width -ne $rw) { $cs[1].Width = $rw }
    } else {
      # (A question gets the larger share: its options, a list of search results.)
      $top = [single]55
      if ($q.AskId) { $top = [single]40 }
      if ($q.Wide -ne $false) {
        $body.SuspendLayout()
        try {
          $body.SetCellPosition($q.RightPane, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(0, 1)))
          $cs[1].SizeType = [System.Windows.Forms.SizeType]::Absolute; $cs[1].Width = 0
          $rs[0].SizeType = [System.Windows.Forms.SizeType]::Percent; $rs[0].Height = $top
          $rs[1].SizeType = [System.Windows.Forms.SizeType]::Percent; $rs[1].Height = [single](100 - $top)
          $q.LeftPane.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, [int](6 * $k))
        } finally { $body.ResumeLayout($true) }
      } elseif ($rs[0].Height -ne $top) { $rs[0].Height = $top; $rs[1].Height = [single](100 - $top) }
    }
    $q.Wide = $wide
  } finally { $q.InRows = $false }
}

# The status line: one line high, two when its text needs them at this width (a third line ends in "..."). Measured
# by the label itself (it draws the way it measures): taller at its width than in one line = it wraps.
function Set-PanelStatusHeight {
  $q = $script:Panel
  if ($null -eq $q -or $null -eq $q.Status) { return }
  $st = $q.Status
  $w = $st.Width
  if ($w -le 20) { return }
  $lines = 1
  if ($st.Text -and $st.GetPreferredSize((New-Object System.Drawing.Size($w, 0))).Height -gt $st.GetPreferredSize((New-Object System.Drawing.Size(0, 0))).Height) { $lines = 2 }
  $want = $lines * $q.Font.Height + 6
  if ($st.Height -ne $want) { $st.Height = $want }
}

# Shows one page of the right side: 'queue' (Up next; a hint instead while nothing is queued), 'log' (Messages) or
# 'ask' (the open question).
function Select-PanelPage([string]$page) {
  $q = $script:Panel
  if ($page -eq 'ask' -and -not $q.AskId) { $page = 'queue' }
  $empty = ($q.List.Items.Count -eq 0)
  $show = @{ List = ($page -eq 'queue' -and -not $empty); ListEmpty = ($page -eq 'queue' -and $empty); Log = ($page -eq 'log'); Ask = ($page -eq 'ask') }
  # (A page that goes away with the focus in it hands it to the read-only link box first: not to the next control, a
  # transport button, where a later Enter / Space would act.)
  foreach ($n in @('List', 'Log', 'Ask')) { if (-not $show[$n] -and $q[$n].ContainsFocus) { $q.Form.ActiveControl = $q.LinkBox } }
  # (Leaving Messages: whether it showed the newest lines then - not when the last line came - decides how it opens again.)
  if ($q.Log.Visible -and -not $show.Log) {
    $rows = [Math]::Max(1, [int][Math]::Floor($q.Log.ClientSize.Height / [Math]::Max(1, $q.Log.ItemHeight)))
    $q.LogAtEnd = ($q.Log.Items.Count -eq 0) -or (($q.Log.TopIndex + $rows) -ge ($q.Log.Items.Count - 1))
  }
  $wasLog = $q.Log.Visible
  $q.Page = $page
  foreach ($n in @('List', 'ListEmpty', 'Log', 'Ask')) { if ($q[$n].Visible -ne $show[$n]) { $q[$n].Visible = $show[$n] } }
  # (Messages that came while another page showed: it shows the newest ones, unless it was scrolled up before.)
  if ($show.Log -and -not $wasLog -and $q.LogAtEnd -and $q.Log.Items.Count -gt 0) {
    $rows = [Math]::Max(1, [int][Math]::Floor($q.Log.ClientSize.Height / [Math]::Max(1, $q.Log.ItemHeight)))
    $q.Log.TopIndex = [Math]::Max(0, $q.Log.Items.Count - $rows)
  }
  Update-PanelTabs
}

# The tabs' texts (Up next with how many) and looks: the shown one light and underlined, [Question] yellow while open.
function Update-PanelTabs {
  $q = $script:Panel
  $n = [Math]::Max(@($q.ListIds).Count, [int]$q.ListTotal)
  $t = T 'Up next'
  if ($n -gt 0) { $t += ' (' + $n + ')' }
  if ($q.TabQueue.Text -cne $t) { $q.TabQueue.Text = $t }
  $ask = [bool]$q.AskId
  if ($q.TabAsk.Visible -ne $ask) { $q.TabAsk.Visible = $ask }
  foreach ($b in @($q.TabAsk, $q.TabQueue, $q.TabLog)) {
    $on = ([string]$b.Tag -ceq $q.Page)
    $fc = $q.Colors.Dim
    if ($on) { $fc = $q.Colors.Text } elseif ($b -eq $q.TabAsk) { $fc = $q.Colors.Warn }
    $bc = $q.Colors.Back
    if ($on) { $bc = $q.Colors.Box }
    if ($b.ForeColor -ne $fc) { $b.ForeColor = $fc }
    if ($b.BackColor -ne $bc) { $b.BackColor = $bc }
    $b.Invalidate()
  }
}

# ------------------------------------------------------------------ Up next rows
# The row's buttons (only on the row under the mouse or the selected one, and only while the queue can change): Play
# now, Move up, Move down, Remove, from the left; each @{ Cmd; Rect; On; Glyph }.
function Get-PanelQueueIcons($lb, [int]$i) {
  $q = $script:Panel
  $n = @($q.ListIds).Count
  if (-not $q.QOn -or $i -lt 0 -or $i -ge $n -or $i -ge $lb.Items.Count) { return @() }
  if ($i -ne $q.QHot -and $i -ne $lb.SelectedIndex) { return @() }
  # (The rows stop at 20: the 20th can still go down when more wait.)
  $all = [Math]::Max($n, [int]$q.ListTotal)
  $r = $lb.GetItemRectangle($i)
  $iw = [int](24 * $q.K)
  $x = $r.Right - [int](4 * $q.K) - 4 * $iw
  $out = @()
  foreach ($d in @(@('qplay', 0x25B6, $true), @('qup', 0x25B2, ($i -gt 0)), @('qdown', 0x25BC, ($i -lt $all - 1)), @('qremove', 0x2715, $true))) {
    $out += @{ Cmd = [string]$d[0]; Glyph = [string][char][int]$d[1]; On = [bool]$d[2]; Rect = (New-Object System.Drawing.Rectangle($x, $r.Y, $iw, $r.Height)) }
    $x += $iw
  }
  return $out
}

function Get-PanelQueueTip([string]$cmd) {
  switch ($cmd) {
    'qplay' { return (T 'Play now') }
    'qup' { return (T 'Move up') }
    'qdown' { return (T 'Move down') }
    'qremove' { return (T 'Remove') }
  }
  return ''
}

# One Up next row: its number, the name, how far its download is (a thin bar under it when that has a percentage), and
# the row's buttons.
function Show-PanelQueueRow($lb, $e) {
  $q = $script:Panel
  $i = $e.Index
  if ($i -lt 0 -or $i -ge $lb.Items.Count) { return }
  $g = $e.Graphics
  $b = $e.Bounds
  $c = $q.Colors
  $k = $q.K
  $sel = (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0)
  $bg = $c.Box
  if ($sel) { $bg = $c.Sel } elseif ($q.QHot -eq $i) { $bg = $c.Hot }
  $q.Brushes.Row.Color = $bg
  $g.FillRectangle($q.Brushes.Row, $b)
  $TF = [System.Windows.Forms.TextFormatFlags]
  $flags = $TF::NoPrefix -bor $TF::SingleLine -bor $TF::VerticalCenter -bor $TF::EndEllipsis
  $pad = [int](6 * $k)
  $name = [string]$lb.Items[$i]
  $info = ''
  if ($i -lt $q.ListNames.Count) { $name = [string]$q.ListNames[$i] }
  if ($i -lt $q.ListInfo.Count) { $info = [string]$q.ListInfo[$i] }
  $numW = $q.NumW
  $x = $b.X + $pad
  [System.Windows.Forms.TextRenderer]::DrawText($g, [string]($i + 1), $q.Font, (New-Object System.Drawing.Rectangle($x, $b.Y, $numW, $b.Height)), $c.Dim, ($flags -bor $TF::Right))
  $x += $numW + $pad
  $right = $b.Right - $pad
  $icons = @(Get-PanelQueueIcons $lb $i)
  if ($icons.Count -gt 0) {
    $right = $icons[0].Rect.X - [int](2 * $k)
    foreach ($ic in $icons) {
      $col = $c.Faint
      if ($ic.On) { $col = $c.Dim; if ($q.QHot -eq $i -and $q.QHotBtn -ceq $ic.Cmd) { $col = $c.Text } }
      [System.Windows.Forms.TextRenderer]::DrawText($g, $ic.Glyph, $q.Sym, $ic.Rect, $col, ($TF::NoPrefix -bor $TF::SingleLine -bor $TF::VerticalCenter -bor $TF::HorizontalCenter))
    }
  }
  $pct = -1
  if ($info -match '(\d{1,3})\s?%') { $pct = [Math]::Min(100, [int]$matches[1]) }
  if ($info -and $right - $x -gt 60) {
    $iw = [Math]::Min([int](($right - $x) * 0.45), [System.Windows.Forms.TextRenderer]::MeasureText($info, $q.Font).Width + 4)
    [System.Windows.Forms.TextRenderer]::DrawText($g, $info, $q.Font, (New-Object System.Drawing.Rectangle(($right - $iw), $b.Y, $iw, $b.Height)), $c.Dim, ($flags -bor $TF::Right))
    $right -= $iw + $pad
  }
  if ($right -gt $x) { [System.Windows.Forms.TextRenderer]::DrawText($g, $name, $q.Font, (New-Object System.Drawing.Rectangle($x, $b.Y, ($right - $x), $b.Height)), $c.Text, $flags) }
  if ($pct -ge 0) {
    $h = [Math]::Max(2, [int](3 * $k))
    $y = $b.Bottom - $h - [int](2 * $k)
    $w = [Math]::Max(1, $b.Right - $pad - $x)
    if ($icons.Count -gt 0) { $w = [Math]::Max(1, $icons[0].Rect.X - [int](2 * $k) - $x) }
    $g.FillRectangle($q.Brushes.Track, $x, $y, $w, $h)
    $g.FillRectangle($q.Brushes.Fill, $x, $y, [int]($w * $pct / 100.0), $h)
  }
}

# The list row under the mouse point $pt (-1: none, or no point = the mouse left the list).
function Get-PanelRowAt($lb, $pt) {
  if ($null -eq $pt) { return -1 }
  $i = $lb.IndexFromPoint($pt)
  if ($i -lt 0 -or $i -ge $lb.Items.Count) { return -1 }
  return $i
}

# Redraws the rows $old and $new of a list (the one the mouse left and the one it is over now).
function Update-PanelRowsLit($lb, [int]$old, [int]$new) {
  foreach ($j in @($old, $new)) { if ($j -ge 0 -and $j -lt $lb.Items.Count) { $lb.Invalidate($lb.GetItemRectangle($j)) } }
}

# The mouse over Up next: which row and which of its buttons (the row lights up, the button too; its tooltip).
function Update-PanelQueueHot($lb, $pt) {
  $q = $script:Panel
  $i = Get-PanelRowAt $lb $pt
  $cmd = ''
  $old = $q.QHot
  $q.QHot = $i
  if ($i -ge 0) { foreach ($ic in @(Get-PanelQueueIcons $lb $i)) { if ($ic.On -and $ic.Rect.Contains($pt)) { $cmd = $ic.Cmd } } }
  if ($i -eq $old -and $cmd -ceq $q.QHotBtn) { return }
  $q.QHotBtn = $cmd
  Update-PanelRowsLit $lb $old $i
  $q.Tips.SetToolTip($lb, (Get-PanelQueueTip $cmd))
}

# The row button under the point $pt: @{ Cmd; Id } (an enabled one only), or $null.
function Get-PanelQueueHit($lb, $pt) {
  $q = $script:Panel
  $i = Get-PanelRowAt $lb $pt
  $ids = @($q.ListIds)
  if ($i -lt 0 -or $i -ge $ids.Count) { return $null }
  foreach ($ic in @(Get-PanelQueueIcons $lb $i)) { if ($ic.On -and $ic.Rect.Contains($pt)) { return @{ Cmd = $ic.Cmd; Id = [int]$ids[$i] } } }
  return $null
}

# A click on a row's button: that command for that row's item (by its Id) - only when it was pressed on the same
# button of the same item (QPress, from MouseDown): the list may have changed under the mouse meanwhile (a video ended,
# the next one moved up), and the release must never act on another item.
function Invoke-PanelQueueIcon($lb, $pt) {
  $q = $script:Panel
  $press = $q.QPress
  $q.QPress = $null
  $hit = Get-PanelQueueHit $lb $pt
  if ($null -eq $hit -or $null -eq $press -or $hit.Id -ne $press.Id -or $hit.Cmd -cne $press.Cmd) { return }
  Add-PanelCommand $hit.Cmd @{ Id = $hit.Id }
}

# ------------------------------------------------------------------ the window's own looks
# A dark title bar to match the window (DwmSetWindowAttribute through the tool's helper DLL; Windows 10 1809 and
# later. Without the DLL, or on an older Windows, it stays light).
function Set-PanelDarkTitle($f) {
  if (-not ('VRCLinkMaker.Win' -as [type])) { return }
  try { [void][VRCLinkMaker.Win]::DarkTitle($f.Handle) } catch {}
}

# The window's icon, drawn here (no image files): a blue rounded square with a white "play" triangle, at 16 and 32
# pixels, made into an .ico in memory (the Icon owns its handle, so Dispose frees it).
function New-PanelIcon {
  $imgs = @(16, 32 | ForEach-Object { , (Get-PanelIconImage $_) })
  $ms = New-Object System.IO.MemoryStream
  try {
    $w = New-Object System.IO.BinaryWriter($ms)
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$imgs.Count)
    $off = 6 + 16 * $imgs.Count
    for ($i = 0; $i -lt $imgs.Count; $i++) {
      $n = @(16, 32)[$i]
      $w.Write([byte]$n); $w.Write([byte]$n); $w.Write([byte]0); $w.Write([byte]0)
      $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$imgs[$i].Length); $w.Write([uint32]$off)
      $off += $imgs[$i].Length
    }
    foreach ($b in $imgs) { $w.Write([byte[]]$b) }
    $w.Flush()
    $ms.Position = 0
    return (New-Object System.Drawing.Icon($ms))
  } finally { $ms.Dispose() }
}

# One image of the icon as an .ico entry: a 32-bit bitmap (bottom-up rows, height doubled) plus an empty mask.
function Get-PanelIconImage([int]$n) {
  $bmp = New-Object System.Drawing.Bitmap($n, $n, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $px = New-Object byte[] ($n * $n * 4)
  try {
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
      $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
      $g.Clear([System.Drawing.Color]::Transparent)
      $d = [single][Math]::Round($n * 0.44)
      $e = [single]($n - 1 - $d)
      $z = [single]0
      $path = New-Object System.Drawing.Drawing2D.GraphicsPath
      $path.AddArc($z, $z, $d, $d, [single]180, [single]90)
      $path.AddArc($e, $z, $d, $d, [single]270, [single]90)
      $path.AddArc($e, $e, $d, $d, $z, [single]90)
      $path.AddArc($z, $e, $d, $d, [single]90, [single]90)
      $path.CloseFigure()
      $bg = New-Object System.Drawing.SolidBrush((New-PanelColor 47 128 237))
      $g.FillPath($bg, $path)
      $bg.Dispose(); $path.Dispose()
      $tri = [System.Drawing.PointF[]]@((New-Object System.Drawing.PointF([single]($n * 0.37), [single]($n * 0.26))), (New-Object System.Drawing.PointF([single]($n * 0.37), [single]($n * 0.74))), (New-Object System.Drawing.PointF([single]($n * 0.76), [single]($n * 0.5))))
      $g.FillPolygon([System.Drawing.Brushes]::White, $tri)
    } finally { $g.Dispose() }
    $rect = New-Object System.Drawing.Rectangle(0, 0, $n, $n)
    $bd = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
      for ($y = 0; $y -lt $n; $y++) { [System.Runtime.InteropServices.Marshal]::Copy([IntPtr]($bd.Scan0.ToInt64() + $y * $bd.Stride), $px, $y * $n * 4, $n * 4) }
    } finally { $bmp.UnlockBits($bd) }
  } finally { $bmp.Dispose() }
  $mask = [int][Math]::Floor(($n + 31) / 32) * 4
  $ms = New-Object System.IO.MemoryStream
  try {
    $w = New-Object System.IO.BinaryWriter($ms)
    $w.Write([uint32]40); $w.Write([int32]$n); $w.Write([int32](2 * $n)); $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]0); $w.Write([uint32]($n * $n * 4)); $w.Write([int32]0); $w.Write([int32]0); $w.Write([uint32]0); $w.Write([uint32]0)
    for ($y = $n - 1; $y -ge 0; $y--) { $w.Write($px, $y * $n * 4, $n * 4) }
    $w.Write((New-Object byte[] ($mask * $n)))
    $w.Flush()
    return $ms.ToArray()
  } finally { $ms.Dispose() }
}

# The warnings banner: the latest yellow / red message line, for about 15 s.
function Show-PanelBanner([string]$text, [string]$color) {
  $q = $script:Panel
  $line = ''
  foreach ($l in ($text -split "`r?`n")) { if ($l.Trim()) { $line = $l.Trim(); break } }
  if (-not $line) { return }
  $bn = $q.Banner
  if ($color -like '*Red') { $bn.BackColor = (New-PanelColor 84 34 34); $bn.ForeColor = (New-PanelColor 250 150 150) }
  else { $bn.BackColor = (New-PanelColor 74 62 22); $bn.ForeColor = (New-PanelColor 240 214 120) }
  $bn.Text = $line
  $q.Tips.SetToolTip($bn, $text.Trim() + "`r`n" + (T 'Click to hide.'))
  $q.BannerUntil = [DateTime]::UtcNow.AddSeconds(15)
  if (-not $bn.Visible) { $bn.Visible = $true }
}

function Hide-PanelBanner {
  $q = $script:Panel
  $q.BannerUntil = [DateTime]::MinValue
  if ($q.Banner.Visible) { $q.Banner.Visible = $false }
}

function Update-PanelBanner {
  $q = $script:Panel
  if ($q.Banner.Visible -and [DateTime]::UtcNow -ge $q.BannerUntil) { Hide-PanelBanner }
}

# Where the window is (for the next window of this run, e.g. after a language change).
function Save-PanelBounds {
  $q = $script:Panel
  $f = $q.Form
  $b = $f.Bounds
  if ($f.WindowState -ne [System.Windows.Forms.FormWindowState]::Normal) { $b = $f.RestoreBounds }
  $script:PanelSync.Bounds = @{ X = $b.X; Y = $b.Y; W = $b.Width; H = $b.Height; Top = [bool]$f.TopMost }
}

# ------------------------------------------------------------------ questions (the card on the right side)
# The main thread's open question is bus.Ask (Publish-UiAsk in the main script): Id, Kind (choice | yesno | text |
# episodes; 'line' = the start screen's '>', answered by the input box, no card), Title, Options, Default, Prev, Crumb,
# BackMode, CanBack, CanHome, CanForward, EscLabel, Secret, Prefill, All, Deadline. The console asks the same question at
# the same time: the first answer wins and the other side closes (the card goes when bus.Ask goes or changes).
# The card is a page of the right side with its own tab, [Question]: it opens by itself, the tab shown before comes back
# after it, and Up next / Messages can be looked at meanwhile (the card's keys wait until it shows again).
# An answer goes into bus.Answers: @{ Id; Nav = '' | 'back' | 'forward' | 'home'; Text; Pick (choice: the option's
# index, -1 = "0) None"); Yes (yes / no, said explicitly); Files; Prefilled }.
# Keys while the card shows: Enter = OK, Esc = what Esc means for this question, Alt+Left = Back, Alt+Right =
# Forward, digits 1-9 pick an option; Space and the arrows belong to the card (Test-PanelKeyOurs).

function Get-PanelBus { try { return $script:PanelSync.Bus } catch { return $null } }

function Get-PanelAsk {
  $b = Get-PanelBus
  if ($null -eq $b) { return $null }
  $a = $b.Ask
  if (-not ($a -is [System.Collections.IDictionary] -and [string]$a['Id'])) { $a = $null }
  # The search started in this window while a video plays (Start-AddWorker) asks on a bus of its own: its card shows
  # when the main thread asks nothing (the start screen's '>' waits behind it).
  if ($null -eq $a -or [string]$a['Kind'] -eq 'line') {
    $wb = $b['WBus']
    if ($null -ne $wb) {
      $w = $wb.Ask
      if ($w -is [System.Collections.IDictionary] -and [string]$w['Id']) { return $w }
    }
  }
  return $a
}

# Is a question open that the card shows (not the start screen's '>')?
function Test-PanelAskOpen {
  $a = Get-PanelAsk
  return ($null -ne $a -and [string]$a['Kind'] -ne 'line')
}

# Is the main thread asking (not the start screen's '>')? Its questions hold it: Up next's buttons and menu wait for them
# (what they ask for would only run after). The search's questions (Start-AddWorker) don't hold it.
function Test-PanelMainAsk {
  $b = Get-PanelBus
  if ($null -eq $b) { return $false }
  $a = $b.Ask
  return ($a -is [System.Collections.IDictionary] -and [string]$a['Id'] -and [string]$a['Kind'] -ne 'line')
}

function Test-PanelActive {
  try { return ([System.Windows.Forms.Form]::ActiveForm -eq $script:Panel.Form) } catch { return $false }
}

# One answer per question (a double click sends one): the card is locked until the question goes (or, if the main
# thread didn't take it, for 2 s: Update-PanelAsk). The card answers the question it shows ($q.AskId) and nothing
# once that one has gone (a click on a card a tick late never answers the next question, unseen); -Line answers the
# start screen's '>' (the input box).
function Send-PanelAnswer([hashtable]$ans, [switch]$Line) {
  $q = $script:Panel
  $b = Get-PanelBus
  $a = Get-PanelAsk
  if ($null -eq $b -or $null -eq $a) { return $false }
  $id = [string]$a['Id']
  if ($Line) { if ([string]$a['Kind'] -ne 'line') { return $false } }
  elseif (-not $q.AskId -or $q.AskId -cne $id) { return $false }
  if ($q.AskSent -ceq $id) { return $false }
  $ans['Id'] = $id
  if (-not $ans.ContainsKey('Nav')) { $ans['Nav'] = '' }
  $q.AskSent = $id
  $q.AskSentAt = [DateTime]::UtcNow
  if ($q.AskId -ceq $id) {
    # (The focus first leaves the card for the read-only link box: disabling a focused control hands the focus on.)
    if ($q.Ask.ContainsFocus) { $q.Form.ActiveControl = $q.LinkBox }
    $q.Ask.Enabled = $false
  }
  # (To the thread that asked: the main one, or the search's.)
  $to = $b
  $wb = $b['WBus']
  if ($null -ne $wb -and $wb.Ask -is [System.Collections.IDictionary] -and [string]$wb.Ask['Id'] -ceq $id) { $to = $wb }
  $to.Answers.Enqueue($ans)
  return $true
}

function Send-PanelAskNav([string]$nav) { [void](Send-PanelAnswer @{ Nav = $nav }) }

# Enter / [OK]: the selected option, the default (highlighted) one, or the text in the box.
function Submit-PanelAskOk {
  $q = $script:Panel
  $a = $q.AskView
  if ($null -eq $a) { return }
  switch ([string]$a['Kind']) {
    'choice' {
      $pick = [int]$a['Default']
      if ($q.AskList -and $q.AskList.SelectedIndex -ge 0) { $pick = [int]@($q.AskPicks)[$q.AskList.SelectedIndex] }
      [void](Send-PanelAnswer @{ Pick = $pick })
    }
    'yesno' { [void](Send-PanelAnswer @{ Yes = [bool]$a['Default'] }) }
    default { if ($q.AskText) { [void](Send-PanelAnswer @{ Text = [string]$q.AskText.Text; Prefilled = $true }) } }
  }
}

# A button of the card: $wide = an option (a whole line, its text on the left), else sized by its text (Back, OK...).
function New-PanelAskButton([string]$text, [bool]$wide) {
  $q = $script:Panel
  $k = $q.K
  $b = New-PanelButton $text '' '' $null $null
  if ($wide) {
    $b.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $b.Height = [int]($q.Font.Height * 1.9)
    $b.Padding = New-Object System.Windows.Forms.Padding([int](6 * $k), 0, [int](6 * $k), 0)
  } else { Set-PanelAutoButton $b }
  return $b
}

function Set-PanelAskDefault($b) {
  $q = $script:Panel
  $b.BackColor = $q.Colors.Pick
  $b.FlatAppearance.BorderColor = $q.Colors.Accent
}

# The question card (hidden while no question is open): the question and what Esc does / the countdown, the steps so
# far, what was said just before it (an explanation, a warning: the card covers the Messages tab), then the answer
# (option buttons, a list, Yes / No, or a box; it scrolls if the window is too low for it), and at the bottom Back /
# Forward / Cancel / OK.
function New-PanelAskStrip {
  $p = $script:Panel
  $c = $p.Colors
  $k = $p.K
  $WF = 'System.Windows.Forms'
  $t = New-Object "$WF.TableLayoutPanel"
  $t.ColumnCount = 2
  $t.RowCount = 5
  $t.Dock = [System.Windows.Forms.DockStyle]::Fill
  $t.Margin = New-Object System.Windows.Forms.Padding(0)
  $t.Padding = New-Object System.Windows.Forms.Padding([int](10 * $k), [int](8 * $k), [int](10 * $k), [int](8 * $k))
  $t.BackColor = $c.Card
  [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
  for ($i = 0; $i -lt 3; $i++) { [void]$t.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) }
  [void]$t.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  [void]$t.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
  $p.AskTitle = New-Object "$WF.Label"
  $p.AskTitle.AutoSize = $true
  $p.AskTitle.Font = $p.Bold
  $p.AskTitle.UseMnemonic = $false
  $p.AskTitle.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, [int](2 * $k))
  $p.AskInfo = New-Object "$WF.Label"
  $p.AskInfo.AutoSize = $true
  $p.AskInfo.UseMnemonic = $false
  $p.AskInfo.ForeColor = $c.Warn
  $p.AskInfo.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
  $p.AskInfo.Margin = New-Object System.Windows.Forms.Padding([int](8 * $k), [int](2 * $k), 0, 0)
  $p.AskCrumb = New-Object "$WF.Label"
  $p.AskCrumb.AutoSize = $true
  $p.AskCrumb.UseMnemonic = $false
  $p.AskCrumb.ForeColor = $c.Dim
  $p.AskCrumb.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, [int](4 * $k))
  # (What was said just before it: up to 3 lines, each in its console colour and one line high - a longer one ends in
  # "...", its whole text is the tooltip - so the answer below always keeps its room.)
  $p.AskCtx = New-Object "$WF.TableLayoutPanel"
  $p.AskCtx.ColumnCount = 1
  $p.AskCtx.AutoSize = $true
  $p.AskCtx.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
  $p.AskCtx.Dock = [System.Windows.Forms.DockStyle]::Fill
  $p.AskCtx.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, [int](6 * $k))
  $p.AskCtx.Padding = New-Object System.Windows.Forms.Padding(0)
  [void]$p.AskCtx.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  $lines = @()
  for ($i = 0; $i -lt 3; $i++) {
    [void]$p.AskCtx.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $l = New-PanelLabel '' ($p.Font.Height + [int](3 * $k)) $null $c.Dim
    $l.UseMnemonic = $false
    $l.Margin = New-Object System.Windows.Forms.Padding(0)
    $l.Visible = $false
    $p.AskCtx.Controls.Add($l, 0, $i)
    $lines += $l
  }
  $p.AskCtxLines = $lines
  $p.AskCtx.Visible = $false
  # (The answer: buttons / a box at the top of a scrolling area, or a list filling it: Set-PanelAskBody.)
  $p.AskScroll = New-Object "$WF.Panel"
  $p.AskScroll.Dock = [System.Windows.Forms.DockStyle]::Fill
  $p.AskScroll.Margin = New-Object System.Windows.Forms.Padding(0, [int](2 * $k), 0, 0)
  $p.AskScroll.Padding = New-Object System.Windows.Forms.Padding(0)
  $p.AskScroll.AutoScroll = $true
  $p.AskBody = New-Object "$WF.TableLayoutPanel"
  $p.AskBody.ColumnCount = 1
  $p.AskBody.Margin = New-Object System.Windows.Forms.Padding(0)
  [void]$p.AskBody.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  $p.AskScroll.Controls.Add($p.AskBody)
  Set-PanelAskBody $false
  $p.AskBar = New-Object "$WF.FlowLayoutPanel"
  $p.AskBar.AutoSize = $true
  $p.AskBar.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
  $p.AskBar.Dock = [System.Windows.Forms.DockStyle]::Fill
  # (One row: Back, Forward, Cancel, OK fit the window's narrowest width. A wrapping bar reports the height of its
  # buttons stacked, an empty band under them.)
  $p.AskBar.WrapContents = $false
  $p.AskBar.Margin = New-Object System.Windows.Forms.Padding(0, [int](8 * $k), 0, 0)
  $t.Controls.Add($p.AskTitle, 0, 0)
  $t.Controls.Add($p.AskInfo, 1, 0)
  $t.Controls.Add($p.AskCrumb, 0, 1)
  $t.SetColumnSpan($p.AskCrumb, 2)
  $t.Controls.Add($p.AskCtx, 0, 2)
  $t.SetColumnSpan($p.AskCtx, 2)
  $t.Controls.Add($p.AskScroll, 0, 3)
  $t.SetColumnSpan($p.AskScroll, 2)
  $t.Controls.Add($p.AskBar, 0, 4)
  $t.SetColumnSpan($p.AskBar, 2)
  $t.Visible = $false
  # (Clicked or tabbed into: the user is at the card, a parked focus is over.)
  $t.Add_Enter({ try { $script:Panel.AskFocusPending = $false } catch {} })
  $p.Ask = $t
  return $t
}

# The answer area: $list = one list filling it (search results and other long choices), else buttons / a box at its top
# (the area scrolls when they don't fit).
function Set-PanelAskBody([bool]$list) {
  $q = $script:Panel
  $body = $q.AskBody
  $body.RowStyles.Clear()
  if ($list) {
    $q.AskScroll.AutoScroll = $false
    $body.AutoSize = $false
    $body.Dock = [System.Windows.Forms.DockStyle]::Fill
    [void]$body.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $body.RowCount = 1
  } else {
    $body.Dock = [System.Windows.Forms.DockStyle]::Top
    $body.AutoSize = $true
    $body.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $body.RowCount = 0
    $q.AskScroll.AutoScroll = $true
  }
}

# Long titles and paths wrap inside the card (labels grow downwards up to the card's width).
function Set-PanelAskWidths {
  $q = $script:Panel
  if ($null -eq $q -or $null -eq $q.Ask -or $null -eq $q.Pages) { return }
  $w = $q.Pages.ClientSize.Width - $q.Ask.Padding.Horizontal - 4
  if ($w -lt 100) { return }
  $iw = 0
  if ($q.AskInfo.Text) { $iw = $q.AskInfo.PreferredSize.Width + $q.AskInfo.Margin.Horizontal }
  $q.AskTitle.MaximumSize = New-Object System.Drawing.Size([Math]::Max(80, $w - $iw), 0)
  $q.AskCrumb.MaximumSize = New-Object System.Drawing.Size($w, 0)
}

function Clear-PanelAskControls {
  $q = $script:Panel
  $old = @($q.AskBody.Controls) + @($q.AskBar.Controls)
  $q.AskBody.Controls.Clear()
  $q.AskBar.Controls.Clear()
  Set-PanelAskBody $false
  foreach ($x in $old) { try { $x.Dispose() } catch {} }
  $q.AskList = $null
  $q.AskPicks = @()
  $q.AskRows = @()
  $q.AskHot = -1
  $q.AskText = $null
  $q.AskFocus = $null
}

# What the card says right of its title: the countdown (a question that takes its suggested answer by itself), else
# what Esc does.
function Get-PanelAskInfo($a) {
  if ($null -eq $a) { return '' }
  $dl = $a['Deadline']
  if ($dl -is [DateTime]) {
    $left = [Math]::Max(0, [int][Math]::Ceiling(($dl - [DateTime]::UtcNow).TotalSeconds))
    if ([string]$a['TimeoutLabel']) { return (T 'Answering "{0}" in {1} s' ([string]$a['TimeoutLabel']) $left) }
    return (T 'Using the default in {0} s' $left)
  }
  switch ([string]$a['BackMode']) {
    'back' { return (T '  (Esc = back)').Trim() }
    'leave' { return (T '  (Esc = cancel)').Trim() }
    'esc' { if ([string]$a['EscLabel']) { return (T '(Esc = {0})' ([string]$a['EscLabel'])) } }
  }
  return ''
}

# Draws the question $a in the card and shows the card (once per question Id).
function Show-PanelAsk($a) {
  $q = $script:Panel
  $k = $q.K
  $WF = 'System.Windows.Forms'
  # (The main thread's question over the search's, or back, while the replaced one - not answered here - had the focus:
  # the keys being pressed were meant for that one. This one waits for a click or Tab, as one that comes while the
  # user types in the input box.)
  $prevId = [string]$q.AskId
  $newId = [string]$a['Id']
  $cut = ($prevId -and $newId -and $q.Ask.ContainsFocus -and $q.AskSent -cne $prevId -and $prevId.Substring(0, 1) -cne $newId.Substring(0, 1))
  $q.AskView = $a
  $q.AskId = [string]$a['Id']
  $q.AskSent = ''
  $q.AskDigits = ''
  $focus = $null
  $q.Ask.SuspendLayout()
  try {
    Clear-PanelAskControls
    $q.Ask.Enabled = $true
    $title = [string]$a['Title']
    $q.AskTitle.Text = $title
    $q.Tips.SetToolTip($q.AskTitle, $title)
    $crumb = [string]$a['Crumb']
    $q.AskCrumb.Text = $crumb
    $q.AskCrumb.Visible = [bool]$crumb
    $q.AskInfoText = Get-PanelAskInfo $a
    $q.AskInfo.Text = $q.AskInfoText
    # What was said just before it: its last 3 lines, each in the colour the console gives it (a yellow warning
    # stays yellow, a grey note grey).
    $ctx = New-Object 'System.Collections.Generic.List[object]'
    foreach ($ce in @($a['Context'])) {
      if ($null -eq $ce -or @($ce).Count -lt 2) { continue }
      foreach ($ln in (([string]$ce[0]) -split "`r?`n")) { if ($ln.Trim()) { $ctx.Add(@($ln.Trim(), [string]$ce[1])) } }
    }
    while ($ctx.Count -gt 3) { $ctx.RemoveAt(0) }
    for ($i = 0; $i -lt @($q.AskCtxLines).Count; $i++) {
      $l = $q.AskCtxLines[$i]
      if ($i -lt $ctx.Count) {
        $l.Text = [string]$ctx[$i][0]
        $col = $q.Colors.Text
        if ($ctx[$i][1] -and $q.LogPal.ContainsKey([string]$ctx[$i][1])) { $col = $q.LogPal[[string]$ctx[$i][1]] }
        $l.ForeColor = $col
        $q.Tips.SetToolTip($l, [string]$ctx[$i][0])
        $l.Visible = $true
      } else { $l.Text = ''; $l.Visible = $false }
    }
    $q.AskCtx.Visible = ($ctx.Count -gt 0)
    # (Search results end in their source, [WPARTY]: drawn as a tag. Only there: other texts may end in brackets.)
    $q.AskTags = ([string]$a['Key'] -ceq 'search')
    $ok = $false
    switch ([string]$a['Kind']) {
      'choice' {
        $opts = @($a['Options'])
        $rows = @()
        if ([bool]$a['AllowNone']) { $rows += @{ Pick = -1; Num = '0'; Opt = [string]$a['NoneLabel']; Text = '0) ' + [string]$a['NoneLabel']; Mine = $false } }
        for ($i = 0; $i -lt $opts.Count; $i++) { $rows += @{ Pick = $i; Num = [string]($i + 1); Opt = [string]$opts[$i]; Text = ('{0}) {1}' -f ($i + 1), [string]$opts[$i]); Mine = $false } }
        $prev = $a['Prev']
        foreach ($r in $rows) { if ($null -ne $prev -and [int]$prev -eq [int]$r.Pick) { $r.Text += (T '   <- your answer'); $r.Mine = $true } }
        $def = [int]$a['Default']
        if ($rows.Count -le 6) {
          foreach ($r in $rows) {
            $b = New-PanelAskButton $r.Text $true
            $b.Tag = [int]$r.Pick
            $q.Tips.SetToolTip($b, $r.Text)
            $b.Add_Click({ try { [void](Send-PanelAnswer @{ Pick = [int]$this.Tag }) } catch { Write-PanelWarning $_ } })
            if ([int]$r.Pick -eq $def) { Set-PanelAskDefault $b; $focus = $b }
            $q.AskBody.Controls.Add($b)
          }
          if (-not $focus -and $q.AskBody.Controls.Count -gt 0) { $focus = $q.AskBody.Controls[0] }
        } else {
          # A list filling the card (search results and other long choices): a row each (Show-PanelAskRow), a double
          # click or Enter / OK answers.
          Set-PanelAskBody $true
          $lb = New-Object "$WF.ListBox"
          $lb.IntegralHeight = $false
          $lb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
          $lb.BackColor = $q.Colors.Box
          $lb.ForeColor = $q.Colors.Text
          $lb.Dock = [System.Windows.Forms.DockStyle]::Fill
          $lb.Margin = New-Object System.Windows.Forms.Padding(0)
          $lb.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
          $lb.ItemHeight = $q.Font.Height + [int](10 * $k)
          $q.AskRows = @($rows)
          foreach ($r in $rows) { [void]$lb.Items.Add($r.Text) }
          $q.AskPicks = @($rows | ForEach-Object { [int]$_.Pick })
          $ix = [array]::IndexOf([int[]]$q.AskPicks, $def)
          if ($ix -ge 0) { $lb.SelectedIndex = $ix }
          $lb.Add_DrawItem({ param($sender, $e) try { Show-PanelAskRow $sender $e } catch {} })
          $lb.Add_MouseMove({ param($sender, $e) try { Update-PanelAskHot $sender $e.Location } catch {} })
          $lb.Add_MouseLeave({ param($sender, $e) try { Update-PanelAskHot $sender $null } catch {} })
          $lb.Add_DoubleClick({ try { if ($this.SelectedIndex -ge 0) { Submit-PanelAskOk } } catch { Write-PanelWarning $_ } })
          $q.AskList = $lb
          $q.AskBody.Controls.Add($lb)
          $focus = $lb
          $ok = $true
        }
      }
      'yesno' {
        $fl = New-Object "$WF.FlowLayoutPanel"
        $fl.AutoSize = $true
        $fl.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
        $fl.WrapContents = $false
        $fl.Margin = New-Object System.Windows.Forms.Padding(0)
        foreach ($yes in @($true, $false)) {
          $txt = T 'No'
          if ($yes) { $txt = T 'Yes' }
          if ($null -ne $a['Prev'] -and [bool]$a['Prev'] -eq $yes) { $txt += (T '   <- your answer') }
          $b = New-PanelAskButton $txt $false
          $b.Tag = $yes
          $b.Add_Click({ try { [void](Send-PanelAnswer @{ Yes = [bool]$this.Tag }) } catch { Write-PanelWarning $_ } })
          if ([bool]$a['Default'] -eq $yes) { Set-PanelAskDefault $b; $focus = $b }
          $fl.Controls.Add($b)
        }
        $q.AskBody.Controls.Add($fl)
      }
      'busy' {
        # (The search's card while it looks something up, before and between its questions: the title and Cancel.)
      }
      default {
        # text / episodes: a box (a secret one shows dots), episodes with [All]
        $g = New-PanelGrid 2 ([int]($q.Font.Height * 2.1))
        $g.Dock = [System.Windows.Forms.DockStyle]::Fill
        [void]$g.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
        $tb = New-Object "$WF.TextBox"
        $tb.BackColor = $q.Colors.Box
        $tb.ForeColor = $q.Colors.Text
        $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $tb.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $tb.Margin = New-Object System.Windows.Forms.Padding(0, 1, 2, 1)
        if ([bool]$a['Secret']) { $tb.UseSystemPasswordChar = $true }
        else { $tb.Text = [string]$a['Prefill'] }
        $g.Controls.Add($tb, 0, 0)
        if ([string]$a['Kind'] -eq 'episodes' -and [string]$a['All']) {
          $all = New-PanelAskButton (T 'All') $false
          $q.Tips.SetToolTip($all, [string]$a['All'])
          $all.Add_Click({ try { $q2 = $script:Panel; [void](Send-PanelAnswer @{ Text = [string]$q2.AskView['All']; Prefilled = $true }) } catch { Write-PanelWarning $_ } })
          [void]$g.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
          $g.ColumnCount = 2
          $g.Controls.Add($all, 1, 0)
        } else { $g.ColumnCount = 1 }
        $q.AskText = $tb
        $q.AskBody.Controls.Add($g)
        $focus = $tb
        $ok = $true
      }
    }
    # Back / Forward / Cancel, then OK where the answer isn't a button.
    $bm = [string]$a['BackMode']
    if ($bm -eq 'back') {
      $b = New-PanelAskButton (T '< Back') $false
      $q.Tips.SetToolTip($b, (T 'Back to the question before (Esc, Alt+Left)'))
      $b.Add_Click({ try { Send-PanelAskNav 'back' } catch { Write-PanelWarning $_ } })
      $q.AskBar.Controls.Add($b)
    }
    if ([bool]$a['CanForward']) {
      $b = New-PanelAskButton (T 'Forward >') $false
      $q.Tips.SetToolTip($b, (T 'Your earlier answer again (Alt+Right)'))
      $b.Add_Click({ try { Send-PanelAskNav 'forward' } catch { Write-PanelWarning $_ } })
      $q.AskBar.Controls.Add($b)
    }
    if ([bool]$a['CanHome'] -or $bm -eq 'leave') {
      $b = New-PanelAskButton (T 'Cancel') $false
      $q.Tips.SetToolTip($b, (T 'Leave these questions; nothing is added or changed'))
      $nav = 'home'
      if (-not [bool]$a['CanHome']) { $nav = 'back' }
      # (The search's card isn't a question: its Cancel stops the search, Stop-PanelSearch.)
      if ([string]$a['Kind'] -eq 'busy') { $nav = 'stop'; $q.Tips.SetToolTip($b, (T 'Stop the search; nothing is added')) }
      $b.Tag = $nav
      $b.Add_Click({ try { if ([string]$this.Tag -eq 'stop') { Stop-PanelSearch } else { Send-PanelAskNav ([string]$this.Tag) } } catch { Write-PanelWarning $_ } })
      $q.AskBar.Controls.Add($b)
    }
    if ($ok) {
      $b = New-PanelAskButton (T 'OK') $false
      Set-PanelAskDefault $b
      $b.Add_Click({ try { Submit-PanelAskOk } catch { Write-PanelWarning $_ } })
      $q.AskBar.Controls.Add($b)
    }
    $q.AskBar.Visible = ($q.AskBar.Controls.Count -gt 0)
  } finally { $q.Ask.ResumeLayout($true) }
  $q.AskFocus = $focus
  Set-PanelAskWidths
  # (The card takes the right side; the tab shown before comes back when the question ends: Hide-PanelAsk.)
  if ($q.Page -ne 'ask') { $q.PageBack = $q.Page }
  Select-PanelPage 'ask'
  Update-PanelLayout
  # Its answer box gets the focus inside this window only: never taking it from another program (VRChat), nor from the
  # input box while the user types there (an Enter / Space / digit meant for the line would answer it unseen). The
  # card then waits for a click or Tab (its keys too: Invoke-PanelAskKey), and the input box gets the focus back
  # when the question ends (InputParked, see Update-PanelView).
  $fc = $null
  try { $fc = Get-PanelFocus } catch {}
  # (The search's card isn't a question: no flash, no sound. Its title was just sent with Enter, so its first question
  # takes the focus as usual.)
  if ([string]$a['Kind'] -eq 'busy') {
    if ($fc -and $q.InputRow.Contains($fc)) { $q.Form.ActiveControl = $q.LinkBox; $q.InputParked = $true }
    $q.AskFocusPending = $false
    # (A flash for the question it replaces - one that ended in the console or by its time limit - stops.)
    if ($q.AskFlashing) {
      $q.AskFlashing = $false
      try { [void][VRCLinkMaker.Win]::StopFlash($q.Form.Handle) } catch {}
    }
    return
  }
  if ($fc -and $q.InputRow.Contains($fc)) { $q.Form.ActiveControl = $q.LinkBox; $q.InputParked = $true; $q.AskFocusPending = $true }
  if ($cut) { $q.Form.ActiveControl = $q.LinkBox; $q.AskFocusPending = $true }
  if (-not (Test-PanelActive)) { $q.AskFocusPending = $true; Invoke-PanelAttention }
  elseif (-not $q.AskFocusPending) { Move-PanelAskFocus }
}

# Cancel / Esc on the search's card: the main thread stops the search (Stop-AddWorkerSearch) and the card goes.
function Stop-PanelSearch {
  $q = $script:Panel
  if (-not $q.AskId -or $null -eq $q.AskView -or [string]$q.AskView['Kind'] -ne 'busy') { return }
  if ($q.Ask.ContainsFocus) { $q.Form.ActiveControl = $q.LinkBox }
  $q.Ask.Enabled = $false
  Add-PanelCommand 'wcancel' $q.AskId
}

function Move-PanelAskFocus {
  $q = $script:Panel
  $c = $q.AskFocus
  if ($null -eq $c -or $c.IsDisposed -or -not $q.AskId -or -not $q.Ask.Visible) { return }
  $q.Form.ActiveControl = $c
  if ($c -is [System.Windows.Forms.TextBox]) { $c.SelectionStart = $c.TextLength }
}

# A question while the window isn't in front: its taskbar button flashes until it is (FlashWindowEx through the
# tool's helper DLL) and one short sound plays. Not while the console window is in front (the question shows there).
function Invoke-PanelAttention {
  $q = $script:Panel
  $win = [bool]('VRCLinkMaker.Win' -as [type])
  try { if ($win -and [VRCLinkMaker.Win]::ConsoleInFront()) { return } } catch {}
  # (Flash returns the caption's state before the call, not whether it flashes: a flash started here is one to stop.)
  if ($win) { try { [void][VRCLinkMaker.Win]::Flash($q.Form.Handle); $q.AskFlashing = $true } catch {} }
  try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
}

function Hide-PanelAsk {
  $q = $script:Panel
  $q.AskId = ''
  $q.AskView = $null
  $q.AskFocusPending = $false
  if ($q.AskFlashing) {
    $q.AskFlashing = $false
    try { [void][VRCLinkMaker.Win]::StopFlash($q.Form.Handle) } catch {}
  }
  # (The focus leaves for the read-only link box: not for a transport button, where Enter / Space would act.)
  if ($q.Ask.ContainsFocus) { $q.Form.ActiveControl = $q.LinkBox }
  if ($q.Page -eq 'ask') { Select-PanelPage $q.PageBack } else { Update-PanelTabs }
  Update-PanelLayout
  Clear-PanelAskControls
}

# One row of a long choice (search results and the like): its number, the text, and a source named in [brackets] at the
# end as a tag on the right (WPARTY, AniLiberty, Nyaa...). The whole text is the row's tooltip (Update-PanelAskHot).
function Show-PanelAskRow($lb, $e) {
  $q = $script:Panel
  $i = $e.Index
  if ($i -lt 0 -or $i -ge $lb.Items.Count) { return }
  $g = $e.Graphics
  $b = $e.Bounds
  $c = $q.Colors
  $k = $q.K
  $sel = (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0)
  $bg = $c.Box
  $dim = $c.Dim
  if ($sel) { $bg = $c.Pick; $dim = $c.TagText } elseif ($q.AskHot -eq $i) { $bg = $c.Hot }
  $q.Brushes.Row.Color = $bg
  $g.FillRectangle($q.Brushes.Row, $b)
  $TF = [System.Windows.Forms.TextFormatFlags]
  $flags = $TF::NoPrefix -bor $TF::SingleLine -bor $TF::VerticalCenter -bor $TF::EndEllipsis
  $rows = @($q.AskRows)
  $num = ''
  $text = [string]$lb.Items[$i]
  $mine = $false
  if ($i -lt $rows.Count) { $num = [string]$rows[$i].Num; $text = [string]$rows[$i].Opt; $mine = [bool]$rows[$i].Mine }
  $tag = ''
  if ($q.AskTags -and $text -match '^(.*\S)\s*\[([^\[\]]{1,24})\]\s*$') { $text = $matches[1]; $tag = $matches[2] }
  $pad = [int](6 * $k)
  $numW = $q.NumW
  $x = $b.X + $pad
  if ($num) { [System.Windows.Forms.TextRenderer]::DrawText($g, $num, $q.Font, (New-Object System.Drawing.Rectangle($x, $b.Y, $numW, $b.Height)), $dim, ($flags -bor $TF::Right)) }
  $x += $numW + $pad
  $right = $b.Right - $pad
  if ($tag) {
    $tw = [System.Windows.Forms.TextRenderer]::MeasureText($tag, $q.Font).Width + [int](10 * $k)
    $th = $q.Font.Height + [int](2 * $k)
    $tr = New-Object System.Drawing.Rectangle(($right - $tw), ($b.Y + [int](($b.Height - $th) / 2)), $tw, $th)
    $q.Brushes.Row.Color = $c.Tag
    $g.FillRectangle($q.Brushes.Row, $tr)
    [System.Windows.Forms.TextRenderer]::DrawText($g, $tag, $q.Font, $tr, $c.TagText, ($TF::NoPrefix -bor $TF::SingleLine -bor $TF::VerticalCenter -bor $TF::HorizontalCenter))
    $right = $tr.X - $pad
  }
  if ($mine) {
    $mt = (T '   <- your answer').Trim()
    $mw = [System.Windows.Forms.TextRenderer]::MeasureText($mt, $q.Font).Width + 4
    if ($right - $x -gt $mw + 40) {
      [System.Windows.Forms.TextRenderer]::DrawText($g, $mt, $q.Font, (New-Object System.Drawing.Rectangle(($right - $mw), $b.Y, $mw, $b.Height)), $c.Warn, ($flags -bor $TF::Right))
      $right -= $mw + $pad
    }
  }
  if ($right -gt $x) { [System.Windows.Forms.TextRenderer]::DrawText($g, $text, $q.Font, (New-Object System.Drawing.Rectangle($x, $b.Y, ($right - $x), $b.Height)), $c.Text, $flags) }
}

# The mouse over a long choice: the row under it lights up and shows its whole text as the tooltip.
function Update-PanelAskHot($lb, $pt) {
  $q = $script:Panel
  $i = Get-PanelRowAt $lb $pt
  if ($i -eq $q.AskHot) { return }
  Update-PanelRowsLit $lb $q.AskHot $i
  $q.AskHot = $i
  $tip = ''
  if ($i -ge 0) { $tip = [string]$lb.Items[$i] }
  $q.Tips.SetToolTip($lb, $tip)
}

# Every tick: shows a new question, hides one that ended, and counts down.
function Update-PanelAsk {
  $q = $script:Panel
  if ($null -eq $q.Ask) { return }
  $a = Get-PanelAsk
  $id = ''
  if ($a -and [string]$a['Kind'] -ne 'line') { $id = [string]$a['Id'] }
  if ($id -cne $q.AskId) {
    if ($id) { Show-PanelAsk $a } else { Hide-PanelAsk }
  }
  # (An answer the main thread didn't take - it asks again with the same question: the card is free again.)
  if ($q.AskSent -and ([DateTime]::UtcNow - $q.AskSentAt).TotalSeconds -gt 2) {
    $live = ($a -and [string]$a['Id'] -ceq $q.AskSent)
    $q.AskSent = ''
    if ($live -and $q.AskId) { $q.Ask.Enabled = $true }
  }
  if ($q.AskId) {
    $txt = Get-PanelAskInfo $q.AskView
    if ($txt -cne $q.AskInfoText) { $q.AskInfoText = $txt; $q.AskInfo.Text = $txt }
    # (The search's card: what it is doing now - its status line, e.g. a download's progress - under its title.)
    if ([string]$q.AskView['Kind'] -eq 'busy') {
      $now = ''
      try {
        $wb = (Get-PanelBus)['WBus']
        $st = $null
        if ($null -ne $wb) { $st = $wb.Status }
        if ($st -and ([DateTime]::UtcNow - [DateTime]$st['At']).TotalSeconds -lt 5) { $now = [string]$st['Text'] }
      } catch {}
      $l = $q.AskCtxLines[0]
      if ($l.Text -cne $now) {
        $l.Text = $now
        $l.ForeColor = $q.Colors.Dim
        $q.Tips.SetToolTip($l, $now)
        $l.Visible = [bool]$now
        $q.AskCtx.Visible = [bool]$now
      }
    }
  }
}

# The card's keys (see above). $true = the key was the card's.
function Invoke-PanelAskKey([System.Windows.Forms.Keys]$keyData) {
  $q = $script:Panel
  if ($null -eq $q -or -not $q.AskId -or -not $q.Ask.Enabled) { return $false }
  # (Not while another tab is looked at; a question that came while the user typed in the input box: its keys wait
  # until the user is at the card.)
  if (-not $q.Ask.Visible) { return $false }
  if ($q.AskFocusPending -and -not $q.Ask.ContainsFocus) { return $false }
  $a = $q.AskView
  $K = [System.Windows.Forms.Keys]
  $code = $keyData -band $K::KeyCode
  $mods = $keyData -band $K::Modifiers
  $bm = [string]$a['BackMode']
  if ([string]$a['Kind'] -eq 'busy') {
    if ($mods -eq $K::None -and $code -eq $K::Escape) { Stop-PanelSearch; return $true }
    return $false
  }
  if ($mods -eq $K::Alt -and $code -eq $K::Left) { if ($bm -eq 'back' -or $bm -eq 'leave') { Send-PanelAskNav 'back' }; return $true }
  if ($mods -eq $K::Alt -and $code -eq $K::Right) { if ([bool]$a['CanForward']) { Send-PanelAskNav 'forward' }; return $true }
  if ($mods -ne $K::None) { return $false }
  if ($code -eq $K::Escape) { if ($bm -eq 'back' -or $bm -eq 'leave' -or $bm -eq 'esc') { Send-PanelAskNav 'back' }; return $true }
  if ($code -eq $K::Enter) { Submit-PanelAskOk; return $true }
  $fc = $null
  try { $fc = Get-PanelFocus } catch {}
  if ([string]$a['Kind'] -eq 'choice' -and -not ($fc -is [System.Windows.Forms.TextBoxBase])) {
    $d = -1
    if ($code -ge $K::D0 -and $code -le $K::D9) { $d = [int]$code - [int]$K::D0 }
    elseif ($code -ge $K::NumPad0 -and $code -le $K::NumPad9) { $d = [int]$code - [int]$K::NumPad0 }
    if ($d -lt 0) { return $false }
    # (10 options or more: a number of two digits as in the console. A digit that can start a larger number only
    # selects its row; the next digit within a second, or Enter, answers.)
    $num = $d
    if ($q.AskDigits -and ([DateTime]::UtcNow - $q.AskDigitsAt).TotalMilliseconds -lt 1000) { $num = [int]($q.AskDigits + [string]$d) }
    $q.AskDigits = ''
    $n = @($a['Options']).Count
    if ($num -ge 1 -and $num * 10 -le $n) {
      $q.AskDigits = [string]$num
      $q.AskDigitsAt = [DateTime]::UtcNow
      if ($q.AskList) { $ix = [array]::IndexOf([int[]]$q.AskPicks, $num - 1); if ($ix -ge 0) { $q.AskList.SelectedIndex = $ix } }
      return $true
    }
    if ($num -ge 1 -and $num -le $n) { [void](Send-PanelAnswer @{ Pick = ($num - 1) }); return $true }
    if ($num -eq 0) {
      if ([bool]$a['AllowNone']) { [void](Send-PanelAnswer @{ Pick = -1 }) }
      elseif ($bm -eq 'back' -or $bm -eq 'leave') { Send-PanelAskNav 'back' }
    }
    return $true
  }
  return $false
}

# ------------------------------------------------------------------ pieces the update uses
function Remove-PanelImage {
  try {
    $pv = $script:Panel.Preview
    if ($pv -and $pv.Image) { $old = $pv.Image; $pv.Image = $null; $old.Dispose() }
  } catch {}
}

function Reset-PanelStop {
  $q = $script:Panel
  $q.Stop.Text = $q.StopText
  $q.Stop.Font = $q.Sym
  $q.Stop.BackColor = $q.Colors.Button
}

function Get-PanelBarValue($bar, [int]$x) {
  $q = $script:Panel
  $r = [Math]::Max(5, [int]($bar.ClientSize.Height * 0.28))
  $span = $bar.ClientSize.Width - 2 * $r
  if ($span -le 0 -or $q.SeekDur -le 0) { return 0.0 }
  $frac = [Math]::Min(1.0, [Math]::Max(0.0, ($x - $r) / [double]$span))
  return ($frac * $q.SeekDur)
}

function Show-PanelSeekBar($g, $bar) {
  $q = $script:Panel
  $b = $q.Brushes
  $w = $bar.ClientSize.Width
  $h = $bar.ClientSize.Height
  $r = [Math]::Max(5, [int]($h * 0.28))
  $th = [Math]::Max(3, [int]($h * 0.14))
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear($q.Colors.Back)
  $x0 = $r
  $span = [Math]::Max(1, $w - 2 * $r)
  $y = [int]($h / 2)
  if (-not $q.SeekOn) { $g.FillRectangle($b.Off, $x0, $y - [int]($th / 2), $span, $th); return }
  $frac = 0.0
  if ($q.SeekDur -gt 0) { $frac = [Math]::Min(1.0, [Math]::Max(0.0, $q.SeekShown / $q.SeekDur)) }
  $xp = $x0 + [int]($span * $frac)
  $g.FillRectangle($b.Track, $x0, $y - [int]($th / 2), $span, $th)
  $g.FillRectangle($b.Fill, $x0, $y - [int]($th / 2), $xp - $x0, $th)
  $g.FillEllipse($b.Thumb, $xp - $r, $y - $r, 2 * $r, 2 * $r)
}

# Where the bar shows: the dragged spot while dragging; for a moment after a jump, the spot jumped to
# (the stream takes a second to get there); otherwise the real position.
function Update-PanelSeekShown {
  $q = $script:Panel
  $shown = $q.RealPos
  if ($q.Drag) { $shown = $q.DragPos }
  elseif ($q.HoldUntil -ne [DateTime]::MinValue) {
    if ([DateTime]::UtcNow -lt $q.HoldUntil -and [Math]::Abs($q.RealPos - $q.HoldPos) -gt 2) { $shown = $q.HoldPos }
    else { $q.HoldUntil = [DateTime]::MinValue }
  }
  $q.SeekShown = $shown
  $px = -1
  if ($q.SeekOn -and $q.SeekDur -gt 0) { $px = [int]([Math]::Min(1.0, [Math]::Max(0.0, $shown / $q.SeekDur)) * $q.Bar.ClientSize.Width) }
  if ($px -ne $q.SeekPx) { $q.SeekPx = $px; $q.Bar.Invalidate() }
  $txt = Format-Time $shown
  if ($q.PosText -cne $txt) { $q.PosText = $txt; $q.Pos.Text = $txt }
}

# Sets a control's property only when the value changed since the last update (keeps updates cheap).
function Set-PanelProp([string]$key, $ctrl, [string]$prop, $value) {
  $last = $script:PanelLast
  if ($last.ContainsKey($key) -and $last[$key] -ceq $value) { return }
  $last[$key] = $value
  $ctrl.$prop = $value
}

function Set-PanelMode([string]$mode) {
  $q = $script:Panel
  if ($q.Mode -ceq $mode) { return }
  $q.Mode = $mode
  $play = [string][char]0x25B6
  $pause = [string][char]0x23F8
  switch ($mode) {
    'content'   { $q.Big.Text = $pause + ' ' + (T 'Pause');     $q.Big.Enabled = $true;  $badge = T 'Playing';        $bc = (New-PanelColor 40 140 70) }
    'paused'    { $q.Big.Text = $play + ' ' + (T 'Continue');   $q.Big.Enabled = $true;  $badge = T 'Paused';         $bc = (New-PanelColor 190 130 30) }
    'hold'      { $q.Big.Text = $play + ' ' + (T 'Start now');  $q.Big.Enabled = $true;  $badge = T 'Ready to start'; $bc = (New-PanelColor 40 110 190) }
    'waiting'   { $q.Big.Text = $play + ' ' + (T 'Start now');  $q.Big.Enabled = $false; $badge = T 'Waiting';        $bc = (New-PanelColor 90 90 100) }
    'reconnect' { $q.Big.Text = $pause + ' ' + (T 'Pause');     $q.Big.Enabled = $false; $badge = T 'Reconnecting';   $bc = (New-PanelColor 180 70 40) }
    default     { $q.Big.Text = $play + ' ' + (T 'Start now');  $q.Big.Enabled = $false; $badge = T 'Off';            $bc = (New-PanelColor 70 70 78) }
  }
  if ($q.Big.Enabled) { $q.Big.BackColor = (New-PanelColor 40 90 150) } else { $q.Big.BackColor = $q.Colors.Button }
  $q.Badge.Text = $badge
  $q.Badge.BackColor = $bc
  $q.Badge.ForeColor = [System.Drawing.Color]::White
}

# The preview JPEG: reloaded when its time stamp changed, at most every 400 ms, and only when it is a
# whole JPEG (ffmpeg may be in the middle of writing it: then the next try picks it up).
function Update-PanelPreview([DateTime]$now) {
  $q = $script:Panel
  if (($now - $q.PrevCheck).TotalMilliseconds -lt 400) { return }
  $q.PrevCheck = $now
  if ($q.Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { return }
  $path = [string]$script:PreviewFile
  if (-not $path) { return }
  $t = [System.IO.File]::GetLastWriteTimeUtc($path)
  if ($t.Year -le 1601) {
    # No file (yet, or ffmpeg is replacing it): keep the last picture for a few seconds.
    if ($q.Preview.Image) {
      if ($q.PrevMissing -eq [DateTime]::MinValue) { $q.PrevMissing = $now }
      elseif (($now - $q.PrevMissing).TotalSeconds -gt 5) { Remove-PanelImage; $q.PrevTime = [DateTime]::MinValue; $q.Preview.Invalidate() }
    }
    return
  }
  $q.PrevMissing = [DateTime]::MinValue
  if ($t -eq $q.PrevTime) { return }
  $bytes = $null
  $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
  try {
    $len = [int]$fs.Length
    if ($len -lt 4 -or $len -gt 16MB) { return }
    $bytes = New-Object byte[] $len
    $off = 0
    while ($off -lt $len) {
      $n = $fs.Read($bytes, $off, $len - $off)
      if ($n -le 0) { break }
      $off += $n
    }
    if ($off -ne $len) { return }
  } finally { $fs.Dispose() }
  if ($bytes[0] -ne 0xFF -or $bytes[1] -ne 0xD8 -or $bytes[$len - 2] -ne 0xFF -or $bytes[$len - 1] -ne 0xD9) { return }
  $ms = New-Object System.IO.MemoryStream(, $bytes)
  try {
    $img = [System.Drawing.Image]::FromStream($ms, $false, $true)
    try { $bmp = New-Object System.Drawing.Bitmap($img) } finally { $img.Dispose() }
  } finally { $ms.Dispose() }
  $old = $q.Preview.Image
  $q.Preview.Image = $bmp
  if ($old) { $old.Dispose() }
  $q.PrevTime = $t
}

# An internal error closes the window (its thread then ends); the reason goes to the main thread for log.txt.
function Stop-PanelAfterError($err) {
  try {
    $sync = $script:PanelSync
    if ($err -and $sync -and -not $sync.Error) {
      $why = [string]$err
      if ($err -is [System.Management.Automation.ErrorRecord]) { $why = $err.Exception.Message + ' (line ' + $err.InvocationInfo.ScriptLineNumber + ')' }
      elseif ($err -is [System.Exception]) { $why = $err.Message }
      $sync.Error = $why
    }
  } catch {}
  try {
    $q = $script:Panel
    if ($q) { $q.Closed = $true; if ($q.Form -and -not $q.Form.IsDisposed) { $q.Form.Close() } }
  } catch {
    try { [System.Windows.Forms.Application]::ExitThread() } catch {}
  }
}

# ------------------------------------------------------------------ the main loop's calls (main thread)
# What the window's runspace runs: this file again, then the window. T and Format-Time come from the main script.
$script:PanelBoot = @'
param($Sync, $PanelFile, $Tr, $PreviewFile, $TSrc, $TimeSrc)
$ErrorActionPreference = 'Stop'
try {
  Set-Item -Path function:global:T -Value ([scriptblock]::Create($TSrc))
  Set-Item -Path function:global:Format-Time -Value ([scriptblock]::Create($TimeSrc))
  . $PanelFile
  $script:Tr = $Tr
  $script:PreviewFile = $PreviewFile
  Start-PanelUi $Sync
} catch {
  if (-not $Sync.Error) { $Sync.Error = $_.Exception.Message + ' (line ' + $_.InvocationInfo.ScriptLineNumber + ')' }
} finally { $Sync.Closed = $true }
'@

function Open-ControlPanel {
  try {
    if (Test-ControlPanelOpen) { $script:PanelSync.ShowReq = $true; return $true }
    Close-ControlPanel
    $script:PanelError = $null
    $rs = $script:PanelRs
    if ($null -eq $rs -or $rs.RunspaceStateInfo.State -ne [System.Management.Automation.Runspaces.RunspaceState]::Opened) {
      # Its own thread (STA, as Windows Forms needs), the same one each time the window opens.
      $rs = [runspacefactory]::CreateRunspace()
      $rs.ApartmentState = [System.Threading.ApartmentState]::STA
      $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
      $rs.Open()
      $script:PanelRs = $rs
    }
    # The message pane: the queue outlives the window; a new window starts from the ring of recent lines.
    $backlog = $null
    $logPath = ''
    # (The file dialog's filter: the same videos as the console's file picker.)
    $exts = ''
    try { if ($script:MediaExts) { $exts = (@($script:MediaExts) | ForEach-Object { '*' + $_ }) -join ';' } } catch {}
    try { if ($script:DataDir) { $logPath = [System.IO.Path]::Combine([string]$script:DataDir, 'log.txt') } } catch {}
    try {
      if ($null -ne $script:UiLogRing) { $backlog = $script:UiLogRing.ToArray() }
      $drop = $null
      if ($null -ne $script:UiLog) { while ($script:UiLog.TryDequeue([ref]$drop)) {} }
    } catch {}
    # The bus outlives the window (the main script makes it at load; Panel.ps1 on its own makes one here, kept as well).
    $bus = $script:UiBus
    if ($null -eq $bus) {
      $bus = [hashtable]::Synchronized(@{ Log = $script:UiLog; Cmds = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Ask = $null
          Answers = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Status = $null; QuitReq = $false })
      $script:UiBus = $bus
    }
    $sync = [hashtable]::Synchronized(@{
      State = $null; Cmds = $bus.Cmds; Bus = $bus
      Ready = $false; Closed = $false; ShowReq = $false; CloseReq = $false; Error = $null; Logged = $false; Warn = $null
      Log = $bus.Log; Backlog = $backlog; LogPath = $logPath
      StartBounds = $script:PanelBounds; Bounds = $null; MediaExts = $exts
    })
    $self = $script:PanelSelf
    if (-not $self) { $self = $script:PanelFile }
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:PanelBoot).AddArgument($sync).AddArgument($self).AddArgument($script:Tr).AddArgument($script:PreviewFile).AddArgument(${function:T}.ToString()).AddArgument(${function:Format-Time}.ToString())
    $script:PanelSync = $sync
    $script:PanelPs = $ps
    $script:PanelRun = $ps.BeginInvoke()
    # Until it shows (the first time takes a moment: Windows Forms loads).
    $until = [DateTime]::UtcNow.AddSeconds(15)
    while (-not $sync.Ready -and -not $sync.Closed -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 20 }
    if ($sync.Ready -and -not $sync.Closed) { return $true }
    if ($sync.Error) { $sync.Logged = $true; Write-PanelError ([string]$sync.Error) }
    Close-ControlPanel
    return $false
  } catch {
    Write-PanelError $_.Exception.Message
    try { Close-ControlPanel } catch {}
    return $false
  }
}

function Close-ControlPanel {
  $sync = $script:PanelSync
  $ps = $script:PanelPs
  $run = $script:PanelRun
  $script:PanelSync = $null
  $script:PanelPs = $null
  $script:PanelRun = $null
  if ($sync) { $sync.CloseReq = $true }
  if ($null -eq $ps) { return }
  $until = [DateTime]::UtcNow.AddSeconds(3)
  while (-not $run.IsCompleted -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 20 }
  if ($run.IsCompleted) { try { $ps.Dispose() } catch {} }
  else { $script:PanelRs = $null }   # its thread doesn't answer: it ends with the tool, and a new window gets a new one
  # (Where it was: the next window of this run opens there.)
  try { if ($sync -and $sync.Bounds) { $script:PanelBounds = $sync.Bounds } } catch {}
}

# $s: what the window shows (see Update-PanelView). The window's thread picks it up; this never waits.
function Update-ControlPanel([hashtable]$s) {
  $sync = $script:PanelSync
  if ($sync) { $sync.State = $s }
}

# ------------------------------------------------------------------ the window's thread
# Builds the window and runs its message loop until it closes. A Forms timer picks up the main thread's
# requests and state (Invoke-PanelTick), so nothing here ever waits for the main thread.
function Start-PanelUi($sync) {
  $script:PanelSync = $sync
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  if (-not $script:PanelStyled) {
    $script:PanelStyled = $true
    try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch {}
  }
  # (for this thread) A stray exception in a handler closes the window instead of showing .NET's error box.
  [System.Windows.Forms.Application]::add_ThreadException({ param($sender, $e) try { Stop-PanelAfterError $e.Exception } catch {} })
  $timer = $null
  try {
    New-ControlPanel
    $q = $script:Panel
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 100
    $timer.Add_Tick({ Invoke-PanelTick })
    $q.Timer = $timer
    $q.Form.Add_Shown({ try { $script:PanelSync.Ready = $true; Update-PanelLayout; Set-PanelCue } catch {} })
    $timer.Start()
    [System.Windows.Forms.Application]::Run($q.Form)
  } finally {
    $sync.Closed = $true
    if ($timer) { try { $timer.Stop(); $timer.Dispose() } catch {} }
    Remove-PanelResources
  }
}

# Every 100 ms on the window's thread: the main thread's requests, then what it wants shown.
function Invoke-PanelTick {
  $sync = $script:PanelSync
  $q = $script:Panel
  if ($null -eq $q -or $q.Closed) { return }
  try {
    if ($sync.CloseReq) { $q.Closed = $true; $q.Form.Close(); return }
    if ($sync.ShowReq) { $sync.ShowReq = $false; Show-PanelWindow }
  } catch {
    Stop-PanelAfterError $_
    return
  }
  # (Each on its own: an error in one doesn't skip the other.)
  try { Update-PanelAsk } catch { Write-PanelWarning $_ }
  try { Update-PanelView $sync.State } catch { Write-PanelWarning $_ }
  if ($q.Closed) { return }
  try { Update-PanelLog $sync } catch { Write-PanelWarning $_ }
  try { Update-PanelBanner } catch { Write-PanelWarning $_ }
}

# New message lines for the pane (at most 300 per tick). Past 1500 lines it drops the oldest down to 1200 (at once, not
# one per new line). It follows the end unless scrolled up.
function Update-PanelLog($sync) {
  $q = $script:Panel
  $lg = $q.Log
  if ($null -eq $lg) { return }
  $new = New-Object 'System.Collections.Generic.List[object]'
  $bl = $sync.Backlog
  if ($bl) { $sync.Backlog = $null; foreach ($e in $bl) { $new.Add($e) } }
  $src = $sync.Log
  # (The warnings banner: the newest yellow / red line that came in now, not one from the backlog of an earlier window.)
  $warn = $null
  if ($null -ne $src) {
    $e = $null
    $n = 0
    while ($n -lt 300 -and $src.TryDequeue([ref]$e)) {
      $new.Add($e); $n++
      try { if ([string]$e[1] -match '^(Dark)?(Yellow|Red)$' -and ([string]$e[0]).Trim()) { $warn = $e } } catch {}
    }
  }
  if ($new.Count -eq 0) { return }
  if ($warn) { try { Show-PanelBanner ([string]$warn[0]) ([string]$warn[1]) } catch { Write-PanelWarning $_ } }
  $rows = [Math]::Max(1, [int][Math]::Floor($lg.ClientSize.Height / [Math]::Max(1, $lg.ItemHeight)))
  $atEnd = ($lg.Items.Count -eq 0) -or (($lg.TopIndex + $rows) -ge ($lg.Items.Count - 1))
  $q.LogAtEnd = $atEnd
  $flags = [System.Windows.Forms.TextFormatFlags]::NoPrefix -bor [System.Windows.Forms.TextFormatFlags]::SingleLine
  $widest = $q.LogWidest
  $failed = $null
  $lg.BeginUpdate()
  try {
    # (The lines are already out of the queue: one that can't be added is skipped, the rest still go in.)
    foreach ($e in $new) {
      try {
        foreach ($ln in (([string]$e[0]) -split "`r?`n")) {
          try {
            [void]$lg.Items.Add($ln)
            $q.LogColors.Add([string]$e[1])
            # Each line is measured once, as it comes in: the widest one sets how far the list scrolls sideways.
            if ($ln.Length -gt 0) { $widest = [Math]::Max($widest, [System.Windows.Forms.TextRenderer]::MeasureText($ln, $lg.Font, [System.Drawing.Size]::Empty, $flags).Width) }
          } catch { if (-not $failed) { $failed = $_ } }
        }
      } catch { if (-not $failed) { $failed = $_ } }
    }
    if ($lg.Items.Count -gt 1500) {
      $keep = 1200
      $drop = $lg.Items.Count - $keep
      # (A view scrolled up and the selected lines stay where they were, on the same lines.)
      $top = $lg.TopIndex
      $sel = @(foreach ($i in $lg.SelectedIndices) { [int]$i })
      $rest = New-Object object[] $keep
      for ($i = 0; $i -lt $keep; $i++) { $rest[$i] = $lg.Items[$drop + $i] }
      $lg.Items.Clear()
      $lg.Items.AddRange($rest)
      if ($q.LogColors.Count -gt $keep) { $q.LogColors.RemoveRange(0, $q.LogColors.Count - $keep) }
      foreach ($i in $sel) { if ($i -ge $drop) { $lg.SetSelected($i - $drop, $true) } }
      if (-not $atEnd) { $lg.TopIndex = [Math]::Max(0, $top - $drop) }
    }
    if ($widest -gt $q.LogWidest) { $q.LogWidest = $widest; $lg.HorizontalExtent = $widest + 6 }
    if ($atEnd) { $lg.TopIndex = [Math]::Max(0, $lg.Items.Count - $rows) }
  } finally { $lg.EndUpdate() }
  if ($failed) { Write-PanelWarning $failed }
}

function Show-PanelWindow {
  $f = $script:Panel.Form
  if ($f.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { $f.WindowState = [System.Windows.Forms.FormWindowState]::Normal }
  if (-not $f.Visible) { $f.Show() }
  $f.BringToFront()
  $f.Activate()
}

function Remove-PanelResources {
  $q = $script:Panel
  if ($null -eq $q) { return }
  try { Remove-PanelImage } catch {}
  try { if ($q.Form -and -not $q.Form.IsDisposed) { $q.Form.Dispose() } } catch {}
  foreach ($x in @($q.Tips, $q.Font, $q.Bold, $q.Small, $q.Sym, $q.SymS, $q.BigFont, $q.Mono, $q.Icon)) { try { if ($x) { $x.Dispose() } } catch {} }
  try { foreach ($x in $q.Brushes.Values) { $x.Dispose() } } catch {}
  $script:Panel = $null
}

# $s (from the main thread, $null before the first update): Mode ('content'|'paused'|'hold'|'waiting'|'reconnect'|
# 'off'), Title, Position, Duration (0 = unknown), Status, Player, Upcoming (string[]) and UpcomingIds (int[], the
# queue items' Ids, same order) with UpcomingNames / UpcomingInfo (string[]: each one's name and how far its download
# is, apart) and UpcomingTotal (how many wait in all: the rows stop at 20), Link, QuestLink ('' = none), Clock (bool), CanSeek (bool), Quality / QualityLow / QualityTip (the chip
# right of the title), Menu / Choices / Chosen (the Settings menu, see Update-PanelMenu),
# Prompt (bool: the start screen and its questions, nothing plays yet: Next / Stop / Resync and the Settings items off;
# the input row answers the start screen's '>' only). An open question (bus.Ask, the card) turns the input row and the
# Up next buttons and menu off.
function Update-PanelView($s) {
  try {
    $hasState = ($null -ne $s)
    if ($null -eq $s) { $s = @{} }
    $q = $script:Panel
    $now = [DateTime]::UtcNow
    $mode = [string]$s['Mode']
    if (-not $mode) { $mode = 'off' }
    $dur = 0.0
    $pos = 0.0
    try { $dur = [double]$s['Duration'] } catch {}
    try { $pos = [double]$s['Position'] } catch {}
    if ([double]::IsNaN($dur) -or [double]::IsInfinity($dur) -or $dur -lt 0) { $dur = 0.0 }
    if ([double]::IsNaN($pos) -or [double]::IsInfinity($pos) -or $pos -lt 0) { $pos = 0.0 }
    $canSeek = [bool]$s['CanSeek']
    $on = ($mode -ne 'off')
    # (Prompt: the tool's own window still asks its start questions, nothing plays yet: no commands meanwhile.)
    $cmdOn = ($on -and -not [bool]$s['Prompt'])

    Set-PanelMode $mode
    $title = [string]$s['Title']
    if (-not $title) { $title = T 'Nothing is playing' }
    if ($script:PanelLast['title'] -cne $title) { $q.Tips.SetToolTip($q.Title, $title) }
    Set-PanelProp 'title' $q.Title 'Text' $title

    $rel = ($canSeek -and ($mode -eq 'content' -or $mode -eq 'paused' -or $mode -eq 'hold'))
    foreach ($b in @($q.Back30, $q.Back10, $q.Fwd10, $q.Fwd30)) { Set-PanelProp ('en' + $b.GetHashCode()) $b 'Enabled' $rel }
    Set-PanelProp 'next' $q.Next 'Enabled' $cmdOn
    Set-PanelProp 'stop' $q.Stop 'Enabled' $cmdOn
    Set-PanelProp 'resync' $q.Resync 'Enabled' $cmdOn
    if ($q.StopArmedUntil -ne [DateTime]::MinValue -and ($now -ge $q.StopArmedUntil -or -not $cmdOn)) {
      $q.StopArmedUntil = [DateTime]::MinValue
      Reset-PanelStop
    }

    $link = [string]$s['Link']
    $q.Link = $link
    Set-PanelProp 'copy' $q.Copy 'Enabled' ([bool]$link)
    Set-PanelProp 'viewer' $q.Viewer 'Enabled' ([bool]$link)
    if ($script:PanelLast['link'] -cne $link) {
      $script:PanelLast['link'] = $link
      $q.LinkBox.Text = $link
      # (Nothing selected: the box takes the focus for a moment at times, see Select-PanelPage, and would select it all.)
      $q.LinkBox.Select(0, 0)
      $q.Tips.SetToolTip($q.Copy, $link)
    }
    # [Quest link]: only when the host has one (its column is 0 wide otherwise).
    $quest = [string]$s['QuestLink']
    $q.QuestLink = $quest
    if ($script:PanelLast['quest'] -cne $quest) {
      $script:PanelLast['quest'] = $quest
      $w = 0
      if ($quest) { $w = $q.QuestW; $q.Tips.SetToolTip($q.Quest, (T 'Copies the link for Quest / Android viewers: {0}' $quest)) }
      $q.Quest.Visible = [bool]$quest
      $q.LinkBar.ColumnStyles[3].Width = [single]$w
    }
    if ($q.CopiedUntil -ne [DateTime]::MinValue -and $now -ge $q.CopiedUntil) { Reset-PanelCopied }
    # The input row: it answers the start screen's '>' (a question of kind 'line') and adds while something streams;
    # off while another question is open (the card is where that one is answered) and on the start screen while its
    # questions are busy (a line typed then would only be lost).
    $ask = Get-PanelAsk
    $lineAsk = ($null -ne $ask -and [string]$ask['Kind'] -eq 'line')
    $stripAsk = ($null -ne $ask -and -not $lineAsk)
    $inputOn = ($hasState -and -not $stripAsk -and ($lineAsk -or -not [bool]$s['Prompt']))
    if ($lineAsk -and $q.AskSent -ceq [string]$ask['Id']) { $inputOn = $false }
    $q.InputOn = $inputOn
    # (The focus first leaves the row for the read-only link box, which owns no transport keys: disabling a focused
    # control would hand the focus to the next one, the Next button, and a later Enter / Space would skip / pause.
    # It comes back to the input box with the row, unless the user moved it meanwhile.)
    if (-not $inputOn) {
      $fc = $null
      try { $fc = Get-PanelFocus } catch {}
      if ($fc -and $q.InputRow.Contains($fc)) { $q.Form.ActiveControl = $q.LinkBox; $q.InputParked = $true }
    }
    foreach ($ctl in @($q.Input, $q.AddLine, $q.Files, $q.Folder)) { Set-PanelProp ('in' + $ctl.GetHashCode()) $ctl 'Enabled' $inputOn }
    if ($inputOn -and $q.InputParked) {
      $q.InputParked = $false
      $fc = $null
      try { $fc = Get-PanelFocus } catch {}
      if ($fc -eq $q.LinkBox) { $q.Form.ActiveControl = $q.Input }
    }
    # (A title back from the search - nothing found, or left: in the box again, to change it.)
    if ($inputOn) {
      $bus = Get-PanelBus
      $back = $null
      try { if ($bus) { $back = $bus['InputBack'] } } catch {}
      if ($back) {
        $bus['InputBack'] = $null
        if (-not $q.Input.Text) { $q.Input.Text = [string]$back; $q.Input.SelectionStart = $q.Input.TextLength }
      }
    }
    $busyAsk = ($stripAsk -and [string]$ask['Kind'] -eq 'busy')
    $tipKey = [string]$inputOn + [string]$stripAsk + [string]$busyAsk
    if ($script:PanelLast['inputtip'] -cne $tipKey) {
      $script:PanelLast['inputtip'] = $tipKey
      $t = ''
      if ($busyAsk) { $t = T 'The search is running: wait for it or cancel it.' }
      elseif ($stripAsk) { $t = T 'Answer the question first.' }
      elseif (-not $inputOn) { $t = T 'Busy with the last step: the box works again in a moment.' }
      $q.Tips.SetToolTip($q.InputRow, $t)
    }
    if (-not $q.CueSet -and $q.CueTries -lt 50) { $q.CueTries++; Set-PanelCue }

    $st = [string]$s['Status']
    # (The console's own status line while nothing plays - a download's %, the speed test - while it is fresh.)
    if ($mode -ne 'content' -and $mode -ne 'paused' -and $mode -ne 'hold') {
      try {
        $bs = (Get-PanelBus).Status
        if ($bs -and [string]$bs['Text'] -and ($now - [DateTime]$bs['At']).TotalSeconds -lt 3) { $st = [string]$bs['Text'] }
      } catch {}
    }
    if ($script:PanelLast['status'] -cne $st) { $q.Tips.SetToolTip($q.Status, $st); $q.Status.Text = $st; $script:PanelLast['status'] = $st; Set-PanelStatusHeight }
    $pl = [string]$s['Player']
    if ($script:PanelLast['player'] -cne $pl) { $q.Tips.SetToolTip($q.Player, $pl) }
    Set-PanelProp 'player' $q.Player 'Text' $pl
    Set-PanelProp 'quality' $q.Quality 'Text' ([string]$s['Quality'])
    $qc = $q.Colors.Dim
    if ([bool]$s['QualityLow']) { $qc = (New-PanelColor 235 150 50) }
    Set-PanelProp 'qualitycol' $q.Quality 'ForeColor' $qc
    $qtipKey = [string]$s['QualityTip'] + "`n" + [string]$s['Quality']
    if ($script:PanelLast['qtip'] -cne $qtipKey) {
      $script:PanelLast['qtip'] = $qtipKey
      $tip = [string]$s['QualityTip']
      if ($s['Quality']) { $tip = [string]$s['Quality'] + "`r`n" + $tip }
      $q.Tips.SetToolTip($q.Quality, $tip.Trim())
    }
    # (Settings stays on: its stream items work only while nothing plays, see Update-PanelMenu; the clock, always on
    # top and log.txt always; End stream while something is on the air or a question waits.)
    $q.CmdOn = $cmdOn
    $q.ClockOn = [bool]$s['Clock']
    # Up next's buttons: not on the start screen, nor while the main thread asks (as its menu, Update-PanelQueueMenu).
    $qon = ($hasState -and -not [bool]$s['Prompt'] -and -not (Test-PanelMainAsk))
    if ($qon -ne $q.QOn) { $q.QOn = $qon; $q.List.Invalidate() }

    $up = @()
    if ($null -ne $s['Upcoming']) { $up = @(foreach ($u in @($s['Upcoming'])) { [string]$u }) }
    $ids = @()
    if ($null -ne $s['UpcomingIds']) { $ids = @(foreach ($u in @($s['UpcomingIds'])) { [int]$u }) }
    if ($ids.Count -ne $up.Count) { $ids = @() }
    # (Each row's name and how far its download is, apart; without them, the whole line is the name.)
    $names = $up
    $infos = @($up | ForEach-Object { '' })
    if ($null -ne $s['UpcomingNames'] -and $null -ne $s['UpcomingInfo']) {
      $nm = @(foreach ($u in @($s['UpcomingNames'])) { [string]$u })
      $nf = @(foreach ($u in @($s['UpcomingInfo'])) { [string]$u })
      if ($nm.Count -eq $up.Count -and $nf.Count -eq $up.Count) { $names = $nm; $infos = $nf }
    }
    $total = $ids.Count
    try { if ($null -ne $s['UpcomingTotal']) { $total = [Math]::Max($ids.Count, [int]$s['UpcomingTotal']) } } catch {}
    $upKey = ($up -join "`n") + "`n" + ($ids -join ',') + "`n" + $total
    if (-not $script:PanelLast.ContainsKey('up') -or $script:PanelLast['up'] -cne $upKey) {
      $script:PanelLast['up'] = $upKey
      $q.ListTotal = $total
      # (The same line stays selected when the list changes around it: by its Id. The view stays scrolled where it
      # was too: a download's progress changes the texts every second or two.)
      $selId = Get-PanelListId
      $top = $q.List.TopIndex
      $q.ListIds = $ids
      $q.ListNames = $names
      $q.ListInfo = $infos
      $q.List.BeginUpdate()
      $q.List.Items.Clear()
      $n = 1
      foreach ($u in $up) { [void]$q.List.Items.Add(('{0}. {1}' -f $n, $u)); $n++ }
      if ($selId -gt 0) { $ix = [array]::IndexOf([int[]]$ids, $selId); if ($ix -ge 0) { $q.List.SelectedIndex = $ix } }
      if ($top -gt 0 -and $q.List.Items.Count -gt 0) { $q.List.TopIndex = [Math]::Min($top, $q.List.Items.Count - 1) }
      if ($q.QHot -ge $q.List.Items.Count) { $q.QHot = -1; $q.QHotBtn = '' }
      $q.List.EndUpdate()
      # (Nothing queued: the hint instead of the empty list; the tab says how many.)
      Select-PanelPage $q.Page
    }

    $seekOn = ($canSeek -and $dur -gt 0)
    if (-not $seekOn -and $q.Drag) { $q.Drag = $false }
    if ($q.SeekOn -ne $seekOn -or $q.SeekDur -ne $dur) { $q.SeekOn = $seekOn; $q.SeekDur = $dur; $q.SeekPx = -2 }
    $q.RealPos = $pos
    Update-PanelSeekShown
    $durText = '--:--'
    if ($dur -gt 0) { $durText = Format-Time $dur }
    Set-PanelProp 'dur' $q.Dur 'Text' $durText
  } catch {
    Stop-PanelAfterError $_
    return
  }
  try { Update-PanelPreview ([DateTime]::UtcNow) } catch {}   # a bad frame only skips that frame
}

# ------------------------------------------------------------------ viewer preview (ffplay)
function Find-FFplay {
  $name = 'ffplay.exe'
  foreach ($dir in @($script:FFmpegDir, $(if ($script:FFmpeg) { [System.IO.Path]::GetDirectoryName($script:FFmpeg) }))) {
    if ($dir) { $f = [System.IO.Path]::Combine($dir, $name); if ([System.IO.File]::Exists($f)) { return $f } }
  }
  $cmd = Get-Command 'ffplay' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd) { return $cmd.Path }
  return $null
}

function ConvertTo-PanelArg([string]$a) {
  if ($a.Length -gt 0 -and $a -notmatch '[\s"]') { return $a }
  return '"' + (($a -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Stop-ViewerPreview {
  try { if ($script:ViewerProc -and -not $script:ViewerProc.HasExited) { $script:ViewerProc.Kill() } } catch {}
  try { if ($script:ViewerProc) { $script:ViewerProc.Dispose() } } catch {}
  $script:ViewerProc = $null
}

# Opens ffplay on the stream's rtsp:// link: the real stream from the server, as viewers get it.
function Start-ViewerPreview([string]$url) {
  try {
    if (-not $url) { return $false }
    $exe = Find-FFplay
    if (-not $exe) { return $false }
    Stop-ViewerPreview
    $argv = New-Object System.Collections.Generic.List[string]
    $argv.AddRange([string[]]@('-hide_banner', '-loglevel', 'error', '-fflags', 'nobuffer', '-flags', 'low_delay', '-framedrop'))
    # (-rtsp_transport exists only for rtsp:// links: ffplay refuses it for anything else)
    if ($url -match '^(?i)rtsps?://') { $argv.AddRange([string[]]@('-rtsp_transport', 'tcp')) }
    $argv.AddRange([string[]]@('-window_title', (T 'What viewers see'), '-x', '640', '-y', '360', $url))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = (($argv | ForEach-Object { ConvertTo-PanelArg ([string]$_) }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $script:ViewerProc = [System.Diagnostics.Process]::Start($psi)
    # (Closed together with the tool: the main script's job, see Add-ChildToJob.)
    try { if ('VRCLinkMaker.ChildJob' -as [type]) { [void][VRCLinkMaker.ChildJob]::Add($script:ViewerProc.Handle) } } catch {}
    return ($null -ne $script:ViewerProc)
  } catch {
    $script:PanelError = $_
    return $false
  }
}
