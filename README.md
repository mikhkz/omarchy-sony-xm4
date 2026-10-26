# omarchy-sony-xm4 (`Sony WH-1000XM4` for Omarchy)

An Omarchy bar widget and background service for **Sony WH-1000XM4**, featuring full Sony MDR v1 protocol control, PipeWire codec switching, and seamless multipoint A2DP audio handoff between your Linux PC and phone.

> **Companion Driver**: Pair this plugin with [`pipewire-sony-xm4-lowlatency`](https://github.com/mikhkz/pipewire-sony-xm4-lowlatency) to eliminate post-dropout A2DP buffer buildup and multi-second audio lag on Linux.

---

## Features

- **Sony WH-1000XM4 Native Control (`sony-v1-bridge`)**
  - **Listening Modes**: `Off`, `ANC` (Active Noise Cancelling), `Wind` (Wind Noise Reduction), and `Ambient` (Ambient Sound).
  - **Ambient Sound Controls**: 0–20 passthrough slider + **Focus on Voice** toggle.
  - **Multipoint (2 Devices) Toggle**: Enable or disable dual-device Bluetooth connection directly from the bar panel, with protocol handshake confirmation and automatic reconnect grace handling.
  - **Auto Power-Off**: Configure headset auto power-off (`5 min`, `30 min`, `1 h`, `3 h`, `When removed`, `Never`).
  - **Animated Visual Layers**: Smooth high-overlap crossfade between `off`, `anc`, `wind`, and `ambient` visual states in the popup hero.
  - **Multi-Host State Caching**: Preserves the last confirmed headset state if the Sony RFCOMM control channel is temporarily held by another multipoint host.
- **Seamless Multipoint A2DP Audio Handoff (`host-audio`)**
  - Switch active A2DP ownership between **Computer** and **Phone** with one click without dropping the Bluetooth ACL link or Sony control channel.
  - **Auto Handoff on Pause**: When you pause media on your PC, the service automatically releases the local A2DP profile after a configurable delay (default `3 s`) so your phone can immediately play audio; resuming playback on PC automatically reclaims A2DP and restores your active streams and codec profile.
- **PipeWire Codec Switcher**
  - View and switch available PipeWire A2DP codecs (`LDAC`, `AAC`, `SBC-XQ`, `SBC`) directly from the panel.
- **Battery Telemetry**
  - Reads battery levels via Google Fast Pair Message Stream (`gfps-reader`) or `org.bluez.Battery1`, filling the bar icon proportionally and sending critical low-battery notifications.

---

## Installation

Install directly with the Omarchy CLI:

```sh
omarchy plugin add https://github.com/mikhkz/omarchy-sony-xm4 --enable
```

Or install from a local checkout:

```sh
cp -r omarchy-sony-xm4 ~/.config/omarchy/plugins/sony-xm4
omarchy restart shell
```

### Dependencies

- **Arch Linux / Omarchy**: `bluez`, `bluez-utils` (`bluetoothctl`), `pipewire-pulse` (`pactl`), `python-dbus`, `python-gobject`

---

## Keyboard Shortcuts (Inside Panel)

| Key | Action |
| :--- | :--- |
| `q` / `w` / `e` / `r` | Switch mode: `Off` / `ANC` / `Wind` / `Ambient` |
| `[` / `]` or `h` / `l` | Decrease / increase Ambient Sound level (`0–20`) |
| `f` | Toggle **Focus on Voice** (in Ambient mode) |
| `Enter` | Refresh battery, codec, and control channel |
| `,` / `.` | Switch between multiple connected audio devices |
| `b` / `v` | Open Omarchy Bluetooth / Audio panel |

---

## IPC CLI (`omarchy-shell sony-xm4 <command>`)

Control everything from scripts, Hyprland keybindings, or automation:

```sh
# Status & battery
omarchy-shell sony-xm4 status
omarchy-shell sony-xm4 battery

# Noise control & Ambient level
omarchy-shell sony-xm4 mode
omarchy-shell sony-xm4 setMode anc       # off | anc | wind | ambient
omarchy-shell sony-xm4 setAmbientLevel 15 # 0..20
omarchy-shell sony-xm4 setAmbientVoice on # on | off

# PipeWire A2DP codec
omarchy-shell sony-xm4 codec
omarchy-shell sony-xm4 codecs
omarchy-shell sony-xm4 setCodec SBC-XQ

# Multipoint & A2DP source handoff
omarchy-shell sony-xm4 multipoint
omarchy-shell sony-xm4 setMultipoint on  # on | off
omarchy-shell sony-xm4 audioSource
omarchy-shell sony-xm4 setAudioSource other   # computer | other

# Auto power-off
omarchy-shell sony-xm4 powerOffSetting
omarchy-shell sony-xm4 setPowerOffSetting removed # 5min | 30min | 1h | 3h | removed | off
```

---

## Running Tests

```sh
python3 -m unittest discover -s tests -p "*_test.py"
```

---

## License

[MIT](LICENSE)
