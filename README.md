# VolCon (Multi-Output Volume Controller)

> **Note:** This project is currently **under active development**.

VolCon is a macOS Menu Bar utility that restores the ability to control volume using your hardware media keys when a Multi-Output (Aggregate) audio device is the active system output.

Normally, macOS disables volume controls for Multi-Output devices. VolCon runs silently in the background, intercepts hardware volume keys using `IOKit`, and safely translates those inputs directly to the underlying physical sub-devices.

## Features
- **Zero-Latency Adjustments**: Event-driven architecture ensures instant volume changes.
- **Hardware Agnostic**: Reliably maps devices via hardware fingerprints (Bluetooth MAC / USB VID/PID).
- **Background Operation**: Runs strictly as an accessory (menu bar only).

## Download

Grab the latest **`VolCon.zip`** from the [Releases page](https://github.com/raythrp/volcon/releases/latest).

- Universal binary — Apple Silicon **and** Intel Macs.
- Requires **macOS 15.7 or later**.

## Quick Start

### 1. Install
1. Unzip `VolCon.zip`.
2. Drag **VolCon.app** into your `/Applications` folder.

### 2. Allow the app (unidentified developer)
VolCon is not signed with a paid Apple Developer certificate, so macOS Gatekeeper blocks it on first launch.

- **Right-click** (or Control-click) **VolCon.app → Open**, then click **Open** in the dialog. Double-clicking alone will not work the first time.
- If macOS says the app is *"damaged and can't be opened"*, clear the download quarantine flag once in Terminal:
  ```bash
  xattr -dr com.apple.quarantine /Applications/VolCon.app
  ```
  Then Right-click → Open again.

> You only need to do this once. After the first successful open, launch it normally.

### 3. Grant Input Monitoring (required)
VolCon reads your hardware volume keys via `IOKit`, which needs **Input Monitoring** permission.

1. Open **System Settings → Privacy & Security → Input Monitoring**.
2. Enable the toggle next to **VolCon** (add it with the **+** button if it is not listed).
3. If prompted, quit and reopen VolCon so the permission takes effect.

Without this permission the menu bar icon appears but the volume keys will not respond.

### 4. Accessibility (optional)
VolCon does **not** currently require Accessibility. If a future build asks for it, grant it under **System Settings → Privacy & Security → Accessibility** the same way as Input Monitoring above.

### Using it
- Look for the **volume-knob icon** in your menu bar.
- Click it to pick which output devices belong to the Multi-Output group.
- Your keyboard volume keys now control that group directly.
