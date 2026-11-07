[CmdletBinding()]
param([string]$IconPath = "")

# IR Camera Viewer

Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null
Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -AssemblyName System.Drawing | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class IRProc {
  public static int Mean(byte[] b){ long s=0; for(int i=0;i<b.Length;i+=4){ s+=b[i]; } int n=b.Length/4; if(n<1)n=1; return (int)(s/n); }
  public static void Stretch(byte[] b){
    int min=255,max=0; for(int i=0;i<b.Length;i+=4){ int v=b[i]; if(v<min)min=v; if(v>max)max=v; }
    int range=max-min; if(range<1)range=1; double s=255.0/range;
    for(int i=0;i<b.Length;i+=4){ int v=(int)((b[i]-min)*s); if(v<0)v=0; if(v>255)v=255; byte g=(byte)v; b[i]=g; b[i+1]=g; b[i+2]=g; b[i+3]=255; }
  }
  public static byte[] BuildLut(int brightness, double contrast, double gamma){
    byte[] lut=new byte[256]; double invg=1.0/gamma;
    for(int i=0;i<256;i++){ double v=(i-128)*contrast + 128 + brightness; if(v<0)v=0; if(v>255)v=255; v=255.0*Math.Pow(v/255.0, invg);
      int r=(int)Math.Round(v); if(r<0)r=0; if(r>255)r=255; lut[i]=(byte)r; } return lut;
  }
  public static void ApplyLut(byte[] b, byte[] lut){ for(int i=0;i<b.Length;i+=4){ byte g=lut[b[i]]; b[i]=g; b[i+1]=g; b[i+2]=g; b[i+3]=255; } }
  [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
  public static void DarkTitleBar(IntPtr h, bool dark){ int v=dark?1:0; try{ if(DwmSetWindowAttribute(h,20,ref v,4)!=0) DwmSetWindowAttribute(h,19,ref v,4); }catch{} }
}
"@

$genAsTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
$actAsTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } | Select-Object -First 1
function Await($op,$t){ $x=$genAsTask.MakeGenericMethod($t).Invoke($null,@($op)); $x.Wait(-1)|Out-Null; $x.Result }
function AwaitAction($op){ $x=$actAsTask.Invoke($null,@($op)); $x.Wait(-1)|Out-Null }

[void][Windows.Media.Capture.MediaCapture,Windows.Media,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.MediaCaptureInitializationSettings,Windows.Media,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.Frames.MediaFrameSourceGroup,Windows.Media,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.Frames.MediaFrameReader,Windows.Media,ContentType=WindowsRuntime]
[void][Windows.Graphics.Imaging.SoftwareBitmap,Windows.Graphics.Imaging,ContentType=WindowsRuntime]
[void][Windows.Storage.Streams.Buffer,Windows.Storage.Streams,ContentType=WindowsRuntime]

$IR = [Windows.Media.Capture.Frames.MediaFrameSourceKind]::Infrared
$script:ffmpeg = $null
$gc = Get-Command ffmpeg -ErrorAction SilentlyContinue
if($gc){ $script:ffmpeg = $gc.Source } else { $c = "$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffmpeg.exe"; if(Test-Path $c){ $script:ffmpeg = $c } }

# ---------- open IR camera ----------
try {
  $groups = Await ([Windows.Media.Capture.Frames.MediaFrameSourceGroup]::FindAllAsync()) ([System.Collections.Generic.IReadOnlyList[Windows.Media.Capture.Frames.MediaFrameSourceGroup]])
  $grp=$null
  foreach($g in $groups){ if($g.DisplayName -eq 'Integrated IR Camera'){ $grp=$g; break } }
  if(-not $grp){ foreach($g in $groups){ foreach($si in $g.SourceInfos){ if($si.SourceKind -eq $IR){ $grp=$g; break } }; if($grp){break} } }
  if(-not $grp){ [System.Windows.Forms.MessageBox]::Show("No infrared camera was found on this device.","IR Camera Viewer") | Out-Null; return }
  $settings = New-Object Windows.Media.Capture.MediaCaptureInitializationSettings
  $settings.SourceGroup = $grp
  $settings.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
  $settings.MemoryPreference = [Windows.Media.Capture.MediaCaptureMemoryPreference]::Cpu
  $settings.SharingMode = [Windows.Media.Capture.MediaCaptureSharingMode]::ExclusiveControl
  $mc = New-Object Windows.Media.Capture.MediaCapture
  try { AwaitAction ($mc.InitializeAsync($settings)) }
  catch { $settings.SharingMode=[Windows.Media.Capture.MediaCaptureSharingMode]::SharedReadOnly; $mc=New-Object Windows.Media.Capture.MediaCapture; AwaitAction ($mc.InitializeAsync($settings)) }
  $src=$null
  foreach($kv in $mc.FrameSources){ if($kv.Value.Info.SourceKind -eq $IR){ $src=$kv.Value; break } }
  $reader = Await ($mc.CreateFrameReaderAsync($src)) ([Windows.Media.Capture.Frames.MediaFrameReader])
  $null = Await ($reader.StartAsync()) ([Windows.Media.Capture.Frames.MediaFrameReaderStartStatus])
}
catch {
  $d=$_.Exception; while($d.InnerException){ $d=$d.InnerException }
  $hr = try { '0x{0:X8}' -f $d.HResult } catch { '' }
  [System.Windows.Forms.MessageBox]::Show("Could not open the IR camera.`n$hr $($d.Message)`n`nIf the message mentions a reboot, restart Windows and try again.","IR Camera Viewer") | Out-Null
  return
}

# ---------- state ----------
$script:mirror=$true; $script:filter=$true; $script:stretch=$true
$script:peak=0.0; $script:zoom=1.0; $script:lastBmp=$null
$script:lut=[IRProc]::BuildLut(0,1.0,1.0)
$script:W=0; $script:H=0
$script:recording=$false; $script:rec=$null; $script:recPath=""; $script:recStart=[datetime]::Now
$script:fs=$false
$script:msg=$null; $script:msgUntil=[datetime]::MinValue
$script:btns = New-Object System.Collections.ArrayList

# ---------- themes ----------
function C($r,$g,$b){ [System.Drawing.Color]::FromArgb($r,$g,$b) }
$script:themes = @{
  dark  = @{ Bg=(C 14 14 16);   Bar=(C 22 22 26);   Text=(C 240 240 245); Muted=(C 130 130 140); Btn=(C 36 36 42);   Hover=(C 50 50 58);   Accent=(C 0 120 212); Rec=(C 220 50 50); Border=(C 40 40 48) }
  light = @{ Bg=(C 245 245 247); Bar=(C 255 255 255); Text=(C 30 30 35);   Muted=(C 110 110 120); Btn=(C 235 235 240); Hover=(C 220 220 228); Accent=(C 0 102 204); Rec=(C 220 50 50); Border=(C 220 220 225) }
}
$script:themeName = 'dark'
$settingsFile = Join-Path $env:APPDATA 'IRCameraViewer\theme.txt'
try { if(Test-Path $settingsFile){ $v=(Get-Content $settingsFile -ErrorAction Stop | Select-Object -First 1).Trim(); if($script:themes.ContainsKey($v)){ $script:themeName=$v } } } catch {}

# ---------- form ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = "IR Camera Viewer"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
$form.Width = 1000; $form.Height = 660; $form.MinimumSize = New-Object System.Drawing.Size(760, 460)
$form.StartPosition = 'CenterScreen'
$form.KeyPreview = $true
if($IconPath){ try { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($IconPath) } catch {} }

$pb = New-Object System.Windows.Forms.PictureBox
$pb.Dock='Fill'; $pb.SizeMode='Zoom'; $pb.BackColor=[System.Drawing.Color]::FromArgb(10,10,12)
$form.Controls.Add($pb)

function New-Btn($text,$w,[bool]$toggle){
  if($toggle){ $b=New-Object System.Windows.Forms.CheckBox; $b.Appearance='Button' } else { $b=New-Object System.Windows.Forms.Button }
  $b.Text=$text; $b.Width=$w; $b.Height=32; $b.Margin='0,0,6,0'; $b.FlatStyle='Flat'; $b.TextAlign='MiddleCenter'
  $b.TabStop=$false; $b.Cursor='Hand'; $b.FlatAppearance.BorderSize=1
  [void]$script:btns.Add($b)
  return $b
}

# ---------- bottom: image adjustments ----------
$ctrl = New-Object System.Windows.Forms.TableLayoutPanel
$ctrl.Dock='Bottom'; $ctrl.Height=64; $ctrl.ColumnCount=4; $ctrl.RowCount=1
[void]$ctrl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent,31)))
[void]$ctrl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent,31)))
[void]$ctrl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent,31)))
[void]$ctrl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute,96)))
[void]$ctrl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent,100)))

function New-Slider($min,$max,$val){
  $p=New-Object System.Windows.Forms.Panel; $p.Dock='Fill'; $p.Padding='12,6,12,4'
  $l=New-Object System.Windows.Forms.Label; $l.Dock='Top'; $l.Height=18; $l.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
  $tb=New-Object System.Windows.Forms.TrackBar; $tb.Dock='Fill'; $tb.Minimum=$min; $tb.Maximum=$max; $tb.Value=$val; $tb.TickStyle='None'
  $p.Controls.Add($tb); $p.Controls.Add($l)
  return @{ Panel=$p; Label=$l; Bar=$tb }
}
$sB = New-Slider -100 100 0
$sC = New-Slider -100 100 0
$sG = New-Slider 10 300 100
$tbB=$sB.Bar; $tbC=$sC.Bar; $tbG=$sG.Bar

$btnReset = New-Btn "Reset" 78 $false
$btnReset.Margin='0,0,0,0'; $btnReset.Dock='Fill'; $btnReset.Height=32
$resetPanel = New-Object System.Windows.Forms.Panel
$resetPanel.Dock='Fill'; $resetPanel.Padding='8,15,12,15'
$resetPanel.Controls.Add($btnReset)

$ctrl.Controls.Add($sB.Panel,0,0); $ctrl.Controls.Add($sC.Panel,1,0); $ctrl.Controls.Add($sG.Panel,2,0); $ctrl.Controls.Add($resetPanel,3,0)
$form.Controls.Add($ctrl)

# ---------- status bar ----------
$status = New-Object System.Windows.Forms.Panel
$status.Dock='Bottom'; $status.Height=26
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Dock='Fill'; $lblStatus.TextAlign='MiddleLeft'; $lblStatus.Padding='12,0,0,0'; $lblStatus.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$status.Controls.Add($lblStatus)
$form.Controls.Add($status)

# ---------- top toolbar ----------
$toolbar = New-Object System.Windows.Forms.Panel
$toolbar.Dock='Top'; $toolbar.Height=48
$flow = New-Object System.Windows.Forms.FlowLayoutPanel
$flow.Dock='Fill'; $flow.WrapContents=$false; $flow.Padding='10,8,0,0'
$btnSnap = New-Btn "Snapshot" 86 $false
$btnRec  = New-Btn "Record" 82 $false
$cbMirror  = New-Btn "Mirror" 70 $true;        $cbMirror.Checked=$true
$cbFilter  = New-Btn "Anti-flicker" 96 $true; $cbFilter.Checked=$true
$cbStretch = New-Btn "Auto-brighten" 104 $true; $cbStretch.Checked=$true
$btnZout = New-Btn "-" 34 $false
$btnZin  = New-Btn "+" 34 $false
$btnFS   = New-Btn "Fullscreen" 90 $false
$btnRec.Margin='0,0,6,0'; $btnZout.Margin='6,0,4,0'; $btnZin.Margin='0,0,6,0'
$flow.Controls.AddRange(@($btnSnap,$btnRec,$cbMirror,$cbFilter,$cbStretch,$btnZout,$btnZin,$btnFS))

$btnTheme = New-Btn "" 40 $false
$btnTheme.Dock='Right'; $btnTheme.Margin='0,0,0,0'; $btnTheme.Font = New-Object System.Drawing.Font("Segoe MDL2 Assets",11)
$themeHost = New-Object System.Windows.Forms.Panel
$themeHost.Dock='Right'; $themeHost.Width=56; $themeHost.Padding='8,8,8,8'
$themeHost.Controls.Add($btnTheme)

$toolbar.Controls.Add($flow)
$toolbar.Controls.Add($themeHost)
$form.Controls.Add($toolbar)

# ---------- theming ----------
function Style-Btn($b){
  $t=$script:themes[$script:themeName]
  $white=[System.Drawing.Color]::White
  if($b -eq $btnRec -and $script:recording){ $bg=$t.Rec; $fg=$white; $hv=$t.Rec; $bd=$t.Rec }
  elseif(($b -is [System.Windows.Forms.CheckBox]) -and $b.Checked){ $bg=$t.Accent; $fg=$white; $hv=$t.Accent; $bd=$t.Accent }
  else { $bg=$t.Btn; $fg=$t.Text; $hv=$t.Hover; $bd=$t.Border }
  $b.BackColor=$bg; $b.ForeColor=$fg
  $b.FlatAppearance.BorderColor=$bd
  $b.FlatAppearance.MouseOverBackColor=$hv; $b.FlatAppearance.MouseDownBackColor=$hv; $b.FlatAppearance.CheckedBackColor=$bg
}
function Theme-Control($c,$t){
  foreach($k in $c.Controls){
    if($k -is [System.Windows.Forms.ButtonBase]){ continue }
    $k.BackColor=$t.Bar; $k.ForeColor=$t.Text
    if($k.Controls.Count -gt 0){ Theme-Control $k $t }
  }
}
function Apply-Theme {
  $t=$script:themes[$script:themeName]
  $form.BackColor=$t.Bg; $form.ForeColor=$t.Text
  foreach($p in @($toolbar,$ctrl,$status)){ $p.BackColor=$t.Bar; $p.ForeColor=$t.Text; Theme-Control $p $t }
  $lblStatus.ForeColor=$t.Muted
  foreach($b in $script:btns){ Style-Btn $b }
  if($script:themeName -eq 'dark'){ $btnTheme.Text=[string][char]0xE706 } else { $btnTheme.Text=[string][char]0xE708 }
  if($form.IsHandleCreated){ [IRProc]::DarkTitleBar($form.Handle, ($script:themeName -eq 'dark')); $form.Refresh() }
}
function Toggle-Theme {
  if($script:themeName -eq 'dark'){ $script:themeName='light' } else { $script:themeName='dark' }
  Apply-Theme
  try { $dir=Split-Path $settingsFile; if(-not (Test-Path $dir)){ New-Item -ItemType Directory -Path $dir | Out-Null }; Set-Content -Path $settingsFile -Value $script:themeName } catch {}
}

# ---------- helpers ----------
function Refresh-Status {
  if($script:msg -and ([datetime]::Now -lt $script:msgUntil)){ $lblStatus.Text=$script:msg; return }
  if($script:W -gt 0){ $s = ("{0} x {1}    Zoom {2}x" -f $script:W,$script:H,[math]::Round($script:zoom,2)) } else { $s = "Starting camera..." }
  if($script:recording){ $el=[datetime]::Now - $script:recStart; $s += "    Recording " + $el.ToString('mm\:ss') }
  $lblStatus.Text=$s
}
function Show-Status($m){ $script:msg=$m; $script:msgUntil=[datetime]::Now.AddSeconds(4); Refresh-Status }
function Update-Lut {
  $b=$tbB.Value; $c=$tbC.Value; $g=$tbG.Value/100.0
  $contrastF=(259.0*($c+255))/(255.0*(259-$c))
  $script:lut=[IRProc]::BuildLut([int]($b*1.28),$contrastF,$g)
  $sB.Label.Text="Brightness: $b"; $sC.Label.Text="Contrast: $c"; $sG.Label.Text=("Gamma: {0:0.00}" -f $g)
}
function Reset-Adjust { $tbB.Value=0; $tbC.Value=0; $tbG.Value=100; Update-Lut }
function Take-Snapshot {
  if(-not $script:lastBmp){ return }
  $n=Join-Path ([Environment]::GetFolderPath('Desktop')) ("IR_snapshot_{0}.png" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
  $script:lastBmp.Save($n,[System.Drawing.Imaging.ImageFormat]::Png); Show-Status "Saved $n"
}
function Zoom-In  { $script:zoom=[math]::Min(5.0,$script:zoom+0.25); Refresh-Status }
function Zoom-Out { $script:zoom=[math]::Max(1.0,$script:zoom-0.25); Refresh-Status }
function Toggle-FS {
  if($script:fs){ $form.FormBorderStyle='Sizable'; $form.WindowState='Normal'; $toolbar.Visible=$true; $ctrl.Visible=$true; $status.Visible=$true; $script:fs=$false }
  else { $form.WindowState='Normal'; $form.FormBorderStyle='None'; $form.WindowState='Maximized'; $toolbar.Visible=$false; $ctrl.Visible=$false; $status.Visible=$false; $script:fs=$true }
}
function Toggle-Rec {
  if($script:recording){
    $script:recording=$false; $btnRec.Text="Record"
    try { $script:rec.StandardInput.Close() } catch {}; try { $script:rec.WaitForExit(4000) | Out-Null } catch {}
    $p=$script:recPath; $script:rec=$null; Style-Btn $btnRec; Show-Status "Saved $p"
  } else {
    if(-not $script:ffmpeg){ [System.Windows.Forms.MessageBox]::Show("Recording needs ffmpeg.`n`nInstall it with:  winget install Gyan.FFmpeg","IR Camera Viewer") | Out-Null; return }
    if($script:W -eq 0){ return }
    $script:recPath=Join-Path ([Environment]::GetFolderPath('Desktop')) ("IR_rec_{0}.mp4" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $psi=New-Object System.Diagnostics.ProcessStartInfo; $psi.FileName=$script:ffmpeg
    $psi.Arguments="-y -f rawvideo -pixel_format bgra -video_size $($script:W)x$($script:H) -framerate 15 -i - -c:v libx264 -preset veryfast -pix_fmt yuv420p `"$($script:recPath)`""
    $psi.RedirectStandardInput=$true; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $script:rec=[System.Diagnostics.Process]::Start($psi); $script:recStart=[datetime]::Now; $script:recording=$true; $btnRec.Text="Stop"; Style-Btn $btnRec
  }
  Refresh-Status
}

# ---------- events ----------
$tbB.Add_ValueChanged({ Update-Lut }); $tbC.Add_ValueChanged({ Update-Lut }); $tbG.Add_ValueChanged({ Update-Lut })
$btnReset.Add_Click({ Reset-Adjust })
$btnSnap.Add_Click({ Take-Snapshot }); $btnRec.Add_Click({ Toggle-Rec })
$btnZin.Add_Click({ Zoom-In }); $btnZout.Add_Click({ Zoom-Out }); $btnFS.Add_Click({ Toggle-FS })
$btnTheme.Add_Click({ Toggle-Theme })
$cbMirror.Add_CheckedChanged({ $script:mirror=$cbMirror.Checked; Style-Btn $cbMirror })
$cbFilter.Add_CheckedChanged({ $script:filter=$cbFilter.Checked; Style-Btn $cbFilter })
$cbStretch.Add_CheckedChanged({ $script:stretch=$cbStretch.Checked; Style-Btn $cbStretch })
$pb.Add_DoubleClick({ Toggle-FS })

$tt = New-Object System.Windows.Forms.ToolTip
$tt.SetToolTip($btnSnap,"Save a PNG to the Desktop (P)"); $tt.SetToolTip($btnRec,"Record an MP4 to the Desktop (R)")
$tt.SetToolTip($cbMirror,"Mirror (M)"); $tt.SetToolTip($cbFilter,"Drop the dark frames caused by the IR illuminator (F)"); $tt.SetToolTip($cbStretch,"Auto contrast (S)")
$tt.SetToolTip($btnZin,"Zoom in (+)"); $tt.SetToolTip($btnZout,"Zoom out (-)"); $tt.SetToolTip($btnFS,"Fullscreen (F11, Esc to exit)")
$tt.SetToolTip($btnTheme,"Dark / light mode (T)")

$form.Add_KeyDown({
  param($s,$e)
  $handled=$true
  switch($e.KeyCode){
    'P'{ Take-Snapshot } 'R'{ Toggle-Rec } 'F11'{ Toggle-FS } 'T'{ Toggle-Theme }
    'M'{ $cbMirror.Checked = -not $cbMirror.Checked } 'F'{ $cbFilter.Checked = -not $cbFilter.Checked } 'S'{ $cbStretch.Checked = -not $cbStretch.Checked }
    'Escape'{ if($script:fs){ Toggle-FS } else { $form.Close() } }
    'Oemplus'{ Zoom-In } 'Add'{ Zoom-In } 'OemMinus'{ Zoom-Out } 'Subtract'{ Zoom-Out }
    default { $handled=$false }
  }
  if($handled){ $e.SuppressKeyPress=$true; $e.Handled=$true }
})

$form.Add_Shown({ Apply-Theme })

# ---------- timers ----------
$statusTimer = New-Object System.Windows.Forms.Timer
$statusTimer.Interval = 500
$statusTimer.Add_Tick({ Refresh-Status })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 20
$timer.Add_Tick({
  try {
    $frame=$reader.TryAcquireLatestFrame(); if($frame -eq $null){ return }
    $vmf=$frame.VideoMediaFrame; if($vmf -eq $null){ $frame.Dispose(); return }
    $sb=$vmf.SoftwareBitmap; if($sb -eq $null){ $frame.Dispose(); return }
    $bgra=[Windows.Graphics.Imaging.SoftwareBitmap]::Convert($sb,[Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,[Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied)
    $w=$bgra.PixelWidth; $h=$bgra.PixelHeight; $len=$w*$h*4
    $buf=New-Object Windows.Storage.Streams.Buffer($len); $bgra.CopyToBuffer($buf)
    $bytes=[System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions]::ToArray($buf)
    $bgra.Dispose(); $frame.Dispose(); $script:W=$w; $script:H=$h
    if($script:filter){ $mean=[IRProc]::Mean($bytes); if($mean -gt $script:peak){ $script:peak=$mean } else { $script:peak=$script:peak*0.90 }; if($script:peak -lt 1){ $script:peak=1 }; if($mean -lt $script:peak*0.55){ return } }
    if($script:stretch){ [IRProc]::Stretch($bytes) }
    [IRProc]::ApplyLut($bytes,$script:lut)
    if($script:recording -and $script:rec -ne $null){ try { $script:rec.StandardInput.BaseStream.Write($bytes,0,$len) } catch {} }
    $bmp=New-Object System.Drawing.Bitmap($w,$h,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $rect=New-Object System.Drawing.Rectangle(0,0,$w,$h)
    $bd=$bmp.LockBits($rect,[System.Drawing.Imaging.ImageLockMode]::WriteOnly,$bmp.PixelFormat)
    [System.Runtime.InteropServices.Marshal]::Copy($bytes,0,$bd.Scan0,$len); $bmp.UnlockBits($bd)
    if($script:zoom -gt 1.0){
      $zw=[int]($w/$script:zoom); $zh=[int]($h/$script:zoom); $zx=[int](($w-$zw)/2); $zy=[int](($h-$zh)/2)
      $zb=New-Object System.Drawing.Bitmap($w,$h,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
      $gr=[System.Drawing.Graphics]::FromImage($zb); $gr.InterpolationMode=[System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
      $gr.DrawImage($bmp,(New-Object System.Drawing.Rectangle(0,0,$w,$h)),(New-Object System.Drawing.Rectangle($zx,$zy,$zw,$zh)),[System.Drawing.GraphicsUnit]::Pixel)
      $gr.Dispose(); $bmp.Dispose(); $bmp=$zb
    }
    if($script:mirror){ $bmp.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipX) }
    $old=$pb.Image; $pb.Image=$bmp; $script:lastBmp=$bmp; if($old){ $old.Dispose() }
  } catch {}
})

$form.Add_FormClosing({
  try { $timer.Stop() } catch {}
  try { $statusTimer.Stop() } catch {}
  if($script:recording){ try { $script:rec.StandardInput.Close(); $script:rec.WaitForExit(4000) | Out-Null } catch {} }
  try { $reader.StopAsync() | Out-Null } catch {}
  try { $mc.Dispose() } catch {}
})

Update-Lut
Apply-Theme
Refresh-Status
$statusTimer.Start()
$timer.Start()
[System.Windows.Forms.Application]::Run($form)