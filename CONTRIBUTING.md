# Contributing

Issues and pull requests are welcome. For a bigger change, open an issue first so we can agree on the approach.

## Setup

You need macOS 14 or later on Apple Silicon and Xcode 16 or later (Swift 6).

## Layout

- `Sources/CGRBAR/Metrics/` — CPU, GPU, memory and process samplers, plus history.
- `Sources/CGRBAR/Panel/` — the panel that opens on click.
- `Sources/CGRBAR/SettingsWindow/` — the settings window.
- `Sources/CGRBAR/StatusItemController.swift`, `MeterView.swift` — the menu bar readout.
- `Tests/CGRBARTests/` — unit tests.
- `Scripts/` — packaging, install and icon scripts.

## Build and test

```sh
swift build                 # debug build
swift test                  # unit tests
./Scripts/package_app.sh    # release app at build/CGRBAR.app, with icon
./Scripts/install.sh        # package, install to /Applications and start
```

There is no CI yet, so run `swift test` before you open a pull request.

## Keep it light

CGRBAR stays at about 14 MB of memory and well under 0.1% CPU at the default 2 s interval. If a change touches the menu bar readout or the samplers, check that these numbers still hold and mention them in the pull request.

## Style

Match the surrounding code. Commits follow [Conventional Commits](https://www.conventionalcommits.org).
