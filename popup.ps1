# =====================================================================
#  popup notice - mass deploy edition (NetSupport / PDQ / GPO / psexec)
#  exit codes : 0 ok | 1 download failed | 2 already running | 3 session 0
# =====================================================================

# ---- ตั้งค่า log รวมศูนย์ : ใส่ UNC ที่ทุกเครื่องเขียนได้ ('' = ปิด) ----
$LOGUNC = ''      # ตัวอย่าง '\\SERVER\Logs$\popup'

$LOGLOCAL = Join-Path $env:TEMP 'popup-notice.log'
function Wlog {
    param([string]$m)
    $line = "{0}`t{1}`t{2}`t{3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME, $env:USERNAME, $m
    try { Add-Content -LiteralPath $LOGLOCAL -Value $line -Encoding UTF8 -ErrorAction Stop } catch {}
    if ($LOGUNC) {
        # 1 ไฟล์ต่อ 1 เครื่อง = ไม่ชนกันแม้รันพร้อมกันหลายร้อยเครื่อง
        try { Add-Content -LiteralPath (Join-Path $LOGUNC ("{0}.log" -f $env:COMPUTERNAME)) -Value $line -Encoding UTF8 -ErrorAction Stop } catch {}
    }
}

# ---- ต้องมี desktop จริง : ถ้าถูกสั่งรันเป็น SYSTEM/service จะไปโผล่ session 0 ----
if ((Get-Process -Id $PID).SessionId -eq 0) {
    Wlog 'ABORT session0 - no interactive desktop (client is running the command as SYSTEM)'
    [Environment]::Exit(3)
}

# ---- single instance lock : one machine = one running copy ----
$MTXNAME = 'PopupNotice_kfn_v1'
$isNew = $false
try   { $script:Mx = [Threading.Mutex]::new($true, "Global\$MTXNAME", [ref]$isNew) }
catch { $script:Mx = [Threading.Mutex]::new($true, "Local\$MTXNAME",  [ref]$isNew) }
if (-not $isNew) {
    Wlog 'BLOCKED - already running on this machine'
    Write-Host ''
    Write-Host '  [BLOCKED] มีหน้าต่างนี้รันอยู่แล้วในเครื่องนี้ - ยกเลิกการรันซ้ำ' -ForegroundColor Yellow
    Write-Host '            ปิดอันเดิมก่อน แล้วค่อยสั่งรันใหม่ได้' -ForegroundColor DarkGray
    Write-Host ''
    Start-Sleep -Seconds 2
    [Environment]::Exit(2)
}
Wlog 'START'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('WinApi.Dpi' -as [type])) {
    Add-Type -Namespace WinApi -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
}
if (-not ('WinApi.Fnt' -as [type])) {
    Add-Type -Namespace WinApi -Name Fnt -MemberDefinition '[DllImport("gdi32.dll", CharSet=CharSet.Unicode)] public static extern int AddFontResourceEx(string f, uint fl, System.IntPtr pdv);'
}
try { [void][WinApi.Dpi]::SetProcessDPIAware() } catch {}
[System.Windows.Forms.Application]::EnableVisualStyles()

$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$SECONDS   = 900
$FONTSIZE  = 15
$MAXRETRY  = 10
$RETRYWAIT = 3

$dir = Join-Path $env:TEMP 'popup-images'
New-Item -ItemType Directory -Path $dir -Force | Out-Null

$imgs = @(
  @{ File=(Join-Path $dir 'pic1.jpg')
     Url='https://raw.githubusercontent.com/kfngivkdvisdvmdkvn/icon/refs/heads/main/S__10608652.jpg' }
  @{ File=(Join-Path $dir 'pic2.png')
     Url='https://raw.githubusercontent.com/kfngivkdvisdvmdkvn/icon/refs/heads/main/%E0%B8%82%E0%B9%89%E0%B8%AD%E0%B8%84%E0%B8%A7%E0%B8%B2%E0%B8%A1%E0%B9%83%E0%B8%99%E0%B8%A2%E0%B9%88%E0%B8%AD%E0%B8%AB%E0%B8%99%E0%B9%89%E0%B8%B2%E0%B8%82%E0%B8%AD%E0%B8%87%E0%B8%84%E0%B8%B8%E0%B8%93.png' }
)

$script:PFC = $null
function Get-AppFont {
    param([single]$Size)
    $ttf  = Join-Path $dir 'Prompt-SemiBold.ttf'
    $urls = @(
        'https://raw.githubusercontent.com/google/fonts/main/ofl/prompt/Prompt-SemiBold.ttf'
        'https://raw.githubusercontent.com/google/fonts/main/ofl/prompt/Prompt-Bold.ttf'
        'https://raw.githubusercontent.com/google/fonts/main/ofl/prompt/Prompt-Medium.ttf'
    )
    $got = ((Test-Path -LiteralPath $ttf) -and ((Get-Item $ttf).Length -gt 20KB))
    if (-not $got) {
        foreach ($u in $urls) {
            try {
                Invoke-WebRequest -Uri $u -OutFile "$ttf.part" -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
                if ((Get-Item "$ttf.part").Length -gt 20KB) {
                    Move-Item -LiteralPath "$ttf.part" -Destination $ttf -Force
                    $got = $true; break
                }
            } catch { }
        }
    }
    if ($got) {
        try {
            [void][WinApi.Fnt]::AddFontResourceEx($ttf, 0x10, [IntPtr]::Zero)
            $script:PFC = [System.Drawing.Text.PrivateFontCollection]::new()
            $script:PFC.AddFontFile($ttf)
            $fam   = $script:PFC.Families[0]
            $style = [System.Drawing.FontStyle]::Regular
            if ($fam.IsStyleAvailable([System.Drawing.FontStyle]::Bold)) { $style = [System.Drawing.FontStyle]::Bold }
            Write-Host ("  [OK]  font : {0}" -f $fam.Name) -ForegroundColor Green
            return [System.Drawing.Font]::new($fam, $Size, $style)
        } catch {
            Write-Host ("  [WARN] Prompt font unusable : {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  [WARN] cannot download Prompt font" -ForegroundColor DarkYellow
    }
    foreach ($fb in @('Leelawadee UI','Tahoma','Segoe UI')) {
        $f = [System.Drawing.Font]::new($fb, $Size, [System.Drawing.FontStyle]::Bold)
        if ($f.Name -eq $fb) { Write-Host ("  [FB]  fallback font : {0}" -f $fb) -ForegroundColor DarkYellow; return $f }
        $f.Dispose()
    }
    return [System.Drawing.Font]::new('Segoe UI', $Size, [System.Drawing.FontStyle]::Bold)
}

function Test-ImageFile {
    param([string]$File)
    try {
        $b = [IO.File]::ReadAllBytes($File)
        if ($b.Length -lt 1024) { return $false }
        $ms = [IO.MemoryStream]::new($b); $im = [System.Drawing.Image]::FromStream($ms)
        $ok = ($im.Width -gt 0 -and $im.Height -gt 0); $im.Dispose(); $ms.Dispose(); return $ok
    } catch { return $false }
}

function Get-ImageComplete {
    param([string]$Url, [string]$File, [int]$MaxTry, [int]$Wait)
    for ($n = 1; $n -le $MaxTry; $n++) {
        try {
            $tmp = "$File.part"
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
            Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
            if (Test-ImageFile -File $tmp) {
                Move-Item -LiteralPath $tmp -Destination $File -Force
                Write-Host ("  [OK]  {0}  ({1:N0} KB)" -f (Split-Path $File -Leaf), ((Get-Item $File).Length/1KB)) -ForegroundColor Green
                return $true
            }
            throw 'incomplete / not an image'
        } catch {
            Write-Host ("  [{0}/{1}] {2} : {3}" -f $n, $MaxTry, (Split-Path $File -Leaf), $_.Exception.Message) -ForegroundColor DarkYellow
            if ($n -lt $MaxTry) { Start-Sleep -Seconds $Wait }
        }
    }
    Write-Host ("  [FAIL] {0} - skipped" -f (Split-Path $File -Leaf)) -ForegroundColor Red
    return $false
}

function Show-Popup {
    param([string]$Path, [int]$Seconds, [System.Drawing.Font]$Font)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $ms    = [IO.MemoryStream]::new($bytes)
    $src   = [System.Drawing.Image]::FromStream($ms)
    $wa    = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea

    $bar   = 52
    $ratio = [Math]::Min(($wa.Width * 0.90) / $src.Width, (($wa.Height - $bar) * 0.88) / $src.Height)
    if ($ratio -gt 1) { $ratio = 1 }
    $w = [int]($src.Width * $ratio); $h = [int]($src.Height * $ratio)

    $bmp = [System.Drawing.Bitmap]::new($w, $h)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode  = 'HighQualityBicubic'
    $g.SmoothingMode      = 'HighQuality'
    $g.PixelOffsetMode    = 'HighQuality'
    $g.CompositingQuality = 'HighQuality'
    $g.DrawImage($src, 0, 0, $w, $h)
    $g.Dispose(); $src.Dispose(); $ms.Dispose()

    $cw = [Math]::Max($w, 560)
    $state = @{ Reason = 'timeout'; Left = $Seconds }

    $form = [System.Windows.Forms.Form]::new()
    $form.FormBorderStyle = 'None'
    $form.StartPosition   = 'Manual'
    $form.Location        = [System.Drawing.Point]::new($wa.X, $wa.Y)
    $form.ClientSize      = [System.Drawing.Size]::new($cw, ($h + $bar))
    $form.TopMost         = $true
    $form.KeyPreview      = $true
    $form.BackColor       = [System.Drawing.Color]::FromArgb(17,17,20)

    $head = [System.Windows.Forms.Panel]::new()
    $head.Location  = [System.Drawing.Point]::new(0,0)
    $head.Size      = [System.Drawing.Size]::new($cw, $bar)
    $head.BackColor = [System.Drawing.Color]::FromArgb(17,17,20)
    $form.Controls.Add($head)

    $btn = [System.Windows.Forms.Button]::new()
    $btn.Text      = 'X'
    $btn.Location  = [System.Drawing.Point]::new(($cw - $bar), 0)
    $btn.Size      = [System.Drawing.Size]::new($bar, $bar)
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 0
    $btn.BackColor = [System.Drawing.Color]::FromArgb(214,48,48)
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.Font      = [System.Drawing.Font]::new('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
    $btn.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $btn.TabStop   = $false
    $head.Controls.Add($btn)

    $lbl = [System.Windows.Forms.Label]::new()
    $lbl.Location  = [System.Drawing.Point]::new(16, 0)
    $lbl.Size      = [System.Drawing.Size]::new(($cw - $bar - 26), $bar)
    $lbl.TextAlign = 'MiddleLeft'
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(255,214,90)
    $lbl.Font      = $Font
    $lbl.UseCompatibleTextRendering = $true
    $head.Controls.Add($lbl)

    $pb = [System.Windows.Forms.PictureBox]::new()
    $pb.Location = [System.Drawing.Point]::new([int](($cw - $w)/2), $bar)
    $pb.Size     = [System.Drawing.Size]::new($w, $h)
    $pb.SizeMode = 'Normal'
    $pb.Image    = $bmp
    $form.Controls.Add($pb)

    $ts0 = [TimeSpan]::FromSeconds($Seconds)
    $lbl.Text = ("ปิดอัตโนมัติใน {0:00}:{1:00}      กด X เพื่อปิดทันที" -f $ts0.Minutes, $ts0.Seconds)

    $timer = [System.Windows.Forms.Timer]::new()
    $timer.Interval = 1000
    $timer.Add_Tick({
        param($s,$e)
        $state.Left = $state.Left - 1
        if ($state.Left -le 0) { $timer.Stop(); $form.Close(); return }
        $ts = [TimeSpan]::FromSeconds($state.Left)
        $lbl.Text = ("ปิดอัตโนมัติใน {0:00}:{1:00}      กด X เพื่อปิดทันที" -f $ts.Minutes, $ts.Seconds)
        if ($state.Left -le 10) { $lbl.ForeColor = [System.Drawing.Color]::FromArgb(255,110,110) }
    }.GetNewClosure())

    $btn.Add_Click({ param($s,$e) $state.Reason='closed by user'; $timer.Stop(); $form.Close() }.GetNewClosure())
    $form.Add_KeyDown({ param($s,$e) if ($e.KeyCode -eq 'Escape') { $state.Reason='closed by Esc'; $timer.Stop(); $form.Close() } }.GetNewClosure())

    $drag  = @{ On=$false; X=0; Y=0 }
    $mdown = { param($s,$e) $drag.On=$true; $drag.X=$e.X; $drag.Y=$e.Y }.GetNewClosure()
    $mmove = { param($s,$e) if ($drag.On) { $form.Location = [System.Drawing.Point]::new(($form.Location.X + $e.X - $drag.X), ($form.Location.Y + $e.Y - $drag.Y)) } }.GetNewClosure()
    $mup   = { param($s,$e) $drag.On=$false }.GetNewClosure()
    $head.Add_MouseDown($mdown); $head.Add_MouseMove($mmove); $head.Add_MouseUp($mup)
    $lbl.Add_MouseDown($mdown);  $lbl.Add_MouseMove($mmove);  $lbl.Add_MouseUp($mup)

    $form.Add_Shown({ param($s,$e) $form.Activate(); $timer.Start() }.GetNewClosure())
    [void]$form.ShowDialog()

    $timer.Stop(); $timer.Dispose()
    $lbl.Font = $null
    $pb.Image = $null; $bmp.Dispose(); $form.Dispose()
    return $state.Reason
}

Write-Host ''
Write-Host '=== preparing files (nothing is shown until every file is complete) ===' -ForegroundColor Cyan
$appFont = Get-AppFont -Size $FONTSIZE

$ready = @()
foreach ($i in $imgs) {
    if (Get-ImageComplete -Url $i.Url -File $i.File -MaxTry $MAXRETRY -Wait $RETRYWAIT) { $ready += $i }
}

if ($ready.Count -eq 0) {
    Wlog 'FAIL - no image could be downloaded'
    Write-Host 'no image ready - nothing to show' -ForegroundColor Red
    [Environment]::Exit(1)
}

Wlog ("SHOW {0} image(s), {1} min each" -f $ready.Count, ($SECONDS/60))
Write-Host ("ready: {0} image(s) - {1} min each" -f $ready.Count, ($SECONDS/60)) -ForegroundColor Cyan
$last = $ready.Count - 1
for ($k = 0; $k -le $last; $k++) {
    $r = Show-Popup -Path $ready[$k].File -Seconds $SECONDS -Font $appFont
    Wlog ("IMG {0}/{1} {2}" -f ($k+1), $ready.Count, $r)
    Write-Host ("  [{0}/{1}] {2}" -f ($k+1), $ready.Count, $r) -ForegroundColor Yellow
    if ($k -eq $last) {
        Wlog 'DONE'
        $appFont.Dispose()
        if ($script:PFC) { $script:PFC.Dispose() }
        [Environment]::Exit(0)
    }
}
