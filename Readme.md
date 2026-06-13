# Yeelight Station macOS

Sync your Mac screen color to Yeelight Wi-Fi bulbs.

`YeelightSyncColorScreen` captures one display, computes the dominant sampled
screen color with HSV clustering, and streams that color to the Yeelight bulbs
you choose. It uses Yeelight music mode so color updates can be sent quickly
while the sync is running.

## What You Need

- macOS 13 or newer.
- Swift 6 installed.
- A Yeelight RGB bulb.
- Your Mac and bulb on the same Wi-Fi or local network.
- LAN control enabled for the bulb in the Yeelight app.
- Screen Recording permission for the terminal app you use.

## Quick Start

Open a terminal in this project folder.

List your displays:

```bash
swift run YeelightSyncColorScreen --list-displays
```

Example:

```text
0 main: VA2719 Series 1920x1080
1: Built-in Retina Display 1440x900
```

List your Yeelight bulbs:

```bash
swift run YeelightSyncColorScreen --list-devices
```

Example:

```text
0x00000000189921cf name=- host=192.168.2.33:55443 type=color support=... set_rgb set_music
```

Start syncing display `0` to that bulb:

```bash
swift run -c release YeelightSyncColorScreen --display 0 --id 0x00000000189921cf
```

Stop syncing with `Ctrl-C`.

Use `-c release` for normal syncing. Plain `swift run` uses a debug build and
can use much more CPU.

## Screen Recording Permission

The first sync run may ask macOS for permission to capture the screen. If no
prompt appears, open the permission screen manually:

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
```

Enable the terminal app you are using, such as Terminal, iTerm2, Warp, VS Code,
or Cursor. Then fully quit and reopen that app before running the command again.

## Common Commands

List displays:

```bash
swift run YeelightSyncColorScreen --list-displays
```

List bulbs with a longer discovery wait:

```bash
swift run YeelightSyncColorScreen --list-devices --discovery-timeout 10
```

Sync one bulb:

```bash
swift run -c release YeelightSyncColorScreen --display 0 --id <device-id>
```

Sync multiple bulbs:

```bash
swift run -c release YeelightSyncColorScreen --display 0 --id <device-id-1> --id <device-id-2>
```

Use smoother updates with more CPU:

```bash
swift run -c release YeelightSyncColorScreen --display 0 --id <device-id> --fps 10
```

Use more precise color sampling with more CPU:

```bash
swift run -c release YeelightSyncColorScreen --display 0 --id <device-id> --sample-stride 16
```

## Options

- `--list-displays`: Show display IDs and names.
- `--list-devices`: Discover Yeelight bulbs on the local network.
- `--display <id>`: Required for sync mode. Use an ID from `--list-displays`.
- `--id <device-id>`: Required for sync mode. Repeat it for multiple bulbs.
- `--fps <number>`: Updates per second. Default: `2`.
- `--sample-stride <number>`: Pixel sampling step before HSV clustering.
  Default: `64`. Lower is more precise and uses more CPU; higher is faster and
  rougher.
- `--discovery-timeout <seconds>`: Device discovery wait time. Default: `5`.

## What Happens With Dark Screens

The tool sends RGB colors only. It does not separately change Yeelight brightness
and does not automatically turn bulbs on or off.

Examples:

```text
white screen -> RGB(255, 255, 255)
gray screen  -> RGB(80, 80, 80)
black screen -> RGB(0, 0, 0)
```

If the screen is black, the bulb receives `RGB(0,0,0)`. This usually makes the
bulb effectively dark, but it is not the same as powering the bulb off.

## Troubleshooting

### No bulbs found

Make sure the bulb is powered on, on the same network, and has LAN control
enabled in the Yeelight app. Then try:

```bash
swift run YeelightSyncColorScreen --list-devices --discovery-timeout 10
```

### Screen permission error

Open Screen Recording settings:

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
```

Enable your terminal app, quit it, reopen it, and run the sync command again.

### `request timed out`

The bulb did not answer a command. Run `--list-devices` again and use the fresh
ID. Also check LAN control, Wi-Fi, and firewall settings.

### Bulb is rejected

The sync tool requires RGB support. White-only bulbs are rejected.

## Developer Docs

Module documentation is in [`Docs`](Docs/README.md).

Build:

```bash
swift build
```

Test:

```bash
swift test
```
