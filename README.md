# VolCon (Multi-Output Volume Controller)

> **Note:** This project is currently **under active development**.

VolCon is a macOS Menu Bar utility that restores the ability to control volume using your hardware media keys when a Multi-Output (Aggregate) audio device is the active system output.

Normally, macOS disables volume controls for Multi-Output devices. VolCon runs silently in the background, intercepts hardware volume keys using `IOKit`, and safely translates those inputs directly to the underlying physical sub-devices.

## Features
- **Zero-Latency Adjustments**: Event-driven architecture ensures instant volume changes.
- **Hardware Agnostic**: Reliably maps devices via hardware fingerprints (Bluetooth MAC / USB VID/PID) instead of fragile string names.
- **Background Operation**: Runs strictly as an accessory (menu bar only) with minimal system footprint.
