# Monitor Consistency Toolkit

Small PowerShell tools for Windows that **diagnose and fix multi-monitor colour / white-point mismatch** — including the frustrating case where two *identical* monitors with *identical* settings still look different.

No colorimeter needed: the adjust tool talks to each monitor directly over **DDC/CI**.

---

## The problem

You have two or three monitors of the same model. Windows settings are the same.
The monitor OSD menus look the same. And yet one screen is noticeably warmer,
or dimmer, or "dirtier" than the other — and staring at them side by side all day
gives you a headache.

The usual advice ("just calibrate them") skips a step: **finding out which layer
the difference actually comes from.** That is what this toolkit does.

---

## What it reads

Three independent layers, all of which can cause a visible difference:

| Layer | What is read | How |
|---|---|---|
| 1. Windows / GPU | ICC profile, gamma-ramp fingerprint (the `vcgt` LUT), HDR / advanced colour, SDR white level, resolution, refresh, DPI scaling | `GetICMProfile`, `GetDeviceGammaRamp`, `QueryDisplayConfig` |
| 2. Monitor OSD | brightness, contrast, RGB gain, RGB black level, colour preset, colour temperature, gamma, VCP version | **DDC/CI** via `dxva2.dll` |
| 3. The panel itself | model, manufacturer, **serial number**, **production year/week**, **accumulated backlight hours** | WMI `WmiMonitorID` + DDC/CI `VCP 0xC0` |

Layer 3 is the one almost nobody checks. `VCP 0xC0` reports how many hours the
backlight has been lit. Two units from the same production week can easily differ
by hundreds of hours, and LCD backlight output drifts with use — so the same
brightness *setting* produces different actual light output. That is a real,
measurable explanation for "identical monitors look different".

**If layers 1 and 2 are identical and the screens still differ, it is layer 3 —
and no settings change will ever fix it.** The adjust tool compensates at layer 2
instead.

---

## Files

### Tools

| File | Purpose |
|---|---|
| `1-Check.cmd` | Inspect every attached monitor, print a report, export JSON |
| `2-Compare.cmd` | Compare two PCs' reports, item by item |
| `3-Adjust.cmd` | Interactive DDC/CI adjustment on a fullscreen test pattern |
| `4-Restore.cmd` | Restore all monitor values from the latest snapshot |

### Engine

| File | Purpose |
|---|---|
| `Check-DisplayConsistency.ps1` | The inspection engine (also does `-Compare`) |
| `Adjust-Monitor.ps1` | The DDC/CI read/write engine and interactive UI |

The `.cmd` launchers and the `.ps1` scripts must stay in the same folder
(the launchers use `%~dp0`).

---

## Quick start

### 1. Inspect

Double-click `1-Check.cmd`. It prints a per-monitor report and writes
`display-report-<PCNAME>.json` next to the script.

```
[\\.\DISPLAY1] AOC U24P10R  SN AP10609Z00569   <== primary
    连接方式   : DisplayPort / EDID:DisplayPort
    分辨率     : 3840 x 2160 @ 60 Hz   scale 200%
    ICC 配置   : sRGB Color Space Profile.icm
    Gamma 曲线 : R[0/32896/65535] G[32896] B[32896]   fingerprint b1ea20d6c656
    显示器内部 : brightness 70/100   contrast 50   colour preset 5
                 R gain 50  G gain 50  B gain 50
                 accumulated use 882 hours
                 VCP version 2.2   current input 15
```

### 2. Compare

Run `1-Check.cmd` on the second PC, copy its `display-report-*.json` into the
same folder, then double-click `2-Compare.cmd`. It pairs monitors by serial
number (falling back to position when the serials differ, i.e. different units),
and labels every row:

- `[一致]` identical
- `[差异]` a *setting* difference — this is what you need to unify
- `[留意]` not a setting error but worth confirming (e.g. DP vs HDMI)
- `[固有]` expected to differ (serial, production batch)

### 3. Adjust

Double-click `3-Adjust.cmd`. A snapshot of all current values is saved first,
then every monitor shows a fullscreen test pattern.

| Key | Action |
|---|---|
| `↑` / `↓` | brightness ±1 |
| `←` / `→` | contrast ∓1 |
| `R` | red gain −1 &nbsp;&nbsp; `Shift+R` +1 |
| `G` | green gain −1 &nbsp;&nbsp; `Shift+G` +1 |
| `B` | blue gain −1 &nbsp;&nbsp; `Shift+B` +1 |
| hold `Ctrl` | step becomes 5 |
| `W` | cycle background: white → mid grey → black |
| `Tab` / `Shift+Tab` | switch to another screen (or just click it) |
| `Z` | undo |
| `H` | hide the on-screen text |
| `Q` | **keep** changes and quit |
| `Esc` | **revert everything** and quit |

Usable suggestions: white reveals colour temperature, mid grey reveals gamma,
black reveals black level.

- Too blue → lower `B` gain; too yellow → lower `R` gain.
- Match brightness on the white field first — brightness mismatch causes more
  eye strain than colour temperature mismatch.

### 4. Regret

Double-click `4-Restore.cmd` — restores every monitor from the latest snapshot.

---

## CLI reference

```powershell
# inspect + export report
.\Check-DisplayConsistency.ps1
.\Check-DisplayConsistency.ps1 -Export D:\report.json
.\Check-DisplayConsistency.ps1 -Quiet          # JSON only, no console report

# compare
.\Check-DisplayConsistency.ps1 -Compare a.json b.json
.\Check-DisplayConsistency.ps1 -Compare auto   # auto-pick the two newest reports

# adjust
.\Adjust-Monitor.ps1                # interactive
.\Adjust-Monitor.ps1 -SelfTest      # verify read/write + build the UI without showing it
.\Adjust-Monitor.ps1 -SaveSnapshot  # save a baseline snapshot only
.\Adjust-Monitor.ps1 -Restore       # restore from newest snapshot
.\Adjust-Monitor.ps1 -Restore -SnapshotFile <path>
```

`-SelfTest` writes each current value back to the monitor and reads it back.
The picture does not change; it only proves the DDC/CI write path works.

---

## Safety

- **No admin rights required.**
- `1-Check` only **reads**. It changes nothing.
- `3-Adjust` writes only brightness / contrast / RGB gain **on the monitor**.
  It never touches Windows settings, the registry, or the GPU driver.
- A snapshot is written **before** any change, and `Esc` reverts in-session.
- Changes take effect immediately. Most monitors keep them across power cycles;
  if yours does not, run the tool again.

---

## Technical notes

### Reading the monitor's own state

`dxva2.dll` is the supported path:

```c
GetNumberOfPhysicalMonitorsFromHMONITOR   // then
GetPhysicalMonitorsFromHMONITOR           // -> PHYSICAL_MONITOR.hPhysicalMonitor
GetVCPFeatureAndVCPFeatureReply           // read a VCP code
SetVCPFeature                             // write a VCP code
```

Relevant VCP codes (MCCS): `0x10` brightness, `0x12` contrast,
`0x14` colour preset, `0x16`/`0x18`/`0x1A` RGB gain, `0x6C`/`0x6E`/`0x70` RGB
black level, `0x72` gamma, `0x0C` colour temperature, `0x60` input source,
`0xC0` **display usage time (hours)**, `0xC9` firmware, `0xDF` VCP version.

### Gotcha 1 — a DXVA2 physical-monitor handle may legitimately be `0`

`PHYSICAL_MONITOR.hPhysicalMonitor` is a table index, not a kernel pointer, so
**handle `0` is a valid monitor**. Code like

```csharp
if (h == IntPtr.Zero) return -1;   // WRONG
```

silently rejects one of your monitors. The symptom is nasty: every VCP read for
that monitor fails, which looks exactly like "this monitor doesn't support
DDC/CI". Detect validity from *how you obtained the handle*, never from its value.

### Gotcha 2 — PowerShell 5.1 `@($genericList)` throws `ArgumentException`

In Windows PowerShell 5.1, wrapping a generic `List<T>` in the array
subexpression operator can fail with `参数类型不匹配` / *Argument types do not
match*:

```powershell
$list = New-Object System.Collections.Generic.List[object]
@($list)          # ArgumentException
$list.ToArray()   # fine
```

Reading properties off it, `foreach`, `.Count` and piping all work — only
`@(...)` breaks. This bites when you build a `[pscustomobject]` from a hashtable
whose value is the list. Use `.ToArray()`.

### Gotcha 3 — gamma-ramp fingerprints

`GetDeviceGammaRamp` returns the 3×256 16-bit LUT actually driving the display.
Hashing it is a cheap way to detect *any* per-display colour transform applied
in software: an ICC `vcgt` curve, Windows' own calibration, Night Light.
If two monitors report different fingerprints, something software-side is
already treating them differently. If the fingerprints match, software is
exonerated and the difference is downstream (OSD or panel).

### DDC/CI is slow and lossy

Reads fail intermittently. Retry a few times before concluding a code is
unsupported; the scripts do.

---

## Requirements

- Windows 10 / 11
- Windows PowerShell 5.1 (built in) or PowerShell 7+
- Monitors with DDC/CI supported and enabled — check the OSD menu if the tool
  reports a monitor as unsupported. Some KVM switches and HDMI splitters break
  DDC/CI too.
- Network is not used. Nothing is uploaded anywhere.

## Generated files (gitignored)

- `display-report-<PCNAME>.json`
- `snapshot-<PCNAME>-<yyyyMMdd-HHmmss>.json`

These contain your machine name, monitor serial numbers and production dates —
keep them local.

## License

MIT — see [LICENSE](LICENSE).

Chinese documentation: [README.zh-CN.md](README.zh-CN.md)
