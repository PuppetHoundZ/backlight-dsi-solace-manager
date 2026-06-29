# Backlight DSI Solace — Manager & Screen Saver.

An opt-in, long-running background idle-dim manager and touchscreen utility designed specifically for the official Raspberry Pi 7" DSI touchscreen panel. It implements an intelligent screensaver workflow under the Wayland protocol, fading screen brightness dynamically during periods of inactivity and waking seamlessly on the initial touch event.

This tool acts completely in user space: it is **never** deployed as a systemd service, **never** alters audio/PipeWire endpoints automatically, and **never** forces autostart configurations unless explicitly toggled on by the user.

---

## 📐 Display Architecture & Layout Topology

When the idle timer expires, the screen state transitions through a strict sequence to eliminate hardware backlight race conditions and visually jarring flickering. 

### Transition Workflow Sequences
1. **Dim Order Sequence:** Backlight fades smoothly to `0` **FIRST** $\rightarrow$ Fullscreen black blocking overlay layer renders **AFTER**.
2. **Wake Order Sequence:** Fullscreen black blocking overlay hides **FIRST** $\rightarrow$ Backlight fades smoothly back up to its cached pre-dim value **AFTER**.

### Screen Dimension Layer Mapping
The script targets the physical geometry of official Raspberry Pi DSI touch panels via a static allowlist (e.g., $800\times480$ or $1280\times720$) coupled with physical millimetric fallbacks to correctly bind the overlay context to the touch layer when multi-monitor HDMI connections are present.

### Install:
```bash
mkdir -p ~/.local/share/backlight-dsi-solace && nano ~/.local/share/backlight-dsi-solace/backlight-dsi-solace-manager.sh && chmod +x ~/.local/share/backlight-dsi-solace/backlight-dsi-solace-manager.sh && ~/.local/share/backlight-dsi-solace/backlight-dsi-solace-manager.sh

```

### What this command does:

1. **`mkdir -p ...`**: Creates the internal application directory (`~/.local/share/backlight-dsi-solace`) to match the script's strict `INSTALL_DIR` internal paths.
2. **`nano ...`**: Opens a blank terminal text editor at the correct target file location (`backlight-dsi-solace-manager.sh`). **Paste your script code here, then press `Ctrl+O` to save and `Ctrl+X` to exit.**
3. **`chmod +x ...`**: Grants execution permissions to the manager utility.
4. **`~/.local/...`**: Automatically launches the interactive setup menu, allowing you to run the dependency check and toggle your autostart configurations.

##  References:
* **Official 7" Touch Display Product Brief PDF:** `datasheets.raspberrypi.com/display/7-inch-display-product-brief.pdf`
* **Official Touch Display 2 Documentation:** `raspberrypi.com/documentation/accessories/touch-display-2.html`
* **Official Raspberry Pi News Announcement (5" variant):** `raspberrypi.com/news/a-new-5-variant-of-raspberry-pi-touch-display-2/`
* **Raspberry Pi Engineering Forums Discussion (Landscape Configuration):** `forums.raspberrypi.com/viewtopic.php?t=379738`
* **Swayidle Upstream Gamepad Limitation Thread:** `github.com/swaywm/swayidle/issues/68`
