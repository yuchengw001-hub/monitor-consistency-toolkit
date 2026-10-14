#Requires -Version 5.1
<#
========================================================================
 Check-DisplayConsistency.ps1   ——  多显示器「一致性」检查工具
========================================================================
 用途
   逐台读取显示器的显示 / 色彩关键设置，自动找出不一致项，并给出处置建议。
   专门针对「同型号显示器看起来色温、颜色、亮度不一样」这类问题。

 为什么同型号也会不一样
   同型号 != 同颜色。同一批次的面板白点可以相差 200~400K、亮度差 5~10%；
   再加上 HDR 开关、输出动态范围(全/有限)、每屏 ICC 配置文件、显卡色彩
   微调、系统夜间模式等差异，肉眼就会明显看到两块屏颜色不同，长时间看
   容易头痛。

 用法
   .\Check-DisplayConsistency.ps1
        检查本机；屏幕打印报告，并在脚本同目录导出 JSON 报告。

   .\Check-DisplayConsistency.ps1 -Export D:\a.json
        指定报告导出路径。

   .\Check-DisplayConsistency.ps1 -Compare a.json b.json
        对比两份报告（用于另一台主机上的第三台同型号显示器）。

   .\Check-DisplayConsistency.ps1 -Compare auto
        自动挑出本文件夹里的两份 display-report-*.json 进行对比。
        平时不需要手敲命令：直接双击同目录的 1-Check.cmd / 2-Compare.cmd 即可。

   .\Check-DisplayConsistency.ps1 -Quiet
        只导出 JSON，不打印详细报告。

 说明
   - 不需要管理员权限。
   - 兼容 Windows PowerShell 5.1 与 PowerShell 7+。
========================================================================
#>
[CmdletBinding()]
param(
    [string]   $Export,
    [string[]] $Compare,
    [switch]   $Quiet
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ======================================================================
# 0. 常量 / 工具函数
# ======================================================================

$SCRIPT_VERSION = '1.0'

$OutputTechMap = @{
    0          = 'VGA'
    1          = 'S-Video'
    2          = 'Composite'
    3          = 'Component'
    4          = 'DVI'
    5          = 'HDMI'
    6          = 'LVDS'
    8          = 'D-Jpn'
    9          = 'SDI'
    10         = 'DisplayPort'
    11         = 'DisplayPort(内置)'
    12         = 'UDI'
    13         = 'UDI(内置)'
    14         = 'SDTV Dongle'
    15         = 'Miracast(无线)'
    16         = 'Indirect Wired'
    17         = 'Indirect Virtual'
    2147483648 = '内置屏'
}

$RotationMap = @{ 1 = '0°'; 2 = '90°'; 3 = '180°'; 4 = '270°' }

$ScalingMap = @{
    0 = '未指定'
    1 = '拉伸'
    2 = '居中'
    3 = '保持比例'
    4 = '自定义'
    5 = '首选'
}

function Write-Head([string]$text) {
    Write-Host ''
    Write-Host ('=' * 74) -ForegroundColor DarkCyan
    Write-Host ("  $text") -ForegroundColor Cyan
    Write-Host ('=' * 74) -ForegroundColor DarkCyan
}

function Write-Sub([string]$text) {
    Write-Host ''
    Write-Host ("-- $text " + ('-' * [Math]::Max(0, 68 - $text.Length))) -ForegroundColor DarkGray
}

function Format-Bool([bool]$v) { if ($v) { '是' } else { '否' } }

function Get-ScalePercent([uint32]$dpi) {
    if (-not $dpi -or $dpi -le 0) { return '' }
    return ('{0}%' -f [Math]::Round(100.0 * $dpi / 96.0))
}

# ======================================================================
# 1. 内嵌 C# —— 调用 Windows 显示配置 API / GDI
# ======================================================================

$csSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

public class DisplayProbe
{
    public const uint QDC_ONLY_ACTIVE_PATHS = 0x00000002;

    // ---------------- 结构体 ----------------
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RATIONAL { public uint Numerator; public uint Denominator; }

    [StructLayout(LayoutKind.Sequential)]
    public struct PATH_SOURCE_INFO {
        public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PATH_TARGET_INFO {
        public LUID adapterId; public uint id; public uint modeInfoIdx;
        public uint outputTechnology; public uint rotation; public uint scaling;
        public RATIONAL refreshRate; public uint scanLineOrdering;
        public int targetAvailable; public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PATH_INFO {
        public PATH_SOURCE_INFO sourceInfo;
        public PATH_TARGET_INFO targetInfo;
        public uint flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DEVICE_INFO_HEADER {
        public uint type; public uint size; public LUID adapterId; public uint id;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SOURCE_DEVICE_NAME {
        public DEVICE_INFO_HEADER header;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string viewGdiDeviceName;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct TARGET_DEVICE_NAME {
        public DEVICE_INFO_HEADER header;
        public uint flags;
        public uint outputTechnology;
        public ushort edidManufactureId;
        public ushort edidProductCodeId;
        public uint connectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string monitorFriendlyDeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string monitorDevicePath;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ADVANCED_COLOR_INFO { public DEVICE_INFO_HEADER header; public uint value; }

    [StructLayout(LayoutKind.Sequential)]
    public struct SDR_WHITE_LEVEL { public DEVICE_INFO_HEADER header; public uint SDRWhiteLevel; }

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

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "EnumDisplayDevicesW")]
    public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum,
        ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

    // ---------------- P/Invoke ----------------
    [DllImport("user32.dll")]
    public static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPath, out uint numMode);

    [DllImport("user32.dll")]
    public static extern int QueryDisplayConfig(uint flags, ref uint numPath,
        [Out] PATH_INFO[] paths, ref uint numMode, IntPtr modes, IntPtr topologyId);

    [DllImport("user32.dll")]
    public static extern int DisplayConfigGetDeviceInfo(ref SOURCE_DEVICE_NAME info);

    [DllImport("user32.dll")]
    public static extern int DisplayConfigGetDeviceInfo(ref TARGET_DEVICE_NAME info);

    [DllImport("user32.dll")]
    public static extern int DisplayConfigGetDeviceInfo(ref ADVANCED_COLOR_INFO info);

    [DllImport("user32.dll")]
    public static extern int DisplayConfigGetDeviceInfo(ref SDR_WHITE_LEVEL info);

    [DllImport("user32.dll")]
    public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetMonitorInfoW")]
    public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX info);

    [DllImport("shcore.dll")]
    public static extern int GetDpiForMonitor(IntPtr hMonitor, int dpiType, out uint dpiX, out uint dpiY);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [DllImport("gdi32.dll", CharSet = CharSet.Unicode, EntryPoint = "CreateDCW")]
    public static extern IntPtr CreateDC(string driver, string device, string port, IntPtr pdm);

    [DllImport("gdi32.dll")]
    public static extern bool DeleteDC(IntPtr hdc);

    [DllImport("gdi32.dll")]
    public static extern bool GetDeviceGammaRamp(IntPtr hdc, [Out] ushort[] ramp);

    [DllImport("gdi32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetICMProfileW")]
    public static extern bool GetICMProfile(IntPtr hdc, ref uint size, StringBuilder name);

    // ---------------- 结果类型 ----------------
    public class PathResult {
        public string GdiDeviceName = "";
        public string MonitorFriendlyName = "";
        public string MonitorDevicePath = "";
        public uint OutputTechnology;
        public uint Rotation;
        public uint Scaling;
        public uint RefreshNumerator;
        public uint RefreshDenominator;
        public bool TargetAvailable;
        public bool AcSupported;
        public bool AcEnabled;
        public bool WideColorEnforced;
        public bool AcForceDisabled;
        public uint SdrWhiteLevel = 4294967295u;
        public string Error = "";
    }

    public class MonitorResult {
        public string SzDevice = "";
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
        public bool Primary;
        public uint DpiX;
        public uint DpiY;
        public IntPtr HMonitor = IntPtr.Zero;
    }

    // 显示器内部硬件参数（通过 DDC/CI 从显示器直接读出）
    // 约定：读不到的项一律为 -1
    public class DdcInfo {
        public bool Ok;
        public string Error = "";
        public int Brightness = -1, BrightnessMax = -1;
        public int Contrast = -1, ContrastMax = -1;
        public int ColorPreset = -1, ColorPresetMax = -1;
        public int GainR = -1, GainG = -1, GainB = -1, GainMax = -1;
        public int BlackR = -1, BlackG = -1, BlackB = -1;
        public int Gamma = -1, GammaMax = -1;
        public int ColorTemp = -1;
        public int UsageHours = -1;
        public int InputSource = -1;
        public int VcpVersion = -1;
        public int FirmwareRaw = -1;
    }

    public class DcResult {
        public string GdiDeviceName = "";
        public string IcmProfile = "";
        public bool RampOk;
        public string RampHash = "";
        public uint RLow, RMid, RHigh;
        public uint GLow, GMid, GHigh;
        public uint BLow, BMid, BHigh;
        public string Error = "";
    }

    // ---------------- 方法 ----------------

    public static bool TrySetPerMonitorDpiAware() {
        try { return SetProcessDpiAwarenessContext(new IntPtr(-4)); }
        catch { return false; }
    }

    public static MonitorResult[] EnumMonitors() {
        List<MonitorResult> list = new List<MonitorResult>();
        MonitorEnumProc cb = delegate(IntPtr hMon, IntPtr hdc, IntPtr lprc, IntPtr data) {
            MONITORINFOEX mi = new MONITORINFOEX();
            mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            mi.szDevice = "";
            if (GetMonitorInfo(hMon, ref mi)) {
                MonitorResult r = new MonitorResult();
                r.SzDevice = mi.szDevice;
                r.Left = mi.rcMonitor.left;
                r.Top = mi.rcMonitor.top;
                r.Right = mi.rcMonitor.right;
                r.Bottom = mi.rcMonitor.bottom;
                r.Primary = ((mi.dwFlags & 1) != 0);
                r.HMonitor = hMon;
                uint dx, dy;
                if (GetDpiForMonitor(hMon, 0, out dx, out dy) == 0) {
                    r.DpiX = dx; r.DpiY = dy;
                }
                list.Add(r);
            }
            return true;
        };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, cb, IntPtr.Zero);
        return list.ToArray();
    }

    public static PathResult[] QueryPaths() {
        uint numPath, numMode;
        int err = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out numPath, out numMode);
        if (err != 0) throw new Exception("GetDisplayConfigBufferSizes 返回错误码 " + err);

        PATH_INFO[] paths = null;
        uint np = 0;
        uint nm = 0;
        IntPtr modes = IntPtr.Zero;
        try {
            for (int attempt = 0; attempt < 6; attempt++) {
                if (modes != IntPtr.Zero) { Marshal.FreeHGlobal(modes); modes = IntPtr.Zero; }
                np = numPath + 8;
                nm = numMode + 8;
                paths = new PATH_INFO[np];
                modes = Marshal.AllocHGlobal((int)nm * 64);
                err = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref np, paths, ref nm, modes, IntPtr.Zero);
                if (err == 0) break;
                if (err == 122) {
                    uint a, b;
                    GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out a, out b);
                    numPath = a; numMode = b;
                    continue;
                }
                throw new Exception("QueryDisplayConfig 返回错误码 " + err);
            }
            if (err != 0) throw new Exception("QueryDisplayConfig 反复返回错误码 " + err);

            List<PathResult> list = new List<PathResult>();
            for (int i = 0; i < (int)np; i++) {
                PATH_INFO p = paths[i];
                PathResult r = new PathResult();
                r.OutputTechnology = p.targetInfo.outputTechnology;
                r.Rotation = p.targetInfo.rotation;
                r.Scaling = p.targetInfo.scaling;
                r.RefreshNumerator = p.targetInfo.refreshRate.Numerator;
                r.RefreshDenominator = p.targetInfo.refreshRate.Denominator;
                r.TargetAvailable = (p.targetInfo.targetAvailable != 0);

                SOURCE_DEVICE_NAME sn = new SOURCE_DEVICE_NAME();
                sn.header.type = 1;
                sn.header.size = (uint)Marshal.SizeOf(typeof(SOURCE_DEVICE_NAME));
                sn.header.adapterId = p.sourceInfo.adapterId;
                sn.header.id = p.sourceInfo.id;
                sn.viewGdiDeviceName = "";
                if (DisplayConfigGetDeviceInfo(ref sn) == 0) r.GdiDeviceName = sn.viewGdiDeviceName;

                TARGET_DEVICE_NAME tn = new TARGET_DEVICE_NAME();
                tn.header.type = 2;
                tn.header.size = (uint)Marshal.SizeOf(typeof(TARGET_DEVICE_NAME));
                tn.header.adapterId = p.targetInfo.adapterId;
                tn.header.id = p.targetInfo.id;
                tn.monitorFriendlyDeviceName = "";
                tn.monitorDevicePath = "";
                if (DisplayConfigGetDeviceInfo(ref tn) == 0) {
                    r.MonitorFriendlyName = tn.monitorFriendlyDeviceName;
                    r.MonitorDevicePath = tn.monitorDevicePath;
                }

                ADVANCED_COLOR_INFO ac = new ADVANCED_COLOR_INFO();
                ac.header.type = 9;
                ac.header.size = (uint)Marshal.SizeOf(typeof(ADVANCED_COLOR_INFO));
                ac.header.adapterId = p.targetInfo.adapterId;
                ac.header.id = p.targetInfo.id;
                if (DisplayConfigGetDeviceInfo(ref ac) == 0) {
                    r.AcSupported = ((ac.value & 1) != 0);
                    r.AcEnabled = ((ac.value & 2) != 0);
                    r.WideColorEnforced = ((ac.value & 4) != 0);
                    r.AcForceDisabled = ((ac.value & 8) != 0);
                }

                SDR_WHITE_LEVEL sw = new SDR_WHITE_LEVEL();
                sw.header.type = 20;
                sw.header.size = (uint)Marshal.SizeOf(typeof(SDR_WHITE_LEVEL));
                sw.header.adapterId = p.targetInfo.adapterId;
                sw.header.id = p.targetInfo.id;
                if (DisplayConfigGetDeviceInfo(ref sw) == 0) r.SdrWhiteLevel = sw.SDRWhiteLevel;

                list.Add(r);
            }
            return list.ToArray();
        } finally {
            if (modes != IntPtr.Zero) Marshal.FreeHGlobal(modes);
        }
    }

    public class AdapterInfo {
        public string DeviceName = "";
        public string DeviceString = "";
        public int StateFlags;
    }

    public static AdapterInfo[] EnumAdapters() {
        List<AdapterInfo> list = new List<AdapterInfo>();
        for (uint i = 0; i < 32; i++) {
            DISPLAY_DEVICE d = new DISPLAY_DEVICE();
            d.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            d.DeviceName = ""; d.DeviceString = ""; d.DeviceID = ""; d.DeviceKey = "";
            if (!EnumDisplayDevices(null, i, ref d, 0)) break;
            AdapterInfo a = new AdapterInfo();
            a.DeviceName = d.DeviceName;
            a.DeviceString = d.DeviceString;
            a.StateFlags = d.StateFlags;
            list.Add(a);
        }
        return list.ToArray();
    }

    // ---------------- DDC/CI：直接读显示器内部硬件参数 ----------------
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szPhysicalMonitorDescription;
    }

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

    static int ReadVcp(IntPtr h, byte code, out int maxVal) {
        maxVal = -1;
        // DDC/CI 是慢速易丢的通道，失败时重试几次再判定为「不支持」
        for (int attempt = 0; attempt < 3; attempt++) {
            try {
                uint cur = 0, mx = 0;
                if (GetVCPFeatureAndVCPFeatureReply(h, code, IntPtr.Zero, out cur, out mx)) {
                    maxVal = (int)mx;
                    return (int)cur;
                }
            } catch { }
            System.Threading.Thread.Sleep(60);
        }
        return -1;
    }

    public static DdcInfo ProbeDdc(IntPtr hMonitor) {
        DdcInfo d = new DdcInfo();
        if (hMonitor == IntPtr.Zero) { d.Error = "无效的显示器句柄"; return d; }
        uint count = 0;
        if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hMonitor, out count) || count == 0) {
            d.Error = "此显示器不支持 DDC/CI";
            return d;
        }
        PHYSICAL_MONITOR[] arr = new PHYSICAL_MONITOR[count];
        for (int i = 0; i < count; i++) arr[i].szPhysicalMonitorDescription = "";
        if (!GetPhysicalMonitorsFromHMONITOR(hMonitor, count, arr)) {
            d.Error = "GetPhysicalMonitorsFromHMONITOR 失败";
            return d;
        }
        try {
            IntPtr h = arr[0].hPhysicalMonitor;
            int mx;
            d.Brightness  = ReadVcp(h, 0x10, out mx); d.BrightnessMax  = mx;
            d.Contrast    = ReadVcp(h, 0x12, out mx); d.ContrastMax    = mx;
            d.ColorPreset = ReadVcp(h, 0x14, out mx); d.ColorPresetMax = mx;
            d.GainR       = ReadVcp(h, 0x16, out mx); d.GainMax        = mx;
            d.GainG       = ReadVcp(h, 0x18, out mx);
            d.GainB       = ReadVcp(h, 0x1A, out mx);
            d.BlackR      = ReadVcp(h, 0x6C, out mx);
            d.BlackG      = ReadVcp(h, 0x6E, out mx);
            d.BlackB      = ReadVcp(h, 0x70, out mx);
            d.Gamma       = ReadVcp(h, 0x72, out mx); d.GammaMax       = mx;
            d.ColorTemp   = ReadVcp(h, 0x0C, out mx);
            d.UsageHours  = ReadVcp(h, 0xC0, out mx);
            d.InputSource = ReadVcp(h, 0x60, out mx);
            d.VcpVersion  = ReadVcp(h, 0xDF, out mx);
            d.FirmwareRaw = ReadVcp(h, 0xC9, out mx);
            d.Ok = (d.Brightness >= 0 || d.GainR >= 0);
        } catch (Exception ex) {
            d.Error = ex.Message;
        } finally {
            DestroyPhysicalMonitors(count, arr);
        }
        return d;
    }

    public static DcResult ProbeDC(string gdiName) {
        DcResult r = new DcResult();
        r.GdiDeviceName = gdiName;
        IntPtr hdc = IntPtr.Zero;
        try {
            hdc = CreateDC("DISPLAY", gdiName, null, IntPtr.Zero);
        } catch (Exception ex) {
            r.Error = "CreateDC 异常: " + ex.Message;
            return r;
        }
        if (hdc == IntPtr.Zero) { r.Error = "CreateDC 失败"; return r; }
        try {
            uint size = 520;
            StringBuilder sb = new StringBuilder(520);
            if (GetICMProfile(hdc, ref size, sb)) r.IcmProfile = sb.ToString();

            ushort[] ramp = new ushort[768];
            r.RampOk = GetDeviceGammaRamp(hdc, ramp);
            if (r.RampOk) {
                r.RLow = ramp[0];   r.RMid = ramp[128]; r.RHigh = ramp[255];
                r.GLow = ramp[256]; r.GMid = ramp[384]; r.GHigh = ramp[511];
                r.BLow = ramp[512]; r.BMid = ramp[640]; r.BHigh = ramp[767];
                byte[] bytes = new byte[1536];
                Buffer.BlockCopy(ramp, 0, bytes, 0, 1536);
                using (MD5 md5 = MD5.Create()) {
                    byte[] h = md5.ComputeHash(bytes);
                    StringBuilder hx = new StringBuilder();
                    for (int i = 0; i < h.Length; i++) hx.Append(h[i].ToString("x2"));
                    r.RampHash = hx.ToString().Substring(0, 12);
                }
            }
        } catch (Exception ex) {
            r.Error = ex.Message;
        } finally {
            DeleteDC(hdc);
        }
        return r;
    }
}
'@

try {
    Add-Type -TypeDefinition $csSource -Language CSharp -ErrorAction Stop
} catch {
    Write-Host "内部组件编译失败，脚本无法继续：" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# ======================================================================
# 2. -Compare 模式：只对比两份已有报告
# ======================================================================

function Invoke-Compare([string[]]$Paths) {
    if ($Paths.Count -ne 2) {
        Write-Host '用法: -Compare <报告A.json> <报告B.json>' -ForegroundColor Yellow
        Write-Host '  或: -Compare "<报告A.json>,<报告B.json>"' -ForegroundColor Yellow
        return
    }
    $reports = @()
    foreach ($p in $Paths) {
        if (-not (Test-Path -LiteralPath $p)) {
            Write-Host "找不到文件: $p" -ForegroundColor Red
            return
        }
        $reports += (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
    }

    $a = $reports[0]; $b = $reports[1]
    $da = @($a.Displays); $db = @($b.Displays)

    Write-Head '两台主机的显示器设置对比'
    Write-Host ("  A = {0}  （{1} 台显示器，检查于 {2}）" -f $a.ComputerName, $da.Count, $a.CheckedAt)
    Write-Host ("  B = {0}  （{1} 台显示器，检查于 {2}）" -f $b.ComputerName, $db.Count, $b.CheckedAt)

    $fields = @(
        @{ Key = 'Model';           Label = '型号';         Kind = '设置' }
        @{ Key = 'Serial';          Label = '序列号';       Kind = '固有' }
        @{ Key = 'MfgYear';         Label = '生产年份';     Kind = '固有' }
        @{ Key = 'MfgWeek';         Label = '生产周';       Kind = '固有' }
        @{ Key = 'Connection';      Label = '连接方式';     Kind = '注意' }
        @{ Key = 'Resolution';      Label = '分辨率';       Kind = '设置' }
        @{ Key = 'RefreshHz';       Label = '刷新率';       Kind = '注意' }
        @{ Key = 'ScalePercent';    Label = '缩放';         Kind = '设置' }
        @{ Key = 'Scaling';         Label = '显示缩放模式'; Kind = '设置' }
        @{ Key = 'HdrEnabled';      Label = 'HDR';          Kind = '设置' }
        @{ Key = 'SdrWhiteLevel';   Label = 'SDR白点';      Kind = '设置' }
        @{ Key = 'IccProfile';      Label = 'ICC 配置文件'; Kind = '设置' }
        @{ Key = 'RampHash';        Label = 'Gamma 指纹';   Kind = '设置' }
    )

    $anyDiff = $false
    $noticeCount = 0
    $inherentCount = 0
    $used = New-Object System.Collections.Generic.List[string]

    foreach ($d in $da) {
        # 1) 优先按序列号配对 —— 说明是同一块屏
        $match = $db | Where-Object {
            $_.Serial -and $_.Serial -eq $d.Serial -and -not $used.Contains("s:$($_.Serial)")
        } | Select-Object -First 1
        $pairKind = '序列号相同 = 同一块屏'

        # 2) 序列号配不上（两块不同的屏）：退化为按位置顺序配对，仍然可以比设置
        if (-not $match) {
            $match = $db | Where-Object { -not $used.Contains("i:$($_.Index)") } | Select-Object -First 1
            if ($match) { $pairKind = '序列号不同 = 两块不同的屏，按位置对应' }
        }

        Write-Sub ("A 的 {0}  {1} {2}   (SN {3})" -f $d.Index, $d.Manufacturer, $d.Model, $d.Serial)
        if (-not $match) {
            Write-Host '  B 主机上已没有可对应的显示器。' -ForegroundColor Yellow
            continue
        }

        $used.Add("i:$($match.Index)")
        if ($match.Serial) { $used.Add("s:$($match.Serial)") }

        Write-Host ("  对应 B 主机的 {0}  {1} {2}   (SN {3})" -f $match.Index, $match.Manufacturer, $match.Model, $match.Serial)
        Write-Host ("  配对方式: {0}" -f $pairKind) -ForegroundColor DarkGray
        if ($pairKind -like '序列号不同*') {
            Write-Host '  注意：这是两块不同的物理屏。设置可以比，但「面板本身」的颜色差异脚本测不出来。' -ForegroundColor DarkGray
        }

        foreach ($f in $fields) {
            $va = $d.($f.Key)
            $vb = $match.($f.Key)
            $sa = if ($null -eq $va) { '(空)' } else { "$va" }
            $sb = if ($null -eq $vb) { '(空)' } else { "$vb" }
            if ($sa -eq $sb) {
                Write-Host ("    [一致] {0,-14} {1}" -f $f.Label, $sa)
            } elseif ($f.Kind -eq '固有') {
                # 序列号 / 生产批次这类「本来就该不同」的项，不算问题
                $inherentCount++
                Write-Host ("    [固有] {0,-14} A={1}   B={2}" -f $f.Label, $sa, $sb) -ForegroundColor DarkGray
            } elseif ($f.Kind -eq '注意') {
                # 连接方式 / 刷新率：不是设置错误，但值得确认
                $noticeCount++
                Write-Host ("    [留意] {0,-14} A={1}   B={2}" -f $f.Label, $sa, $sb) -ForegroundColor DarkYellow
            } else {
                $anyDiff = $true
                Write-Host ("    [差异] {0,-14} A={1}   B={2}" -f $f.Label, $sa, $sb) -ForegroundColor Yellow
            }
        }
    }

    Write-Host ''
    if ($anyDiff) {
        Write-Host '结论：存在「设置类」差异，见上面标 [差异] 的项 —— 这些是应该统一的。' -ForegroundColor Yellow
    } else {
        Write-Host '结论：所有「设置类」项目完全一致。' -ForegroundColor Green
        if ($noticeCount -gt 0) {
            Write-Host ("      [留意] 类的 {0} 项不是设置错误：连接方式不同（DP/HDMI）时记得确认显卡输出" -f $noticeCount)
            Write-Host '      颜色格式为 RGB、动态范围为「完全」；刷新率 60 与 59.94 属同一档，可忽略。'
        }
        if ($inherentCount -gt 0) {
            Write-Host ("      [固有] 类的 {0} 项（序列号/生产批次）本来就该不同，不是问题。" -f $inherentCount)
        }
        Write-Host ''
        Write-Host '      既然设置已经一模一样，而肉眼仍觉得颜色不同，那差异就在面板本身' -ForegroundColor Cyan
        Write-Host '      （生产批次不同、使用时长不同导致的白点/亮度漂移）。设置层面已无可调，' -ForegroundColor Cyan
        Write-Host '      能做的只有两件事：' -ForegroundColor Cyan
        Write-Host '        ① 用 DDC/CI 分别微调各屏的 RGB 增益 / 亮度做视觉对齐（不需要买硬件）'
        Write-Host '        ② 用校色仪分别生成各屏的 ICC 配置文件（最彻底、最准）'
    }
    Write-Host ''
}

if ($Compare -and $Compare.Count -gt 0) {
    # 兼容 .cmd / -File 调用时把两份报告写成一个逗号分隔参数的情况
    if ($Compare.Count -eq 1 -and $Compare[0] -match '[,;]') {
        $Compare = @($Compare[0] -split '[,;]' |
            Where-Object { $_ -and $_.Trim() } |
            ForEach-Object { $_.Trim() })
    }

    # -Compare auto ：自动挑出本文件夹里的报告进行对比（无需拖文件）
    if ($Compare.Count -eq 1 -and $Compare[0] -eq 'auto') {
        $found = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'display-report-*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)

        if ($found.Count -lt 2) {
            Write-Host ''
            Write-Host ("本文件夹里只找到 {0} 份报告（display-report-*.json）。" -f $found.Count) -ForegroundColor Yellow
            Write-Host ''
            Write-Host '需要两份才能对比。请这样做：'
            Write-Host '  1) 在另一台电脑上也双击一次 1-Check.cmd，会生成它自己的 display-report-*.json'
            Write-Host '  2) 把那个 json 文件拷进本文件夹'
            Write-Host '  3) 再双击 2-Compare.cmd'
            Write-Host ''
            return
        }

        # 优先挑「两台不同电脑」的报告
        $first = $found[0]
        $firstPc = ''
        try { $firstPc = (Get-Content -LiteralPath $first.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).ComputerName } catch { }
        $second = $null
        if ($found.Count -gt 1) {
            foreach ($f in $found[1..($found.Count - 1)]) {
                $pc = ''
                try { $pc = (Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).ComputerName } catch { }
                if ($pc -and $pc -ne $firstPc) { $second = $f; break }
            }
            if (-not $second) { $second = $found[1] }
        }

        Write-Host ''
        Write-Host '自动选中这两份报告进行对比：' -ForegroundColor DarkGray
        Write-Host ("  A = {0}" -f $first.Name) -ForegroundColor DarkGray
        Write-Host ("  B = {0}" -f $second.Name) -ForegroundColor DarkGray
        $Compare = @($first.FullName, $second.FullName)
    }

    Invoke-Compare $Compare
    return
}

# ======================================================================
# 3. 采集数据
# ======================================================================

Write-Host ''
Write-Host '正在读取显示器配置…' -ForegroundColor DarkGray

[void][DisplayProbe]::TrySetPerMonitorDpiAware()

$monitors = @()
try { $monitors = [DisplayProbe]::EnumMonitors() } catch { }

$paths = @()
$pathError = ''
try { $paths = [DisplayProbe]::QueryPaths() } catch { $pathError = $_.Exception.Message }

# --- WMI：显示器型号 / 序列号 / EDID 连接方式 ---
$wmiId = @()
try {
    $wmiId = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop
} catch { }

$wmiConn = @()
try {
    $wmiConn = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -ErrorAction Stop
} catch { }

function Convert-NameArray($arr) {
    if (-not $arr) { return '' }
    $chars = $arr | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ }
    return (-join $chars)
}

# 把 WMI 的 InstanceName 规范化，便于和 QueryDisplayConfig 的设备路径对上
function Get-NormalizedMonitorKey([string]$raw) {
    if (-not $raw) { return '' }
    $s = $raw.ToUpperInvariant()
    $s = $s -replace '^\\\\\?\\', ''
    $s = $s -replace '\{.*$', ''
    $s = $s -replace '#', '\'
    $s = $s -replace '_0$', ''
    return $s.TrimEnd('\')
}

$wmiTable = @{}
foreach ($w in $wmiId) {
    $key = Get-NormalizedMonitorKey $w.InstanceName
    if (-not $key) { continue }
    $wmiTable[$key] = [pscustomobject]@{
        Model        = Convert-NameArray $w.UserFriendlyName
        Manufacturer = Convert-NameArray $w.ManufacturerName
        Serial       = Convert-NameArray $w.SerialNumberID
        ProductCode  = Convert-NameArray $w.ProductCodeID
        Week         = $w.WeekOfManufacture
        Year         = $w.YearOfManufacture
    }
}

$wmiConnTable = @{}
foreach ($c in $wmiConn) {
    $key = Get-NormalizedMonitorKey $c.InstanceName
    if ($key) { $wmiConnTable[$key] = $c.VideoOutputTechnology }
}

# --- 显卡 / 系统 ---
$gpus = @()
try { $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | Select-Object -ExpandProperty Name) } catch { }

# --- 显示适配器（含未接显示器的输出 / 虚拟显示驱动）---
$adapters = @()
try { $adapters = @([DisplayProbe]::EnumAdapters()) } catch { }

# --- 用户每屏缩放记录 ---
$perMon = @{}
try {
    $k = 'HKCU:\Control Panel\Desktop\PerMonitorSettings'
    if (Test-Path $k) {
        Get-ChildItem $k -ErrorAction SilentlyContinue | ForEach-Object {
            $v = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DpiValue
            $perMon[$_.PSChildName] = $v
        }
    }
} catch { }

# --- NVIDIA 驱动里记录过的显示器（含已拔掉的）---
$nvRecords = @()
try {
    $nv = 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\State\DisplayDatabase'
    if (Test-Path $nv) {
        $nvRecords = @(Get-ChildItem $nv -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -notmatch '^(ADAPTER|CONNECTOR|MSBDD|MSNIL)' } |
            Select-Object -ExpandProperty PSChildName)
    }
} catch { }

# --- 组装每台显示器的记录 ---
$displays = New-Object System.Collections.Generic.List[object]
$index = 0

$ordered = @()
if ($monitors.Count -gt 0) {
    $ordered = $monitors | Sort-Object SzDevice
} else {
    $ordered = $paths | Sort-Object GdiDeviceName | ForEach-Object {
        [pscustomobject]@{ SzDevice = $_.GdiDeviceName; Left = $null; Top = $null; Right = $null; Bottom = $null; Primary = $false; DpiX = 0; DpiY = 0 }
    }
}

foreach ($m in $ordered) {
    $index++
    $gdi = $m.SzDevice
    $p = $paths | Where-Object { $_.GdiDeviceName -eq $gdi } | Select-Object -First 1

    $wmiKey = ''
    if ($p) { $wmiKey = Get-NormalizedMonitorKey $p.MonitorDevicePath }
    $w = if ($wmiKey -and $wmiTable.ContainsKey($wmiKey)) { $wmiTable[$wmiKey] } else { $null }

    $connRaw = if ($p) { $p.OutputTechnology } else { $null }
    $connName = if ($null -ne $connRaw -and $OutputTechMap.ContainsKey([int]$connRaw)) {
        $OutputTechMap[[int]$connRaw]
    } elseif ($null -ne $connRaw) { "未知($connRaw)" } else { '(未知)' }

    $connWmi = if ($wmiKey -and $wmiConnTable.ContainsKey($wmiKey)) { $wmiConnTable[$wmiKey] } else { $null }
    if ($connWmi -and $OutputTechMap.ContainsKey([int]$connWmi)) {
        $connName = "$connName / EDID:$($OutputTechMap[[int]$connWmi])"
    }

    $dc = $null
    if ($gdi) { $dc = [DisplayProbe]::ProbeDC($gdi) }

    # DDC/CI：直接问显示器自己内部的硬件参数
    $ddc = $null
    if ($m.PSObject.Properties['HMonitor'] -and $m.HMonitor -ne [IntPtr]::Zero) {
        try { $ddc = [DisplayProbe]::ProbeDdc($m.HMonitor) } catch { $ddc = $null }
    }

    $refresh = ''
    if ($p -and $p.RefreshDenominator -gt 0) {
        $refresh = [Math]::Round($p.RefreshNumerator / $p.RefreshDenominator, 2)
    }

    $resW = if ($m.Right -ne $null) { $m.Right - $m.Left } else { $null }
    $resH = if ($m.Bottom -ne $null) { $m.Bottom - $m.Top } else { $null }
    $resolution = if ($resW) { "$resW x $resH" } else { '(未知)' }

    # 用序列号去匹配用户的每屏缩放记录
    $scaleHint = ''
    if ($w -and $w.Serial) {
        $hit = $perMon.Keys | Where-Object { $_ -like "*$($w.Serial)*" } | Select-Object -First 1
        if ($hit) { $scaleHint = "注册表 DpiValue=$($perMon[$hit])" }
    }

    $displays.Add([pscustomobject]@{
        Index             = $index
        GdiDeviceName     = $gdi
        Primary           = [bool]$m.Primary
        Model             = if ($w) { $w.Model } else { '' }
        Manufacturer      = if ($w) { $w.Manufacturer } else { '' }
        Serial            = if ($w) { $w.Serial } else { '' }
        MfgWeek           = if ($w) { $w.Week } else { $null }
        MfgYear           = if ($w) { $w.Year } else { $null }
        Connection        = $connName
        ConnectionRaw     = $connRaw
        Resolution        = $resolution
        ResolutionW       = $resW
        ResolutionH       = $resH
        RefreshHz         = $refresh
        Rotation          = if ($p -and $RotationMap.ContainsKey([int]$p.Rotation)) { $RotationMap[[int]$p.Rotation] } elseif ($p) { "$($p.Rotation)" } else { '' }
        Scaling           = if ($p -and $ScalingMap.ContainsKey([int]$p.Scaling)) { $ScalingMap[[int]$p.Scaling] } elseif ($p) { "$($p.Scaling)" } else { '' }
        DesktopPos        = if ($m.Left -ne $null) { "($($m.Left), $($m.Top))" } else { '' }
        Dpi               = [uint32]$m.DpiX
        ScalePercent      = Get-ScalePercent $m.DpiX
        ScaleHint         = $scaleHint
        HdrSupported      = if ($p) { [bool]$p.AcSupported } else { $false }
        HdrEnabled        = if ($p) { [bool]$p.AcEnabled } else { $false }
        WideColorEnforced = if ($p) { [bool]$p.WideColorEnforced } else { $false }
        HdrForceDisabled  = if ($p) { [bool]$p.AcForceDisabled } else { $false }
        SdrWhiteLevel     = if ($p -and $p.SdrWhiteLevel -ne 4294967295) { [uint32]$p.SdrWhiteLevel } else { $null }
        SdrNits           = if ($p -and $p.SdrWhiteLevel -ne 4294967295) { [Math]::Round($p.SdrWhiteLevel / 1000.0 * 80.0, 1) } else { $null }
        IccProfile        = if ($dc -and $dc.IcmProfile) { Split-Path -Leaf $dc.IcmProfile } else { '(未关联)' }
        IccProfilePath    = if ($dc) { $dc.IcmProfile } else { '' }
        RampOk            = if ($dc) { [bool]$dc.RampOk } else { $false }
        RampHash          = if ($dc) { $dc.RampHash } else { '' }
        RLow  = if ($dc) { $dc.RLow }  else { $null }
        RMid  = if ($dc) { $dc.RMid }  else { $null }
        RHigh = if ($dc) { $dc.RHigh } else { $null }
        GMid  = if ($dc) { $dc.GMid }  else { $null }
        BMid  = if ($dc) { $dc.BMid }  else { $null }
        # ---- DDC/CI：显示器内部硬件参数（-1 表示该项读不到）----
        DdcOk          = if ($ddc) { [bool]$ddc.Ok } else { $false }
        DdcError       = if ($ddc) { $ddc.Error } else { '未探测' }
        DdcBrightness  = if ($ddc) { $ddc.Brightness } else { $null }
        DdcBrightMax   = if ($ddc) { $ddc.BrightnessMax } else { $null }
        DdcContrast    = if ($ddc) { $ddc.Contrast } else { $null }
        DdcColorPreset = if ($ddc) { $ddc.ColorPreset } else { $null }
        DdcGainR       = if ($ddc) { $ddc.GainR } else { $null }
        DdcGainG       = if ($ddc) { $ddc.GainG } else { $null }
        DdcGainB       = if ($ddc) { $ddc.GainB } else { $null }
        DdcGainMax     = if ($ddc) { $ddc.GainMax } else { $null }
        DdcBlackR      = if ($ddc) { $ddc.BlackR } else { $null }
        DdcBlackG      = if ($ddc) { $ddc.BlackG } else { $null }
        DdcBlackB      = if ($ddc) { $ddc.BlackB } else { $null }
        DdcGamma       = if ($ddc) { $ddc.Gamma } else { $null }
        DdcColorTemp   = if ($ddc) { $ddc.ColorTemp } else { $null }
        DdcUsageHours  = if ($ddc) { $ddc.UsageHours } else { $null }
        DdcInputSource = if ($ddc) { $ddc.InputSource } else { $null }
        DdcVcpVersion  = if ($ddc) { $ddc.VcpVersion } else { $null }
        DdcFirmwareRaw = if ($ddc) { $ddc.FirmwareRaw } else { $null }
        Note              = if ($pathError) { "QueryDisplayConfig: $pathError" } else { '' }
    })
}

$osCaption = ''
try {
    $osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    if ($osInfo -and $osInfo.Caption) { $osCaption = [string]$osInfo.Caption }
} catch { $osCaption = '(读取失败)' }

$reportHT = New-Object System.Collections.Specialized.OrderedDictionary
try {
    $reportHT['ScriptVersion'] = [string]$SCRIPT_VERSION
    $reportHT['ComputerName']  = [string]$env:COMPUTERNAME
    $reportHT['UserName']      = [string]$env:USERNAME
    $reportHT['CheckedAt']     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $reportHT['OS']            = $osCaption
    $reportHT['GPUs']          = @($gpus | ForEach-Object { [string]$_ })
    $reportHT['Adapters']      = @($adapters | ForEach-Object { "$($_.DeviceName)|$($_.DeviceString)|$($_.StateFlags)" })
    $reportHT['NvidiaRecords'] = @($nvRecords | ForEach-Object { [string]$_ })
    # 注意：本环境下 PowerShell 5.1 对 @(泛型 List) 会抛 ArgumentException，
    #       所以这里一律用 .ToArray() 转成真正的数组。
    $reportHT['Displays']      = $displays.ToArray()
} catch {
    Write-Host ("构造报告对象失败: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

$report = [pscustomobject]$reportHT

# ======================================================================
# 4. 一致性判定
# ======================================================================

$findings = New-Object System.Collections.Generic.List[object]

function Add-Finding([string]$Level, [string]$Title, [string]$Detail, [string]$Advice) {
    $findings.Add([pscustomobject]@{ Level = $Level; Title = $Title; Detail = $Detail; Advice = $Advice })
}

if ($displays.Count -lt 2) {
    Add-Finding '提示' '只检测到一台显示器' "本机只有 $($displays.Count) 台活动显示器。" '多屏对比需要两台以上同时连接。'
} else {
    $hdrs    = @($displays | Select-Object -ExpandProperty HdrEnabled -Unique)
    $conns   = @($displays | ForEach-Object { ($_.Connection -split ' / ')[0] } | Select-Object -Unique)
    $resos   = @($displays | Select-Object -ExpandProperty Resolution -Unique)
    # 刷新率取整后再比较：59.94 与 60 属于同一档，不算差异
    $refr    = @($displays | ForEach-Object { [Math]::Round($_.RefreshHz) } | Select-Object -Unique)
    $scales  = @($displays | Select-Object -ExpandProperty ScalePercent -Unique)
    $icc     = @($displays | Select-Object -ExpandProperty IccProfile -Unique)
    $hashes  = @($displays | Where-Object { $_.RampOk } | Select-Object -ExpandProperty RampHash -Unique)
    $white   = @($displays | Select-Object -ExpandProperty SdrWhiteLevel -Unique)
    $wide    = @($displays | Select-Object -ExpandProperty WideColorEnforced -Unique)

    if ($hdrs.Count -gt 1) {
        Add-Finding '严重' 'HDR 开关不一致' `
            (($displays | ForEach-Object { "$($_.GdiDeviceName)=" + (Format-Bool $_.HdrEnabled) }) -join ', ') `
            '一台开 HDR、一台关闭，会造成极大的亮度与色彩差异。请到「设置 → 系统 → 显示 → HDR」把两台设成一致（办公场景建议都关）。'
    }
    if ($wide.Count -gt 1) {
        Add-Finding '严重' '广色域强制(wideColorEnforced)不一致' `
            (($displays | ForEach-Object { "$($_.GdiDeviceName)=" + (Format-Bool $_.WideColorEnforced) }) -join ', ') `
            '两台屏的色域模式不同，颜色会明显不同。请在显卡控制面板/系统显示设置中统一。'
    }
    if ($conns.Count -gt 1) {
        Add-Finding '严重' '连接方式不同' ($conns -join ' / ') `
            '同一块显卡用不同接口(如一台 DP、一台 HDMI)时，输出动态范围/色彩格式可能不同。请到「NVIDIA 控制面板 → 更改分辨率」逐台确认输出颜色格式为 RGB、动态范围为“完全”。'
    }
    if ($resos.Count -gt 1) {
        Add-Finding '注意' '分辨率不一致' ($resos -join ' / ') '分辨率不同会让文字大小与观感差异明显，请统一为显示器原生分辨率。'
    }
    if ($refr.Count -gt 1) {
        Add-Finding '注意' '刷新率不一致' (($refr | ForEach-Object { "$_ Hz" }) -join ' / ') '刷新率不同会造成观感差异，建议统一。'
    }
    if ($scales.Count -gt 1) {
        Add-Finding '注意' '缩放比例(DPI)不一致' ($scales -join ' / ') '缩放不同会让两台屏上文字大小不一致，频繁切换视线的调焦负担更大，建议统一。'
    }
    if ($icc.Count -gt 1) {
        Add-Finding '严重' 'ICC 配置文件不一致' ($icc -join ' / ') '两台屏加载的色彩配置文件不同，等于用不同标准解释同一份颜色数据。请统一，或各自加载针对本屏校正过的 ICC。'
    } else {
        $iccName = $icc[0]
        if ($iccName -match 'sRGB' -or $iccName -eq '(未关联)') {
            Add-Finding '严重' '两台屏都没有逐屏校正的 ICC' "两台当前都使用: $iccName" `
                '这是同型号面板颜色不一样的根本原因：系统没有对面板个体差异做任何补偿。要用校正仪分别生成两台各自的 ICC 并加载，才能真正做到颜色一致。'
        }
    }
    if ($hashes.Count -gt 1) {
        Add-Finding '严重' 'Gamma 曲线不一致（驱动层色彩调整不同）' (($displays | ForEach-Object { "$($_.GdiDeviceName)=$($_.RampHash)" }) -join ', ') `
            '说明至少有一台屏在系统/显卡层被施加了不同的色彩调整（ICC 的 vcgt 曲线、夜间模式、显卡色调设置等）。请检查「NVIDIA 控制面板 → 调整桌面颜色设置」逐台是否被单独改过，以及夜间模式开关。'
    }
    if ($white.Count -gt 1) {
        Add-Finding '严重' 'SDR 白点亮度不一致' (($displays | ForEach-Object { "$($_.GdiDeviceName)=$($_.SdrWhiteLevel)" }) -join ', ') `
            'SDR 内容的白点亮度不同，两台屏的“白”看起来亮度/色感就不同。检查是否有显示器开了 HDR 或做过单独的 SDR 亮度设置。'
    }
    if ($perMon.Count -gt 0 -and $displays.Count -gt 1) {
        $vals = @($displays | Where-Object { $_.ScaleHint } | ForEach-Object { $_.ScaleHint } | Select-Object -Unique)
        if ($vals.Count -gt 1) {
            Add-Finding '注意' '注册表中的每屏缩放记录不同' ($vals -join ' / ') '确认两台屏的缩放设置确实一致。'
        }
    }

    # ---------------- DDC/CI：显示器内部硬件参数比对 ----------------
    $ddcOk = @($displays | Where-Object { $_.DdcOk })
    if ($ddcOk.Count -ge 2) {
        $bri = @($ddcOk | Select-Object -ExpandProperty DdcBrightness -Unique)
        if ($bri.Count -gt 1) {
            Add-Finding '严重' '显示器内部亮度设置不一致（DDC/CI）' `
                (($ddcOk | ForEach-Object { "$($_.GdiDeviceName)=$($_.DdcBrightness)/$($_.DdcBrightMax)" }) -join ', ') `
                '这是显示器自己菜单里的亮度值。亮度不一致比色温不一致更容易引起眼睛疲劳，请先统一。'
        }
        $con = @($ddcOk | Select-Object -ExpandProperty DdcContrast -Unique)
        if ($con.Count -gt 1) {
            Add-Finding '注意' '显示器内部对比度设置不一致（DDC/CI）' `
                (($ddcOk | ForEach-Object { "$($_.GdiDeviceName)=$($_.DdcContrast)" }) -join ', ') '请统一。'
        }
        $gainR = @($ddcOk | Select-Object -ExpandProperty DdcGainR -Unique)
        $gainG = @($ddcOk | Select-Object -ExpandProperty DdcGainG -Unique)
        $gainB = @($ddcOk | Select-Object -ExpandProperty DdcGainB -Unique)
        if ($gainR.Count -gt 1 -or $gainG.Count -gt 1 -or $gainB.Count -gt 1) {
            Add-Finding '严重' '显示器内部 RGB 增益不一致（DDC/CI）' `
                (($ddcOk | ForEach-Object { "$($_.GdiDeviceName)=R$($_.DdcGainR) G$($_.DdcGainG) B$($_.DdcGainB)" }) -join ', ') `
                'RGB 增益直接决定白点色温，不一致必然偏色。用 DDC/CI 调节工具（3-Adjust.cmd）可以逐台对齐。'
        }
        $ct = @($ddcOk | Select-Object -ExpandProperty DdcColorTemp -Unique)
        if ($ct.Count -gt 1) {
            Add-Finding '注意' '显示器内部色温值不一致（DDC/CI）' `
                (($ddcOk | ForEach-Object { "$($_.GdiDeviceName)=$($_.DdcColorTemp)" }) -join ', ') '请统一到相同的色温档位。'
        }

        # 累计使用时长 —— 面板老化程度的直接证据
        $usage = @($ddcOk | Where-Object { $null -ne $_.DdcUsageHours -and $_.DdcUsageHours -ge 0 } |
            Sort-Object DdcUsageHours)
        if ($usage.Count -ge 2) {
            $minH = $usage[0].DdcUsageHours
            $maxH = $usage[-1].DdcUsageHours
            $delta = $maxH - $minH
            $detail = (($usage | ForEach-Object { "$($_.GdiDeviceName)($($_.Serial))=$($_.DdcUsageHours)h" }) -join ', ')
            if ($delta -ge 100) {
                Add-Finding '严重' '各屏累计点亮时长差距较大（面板老化程度不同）' $detail `
                    ("两块屏相差 $delta 小时（约 $([Math]::Round($delta/24.0,1)) 天）。液晶背光会随点亮时长衰减，" +
                     "用的久的那块实际亮度和白点已经漂移——这是「设置完全相同但看起来不一样」最常见也最容易被忽略的原因。" +
                     "这种情况改设置没用，只能用 DDC/CI 逐台补偿，或用校色仪做逐屏 ICC。")
            } else {
                Add-Finding '提示' '各屏累计点亮时长' $detail '差距不大，一般不影响观感。'
            }
        }
    } elseif ($ddcOk.Count -eq 1) {
        Add-Finding '提示' '部分显示器读不到 DDC/CI 数据' `
            "只有 1 台能读到内部参数。" '剩下那台可能没开 DDC/CI，或走了不支持 DDC/CI 的接口/转接器。'
    }
}

# 显示适配器（含未连接的）
$inactiveAdapters = @($adapters | Where-Object { ($_.StateFlags -band 1) -eq 0 })

$virtualPattern = 'Virtual|Mirror|Indirect|Idd|DisplayLink|Duet|Splashtop|Sunlogin|Todesk|MyApps|Remote'
$virtualAdapters = @($inactiveAdapters | Where-Object { $_.DeviceString -match $virtualPattern } |
    Select-Object -ExpandProperty DeviceString -Unique)
if ($virtualAdapters.Count -gt 0) {
    Add-Finding '注意' '存在虚拟显示适配器' ($virtualAdapters -join ', ') `
        '投屏/远控/虚拟显示器驱动会参与显示拓扑与色彩处理，可能干扰多屏观感。如果不用这些软件，建议在「设备管理器 → 显示适配器」中停用或卸载它。'
} elseif ($inactiveAdapters.Count -gt 0) {
    Add-Finding '提示' '存在未连接显示器的显卡输出' `
        (($inactiveAdapters | Where-Object { $_.DeviceName } | ForEach-Object { "$($_.DeviceName) ($($_.DeviceString))" }) -join ', ') `
        '这些输出当前没接显示器，一般无影响；若其中有你不认识的设备名，值得留意。'
}

# NVIDIA 残留记录
if ($nvRecords.Count -gt 0) {
    $connectedSerials = @($displays | Where-Object { $_.Serial } | ForEach-Object { $_.Serial })
    $extra = @($nvRecords | Where-Object {
        $rec = $_
        -not ($connectedSerials | Where-Object { $rec -like "*$_*" })
    })
    if ($extra.Count -gt 0) {
        Add-Finding '注意' '显卡驱动中残留了未连接显示器的记录' ($extra -join ', ') `
            '可能是以前接过别的显示器或换过接口。建议在「NVIDIA 控制面板 → 调整桌面颜色设置」中先对当前每台屏点“恢复默认”，再重新统一设置，避免旧设置错配。'
    }
}

# ======================================================================
# 5. 打印报告
# ======================================================================

if (-not $Quiet) {
    Write-Head "显示器一致性检查   主机: $($report.ComputerName)   $($report.CheckedAt)"
    Write-Host ("  系统 : {0}" -f $report.OS)
    Write-Host ("  显卡 : {0}" -f ($report.GPUs -join ' / '))
    Write-Host ("  数量 : 检测到 {0} 台活动显示器" -f $displays.Count)
    $otherAdapters = @($inactiveAdapters | Where-Object { $_.DeviceName } | ForEach-Object { $_.DeviceString } | Select-Object -Unique)
    if ($otherAdapters.Count -gt 0) {
        Write-Host ("  其他 : 未连接的显示适配器 -> {0}" -f ($otherAdapters -join ' / ')) -ForegroundColor DarkGray
    }

    foreach ($d in $displays) {
        $tag = if ($d.Primary) { '  <== 主显示器' } else { '' }
        Write-Sub ("[{0}] {1} {2}  SN {3}{4}" -f $d.GdiDeviceName, $d.Manufacturer, $d.Model, $d.Serial, $tag)
        Write-Host ("    生产周期   : {0} 年第 {1} 周" -f $d.MfgYear, $d.MfgWeek)
        Write-Host ("    连接方式   : {0}" -f $d.Connection)
        Write-Host ("    分辨率     : {0} @ {1} Hz   旋转 {2}   缩放 {3}{4}" -f $d.Resolution, $d.RefreshHz, $d.Rotation, $d.ScalePercent, $(if ($d.ScaleHint) { "  ($($d.ScaleHint))" } else { '' }))
        Write-Host ("    桌面位置   : {0}" -f $d.DesktopPos)
        Write-Host ("    HDR        : 支持 " + (Format-Bool $d.HdrSupported) + " / 已启用 " + (Format-Bool $d.HdrEnabled) + " / 广色域强制 " + (Format-Bool $d.WideColorEnforced))
        if ($null -ne $d.SdrWhiteLevel) {
            Write-Host ("    SDR 白点   : {0}  (约 {1} nits)" -f $d.SdrWhiteLevel, $d.SdrNits)
        }
        Write-Host ("    ICC 配置   : {0}" -f $d.IccProfile)
        if ($d.RampOk) {
            Write-Host ("    Gamma 曲线 : R[{0}/{1}/{2}] G[{3}] B[{4}]   指纹 {5}" -f $d.RLow, $d.RMid, $d.RHigh, $d.GMid, $d.BMid, $d.RampHash)
        } else {
            Write-Host '    Gamma 曲线 : 读取失败（该显卡/驱动不允许读取）' -ForegroundColor DarkYellow
        }

        # ---- DDC/CI：显示器内部硬件参数 ----
        if ($d.DdcOk) {
            Write-Host ("    显示器内部 : 亮度 {0}/{1}   对比度 {2}   色彩预设 {3}" -f `
                $d.DdcBrightness, $d.DdcBrightMax, $d.DdcContrast, $d.DdcColorPreset)
            Write-Host ("                 R增益 {0}  G增益 {1}  B增益 {2}   (上限 {3})" -f `
                $d.DdcGainR, $d.DdcGainG, $d.DdcGainB, $d.DdcGainMax)
            Write-Host ("                 黑电平 R{0} G{1} B{2}   Gamma {3}   色温 {4}" -f `
                $d.DdcBlackR, $d.DdcBlackG, $d.DdcBlackB, $d.DdcGamma, $d.DdcColorTemp)
            if ($null -ne $d.DdcUsageHours -and $d.DdcUsageHours -ge 0) {
                Write-Host ("                 累计使用 {0} 小时（约 {1} 天）" -f $d.DdcUsageHours, [Math]::Round($d.DdcUsageHours / 24.0, 1)) -ForegroundColor Cyan
            }
            $vcpStr = if ($null -ne $d.DdcVcpVersion -and $d.DdcVcpVersion -ge 0) {
                '{0}.{1}' -f [int]($d.DdcVcpVersion / 256), ($d.DdcVcpVersion % 256)
            } else { '未知' }
            Write-Host ("                 VCP 版本 {0}   固件原始值 {1}   当前输入源 {2}" -f `
                $vcpStr, $d.DdcFirmwareRaw, $d.DdcInputSource) -ForegroundColor DarkGray
        } else {
            Write-Host ("    显示器内部 : DDC/CI 读不到 —— {0}" -f $d.DdcError) -ForegroundColor DarkYellow
        }
    }

    Write-Sub '一致性判定'
    if ($findings.Count -eq 0) {
        Write-Host '  未发现设置层面的不一致项。' -ForegroundColor Green
        Write-Host '  如果肉眼仍觉得颜色不同，就是面板个体差异 —— 见下方建议第 3 条。'
    } else {
        $n = 0
        foreach ($f in $findings) {
            $n++
            $color = switch ($f.Level) { '严重' { 'Red' } '注意' { 'Yellow' } default { 'DarkGray' } }
            Write-Host ("  {0}. [{1}] {2}" -f $n, $f.Level, $f.Title) -ForegroundColor $color
            Write-Host ("       现象 : {0}" -f $f.Detail)
            Write-Host ("       处置 : {0}" -f $f.Advice)
        }
    }

    Write-Sub '通用处置顺序（按性价比）'
    Write-Host '  1) 显示器的 OSD 菜单逐项对齐：色温都设 sRGB 或都设暖色(6500K)，'
    Write-Host '     亮度/对比度/Gamma/锐度数值相同，关掉 DCR、低蓝光、Eco 模式、HDR。'
    Write-Host '     注意 OSD 设置是「按输入接口分别存储」的，两台都要各自设一遍。'
    Write-Host '  2) 系统与显卡统一：HDR 两台一致(建议都关)；NVIDIA 控制面板逐台确认'
    Write-Host '     「输出颜色格式=RGB、动态范围=完全」，并把每屏的色调/数字振动恢复默认。'
    Write-Host '  3) 若要根治面板差异：用校色仪(如 Datacolor Spyder / X-Rite i1Display)'
    Write-Host '     配合 DisplayCAL 对每台屏分别生成 ICC 配置文件并加载。'
    Write-Host '     没有校色仪时，可先跑 Windows 自带校准 (Win+R 输入 dccw) 逐台粗调。'
    Write-Host '  4) 亮度一致性往往比色温更影响用眼舒适度：在两台屏上同时打开纯白页面'
    Write-Host '     (浏览器打开 about:blank) 并排对比，把亮度调到肉眼一致。'
}

# ======================================================================
# 6. 导出 JSON
# ======================================================================

if (-not $Export) {
    $Export = Join-Path $PSScriptRoot ("display-report-{0}.json" -f $env:COMPUTERNAME)
}
try {
    $dir = Split-Path -Parent $Export
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (-not $report) { throw '报告对象为空，无法导出' }
    $json = $report | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $Export -Value $json -Encoding UTF8
    Write-Host ''
    Write-Host ("报告已导出: {0}" -f $Export) -ForegroundColor Green
    Write-Host ''
    Write-Host '下一步怎么做：' -ForegroundColor Cyan
    Write-Host '  1) 把整个 display-check 文件夹拷到另一台电脑（U盘/网盘都行）'
    Write-Host '  2) 在那台电脑上也双击 1-Check.cmd，它会生成自己的 display-report-*.json'
    Write-Host '  3) 把那个 json 拷回本文件夹，双击 2-Compare.cmd —— 会自动挑出两份报告'
    Write-Host '     逐项对比，并列出不一致的地方。'
} catch {
    Write-Host ("报告导出失败: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

Write-Host ''
