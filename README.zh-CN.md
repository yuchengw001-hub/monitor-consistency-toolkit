# 显示器一致性工具包

一套 Windows 小工具，用来**诊断并修正多显示器之间的颜色 / 白点差异** ——
特别是那种「同型号、设置一模一样，看起来还是不一样」的情况。

不需要买校色仪：调节工具通过 **DDC/CI** 直接和显示器对话。

---

## 解决什么问题

你有两块或三块同型号显示器。Windows 里的设置一样，显示器菜单里的数值也一样，
但其中一块明显偏暖 / 偏暗 / 发灰。两块屏并排看一天，眼睛就开始疼。

通常的建议是「去做色彩校准」，但漏了一步：**先搞清楚差异到底来自哪一层。**
这个工具包做的就是这件事。

---

## 它读什么

会互相造成视觉差异的，其实是三个独立的层：

| 层 | 读什么 | 用什么读 |
|---|---|---|
| 1. Windows / 显卡 | ICC 配置文件、Gamma 曲线指纹（vcgt LUT）、HDR、SDR 白点、分辨率、刷新率、DPI 缩放 | `GetICMProfile`、`GetDeviceGammaRamp`、`QueryDisplayConfig` |
| 2. 显示器菜单 | 亮度、对比度、RGB 增益、RGB 黑电平、色彩预设、色温、Gamma、VCP 版本 | **DDC/CI**（`dxva2.dll`） |
| 3. 面板本身 | 型号、厂商、**序列号**、**生产年/周**、**累计点亮时长** | WMI `WmiMonitorID` + DDC/CI `VCP 0xC0` |

第 3 层几乎没人查。`VCP 0xC0` 会报告背光点亮了多少小时。同周生产的两块屏，
累计时长可能差好几百小时，而液晶背光会随使用时长衰减 ——
于是**同样的亮度设定，实际出光并不一样**。这就是「同型号看着不同」的一个
真实且可测量的原因。

**如果第 1 层和第 2 层都完全一致，看起来还是不同，那就是第 3 层 ——
改设置永远改不掉。** 这时调节工具改为在第 2 层做补偿。

---

## 文件说明

### 工具

| 文件 | 用途 |
|---|---|
| `1-Check.cmd` | 检查本机所有显示器，打印报告并导出 JSON |
| `2-Compare.cmd` | 对比两台电脑的报告，逐项列出差异 |
| `3-Adjust.cmd` | 在全屏测试画面上交互式调节各屏 |
| `4-Restore.cmd` | 用最近一次快照还原所有显示器的值 |

### 引擎

| 文件 | 用途 |
|---|---|
| `Check-DisplayConsistency.ps1` | 检查引擎（也负责 `-Compare`） |
| `Adjust-Monitor.ps1` | DDC/CI 读写引擎与交互界面 |

`.cmd` 和 `.ps1` 必须放在同一个文件夹（启动器用 `%~dp0` 定位脚本）。

---

## 快速开始

### 第一步：检查

双击 `1-Check.cmd`。会打印每块屏的详细报告，并在脚本旁生成
`display-report-你的电脑名.json`。

```
[\\.\DISPLAY1] AOC U24P10R  SN AP10609Z00569   <== 主显示器
    连接方式   : DisplayPort / EDID:DisplayPort
    分辨率     : 3840 x 2160 @ 60 Hz   缩放 200%
    ICC 配置   : sRGB Color Space Profile.icm
    Gamma 曲线 : R[0/32896/65535] G[32896] B[32896]   指纹 b1ea20d6c656
    显示器内部 : 亮度 70/100   对比度 50   色彩预设 5
                 R增益 50  G增益 50  B增益 50
                 累计使用 882 小时
                 VCP 版本 2.2   当前输入源 15
```

### 第二步：对比

在第二台电脑上也运行一次 `1-Check.cmd`，把它的 `display-report-*.json`
拷进同一个文件夹，然后双击 `2-Compare.cmd`。

工具会**按序列号配对**显示器（序列号不同时退化为按位置配对，即"不同的屏"），
每一行都会标注：

- `[一致]` 完全相同
- `[差异]` **设置类**差异 —— 这是需要统一的
- `[留意]` 不是设置错误，但值得确认（比如一边 DP 一边 HDMI）
- `[固有]` 本来就该不同（序列号、生产批次）

### 第三步：调节

双击 `3-Adjust.cmd`。启动时会先自动保存一份所有当前值的快照，
然后每块屏都显示为全屏测试画面。

| 按键 | 作用 |
|---|---|
| `↑` / `↓` | 亮度 ±1 |
| `←` / `→` | 对比度 ∓1 |
| `R` | 红增益 −1 &nbsp;&nbsp; `Shift+R` +1 |
| `G` | 绿增益 −1 &nbsp;&nbsp; `Shift+G` +1 |
| `B` | 蓝增益 −1 &nbsp;&nbsp; `Shift+B` +1 |
| 按住 `Ctrl` | 步进变成 5（快速大幅调整） |
| `W` | 切换底色：白 → 中灰 → 黑 |
| `Tab` / `Shift+Tab` | 切到另一块屏（也可以直接用鼠标点那块屏） |
| `Z` | 撤销上一步 |
| `H` | 隐藏屏幕上的文字 |
| `Q` | **保留**改动并退出 |
| `Esc` | **全部还原**并退出 |

配色思路：

- 白底看色温，中灰看伽马，黑底看暗部。
- 偏蓝 → 降低 `B` 增益；偏黄 → 降低 `R` 增益。
- **先在白底把亮度对齐** —— 亮度不一致比色温不一致更容易引起眼疲劳。

### 第四步：后悔药

双击 `4-Restore.cmd`，用最近一次快照还原所有显示器的值。

---

## 命令行用法

```powershell
# 检查并导出报告
.\Check-DisplayConsistency.ps1
.\Check-DisplayConsistency.ps1 -Export D:\report.json
.\Check-DisplayConsistency.ps1 -Quiet          # 只导出 JSON，不打印报告

# 对比
.\Check-DisplayConsistency.ps1 -Compare a.json b.json
.\Check-DisplayConsistency.ps1 -Compare auto   # 自动挑出最新的两份报告

# 调节
.\Adjust-Monitor.ps1                # 交互式调节
.\Adjust-Monitor.ps1 -SelfTest      # 自检：验证读写通道并组装界面但不显示
.\Adjust-Monitor.ps1 -SaveSnapshot  # 只保存一份基线快照
.\Adjust-Monitor.ps1 -Restore       # 用最近一次快照还原
.\Adjust-Monitor.ps1 -Restore -SnapshotFile <路径>
```

`-SelfTest` 会把每个当前值原样写回显示器再读回来。画面不会有任何变化，
只是证明 DDC/CI 写入通道可用。

---

## 安全说明

- **不需要管理员权限。**
- `1-Check` 只**读**，不改任何东西。
- `3-Adjust` 只写显示器上的亮度 / 对比度 / RGB 增益，
  **不动** Windows 设置、注册表和显卡驱动。
- 任何改动前都会先写一份快照；`Esc` 可在会话内立刻全部还原。
- 改动立即生效。多数显示器断电后仍会保留；若不保留，重跑一次即可。

---

## 技术笔记

### 读取显示器自身状态

正式路径是 `dxva2.dll`：

```c
GetNumberOfPhysicalMonitorsFromHMONITOR   // 然后
GetPhysicalMonitorsFromHMONITOR           // -> PHYSICAL_MONITOR.hPhysicalMonitor
GetVCPFeatureAndVCPFeatureReply           // 读一个 VCP 代码
SetVCPFeature                             // 写一个 VCP 代码
```

用到的 VCP 代码（MCCS）：`0x10` 亮度、`0x12` 对比度、`0x14` 色彩预设、
`0x16`/`0x18`/`0x1A` RGB 增益、`0x6C`/`0x6E`/`0x70` RGB 黑电平、
`0x72` Gamma、`0x0C` 色温、`0x60` 输入源、`0xC0` **累计使用时长（小时）**、
`0xC9` 固件、`0xDF` VCP 版本。

### 坑 1 —— DXVA2 的显示器句柄可能就是 `0`

`PHYSICAL_MONITOR.hPhysicalMonitor` 是句柄表里的**索引**，不是内核指针，
所以**句柄 `0` 是一块合法显示器**。这样的代码：

```csharp
if (h == IntPtr.Zero) return -1;   // 错误
```

会悄悄地把你的某一块显示器判成无效。症状很有迷惑性：那块屏的所有 VCP 读取
全部失败，看起来和「这块显示器不支持 DDC/CI」一模一样。
**句柄是否有效，要靠"它怎么来的"判断，绝不能靠它的数值。**

### 坑 2 —— PowerShell 5.1 里 `@($genericList)` 会抛异常

在 Windows PowerShell 5.1 中，用数组子表达式运算符包住泛型 `List<T>`
可能直接抛 `ArgumentException`（*参数类型不匹配* / *Argument types do not
match*）：

```powershell
$list = New-Object System.Collections.Generic.List[object]
@($list)          # ArgumentException
$list.ToArray()   # 正常
```

读属性、`foreach`、`.Count`、管道都正常，**只有 `@(...)` 会炸**。
最容易踩的场景是用一个以该 List 为值的哈希表去构造 `[pscustomobject]`。
用 `.ToArray()` 绕过。

### 坑 3 —— Gamma 曲线指纹

`GetDeviceGammaRamp` 返回真正驱动显示器的 3×256 16 位 LUT。对它做哈希，
是一种廉价的检测手段：可以发现**任何**在软件层施加的逐屏色彩变换 ——
ICC 的 `vcgt` 曲线、Windows 自带校准、夜间模式。
两块屏指纹不同，说明软件层已经在区别对待它们；指纹相同，则软件层被排除，
差异在更下游（显示器菜单或面板）。

### DDC/CI 又慢又容易丢包

读取会间歇性失败。在判定某个代码「不支持」之前，应该多试几次；
脚本内部已经做了重试。

---

## 系统要求

- Windows 10 / 11
- Windows PowerShell 5.1（系统自带）或 PowerShell 7+
- 显示器支持并启用了 DDC/CI —— 如果工具报告某块屏不支持，先去显示器
  菜单里把 DDC/CI 打开。部分 KVM 切换器和 HDMI 分配器也会破坏 DDC/CI。
- 不使用网络，不会上传任何数据。

## 生成的文件（已在 .gitignore 中忽略）

- `display-report-<电脑名>.json`
- `snapshot-<电脑名>-<yyyyMMdd-HHmmss>.json`

这些文件包含你的机器名、显示器序列号和生产日期，请保留在本地。

## 许可证

MIT —— 见 [LICENSE](LICENSE)。

英文文档：[README.md](README.md)
