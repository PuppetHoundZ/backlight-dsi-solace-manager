# Backlight DSI Solace

An idle-dim screensaver for the official Raspberry Pi DSI touch displays. Runs entirely in **user space** — no sudo after the initial dependency install, no systemd services, no compositor config changes, nothing system-wide.

## Why this exists

The Raspberry Pi Control Center's built-in screen blanking is unreliable on touch displays — it blanks once, then fails to blank again on subsequent idle periods. There's also no way to adjust the timeout from the Control Center UI. Backlight DSI Solace was built to fix both problems with a dedicated, user-space tool made specifically for DSI panels.

## What it does

After a configurable number of seconds with no touch/mouse/keyboard activity, the backlight fades smoothly to zero (screen stays powered — no flicker on wake). The next tap fades it back up to whatever brightness you had set. That's it.

## Features

- **Smooth fade in/out** — configurable fade duration, not an instant on/off
- **Adjustable idle timeout** — set however long you want before it dims
- **GTK3 control panel** — gear icon opens a settings UI; no command line needed for day-to-day use
- **Brightness slider (4–100%)** — floor set at 4% because 1–3% reads as fully black on the official 7" panel
- **Four safety layers against getting stuck dimmed:**
  1. Tapping the screen during a dim always wakes it
  2. Resume signal from the idle daemon always wakes it
  3. Stopping the app from the panel force-restores brightness
  4. A boot guard checks for and corrects a 0% brightness left over from a power loss while dimmed
- **Optional autostart** — off by default; toggle it on from the panel if you want it running every boot
- **HDMI audio re-detect shortcut** — one-tap WirePlumber restart for when HDMI audio devices don't get picked up after a display change
- **Optional logging** — off by default (keeps SD card writes minimal); flip on from settings if you need to troubleshoot
- **Clean uninstall** — removes all configs, caches, and binaries from your user directories; shared system packages are never removed

## Requirements

- Raspberry Pi OS Trixie (Debian 13) with the **labwc** Wayland compositor — this is what the script is built and tested against
- An official Raspberry Pi DSI touch display — the script auto-detects the DSI backlight device and has been confirmed against the official panel specifically. It may work with other DSI panels, but that's untested
- Uses `swayidle` + `ext-idle-notify-v1` for idle detection (not X11, not evdev) — installed automatically as a dependency

## Install

Download the single `.sh` file and run it:

```bash
chmod +x backlight-dsi-solace-manager.sh
./backlight-dsi-solace-manager.sh
```

Choose **Install / Repair** from the menu. It installs dependencies via `apt`, writes the watcher and GUI scripts to `~/.local/share/`, optionally creates a desktop shortcut, and installs the boot guard.

## Using it

1. Launch the control panel (desktop shortcut, or the gear icon from the manager menu)
2. Set your idle timeout and fade duration
3. Adjust the brightness slider to your preferred level
4. Optionally enable autostart if you want it running on every boot
5. Tap **Stop** any time you don't want the screen dimming — for movies, games, anything — then **Start** again with one tap when you're done

## Uninstalling

Run the script again and choose **Uninstall** from the menu. This removes the watcher/GUI scripts, configs, logs, and desktop shortcuts under your user account. Dependencies installed via `apt` (e.g. `swayidle`, GTK3 bindings) are left in place since they may be shared by other software — the script never removes system packages.

## Known limitations

- No gamepad-driven idle reset — this is an upstream `swayidle` limitation, not a bug in this script
- No automatic HDMI hotplug watcher — audio re-detection is a manual one-tap action, by design, to avoid unexpected WirePlumber restarts
- Built and confirmed on Pi OS Trixie / labwc; other compositors (e.g. X11-based desktops, older Bookworm setups) are untested

## Compatibility notes

Confirmed working: Raspberry Pi 4, official 7" DSI touch display, Pi OS Trixie, labwc compositor. If you try it on a different setup, feedback on what works (or doesn't) is welcome.

---

Questions or issues are welcome — open an issue on this repo or reply on the [Raspberry Pi Forums thread](https://forums.raspberrypi.com/) where this was originally shared.
