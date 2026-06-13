# YeelightSyncColorScreen

`YeelightSyncColorScreen` is the Swift executable that syncs a selected macOS
display's average color to selected Yeelight RGB bulbs.

## Commands

List displays:

```bash
swift run YeelightSyncColorScreen --list-displays
```

List bulbs:

```bash
swift run YeelightSyncColorScreen --list-devices
```

Start sync:

```bash
swift run YeelightSyncColorScreen --display 0 --id <device-id>
```

Stop sync with `Ctrl-C`.

## Runtime Flow

In sync mode, the executable:

1. Parses CLI arguments.
2. Checks or requests Screen Recording permission.
3. Discovers Yeelight devices.
4. Filters devices by the requested `--id` values.
5. Starts Yeelight music mode for each selected bulb.
6. Captures the selected display at the configured FPS.
7. Computes the average frame color using the configured sample stride.
8. Sends changed RGB values to every active music-mode socket.
9. Stops music mode and closes sockets on shutdown.

## Permission Behavior

The executable requests macOS Screen Recording permission before discovering
bulbs or starting music mode. This avoids leaving bulbs in music mode if screen
capture is denied.

If macOS does not show a prompt, enable permission manually:

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
```

Then enable the terminal app, quit it, reopen it, and run the command again.

## Sync Behavior

Defaults:

- `--fps 10`
- `--sample-stride 8`
- `--discovery-timeout 5`

Duplicate RGB values are skipped, so the executable does not send repeated
commands when the average color has not changed.

The executable sends `set_rgb` only. It does not send `set_bright`, does not
apply a minimum brightness clamp, and does not automatically power bulbs off.

When the screen is black, the average color is `RGB(0,0,0)`, which is sent to the
bulb as Yeelight RGB value `0`.

## Troubleshooting

- Screen permission error: Enable Screen Recording for the terminal app.
- No devices found: Check LAN control, Wi-Fi/LAN, and discovery timeout.
- Missing device ID: Run `--list-devices` again and copy the fresh ID.
- Non-RGB device: Use a Yeelight bulb that supports `set_rgb`.
- Command timeout: Check bulb reachability, LAN control, firewall, and network.

## Notes

This is a command-line tool, not a packaged macOS app. The terminal app is the
process that macOS sees for Screen Recording permission.
