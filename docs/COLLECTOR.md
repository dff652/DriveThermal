# Collector integration contract

The public app can run without a collector. In that state it can display existing
saved readings, but the capture button is disabled and the missing backend is
explained. No hardware probing or enrollment is attempted automatically.

## Local integration

The private build expects an executable at
`Contents/Resources/collector/rtl9210-health`, called via `/bin/bash` with
`probe --confirm`. This command runs as the logged-in user. The backend, not the
UI, must handle local administrator authorization and all hardware safety checks.
The UI never receives or stores an administrator password.

Environment passed to the backend:

- `DRIVETHERMAL_STATE`: private application-state directory.
- `RTL9210_HEALTH_CONFIG`: path to the enrolled-device plist within that directory.

The adapter must verify the exact disk-to-USB relationship, volume physical
store, device identity, idleness, authorization, transfer lengths, command status
and remount. It must never force an unmount or implement storage writes, firmware
updates, format, sanitize or self-tests for this workflow. Failure must preserve
the last successful reading. Driver restoration and remount must be attempted
on every error/interruption path. Use a separately reviewed implementation.

## Output

Exit 0 is accepted only with a newly completed run at
`runs/yyyyMMdd_HHmmss/summary.txt`, and `latest` atomically updated to that run
**after** successful remount verification. The current parser expects:

```text
Model: Example NVMe
Critical Warning: 0x00 (none)
Composite Temperature: 40 C
Available Spare: 100%
Percentage Used: 1%
Power On Hours: 100
Media/Data Integrity Errors: 0
probe result: identify=OK smart=OK error_log=OK
```

The values above are synthetic examples. Invalid temperatures or partial success
are rejected. Raw pages and enrollment must never enter the public repository.

The current frontend's enrollment view reads `volume_uuid`, `mount_path` and
`nvme_model` from `device.plist`; the backend must maintain its additional identity
checks. Use the backend's guarded enrollment workflow, never fabricate an
identity profile to skip hardware checks. There is no public enrollment helper
in this UI-first version.

## Future complete public release

Either obtain an explicit redistribution license for the original collector,
or integrate an appropriately licensed implementation and preserve its notices.
Only after that can a complete USB-capable bundle be published. Current public
builds intentionally omit the unlicensed implementation.

## Optional snapshot fields

The parser also accepts `Firmware`, `Available Spare Threshold`,
`Data Units Read (x512,000B)`, `Data Units Written (x512,000B)`,
`Host Read Commands`, `Host Write Commands`, `Controller Busy Time (min)`,
`Power Cycles`, `Unsafe Shutdowns`, and `Error Info Log Entries`.
Counters remain decimal strings to preserve NVMe 128-bit values. Missing fields
render as unavailable; opening details never invokes the collector.
Lifetime I/O uses 512,000 bytes per data unit and decimal GB/TB.

Field semantics: [NVMe SMART / Health Information](https://learn.microsoft.com/en-us/windows/win32/api/nvme/ns-nvme-nvme_health_info_log).
