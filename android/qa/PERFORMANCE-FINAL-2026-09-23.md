# Final targeted Android performance pass — September 23, 2026

This pass changes MainActivity.kt only. No renderer replacement, Pixel installation, site deployment, cloud changes, or release version change was performed by this reviewer.

## Applied

- Read dock animation progress in layout/draw rather than in composition. The dock's buttons, menus and logo no longer need full recomposition for every animation tick; only the visibility/interactivity thresholds recompose.
- Apply the same deferred read/derived threshold pattern to the address chrome and collapsed URL chip.
- Remove the second full-page capture that ran 140 ms after opening Nav or page tools. The initial capture and recapture on completed page navigation remain.
- Reject thumbnail/backdrop capture callbacks after their GeckoView has switched sessions or their tab has closed, preventing stale images and unnecessary cache writes.

## Evidence

- `:app:assembleDebug :app:testDebugUnitTest` passed; `git diff --check` passed.
- Emulator scroll fixture checked expanded and collapsed toolbar positions, tap-caret expansion, page scroll, and current process survival. Screenshots were inspected at `/tmp/breeze-perf-before.png`, `/tmp/breeze-perf-after.png`, and `/tmp/breeze-perf-expanded.png`.
- ADB frame counters were collected in `performance-final/`. Initial baseline: 341 frames, 75.95% janky, p50 48 ms, p95 101 ms. A subsequent baseline returned zero frames and is invalid. Post-change interaction sample: 217 frames, 56.22% janky, p50 40 ms, p95 117 ms. **These are not a controlled A/B benchmark**: the first baseline overlapped a host build, the later sample used a different sequence, and this is a debug APK in an emulator. Do not claim a percent improvement or Pixel FPS from these numbers.
- No Pixel interaction was performed by this reviewer. Physical-device sustained scrolling and SurfaceFlinger/Perfetto FrameTimeline measurements remain necessary to prove overall smoothness.

## Remaining highest-value work

1. Integrate Gecko dynamic toolbar/viewport handling. The current web viewport height still changes at collapse state boundaries; replacing that resize with the supported compositor toolbar mechanism is a larger, separately verified task.
2. Profile an optimized release build on Pixel. Current Gradle release settings have minification/optimization disabled and no app-specific Baseline Profile. Establish an actual release measurement before changing engine flags or promising Chrome-level FPS.
3. Full-page capture still creates a screen-sized bitmap before a 360 px thumbnail is made. GeckoDisplay has a scaled ScreenshotBuilder API, but GeckoView's public capturePixels wrapper does not expose it directly. Implement through a deliberately owned display lifecycle or move safe downsampling off the main thread in a focused follow-up, rather than reflection/private API access.
4. Prior review's tab-wall black flash, overlapping controls and crop changes remain outside this narrow pass. Deferred animation reads reduce CPU work; they do not prove those transition correctness issues resolved.

## Official references

- https://developer.android.com/develop/ui/compose/performance/bestpractices
- https://developer.android.com/develop/ui/compose/performance/phases
- https://developer.android.com/topic/performance/hardware-accel
- https://mozilla.github.io/geckoview/javadoc/mozilla-central/org/mozilla/geckoview/GeckoView.html
- https://mozilla.github.io/geckoview/javadoc/mozilla-central/org/mozilla/geckoview/GeckoDisplay.ScreenshotBuilder.html

GeckoView 156 is the current dependency in this checkout; there was no evidence of a deliberate low-FPS cap or software-layer override. Changing browser engines is not supported by this evidence.
