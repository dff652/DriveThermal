# Changelog

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
