# VT terminal engine and renderer

SSHApp uses libghostty-vt for terminal state, an app-owned Metal renderer for
drawing, and UIKit for input, selection, accessibility, and lifecycle.

## Ownership and data flow

- `Packages/SSHAppGhostty` contains the C bridge (`CGhosttyVT`), terminal engine
  and renderers (`GhosttyVT`), and UIKit hosts (`GhosttyTerminal`). The app links
  the single `GhosttyTheme` product to avoid duplicate Objective-C classes.
- SSH channels and tmux panes retain `VTTerminalSession`s independently of host
  views. Detaching a view preserves terminal state; closing or disconnecting
  retires it.
- A session FIFO orders output, input, resize, configuration, and reset on the
  `VTTerminal` actor. Accepted writes finish even if cancelled; replies return
  to the transport in order.
- Output delivery acknowledges native ingestion before advancing. Live SSH
  output uses read backpressure rather than trimming. Pre-viewport buffering
  is bounded; tmux overflow recovers through an authoritative snapshot.
- Renderers consume owned, revisioned snapshots rather than native grid
  references. Generation and host-ownership checks prevent stale publication.

## Rendering and lifecycle

`VTContentView` submits frames to `VTMetalFramePipeline` through
`VTMetalRenderer`. Two raster slots and one newest-pending frame bound the work.
Glyph shaping and atlas uploads run off the main actor. Each frame uses one
command buffer to draw backgrounds, glyphs, decorations, cursor, and images.

Frames render directly into IOSurface-backed BGRA textures, then publish through
`CALayer.contents`. Each pane has at most three presentation targets. The pool
never reuses the displayed surface or a surface still in use by CoreAnimation.
Publication checks frame currency and pixel size after GPU completion.
`onComplete` means layer publication, not display scanout.

Inactive scenes suspend presentation. Teardown invalidates the frame epoch and
waits for in-flight leases before releasing resources. Memory warnings trim
available targets and caches. Repeated Metal failure switches that host to
`VTCoreTextRenderer` without losing terminal state.

Monochrome glyphs use a color-independent coverage atlas; color glyphs use a
separate RGBA atlas. Frames exceeding atlas or image-tile capacity use CPU
rendering. Shared budgets bound preparation, idle textures, retained native
images, and snapshot image copies; their limits are defined in the corresponding
budget types and are not whole-process memory ceilings.

`VTScrollRefreshCoordinator` requests 120 Hz while scrolling in an active scene,
except in Low Power Mode or serious/critical thermal conditions. Its display link
does not render or schedule terminal work.

## Native patches

Build with `make ghostty-vt`. Source and toolchain pins live in
`vendor/libghostty-vt/native-lock.json`; see [../vendor/PINS.md](../vendor/PINS.md)
for updates. The numbered patches in `vendor/libghostty-vt/patches/` extend the
VT API and must be reviewed and reapplied when changing the upstream pin.

| Patch | Why |
| --- | --- |
| 0001 resolved graphics API | Kitty image placements resolved to the viewport for the host renderers |
| 0002 cursor blink mode policy | Let an explicit host blink preference override DEC mode 12 (DECSCUSR and RIS still apply) |
| 0003 link identity and formatted geometry | Compare OSC 8 link identities, and map formatted text back to cells for links and selection |
| 0004 mouse shift-capture query | Expose the remote's XTSHIFTESCAPE request so the host decides whether Shift overrides mouse capture |
| 0005 shared image storage budget | Reserve/release callbacks so all terminals share one retained-image quota |
| 0006 transfer decoded PNG ownership | Keep the decoded PNG buffer instead of copying it into a second full RGBA allocation |
| 0007 clear-screen API | Command-K clears on the primary screen without RIS or parser injection; no-op on the alternate screen |

## Test hooks

Test seams compile under `VT_TEST_HOOKS`, enabled for package/project Debug
builds and Release device tests. Deployment archives must omit it.

## Benchmarking changes

The benchmark tests have no pass/fail thresholds. They run a fixed synthetic
workload and attach a JSON report to the result bundle, so you can compare a
change against its baseline:

- `TerminalBenchmarkTests` drives the production session, UIKit host and Metal
  renderer: paced output with resizes (one and four panes; short and one-minute
  sustained), and retained-pane image memory through teardown. Reports include
  ingest and frame-request timings, process footprint, thermal state and
  renderer diagnostics.
- `VTGlyphAtlasBenchmarkTests` renders scrolling monochrome, seven-color and
  per-glyph truecolor output straight through `VTMetalRasterizer`, reporting
  worker CPU time, render passes, shaping misses and atlas size.

Run them in Release on a physical device, and compare only reports from the same
device, build configuration, brightness and power state. Simulator runs are a
smoke check; the sustained workloads skip there.

```sh
DEVICE_UDID=<udid> DEVICE_BUILD_CONFIGURATION=Release scripts/run-device-tests.py \
  -only-testing:SSHAppTests/TerminalBenchmarkTests \
  -only-testing:SSHAppTests/VTGlyphAtlasBenchmarkTests
```

For system-level detail (GPU, hitches, power), record the same tests with
Instruments.

## Accessibility

The UIKit host exposes input, selection handles, the accessory bar, and edit
menus. VoiceOver reading of arbitrary terminal output is not verified.
