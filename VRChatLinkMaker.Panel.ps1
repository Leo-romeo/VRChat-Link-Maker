# VRChat Link Maker - the control window
# --------------------------------------
# A small window next to the console with a live preview of the stream and buttons for it: pause /
# continue, jump back and forward, next video, stop, add, resync, copy the link. The main script
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
# synchronized hashtable: State (what to show), Cmds (the clicks), Ready, Closed, ShowReq, CloseReq, Error.
# Nothing on the window's side may throw: every handler is wrapped, and an internal error only closes the
# window (the reason goes to $script:PanelError and log.txt).
# What the window posts (Cmds, {Cmd; Arg}): the stream's commands (toggle, seek, seekto, skip, stop, resync, quit),
# add / viewer / clock, the Settings menu's item Ids (host / res / lang with the choice as Arg), 'line' (the input
# box's text), 'files' (paths: picked, dropped or pasted), and qplay / qup / qdown / qremove / qclear (Arg = @{ Id },
# the Up next menu). The main thread carries them out in Receive-Commands only, never inside a question.
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
    if ($script:PanelSync -and $script:PanelSync.Cmds.TryDequeue([ref]$c)) { return $c }
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

# Columns sized by how wide each button's text is (translations differ a lot in length).
function Set-PanelGridWidths($grid, $buttons, [int]$extra) {
  $grid.ColumnStyles.Clear()
  foreach ($b in $buttons) {
    $w = [System.Windows.Forms.TextRenderer]::MeasureText([string]$b.Text, $b.Font).Width + $extra
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, [single]$w)))
  }
}

function New-ControlPanel {
  $WF = 'System.Windows.Forms'
  $p = @{
    Closed = $false; Link = ''; QuestLink = ''; Mode = ''; Warned = 0; LogWidest = 0; RealPos = 0.0; PosText = ''; SeekDur = 0.0; SeekShown = 0.0; SeekOn = $false; SeekPx = -1
    Drag = $false; DragPos = 0.0; HoldPos = 0.0; HoldUntil = [DateTime]::MinValue
    StopArmedUntil = [DateTime]::MinValue; CopiedUntil = [DateTime]::MinValue; CopiedBtn = $null
    PrevCheck = [DateTime]::MinValue; PrevTime = [DateTime]::MinValue; PrevMissing = [DateTime]::MinValue
    InputOn = $false; CmdOn = $false; ListIds = @(); BannerUntil = [DateTime]::MinValue; CueSet = $false; CueTries = 0; InputParked = $false; InRows = $false; Timer = $null
  }
  $script:Panel = $p
  $script:PanelLast = @{}
  $p.Colors = @{
    Back = (New-PanelColor 30 30 32); Box = (New-PanelColor 40 40 44); Button = (New-PanelColor 52 52 58)
    Hover = (New-PanelColor 70 70 80); Border = (New-PanelColor 80 80 90); Text = (New-PanelColor 232 232 236)
    Dim = (New-PanelColor 160 160 170); Accent = (New-PanelColor 64 156 255); Track = (New-PanelColor 75 75 85)
    Red = (New-PanelColor 190 55 55); Black = [System.Drawing.Color]::Black
  }
  $c = $p.Colors
  $p.Brushes = @{
    Track = (New-Object System.Drawing.SolidBrush($c.Track)); Fill = (New-Object System.Drawing.SolidBrush($c.Accent))
    Thumb = (New-Object System.Drawing.SolidBrush($c.Text)); Off = (New-Object System.Drawing.SolidBrush((New-PanelColor 60 60 66)))
    Dim = (New-Object System.Drawing.SolidBrush($c.Dim))
  }
  $p.Font = New-Object System.Drawing.Font('Segoe UI', [single]9)
  $p.Bold = New-Object System.Drawing.Font('Segoe UI', [single]10.5, [System.Drawing.FontStyle]::Bold)
  $p.Small = New-Object System.Drawing.Font('Segoe UI', [single]8.25, [System.Drawing.FontStyle]::Bold)
  $p.Sym = New-Object System.Drawing.Font('Segoe UI Symbol', [single]9.75)
  $p.BigFont = New-Object System.Drawing.Font('Segoe UI Symbol', [single]11, [System.Drawing.FontStyle]::Bold)
  $p.Mono = New-Object System.Drawing.Font('Consolas', [single]9)
  $fh = $p.Font.Height
  $k = $fh / 15.0
  $p.K = $k
  $p.Tips = New-Object "$WF.ToolTip"
  $p.Tips.AutoPopDelay = 15000
  $p.Tips.InitialDelay = 400

  $f = New-Object "$WF.Form"
  $p.Form = $f
  $f.Text = (T 'Stream controls') + ' - VRChat Link Maker'
  $f.Font = $p.Font
  $f.BackColor = $c.Back
  $f.ForeColor = $c.Text
  $f.KeyPreview = $true
  $f.ShowInTaskbar = $true
  $f.AllowDrop = $true
  $f.StartPosition = [System.Windows.Forms.FormStartPosition]::WindowsDefaultLocation
  $f.MinimumSize = New-Object System.Drawing.Size([int](560 * $k), [int](620 * $k))
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $f.Size = New-Object System.Drawing.Size([int]([Math]::Min(720 * $k, [Math]::Max(560 * $k, $wa.Width - 40))), [int]([Math]::Min(960 * $k, [Math]::Max(620 * $k, $wa.Height - 60))))
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
  # Rows: 0 title, 1 link bar, 2 warnings banner, 3 input box, 4 preview, 5 seek bar, 6 transport, 7 status, 8 player,
  # 9-10 up next, 11-12 messages, 13 buttons, 14 checkboxes. The preview takes what is left (it shrinks first on a small
  # screen); up next and messages get a share of it, at least a few lines each (Update-PanelRows).
  $p.ListMin = [int]($fh * 2.5) + [int](4 * $k)
  $p.LogMin = [int]($fh * 3) + [int](4 * $k)
  $rowSizes = @('Auto', 'Auto', 'Auto', 'Auto', 'P100', 'Auto', 'Auto', 'Auto', 'Auto', 'Auto', ('A' + [int]($fh * 5)), 'Auto', ('A' + [int]($fh * 6)), 'Auto', 'Auto')
  $p.RowPreview = 4; $p.RowList = 10; $p.RowLog = 12
  $root.RowCount = $rowSizes.Count
  foreach ($r in $rowSizes) {
    if ($r -eq 'Auto') { [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) }
    elseif ($r.StartsWith('A')) { [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, [single]$r.Substring(1)))) }
    else { [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, [single]$r.Substring(1)))) }
  }
  $p.Root = $root

  # Row 0: what the stream is doing + the title, and what the stream carries (a dim chip: host - picture fps kbps;
  # orange when it is too few bits for the picture size). The chip is as wide as its text: the title gives way.
  $top = New-PanelGrid 3 ($p.Bold.Height + 8)
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
  $p.Quality.Margin = New-Object System.Windows.Forms.Padding([int](6 * $k), 1, 2, 1)
  $top.Controls.Add($p.Quality, 2, 0)
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

  # Row 3: the input box (a title, a link, a file path; Enter = Add), [Files...], [Folder...]. Files and folders can be
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
  $root.Controls.Add($in, 0, 3)

  # Row 4: the preview picture (what ffmpeg sends, refreshed about twice a second)
  $pv = New-Object "$WF.PictureBox"
  $pv.Dock = [System.Windows.Forms.DockStyle]::Fill
  $pv.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
  $pv.BackColor = $c.Black
  $pv.Margin = New-Object System.Windows.Forms.Padding(2, [int](4 * $k), 2, [int](4 * $k))
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
  $root.Controls.Add($pv, 0, 4)

  # Row 5: position, seek bar, duration
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
  $root.Controls.Add($time, 0, 5)

  # Row 6: transport buttons
  $rew = [string][char]0x23EA
  $fwd = [string][char]0x23E9
  $tr = New-PanelGrid 7 ([int]($fh * 2.5))
  $p.Back30 = New-PanelButton ($rew + ' ' + (T '{0}s' 30)) (T 'Back 30 seconds (Shift+Left)') 'seek' (-30) $p.Sym
  $p.Back10 = New-PanelButton ($rew + ' ' + (T '{0}s' 10)) (T 'Back 10 seconds (Left arrow)') 'seek' (-10) $p.Sym
  $p.Big = New-PanelButton '' (T 'Space pauses and continues') 'toggle' $null $p.BigFont
  $p.Big.BackColor = (New-PanelColor 40 90 150)
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
  $root.Controls.Add($tr, 0, 6)

  # Rows 7-10: status, VRChat player, up next
  $p.Status = New-PanelLabel '' ($fh * 2 + 6) $null $null
  $p.Status.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
  $p.Status.Margin = New-Object System.Windows.Forms.Padding(2, [int](6 * $k), 2, 1)
  $root.Controls.Add($p.Status, 0, 7)
  # The VRChat player's state (what the stream carries is the chip right of the title).
  $p.Player = New-PanelLabel '' ($fh + 6) $null $c.Dim
  $root.Controls.Add($p.Player, 0, 8)
  $root.Controls.Add((New-PanelLabel (T 'Up next') ($p.Small.Height + 8) $p.Small $c.Dim), 0, 9)
  $lb = New-Object "$WF.ListBox"
  $lb.Dock = [System.Windows.Forms.DockStyle]::Fill
  $lb.IntegralHeight = $false
  $lb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $lb.BackColor = $c.Box
  $lb.ForeColor = $c.Text
  $lb.Margin = New-Object System.Windows.Forms.Padding(2, 0, 2, [int](4 * $k))
  $lb.MinimumSize = New-Object System.Drawing.Size(0, [int]($fh * 2.5))
  # Right-click: play now, move, remove, clear (by the item's Id: the main thread may have changed the queue meanwhile).
  $lb.Add_MouseDown({
    param($sender, $e)
    try {
      if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        $ix = $sender.IndexFromPoint($e.Location)
        if ($ix -ge 0) { $sender.SelectedIndex = $ix }
      }
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
  $root.Controls.Add($lb, 0, 10)

  # Rows 11-12: messages (everything the console window shows; right-click copies)
  $root.Controls.Add((New-PanelLabel (T 'Messages') ($p.Small.Height + 8) $p.Small $c.Dim), 0, 11)
  $lg = New-Object "$WF.ListBox"
  $lg.Dock = [System.Windows.Forms.DockStyle]::Fill
  $lg.IntegralHeight = $false
  $lg.HorizontalScrollbar = $true
  $lg.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $lg.BackColor = $c.Box
  $lg.ForeColor = $c.Text
  $lg.Font = New-Object System.Drawing.Font('Consolas', [single]8.25)
  $lg.Margin = New-Object System.Windows.Forms.Padding(2, 0, 2, [int](4 * $k))
  $lg.MinimumSize = New-Object System.Drawing.Size(0, [int]($fh * 3))
  $lg.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
  $lg.ItemHeight = $lg.Font.Height + 1
  $lg.SelectionMode = [System.Windows.Forms.SelectionMode]::MultiExtended
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
  $root.Controls.Add($lg, 0, 12)

  # Row 13: search / add in a second window, viewer preview, resync, settings
  $bot = New-PanelGrid 4 ([int]($fh * 2.7))
  $p.Add = New-PanelButton (T 'Add / search...') (T 'Add a video or a link, or search for one.') 'add' $null $null
  $p.Viewer = New-PanelButton (T 'Watch as viewers see it') (T 'Opens the real stream in a small player window, the way viewers get it (with their delay). Close it any time.') 'viewer' $null $null
  $p.Resync = New-PanelButton ([string][char]0x21BB + ' ' + (T 'Resync everyone')) (T 'Everyone''s player reconnects to the live picture, so all viewers are in sync again. The video waits for them.') 'resync' $null $p.Sym
  # Settings: the same list as M in the console (the main thread sends it, see Update-PanelMenu), then log.txt and
  # End stream. What changes the link or the picture works only while nothing plays.
  $p.More = New-PanelButton ((T 'Settings') + ' ' + [char]0x25BE) (T 'Where to stream, picture size, speed test, new link, language, log.txt and End stream. The stream settings work while nothing plays; questions that need typing appear in the console window.') '' $null $p.Sym
  $menu = New-Object "$WF.ContextMenuStrip"
  $menu.ShowItemToolTips = $true
  $menu.Add_Opening({ try { Update-PanelMenu } catch { Write-PanelWarning $_ } })
  $p.Menu = $menu
  Update-PanelMenu
  $p.More.Add_Click({ try { $q = $script:Panel; $q.Menu.Show($q.More, 0, $q.More.Height) } catch {} })
  $bb = @($p.Add, $p.Viewer, $p.Resync, $p.More)
  Set-PanelGridWidths $bot $bb ([int](24 * $k))
  foreach ($b in $bb) { $b.AutoEllipsis = $false }   # long translations wrap onto a second line
  $i = 0
  foreach ($b in $bb) { $bot.Controls.Add($b, $i, 0); $i++ }
  $root.Controls.Add($bot, 0, 13)

  # Row 14: checkboxes
  $flow = New-Object "$WF.FlowLayoutPanel"
  $flow.Dock = [System.Windows.Forms.DockStyle]::Fill
  $flow.Height = $fh + [int](12 * $k)
  $flow.WrapContents = $false
  $flow.Margin = New-Object System.Windows.Forms.Padding(0, [int](2 * $k), 0, 0)
  $p.Clock = New-Object "$WF.CheckBox"
  $p.Clock.Text = T 'Clock on the stream'
  $p.Clock.AutoSize = $true
  $p.Clock.AutoCheck = $false   # shows what the stream does: the main script flips it after the command
  $p.Clock.Add_Click({ try { Add-PanelCommand 'clock' } catch {} })
  $p.OnTop = New-Object "$WF.CheckBox"
  $p.OnTop.Text = T 'Always on top'
  $p.OnTop.AutoSize = $true
  $p.OnTop.Margin = New-Object System.Windows.Forms.Padding([int](16 * $k), 3, 3, 3)
  $p.OnTop.Add_CheckedChanged({ try { $script:Panel.Form.TopMost = $script:Panel.OnTop.Checked } catch {} })
  $flow.Controls.Add($p.Clock)
  $flow.Controls.Add($p.OnTop)
  $root.Controls.Add($flow, 0, 14)
  if ($sb -and $sb.Top) { $p.OnTop.Checked = $true }

  $f.Controls.Add($root)
  $f.Add_KeyDown({
    param($sender, $e)
    try {
      if (Invoke-PanelPaste $e.KeyData) { $e.Handled = $true; $e.SuppressKeyPress = $true; return }
      if (Invoke-PanelKey $e.KeyData) { $e.Handled = $true; $e.SuppressKeyPress = $true }
    } catch {}
  })
  $f.Add_KeyUp({
    param($sender, $e)
    try { if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Space -and (Test-PanelKeyOurs $e.KeyCode)) { $e.Handled = $true; $e.SuppressKeyPress = $true } } catch {}
  })
  $f.Add_Resize({ try { Update-PanelRows } catch {} })
  $f.Add_FormClosing({ try { Save-PanelBounds } catch {} })
  $f.Add_FormClosed({ try { $script:Panel.Closed = $true; $script:PanelSync.Closed = $true; Remove-PanelImage } catch {} })
  Add-PanelKeyHook $f
  Add-PanelDropHook $f
  $f.ResumeLayout($true)
  $f.ActiveControl = $p.Big
  Set-PanelMode 'off'
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
  if ($d.Kind -eq 'files') { Add-PanelCommand 'files' $d.Files } else { Add-PanelCommand 'line' $d.Text }
  return $true
}

# Enter / [Add]: what the box holds goes to the main thread as a typed line.
function Submit-PanelInput {
  $q = $script:Panel
  if (-not $q.InputOn) { return }
  $t = [string]$q.Input.Text
  if (-not $t.Trim()) { return }
  Add-PanelCommand 'line' $t.Trim()
  $q.Input.Clear()
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
  if ($txt.Trim() -match "[`r`n]") { Add-PanelCommand 'line' $txt.Trim(); return $true }
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
  [void][VRCLinkMaker.Win]::SendMessage($q.Input.Handle, 0x1501, [IntPtr]1, (T 'Type a title, paste a link, or drop videos here'))
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
  if ($files.Count -gt 0) { Add-PanelCommand 'files' ([string[]]$files) }
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
  if ($dir) { Add-PanelCommand 'files' ([string[]]@($dir)) }
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
  $waitOk = ($mode -eq 'waiting' -and -not $prompt)
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
  $lo = New-PanelMenuItem (T 'Open log.txt') 'openlog'
  $lo.Enabled = (Test-PanelLogFile)
  $lo.Add_Click({ try { Open-PanelLogFile } catch { Write-PanelWarning $_ } })
  [void]$m.Items.Add($lo)
  [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  $en = New-PanelMenuItem (T 'End stream...') 'quit'
  $en.Enabled = ($s -and $mode -and $mode -ne 'off' -and -not $prompt)
  $en.Add_Click({ try { if (Confirm-Panel (T 'End the stream now? Viewers lose the picture.')) { Add-PanelCommand 'quit' } } catch { Write-PanelWarning $_ } })
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
  $ok = ($null -ne $s -and -not [bool]$s['Prompt'] -and -not [bool]$s['Asking'])
  $ids = @($q.ListIds)
  $ix = $q.List.SelectedIndex
  $has = ($ok -and (Get-PanelListId) -gt 0)
  $q.QPlay.Enabled = $has
  $q.QRemove.Enabled = $has
  $q.QUp.Enabled = ($has -and $ix -gt 0)
  $q.QDown.Enabled = ($has -and $ix -lt $ids.Count - 1)
  $q.QClear.Enabled = ($ok -and $ids.Count -gt 0)
}

# Up next and Messages get a share of the room left by the fixed rows, but at least a few lines each; the preview
# takes the rest, so on a small screen it is the one that shrinks.
function Update-PanelRows {
  $q = $script:Panel
  if ($null -eq $q -or $q.InRows -or $null -eq $q.Root) { return }
  $q.InRows = $true
  try {
    $root = $q.Root
    $hs = $root.GetRowHeights()
    $fixed = 0
    for ($i = 0; $i -lt $hs.Length; $i++) { if ($i -ne $q.RowPreview -and $i -ne $q.RowList -and $i -ne $q.RowLog) { $fixed += $hs[$i] } }
    $avail = $root.ClientSize.Height - $root.Padding.Vertical - $fixed
    $list = [single][Math]::Max($q.ListMin, [int]($avail * 0.24))
    $log = [single][Math]::Max($q.LogMin, [int]($avail * 0.26))
    $changed = $false
    if ($root.RowStyles[$q.RowList].Height -ne $list) { $root.RowStyles[$q.RowList].Height = $list; $changed = $true }
    if ($root.RowStyles[$q.RowLog].Height -ne $log) { $root.RowStyles[$q.RowLog].Height = $log; $changed = $true }
  } finally { $q.InRows = $false }
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
  if (-not $bn.Visible) { $bn.Visible = $true; Update-PanelRows }
}

function Hide-PanelBanner {
  $q = $script:Panel
  $q.BannerUntil = [DateTime]::MinValue
  if ($q.Banner.Visible) { $q.Banner.Visible = $false; Update-PanelRows }
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
  $script:PanelSync.Bounds = @{ X = $b.X; Y = $b.Y; W = $b.Width; H = $b.Height; Top = [bool]$q.OnTop.Checked }
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
    $sync = [hashtable]::Synchronized(@{
      State = $null; Cmds = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]')
      Ready = $false; Closed = $false; ShowReq = $false; CloseReq = $false; Error = $null; Logged = $false; Warn = $null
      Log = $script:UiLog; Backlog = $backlog; LogPath = $logPath
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
    $q.Form.Add_Shown({ try { $script:PanelSync.Ready = $true; Update-PanelRows; Set-PanelCue } catch {} })
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
  foreach ($x in @($q.Tips, $q.Font, $q.Bold, $q.Small, $q.Sym, $q.BigFont, $q.Mono)) { try { if ($x) { $x.Dispose() } } catch {} }
  try { foreach ($x in $q.Brushes.Values) { $x.Dispose() } } catch {}
  $script:Panel = $null
}

# $s (from the main thread, $null before the first update): Mode ('content'|'paused'|'hold'|'waiting'|'reconnect'|
# 'off'), Title, Position, Duration (0 = unknown), Status, Player, Upcoming (string[]) and UpcomingIds (int[], the
# queue items' Ids, same order), Link, QuestLink ('' = none), Clock (bool), CanSeek (bool), Quality / QualityLow /
# QualityTip (the chip right of the title), Menu / Choices / Chosen (the Settings menu, see Update-PanelMenu),
# Prompt (bool: start questions in the tool's window, Next / Stop / Resync / Settings / the input row off).
# Asking (bool: a question waits in the tool's window: the input row and the Up next menu off).
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
    Set-PanelProp 'linkbox' $q.LinkBox 'Text' $link
    if ($script:PanelLast['link'] -cne $link) { $script:PanelLast['link'] = $link; $q.Tips.SetToolTip($q.Copy, $link) }
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
    # The input row: off while the start questions or any other question waits in the console (Asking; the window's
    # answers come later): a line typed here meanwhile would only run after the question, as a new line.
    $inputOn = ($hasState -and -not [bool]$s['Prompt'] -and -not [bool]$s['Asking'])
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
    if ($script:PanelLast['inputtip'] -ne $inputOn) {
      $script:PanelLast['inputtip'] = $inputOn
      $t = ''
      if (-not $inputOn) { $t = T 'Answer in the console window for now.' }
      $q.Tips.SetToolTip($q.InputRow, $t)
    }
    if (-not $q.CueSet -and $q.CueTries -lt 50) { $q.CueTries++; Set-PanelCue }

    $st = [string]$s['Status']
    if ($script:PanelLast['status'] -cne $st) { $q.Tips.SetToolTip($q.Status, $st) }
    Set-PanelProp 'status' $q.Status 'Text' $st
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
    # (Settings: its stream items work only while nothing plays, see Update-PanelMenu; log.txt and End stream always.)
    Set-PanelProp 'more' $q.More 'Enabled' $cmdOn
    $q.CmdOn = $cmdOn

    $up = @()
    if ($null -ne $s['Upcoming']) { $up = @(foreach ($u in @($s['Upcoming'])) { [string]$u }) }
    $ids = @()
    if ($null -ne $s['UpcomingIds']) { $ids = @(foreach ($u in @($s['UpcomingIds'])) { [int]$u }) }
    if ($ids.Count -ne $up.Count) { $ids = @() }
    $upKey = ($up -join "`n") + "`n" + ($ids -join ',')
    if (-not $script:PanelLast.ContainsKey('up') -or $script:PanelLast['up'] -cne $upKey) {
      $script:PanelLast['up'] = $upKey
      # (The same line stays selected when the list changes around it: by its Id. The view stays scrolled where it
      # was too: a download's progress changes the texts every second or two.)
      $selId = Get-PanelListId
      $top = $q.List.TopIndex
      $q.ListIds = $ids
      $q.List.BeginUpdate()
      $q.List.Items.Clear()
      if ($up.Count -eq 0) { [void]$q.List.Items.Add((T 'Nothing queued yet')) }
      $n = 1
      foreach ($u in $up) { [void]$q.List.Items.Add(('{0}. {1}' -f $n, $u)); $n++ }
      if ($selId -gt 0) { $ix = [array]::IndexOf([int[]]$ids, $selId); if ($ix -ge 0) { $q.List.SelectedIndex = $ix } }
      if ($top -gt 0 -and $q.List.Items.Count -gt 0) { $q.List.TopIndex = [Math]::Min($top, $q.List.Items.Count - 1) }
      $q.List.EndUpdate()
    }

    Set-PanelProp 'clock' $q.Clock 'Checked' ([bool]$s['Clock'])

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
