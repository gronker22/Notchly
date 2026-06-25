# Notchly

A macOS "Dynamic Island" for the MacBook notch. A borderless panel sits over the
notch and drops down on hover into an interactive bubble with:

- **Now Playing** — Spotify / Apple Music track, artwork, and transport controls
- **Pomodoro timer** — adjustable focus/break lengths, collapsed countdown + ring, notification on completion
- **Calendar** — your next upcoming event
- **System** — network up/down speed, mic/camera-in-use indicators
- **Clipboard** — last 5 copied items, click to copy back
- **Live Sports** — live scores & yesterday's results via ESPN's public API (NBA, Premier League, Champions League, La Liga, World Cup)
- **Window docking** — drag a window onto the island to snap it left/right

## Requirements

- macOS 14 or later (built and tested on macOS 26 Tahoe)
- Xcode 16+ to build

## Build & run

1. Open `Notchly.xcodeproj` in Xcode.
2. Select the **Notchly** scheme and **My Mac**, then press **Run** (⌘R).

It's a menu-bar-less accessory app (no Dock icon) — look at the **top-center of
your screen**, over the notch, and hover to open it.

## Permissions

Granted on first use via System Settings → Privacy & Security:

- **Automation** (Spotify / Music) — for Now Playing
- **Calendars** — for the next-event row
- **Accessibility** — for drag-to-dock window snapping
- **Notifications** — for the Pomodoro completion alert

App Sandbox is intentionally **off** (the app reads system media/window state),
so it is unsigned for distribution — see note below.

## Note for other users

This builds and runs locally from Xcode with no API keys or configuration. To run
a prebuilt copy from someone else you'd need to build it yourself (it is not
notarized/code-signed for distribution), or remove the Gatekeeper quarantine
manually. Building from source in Xcode is the supported path.
