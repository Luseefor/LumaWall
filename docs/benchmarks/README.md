# LumaWall power benchmark

Run from the repository root on a Mac with the Swift toolchain and an installed
copy of LumaWall. The script reads process counters as your own user and needs
no sudo. Set each state yourself before running its command. It measures only
matching executable names inside `/Applications/LumaWall.app` by default.
Pass `--app-path "/path/to/LumaWall.app"` for a different installed copy.

## Set up the comparison

1. Keep display count, resolution, refresh rate, brightness, and power source
   fixed across all four states. Use AC for the four commands below. Battery
   Saver selects the battery copy on AC too. If you want to test unplugged
   behavior, repeat the set as a separate comparison and record the power source.
2. Use the same LumaWall build, wallpaper mode, and video across a comparison.
   Pick a source that produces a lower-tier copy, such as a 4K clip. Record the
   build, mode, source resolution and frame rate, and which copy plays on each
   display. For the Full test, use a matching display and source resolution so
   Full Quality selects the Full copy.
3. Disable playlist changes and avoid imports, previews, and other activity
   during measurement. Wait for copy generation and playback transitions to
   settle. Use a small terminal window that leaves the desktop visible. Leave
   the machine awake and unlocked and keep the setup steady until each command
   finishes, about five minutes at the defaults.

## Measure each state

1. **Static wallpaper baseline.** Keep LumaWall open and use the steps for
   the mode you plan to benchmark.

   - **Safe mode (overlay).** In LumaWall → Displays, click **Clear** for each
     assigned wallpaper and check that every display says **No wallpaper
     assigned**. Then choose a still image for every display in macOS System
     Settings → Wallpaper. The overlay can keep playing after a change in
     System Settings alone.
   - **Native mode.** Clear any assignments using the overlay fallback first.
     In macOS System Settings → Wallpaper, replace LumaWall with a still image
     on every display. Check that all native renderers stop.

   Close System Settings and hide LumaWall's main window. On every display,
   verify that the still image is visible and playback has stopped. Use the
   menu bar popover's per-display state when available. In Native mode, you can
   also watch the extension log for a stop event for each active renderer and
   check that playback FPS has dropped to zero where diagnostics are available.
   Record the mode alongside the baseline. Run:

   ```sh
   swift scripts/benchmark-power.swift --label static-baseline --duration 60 --runs 5
   ```

2. **Visible playback at Full.** Reapply the test video, choose **Full
   Quality** in LumaWall, and leave the desktop visible on each test display.
   Check that the video is moving and that the Full copy is playing. Run:

   ```sh
   swift scripts/benchmark-power.swift --label visible-full --duration 60 --runs 5
   ```

3. **Visible playback on the battery copy.** Keep the same video and display
   layout. Select **Battery Saver**, wait for the lower-tier animated copy,
   and verify that each display is playing the lower-tier copy. Check the
   per-display copy and frame rate when available. In Native mode, the
   extension log can confirm the active variant. Wait until the copy has
   switched on every display before running:

   ```sh
   swift scripts/benchmark-power.swift --label visible-battery-copy --duration 60 --runs 5
   ```

4. **Covered and paused.** Return to **Full Quality** and enable **Pause When
   Hidden**. Cover each test display with a full-screen app using the green
   window button, or with an opaque window sized to the entire display,
   including the menu bar area. A normally maximized window can fall below
   the 98.5% coverage threshold. Use a full-screen terminal on the display
   where you start the command. Confirm that each display's pause reason is
   **Covered** in the menu bar popover when that state is available. On older
   builds, verify that every renderer stops or drops to zero FPS as you cover
   the displays, and that playback resumes when you uncover them. Restore
   coverage, confirm the pause again, and keep the windows in place while you
   run:

   ```sh
   swift scripts/benchmark-power.swift --label covered-paused --duration 60 --runs 5
   ```

## Read the results

Each run reports average mW and CPU % for `LumaWall`, `LumaWallWallpaper`,
`LumaWallMediaService`, and their total. CPU % uses one logical CPU as 100% and converts Mach CPU ticks to nanoseconds.
Power uses the difference in the Apple silicon `ri_energy_nj` counter from
`proc_pid_rusage` (V6), divided by elapsed time. It measures
[task energy](https://github.com/apple-oss-distributions/xnu/blob/main/doc/observability/recount.md).
Whole-machine power, including the display and work attributed to system
processes such as WindowServer, is outside the measurement. Power is
unavailable on Intel.

`absent` means the tool found no matching process at either endpoint. This is
common for the idle media service. Processes that start and exit entirely inside
the window can go undetected, so run the benchmark in steady states. Totals sum
the measured processes and are unavailable if any observed process changed or
its counters could not be read. If no matching process was measured, the total
is also unavailable. Check the per-run status and the sample count `n` before
comparing medians. The summary includes only runs with known machine metadata and matching
display-count and power-source readings at the start and end.

The summary gives the median, min, max, and IQR for each metric. IQR is the
75th percentile minus the 25th percentile, using linear interpolation between
sorted samples. Compare the Total medians and report their spread and sample
counts alongside the machine model, chip, macOS version, display count, and
power source.

The script appends one JSON line per completed window and one summary line
per invocation to `/tmp/lumawall-power.jsonl`. Pass `--output <path>` to keep
the log at a different location. Use the session ID to group lines from one
invocation. To check statistics, CPU conversion, and environment matching without sampling processes, run
`swift scripts/benchmark-power.swift --self-test`.

## Results
