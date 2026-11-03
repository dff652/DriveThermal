# DriveThermal

A lightweight macOS desktop window and menu-bar companion for **timestamped SSD
temperature snapshots**. 中文界面，支持手动／定时采集、历史记录及脱敏诊断。

> **Public release scope:** this repository contains the UI, data parser,
> diagnostics, optional service/installer and collector integration contract. It does **not** include a USB
> SMART collector. A clean checkout can build and run the UI, but cannot obtain
> fresh disk temperatures until an authorized compatible backend and enrollment
> are provided. No claim of universal USB SSD support is made.

## Features

- Desktop window, optional always-on-top, and menu-bar temperature display.
- Last-captured temperature and explicit timestamp; no misleading live readings.
- Up to 500 local history entries; main-window and history charts show the latest 30 observations on a real time axis, with temperature ticks and measured points.
- Passive mount-state and capacity refresh every 15 seconds (APFS shared-container space).
- SMART details: firmware, spare capacity, lifetime read/write totals, power cycles and error counts.
- Compact collection-help popover and native hover tooltips.
- Lifetime I/O totals are not live throughput; no background benchmark is performed.
- Version, build revision, maintainer link and project link in About.
- Local application event log, collector-log access and allowlisted diagnostic export.
- Optional authorized background capture, manual/automatic switching and configurable 5–1440 minute intervals.
- Mount/unmount controls in the desktop window and menu-bar menu. Unmount pauses collection; a verified mount restores the selected mode. USB power is unchanged.
- No telemetry, accounts or automatic uploads. GitHub links open only when clicked.

## 为什么温度不是实时刷新？

本地验证过的 USB NVMe 采集方式需要短暂卸载磁盘、接管 USB 接口，完成后恢复挂载。
因此 DriveThermal 不高频轮询温度。可选后台服务支持 5–1440 分钟的定时采集，磁盘忙碌时跳过。菜单栏显示的是**上次读数**，提示和窗口注明时间。
关闭小窗仍保留菜单栏；从菜单栏退出应用。

## Build / 构建

Requirements: macOS 14+, Apple Command Line Tools, Python 3. Apple Silicon has
been tested; other hardware is not yet validated. No Xcode project or package
download is required for the UI build.

```sh
./scripts/test.sh
./scripts/build.sh
open build/DriveThermal.app
```

This creates an ad-hoc signed local app. It is not Apple-notarized. Use a local
source build if you do not wish to run an unnotarized download.

A separate private local build can retain a licensed/authorized collector:

```sh
# Requires a compatible local collector/ tree and shellcheck.
./scripts/build.sh --with-local-collector
open build-local/DriveThermal.app
```

The collector directory is ignored by Git. See [collector contract](docs/COLLECTOR.md)
and [source/permission boundaries](THIRD_PARTY_NOTICES.md). Never upload a private
bundle that embeds an unlicensed backend.

## Diagnostics / 调试

Open **关于 DriveThermal** to see version, build number, revision and build time.
Use **导出脱敏诊断报告** when reporting a problem. Review the exported text before
posting it. Do not attach `device.plist`, a raw `runs/` directory, `*.bin`, or the
unfiltered capture log to a public issue. See [privacy](docs/PRIVACY.md).

Private local state is stored in `~/Library/Application Support/DriveThermal`.
The application bundle contains no device enrollment. No new capture is needed
to open About, inspect history or export a diagnostic report.

## Status

Version 0.6.2 is an early, UI-first public release. The private local collector
integration was validated on one Apple Silicon Mac and one Realtek 0BDA:9210
NVMe enclosure; that does not establish compatibility for other disks or bridges.

Maintainer: [dff652](https://github.com/dff652).

MIT applies to the code distributed in this repository. See [LICENSE](LICENSE)
and [third-party notices](THIRD_PARTY_NOTICES.md).

## Acknowledgements / 致谢

Special thanks to [RazeBerry/rtl9210-health-monitor](https://github.com/RazeBerry/rtl9210-health-monitor)
for the USB transport and NVMe health-reading implementation used by the private
local collector adaptation. Attribution does not change the redistribution
boundaries described in THIRD_PARTY_NOTICES.md.

## Optional background service

Local collector builds include a first-authorization installer and a mode/interval
settings panel. Manual remains the initial default. See
[background service design](docs/BACKGROUND_SERVICE.md) for authority boundaries,
sleep behavior, scheduling, update and removal.
