# Privacy and diagnostics

DriveThermal operates locally. It does not send telemetry, device information or
logs to GitHub or any server. The GitHub links in About open the user's browser.

Private state can include hardware serials and volume UUIDs in enrollment/raw
captures, plus model names, health counters, capture times and the last collector
log. This data stays outside the app bundle, in the user's application-support
directory. These files are excluded from Git and must not be attached to public
issues.

The app event logger accepts an enumerated event type and an optional numeric
exit code; it does not accept arbitrary subprocess output or user paths. It
rotates after 256 KiB and retains one previous file.

Diagnostic export constructs a new report from an allowlist: app/build version,
revision/time, OS version, boolean connection/enrollment/backend state, last
temperature/warning/capture time, and validated application event records. It
excludes model and volume names, serials, UUIDs, user paths, lifetime health
counters, raw logs and raw binary pages. The report is written only to a path
selected in the save dialog, never uploaded automatically. Timestamps and OS
version are still included: review before sharing.

Optional background service state and raw logs are stored in the root-protected
`/Library/Application Support/DriveThermalService/state` directory. The enrolled
local account can request its readings and capture log through the limited local
socket API. Viewing the log explicitly copies it to the user app state; it is
not included in the allowlisted diagnostic export.

macOS removable-volume access is a separate Files & Folders privacy consent.
Administrator installation approval and collection mode cannot grant it. The
settings panel explains this and opens the corresponding System Settings pane;
it never writes the privacy database or silently grants Full Disk Access.
Local ad-hoc builds can be identified differently after rebuilding, so a system
prompt may recur during development. The app includes a removable-volume usage
description explaining the disk checks and mount/unmount workflow.
