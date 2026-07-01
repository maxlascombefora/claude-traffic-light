# Overlay built as a native Swift (SwiftUI/AppKit) app

The Overlay is a native macOS app in Swift — a borderless, always-on-top, non-activating
floating panel rendering the traffic light — rather than Electron, Tauri, or Python.

Chosen for the smallest footprint and most native window behavior (always-on-top across all
Spaces, no runtime deps) in a tool that runs 24/7. We accept the cost that Swift/SwiftUI/Xcode
is the least familiar toolchain here, on the bet that this app is small enough to learn on.

**Surprising, so recorded:** given the rest of the author's work is JS/TS/React, a reader
would expect Electron or a web stack — this deliberately goes native for footprint. Rejected:
Electron (~100 MB+ idle for three dots), Tauri (great fit, but still a webview and a Rust
toolchain), Python/rumps (menu-bar-shaped, awkward as a floating overlay). This decision
covers only the Overlay; the Reporter is a separate program (see later ADR).
