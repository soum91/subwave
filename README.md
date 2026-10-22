# Subwave

An iOS app for a Vizio sound bar that replaces the Vizio app. It talks to the bar straight over your Wi-Fi with SmartCast (the API Vizio's own app uses underneath) and falls back to a Tuya IR blaster when the bar is asleep or its Wi-Fi side stops answering. No Vizio account.

## Features

- **Wi-Fi first, IR as backup.** Every command tries SmartCast, then the IR blaster (the same one [Redshift](https://github.com/soum91/redshift) uses). Settings › Send commands picks Wi-Fi then IR, Wi-Fi only or IR only. The status line shows which path the last command took.
- **Power, exact volume, mute, inputs.** Volume slider over Wi-Fi, hold-to-repeat +/- over IR. Inputs come from the bar itself (TV/ARC, Bluetooth, optical, AUX, USB…).
- **Every setting the bar exposes.** Sound settings and Bar settings browse the bar's own SmartCast menus: EQ, bass, treble, subwoofer, center, surround, height, dialogue, night mode, TruVolume, Virtual:X, DTS, AV delay, LED, speaker test, CEC, name, reset… Sliders, switches and pickers are built from what the bar reports, so it works with whatever model and firmware you have.
- **Sound buttons that work either way.** Sound modes (Movie, Music, Game, Direct), Night, TruVolume, Virtual:X, Surround and level +/- go over Wi-Fi by finding the matching setting on the bar, and over IR when there isn't one.
- **Presets** like Afterglow scenes: TV, Music, Late night, Off to start. Each can turn the bar on, pick an input, set a volume, press sound buttons, and replay exact settings captured from the bar ("Capture how the bar sounds now").
- **Google Cast now playing.** When something is casting to the bar: title, artist, artwork, play/pause, skip, seek, and stop casting.
- **Bluetooth.** Switch to BT, put the bar in pairing mode, pick the bar as this phone's audio output (route picker), and see whether the phone is connected to it.
- **Remote** laid out like the Vizio one (power, volume and bass rockers, mute, transport, sound modes, inputs), then every Vizio sound bar button (built-in NEC codes from the SB3651 / V-series remotes), learn mode to record any button from your real remote, and import of Redshift's learned sound bar buttons.
- **iPhone volume buttons** turn the bar up and down while Subwave is open (Settings to turn off). Not when the bar is off, or when the phone is already playing through it over Bluetooth.
- **Widgets**: small (volume, power, +/-, mute), medium (plus 4 presets), large (a full remote: volume rocker, mute, transport, sound modes, inputs, BT pairing, presets), lock screen circular, rectangular and inline. All buttons work without opening the app.
- **Control Center** (iOS 18): Sound bar power and Mute toggles, Volume up / down buttons, and a Preset button. They also work on the lock screen corner buttons and the Action button.
- **Siri** with no setup: "sound bar off in Subwave", "Subwave louder", "mute Subwave", "Subwave Late night", "switch Subwave to Bluetooth", "bedtime in Subwave" (bar off unless the TV is on).
- **Shortcuts actions**: Set Sound Bar Power, Turn Sound Bar On/Off, Toggle, Volume Up/Down, Set Volume, Mute, Set Input, Run Preset, Press Button (any remote button), Play/Pause, Next Track, Is the Sound Bar On, Sound Bar Off If TV Is Off.

## Bar off when the TV goes off

Same trick as Afterglow's lights, on the same hardware: the [Afterglow bridge](https://github.com/soum91/afterglow/blob/main/Bridge/README.md) (ESP32, firmware 1.1+) watches the Sony TV every 4 s and, when it goes off, switches the bar off after a delay you set. Optional bar-on when the TV turns on, time windows, and a **Sound Bar** plus **Sound Bar Follows TV** switch in Apple Home. Over Wi-Fi it sends a real "power off", so it never fights HDMI-CEC; over IR it only presses the power toggle when that's safe (see the bridge README). Subwave pairs with the bridge separately from Afterglow.

Without the bridge: a Shortcuts automation running **Sound Bar Off If TV Is Off**.

## Setup

1. Sideload the IPA from [Releases](https://github.com/soum91/subwave/releases) (AltStore, SideStore, Sideloadly or FlareStore with the source below; keep app extensions on).
2. Set up › Sound bar on Wi-Fi: Subwave finds it through Cast/SmartCast Bonjour, or type its IP. Give it a fixed IP in your router.
3. Set up › Tuya IR blaster: sign in with your Smart Life user code once (only to fetch the blaster's local key), pick the blaster, Subwave finds it on your Wi-Fi.
4. Optional: Settings › Sony TV, then Follow the TV › pair the bridge.

Sideloading source: `https://raw.githubusercontent.com/soum91/subwave/source/source.json`

## Build

Every push to `main` builds `Subwave-<version>-build-<N>.ipa` on GitHub Actions and publishes it as release `build-N` with a changelog since the previous build. The app and widget are ad-hoc signed with the `group.com.soum91.subwave` App Group.

Local: `brew install xcodegen && xcodegen generate`, open `Subwave.xcodeproj`.

## How it talks to the bar

SmartCast: HTTPS with the bar's self-signed certificate on port 7345 (9000 on older firmware), the same endpoints [pyvizio](https://github.com/raman325/pyvizio) and Home Assistant's Vizio integration use. Power state from `/state/device/power_mode`, keys through `/key_command/` (codeset 11 power, 5 volume/mute, 2 transport), settings by reading `/menu_native/dynamic/audio_settings/…` for values and hash handles, `/menu_native/static/…` for ranges and choices, and writing back with `MODIFY`. Sound bars don't need pairing; if one does, Set up › Sound bar › Pairing handles the PIN.

Google Cast: CASTV2 on port 8009 (TLS, length-prefixed protobuf with JSON payloads) for receiver and media status and control.

IR: NEC frames (9 ms / 4.5 ms leader, address 0x00) turned into the Tuya blaster's raw pulse format, sent over Tuya's LAN protocol (3.3 / 3.4 / 3.5) with either the classic (DP 201/202) or newer (DP 1–13) command set, detected automatically.

Independent implementation, not affiliated with Vizio, Google, Tuya or Sony.
