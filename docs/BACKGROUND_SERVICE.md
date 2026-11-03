# Background capture service

The optional local build uses a root-owned LaunchDaemon, installed after an
explicit macOS administrator authorization. This supports local ad-hoc builds
without a Developer ID certificate. It does not use `sudoers`, cache a password,
or keep `sudo` authorization alive. It is not an SMAppService registration.

The public repository includes the service, installer, protocol and UI sources.
The private collector still requires separate authorization and is not published.
The default public build cannot install a USB collector service.

## Authority boundary

- Code and enrolled-device profile are copied to the root-owned directory
  `/Library/Application Support/DriveThermalService`; writable ACLs are removed
  from installed executables. Runtime state is root-only.
- The daemon binds a Unix-domain socket under that protected directory. The
  enrolled local user owns the mode-0600 socket, but cannot replace it.
- Peer credentials must match the enrolled UID; the client verifies a root peer.
  This is an account-level boundary, not an application code-signature boundary:
  other processes running as that same user can issue the limited requests.
- Requests are limited to status, one capture, bounded schedule configuration,
  and reading the fixed private capture log. There are no caller-supplied paths,
  executable names, shell commands, device identities or firmware operations.
- The daemon runs only its fixed, root-owned collector front door with a clean
  environment, using `launchctl asuser` for the enrolled user's console audit
  session while retaining root credentials. A pure system session failed to
  open the USB interface on the validation Mac. No arbitrary user environment
  or executable is inherited. It does not invoke the native USB executable directly.
- The local collector has an explicit `service-probe` mode requiring root and
  the exact installed path, root-owned configuration and binary. The legacy
  interactive path remains unchanged. Device identity, physical store, idleness,
  transport status and remount checks remain enforced.

## Scheduling

Manual is the initial default. Automatic intervals are 30–1440 minutes, with
presets for 30, 60, 180 and 360 minutes. Switching mode or changing the interval
starts a fresh countdown. Manual capture also resets the countdown.

There is one capture at a time and a one-minute manual request cooldown. Busy
or absent disks are skipped until the next interval. Unexpected capture failure
pauses automatic mode. A persistent in-progress marker prevents automatic
retries following a daemon crash or interrupted capture. A manual retry remains
available after checking the disk; enabling automation requires a successful
manual recovery first. Installation/uninstallation and capture use a root-owned
exclusive file lock, so an update cannot race with a new capture.

A gap of more than 90 seconds between 15-second scheduling ticks is treated as
sleep or clock discontinuity. The next interval starts again; missed captures
are not replayed and no wake alarm is installed. Automatic capture continues
when the UI exits. On daemon startup the next interval starts from startup.
The enrolled user must be the current console user; logged-out sessions and
other console users are skipped. This service does not collect before login.

## Local data and removal

Successful readings are retained in the private service state (up to 500) and
synchronized to the user's existing history while the UI runs. Raw USB pages
stay in root-protected state. Explicitly viewing the service log saves a private
copy in the user's app state. Neither logs nor history are uploaded.

The settings panel provides install/update and uninstall actions. Changes to
the privileged installation require administrator authorization again; ordinary
mode changes and captures do not. Uninstall unregisters the daemon but preserves
private data and installed files for inspection. It does not erase history.

## Validation scope

On the development Mac, the installed service completed a real guarded capture
without a per-capture password prompt: controller identity, SMART and error-log
pages passed, and the enrolled APFS volume was verified after remount. Manual /
automatic switching, a 60-minute countdown, cancellation of that countdown,
invalid intervals and unknown request rejection were checked against the service.
The UI was then exited and the service's active schedule was verified independently.
Unit tests cover timer deadlines, overlap prevention and sleep catch-up behavior.
These checks do not establish support for other enclosures or macOS versions.

`scripts/test.sh` also compiles the service and installer without executing them;
it does not touch USB hardware or require the private collector.

For additional context on console-session USB access, see the independently
published [AirUSB capture investigation](https://github.com/otti83/airusb-hub/blob/main/docs/P1_CAPTURE_VERIFICATION.md).
No code from that project is included here; the invocation semantics are also
documented in macOS's `launchctl(1)` manual under `asuser`.
