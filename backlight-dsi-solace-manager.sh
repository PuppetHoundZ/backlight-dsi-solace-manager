#!/usr/bin/env bash
# ============================================================================
# backlight-dsi-solace-manager.sh
# ============================================================================
# AI REFERENCE NOTES — read this block before modifying anything below.
#
# PURPOSE
#   Opt-in idle-dim screensaver for the official Raspberry Pi 7" DSI touch
#   display. After N seconds of inactivity the backlight fades to zero; the
#   next tap wakes it back to the pre-dim level. Never a systemd service,
#   never touches PipeWire, never autostarts unless the user enables it.
#
# CURRENT STATE (🟢 v1.12.1 — GOLD)
#   Hardware : Pi 4, max_brightness=255, device=10-0045, Pi OS Trixie / labwc
#   Watcher  : swayidle + ext-idle-notify-v1 + gtk-layer-shell overlay
#   GUI      : GTK3 control panel; ⚙ gear icon in header opens terminal manager
#   Settings : IDLE_TIMEOUT, FADE_DURATION, FAILSAFE_BRIGHTNESS, LOGGING
#              stored in ~/.config/backlight-dsi-solace/settings.conf
#   Dim order: backlight fades to 0 FIRST, overlay shown AFTER (HW confirmed)
#   Wake order: overlay hides, then brightness fades back up
#   Slider   : 4–100% (1–3% is visually black on the Pi 7" panel)
#   Autostart: opt-in watcher toggle (default OFF); boot guard always on
#   Logging  : off by default; enable via settings for troubleshooting
#   Shortcuts: GUI always in Settings/Preferences; Start/Stop, desktop
#              launcher, and WirePlumber restart shortcut are opt-in prompts
#
# LOCKED DESIGN DECISIONS — do not re-propose without explicit request
#   - Idle detection: swayidle + ext-idle-notify-v1. Not evdev, not X11.
#   - Wake-tap swallow: fullscreen gtk-layer-shell OVERLAY-layer window.
#   - Brightness slider: 4–100%. 1–3% is visually black (non-linear panel
#     luminance, confirmed HW). Watcher may write raw 0 mid-fade — intentional.
#     Raw<->percent conversion at sysfs boundary only (raw_to_pct / pct_to_raw).
#   - Guard thresholds: 0% -> FAILSAFE_BRIGHTNESS; 1–3% -> 10%; >=4% -> leave.
#   - Four safety layers: (1) overlay tap -> undim, (2) swayidle resume ->
#     SIGUSR2 -> undim, (3) manager stop -> unconditional sysfs write,
#     (4) boot guard -> corrects 0% after power-loss-while-dimmed.
#   - No udev rule: raspberrypi-sys-mods grants video group sysfs write access.
#   - Autostart wrapper polls WAYLAND_DISPLAY socket + 10s labwc settle delay.
#   - No gamepad idle reset — swayidle upstream limitation (issues/68). Do not
#     re-propose.
#   - No automatic HDMI audio hot-plug watcher. Manual Re-detect button only.
#   - SIGUSR1/SIGUSR2 delivered via GLib.unix_signal_add() (safe, deferred to
#     next main-loop iteration). Never use raw signal.signal() in GTK process.
#   - GUI all subprocess calls use Popen (non-blocking). _on_redetect_hdmi
#     intentionally uses subprocess.run() (blocking, timeout=10) for
#     success/fail feedback — WirePlumber restart is typically <1s.
#   - watcher and GUI heredocs define APP_SLUG as their own literals. On any
#     future rename, update ALL THREE: bash constant + PYEOF + GUIEOF.
#   - Dependencies never removed on uninstall (project-wide policy).
#   - PID/state files in XDG_RUNTIME_DIR (clears on reboot).
#     last-set-brightness in CONFIG_DIR (persists across reboots).
#
# VERSION HISTORY
#   v1.0.0–v1.10.0 (2026-06-21/22)
#     Initial build through desktop shortcut restructure. Core features:
#     idle-dim watcher, GTK3 layer-shell overlay, monitor targeting via
#     pixel-geometry allowlist + physical-mm fallback, opt-in autostart toggle,
#     brightness boot guard, FAILSAFE_BRIGHTNESS, slider in percent (floor 4%),
#     LOGGING setting (off by default), all GUI subprocess calls non-blocking.
#     Key fixes: dim order (backlight first, overlay after), duplicate wake-tap
#     guard (self.waking flag), dead-man's switch removed (caused ghost wakes),
#     autostart 10s labwc settle delay (layer-shell anchoring race).
#     Rename: "Backlight Solace" -> "Backlight DSI Solace"; one-time migration
#     in Install/Repair carries old settings forward.
#
#   v1.11.0 (2026-06-23) 🟢 GOLD — confirmed on hardware
#     Re-detect HDMI Audio button added to GUI and CLI (menu option 8). Runs
#     `systemctl --user restart wireplumber` on demand. No polling/automation.
#
#   v1.12.0 (2026-06-23) 🟢 GOLD
#     WirePlumber start-menu launcher toggle (checkbox in HDMI Audio card).
#     Writes <slug>-wireplumber.desktop to ~/.local/share/applications so
#     WirePlumber can be restarted from the app menu without opening the GUI.
#     Install/Repair prompts for it opt-in (y/N), same as Start/Stop shortcuts.
#     GUI _quit() hardened: PulseDot timer cancelled via set_state("stopped")
#     before Gtk.main_quit(); nested try blocks under single outer finally so
#     _remove_gui_pidfile() is guaranteed regardless of source_remove raising.
#
#   v1.12.1 (2026-06-23) 🟢 GOLD
#     Watcher shutdown: _on_terminate() cancels fade_source_id before restoring
#     brightness. Without this a 30ms fade step could overwrite the restored
#     level if the main loop processed one more iteration after main_quit().
# ============================================================================

set -Eeuo pipefail
shopt -s nullglob

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
APP_NAME="Backlight DSI Solace"
APP_SLUG="backlight-dsi-solace"

INSTALL_DIR="${HOME}/.local/share/${APP_SLUG}"
CONFIG_DIR="${HOME}/.config/${APP_SLUG}"
SETTINGS_FILE="${CONFIG_DIR}/settings.conf"
DESKTOP_DIR="${HOME}/.local/share/applications"
# WirePlumber start-menu launcher (opt-in, toggled from HDMI Audio card in GUI).
WP_DESKTOP="${DESKTOP_DIR}/${APP_SLUG}-wireplumber.desktop"
# Physical desktop directory for optional pinned launcher icon.
# xdg-user-dir is the correct query on Pi OS; fall back to ~/Desktop if absent.
XDG_DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "${HOME}/Desktop")"
ICON_DIR="${HOME}/.local/share/icons/hicolor/256x256/apps"
ICON_PATH="${ICON_DIR}/${APP_SLUG}.svg"

# Derived from APP_SLUG rather than separately hardcoded — a prior rename
# (v1.3.0, "Backlight Solace" -> "Backlight DSI Solace") missed these when
# they were literal strings, which silently breaks bash<->Python path
# agreement. Keep it this way on any future rename.
SELF_PATH="${INSTALL_DIR}/${APP_SLUG}-manager.sh"
WATCHER_PATH="${INSTALL_DIR}/${APP_SLUG}-watcher.py"
GUI_PATH="${INSTALL_DIR}/${APP_SLUG}-gui.py"
LOG_FILE="${INSTALL_DIR}/${APP_SLUG}.log"
MARKER_FILE="${INSTALL_DIR}/.install_marker"

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
PID_FILE="${RUNTIME_DIR}/${APP_SLUG}.pid"
STATE_FILE="${RUNTIME_DIR}/${APP_SLUG}-last-brightness"

# --- v1.5.0 autostart + boot guard infrastructure --------------------------
# XDG autostart dir. Two entries can live here:
#   1. <slug>-autostart.desktop  — OPT-IN watcher autostart (toggle, default off)
#   2. <slug>-guard.desktop      — ALWAYS-ON brightness safety guard (every login)
AUTOSTART_DIR="${HOME}/.config/autostart"
AUTOSTART_WRAPPER="${INSTALL_DIR}/${APP_SLUG}-autostart.sh"
AUTOSTART_DESKTOP="${AUTOSTART_DIR}/${APP_SLUG}-autostart.desktop"
GUARD_WRAPPER="${INSTALL_DIR}/${APP_SLUG}-guard.sh"
GUARD_DESKTOP="${AUTOSTART_DIR}/${APP_SLUG}-guard.desktop"

# Persisted in CONFIG_DIR (NOT runtime) so it survives reboot — records the
# last brightness the user deliberately set via the GUI slider, in percent.
# The boot guard reads it only for its diagnostic log line; it does not drive
# the guard's decision tree.
LAST_SET_BRIGHTNESS_FILE="${CONFIG_DIR}/last-set-brightness"

# One-time migration support (v1.3.0 rename) — the slug this app used
# before being renamed from "Backlight Solace". Used only by
# migrate_from_old_name() in cmd_install to find and clean up a prior
# install under the old name. Not used anywhere else; do not repurpose.
OLD_APP_SLUG="backlight-solace"
OLD_INSTALL_DIR="${HOME}/.local/share/${OLD_APP_SLUG}"
OLD_CONFIG_DIR="${HOME}/.config/${OLD_APP_SLUG}"
OLD_SETTINGS_FILE="${OLD_CONFIG_DIR}/settings.conf"
OLD_ICON_PATH="${ICON_DIR}/${OLD_APP_SLUG}.svg"
OLD_PID_FILE="${RUNTIME_DIR}/${OLD_APP_SLUG}.pid"
OLD_GUI_PID_FILE="${RUNTIME_DIR}/${OLD_APP_SLUG}-gui.pid"
OLD_STATE_FILE="${RUNTIME_DIR}/${OLD_APP_SLUG}-last-brightness"

DEPS=(swayidle gir1.2-gtklayershell-0.1 python3-gi gir1.2-gtk-3.0)

DEFAULT_IDLE_TIMEOUT=90
DEFAULT_FADE_DURATION=1.5
DEFAULT_FAILSAFE_BRIGHTNESS=50   # percent; boot guard target when it finds 0%
DEFAULT_LOGGING="false"          # logging off by default; enable for troubleshooting
SCRIPT_VERSION="1.12.1"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
c_red=$'\033[0;31m'; c_green=$'\033[0;32m'; c_yellow=$'\033[0;33m'
c_blue=$'\033[0;34m'; c_bold=$'\033[1m'; c_reset=$'\033[0m'

info()    { printf '%s\n' "${c_blue}[i]${c_reset} $*"; }
success() { printf '%s\n' "${c_green}[OK]${c_reset} $*"; }
warn()    { printf '%s\n' "${c_yellow}[!]${c_reset} $*"; }
err()     { printf '%s\n' "${c_red}[ERROR]${c_reset} $*" >&2; }
heading() { printf '\n%s\n' "${c_bold}== $* ==${c_reset}"; }

# ---------------------------------------------------------------------------
# Crash recovery / rollback (standing rule for all manager scripts)
# ---------------------------------------------------------------------------
_LAST_CMD=""
trap '_LAST_CMD=${BASH_COMMAND}' DEBUG

_rollback_cleanup() {
    local exit_code=$? line_no=${1:-${LINENO}}
    err "Failed command (exit ${exit_code}), line ${line_no}: ${_LAST_CMD}"
    warn "Rolling back partial changes from this run..."
    rm -f "${MARKER_FILE}" 2>/dev/null || true
    warn "Rollback complete. Re-run 'Install / Repair' to try again."
    return 0
}

_on_exit() {
    local real_exit=$?
    exit "${real_exit}"
}

trap '_rollback_cleanup ${LINENO}' ERR
trap '_on_exit' EXIT

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
ensure_settings_file() {
    mkdir -p "${CONFIG_DIR}"
    if [[ ! -f "${SETTINGS_FILE}" ]]; then
        cat > "${SETTINGS_FILE}" <<EOF
# Backlight DSI Solace settings — edit via the manager menu (option 4) or by hand.
IDLE_TIMEOUT=${DEFAULT_IDLE_TIMEOUT}
FADE_DURATION=${DEFAULT_FADE_DURATION}
# Boot guard target (percent, 50-100) when it finds the screen at 0% after a
# power loss while dimmed. See the "Boot Guard" notes in the manager.
FAILSAFE_BRIGHTNESS=${DEFAULT_FAILSAFE_BRIGHTNESS}
# Enable watcher logging (true/false). Off by default — SD card friendly.
# Turn on temporarily when troubleshooting unexpected behaviour.
LOGGING=${DEFAULT_LOGGING}
EOF
        success "Created default settings (idle ${DEFAULT_IDLE_TIMEOUT}s, fade ${DEFAULT_FADE_DURATION}s, failsafe ${DEFAULT_FAILSAFE_BRIGHTNESS}%, logging ${DEFAULT_LOGGING})."
    else
        # Migrate pre-v1.5.0: add FAILSAFE_BRIGHTNESS if missing
        if ! grep -q "^FAILSAFE_BRIGHTNESS=" "${SETTINGS_FILE}" 2>/dev/null; then
            {
                echo "# Boot guard target (percent, 50-100) when it finds the screen at 0%"
                echo "# after a power loss while dimmed. Added by v1.5.0."
                echo "FAILSAFE_BRIGHTNESS=${DEFAULT_FAILSAFE_BRIGHTNESS}"
            } >> "${SETTINGS_FILE}"
            info "Added FAILSAFE_BRIGHTNESS=${DEFAULT_FAILSAFE_BRIGHTNESS}% to your existing settings."
        fi
        # Migrate pre-v1.9.0: add LOGGING if missing
        if ! grep -q "^LOGGING=" "${SETTINGS_FILE}" 2>/dev/null; then
            {
                echo "# Enable watcher logging (true/false). Off by default — SD card friendly."
                echo "# Turn on temporarily when troubleshooting unexpected behaviour."
                echo "LOGGING=${DEFAULT_LOGGING}"
            } >> "${SETTINGS_FILE}"
            info "Added LOGGING=${DEFAULT_LOGGING} to your existing settings."
        fi
    fi
}

read_settings() {
    IDLE_TIMEOUT="${DEFAULT_IDLE_TIMEOUT}"
    FADE_DURATION="${DEFAULT_FADE_DURATION}"
    FAILSAFE_BRIGHTNESS="${DEFAULT_FAILSAFE_BRIGHTNESS}"
    LOGGING="${DEFAULT_LOGGING}"
    if [[ -f "${SETTINGS_FILE}" ]]; then
        local _val
        _val=$(grep -m1 "^IDLE_TIMEOUT=" "${SETTINGS_FILE}" | cut -d= -f2-)
        [[ -n "${_val}" ]] && IDLE_TIMEOUT="${_val}"
        _val=$(grep -m1 "^FADE_DURATION=" "${SETTINGS_FILE}" | cut -d= -f2-)
        [[ -n "${_val}" ]] && FADE_DURATION="${_val}"
        _val=$(grep -m1 "^FAILSAFE_BRIGHTNESS=" "${SETTINGS_FILE}" | cut -d= -f2-)
        [[ -n "${_val}" ]] && FAILSAFE_BRIGHTNESS="${_val}"
        _val=$(grep -m1 "^LOGGING=" "${SETTINGS_FILE}" | cut -d= -f2-)
        [[ -n "${_val}" ]] && LOGGING="${_val}"
    fi
}

cmd_edit_settings() {
    read_settings
    heading "Edit Settings"
    echo "Current idle timeout : ${IDLE_TIMEOUT}s"
    echo "Current fade duration : ${FADE_DURATION}s"
    echo
    warn "Heads up: touch, mouse, and keyboard activity all reset the idle timer."
    warn "Most video playback (e.g. Chrome) also resets it. PS4 controller users:"
    warn "the touchpad works in pointer mode and resets the timer too. Standard"
    warn "controller buttons and analog sticks do NOT reset the timer — this is a"
    warn "wlroots/swayidle limitation (github.com/swaywm/swayidle/issues/68)."
    warn "If gaming with buttons only, use the Stop option to disable dimming."
    echo

    local new_timeout new_fade
    read -r -p "New idle timeout in seconds [${IDLE_TIMEOUT}]: " new_timeout
    new_timeout="${new_timeout:-${IDLE_TIMEOUT}}"
    if ! [[ "${new_timeout}" =~ ^[0-9]+$ ]] || (( new_timeout < 5 || new_timeout > 3600 )); then
        warn "Invalid value, keeping ${IDLE_TIMEOUT}s (must be a whole number 5-3600)."
        new_timeout="${IDLE_TIMEOUT}"
    fi

    read -r -p "New fade duration in seconds [${FADE_DURATION}]: " new_fade
    new_fade="${new_fade:-${FADE_DURATION}}"
    if ! [[ "${new_fade}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || \
       ! python3 -c "import sys; v=float('${new_fade}'); sys.exit(0 if 0.1 <= v <= 10 else 1)" 2>/dev/null; then
        warn "Invalid value, keeping ${FADE_DURATION}s (must be 0.1-10)."
        new_fade="${FADE_DURATION}"
    fi

    echo
    info "Failsafe brightness: if the screen is found at 0% after a power loss"
    info "while dimmed, the boot guard restores it to this level (50-100%)."
    local new_failsafe
    read -r -p "New failsafe brightness percent [${FAILSAFE_BRIGHTNESS}]: " new_failsafe
    new_failsafe="${new_failsafe:-${FAILSAFE_BRIGHTNESS}}"
    if ! [[ "${new_failsafe}" =~ ^[0-9]+$ ]] || (( new_failsafe < 50 || new_failsafe > 100 )); then
        warn "Invalid value, keeping ${FAILSAFE_BRIGHTNESS}% (must be a whole number 50-100)."
        new_failsafe="${FAILSAFE_BRIGHTNESS}"
    fi

    echo
    info "Logging: when enabled, the watcher writes to ${LOG_FILE}."
    info "Off by default (SD card friendly). Enable only when troubleshooting."
    local new_logging
    read -r -p "Enable logging? (true/false) [${LOGGING}]: " new_logging
    new_logging="${new_logging:-${LOGGING}}"
    if [[ "${new_logging}" != "true" && "${new_logging}" != "false" ]]; then
        warn "Invalid value, keeping ${LOGGING} (must be true or false)."
        new_logging="${LOGGING}"
    fi

    cat > "${SETTINGS_FILE}" <<EOF
# Backlight DSI Solace settings — edit via the manager menu (option 4) or by hand.
IDLE_TIMEOUT=${new_timeout}
FADE_DURATION=${new_fade}
# Boot guard target (percent, 50-100) when it finds the screen at 0% after a
# power loss while dimmed. See the "Boot Guard" notes in the manager.
FAILSAFE_BRIGHTNESS=${new_failsafe}
# Enable watcher logging (true/false). Off by default — SD card friendly.
# Turn on temporarily when troubleshooting unexpected behaviour.
LOGGING=${new_logging}
EOF
    success "Saved: idle timeout ${new_timeout}s, fade duration ${new_fade}s, failsafe ${new_failsafe}%, logging ${new_logging}."

    # Re-write the guard wrapper so it picks up the new failsafe value (the
    # value is baked into the wrapper at write time as a default, though the
    # wrapper also re-reads settings.conf live at each boot).
    if [[ -f "${GUARD_WRAPPER}" ]]; then
        write_guard_wrapper >/dev/null 2>&1 || true
    fi

    if is_running; then
        warn "${APP_NAME} is currently running with the old values."
        read -r -p "Restart it now to apply the new settings? [y/N]: " ans
        if [[ "${ans,,}" == "y" ]]; then
            cmd_stop
            cmd_start
        else
            info "New values will apply next time you start it."
        fi
    fi
}

# ---------------------------------------------------------------------------
# Dependency handling — install missing only, NEVER remove on uninstall
# ---------------------------------------------------------------------------
check_deps() {
    local missing=()
    for pkg in "${DEPS[@]}"; do
        if ! dpkg -s "${pkg}" >/dev/null 2>&1; then
            missing+=("${pkg}")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        info "Installing missing dependencies: ${missing[*]}"
        sudo apt-get update -qq
        sudo apt-get install -y "${missing[@]}"
        success "Dependencies installed."
    else
        success "All dependencies already present."
    fi
}

# ---------------------------------------------------------------------------
# Backlight device sanity check (real detection happens in the Python watcher;
# this is just an install-time confidence check for the user)
# ---------------------------------------------------------------------------
check_backlight_device() {
    local found=""
    for dir in /sys/class/backlight/*/; do
        [[ -e "${dir}display_name" ]] || continue
        if grep -q "DSI" "${dir}display_name" 2>/dev/null; then
            found="${dir}"
            break
        fi
    done
    if [[ -z "${found}" ]]; then
        found=$(ls -d /sys/class/backlight/*/ 2>/dev/null | head -n1 || true)
    fi
    if [[ -z "${found}" ]]; then
        err "No backlight device found under /sys/class/backlight. Is the official touch display connected?"
        return 1
    fi
    info "Backlight device: ${found}"
    local bperm
    bperm=$(stat -c '%U:%G %a' "${found}brightness" 2>/dev/null || echo "unknown")
    info "Brightness file permissions: ${bperm}"
    if ! groups | grep -qw video; then
        warn "Your user is not in the 'video' group — brightness writes may need sudo."
        warn "Fix with: sudo usermod -aG video \$USER (then log out/in)."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Watcher script (the actual GTK process that does the dimming/waking)
# ---------------------------------------------------------------------------
write_watcher_script() {
    mkdir -p "${INSTALL_DIR}"
    cat > "${WATCHER_PATH}" <<'PYEOF'
#!/usr/bin/env python3
"""
backlight-dsi-solace-watcher.py

Long-running GTK3 process. See backlight-dsi-solace-manager.sh AI REFERENCE NOTES
for the full design rationale, especially the four "never stuck blank"
safety nets referenced in the comments below.
"""
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("GtkLayerShell", "0.1")
from gi.repository import Gtk, Gdk, GLib, GtkLayerShell

import os
import sys
import atexit
import glob
import signal
import subprocess
import time

APP_SLUG = "backlight-dsi-solace"
CONFIG_DIR = os.path.expanduser(f"~/.config/{APP_SLUG}")
SETTINGS_FILE = os.path.join(CONFIG_DIR, "settings.conf")
INSTALL_DIR = os.path.expanduser(f"~/.local/share/{APP_SLUG}")
LOG_FILE = os.path.join(INSTALL_DIR, "backlight-dsi-solace.log")
RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
PID_FILE = os.path.join(RUNTIME_DIR, f"{APP_SLUG}.pid")
STATE_FILE = os.path.join(RUNTIME_DIR, f"{APP_SLUG}-last-brightness")

DEFAULT_TIMEOUT = 90
DEFAULT_FADE = 1.5

# Module-level flag set once at startup from settings. All log() calls check
# this before doing any file I/O — when False, log() is a true no-op.
LOGGING_ENABLED = False
LOG_SIZE_LIMIT  = 51200   # 50KB — trim when exceeded
LOG_KEEP_LINES  = 100     # lines to retain after trim


def log(msg):
    if not LOGGING_ENABLED:
        return
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line, flush=True)
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        # Trim before appending if the file has grown too large.
        try:
            if os.path.getsize(LOG_FILE) > LOG_SIZE_LIMIT:
                with open(LOG_FILE) as f:
                    lines = f.readlines()
                with open(LOG_FILE, "w") as f:
                    f.writelines(lines[-LOG_KEEP_LINES:])
        except FileNotFoundError:
            pass  # file doesn't exist yet — nothing to trim
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


def read_settings():
    timeout, fade = DEFAULT_TIMEOUT, DEFAULT_FADE
    logging_enabled = False  # default off — SD card friendly
    try:
        with open(SETTINGS_FILE) as f:
            for raw in f:
                line = raw.strip()
                if line.startswith("IDLE_TIMEOUT="):
                    timeout = int(line.split("=", 1)[1])
                elif line.startswith("FADE_DURATION="):
                    fade = float(line.split("=", 1)[1])
                elif line.startswith("LOGGING="):
                    logging_enabled = line.split("=", 1)[1].strip().lower() == "true"
    except Exception as e:
        # Cannot use log() here — LOGGING_ENABLED not set yet.
        print(f"[warn] could not read settings ({e}), using defaults", flush=True)
    return timeout, fade, logging_enabled


def detect_backlight_dir():
    candidates = sorted(glob.glob("/sys/class/backlight/*"))
    chosen = None
    for c in candidates:
        name_file = os.path.join(c, "display_name")
        try:
            with open(name_file) as f:
                if "DSI" in f.read():
                    chosen = c
                    break
        except Exception:
            continue
    if not chosen and candidates:
        chosen = candidates[0]
        log(f"WARN: no DSI-named backlight found, falling back to {chosen}")
    if not chosen:
        log("FATAL: no backlight device found under /sys/class/backlight")
        sys.exit(1)
    return chosen


class BacklightSolace:
    def __init__(self):
        global LOGGING_ENABLED
        self.idle_timeout, self.fade_duration, LOGGING_ENABLED = read_settings()
        self.bl_dir = detect_backlight_dir()
        self.brightness_path = os.path.join(self.bl_dir, "brightness")
        self.max_brightness = self._read_int(
            os.path.join(self.bl_dir, "max_brightness"), 255
        )
        self.last_active_brightness = self._read_int(
            self.brightness_path, self.max_brightness
        )
        if self.last_active_brightness <= 0:
            self.last_active_brightness = self.max_brightness
        self._persist_last_active()

        self.dimmed = False
        self.waking = False
        self.fade_source_id = None
        self.swayidle_proc = None
        self.overlay = None

        self._build_overlay()
        self._write_pidfile()
        self._start_swayidle()
        self._install_signal_handlers()

        log(
            f"Backlight DSI Solace started. device={self.bl_dir} "
            f"timeout={self.idle_timeout}s fade={self.fade_duration}s "
            f"max_brightness={self.max_brightness}"
        )

    # -- sysfs helpers ----------------------------------------------------
    @staticmethod
    def _read_int(path, default):
        try:
            with open(path) as f:
                return int(f.read().strip())
        except Exception:
            return default

    def _write_brightness(self, value):
        value = max(0, min(self.max_brightness, int(round(value))))
        try:
            with open(self.brightness_path, "w") as f:
                f.write(str(value))
        except Exception as e:
            log(f"ERROR writing brightness: {e}")

    def _persist_last_active(self):
        # Shared with backlight-dsi-solace-manager.sh's force_restore_brightness
        # so "Stop" restores to this captured value instead of a blind 100%.
        try:
            with open(STATE_FILE, "w") as f:
                f.write(str(self.last_active_brightness))
        except Exception as e:
            log(f"WARN: could not persist brightness state: {e}")

    # -- overlay: swallows the wake-tap so it doesn't hit the app below ---
    # Known pixel geometries of official Raspberry Pi DSI touch panels.
    # Original 7" Touch Display: 800x480 (Raspberry Pi product brief,
    # datasheets.raspberrypi.com/display/7-inch-display-product-brief.pdf).
    # Touch Display 2: 1280x720 landscape / 720x1280 portrait-default
    # (raspberrypi.com/documentation/accessories/touch-display-2.html;
    # confirmed via forums.raspberrypi.com/viewtopic.php?t=379738 showing
    # "video=DSI-1:1280x720@60" as the standard landscape config). The 5"
    # Touch Display 2 variant uses this exact same 720x1280 resolution —
    # confirmed via raspberrypi.com/news/a-new-5-variant-of-raspberry-pi-
    # touch-display-2/ ("keeps the same 1280x720 resolution... as its
    # bigger sibling") — so it's already covered by this same tuple, no
    # separate entry needed. The two sizes only differ at the device-tree
    # level (vc4-kms-dsi-ili9881-5inch vs -7inch overlay name), which has
    # no bearing on anything in this script. Listed here as a static
    # allowlist rather than detected dynamically — GTK3's Gdk.Monitor has
    # no public API for the DRM/Wayland connector name (e.g. "DSI-1");
    # that was only added in GTK4's get_connector(). Adding a new official
    # panel resolution in the future just means adding a tuple here.
    KNOWN_TOUCH_PANEL_SIZES = {(800, 480), (1280, 720), (720, 1280)}

    def _select_target_monitor(self):
        # Explicitly target the touchscreen by geometry. Without this,
        # gtk-layer-shell leaves monitor placement up to the compositor's
        # default, which is not guaranteed to be the touch display when the
        # 1080p HDMI secondary is also connected — and this whole feature
        # is pointless if it dims/overlays the wrong screen.
        display = Gdk.Display.get_default()
        if display is None:
            return None
        try:
            n = display.get_n_monitors()
        except Exception:
            return None

        # Pass 1: exact match against known official-panel resolutions.
        # Checked first and separately from the fallback loop so a known
        # panel is always preferred over a same-or-smaller-area imposter.
        for i in range(n):
            mon = display.get_monitor(i)
            if mon is None:
                continue
            geo = mon.get_geometry()
            if (geo.width, geo.height) in self.KNOWN_TOUCH_PANEL_SIZES:
                return mon

        # Pass 2: nothing matched a known official panel size (unrecognized
        # hardware, or a future official display not yet in the allowlist
        # above). Fall back to the physically smallest connected display —
        # both official touch panels are 7" diagonal, so physical size (mm,
        # reported by the compositor from the DSI panel's mode) is a more
        # reliable discriminator against a typically much larger HDMI
        # monitor than pixel area alone. Falls back to pixel area only if
        # the compositor reports 0x0 physical size for an output.
        chosen, smallest_key = None, None
        for i in range(n):
            mon = display.get_monitor(i)
            if mon is None:
                continue
            geo = mon.get_geometry()
            w_mm, h_mm = mon.get_width_mm(), mon.get_height_mm()
            phys_area = w_mm * h_mm
            key = phys_area if phys_area > 0 else (geo.width * geo.height)
            if smallest_key is None or key < smallest_key:
                smallest_key = key
                chosen = mon
        if chosen is not None:
            geo = chosen.get_geometry()
            log(
                f"WARN: no known official touch-panel resolution matched "
                f"(saw {geo.width}x{geo.height}) — falling back to the "
                "physically smallest connected display for the overlay."
            )
        return chosen

    def _build_overlay(self):
        win = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
        GtkLayerShell.init_for_window(win)
        GtkLayerShell.set_layer(win, GtkLayerShell.Layer.OVERLAY)

        monitor = self._select_target_monitor()
        if monitor is not None:
            GtkLayerShell.set_monitor(win, monitor)

        for edge in (
            GtkLayerShell.Edge.TOP,
            GtkLayerShell.Edge.BOTTOM,
            GtkLayerShell.Edge.LEFT,
            GtkLayerShell.Edge.RIGHT,
        ):
            GtkLayerShell.set_anchor(win, edge, True)
            GtkLayerShell.set_margin(win, edge, 0)
        GtkLayerShell.set_exclusive_zone(win, -1)

        win.set_decorated(False)
        win.set_app_paintable(True)
        # All four edges are anchored with 0 margin and exclusive_zone -1
        # above, so the compositor stretches this surface to fill whichever
        # monitor it's placed on regardless of this initial size — this is
        # just the pre-realization hint, sized to the actual target monitor
        # when known so there's no momentary mismatch on first show.
        if monitor is not None:
            mgeo = monitor.get_geometry()
            win.set_default_size(mgeo.width, mgeo.height)
        else:
            win.set_default_size(800, 480)

        screen = win.get_screen()
        visual = screen.get_rgba_visual()
        if visual:
            win.set_visual(visual)

        win.connect("draw", self._on_overlay_draw)
        win.add_events(Gdk.EventMask.TOUCH_MASK | Gdk.EventMask.BUTTON_PRESS_MASK)
        win.connect("button-press-event", self._on_wake_event)
        win.connect("touch-event", self._on_wake_event)

        self.overlay = win

    @staticmethod
    def _on_overlay_draw(_widget, cr):
        cr.set_source_rgba(0, 0, 0, 1)
        cr.paint()
        return False

    def _on_wake_event(self, *_args):
        # GTK3 synthesises both a touch-event AND a button-press-event from a
        # single physical tap on a touchscreen. Without this guard, one tap
        # fires this handler 2-4 times before _start_undim() clears self.dimmed,
        # producing multiple identical log lines. self.waking is set here and
        # cleared in _start_undim() once the undim is fully underway.
        if self.waking:
            return True
        self.waking = True
        log("Wake-tap received on overlay (primary path)")
        self._start_undim()
        return True  # swallow — do not propagate to whatever is underneath

    # -- idle trigger via swayidle (labwc's ext-idle-notify-v1) ------------
    def _write_pidfile(self):
        try:
            with open(PID_FILE, "w") as f:
                f.write(str(os.getpid()))
        except Exception as e:
            log(f"WARN: could not write pidfile: {e}")

    def _start_swayidle(self):
        my_pid = os.getpid()
        cmd = [
            "swayidle", "-w",
            "timeout", str(self.idle_timeout), f"kill -USR1 {my_pid}",
            "resume", f"kill -USR2 {my_pid}",
        ]
        try:
            self.swayidle_proc = subprocess.Popen(cmd)
            log(f"swayidle started (pid {self.swayidle_proc.pid})")
            GLib.timeout_add_seconds(2, self._check_swayidle_health)
        except FileNotFoundError:
            log(
                "ERROR: swayidle binary not found — idle-based dimming is "
                "disabled, but the watcher will still run (no auto-dim, "
                "no risk of a stuck blank screen)."
            )
            self.swayidle_proc = None

    def _check_swayidle_health(self):
        # One-shot, ~2s after launch: catches an early protocol/compositor
        # failure that Popen() itself can't detect (it only fails if the
        # binary is missing, not if it starts and immediately exits).
        if self.swayidle_proc is not None and self.swayidle_proc.poll() is not None:
            log(
                f"WARN: swayidle exited early (code {self.swayidle_proc.returncode}) "
                "— idle-based auto-dim will not trigger. Manual wake/Stop are "
                "unaffected."
            )
        return False

    def _install_signal_handlers(self):
        for sig in (signal.SIGTERM, signal.SIGINT):
            GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, sig, self._on_terminate, sig)
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR1, self._on_sigusr1)
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR2, self._on_sigusr2)

    def _on_sigusr1(self):
        log("Idle timeout reached — dimming")
        self._start_dim()
        return True

    def _on_sigusr2(self):
        # Safety net #2: swayidle's own resume event, completely independent
        # of whether the overlay's GTK touch handler fired.
        log("swayidle resume signal received — undimming (backup path)")
        self._start_undim()
        return True

    # -- dim / undim animation --------------------------------------------
    def _start_dim(self):
        if self.dimmed:
            return
        self.dimmed = True
        self.waking = False  # reset each dim cycle — guards against a prior
        # _on_wake_event setting waking=True in the same moment _start_undim()
        # returned early (not dimmed), which would leave waking stuck True and
        # prevent the next wake-tap from being recognised.

        current = self._read_int(self.brightness_path, self.max_brightness)
        if current > 0:
            self.last_active_brightness = current
        self._persist_last_active()

        # Fade the backlight FIRST, then show the overlay. Showing the overlay
        # before the fade caused an instant black screen followed by a slow
        # backlight fade — visually jarring and backwards. The overlay only
        # needs to be up to catch the wake-tap, which can't happen until the
        # screen is dark anyway. Confirmed on hardware 2026-06-22.
        self._animate(self.last_active_brightness, 0, self._after_dim)

    def _after_dim(self):
        # Show the overlay NOW — backlight is already at zero, so the overlay
        # appears on a dark screen (invisible to the user) and is ready to
        # swallow the next tap. This is the correct order: dim then cover.
        self.overlay.show_all()
        log("Dim complete")

    def _start_undim(self):
        if not self.dimmed:
            return
        self.dimmed = False
        self.waking = False

        # Hide the overlay right away. It only needs to exist long enough
        # to swallow the single wake-tap that triggered this — that tap was
        # already consumed by the overlay's own event handler before this
        # method ran, so hiding it now doesn't let that tap "leak" through.
        # Keeping it up during the fade caused a visible black screen for
        # the full fade duration instead of a normal brightening wake.
        if self.overlay:
            self.overlay.hide()

        target = self.last_active_brightness or self.max_brightness
        current = self._read_int(self.brightness_path, 0)
        self._animate(current, target, self._after_undim)

    def _after_undim(self):
        log("Undim complete")

    def _animate(self, start, end, on_complete):
        if self.fade_source_id is not None:
            GLib.source_remove(self.fade_source_id)
            self.fade_source_id = None

        steps = max(1, int(self.fade_duration / 0.03))
        delta = (end - start) / steps
        state = {"i": 0, "value": float(start)}

        def step():
            state["i"] += 1
            state["value"] += delta
            self._write_brightness(state["value"])
            if state["i"] >= steps:
                self._write_brightness(end)
                self.fade_source_id = None
                on_complete()
                return False
            return True

        self.fade_source_id = GLib.timeout_add(30, step)

    # -- clean shutdown -----------------------------------------------------
    def _on_terminate(self, sig):
        log(f"Received signal {sig}, restoring brightness and exiting cleanly")
        # Cancel any in-progress fade timer first. _write_brightness() below
        # restores the active level; without this cancel, a 30ms fade step
        # could fire after the restore and overwrite it with a mid-fade value
        # if the main loop processes one more iteration after main_quit().
        if self.fade_source_id is not None:
            try:
                GLib.source_remove(self.fade_source_id)
            except Exception:
                pass
            self.fade_source_id = None
        try:
            self._write_brightness(self.last_active_brightness or self.max_brightness)
        except Exception:
            pass
        if self.swayidle_proc is not None:
            try:
                self.swayidle_proc.terminate()
            except Exception:
                pass
        try:
            os.remove(PID_FILE)
        except Exception:
            pass
        Gtk.main_quit()
        return False


def _another_instance_running():
    try:
        with open(PID_FILE) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        return pid != os.getpid()
    except Exception:
        return False


def main():
    os.makedirs(INSTALL_DIR, exist_ok=True)
    if _another_instance_running():
        log(
            "Another Backlight DSI Solace watcher is already running — exiting "
            "to avoid two instances fighting over the same backlight device."
        )
        sys.exit(0)
    # Belt-and-suspenders PID cleanup: atexit fires on any exit path that
    # doesn't call os._exit() directly — covers clean return, unhandled
    # exception after re-raise, and sys.exit(). _on_terminate() also removes
    # the file explicitly on SIGTERM/SIGINT; this catches the crash path where
    # the signal handler never runs (v1.4.1 fix for stale-PID bug).
    atexit.register(lambda: (os.remove(PID_FILE) if os.path.exists(PID_FILE) else None))
    app = BacklightSolace()
    try:
        Gtk.main()
    except Exception as e:
        log(f"FATAL: unhandled exception in main loop: {e}")
        try:
            app._write_brightness(app.last_active_brightness or app.max_brightness)
        except Exception:
            pass
        try:
            os.remove(PID_FILE)
        except Exception:
            pass
        raise


if __name__ == "__main__":
    main()
PYEOF
    chmod +x "${WATCHER_PATH}"
}

# ---------------------------------------------------------------------------
# GUI control panel (toggle + brightness slider + settings)
# ---------------------------------------------------------------------------
write_gui_script() {
    mkdir -p "${INSTALL_DIR}"
    cat > "${GUI_PATH}" <<'GUIEOF'
#!/usr/bin/env python3
# =============================================================================
# backlight-dsi-solace-gui.py
# Generated by backlight-dsi-solace-manager.sh — re-run Install / Repair to update.
#
# Style matches the Solace family (Cava Solace / AirPlay Solace): dark
# #111118 theme, hover glows, pulsing status dot, same color palette and
# card/button CSS classes.
#
# Start/Stop here shell out to backlight-dsi-solace-manager.sh so this GUI never
# duplicates the safety-net logic that lives there.
# =============================================================================
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Pango", "1.0")
from gi.repository import Gtk, Gdk, GLib, Pango
import cairo
import math
import os
import atexit
import glob
import subprocess

# ── Path constants — must mirror the bash manager's definitions exactly ──────
APP_SLUG     = "backlight-dsi-solace"
CONFIG_DIR   = os.path.expanduser(f"~/.config/{APP_SLUG}")
SETTINGS_FILE = os.path.join(CONFIG_DIR, "settings.conf")
INSTALL_DIR  = os.path.expanduser(f"~/.local/share/{APP_SLUG}")
MANAGER_SCRIPT = os.path.join(INSTALL_DIR, f"{APP_SLUG}-manager.sh")
# ─────────────────────────────────────────────────────────────────────────────
RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
PID_FILE = os.path.join(RUNTIME_DIR, f"{APP_SLUG}.pid")
# Persisted (survives reboot) record of the last brightness the user set via
# the slider, in PERCENT. The boot guard reads it for its diagnostic log.
LAST_SET_BRIGHTNESS_FILE = os.path.join(CONFIG_DIR, "last-set-brightness")

# XDG autostart entry for the OPT-IN watcher autostart toggle. The GUI checks
# for this file's existence to reflect the toggle state; it shells out to the
# manager's enable-autostart / disable-autostart subcommands to change it.
AUTOSTART_DESKTOP = os.path.expanduser(
    f"~/.config/autostart/{APP_SLUG}-autostart.desktop"
)

# Optional start-menu launcher for the WirePlumber restart action (HDMI audio
# re-detect). Toggled from the HDMI Audio card; existence drives checkbox state.
DESKTOP_DIR  = os.path.expanduser("~/.local/share/applications")
WP_DESKTOP   = os.path.join(DESKTOP_DIR, f"{APP_SLUG}-wireplumber.desktop")

DEFAULT_TIMEOUT = 90
DEFAULT_FADE = 1.5


# ── Percent <-> raw sysfs helpers ───────────────────────────────────────────
# The kernel's brightness file is in raw units (0..max_brightness). The GUI
# shows and stores PERCENT (1..100). These convert between the two. Raw values
# are used only at the sysfs read/write boundary; everything user-facing is
# percent (v1.5.0).
def raw_to_pct(raw, maxb):
    if maxb <= 0:
        return 100
    return min(100, max(1, round(raw / maxb * 100)))

def pct_to_raw(pct, maxb):
    pct = min(100, max(1, int(pct)))
    return min(maxb, max(1, round(maxb * pct / 100)))

# ── Color palette — matches Cava Solace / AirPlay Solace dark theme ────────
ACCENT_GREEN = (0.118, 0.843, 0.376)
ACCENT_AMBER = (0.980, 0.741, 0.184)
FG_DIM       = (0.314, 0.314, 0.439)

# ── CSS — identical structure and feel to Cava Solace / AirPlay Solace ─────
CSS = b"""
window {
    background-color: #111118;
}
.card {
    background-color: #191922;
    border-radius: 12px;
    padding: 8px;
}
.card2 {
    background-color: #20202a;
    border-radius: 10px;
    padding: 7px;
}
.btn-primary {
    background: #1ebdd1;
    color: #111118;
    border-radius: 10px;
    border: none;
    padding: 7px 14px;
    font-weight: bold;
    font-size: 13px;
    transition: all 120ms ease;
}
.btn-primary:hover {
    background: #38d8ef;
    box-shadow: 0 0 14px rgba(30,189,209,0.55);
}
.btn-primary:active {
    background: #0fa8bc;
}
.btn-stop {
    background: #1a1a2a;
    color: #fabf2f;
    border-radius: 10px;
    border: 1px solid #fabf2f;
    padding: 7px 14px;
    font-weight: bold;
    font-size: 13px;
    transition: all 120ms ease;
}
.btn-stop:hover {
    background: #2a2a1a;
    box-shadow: 0 0 14px rgba(250,191,47,0.45);
}
.btn-muted {
    background: #191922;
    color: #505070;
    border-radius: 10px;
    border: 1px solid #28283a;
    padding: 7px 14px;
    font-size: 12px;
    transition: all 120ms ease;
}
.btn-muted:hover {
    background: #20202e;
    color: #7070a0;
    box-shadow: 0 0 10px rgba(80,80,112,0.3);
}
/* Compact square icon button - same colours as btn-muted, tight padding for
   inline use in the header bar. Used for the Manager gear button (v1.5.1). */
.btn-icon {
    background: #191922;
    color: #505070;
    border-radius: 8px;
    border: 1px solid #28283a;
    padding: 4px 6px;
    font-size: 13px;
    transition: all 120ms ease;
}
.btn-icon:hover {
    background: #20202e;
    color: #9090b8;
    box-shadow: 0 0 8px rgba(80,80,112,0.3);
}
/* btn-close removed in v1.5.1 - Close button removed (use window X instead) */
.label-title {
    color: #e0e0f0;
    font-size: 15px;
    font-weight: bold;
}
.label-sub {
    color: #505070;
    font-size: 12px;
}
.label-hint {
    color: #404060;
    font-size: 11px;
}
.label-device {
    color: #1ebdd1;
    font-size: 13px;
    font-weight: bold;
}
separator {
    background-color: #28283a;
    min-height: 1px;
    margin: 6px 0;
}
scale trough {
    background-color: #20202a;
    border-radius: 6px;
    min-height: 10px;
}
scale slider {
    background-color: #1ebdd1;
    border-radius: 8px;
    min-width: 18px;
    min-height: 18px;
}
"""

def _apply_css():
    provider = Gtk.CssProvider()
    provider.load_from_data(CSS)
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(),
        provider,
        Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
    )

def _sty(widget, *classes):
    ctx = widget.get_style_context()
    for c in classes:
        ctx.add_class(c)

# ── Backlight / settings / process helpers ──────────────────────────────────
def detect_backlight_dir():
    candidates = sorted(glob.glob("/sys/class/backlight/*"))
    chosen = None
    for c in candidates:
        try:
            with open(os.path.join(c, "display_name")) as f:
                if "DSI" in f.read():
                    chosen = c
                    break
        except Exception:
            continue
    if not chosen and candidates:
        chosen = candidates[0]
    return chosen

def read_int(path, default):
    try:
        with open(path) as f:
            return int(f.read().strip())
    except Exception:
        return default

def is_running():
    try:
        with open(PID_FILE) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        return True
    except Exception:
        return False

def read_settings():
    timeout, fade, failsafe = DEFAULT_TIMEOUT, DEFAULT_FADE, 50
    logging_enabled = False
    try:
        with open(SETTINGS_FILE) as f:
            for raw in f:
                line = raw.strip()
                if line.startswith("IDLE_TIMEOUT="):
                    timeout = int(line.split("=", 1)[1])
                elif line.startswith("FADE_DURATION="):
                    fade = float(line.split("=", 1)[1])
                elif line.startswith("FAILSAFE_BRIGHTNESS="):
                    failsafe = int(line.split("=", 1)[1])
                elif line.startswith("LOGGING="):
                    logging_enabled = line.split("=", 1)[1].strip().lower() == "true"
    except Exception:
        pass
    return timeout, fade, failsafe, logging_enabled

def write_settings(timeout, fade, failsafe, logging_enabled):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(SETTINGS_FILE, "w") as f:
        f.write(
            "# Backlight DSI Solace settings — edit here or via the manager menu.\n"
            f"IDLE_TIMEOUT={timeout}\n"
            f"FADE_DURATION={fade}\n"
            "# Boot guard target (percent, 50-100) when it finds the screen at\n"
            "# 0% after a power loss while dimmed.\n"
            f"FAILSAFE_BRIGHTNESS={failsafe}\n"
            "# Enable watcher logging (true/false). Off by default — SD card friendly.\n"
            "# Turn on temporarily when troubleshooting unexpected behaviour.\n"
            f"LOGGING={'true' if logging_enabled else 'false'}\n"
        )

def autostart_is_enabled():
    return os.path.isfile(AUTOSTART_DESKTOP)

def wireplumber_menu_entry_exists():
    return os.path.isfile(WP_DESKTOP)

def _open_manager():
    if not os.path.isfile(MANAGER_SCRIPT):
        return False
    # Each -e / --command arg is passed as a SEPARATE list entry so the
    # terminal receives "bash" and the path as distinct argv items. The old
    # f"bash {MANAGER_SCRIPT}" single-string form would split on spaces if
    # the path ever contained one (v1.4.1 fix). foot already used the correct
    # form; lxterminal and x-terminal-emulator now match it.
    for cmd in [
        ["foot", "--", "bash", MANAGER_SCRIPT],
        ["xfce4-terminal", "--command", f"bash {MANAGER_SCRIPT}"],
        ["lxterminal", "-e", "bash", MANAGER_SCRIPT],
        ["x-terminal-emulator", "-e", "bash", MANAGER_SCRIPT],
    ]:
        try:
            subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        except FileNotFoundError:
            continue
    return False

# ── Duplicate-instance guard ─────────────────────────────────────────────────
# The desktop icon or Manager button can be tapped at any time. Without this
# guard, a second GUI process would open alongside the first. The GUI PID file
# lets us detect and block that cleanly without any IPC complexity.
GUI_PID_FILE = os.path.join(RUNTIME_DIR, f"{APP_SLUG}-gui.pid")

def _another_gui_running():
    try:
        with open(GUI_PID_FILE) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        return pid != os.getpid()
    except Exception:
        return False

def _write_gui_pidfile():
    try:
        with open(GUI_PID_FILE, "w") as f:
            f.write(str(os.getpid()))
    except Exception:
        pass

def _remove_gui_pidfile():
    try:
        os.remove(GUI_PID_FILE)
    except Exception:
        pass

# ── Pulse dot — identical to Cava Solace / AirPlay Solace ───────────────────
class PulseDot(Gtk.DrawingArea):
    def __init__(self):
        super().__init__()
        self.set_size_request(18, 18)
        self._state = "inactive"
        self._alpha = 1.0
        self._dir = -1
        self._tid = None
        self.connect("draw", self._draw)

    def set_state(self, s):
        self._state = s
        if s == "running" and self._tid is None:
            self._tid = GLib.timeout_add(50, self._pulse)
        elif s != "running" and self._tid:
            GLib.source_remove(self._tid)
            self._tid = None
            self._alpha = 1.0
        self.queue_draw()

    def _pulse(self):
        self._alpha += self._dir * 0.04
        if self._alpha <= 0.35:
            self._dir = 1
        elif self._alpha >= 1.0:
            self._dir = -1
        self.queue_draw()
        return True

    def _draw(self, w, cr):
        a = self.get_allocation()
        cx, cy, r = a.width / 2, a.height / 2, 7
        col = (ACCENT_GREEN if self._state == "running"
               else ACCENT_AMBER if self._state == "stopped"
               else FG_DIM)
        if self._state == "running":
            pat = cairo.RadialGradient(cx, cy, 0, cx, cy, r * 2.2)
            pat.add_color_stop_rgba(0.0, *col, self._alpha * 0.6)
            pat.add_color_stop_rgba(1.0, *col, 0.0)
            cr.set_source(pat)
            cr.arc(cx, cy, r * 2.2, 0, 2 * math.pi)
            cr.fill()
        a_val = self._alpha if self._state == "running" else 1.0
        cr.set_source_rgba(*col, a_val)
        cr.arc(cx, cy, r, 0, 2 * math.pi)
        cr.fill()

# ── Main window ──────────────────────────────────────────────────────────────
class BacklightSolaceGUI(Gtk.Window):
    def __init__(self):
        super().__init__(title="Backlight DSI Solace")
        # Default geometry comfortably fits the smaller official display
        # (800x480 — leaves room for the panel bar, floor stays well within
        # the 480px screen height). On the larger 1280x720 Touch Display 2
        # this same geometry fits with extra room to spare, so no separate
        # sizing path is needed for that panel.
        self.set_default_size(480, 400)
        self.set_size_request(340, 360)
        self.set_resizable(True)
        self.set_border_width(0)
        self.connect("delete-event", self._on_x)
        _apply_css()

        self.bl_dir = detect_backlight_dir()
        self.brightness_path = (
            os.path.join(self.bl_dir, "brightness") if self.bl_dir else None
        )
        self.max_brightness = (
            read_int(os.path.join(self.bl_dir, "max_brightness"), 255)
            if self.bl_dir else 255
        )
        self.slider_dragging = False

        # Scrollable so the window is always usable on the small touchscreen
        # even if content runs a little taller than the visible area —
        # native GTK3 touch/kinetic scrolling, no extra setup needed.
        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.add(scroller)

        main_vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        main_vbox.set_margin_start(10); main_vbox.set_margin_end(10)
        main_vbox.set_margin_top(10);   main_vbox.set_margin_bottom(10)
        scroller.add(main_vbox)

        # ═══ TOP ROW — column 1 (header/status), column 2 (start/stop) ═══
        top_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        top_row.set_halign(Gtk.Align.FILL)
        main_vbox.pack_start(top_row, False, False, 0)

        left = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        top_row.pack_start(left, True, True, 0)

        # Header
        hdr = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        _sty(hdr, "card")
        self._dot = PulseDot()
        hdr.pack_start(self._dot, False, False, 4)
        col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        t = Gtk.Label(label="Backlight DSI Solace")
        _sty(t, "label-title"); t.set_halign(Gtk.Align.START)
        t.set_ellipsize(Pango.EllipsizeMode.END)
        s = Gtk.Label(label="Pi 4  ·  Idle-Dim Touch Screensaver")
        _sty(s, "label-sub"); s.set_halign(Gtk.Align.START)
        s.set_ellipsize(Pango.EllipsizeMode.END)
        col.pack_start(t, False, False, 0)
        col.pack_start(s, False, False, 0)
        hdr.pack_start(col, True, True, 0)
        # Compact gear button — right-aligned in the header, opens the
        # terminal manager. Replaces the old full-width bottom Manager button
        # (removed in v1.5.1). Small, out of the way, but always visible at
        # the top regardless of scroll position. set_relief(NONE) removes the
        # button border so it reads as an icon rather than a button block.
        bm = Gtk.Button(label="\u2699")
        _sty(bm, "btn-icon")
        bm.set_size_request(32, 32)
        bm.set_valign(Gtk.Align.CENTER)
        bm.set_relief(Gtk.ReliefStyle.NONE)
        bm.connect("clicked", self._on_manager)
        bm.set_tooltip_text("Open terminal manager (install, uninstall, logs)")
        hdr.pack_end(bm, False, False, 0)
        left.pack_start(hdr, False, False, 0)

        # Status
        sc = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        _sty(sc, "card")
        self._slbl = Gtk.Label(); self._slbl.set_halign(Gtk.Align.START)
        self._slbl.set_ellipsize(Pango.EllipsizeMode.END)
        self._dlbl = Gtk.Label(); self._dlbl.set_halign(Gtk.Align.START)
        self._dlbl.set_ellipsize(Pango.EllipsizeMode.END)
        _sty(self._dlbl, "label-device")
        sc.pack_start(self._slbl, False, False, 0)
        sc.pack_start(self._dlbl, False, False, 0)
        left.pack_start(sc, False, False, 0)

        # Column 2 — Start/Stop
        right = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        right.set_size_request(150, -1)
        right.set_valign(Gtk.Align.START)
        top_row.pack_start(right, False, False, 0)

        self._bstart = Gtk.Button(label="\u25b6  Start")
        _sty(self._bstart, "btn-primary")
        self._bstart.set_size_request(-1, 44)
        self._bstart.get_child().set_ellipsize(Pango.EllipsizeMode.END)
        self._bstart.connect("clicked", self._on_start)
        right.pack_start(self._bstart, False, False, 0)

        self._bstop = Gtk.Button(label="\u25a0  Stop")
        _sty(self._bstop, "btn-stop")
        self._bstop.set_size_request(-1, 44)
        self._bstop.get_child().set_ellipsize(Pango.EllipsizeMode.END)
        self._bstop.connect("clicked", self._on_stop)
        right.pack_start(self._bstop, False, False, 0)

        # ═══ Brightness slider card ═══
        bc_card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        _sty(bc_card, "card2")
        blabel = Gtk.Label(label="Brightness"); _sty(blabel, "label-sub")
        blabel.set_halign(Gtk.Align.START)
        bc_card.pack_start(blabel, False, False, 0)
        # Slider is in PERCENT, range 4..100 (v1.5.0, floor raised to 4% in
        # v1.5.1). Zero is structurally unreachable at the widget level.
        # Floor is 4% not 1%: confirmed on hardware 2026-06-22 that 1–3% is
        # visually black on the official Pi 7" panel (non-linear luminance
        # curve; 4% is the lowest visibly-lit setting). The guard handles the
        # 1–3% zone for power-loss-while-dimmed recovery. Raw<->percent
        # conversion happens only at the sysfs read/write boundary.
        self.brightness_scale = Gtk.Scale.new_with_range(
            Gtk.Orientation.HORIZONTAL, 4, 100, 1
        )
        if self.brightness_path:
            cur_raw = read_int(self.brightness_path, self.max_brightness)
            cur_pct = raw_to_pct(cur_raw, self.max_brightness)
            # Clamp to the visible floor — if the panel is currently below 4%
            # (e.g. a guard hasn't fired yet after power loss), show 4% so
            # the user can't inadvertently confirm a black-zone value.
            self.brightness_scale.set_value(max(4, cur_pct))
        else:
            self.brightness_scale.set_value(100)
        self.brightness_scale.set_draw_value(False)
        # 44px-tall touch target for the whole slider widget, even though
        # the visual track stays slim via CSS — easier to grab on a small
        # capacitive screen without precision aiming.
        self.brightness_scale.set_size_request(-1, 44)
        self.brightness_scale.connect("value-changed", self._on_brightness_changed)
        self.brightness_scale.connect("button-press-event", self._on_slider_press)
        self.brightness_scale.connect("button-release-event", self._on_slider_release)
        bc_card.pack_start(self.brightness_scale, False, False, 0)
        main_vbox.pack_start(bc_card, False, False, 0)

        # ═══ Settings card ═══
        settings_card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        _sty(settings_card, "card2")
        slabel = Gtk.Label(label="Settings"); _sty(slabel, "label-sub")
        slabel.set_halign(Gtk.Align.START)
        settings_card.pack_start(slabel, False, False, 0)

        # Visible (not just a hover tooltip, since the primary input here is
        # touch) reminder about what resets the idle timer. Chrome video and
        # PS4 touchpad (pointer mode) both work fine. Controller buttons/sticks
        # do not reset the timer — a known wlroots/swayidle limitation
        # (github.com/swaywm/swayidle/issues/68), not a bug in this app.
        # Wrapped in the existing ScrolledWindow, so this extra line never
        # risks breaking the small-screen layout.
        warn_lbl = Gtk.Label(
            label="Chrome video & PS4 touchpad reset this fine.\nController buttons/sticks do not."
        )
        _sty(warn_lbl, "label-hint")
        warn_lbl.set_halign(Gtk.Align.START)
        warn_lbl.set_line_wrap(True)
        warn_lbl.set_max_width_chars(40)
        settings_card.pack_start(warn_lbl, False, False, 0)

        timeout, fade, failsafe, logging_enabled = read_settings()

        timeout_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        tlbl = Gtk.Label(label="Idle timeout (s)"); _sty(tlbl, "label-hint")
        tlbl.set_halign(Gtk.Align.START)
        timeout_row.pack_start(tlbl, True, True, 0)
        self.timeout_spin = Gtk.SpinButton.new_with_range(5, 3600, 1)
        self.timeout_spin.set_value(timeout)
        self.timeout_spin.set_size_request(90, 44)
        self.timeout_spin.set_tooltip_text(
            "Touch, mouse, keyboard, Chrome video, and PS4 touchpad (pointer "
            "mode) all reset this. Controller buttons/sticks do not "
            "(wlroots/swayidle limitation)."
        )
        timeout_row.pack_end(self.timeout_spin, False, False, 0)
        settings_card.pack_start(timeout_row, False, False, 0)

        fade_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        flbl = Gtk.Label(label="Fade duration (s)"); _sty(flbl, "label-hint")
        flbl.set_halign(Gtk.Align.START)
        fade_row.pack_start(flbl, True, True, 0)
        self.fade_spin = Gtk.SpinButton.new_with_range(0.1, 10, 0.1)
        self.fade_spin.set_digits(1)
        self.fade_spin.set_value(fade)
        self.fade_spin.set_size_request(90, 44)
        fade_row.pack_end(self.fade_spin, False, False, 0)
        settings_card.pack_start(fade_row, False, False, 0)

        # Failsafe brightness (percent, 50-100) — boot guard target when it
        # finds the screen at 0% after a power loss while dimmed (v1.5.0).
        failsafe_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        fslbl = Gtk.Label(label="Failsafe brightness (%)"); _sty(fslbl, "label-hint")
        fslbl.set_halign(Gtk.Align.START)
        failsafe_row.pack_start(fslbl, True, True, 0)
        self.failsafe_spin = Gtk.SpinButton.new_with_range(50, 100, 1)
        self.failsafe_spin.set_value(failsafe)
        self.failsafe_spin.set_size_request(90, 44)
        self.failsafe_spin.set_tooltip_text(
            "If a power loss while dimmed leaves the screen black at next boot, "
            "the boot guard restores it to this level. 50-100%."
        )
        failsafe_row.pack_end(self.failsafe_spin, False, False, 0)
        settings_card.pack_start(failsafe_row, False, False, 0)

        # Logging toggle — off by default (SD card friendly). User enables
        # only when troubleshooting. Watcher must be restarted to pick it up.
        self.logging_check = Gtk.CheckButton(label="Enable watcher logging (for troubleshooting)")
        self.logging_check.set_active(logging_enabled)
        self.logging_check.set_size_request(-1, 44)
        self.logging_check.set_tooltip_text(
            "Off by default. Turn on to write a log file when diagnosing "
            "unexpected behaviour. Restart the watcher after changing this."
        )
        settings_card.pack_start(self.logging_check, False, False, 0)

        save_button = Gtk.Button(label="Save Settings")
        _sty(save_button, "btn-primary")
        save_button.set_size_request(-1, 44)
        save_button.get_child().set_ellipsize(Pango.EllipsizeMode.END)
        save_button.connect("clicked", self._on_save_settings)
        settings_card.pack_start(save_button, False, False, 0)

        main_vbox.pack_start(settings_card, False, False, 0)

        # ═══ Autostart card ═══
        autostart_card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        _sty(autostart_card, "card2")
        aslabel = Gtk.Label(label="Autostart"); _sty(aslabel, "label-sub")
        aslabel.set_halign(Gtk.Align.START)
        autostart_card.pack_start(aslabel, False, False, 0)

        self.autostart_check = Gtk.CheckButton(
            label="Start the idle-dim watcher automatically at login"
        )
        self.autostart_check.set_active(autostart_is_enabled())
        self.autostart_check.set_size_request(-1, 44)
        self.autostart_check.connect("toggled", self._on_autostart_toggled)
        autostart_card.pack_start(self.autostart_check, False, False, 0)

        # Tip: controller-buttons-only users
        tip_lbl = Gtk.Label(
            label="\u2139  Using controller buttons only? Tap Stop above"
                  " \u2014 resume anytime."
        )
        _sty(tip_lbl, "label-hint")
        tip_lbl.set_halign(Gtk.Align.START)
        tip_lbl.set_line_wrap(True)
        tip_lbl.set_max_width_chars(40)
        autostart_card.pack_start(tip_lbl, False, False, 0)

        guard_lbl = Gtk.Label(
            label="A brightness boot guard always runs at login to fix a black "
                  "screen after power loss — this is separate and always on."
        )
        _sty(guard_lbl, "label-hint")
        guard_lbl.set_halign(Gtk.Align.START)
        guard_lbl.set_line_wrap(True)
        guard_lbl.set_max_width_chars(40)
        autostart_card.pack_start(guard_lbl, False, False, 0)

        main_vbox.pack_start(autostart_card, False, False, 0)

        # === HDMI Audio card ===
        hdmi_card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        _sty(hdmi_card, "card2")
        hdmi_label = Gtk.Label(label="HDMI Audio"); _sty(hdmi_label, "label-sub")
        hdmi_label.set_halign(Gtk.Align.START)
        hdmi_card.pack_start(hdmi_label, False, False, 0)

        hdmi_hint = Gtk.Label(label="Use if HDMI audio is missing after plugging in a display.")
        _sty(hdmi_hint, "label-hint")
        hdmi_hint.set_halign(Gtk.Align.START)
        hdmi_hint.set_line_wrap(True)
        hdmi_hint.set_max_width_chars(40)
        hdmi_card.pack_start(hdmi_hint, False, False, 0)

        hdmi_btn = Gtk.Button(label="Re-detect HDMI Audio")
        _sty(hdmi_btn, "btn-primary")
        hdmi_btn.set_size_request(-1, 44)
        hdmi_btn.get_child().set_ellipsize(Pango.EllipsizeMode.END)
        hdmi_btn.connect("clicked", self._on_redetect_hdmi)
        hdmi_card.pack_start(hdmi_btn, False, False, 0)

        # Checkbox: pin a start-menu shortcut for the WirePlumber restart action.
        self.wp_launcher_check = Gtk.CheckButton(
            label="Add 'Re-detect HDMI Audio' to the start menu"
        )
        self.wp_launcher_check.set_active(wireplumber_menu_entry_exists())
        self.wp_launcher_check.set_size_request(-1, 44)
        self.wp_launcher_check.connect("toggled", self._on_wp_launcher_toggled)
        hdmi_card.pack_start(self.wp_launcher_check, False, False, 0)

        main_vbox.pack_start(hdmi_card, False, False, 0)

        self._mlbl = Gtk.Label(label="")
        _sty(self._mlbl, "label-hint"); self._mlbl.set_halign(Gtk.Align.CENTER)
        self._mlbl.set_ellipsize(Pango.EllipsizeMode.END)
        main_vbox.pack_start(self._mlbl, False, False, 0)

        self._ptid = GLib.timeout_add_seconds(2, self._poll)
        self._refresh()

    # -- messaging --------------------------------------------------------------
    def _msg(self, text):
        self._mlbl.set_text(text)

    # -- status -------------------------------------------------------------------
    def _refresh(self):
        running = is_running()
        self._dot.set_state("running" if running else "stopped")
        if running:
            self._slbl.set_markup("Idle-dim active — dims after no touch")
        else:
            self._slbl.set_markup("Not running")
        if self.brightness_path and not self.slider_dragging:
            current_raw = read_int(self.brightness_path, self.max_brightness)
            current_pct = raw_to_pct(current_raw, self.max_brightness)
            self._dlbl.set_text(f"Brightness: {current_pct}%")
            # Sync the slider to the real brightness WITHOUT firing
            # value-changed — otherwise a poll that observes a watcher-dimmed
            # or guard-adjusted value would re-enter _on_brightness_changed and
            # (a) needlessly re-write sysfs and (b) clobber last-set-brightness
            # with a non-user value. Block the handler around the sync so only
            # genuine user slider moves ever reach _on_brightness_changed.
            self.brightness_scale.handler_block_by_func(self._on_brightness_changed)
            self.brightness_scale.set_value(current_pct)
            self.brightness_scale.handler_unblock_by_func(self._on_brightness_changed)
        elif not self.brightness_path:
            self._dlbl.set_text("Brightness: —")
        return running

    def _poll(self):
        self._refresh()
        return True

    # -- start/stop -----------------------------------------------------------------
    def _on_start(self, *_):
        if not os.path.isfile(MANAGER_SCRIPT):
            self._msg("Manager script not found — run Install/Repair first.")
            GLib.timeout_add_seconds(4, lambda: (self._msg(""), False)[1])
            return
        self._msg("Starting Backlight DSI Solace…")
        subprocess.Popen(
            [MANAGER_SCRIPT, "start"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        GLib.timeout_add(1500, lambda: (self._refresh(), False)[1])
        GLib.timeout_add(3000, lambda: (self._msg(""), False)[1])

    def _on_stop(self, *_):
        self._msg("Stopping Backlight DSI Solace…")
        subprocess.Popen(
            [MANAGER_SCRIPT, "stop"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        GLib.timeout_add(2000, lambda: (self._refresh(), False)[1])
        GLib.timeout_add(3000, lambda: (self._msg(""), False)[1])

    # -- brightness slider -------------------------------------------------------------
    def _on_slider_press(self, *_args):
        self.slider_dragging = True
        return False

    def _on_slider_release(self, *_args):
        self.slider_dragging = False
        return False

    def _on_brightness_changed(self, scale):
        if not self.brightness_path:
            return
        pct = max(4, int(scale.get_value()))   # enforce hardware floor
        raw = pct_to_raw(pct, self.max_brightness)
        try:
            with open(self.brightness_path, "w") as f:
                f.write(str(raw))
        except Exception:
            pass
        # Record the user's deliberate choice (percent) so the boot guard can
        # report it in its diagnostic log. Only written on a real slider
        # change, not on the passive poll refresh. Best-effort; never fatal.
        try:
            os.makedirs(CONFIG_DIR, exist_ok=True)
            with open(LAST_SET_BRIGHTNESS_FILE, "w") as f:
                f.write(str(pct))
        except Exception:
            pass
        self._dlbl.set_text(f"Brightness: {pct}%")

    # -- settings -----------------------------------------------------------------------
    def _on_save_settings(self, *_):
        timeout = int(self.timeout_spin.get_value())
        fade = round(self.fade_spin.get_value(), 1)
        failsafe = int(self.failsafe_spin.get_value())
        logging_enabled = self.logging_check.get_active()
        write_settings(timeout, fade, failsafe, logging_enabled)
        # NOTE: we deliberately do NOT shell out to the manager here. The boot
        # guard re-reads settings.conf live at every login, so the new failsafe
        # value takes effect on the next boot with no wrapper rewrite needed.
        # (An earlier version called `manager install`, which re-ran the full
        # install including a sudo apt step — wrong from a GUI button with no
        # terminal to answer the sudo prompt.)
        if is_running():
            dialog = Gtk.MessageDialog(
                transient_for=self,
                flags=0,
                message_type=Gtk.MessageType.QUESTION,
                buttons=Gtk.ButtonsType.YES_NO,
                text="Restart Backlight DSI Solace now to apply the new settings?",
            )
            response = dialog.run()
            dialog.destroy()
            if response == Gtk.ResponseType.YES:
                # Popen (non-blocking) — stop then start with a gap so the
                # watcher has time to exit before the new one starts.
                subprocess.Popen(
                    [MANAGER_SCRIPT, "stop"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
                )
                GLib.timeout_add(2000, self._deferred_start)
        self._msg("Settings saved.")
        GLib.timeout_add_seconds(3, lambda: (self._msg(""), False)[1])
        self._refresh()

    def _deferred_start(self):
        subprocess.Popen(
            [MANAGER_SCRIPT, "start"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        GLib.timeout_add(1500, lambda: (self._refresh(), False)[1])
        return False

    # -- autostart toggle ----------------------------------------------------------------
    def _on_autostart_toggled(self, check):
        if not os.path.isfile(MANAGER_SCRIPT):
            self._msg("Manager not found — run Install/Repair first.")
            GLib.timeout_add_seconds(4, lambda: (self._msg(""), False)[1])
            # revert checkbox to actual on-disk state
            check.handler_block_by_func(self._on_autostart_toggled)
            check.set_active(autostart_is_enabled())
            check.handler_unblock_by_func(self._on_autostart_toggled)
            return
        if check.get_active():
            subprocess.Popen(
                [MANAGER_SCRIPT, "enable-autostart"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            self._msg("Autostart enabled.")
        else:
            subprocess.Popen(
                [MANAGER_SCRIPT, "disable-autostart"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            self._msg("Autostart disabled.")
        GLib.timeout_add_seconds(3, lambda: (self._msg(""), False)[1])

    # -- HDMI audio re-detect ---------------------------------------------------
    def _on_redetect_hdmi(self, *_):
        self._msg("Restarting WirePlumber...")
        try:
            result = subprocess.run(
                ["systemctl", "--user", "restart", "wireplumber"],
                timeout=10,
                capture_output=True
            )
            if result.returncode == 0:
                self._msg("WirePlumber restarted successfully — check your audio output.")
            else:
                self._msg("WirePlumber restart failed — check the terminal manager.")
        except Exception:
            self._msg("WirePlumber restart failed — check the terminal manager.")
        GLib.timeout_add_seconds(5, lambda: (self._msg(""), False)[1])

    # -- WirePlumber start-menu launcher toggle ----------------------------------
    def _on_wp_launcher_toggled(self, check):
        if check.get_active():
            # Write the .desktop file via the manager so the bash constant
            # paths stay authoritative; fall back to a direct Python write if
            # the manager script is somehow absent.
            if os.path.isfile(MANAGER_SCRIPT):
                subprocess.Popen(
                    [MANAGER_SCRIPT, "write-wp-launcher"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
                )
                self._msg("Start-menu shortcut added.")
            else:
                # Direct fallback: write the .desktop file ourselves.
                try:
                    os.makedirs(DESKTOP_DIR, exist_ok=True)
                    with open(WP_DESKTOP, "w") as fh:
                        fh.write(
                            "[Desktop Entry]\n"
                            "Type=Application\n"
                            "Version=1.0\n"
                            "Name=Re-detect HDMI Audio\n"
                            "Comment=Restart WirePlumber to enumerate HDMI audio after hot-plugging a display\n"
                            "Exec=systemctl --user restart wireplumber\n"
                            "Terminal=false\n"
                            "Categories=Settings;HardwareSettings;\n"
                        )
                    subprocess.Popen(
                        ["update-desktop-database", DESKTOP_DIR],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
                    )
                    self._msg("Start-menu shortcut added.")
                except Exception:
                    # Revert checkbox to reflect actual on-disk state.
                    check.handler_block_by_func(self._on_wp_launcher_toggled)
                    check.set_active(wireplumber_menu_entry_exists())
                    check.handler_unblock_by_func(self._on_wp_launcher_toggled)
                    self._msg("Failed to write start-menu shortcut.")
        else:
            try:
                os.remove(WP_DESKTOP)
            except FileNotFoundError:
                pass  # already gone — treat as success
            except Exception:
                self._msg("Failed to remove start-menu shortcut.")
                check.handler_block_by_func(self._on_wp_launcher_toggled)
                check.set_active(wireplumber_menu_entry_exists())
                check.handler_unblock_by_func(self._on_wp_launcher_toggled)
                GLib.timeout_add_seconds(3, lambda: (self._msg(""), False)[1])
                return
            subprocess.Popen(
                ["update-desktop-database", DESKTOP_DIR],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            self._msg("Start-menu shortcut removed.")
        GLib.timeout_add_seconds(3, lambda: (self._msg(""), False)[1])

    # -- manager / background / close ----------------------------------------------------
    def _on_manager(self, *_):
        if not _open_manager():
            self._msg("Manager not found — check ~/.local/share/backlight-dsi-solace/")
            GLib.timeout_add_seconds(4, lambda: (self._msg(""), False)[1])

    def _on_x(self, *_):
        # Closing the window exits the GUI but does NOT stop the watcher —
        # the watcher is an independent background process, and closing the
        # control panel isn't necessarily a request to stop it.
        self._quit()
        return True

    def _quit(self):
        # Use try/finally so _remove_gui_pidfile() is guaranteed to run even
        # if either source_remove raises. A stale PID file is the exact bug
        # that blocked re-opening the GUI after the old Background button was
        # used — we never want that again.
        try:
            try:
                if self._ptid:
                    GLib.source_remove(self._ptid)
            except Exception:
                pass
            # Cancel the PulseDot animation timer explicitly via set_state().
            # After Gtk.main_quit() the loop stops so the timer would never
            # fire anyway, but cancelling it here ensures it cannot fire if
            # GTK defers the quit slightly and processes one more main-loop
            # iteration before returning.
            try:
                self._dot.set_state("stopped")
            except Exception:
                pass
        finally:
            _remove_gui_pidfile()
        Gtk.main_quit()


def main():
    if _another_gui_running():
        # Already have a Backlight DSI Solace window open — bring it to
        # focus rather than stacking a second instance.
        return
    _write_gui_pidfile()
    # Belt-and-suspenders: atexit fires on any exit path that doesn't call
    # os._exit() — covers clean _quit(), unhandled exception, and sys.exit().
    # _quit() also removes the file explicitly; this catches any path where
    # _quit() is bypassed (e.g. the window is destroyed externally).
    atexit.register(lambda: (os.remove(GUI_PID_FILE) if os.path.exists(GUI_PID_FILE) else None))
    win = BacklightSolaceGUI()
    win.show_all()
    Gtk.main()


if __name__ == "__main__":
    main()
GUIEOF
    chmod +x "${GUI_PATH}"
}

# ---------------------------------------------------------------------------
# Desktop integration (locked icon-cache pattern)
# ---------------------------------------------------------------------------
write_icon() {
    mkdir -p "${ICON_DIR}"
    cat > "${ICON_PATH}" <<'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect x="4" y="10" width="56" height="38" rx="4" fill="#1a1a1a" stroke="#7fb3ff" stroke-width="2"/>
  <rect x="10" y="16" width="44" height="26" rx="2" fill="#101820"/>
  <circle cx="32" cy="29" r="9" fill="#ffd76b" opacity="0.85"/>
  <rect x="24" y="52" width="16" height="4" rx="2" fill="#7fb3ff"/>
</svg>
SVGEOF
}

write_gui_menu_entry() {
    # Always installed — GUI control panel in Settings/Preferences.
    mkdir -p "${DESKTOP_DIR}"
    cat > "${DESKTOP_DIR}/${APP_SLUG}-gui.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=${APP_NAME}
Comment=Adjust brightness and idle-dim settings for the DSI touch display
Exec=python3 ${GUI_PATH}
Icon=${ICON_PATH}
Terminal=false
Categories=Settings;HardwareSettings;
EOF
}

write_start_stop_entries() {
    # Optional — Start and Stop shortcuts in Settings/Preferences.
    mkdir -p "${DESKTOP_DIR}"
    cat > "${DESKTOP_DIR}/${APP_SLUG}-start.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Start ${APP_NAME}
Comment=Dim the touch display after idle; tap to wake
Exec=${SELF_PATH} start
Icon=${ICON_PATH}
Terminal=false
Categories=Settings;HardwareSettings;
EOF

    cat > "${DESKTOP_DIR}/${APP_SLUG}-stop.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Stop ${APP_NAME}
Comment=Force the touch display back to full brightness and stop watching
Exec=${SELF_PATH} stop
Icon=${ICON_PATH}
Terminal=false
Categories=Settings;HardwareSettings;
EOF
}

write_desktop_launcher() {
    # Optional — GUI launcher pinned to the physical desktop (~Desktop folder).
    mkdir -p "${XDG_DESKTOP_DIR}"
    cat > "${XDG_DESKTOP_DIR}/${APP_SLUG}.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=${APP_NAME}
Comment=Adjust brightness and idle-dim settings for the DSI touch display
Exec=python3 ${GUI_PATH}
Icon=${ICON_PATH}
Terminal=false
Categories=Settings;HardwareSettings;
EOF
    chmod +x "${XDG_DESKTOP_DIR}/${APP_SLUG}.desktop" 2>/dev/null || true
}

write_wireplumber_menu_entry() {
    # Optional — start-menu shortcut to restart WirePlumber (re-detect HDMI audio).
    # Note: also called directly via the write-wp-launcher subcommand from the GUI
    # toggle, so this function must call both icon cache and desktop database itself.
    mkdir -p "${DESKTOP_DIR}"
    cat > "${WP_DESKTOP}" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Re-detect HDMI Audio
Comment=Restart WirePlumber to enumerate HDMI audio after hot-plugging a display
Exec=systemctl --user restart wireplumber
Icon=${ICON_PATH}
Terminal=false
Categories=Settings;HardwareSettings;
EOF
    gtk-update-icon-cache -f -t "${HOME}/.local/share/icons/hicolor" 2>/dev/null || true
    update-desktop-database "${DESKTOP_DIR}" 2>/dev/null || true
}

wireplumber_menu_entry_exists() {
    [[ -f "${WP_DESKTOP}" ]]
}

remove_desktop_entries() {
    # Removes all possible shortcuts — called by uninstall and repair.
    rm -f "${DESKTOP_DIR}/${APP_SLUG}-gui.desktop"
    rm -f "${DESKTOP_DIR}/${APP_SLUG}-start.desktop"
    rm -f "${DESKTOP_DIR}/${APP_SLUG}-stop.desktop"
    rm -f "${WP_DESKTOP}"
    rm -f "${XDG_DESKTOP_DIR}/${APP_SLUG}.desktop"
    rm -f "${ICON_PATH}"
    gtk-update-icon-cache -f -t "${HOME}/.local/share/icons/hicolor" 2>/dev/null || true
    update-desktop-database "${DESKTOP_DIR}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# v1.5.0 — Watcher autostart (OPT-IN) + brightness boot guard (ALWAYS ON)
# ---------------------------------------------------------------------------
# Two separate XDG autostart entries, deliberately decoupled:
#
#   1. AUTOSTART (opt-in, default OFF): launches the idle-dim watcher at
#      login. Toggled by the user via the GUI checkbox or CLI menu. Writes
#      <slug>-autostart.desktop only when enabled; removed when disabled.
#
#   2. GUARD (always installed by Install/Repair, runs every login): a tiny
#      <1s script that corrects a 0% / dangerously-dim backlight left behind
#      by a hard power-loss while the screen was dimmed. systemd-backlight
#      faithfully restores whatever brightness was active at shutdown, so a
#      crash mid-dim can boot to a black screen — the one gap the four
#      runtime safety nets cannot cover (they only run while the watcher is
#      alive). The guard is independent of the autostart toggle and of the
#      watcher process entirely.
#
# Both wrappers live in INSTALL_DIR and are the Exec= targets, so the
# .desktop trigger stays stable regardless of where the .sh manager lives.
# ---------------------------------------------------------------------------

write_autostart_wrapper() {
    mkdir -p "${INSTALL_DIR}"
    cat > "${AUTOSTART_WRAPPER}" <<EOF
#!/usr/bin/env bash
# ${APP_SLUG}-autostart.sh — generated by ${APP_SLUG}-manager.sh v${SCRIPT_VERSION}
# Opt-in watcher autostart. Fires at login via XDG autostart, waits for the
# Wayland session, then starts the idle-dim watcher. Self-heals: if the
# watcher is gone (uninstalled), it deletes its own autostart entry.
set -uo pipefail

SELF_PATH="${SELF_PATH}"
WATCHER_PATH="${WATCHER_PATH}"
AUTOSTART_DESKTOP="${AUTOSTART_DESKTOP}"
LOG_FILE="${LOG_FILE}"

_log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] [autostart] \$*" >> "\$LOG_FILE" 2>/dev/null || true; }

# Self-heal: if the watcher no longer exists, remove our own autostart entry
# and exit. Prevents a stale login entry from lingering after an uninstall
# that somehow left this file behind.
if [[ ! -f "\$WATCHER_PATH" ]]; then
    _log "Watcher not found at \$WATCHER_PATH — removing stale autostart entry and exiting."
    rm -f "\$AUTOSTART_DESKTOP" 2>/dev/null || true
    exit 0
fi

# Wait up to 15s for a usable Wayland session. We poll the Wayland socket
# rather than a specific compositor name (e.g. labwc) so this works on any
# wlroots-based compositor without hanging the full 15s on a name mismatch.
# The wait exists only so the watcher's GTK overlay has a display to draw on
# — backlight control itself is a kernel sysfs operation and needs no
# compositor.
for _i in \$(seq 1 15); do
    if [[ -n "\${WAYLAND_DISPLAY:-}" ]]; then
        # WAYLAND_DISPLAY may be a bare name (joined to XDG_RUNTIME_DIR, the
        # normal case on Pi OS) or an absolute path. Handle both.
        case "\$WAYLAND_DISPLAY" in
            /*) _wl_sock="\$WAYLAND_DISPLAY" ;;
            *)  _wl_sock="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}/\$WAYLAND_DISPLAY" ;;
        esac
        if [[ -e "\$_wl_sock" ]]; then
            # Socket exists — but labwc needs more time to finish initialising
            # layer-shell protocol support after the socket appears. On a Pi 4
            # with DSI + optional HDMI, launching immediately caused the watcher
            # to fail silently (GTK connected but gtk-layer-shell couldn't
            # anchor the overlay). 10s is the confirmed-safe settle time.
            _log "Wayland socket found — waiting 10s for compositor to settle"
            sleep 10
            break
        fi
    fi
    sleep 1
done

if [[ -z "\${WAYLAND_DISPLAY:-}" ]]; then
    _log "No Wayland display after 15s — starting watcher anyway (it will log if it can't draw)."
fi

_log "Starting watcher via \$SELF_PATH start"
exec "\$SELF_PATH" start
EOF
    chmod +x "${AUTOSTART_WRAPPER}"
}

write_guard_wrapper() {
    mkdir -p "${INSTALL_DIR}"
    read_settings
    cat > "${GUARD_WRAPPER}" <<EOF
#!/usr/bin/env bash
# ${APP_SLUG}-guard.sh — generated by ${APP_SLUG}-manager.sh v${SCRIPT_VERSION}
# Brightness safety guard. Runs at EVERY login via XDG autostart and exits in
# under a second. Corrects a dangerously dim or zero backlight caused by a
# power loss while the screen was dimmed (systemd-backlight faithfully
# restores that 0% state on the next boot). Never touches the watcher process.
#
# Decision tree:
#   current == 0%  -> write FAILSAFE_BRIGHTNESS (from settings, default ${DEFAULT_FAILSAFE_BRIGHTNESS}%)
#   current 1-3%   -> write 10%  (visually black on Pi 7" panel, confirmed 2026-06-22)
#   current >= 4%  -> leave alone (deliberate user setting, visible)
set -uo pipefail

SETTINGS_FILE="${SETTINGS_FILE}"
LOG_FILE="${LOG_FILE}"
LAST_SET_FILE="${LAST_SET_BRIGHTNESS_FILE}"
DEFAULT_FAILSAFE=${DEFAULT_FAILSAFE_BRIGHTNESS}

_log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] [guard] \$*" >> "\$LOG_FILE" 2>/dev/null || true; }

# Detect DSI backlight device (same logic as the manager and watcher).
BL_DIR=""
for d in /sys/class/backlight/*/; do
    if grep -q "DSI" "\${d}display_name" 2>/dev/null; then
        BL_DIR="\$d"; break
    fi
done
if [[ -z "\$BL_DIR" ]]; then
    BL_DIR=\$(ls -d /sys/class/backlight/*/ 2>/dev/null | head -n1 || true)
fi
if [[ -z "\$BL_DIR" ]] || [[ ! -w "\${BL_DIR}brightness" ]]; then
    _log "No writable backlight device found — guard exiting."
    exit 0
fi

MAX=\$(cat "\${BL_DIR}max_brightness" 2>/dev/null || echo "255")
CURRENT_RAW=\$(cat "\${BL_DIR}brightness" 2>/dev/null || echo "\$MAX")

# Guard against empty or non-numeric values from sysfs reads.
[[ "\$MAX" =~ ^[0-9]+\$ ]]         || MAX=255
[[ "\$CURRENT_RAW" =~ ^[0-9]+\$ ]] || CURRENT_RAW="\$MAX"
[[ "\$MAX" -gt 0 ]]                || MAX=255

# Convert raw -> percent using python3 for reliable rounding. Fallback to 100
# on any error so the guard exits cleanly rather than crashing.
CURRENT_PCT=\$(python3 -c "print(min(100,max(0,round(\${CURRENT_RAW}/\${MAX}*100))))" 2>/dev/null || echo "100")
[[ "\$CURRENT_PCT" =~ ^[0-9]+\$ ]] || CURRENT_PCT=100

# Read failsafe from settings; fall back to baked-in default if missing/invalid.
FAILSAFE=\$DEFAULT_FAILSAFE
if [[ -f "\$SETTINGS_FILE" ]]; then
    val=\$(grep -m1 "^FAILSAFE_BRIGHTNESS=" "\$SETTINGS_FILE" 2>/dev/null | cut -d= -f2- || true)
    if [[ "\$val" =~ ^[0-9]+\$ ]] && [[ "\$val" -ge 50 ]] && [[ "\$val" -le 100 ]]; then
        FAILSAFE=\$val
    fi
fi

# Read last deliberately-set brightness for the log line only.
LAST_SET="(not recorded)"
if [[ -f "\$LAST_SET_FILE" ]]; then
    ls_val=\$(cat "\$LAST_SET_FILE" 2>/dev/null || true)
    if [[ "\$ls_val" =~ ^[0-9]+\$ ]]; then LAST_SET="\${ls_val}%"; fi
fi

# Decision tree — use [[ ]] -eq/-ge/-le comparisons, NOT (( )), because under
# set -e an arithmetic expression that evaluates to 0 returns a falsy exit
# status and would kill the script on the normal/common path.
if [[ "\$CURRENT_PCT" -eq 0 ]]; then
    TARGET_RAW=\$(python3 -c "print(round(\${MAX}*\${FAILSAFE}/100))" 2>/dev/null || echo "\$MAX")
    echo "\$TARGET_RAW" > "\${BL_DIR}brightness" 2>/dev/null || true
    _log "Brightness was 0% (crash-while-dimmed). Restored to \${FAILSAFE}% (failsafe). Last user set: \$LAST_SET."
elif [[ "\$CURRENT_PCT" -ge 1 ]] && [[ "\$CURRENT_PCT" -le 3 ]]; then
    TARGET_RAW=\$(python3 -c "print(round(\${MAX}*10/100))" 2>/dev/null || echo "\$MAX")
    echo "\$TARGET_RAW" > "\${BL_DIR}brightness" 2>/dev/null || true
    _log "Brightness was \${CURRENT_PCT}% (visually black zone). Raised to 10%. Last user set: \$LAST_SET."
else
    _log "Brightness is \${CURRENT_PCT}% — OK, no correction needed. Last user set: \$LAST_SET."
fi
exit 0
EOF
    chmod +x "${GUARD_WRAPPER}"
}

install_guard() {
    # Always installed by Install/Repair (runs every login regardless of the
    # autostart toggle). Reinstalled on every Install/Repair so bug fixes to
    # the wrapper propagate.
    mkdir -p "${AUTOSTART_DIR}"
    write_guard_wrapper
    cat > "${GUARD_DESKTOP}" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=${APP_NAME} — Boot Guard
Comment=Corrects a dangerously dim or black screen after a power loss while dimmed. Runs at login, exits instantly. Safe to keep enabled.
Exec=${GUARD_WRAPPER}
Terminal=false
Hidden=false
X-GNOME-Autostart-enabled=true
Categories=Utility;
EOF
    chmod 644 "${GUARD_DESKTOP}"
    info "Boot guard installed (runs at every login, corrects a black screen after power loss)."
}

remove_guard() {
    rm -f "${GUARD_DESKTOP}" "${GUARD_WRAPPER}" 2>/dev/null || true
    update-desktop-database "${DESKTOP_DIR}" 2>/dev/null || true
}

autostart_is_enabled() {
    [[ -f "${AUTOSTART_DESKTOP}" ]]
}

enable_autostart() {
    mkdir -p "${AUTOSTART_DIR}"
    write_autostart_wrapper
    cat > "${AUTOSTART_DESKTOP}" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Start ${APP_NAME}
Comment=Automatically start the idle-dim watcher at login
Exec=${AUTOSTART_WRAPPER}
Terminal=false
Hidden=false
X-GNOME-Autostart-enabled=true
Categories=Utility;
EOF
    chmod 644 "${AUTOSTART_DESKTOP}"
    success "Autostart enabled — ${APP_NAME} will start the idle-dim watcher at login."
}

disable_autostart() {
    rm -f "${AUTOSTART_DESKTOP}" "${AUTOSTART_WRAPPER}" 2>/dev/null || true
    update-desktop-database "${DESKTOP_DIR}" 2>/dev/null || true
    success "Autostart disabled — ${APP_NAME} will no longer start at login."
}

cmd_toggle_autostart() {
    heading "Autostart at Login"
    if autostart_is_enabled; then
        info "Autostart is currently ENABLED."
        read -r -p "Disable it? [y/N]: " ans
        if [[ "${ans,,}" == "y" ]]; then
            disable_autostart
        else
            info "Left enabled."
        fi
    else
        info "Autostart is currently DISABLED."
        echo "When enabled, the idle-dim watcher starts automatically at login."
        echo "The brightness boot guard always runs regardless of this setting."
        read -r -p "Enable it? [y/N]: " ans
        if [[ "${ans,,}" == "y" ]]; then
            enable_autostart
        else
            info "Left disabled."
        fi
    fi
}

# ---------------------------------------------------------------------------
# Process control
# ---------------------------------------------------------------------------
is_running() {
    [[ -f "${PID_FILE}" ]] || return 1
    local pid
    pid=$(cat "${PID_FILE}" 2>/dev/null || echo "")
    [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}

force_restore_brightness() {
    # Unconditional fail-safe (safety net #4): works even if the watcher
    # process is hung, crashed, or was never running at all. Restores to the
    # brightness captured right before the most recent dim, not a blind 100%
    # — falls back to max only if no captured value has ever been recorded.
    local dir found=""
    for dir in /sys/class/backlight/*/; do
        [[ -e "${dir}display_name" ]] || continue
        if grep -q "DSI" "${dir}display_name" 2>/dev/null; then
            found="${dir}"
            break
        fi
    done
    if [[ -z "${found}" ]]; then
        found=$(ls -d /sys/class/backlight/*/ 2>/dev/null | head -n1 || true)
    fi
    if [[ -z "${found}" ]]; then
        warn "No backlight device found to restore."
        return 0
    fi
    if [[ ! -w "${found}brightness" ]]; then
        warn "Could not write to ${found}brightness directly (no permission)."
        warn "Try: sudo sh -c 'echo 255 > ${found}brightness'"
        return 0
    fi

    local maxb target source
    maxb=$(cat "${found}max_brightness" 2>/dev/null || echo 255)
    target=""
    if [[ -f "${STATE_FILE}" ]]; then
        target=$(cat "${STATE_FILE}" 2>/dev/null || echo "")
    fi
    if [[ "${target}" =~ ^[0-9]+$ ]] && (( target > 0 && target <= maxb )); then
        source="captured original brightness"
    else
        target="${maxb}"
        source="full brightness — no captured value yet, this is the safe fallback"
    fi

    echo "${target}" > "${found}brightness" 2>/dev/null || true
    success "Brightness restored to ${target}/${maxb} (${source}) on ${found}brightness."
}

# ---------------------------------------------------------------------------
# Log trimming — keeps LOG_FILE modest when logging is enabled.
# Trims to the last 100 lines if the file exceeds 50KB. Called by cmd_stop
# and cmd_install so it runs on user-initiated events, not continuously.
# The watcher's own log() function also trims inline (Python side).
# ---------------------------------------------------------------------------
trim_log() {
    if [[ ! -f "${LOG_FILE}" ]]; then
        return 0
    fi
    local size
    size=$(stat -c%s "${LOG_FILE}" 2>/dev/null || echo 0)
    if (( size > 51200 )); then
        local tmp
        tmp=$(tail -n 100 "${LOG_FILE}" 2>/dev/null || true)
        printf '%s\n' "${tmp}" > "${LOG_FILE}" 2>/dev/null || true
        info "Log trimmed to last 100 lines (was ${size} bytes)."
    fi
}

cmd_start() {
    if is_running; then
        warn "${APP_NAME} is already running (pid $(cat "${PID_FILE}"))."
        return 0
    fi
    if [[ ! -f "${WATCHER_PATH}" ]]; then
        err "Not installed yet. Run 'Install / Repair' first."
        return 1
    fi
    ensure_settings_file
    info "Starting ${APP_NAME}..."
    # Redirect stdout to /dev/null — the watcher's log() function writes
    # directly to LOG_FILE already. Redirecting stdout to LOG_FILE too caused
    # every log line to appear twice (once from log()'s file write, once from
    # the nohup stdout redirect). Confirmed on hardware 2026-06-22.
    nohup python3 "${WATCHER_PATH}" >>/dev/null 2>&1 &
    disown
    sleep 1
    if is_running; then
        success "${APP_NAME} is running. Stop it anytime with menu option 3, the desktop icon, or:"
        echo "  ${SELF_PATH} stop"
    else
        err "Watcher did not start — check ${LOG_FILE} for details."
        return 1
    fi
}

cmd_stop() {
    info "Stopping ${APP_NAME}..."
    if is_running; then
        local pid
        pid=$(cat "${PID_FILE}")
        kill -TERM "${pid}" 2>/dev/null || true
        for _ in 1 2 3 4 5; do
            kill -0 "${pid}" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "${pid}" 2>/dev/null; then
            warn "Watcher did not exit cleanly, forcing kill."
            kill -KILL "${pid}" 2>/dev/null || true
        fi
        # also reap any swayidle child left behind
        pkill -f "swayidle -w timeout" 2>/dev/null || true
    else
        info "${APP_NAME} was not running."
    fi
    rm -f "${PID_FILE}"
    # Unconditional, regardless of the above — guarantees a usable screen.
    force_restore_brightness
    trim_log
}

# ---------------------------------------------------------------------------
# Install / Uninstall
# ---------------------------------------------------------------------------
migrate_from_old_name() {
    # One-time migration (v1.3.0 rename, "Backlight Solace" -> "Backlight
    # DSI Solace"). If a previous install exists under the old slug, stop
    # it cleanly, restore brightness, remove its desktop entries/icon, and
    # carry its settings forward — so re-running Install/Repair after this
    # update doesn't leave an orphaned icon, a phantom background process,
    # or a forgotten idle-timeout/fade preference behind. No-ops silently
    # if no old install is found (the normal case after the first run).
    local found_old=0
    [[ -d "${OLD_INSTALL_DIR}" ]] && found_old=1
    [[ -d "${OLD_CONFIG_DIR}" ]] && found_old=1
    [[ -f "${DESKTOP_DIR}/${OLD_APP_SLUG}-start.desktop" ]] && found_old=1
    [[ -f "${DESKTOP_DIR}/${OLD_APP_SLUG}-stop.desktop" ]] && found_old=1
    [[ -f "${DESKTOP_DIR}/${OLD_APP_SLUG}-gui.desktop" ]] && found_old=1
    [[ -f "${OLD_ICON_PATH}" ]] && found_old=1

    if (( found_old == 0 )); then
        return 0
    fi

    info "Found a previous \"Backlight Solace\" install — migrating to ${APP_NAME}..."

    # Stop the old watcher if it's running (its own PID file, separate
    # from this script's current PID_FILE).
    if [[ -f "${OLD_PID_FILE}" ]]; then
        local old_pid
        old_pid=$(cat "${OLD_PID_FILE}" 2>/dev/null || echo "")
        if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
            kill -TERM "${old_pid}" 2>/dev/null || true
            sleep 1
            if kill -0 "${old_pid}" 2>/dev/null; then
                kill -KILL "${old_pid}" 2>/dev/null || true
            fi
        fi
    fi
    pkill -f "swayidle -w timeout" 2>/dev/null || true

    # Force-restore brightness in case the old watcher was mid-dim when
    # stopped above — same unconditional safety net cmd_stop relies on.
    force_restore_brightness

    # Carry settings forward if the new config doesn't have them yet.
    if [[ -f "${OLD_SETTINGS_FILE}" ]] && [[ ! -f "${SETTINGS_FILE}" ]]; then
        mkdir -p "${CONFIG_DIR}"
        cp -f -- "${OLD_SETTINGS_FILE}" "${SETTINGS_FILE}"
        info "Carried forward your idle timeout / fade duration settings."
    fi

    # Remove old runtime files, desktop entries, icon, and install/config
    # dirs. Nothing here touches dependencies (swayidle, gtk-layer-shell,
    # etc.) — those stay installed per project policy.
    rm -f "${OLD_PID_FILE}" "${OLD_GUI_PID_FILE}" "${OLD_STATE_FILE}"
    rm -f "${DESKTOP_DIR}/${OLD_APP_SLUG}-start.desktop"
    rm -f "${DESKTOP_DIR}/${OLD_APP_SLUG}-stop.desktop"
    rm -f "${DESKTOP_DIR}/${OLD_APP_SLUG}-gui.desktop"
    rm -f "${OLD_ICON_PATH}"
    # Old-name autostart/guard entries, in case a pre-rename install ever had
    # them (defensive — the old name predates v1.5.0, but harmless to clean).
    rm -f "${AUTOSTART_DIR}/${OLD_APP_SLUG}-autostart.desktop"
    rm -f "${AUTOSTART_DIR}/${OLD_APP_SLUG}-guard.desktop"
    rm -rf "${OLD_INSTALL_DIR}" "${OLD_CONFIG_DIR}"

    gtk-update-icon-cache -f -t "${HOME}/.local/share/icons/hicolor" 2>/dev/null || true
    update-desktop-database "${DESKTOP_DIR}" 2>/dev/null || true

    success "Migration complete — old \"Backlight Solace\" files removed."
}

cmd_install() {
    heading "Install / Repair ${APP_NAME}"
    migrate_from_old_name
    mkdir -p "${INSTALL_DIR}" "${CONFIG_DIR}"
    check_deps
    check_backlight_device || warn "Continuing anyway — fix the display connection if dimming doesn't work."
    ensure_settings_file
    write_watcher_script
    write_gui_script
    write_icon
    # Mirror this manager script into INSTALL_DIR so desktop entries have a
    # stable path to call (same self-mirroring pattern as
    # script-launcher-manager.sh).
    if [[ "$(readlink -f "$0")" != "$(readlink -f "${SELF_PATH}" 2>/dev/null || echo "")" ]]; then
        cp -f -- "$0" "${SELF_PATH}"
        chmod +x "${SELF_PATH}"
    fi

    # GUI menu entry — always installed (Settings/Preferences section).
    write_gui_menu_entry
    success "GUI shortcut added to Settings/Preferences in the app menu."

    # Optional: Start/Stop shortcuts in app menu.
    local ans_ss
    read -r -p "Add Start and Stop shortcuts to Settings/Preferences? [y/N]: " ans_ss
    if [[ "${ans_ss,,}" == "y" ]]; then
        write_start_stop_entries
        success "Start and Stop shortcuts added to Settings/Preferences."
    else
        # Remove any from a prior install so re-running Install/Repair is clean.
        rm -f "${DESKTOP_DIR}/${APP_SLUG}-start.desktop" \
              "${DESKTOP_DIR}/${APP_SLUG}-stop.desktop"
        info "Start/Stop shortcuts skipped."
    fi

    # Optional: desktop launcher icon (pinned to ~/Desktop).
    local ans_dl
    read -r -p "Add a GUI launcher icon to the desktop? [y/N]: " ans_dl
    if [[ "${ans_dl,,}" == "y" ]]; then
        write_desktop_launcher
        success "Desktop launcher icon added to ${XDG_DESKTOP_DIR}."
    else
        rm -f "${XDG_DESKTOP_DIR}/${APP_SLUG}.desktop"
        info "Desktop launcher skipped."
    fi

    # Optional: WirePlumber restart shortcut in the start menu.
    local ans_wp
    read -r -p "Add a 'Re-detect HDMI Audio' shortcut to the start menu? [y/N]: " ans_wp
    if [[ "${ans_wp,,}" == "y" ]]; then
        write_wireplumber_menu_entry
        success "WirePlumber restart shortcut added to Settings/Preferences."
    else
        rm -f "${WP_DESKTOP}"
        info "WirePlumber start-menu shortcut skipped."
    fi

    gtk-update-icon-cache -f -t "${HOME}/.local/share/icons/hicolor" 2>/dev/null || true
    update-desktop-database "${DESKTOP_DIR}" 2>/dev/null || true
    # Always (re)install the brightness boot guard — runs at every login,
    # independent of the autostart toggle. Reinstalled on every Install/Repair
    # so wrapper bug fixes propagate (v1.5.0).
    install_guard
    # If watcher autostart was previously enabled, re-write its wrapper too so
    # any wrapper bug fixes propagate without the user having to re-toggle.
    if autostart_is_enabled; then
        write_autostart_wrapper
        info "Autostart is enabled — refreshed its wrapper."
    fi
    touch "${MARKER_FILE}"
    trim_log
    success "${APP_NAME} installed."
    info "GUI shortcut is in Settings/Preferences in the app menu."
    info "The brightness boot guard is installed and will run at every login."
    info "Or run: ${SELF_PATH} start"
}

cmd_uninstall() {
    heading "Uninstall ${APP_NAME}"
    read -r -p "This removes all ${APP_NAME} files and configs (dependencies are kept). Continue? [y/N]: " ans
    if [[ "${ans,,}" != "y" ]]; then
        info "Uninstall cancelled."
        return 0
    fi
    cmd_stop || true
    remove_desktop_entries
    # Remove both autostart entries (opt-in watcher autostart AND the always-on
    # boot guard) and their wrappers, unconditionally regardless of toggle
    # state (v1.5.0).
    disable_autostart >/dev/null 2>&1 || true
    remove_guard
    rm -rf "${INSTALL_DIR}" "${CONFIG_DIR}"
    rm -f "${PID_FILE}" "${STATE_FILE}"
    success "${APP_NAME} fully removed."
    info "Autostart entry and brightness boot guard were removed from ~/.config/autostart/."
    info "Dependencies (swayidle, gir1.2-gtklayershell-0.1, python3-gi, gir1.2-gtk-3.0) were intentionally left installed."
}

cmd_show_logs() {
    heading "Recent Log Output"
    if [[ -f "${LOG_FILE}" ]]; then
        tail -n 40 "${LOG_FILE}"
    else
        info "No log file yet — start ${APP_NAME} at least once."
    fi
}

cmd_show_device_info() {
    heading "Backlight Device Info"
    check_backlight_device
}

cmd_redetect_hdmi_audio() {
    heading "Re-detect HDMI Audio"
    info "Restarting WirePlumber to re-enumerate audio devices..."
    if systemctl --user restart wireplumber; then
        success "WirePlumber restarted successfully — check your audio output."
    else
        err "WirePlumber restart failed. Check: systemctl --user status wireplumber"
    fi
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
show_menu() {
    while true; do
        heading "${APP_NAME}"
        read_settings 2>/dev/null || true
        local as_state="disabled"
        autostart_is_enabled && as_state="ENABLED"
        echo "Idle timeout: ${IDLE_TIMEOUT:-${DEFAULT_IDLE_TIMEOUT}}s   Fade: ${FADE_DURATION:-${DEFAULT_FADE_DURATION}}s   Running: $(is_running && echo yes || echo no)"
        echo "Autostart: ${as_state}   Failsafe: ${FAILSAFE_BRIGHTNESS:-${DEFAULT_FAILSAFE_BRIGHTNESS}}%   Boot guard: always on"
        echo "Note: Chrome video & PS4 touchpad reset the timer fine. Controller buttons/sticks do not."
        cat <<MENU

  1) Install / Repair
  2) Start ${APP_NAME}
  3) Stop ${APP_NAME}  (force-restores full brightness no matter what)
  4) Edit Settings (idle timeout / fade duration / failsafe brightness)
  5) Autostart at login  (toggle — currently ${as_state})
  6) Show Logs
  7) Show Backlight Device Info
  8) Re-detect HDMI Audio
  9) Uninstall
  10) Exit

MENU
        read -r -p "Choose an option [1-10]: " choice
        case "${choice}" in
            1) cmd_install ;;
            2) cmd_start ;;
            3) cmd_stop ;;
            4) cmd_edit_settings ;;
            5) cmd_toggle_autostart ;;
            6) cmd_show_logs ;;
            7) cmd_show_device_info ;;
            8) cmd_redetect_hdmi_audio ;;
            9) cmd_uninstall ;;
            10) info "Bye."; exit 0 ;;
            *) warn "Invalid choice." ;;
        esac
        echo
        read -r -p "Press Enter to continue..." _
    done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "${1:-menu}" in
    start) cmd_start ;;
    stop) cmd_stop ;;
    install) cmd_install ;;
    uninstall) cmd_uninstall ;;
    enable-autostart) ensure_settings_file; enable_autostart ;;
    disable-autostart) disable_autostart ;;
    write-wp-launcher) write_wireplumber_menu_entry ;;
    menu) show_menu ;;
    *) err "Unknown argument: ${1}"; echo "Usage: $0 [start|stop|install|uninstall|enable-autostart|disable-autostart|write-wp-launcher|menu]"; exit 1 ;;
esac
