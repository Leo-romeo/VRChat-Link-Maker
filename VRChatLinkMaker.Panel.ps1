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
    if ($s.Closed) { return $false }
    return (-not ($script:PanelRun -and $script:PanelRun.IsCompleted))
  } catch { return $false }
}

function Write-PanelError([string]$text) {
  $script:PanelError = $text
  if (Get-Command Write-LogLine -CommandType Function -ErrorAction SilentlyContinue) { Write-LogLine ('  (control window: ' + $text + ')') }
}

# Space / Left / Right / Shift+Left / Shift+Right while the window has focus. $true = the key was ours.
function Invoke-PanelKey([System.Windows.Forms.Keys]$keyData) {
  $p = $script:Panel
  if ($null -eq $p) { return $false }
  $K = [System.Windows.Forms.Keys]
  $code = $keyData -band $K::KeyCode
  $mods = $keyData -band $K::Modifiers
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
    Closed = $false; Link = ''; Mode = ''; RealPos = 0.0; PosText = ''; SeekDur = 0.0; SeekShown = 0.0; SeekOn = $false; SeekPx = -1
    Drag = $false; DragPos = 0.0; HoldPos = 0.0; HoldUntil = [DateTime]::MinValue
    StopArmedUntil = [DateTime]::MinValue; CopiedUntil = [DateTime]::MinValue
    PrevCheck = [DateTime]::MinValue; PrevTime = [DateTime]::MinValue; PrevMissing = [DateTime]::MinValue
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
  $fh = $p.Font.Height
  $k = $fh / 15.0
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
  $f.StartPosition = [System.Windows.Forms.FormStartPosition]::WindowsDefaultLocation
  $f.MinimumSize = New-Object System.Drawing.Size([int](540 * $k), [int](560 * $k))
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $f.Size = New-Object System.Drawing.Size([int](620 * $k), [int]([Math]::Min(760 * $k, [Math]::Max(560 * $k, $wa.Height - 60))))
  $f.SuspendLayout()

  $root = New-Object "$WF.TableLayoutPanel"
  $root.Dock = [System.Windows.Forms.DockStyle]::Fill
  $root.ColumnCount = 1
  $root.Padding = New-Object System.Windows.Forms.Padding([int](8 * $k))
  [void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  $rowSizes = @('Auto', 'P62', 'Auto', 'Auto', 'Auto', 'Auto', 'Auto', 'P38', 'Auto', 'Auto')
  $root.RowCount = $rowSizes.Count
  foreach ($r in $rowSizes) {
    if ($r -eq 'Auto') { [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) }
    else { [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, [single]$r.Substring(1)))) }
  }

  # Row 0: what the stream is doing + the title
  $top = New-PanelGrid 2 ($p.Bold.Height + 8)
  [void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
  [void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  $p.Badge = New-Object "$WF.Label"
  $p.Badge.AutoSize = $true
  $p.Badge.Font = $p.Small
  $p.Badge.Anchor = [System.Windows.Forms.AnchorStyles]::Left
  $p.Badge.Padding = New-Object System.Windows.Forms.Padding([int](6 * $k), [int](2 * $k), [int](6 * $k), [int](2 * $k))
  $p.Badge.Margin = New-Object System.Windows.Forms.Padding(2, 2, [int](6 * $k), 2)
  $p.Title = New-PanelLabel (T 'Nothing is playing') ($p.Bold.Height + 6) $p.Bold $null
  $top.Controls.Add($p.Badge, 0, 0)
  $top.Controls.Add($p.Title, 1, 0)
  $root.Controls.Add($top, 0, 0)

  # Row 1: the preview picture (what ffmpeg sends, refreshed about twice a second)
  $pv = New-Object "$WF.PictureBox"
  $pv.Dock = [System.Windows.Forms.DockStyle]::Fill
  $pv.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
  $pv.BackColor = $c.Black
  $pv.Margin = New-Object System.Windows.Forms.Padding(2, [int](4 * $k), 2, [int](4 * $k))
  $pv.MinimumSize = New-Object System.Drawing.Size(0, [int](120 * $k))
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
  $root.Controls.Add($pv, 0, 1)

  # Row 2: position, seek bar, duration
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
  $root.Controls.Add($time, 0, 2)

  # Row 3: transport buttons
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
  $root.Controls.Add($tr, 0, 3)

  # Rows 4-7: status, VRChat player, up next
  $p.Status = New-PanelLabel '' ($fh * 2 + 6) $null $null
  $p.Status.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
  $p.Status.Margin = New-Object System.Windows.Forms.Padding(2, [int](6 * $k), 2, 1)
  $root.Controls.Add($p.Status, 0, 4)
  # The VRChat player's state, and on the right what the stream carries (picture size, fps, bitrate, server).
  $pq = New-PanelGrid 2 ($fh + 6)
  [void]$pq.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  [void]$pq.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
  $p.Player = New-PanelLabel '' ($fh + 6) $null $c.Dim
  $p.Quality = New-Object "$WF.Label"
  $p.Quality.AutoSize = $true
  $p.Quality.Anchor = [System.Windows.Forms.AnchorStyles]::Right
  $p.Quality.ForeColor = $c.Dim
  $p.Quality.Margin = New-Object System.Windows.Forms.Padding([int](8 * $k), 1, 2, 1)
  $pq.Controls.Add($p.Player, 0, 0)
  $pq.Controls.Add($p.Quality, 1, 0)
  $root.Controls.Add($pq, 0, 5)
  $root.Controls.Add((New-PanelLabel (T 'Up next') ($p.Small.Height + 8) $p.Small $c.Dim), 0, 6)
  $lb = New-Object "$WF.ListBox"
  $lb.Dock = [System.Windows.Forms.DockStyle]::Fill
  $lb.IntegralHeight = $false
  $lb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $lb.BackColor = $c.Box
  $lb.ForeColor = $c.Text
  $lb.Margin = New-Object System.Windows.Forms.Padding(2, 0, 2, [int](4 * $k))
  $lb.MinimumSize = New-Object System.Drawing.Size(0, [int]($fh * 2.5))
  $p.List = $lb
  $root.Controls.Add($lb, 0, 7)

  # Row 8: add, viewer preview, copy link, resync
  $bot = New-PanelGrid 4 ([int]($fh * 2.7))
  $p.Add = New-PanelButton (T 'Add / search...') (T 'Add a video or a link, or search for one.') 'add' $null $null
  $p.Viewer = New-PanelButton (T 'Watch as viewers see it') (T 'Opens the real stream in a small player window, the way viewers get it (with their delay). Close it any time.') 'viewer' $null $null
  $p.Copy = New-PanelButton (T 'Copy link') '' '' $null $null
  $p.Copy.Add_Click({
    try {
      $q = $script:Panel
      if ($q.Link) {
        [System.Windows.Forms.Clipboard]::SetDataObject([string]$q.Link, $true, 5, 100)
        $q.Copy.Text = T 'Copied!'
        $q.CopiedUntil = [DateTime]::UtcNow.AddSeconds(1.5)
      }
    } catch {}
  })
  $p.Resync = New-PanelButton ([string][char]0x21BB + ' ' + (T 'Resync everyone')) (T 'Everyone''s player reconnects to the live picture, so all viewers are in sync again. The video waits for them.') 'resync' $null $p.Sym
  $p.CopyText = $p.Copy.Text
  # Settings that change the link or the picture: only while nothing plays (the questions come in the console window).
  $p.More = New-PanelButton ((T 'Settings') + ' ' + [char]0x25BE) (T 'Server, picture size, upload speed test, new link. Available while nothing plays; the questions appear in the console window.') '' $null $p.Sym
  $menu = New-Object "$WF.ContextMenuStrip"
  foreach ($it in @(@((T 'Where to stream (server)...'), 'host'), @((T 'Picture size...'), 'res'), @((T 'Upload speed test'), 'speedtest'), @((T 'New link...'), 'newlink'))) {
    $mi = New-Object "$WF.ToolStripMenuItem"
    $mi.Text = $it[0]
    $mi.Tag = $it[1]
    $mi.Add_Click({ try { Add-PanelCommand ([string]$this.Tag) } catch {} })
    [void]$menu.Items.Add($mi)
  }
  $p.Menu = $menu
  $p.More.Add_Click({ try { $q = $script:Panel; $q.Menu.Show($q.More, 0, $q.More.Height) } catch {} })
  $bot.ColumnCount = 5
  $bb = @($p.Add, $p.Viewer, $p.Copy, $p.Resync, $p.More)
  Set-PanelGridWidths $bot $bb ([int](24 * $k))
  foreach ($b in $bb) { $b.AutoEllipsis = $false }   # long translations wrap onto a second line
  $i = 0
  foreach ($b in $bb) { $bot.Controls.Add($b, $i, 0); $i++ }
  $root.Controls.Add($bot, 0, 8)

  # Row 9: checkboxes
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
  $root.Controls.Add($flow, 0, 9)

  $f.Controls.Add($root)
  $f.Add_KeyDown({
    param($sender, $e)
    try { if (Invoke-PanelKey $e.KeyData) { $e.Handled = $true; $e.SuppressKeyPress = $true } } catch {}
  })
  $f.Add_KeyUp({
    param($sender, $e)
    try { if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Space) { $e.Handled = $true; $e.SuppressKeyPress = $true } } catch {}
  })
  $f.Add_FormClosed({ try { $script:Panel.Closed = $true; $script:PanelSync.Closed = $true; Remove-PanelImage } catch {} })
  Add-PanelKeyHook $f
  $f.ResumeLayout($true)
  $f.ActiveControl = $p.Big
  Set-PanelMode 'off'
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
    $sync = [hashtable]::Synchronized(@{
      State = $null; Cmds = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]')
      Ready = $false; Closed = $false; ShowReq = $false; CloseReq = $false; Error = $null; Logged = $false
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
    $q.Form.Add_Shown({ try { $script:PanelSync.Ready = $true } catch {} })
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
  Update-PanelView $sync.State
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
  foreach ($x in @($q.Tips, $q.Font, $q.Bold, $q.Small, $q.Sym, $q.BigFont)) { try { if ($x) { $x.Dispose() } } catch {} }
  try { foreach ($x in $q.Brushes.Values) { $x.Dispose() } } catch {}
  $script:Panel = $null
}

# $s (from the main thread, $null before the first update): Mode ('content'|'paused'|'hold'|'waiting'|'reconnect'|
# 'off'), Title, Position, Duration (0 = unknown), Status, Player, Upcoming (string[]), Link, Clock (bool), CanSeek (bool).
function Update-PanelView($s) {
  try {
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

    Set-PanelMode $mode
    $title = [string]$s['Title']
    if (-not $title) { $title = T 'Nothing is playing' }
    if ($script:PanelLast['title'] -cne $title) { $q.Tips.SetToolTip($q.Title, $title) }
    Set-PanelProp 'title' $q.Title 'Text' $title

    $rel = ($canSeek -and ($mode -eq 'content' -or $mode -eq 'paused' -or $mode -eq 'hold'))
    foreach ($b in @($q.Back30, $q.Back10, $q.Fwd10, $q.Fwd30)) { Set-PanelProp ('en' + $b.GetHashCode()) $b 'Enabled' $rel }
    Set-PanelProp 'next' $q.Next 'Enabled' $on
    Set-PanelProp 'stop' $q.Stop 'Enabled' $on
    Set-PanelProp 'resync' $q.Resync 'Enabled' $on
    if ($q.StopArmedUntil -ne [DateTime]::MinValue -and ($now -ge $q.StopArmedUntil -or -not $on)) {
      $q.StopArmedUntil = [DateTime]::MinValue
      Reset-PanelStop
    }

    $link = [string]$s['Link']
    $q.Link = $link
    Set-PanelProp 'copy' $q.Copy 'Enabled' ([bool]$link)
    Set-PanelProp 'viewer' $q.Viewer 'Enabled' ([bool]$link)
    if ($script:PanelLast['link'] -cne $link) { $script:PanelLast['link'] = $link; $q.Tips.SetToolTip($q.Copy, $link) }
    if ($q.CopiedUntil -ne [DateTime]::MinValue -and $now -ge $q.CopiedUntil) { $q.CopiedUntil = [DateTime]::MinValue; $q.Copy.Text = $q.CopyText }

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
    if ($script:PanelLast['qtip'] -cne [string]$s['QualityTip']) { $script:PanelLast['qtip'] = [string]$s['QualityTip']; $q.Tips.SetToolTip($q.Quality, [string]$s['QualityTip']) }
    Set-PanelProp 'more' $q.More 'Enabled' ($mode -eq 'waiting')

    $up = @()
    if ($null -ne $s['Upcoming']) { $up = @(foreach ($u in @($s['Upcoming'])) { [string]$u }) }
    $upKey = $up -join "`n"
    if (-not $script:PanelLast.ContainsKey('up') -or $script:PanelLast['up'] -cne $upKey) {
      $script:PanelLast['up'] = $upKey
      $q.List.BeginUpdate()
      $q.List.Items.Clear()
      if ($up.Count -eq 0) { [void]$q.List.Items.Add((T 'Nothing queued yet')) }
      $n = 1
      foreach ($u in $up) { [void]$q.List.Items.Add(('{0}. {1}' -f $n, $u)); $n++ }
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
