# CGRBAR

A tiny macOS menu bar app that shows CPU, GPU and RAM usage. Nothing else.

```
CPU  12%  GPU  58%  RAM  63%
```

- **Light.** Native AppKit, no dependencies, about 14 MB of memory and roughly
  0.03% CPU at the default 2 s interval. Sampling all three metrics takes about
  20 µs, and the menu bar readout is drawn from cached glyph images, so an
  update never re-runs text layout.
- **No root.** CPU and RAM come from Mach host statistics, GPU from the
  `IOAccelerator` driver statistics in the IORegistry.
- **Customizable.** Pick which metrics show in the menu bar, the update interval
  (1–10 s), labels on or off, and color by load (orange above 70%, red above 90%).
- **Details on click.** User/system CPU split, GPU renderer/tiler load and memory,
  RAM breakdown (app, wired, compressed) and memory pressure.

RAM "used" follows Activity Monitor: app memory + wired + compressed.

## Requirements

macOS 14 or later on Apple Silicon.

## Build

```sh
swift build            # debug build
swift test             # unit tests
./Scripts/package_app.sh   # release build at build/CGRBAR.app
```

The packaged app is ad-hoc signed. On first launch, right-click it and choose
**Open**. "Launch at Login" is only available from the packaged app.

## License

MIT
