# VolCon (Multi-Output Volume Controller) - Agent Instructions

Welcome! If you are an agent working on this project, please adhere to the following rules and guidelines:

1. **Project Plan**: Always refer to the [project-plan.md](../project-plan.md) in the root of the workspace for the architectural overview and implementation steps.
2. **Framework Restrictions**:
   - Use `IOKit` for hardware event monitoring (`HIDMonitor`). Do **not** use `CGEventTap` as it is unreliable for Bluetooth media keys during Multi-Output device usage.
   - Use `CoreAudio` for all device discovery and volume mutations (`AudioStateManager`, `VolumeExecutor`).
3. **Hardware Fingerprints**: Do not match audio devices by human-readable string names. Always use the MAC address (Bluetooth) or VID/PID (USB) via the `HardwareFingerprint` data model.
4. **Concurrency**: CoreAudio listener callbacks happen on background threads. Ensure that all shared state modifications in `AudioStateManager` and `VolumeExecutor` are strictly thread-safe.
5. **C-Interop**: Be mindful of CoreAudio's C-pointers. Always fetch `AudioObjectGetPropertyDataSize` before allocating memory buffers in Swift.

### Project-Specific Quirks & Debugging Notes (CRITICAL)
- **CoreAudio `nope` Error (Error 1852797029)**: When the app connects to CoreAudio, the internal `HALC_ShellObject` might log a `nope` error trying to `SetPropertyData`. This is a harmless system red herring caused by Apple's internal HAL initialization. Do not try to debug this error if the app is otherwise functioning.
- **Extracting Sub-Devices**: Do **not** rely on `deviceClass == kAudioAggregateDeviceClassID` to identify a Multi-Output device. It is flaky. Instead, query the `kAudioAggregateDevicePropertyFullSubDeviceList` property directly. If the query succeeds, you know it is an Aggregate/Multi-Output device.
- **Master Channel Volumes**: Physical sub-devices rarely support a Master Volume (`kAudioObjectPropertyElementMain` / `0`). Always use `AudioObjectIsPropertySettable` to discover which channels actually support the `kAudioDevicePropertyVolumeScalar` property, and apply changes to all supported channels (e.g., Left/Right channels 1 and 2).
- **Accessibility Sandbox**: When testing the app via Xcode, the ad-hoc built binary constantly changes its CDHash, which invalidates the macOS Accessibility permissions in System Settings. To test the `IOKit` global key listener with logs without losing permissions, either launch the specific `DerivedData` executable from the terminal using `sudo`, OR drag the built `.app` to Accessibility and strictly use `Control + Command + R` ("Run Without Building") in Xcode.
- **Accessibility UI Flow**: We have implemented an `NSAlert` in `VolConApp.swift` that automatically detects if accessibility permissions are missing. If they are, it prompts the user and *terminates the application* (`NSApp.terminate`). Do not mistake this intentional termination as a crash on launch.
