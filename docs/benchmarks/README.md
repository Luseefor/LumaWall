# LumaWall power benchmark

Run from the repository root on a Mac with the Swift toolchain and an installed
copy of LumaWall. The script reads process counters as your own user and needs
no sudo. Set each state yourself before running its command.

## Set up the comparison

1. Keep display count, resolution, refresh rate, brightness, and power source
   fixed across all four states. Use AC for the four commands below. Battery
   Saver selects the battery copy on AC too. If you want to test unplugged
   behavior, repeat the set as a separate comparison and record the power source.
2. Use the same LumaWall build and video for all playback states. Record the
   build, video resolution and frame rate, and which copy plays on each display.
   For the Full test, use a matching display and source resolution so Full
   Quality does not select a smaller display-matched copy.
3. Disable playlist changes and avoid imports, previews, and other activity
   during measurement. Wait for copy generation and playback transitions to
   settle. Use a small terminal window that leaves the desktop visible. Leave
   the machine awake and unlocked and keep the setup steady until each command
   finishes, about five minutes at the defaults.

## Measure each state

1. **Static wallpaper baseline.** In macOS System Settings → Wallpaper, select
   a still image on every display. Leave LumaWall idle and hide its main window.
   Run:

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
   and confirm that playback is visible. Run:

   ```sh
   swift scripts/benchmark-power.swift --label visible-battery-copy --duration 60 --runs 5
   ```

4. **Covered and paused.** Return to **Full Quality** and enable **Pause When
   Hidden**. Cover each test display with an opaque window, including the
   display where you start the command. A maximized terminal on that display
   works. Wait for LumaWall to pause for coverage, then keep the windows in
   place and run:

   ```sh
   swift scripts/benchmark-power.swift --label covered-paused --duration 60 --runs 5
   ```

## Read the results

Each run reports average mW and CPU % for `LumaWall`, `LumaWallWallpaper`,
`LumaWallMediaService`, and their total. CPU % uses one logical CPU as 100%.
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
comparing medians. Runs with a detected display-count or power-source change
are excluded from the summary.

The summary gives the median, min, max, and IQR for each metric. IQR is the
75th percentile minus the 25th percentile, using linear interpolation between
sorted samples. Compare the Total medians and report their spread and sample
counts alongside the machine model, chip, macOS version, display count, and
power source.

The script appends one JSON line per completed window and one summary line
per invocation to `/tmp/lumawall-power.jsonl`. Pass `--output <path>` to keep
the log at a different location. Use the session ID to group lines from one
invocation. To check the statistics without sampling processes, run
`swift scripts/benchmark-power.swift --self-test`.

## Results
