#Requires -Version 5.1
<#
========================================================================
 Adjust-Monitor.ps1   ——  显示器 DDC/CI 亮度 / 色温 调节工具
========================================================================
 干什么用的
   直接通过视频线（DDC/CI 协议）调节显示器「自己内部」的亮度、对比度、
   R/G/B 增益。用于把多块颜色不一致的显示器在视觉上对齐，不需要买校色仪。

 为什么需要它
   当两块屏的 Windows 设置、显示器 OSD 数值都完全一样时，颜色还是不同，
   那差异就来自面板本身（生产批次不同、累计点亮时长不同导致背光老化）。
   这种情况改设置没用，只能反过来「补偿」——把偏亮那块的亮度调低一点、
   把偏蓝那块的 B 增益调低一点，靠眼睛对齐。

 怎么用
   双击同目录的 3-Adjust.cmd
   或： .\Adjust-Monitor.ps1
   或： .\Adjust-Monitor.ps1 -SelfTest     只做自检，不弹全屏窗口
   或： .\Adjust-Monitor.ps1 -Restore      用最近一次快照还原所有显示器

 操作说明（全屏测试画面里按键）
   ↑ / ↓        亮度 +1 / -1
   ← / →        对比度 -1 / +1
   R             R 增益 -1      Shift+R  R 增益 +1
   G             G 增益 -1      Shift+G  G 增益 +1
   B             B 增益 -1      Shift+B  B 增益 +1
   按住 Ctrl    上面的每次步进变成 5（想快速大幅调整时用）
   W            切换测试底色：白 → 中灰 → 黑（白看色温，灰看伽马，黑看暗部）
   Tab / Shift+Tab   切换到另一块屏（也可以直接用鼠标点那块屏）
   Z            撤销上一步
   H            隐藏/显示屏幕上的文字（纯白对比时用）
   Esc          放弃本次全部改动，还原成开始前的值，退出
   Q            保留本次改动，退出

 安全性
   - 启动时会自动把当前所有值存成 snapshot-*.json，随时可以 -Restore 还原。
   - 只写显示器的亮度/对比度/RGB 增益，不动 Windows 和显卡的任何设置。
   - 不需要管理员权限。
========================================================================
#>
[CmdletBinding()]
param(
    [switch] $SelfTest,
    [switch] $Restore,
    [string] $SnapshotFile,
    [switch] $NoSnapshot,
    [switch] $SaveSnapshot
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Head([string]$t) {
    Write-Host ''
    Write-Host ('=' * 74) -ForegroundColor DarkCyan
    Write-Host ("  $t") -ForegroundColor Cyan
    Write-Host ('=' * 74) -ForegroundColor DarkCyan
}
function Write-Sub([string]$t) {
    Write-Host ''
    Write-Host ("-- $t " + ('-' * [Math]::Max(0, 68 - $t.Length))) -ForegroundColor DarkGray
}

# ======================================================================
# 1. DDC/CI 底层（P/Invoke）
# ======================================================================

$csSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class DdcApi
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szPhysicalMonitorDescription;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left; public int top; public int right; public int bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFOEX {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }

    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, IntPtr lprc, IntPtr data);

    [DllImport("user32.dll")]
    public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetMonitorInfoW")]
    public static extern bool GetMonitorInfo(IntPtr hMon, ref MONITORINFOEX mi);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMon, out uint count);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMon, uint count, [Out] PHYSICAL_MONITOR[] arr);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool DestroyPhysicalMonitors(uint count, [In] PHYSICAL_MONITOR[] arr);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr hMon, byte code, IntPtr type, out uint current, out uint max);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool SetVCPFeature(IntPtr hMon, byte code, uint value);

    public class DdcMon {
        public string Device = "";
        public string Desc = "";
        public string Error = "";
        public IntPtr Handle = IntPtr.Zero;
        public uint Count = 0;
        public PHYSICAL_MONITOR[] Arr = null;
    }

    // 打开所有显示器的 DDC/CI 通道并保持句柄有效，退出时用 Close() 释放
    public static DdcMon[] Open() {
        List<DdcMon> list = new List<DdcMon>();
        MonitorEnumProc cb = delegate(IntPtr hMon, IntPtr hdc, IntPtr lprc, IntPtr data) {
            MONITORINFOEX mi = new MONITORINFOEX();
            mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            mi.szDevice = "";
            GetMonitorInfo(hMon, ref mi);

            DdcMon m = new DdcMon();
            m.Device = mi.szDevice;
            m.Desc = mi.szDevice;

            uint count = 0;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, out count) || count == 0) {
                m.Error = "此显示器不支持 DDC/CI（或 OSD 里 DDC/CI 被关闭）";
                list.Add(m);
                return true;
            }
            PHYSICAL_MONITOR[] arr = new PHYSICAL_MONITOR[count];
            for (int i = 0; i < count; i++) arr[i].szPhysicalMonitorDescription = "";
            if (!GetPhysicalMonitorsFromHMONITOR(hMon, count, arr)) {
                m.Error = "GetPhysicalMonitorsFromHMONITOR 失败";
                list.Add(m);
                return true;
            }
            m.Count = count;
            m.Arr = arr;
            m.Handle = arr[0].hPhysicalMonitor;
            m.Desc = arr[0].szPhysicalMonitorDescription;
            list.Add(m);
            return true;
        };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, cb, IntPtr.Zero);
        return list.ToArray();
    }

    public static void Close(DdcMon[] mons) {
        if (mons == null) return;
        for (int i = 0; i < mons.Length; i++) {
            DdcMon m = mons[i];
            if (m.Arr != null && m.Count > 0) {
                try { DestroyPhysicalMonitors(m.Count, m.Arr); } catch { }
                m.Arr = null;
                m.Count = 0;
                m.Handle = IntPtr.Zero;
            }
        }
    }

    // 返回 -1 表示该项不支持。DDC/CI 是慢速易丢的通道，失败时重试几次。
    // 【重要】DXVA2 的物理显示器句柄是小整数伪句柄，合法值可能就是 0，
    //         所以绝对不能用 h == IntPtr.Zero 判定「无效」。
    //         调用方必须保证只对 DdcMon.Error 为空的显示器调用本方法。
    public static int GetVcp(IntPtr h, byte code, out int maxVal) {
        maxVal = -1;
        for (int attempt = 0; attempt < 3; attempt++) {
            try {
                uint cur = 0, mx = 0;
                if (GetVCPFeatureAndVCPFeatureReply(h, code, IntPtr.Zero, out cur, out mx)) {
                    maxVal = (int)mx;
                    return (int)cur;
                }
            } catch { }
            System.Threading.Thread.Sleep(70);
        }
        return -1;
    }

    // 同上：不要用句柄是否为 0 来判断有效性
    public static bool SetVcp(IntPtr h, byte code, int value) {
        try { return SetVCPFeature(h, code, (uint)value); }
        catch { return false; }
    }
}
'@

try {
    Add-Type -TypeDefinition $csSource -Language CSharp -ErrorAction Stop
} catch {
    Write-Host '内部组件编译失败：' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# VCP 代码：亮度 0x10  对比度 0x12  红增益 0x16  绿增益 0x18  蓝增益 0x1A
$script:ParamMap = [ordered]@{
    'brightness' = @{ Code = 0x10; Field = 'Brightness'; MaxField = 'BrightMax'; Label = '亮度' }
    'contrast'   = @{ Code = 0x12; Field = 'Contrast';   MaxField = 'ContrastMax'; Label = '对比度' }
    'gainr'      = @{ Code = 0x16; Field = 'GainR';      MaxField = 'GainMax';   Label = 'R增益' }
    'gaing'      = @{ Code = 0x18; Field = 'GainG';      MaxField = 'GainMax';   Label = 'G增益' }
    'gainb'      = @{ Code = 0x1A; Field = 'GainB';      MaxField = 'GainMax';   Label = 'B增益' }
}

# ======================================================================
# 2. 读取显示器当前状态
# ======================================================================

function Get-MonitorState {
    param([object[]]$DdcMons)

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($m in $DdcMons) {
        # 打开失败的显示器句柄不可用（而且 DXVA2 句柄 0 也可能是别的屏的合法句柄），
        # 必须直接跳过，绝不能拿它的句柄去读写。
        if ($m.Error) {
            $result.Add([pscustomobject]@{
                Device     = $m.Device
                Desc       = $m.Desc
                Handle     = $m.Handle
                Error      = $m.Error
                Brightness = -1; BrightMax = -1; Contrast = -1; ContrastMax = -1
                GainR = -1; GainG = -1; GainB = -1; GainMax = -1
                Preset = -1; UsageHours = -1
                Supported  = @{ brightness = $false; contrast = $false; gainr = $false; gaing = $false; gainb = $false }
                Start      = @{ brightness = -1; contrast = -1; gainr = -1; gaing = -1; gainb = -1 }
            })
            continue
        }

        $mx = 0
        $bri = [DdcApi]::GetVcp($m.Handle, [byte]0x10, [ref]$mx); $briMax = $mx
        $con = [DdcApi]::GetVcp($m.Handle, [byte]0x12, [ref]$mx); $conMax = $mx
        $gr  = [DdcApi]::GetVcp($m.Handle, [byte]0x16, [ref]$mx); $gMax = $mx
        $gg  = [DdcApi]::GetVcp($m.Handle, [byte]0x18, [ref]$mx)
        $gb  = [DdcApi]::GetVcp($m.Handle, [byte]0x1A, [ref]$mx)
        $pre = [DdcApi]::GetVcp($m.Handle, [byte]0x14, [ref]$mx)
        $use = [DdcApi]::GetVcp($m.Handle, [byte]0xC0, [ref]$mx)

        $result.Add([pscustomobject]@{
            Device      = $m.Device
            Desc        = $m.Desc
            Handle      = $m.Handle
            Error       = $m.Error
            Brightness  = $bri;  BrightMax   = $briMax
            Contrast    = $con;  ContrastMax = $conMax
            GainR       = $gr;   GainG = $gg;  GainB = $gb;  GainMax = $gMax
            Preset      = $pre
            UsageHours  = $use
            Supported   = @{
                brightness = ($bri -ge 0)
                contrast   = ($con -ge 0)
                gainr      = ($gr  -ge 0)
                gaing      = ($gg  -ge 0)
                gainb      = ($gb  -ge 0)
            }
            Start       = @{
                brightness = $bri
                contrast   = $con
                gainr      = $gr
                gaing      = $gg
                gainb      = $gb
            }
        })
    }
    return $result
}

function Show-MonitorTable {
    param($Mons)
    Write-Sub '检测到的显示器'
    $i = 0
    foreach ($m in $Mons) {
        $i++
        if ($m.Error) {
            Write-Host ("  [{0}] {1}   {2}" -f $i, $m.Device, $m.Error) -ForegroundColor DarkYellow
            continue
        }
        $use = if ($m.UsageHours -ge 0) { "   累计 $($m.UsageHours) 小时" } else { '' }
        Write-Host ("  [{0}] {1}{2}" -f $i, $m.Device, $use) -ForegroundColor White
        Write-Host ("      亮度 {0}/{1}   对比度 {2}   色彩预设 {3}   R增益 {4}  G增益 {5}  B增益 {6}" -f `
            $m.Brightness, $m.BrightMax, $m.Contrast, $m.Preset, $m.GainR, $m.GainG, $m.GainB)
    }
}

# ======================================================================
# 3. 快照：保存 / 还原
# ======================================================================

function Save-Snapshot {
    param($Mons, [string]$Reason)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($m in $Mons) {
        if ($m.Error) { continue }
        $list.Add([pscustomobject]@{
            Device     = $m.Device
            Brightness = $m.Brightness
            Contrast   = $m.Contrast
            GainR      = $m.GainR
            GainG      = $m.GainG
            GainB      = $m.GainB
        })
    }
    $obj = [ordered]@{
        ComputerName = $env:COMPUTERNAME
        SavedAt      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Reason       = $Reason
        Monitors     = $list.ToArray()
    }
    $file = Join-Path $ScriptDir ("snapshot-{0}-{1}.json" -f $env:COMPUTERNAME, (Get-Date).ToString('yyyyMMdd-HHmmss'))
    try {
        Set-Content -LiteralPath $file -Value ($obj | ConvertTo-Json -Depth 6) -Encoding UTF8
        return $file
    } catch {
        Write-Host ("快照保存失败：{0}" -f $_.Exception.Message) -ForegroundColor Red
        return $null
    }
}

function Invoke-Restore {
    param([string]$Path)

    if (-not $Path) {
        $latest = Get-ChildItem -LiteralPath $ScriptDir -Filter 'snapshot-*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) {
            Write-Host "在 $ScriptDir 里没有找到任何 snapshot-*.json 快照文件。" -ForegroundColor Yellow
            return
        }
        $Path = $latest.FullName
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "找不到快照文件：$Path" -ForegroundColor Red
        return
    }

    $snap = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Head '还原显示器设置'
    Write-Host ("  快照文件 : {0}" -f (Split-Path -Leaf $Path))
    Write-Host ("  保存时间 : {0}  ({1})" -f $snap.SavedAt, $snap.Reason)
    Write-Host ("  来自主机 : {0}" -f $snap.ComputerName)

    $ddcMons = @([DdcApi]::Open())
    try {
        $state = @(Get-MonitorState -DdcMons $ddcMons)
        $ok = 0; $fail = 0
        foreach ($item in @($snap.Monitors)) {
            $m = $state | Where-Object { $_.Device -eq $item.Device } | Select-Object -First 1
            if (-not $m -or $m.Error) {
                Write-Host ("  [跳过] {0} —— 当前未连接或读不到" -f $item.Device) -ForegroundColor DarkYellow
                $fail++
                continue
            }
            $pairs = @(
                @{ Code = 0x10; Value = $item.Brightness; Name = '亮度' }
                @{ Code = 0x12; Value = $item.Contrast;   Name = '对比度' }
                @{ Code = 0x16; Value = $item.GainR;      Name = 'R增益' }
                @{ Code = 0x18; Value = $item.GainG;      Name = 'G增益' }
                @{ Code = 0x1A; Value = $item.GainB;      Name = 'B增益' }
            )
            foreach ($p in $pairs) {
                if ($null -eq $p.Value -or $p.Value -lt 0) { continue }
                if ([DdcApi]::SetVcp($m.Handle, [byte]$p.Code, [int]$p.Value)) { $ok++ } else { $fail++ }
            }
            Write-Host ("  [完成] {0}  亮度={1} 对比度={2} R={3} G={4} B={5}" -f `
                $item.Device, $item.Brightness, $item.Contrast, $item.GainR, $item.GainG, $item.GainB) -ForegroundColor Green
        }
        Write-Host ''
        Write-Host ("  写入成功 {0} 项，失败 {1} 项" -f $ok, $fail) -ForegroundColor Cyan
    } finally {
        [DdcApi]::Close($ddcMons)
    }
}

# ======================================================================
# 4. 交互调节用的辅助函数（放在脚本作用域，供窗口事件调用）
# ======================================================================

function Update-DisplayOverlay {
    $st = $script:S
    for ($i = 0; $i -lt $st.Active.Count; $i++) {
        $lbl = $st.Labels[$i]
        $m = $st.Active[$i]
        if (-not $st.ShowOverlay) { $lbl.Text = ''; continue }
        if ($i -eq $st.Focus) {
            $use = if ($m.UsageHours -ge 0) { "    累计使用 $($m.UsageHours) 小时" } else { '' }
            $lines = @(
                ("屏幕 {0}/{1}   >>> 正在调节： {2}{3}" -f ($i + 1), $st.Active.Count, $m.Device, $use)
                ("亮度 {0}/{1}      对比度 {2}      R增益 {3}   G增益 {4}   B增益 {5}      (上限 {6})" -f `
                    $m.Brightness, $m.BrightMax, $m.Contrast, $m.GainR, $m.GainG, $m.GainB, $m.GainMax)
                ''
                '↑↓ 亮度      ←→ 对比度      R / Shift+R = R增益 减/增      G / Shift+G = G增益 减/增      B / Shift+B = B增益 减/增'
                '按住 Ctrl 每次步进=5      W 换底色(白/灰/黑)      Tab 换屏      Z 撤销      H 隐藏文字      Esc 全部还原退出      Q 保留退出'
            )
            $lbl.Text = ($lines -join "`r`n")
        } else {
            $lbl.Text = ("点击本屏即可切过来调节，或按 Tab 切换    当前屏幕： {0}" -f $m.Device)
        }
    }
}

function Set-TestBackground {
    $st = $script:S
    $bg = [System.Drawing.Color]::White
    $fg = [System.Drawing.Color]::Black
    switch ($st.BgIndex) {
        0 { $bg = [System.Drawing.Color]::White; $fg = [System.Drawing.Color]::Black }
        1 { $bg = [System.Drawing.Color]::FromArgb(128, 128, 128); $fg = [System.Drawing.Color]::Black }
        2 { $bg = [System.Drawing.Color]::Black; $fg = [System.Drawing.Color]::White }
    }
    foreach ($f in $st.Forms) { $f.BackColor = $bg }
    foreach ($l in $st.Labels) { $l.BackColor = $bg; $l.ForeColor = $fg }
    Update-DisplayOverlay
}

function Set-MonitorParam {
    param([int]$Idx, [string]$What, [int]$Delta)
    $st = $script:S
    if ($Idx -lt 0 -or $Idx -ge $st.Active.Count) { return }
    $m = $st.Active[$Idx]
    if (-not $m.Supported[$What]) { return }
    $pm = $script:ParamMap[$What]
    $fName = $pm.Field
    $mxName = $pm.MaxField
    $cur = [int]$m.$fName
    $mx = [int]$m.$mxName
    if ($mx -le 0) { $mx = 100 }
    $new = $cur + $Delta
    if ($new -lt 0) { $new = 0 }
    if ($new -gt $mx) { $new = $mx }
    if ($new -eq $cur) { return }
    if (-not [DdcApi]::SetVcp($m.Handle, [byte]$pm.Code, $new)) { return }
    $m.$fName = $new
    $st.Undo.Add([pscustomobject]@{ Mon = $m; What = $What; Field = $fName; From = $cur })
    Update-DisplayOverlay
}

function Undo-MonitorParam {
    $st = $script:S
    if ($st.Undo.Count -eq 0) { return }
    $u = $st.Undo[$st.Undo.Count - 1]
    $st.Undo.RemoveAt($st.Undo.Count - 1)
    $code = [byte]$script:ParamMap[$u.What].Code
    if ([DdcApi]::SetVcp($u.Mon.Handle, $code, [int]$u.From)) {
        $u.Mon.($u.Field) = $u.From
    }
    Update-DisplayOverlay
}

function Restore-AllMonitorParams {
    $st = $script:S
    foreach ($m in $st.Active) {
        foreach ($k in $script:ParamMap.Keys) {
            if (-not $m.Supported[$k]) { continue }
            $pm = $script:ParamMap[$k]
            $v = [int]$m.Start[$k]
            if ($v -lt 0) { continue }
            [void][DdcApi]::SetVcp($m.Handle, [byte]$pm.Code, $v)
            $m.($pm.Field) = $v
        }
    }
    $st.Undo.Clear()
    Update-DisplayOverlay
}

function Close-AllMonitorForms {
    $st = $script:S
    if ($st.Closing) { return }
    $st.Closing = $true
    foreach ($f in $st.Forms) { try { $f.Close() } catch { } }
}

# ======================================================================
# 5. 打开全屏测试画面并进入交互
# ======================================================================

function Start-AdjustGui {
    param($Mons, [switch]$NoShow)

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    $active = @($Mons | Where-Object { -not $_.Error })
    if ($active.Count -eq 0) { return $null }

    $script:S = @{
        Active      = $active
        Forms       = @()
        Labels      = @()
        Focus       = 0
        Undo        = New-Object System.Collections.Generic.List[object]
        BgIndex     = 0
        ShowOverlay = $true
        ExitAction  = 'keep'
        Closing     = $false
    }

    # ---- 键盘 ----
    $keyHandler = {
        param($sender, $e)
        $st = $script:S
        if ($st.Closing) { return }
        $idx = [int]$sender.Tag
        $step = 1
        if ($e.Control) { $step = 5 }
        $handled = $true
        switch ($e.KeyCode.ToString()) {
            'Up'     { Set-MonitorParam -Idx $idx -What 'brightness' -Delta $step }
            'Down'   { Set-MonitorParam -Idx $idx -What 'brightness' -Delta (-$step) }
            'Right'  { Set-MonitorParam -Idx $idx -What 'contrast'   -Delta $step }
            'Left'   { Set-MonitorParam -Idx $idx -What 'contrast'   -Delta (-$step) }
            'R'      { if ($e.Shift) { Set-MonitorParam -Idx $idx -What 'gainr' -Delta $step } else { Set-MonitorParam -Idx $idx -What 'gainr' -Delta (-$step) } }
            'G'      { if ($e.Shift) { Set-MonitorParam -Idx $idx -What 'gaing' -Delta $step } else { Set-MonitorParam -Idx $idx -What 'gaing' -Delta (-$step) } }
            'B'      { if ($e.Shift) { Set-MonitorParam -Idx $idx -What 'gainb' -Delta $step } else { Set-MonitorParam -Idx $idx -What 'gainb' -Delta (-$step) } }
            'W'      { $st.BgIndex = ($st.BgIndex + 1) % 3; Set-TestBackground }
            'H'      { $st.ShowOverlay = -not $st.ShowOverlay; Update-DisplayOverlay }
            'Z'      { Undo-MonitorParam }
            'Tab'    {
                $n = $st.Active.Count
                if ($n -gt 1) {
                    if ($e.Shift) { $st.Focus = ($st.Focus - 1 + $n) % $n } else { $st.Focus = ($st.Focus + 1) % $n }
                    try { $st.Forms[$st.Focus].Activate() } catch { }
                    Update-DisplayOverlay
                }
            }
            'Q'      { $st.ExitAction = 'keep';   Close-AllMonitorForms }
            'Escape' { Restore-AllMonitorParams; $st.ExitAction = 'revert'; Close-AllMonitorForms }
            default  { $handled = $false }
        }
        if ($handled) { $e.Handled = $true; $e.SuppressKeyPress = $true }
    }

    $clickHandler = {
        param($sender, $e)
        $st = $script:S
        if ($st.Closing) { return }
        if ($sender -is [System.Windows.Forms.Label]) { $st.Focus = [int]$sender.Parent.Tag }
        else { $st.Focus = [int]$sender.Tag }
        Update-DisplayOverlay
    }

    $closingHandler = {
        param($sender, $e)
        $st = $script:S
        if ($st.Closing) { return }
        # 用 Alt+F4 / 关闭按钮时，按「保留」处理
        $st.ExitAction = 'keep'
        Close-AllMonitorForms
    }

    # ---- 每个显示器一个全屏窗口 ----
    $screens = [System.Windows.Forms.Screen]::AllScreens
    for ($i = 0; $i -lt $active.Count; $i++) {
        $m = $active[$i]
        $screen = $screens | Where-Object { $_.DeviceName -eq $m.Device } | Select-Object -First 1
        if (-not $screen) { $screen = $screens[0] }

        $h = $screen.Bounds.Height
        $fontSize = [Math]::Max(9, [int]($h / 80))

        $form = New-Object System.Windows.Forms.Form
        $form.Text = $m.Device
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $form.Bounds = $screen.Bounds
        $form.BackColor = [System.Drawing.Color]::White
        $form.KeyPreview = $true
        $form.TopMost = $true
        $form.ShowInTaskbar = $false
        $form.Tag = $i

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Dock = [System.Windows.Forms.DockStyle]::Bottom
        $lbl.Height = [int]($h / 8)
        $lbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $lbl.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', $fontSize)
        $lbl.ForeColor = [System.Drawing.Color]::Black
        $lbl.BackColor = [System.Drawing.Color]::White
        $form.Controls.Add($lbl)

        $form.add_KeyDown($keyHandler)
        $form.add_Click($clickHandler)
        $lbl.add_Click($clickHandler)
        $form.add_FormClosing($closingHandler)

        $script:S.Forms += $form
        $script:S.Labels += $lbl
    }

    Set-TestBackground
    Update-DisplayOverlay

    # 自检路径：窗口全部组装好、事件已挂上、覆盖文字已生成，但不显示、直接销毁
    if ($NoShow) {
        foreach ($f in $script:S.Forms) { try { $f.Dispose() } catch { } }
        return $script:S
    }

    Write-Host ''
    Write-Host '即将打开全屏测试画面，请在两块屏上对照调整。' -ForegroundColor Cyan
    Write-Host '  Q = 保留退出      Esc = 全部还原退出' -ForegroundColor DarkGray
    Write-Host ''

    foreach ($f in $script:S.Forms) { $f.Show() }
    try { [void]$script:S.Forms[0].Activate() } catch { }
    [System.Windows.Forms.Application]::Run($script:S.Forms[0])

    return $script:S
}

# ======================================================================
# 6. 主流程
# ======================================================================

Write-Head "显示器 DDC/CI 调节工具   主机: $env:COMPUTERNAME"

# ---- -Restore 模式 ----
if ($Restore) {
    Invoke-Restore -Path $SnapshotFile
    Write-Host ''
    return
}

# ---- 打开 DDC 通道并读取状态 ----
$ddcMons = @([DdcApi]::Open())
$mons = @(Get-MonitorState -DdcMons $ddcMons)

try {
    Show-MonitorTable -Mons $mons

    $usable = @($mons | Where-Object { -not $_.Error })
    if ($usable.Count -eq 0) {
        Write-Host ''
        Write-Host '没有显示器响应 DDC/CI。可能原因：' -ForegroundColor Yellow
        Write-Host '  1) 显示器 OSD 菜单里 DDC/CI 被关闭了（通常在「设置 / 其他设置」里）'
        Write-Host '  2) 中间接了不支持 DDC/CI 的转接器（部分 KVM、HDMI 分配器）'
        Write-Host '  3) 显示器本身不支持 DDC/CI'
        Write-Host ''
        return
    }

    # ---- 只保存基线快照，不开窗口 ----
    if ($SaveSnapshot) {
        $f = Save-Snapshot -Mons $mons -Reason 'manual-baseline'
        if ($f) {
            Write-Host ''
            Write-Host ("已保存快照：{0}" -f (Split-Path -Leaf $f)) -ForegroundColor Green
            Write-Host ("完整路径：{0}" -f $f) -ForegroundColor DarkGray
        }
        return
    }

    # ---- SelfTest：验证读写通道与界面组件，不弹窗口 ----
    if ($SelfTest) {
        Write-Sub '自检（把当前值写回原值，画面不会有任何变化）'
        $pass = 0; $fail = 0
        foreach ($m in $usable) {
            if (-not $m.Supported['brightness']) { continue }
            $done = [DdcApi]::SetVcp($m.Handle, [byte]0x10, [int]$m.Brightness)
            $mx = 0
            $back = [DdcApi]::GetVcp($m.Handle, [byte]0x10, [ref]$mx)
            if ($done -and $back -eq $m.Brightness) {
                $pass++
                Write-Host ("  [通过] {0}  亮度写入 {1} 并回读一致" -f $m.Device, $m.Brightness) -ForegroundColor Green
            } else {
                $fail++
                Write-Host ("  [失败] {0}  写入={1} 回读={2}" -f $m.Device, $done, $back) -ForegroundColor Red
            }
        }
        # 完整组装真实的全屏窗口（含事件绑定与覆盖文字），但不显示、立即销毁
        try {
            $st2 = Start-AdjustGui -Mons $mons -NoShow
            $nForms = 0
            if ($st2 -and $st2.Forms) { $nForms = @($st2.Forms).Count }
            if ($nForms -gt 0) {
                $sample = $st2.Labels[0].Text
                if ([string]::IsNullOrEmpty($sample)) { throw '覆盖文字为空' }
                Write-Host ("  [通过] 全屏窗口组装正常（未显示）：{0} 个窗口，覆盖文字 {1} 字" -f $nForms, $sample.Length) -ForegroundColor Green
                $pass++
            } else {
                throw '没有构建出任何全屏窗口'
            }
        } catch {
            Write-Host ("  [失败] 界面组装异常：{0}" -f $_.Exception.Message) -ForegroundColor Red
            $fail++
        }
        Write-Host ''
        Write-Host ("自检结果：通过 {0} 项，失败 {1} 项" -f $pass, $fail) -ForegroundColor Cyan
        Write-Host ''
        return
    }

    # ---- 调节前存快照 ----
    if (-not $NoSnapshot) {
        $snapFile = Save-Snapshot -Mons $mons -Reason 'before-adjust'
        if ($snapFile) {
            Write-Host ''
            Write-Host ("已保存当前值快照：{0}" -f (Split-Path -Leaf $snapFile)) -ForegroundColor Green
            Write-Host '（万一调乱了：双击 4-Restore.cmd 即可一键还原）' -ForegroundColor DarkGray
        }
    }

    # ---- 进入交互调节 ----
    $st = Start-AdjustGui -Mons $mons

    if ($st) {
        Write-Head '本次调节结果'
        $changed = $false
        foreach ($m in $st.Active) {
            $diffs = @()
            foreach ($k in $script:ParamMap.Keys) {
                $pm = $script:ParamMap[$k]
                $fName = $pm.Field
                $now = [int]$m.$fName
                $before = [int]$m.Start[$k]
                if ($now -ne $before) { $diffs += ("{0} {1} → {2}" -f $pm.Label, $before, $now) }
            }
            if ($diffs.Count -gt 0) {
                $changed = $true
                Write-Host ("  {0}" -f $m.Device) -ForegroundColor White
                foreach ($d in $diffs) { Write-Host ("      {0}" -f $d) -ForegroundColor Yellow }
            } else {
                Write-Host ("  {0}   无改动" -f $m.Device) -ForegroundColor DarkGray
            }
        }

        Write-Host ''
        if ($st.ExitAction -eq 'revert') {
            Write-Host '已按 Esc：本次所有改动已还原成开始前的值。' -ForegroundColor Green
        } elseif ($changed) {
            Write-Host '改动已写入显示器并保留。若要还原：' -ForegroundColor Cyan
            Write-Host '  双击 4-Restore.cmd，或运行  .\Adjust-Monitor.ps1 -Restore' -ForegroundColor Cyan
        } else {
            Write-Host '本次没有做任何改动。' -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-Host '提示：多数显示器会自动记住 DDC/CI 的改动；若断电重启后发现没保留，' -ForegroundColor DarkGray
        Write-Host '      重跑一次即可，或用显示器菜单键进出一次以触发保存。' -ForegroundColor DarkGray
    }

} finally {
    [DdcApi]::Close($ddcMons)
}

Write-Host ''
