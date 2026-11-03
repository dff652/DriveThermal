# Changelog

## 0.6.2 — 2026-11-03

- Group Cancel and Save and Close at the bottom right of collection settings, replacing the ambiguous Done action.
- Close only after the service confirms the saved settings; keep errors visible and prevent duplicate saves.
- Label the active configuration separately from unsaved edits and validate custom interval text before saving.
- Preserve the collection countdown when closing unchanged settings.

## 0.6.1 — 2026-11-03

- Allow custom collection intervals of 5–1440 minutes in both the app and service.
- Add a 15-minute preset alongside 30, 60, 180 and 360 minutes.
- Keep existing settings and explain that short intervals still temporarily unmount the disk.

## 0.6.0 — 2026-11-03

- Add mount/unmount controls to the desktop window and menu-bar menu for the enrolled volume.
- Persist a collection pause before unmount; verified mount restores the selected manual/automatic mode and starts a fresh interval.
- Serialize volume changes with captures and service updates; never force unmount or power off USB.
- Explain removable-volume privacy permission separately from administrator authorization and provide a Files & Folders settings link.
- Preserve compatibility with older services, disabling new controls until the service is updated.

## 0.5.0 — 2026-11-03

- Add an optional administrator-approved, root-owned local capture service.
- Add manual/automatic modes, 30–1440 minute intervals, next-attempt status and service installation/removal.
- Keep guarded collector checks; skip busy/offline disks and pause on unexpected failure.
- Prevent overlapping captures and sleep catch-up bursts.
- Run the guarded collector in the enrolled console session; skip captures when that user is logged out.
- Protect updates with a capture lock and require successful manual recovery after interrupted captures.
- Sync service readings into existing local history; expose private service logs on request.

## 0.4.0 — 2026-11-03

- Show temperature history directly in the main window and a larger history chart.
- Use actual timestamps, temperature axes, measured points and dashed connectors; handle empty, single-point and constant-temperature histories.
- Add explicit thanks to RazeBerry/rtl9210-health-monitor in About and the README.

## 0.3.1 — 2026-11-03

- Rename the navigation actions to 查看SMART详情 and 查看历史.
- Place both actions in a dedicated row with matching tinted backgrounds, borders, icons and disclosure arrows; keep collection actions separate.

## 0.3.0 — 2026-11-03

- Add system capacity and available space, explicitly labelled as shared-container space for APFS.
- Add a scrollable SMART detail sheet with firmware, spare capacity, lifetime I/O totals, power cycles and error counters.
- Enrich the latest saved snapshot without another hardware probe; older history remains readable.
- Move static collection/privacy explanations into tooltips and a clickable information popover.
- Preserve visible capture failures and snapshot timestamps; do not imply live temperature or a guaranteed health score.

## 0.2.0 — 2026-11-03

- Add About with version/build/revision, maintainer and repository links.
- Add structured application event logging and allowlisted diagnostic export.
- Add menu-bar log and diagnostic actions, plus a visible version footer.
- Separate public UI builds from private local collector bundles.
- Add MIT licensing, privacy documentation and collector-interface documentation.
- Test that failed readings and private hardware fields are not accepted/exported.

## 0.1.0 — local prototype

- Desktop and menu-bar interface, manual capture, history and mounted-state display.
- Private local end-to-end validation against one enrolled USB NVMe SSD.
