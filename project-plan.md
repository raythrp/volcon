# Project Name: Multi-Output Volume Controller (macOS)

## 1. Project Overview
Build a macOS Menu Bar utility (`LSUIElement = true` in Info.plist) that restores the ability to control volume using hardware media keys when a Multi-Output (Aggregate) audio device is the active system output.

The app uses an **Event-Driven Architecture** to ensure zero-latency volume adjustments, directly modifying the physical sub-device's volume based on hardware interrupts.

## 2. Architecture & File Structure
To maintain clean separation of concerns, the application logic is divided into the following Swift files:

1. **`AppMain.swift` / `AppDelegate.swift`**: Handles application bootstrapping, the `NSStatusItem` (menu bar UI), application lifecycle, and requests macOS Accessibility Permissions on the first launch.
2. **`AudioStateManager.swift`**: A `CoreAudio` wrapper that monitors the system's default output, identifies if it's an Aggregate Device, extracts its underlying physical sub-devices, and listens for topology changes.
3. **`HIDMonitor.swift`**: An `IOKit` wrapper that intercepts hardware media key events (Volume Up/Down/Mute) in the background globally.
4. **`VolumeExecutor.swift`**: The coordinator logic that receives the button press event from `HIDMonitor`, maps the triggering HID device to the correct physical `AudioDeviceID` via `AudioStateManager`, and directly modifies the volume scalar.
5. **`HardwareFingerprint.swift`**: A dedicated data model and utility to extract and match hardware signatures (Bluetooth MAC, USB VID/PID) between `IOHIDDevice` and `AudioDeviceID` properties.

---

## 3. Implementation Steps & API Details

### Step 1: Hardware Identity (The Bridge)
Create `HardwareFingerprint.swift`. Because `IOKit` and `CoreAudio` have completely different representations of devices, we need a common fingerprint.
* **Bluetooth**: Extract `kIOHIDSerialNumberKey` from IOKit, strip special characters, and match against CoreAudio's device UID.
* **USB**: Extract `kIOHIDVendorIDKey` and `kIOHIDProductIDKey`, format as Hex, and match against CoreAudio's UID properties.
* **Built-in/Aux**: Fallback identifiers like `"BuiltInHeadphone"`.

### Step 2: The Audio State Manager (`AudioStateManager.swift`)
Maintains a thread-safe cache of active physical audio devices.

**Initialization Logic:**
1. Fetch the Default Output Device via `kAudioHardwarePropertyDefaultOutputDevice` on the System Object (`AudioObjectID(1)`).
2. Check if it's an Aggregate Device. If so, fetch its sub-device UIDs using `kAudioAggregateDeviceSubDeviceListKey`.
3. Resolve UIDs to `AudioDeviceID` using `kAudioHardwarePropertyDeviceForUID`.

**Observer Logic:**
* Register an `AudioObjectAddPropertyListenerBlock` on the System Object for default output changes.
* Register an `AudioObjectAddPropertyListenerBlock` on the Aggregate Device for sub-device changes.
* Ensure all state mutations are thread-safe (e.g., using a serial DispatchQueue or Actors), as CoreAudio callbacks occur on background threads.

### Step 3: The HID Monitor (`HIDMonitor.swift`)
Listens for hardware button presses globally, bypassing standard UI-level event taps.

**Setup Logic:**
* Create an `IOHIDManager` using `IOHIDManagerCreate`.
* Set matching dictionaries for:
  * Keyboard Page (`0x07`): Volume Up/Down usages.
  * Consumer Page (`0x0C`): Consumer Volume Up/Down usages.
* Attach it to the main run loop via `IOHIDManagerScheduleWithRunLoop`.

**Callback Logic:**
* In the `IOHIDValueCallback`, identify the pressed key.
* Extract the transport layer via `kIOHIDTransportKey` on the originating `IOHIDDeviceRef`.
* Construct a `HardwareFingerprint` and emit the event (Direction, Fingerprint).

### Step 4: The Executor (`VolumeExecutor.swift`)
Executes the volume modification with minimal latency.

**Execution Logic:**
1. Upon receiving an event from `HIDMonitor`, verify with `AudioStateManager` that the fingerprint maps to an active physical sub-device of the current aggregate output.
2. If invalid or `nil`, let macOS handle the event natively.
3. If valid, read current volume via `AudioObjectGetPropertyData` for `kAudioDevicePropertyVolumeScalar`.
4. Calculate new volume (+/- small increment, clamp between 0.0 and 1.0).
5. Apply new volume via `AudioObjectSetPropertyData` for `kAudioDevicePropertyVolumeScalar`.
6. (Optional) Provide auditory or visual feedback simulating the native volume HUD.

---

## 4. Crucial Edge Cases & Rules
* **IOKit over CGEventTap**: You **must** use `IOKit` for hardware events. Bluetooth headsets often fail to register properly through `CGEventTap` when an aggregate device is active.
* **Memory & C-Interop**: Be extremely cautious with Swift C-interop. Use `AudioObjectGetPropertyDataSize` prior to allocating `UnsafeMutableRawPointer` buffers for fetching dictionaries or strings.
* **Sandbox & Entitlements**: The app must prompt the user to enable Accessibility in macOS System Settings. Global `IOKit` keyboard monitoring requires this entitlement, and the app must handle the denied state gracefully.
* **No String Matching**: Never match audio devices by their human-readable name strings. They are unreliable and can change. Match strictly by hardware fingerprint.