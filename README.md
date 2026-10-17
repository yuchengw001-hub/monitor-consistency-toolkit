# monitor-consistency-toolkit

Windows 工具：诊断并修正多显示器之间的颜色 / 白点差异，包括「同型号、设置一样，看起来还是不同」这种情况。
不需要校色仪 —— 调节工具通过 **DDC/CI** 直接和显示器对话。不需要管理员权限。

## 文件

| 文件 | 用途 |
|---|---|
| `1-Check.cmd` | 检查本机显示器，打印报告并导出 JSON |
| `2-Compare.cmd` | 对比两台电脑的报告，逐项列出差异 |
| `3-Adjust.cmd` | 全屏测试画面上用键盘调节各屏的亮度 / RGB 增益 |
| `4-Restore.cmd` | 用最近一次快照还原所有显示器的值 |

`Check-DisplayConsistency.ps1` / `Adjust-Monitor.ps1` 是底层脚本，
必须和 `.cmd` 放在同一个文件夹里。

## 用法

**检查**：双击 `1-Check.cmd`，生成 `display-report-<电脑名>.json`

**对比**：在另一台电脑上也跑一次，把它的 JSON 拷过来，双击 `2-Compare.cmd`

**调节**：双击 `3-Adjust.cmd`，会自动先存快照，然后两块屏变全屏测试画面

| 按键 | 作用 |
|---|---|
| `↑` `↓` | 亮度 ±1 |
| `←` `→` | 对比度 ∓1 |
| `R` `G` `B` | 对应增益 −1（`Shift` + 字母 = +1） |
| `Ctrl` | 按住时步进变 5 |
| `W` | 底色：白 → 中灰 → 黑 |
| `Tab` | 切到另一块屏（也可直接点那块屏） |
| `Z` | 撤销 &nbsp;&nbsp; `H` 隐藏文字 |
| `Q` | 保留退出 &nbsp;&nbsp; `Esc` 全部还原退出 |

白底看色温，灰底看伽马，黑底看暗部。偏蓝就降 `B`，偏黄就降 `R`。
先把亮度在白底对齐 —— 亮度不一致比色温不一致更容易让眼睛累。

**还原**：双击 `4-Restore.cmd`

## 它读什么

- **Windows/显卡层**：ICC 配置文件、Gamma 曲线指纹、HDR、SDR 白点、分辨率、DPI
- **显示器菜单层**：亮度、对比度、RGB 增益 / 黑电平、色彩预设、色温（DDC/CI）
- **面板层**：序列号、生产年/周、**累计点亮时长**（`VCP 0xC0`）

如果前两层完全相同而肉眼仍有差异，那就是第三层：不同生产批次、不同累计使用时长
导致背光衰减不同。这种情况改设置没用，只能反过来用 RGB 增益做补偿，或用校色仪
逐屏生成 ICC。

## 命令行（可选）

```powershell
.\Check-DisplayConsistency.ps1                       # 检查
.\Check-DisplayConsistency.ps1 -Compare a.json b.json  # 对比
.\Adjust-Monitor.ps1                                 # 交互式调节
.\Adjust-Monitor.ps1 -SelfTest                       # 自检，不弹窗口
.\Adjust-Monitor.ps1 -Restore                        # 还原
```

## 两个坑（供改代码的人参考）

1. **DXVA2 的 `hPhysicalMonitor` 可能就是 `0`**。它是句柄表索引不是指针，
   `if (h == IntPtr.Zero) return -1;` 会静默地把某块显示器判成"不支持 DDC/CI"。
2. **PowerShell 5.1 里 `@($genericList)` 会抛 `ArgumentException`**。
   读写属性和 `foreach` 都正常，只有 `@(...)` 会炸 —— 用 `.ToArray()`。

## 说明

- `1-Check` 只读，不改任何东西；`3-Adjust` 只写显示器自身的亮度/对比度/RGB 增益，
  不动 Windows 设置、注册表和显卡驱动。
- 改动前会自动存快照，`Esc` 可当场全部还原。
- 部分 KVM 或 HDMI 分配器会破坏 DDC/CI；若报某块屏不支持，先去显示器菜单确认
  DDC/CI 已打开。
- `display-report-*.json` 和 `snapshot-*.json` 含机器名和序列号，已 gitignore。

## License

软件继续采用 [MIT 许可](LICENSE)，允许商业使用、销售、修改、fork 和再分发。
软件的所有副本或实质性部分须包含其版权声明与许可声明。欢迎宣传时注明项目来源，
但这不是 MIT 的额外强制要求，也不要求公开修改代码。

## 官方来源与独立版本

- 官方仓库：[yuchengw001-hub/monitor-consistency-toolkit](https://github.com/yuchengw001-hub/monitor-consistency-toolkit)。
- 维护者账号：[@yuchengw001-hub](https://github.com/yuchengw001-hub)。
- 源码下载：从官方仓库的 **Code → Download ZIP** 获取完整文件；版本发布入口为 [GitHub Releases](https://github.com/yuchengw001-hub/monitor-consistency-toolkit/releases)，仅在有发布记录时提供对应版本。
- 独立修改、收费服务或重新打包时，请清楚说明自己的发布者和独立身份，不得误导为官方发布或获得官方背书；欢迎真实说明兼容性与衍生关系。

详见[来源与署名说明（简体中文 / English）](ATTRIBUTION.md)。本说明不替换 MIT，
不增加软件许可限制，不撤回历史授权。分发软件时请保留完整 LICENSE 及适用的第三方声明。
