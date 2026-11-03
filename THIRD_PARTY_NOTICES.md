# Source and licensing boundaries

The tracked Swift UI, diagnostic helpers, background service and installer,
tests, build scripts and documentation
in this repository are provided under the MIT license by dff652.

A private local installation was validated using an adapted copy of
[RazeBerry/rtl9210-health-monitor](https://github.com/RazeBerry/rtl9210-health-monitor),
upstream commit `4355fa5cc888efbe3dacb5badc2de3570c12ce44`.
At review time that project did not specify a license. Its code, the local
adaptations, executable and raw hardware records are **not included** in this
public repository or default build. This repository does not grant rights to
that upstream project and does not claim authorship of its USB implementation.

`--with-local-collector` exists for a separately obtained, appropriately authorized
local backend. It is not a redistribution permission. Do not publish a bundle
containing that backend without resolving its license first.

AppKit, SwiftUI, Swift Charts, Foundation, UniformTypeIdentifiers and SF Symbols are system SDK
components supplied by Apple and remain subject to Apple's terms.
