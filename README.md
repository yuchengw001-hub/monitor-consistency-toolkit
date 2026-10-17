# monitor-consistency-toolkit

> **源码许可 1.0，2026-10-17 发布。** 本源码提交采用限制性源码可见 [LICENSE](LICENSE)，不是 MIT/GPL/AGPL 或 OSI 开源许可；不发布新的安装包版本。覆盖许可人原创且有权许可部分，历史及第三方权利保留。见[迁移与范围](LICENSE-MIGRATION.md)。

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

## 许可 1.0、官方来源与修改版

允许个人和公司内部自用、修改；允许注明原作者、原项目链接、保留通知并说明修改情况后免费发布原版或修改版；禁止出售软件、修改版、激活码及提供收费在线服务；收费安装、部署、维护和相应技术支持须事先取得许可人书面授权。不限制用软件完成自己的工作或出售不包含软件受许可内容的工作成果，不强制公开修改源码。禁止冒充整体原创或官方，允许对新增部分真实署名。

许可人公开标识：yuchengw001-hub。完整条文见 [LICENSE](LICENSE)，具体路径及排除项见 [LICENSE-SCOPE.json](LICENSE-SCOPE.json)，历史与第三方边界见 [迁移说明](LICENSE-MIGRATION.md)及[第三方说明](THIRD-PARTY-NOTICES.md)。本许可于 2026-10-17 随源码提交发布，不发布新的安装包版本。

- 官方仓库：[monitor-consistency-toolkit](https://github.com/yuchengw001-hub/monitor-consistency-toolkit)；官方发行入口：[GitHub Releases](https://github.com/yuchengw001-hub/monitor-consistency-toolkit/releases)，仅实际发布记录代表相应官方版本。
- 原作者/版权标识：`Copyright (c) 2026 yuchengw001-hub`；修改版署名示例见 [ATTRIBUTION](ATTRIBUTION.md)。
- 不提供全项目 MIT 任选许可，也不撤回旧 MIT 来源的既有权利。允许更换后续发布许可，不以新写代码为前提；历史副本合规销售不因新许可被禁止。

## English license summary

Personal and internal company use and modification are allowed. Free redistribution of original or modified copies requires original-author credit, the upstream link, retained notices and change descriptions. Selling software, modified copies or activation codes and providing paid online services are prohibited under this license. Paid installation, deployment, maintenance and corresponding support require prior written authorization. Users may do their own work and sell results containing no licensed software content; private modifications need not be disclosed. Do not misrepresent upstream work as entirely original or official; truthful credit for additions is allowed.

Public licensor ID: yuchengw001-hub. Read [LICENSE](LICENSE), [scope/exclusions](LICENSE-SCOPE.json), [migration](LICENSE-MIGRATION.md) and [third-party notices](THIRD-PARTY-NOTICES.md). LICENSE 1.0 is published with this source commit on 2026-10-17; no new installer/package version is released.

- Official source: [monitor-consistency-toolkit](https://github.com/yuchengw001-hub/monitor-consistency-toolkit); version entry point: [GitHub Releases](https://github.com/yuchengw001-hub/monitor-consistency-toolkit/releases), for releases actually listed.
- Original copyright/author identifier: `Copyright (c) 2026 yuchengw001-hub`; derivative examples: [ATTRIBUTION](ATTRIBUTION.md).
- This is not an MIT OR custom project offer. Historic MIT grants remain intact; changing future releases does not require new code, and cannot withdraw lawful sale rights from the old MIT source.
