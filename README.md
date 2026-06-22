# SolderFan ESP32

SolderFan is a two-channel ESP32 controller for a solder fume extractor using
two 4-pin PC fans. The firmware drives both fans with 25 kHz PWM, reads their
tachometer signals, supports an automatic mode through two potentiometers, and
can be controlled over BLE from a Flutter app.

The repository also includes STL models for mechanically connecting 120 mm
fans to DN100 hoses.

## Project Layout

```text
.
|-- app/       Flutter app for BLE control
|-- docs/      Pinout and fan reference images
|-- esp32/     PlatformIO project for the ESP32 firmware
`-- stl/       3D models for 120 mm fans and DN100 hoses
```

## Hardware

The firmware is designed for an ESP32 DevKit and two 4-pin PC fans. The fan PWM
outputs are driven through BC547 open-collector stages. Because of that, the PWM
signal is inverted in firmware.

| Function | ESP32 GPIO | Notes |
| --- | ---: | --- |
| Fan 1 tachometer | GPIO19 | Input with internal pull-up |
| Fan 2 tachometer | GPIO18 | Input with internal pull-up |
| Fan 1 PWM | GPIO23 | Through BC547 open-collector stage |
| Fan 2 PWM | GPIO22 | Through BC547 open-collector stage |
| Fan 1 potentiometer | GPIO32 | ADC1_CH4 |
| Fan 2 potentiometer | GPIO33 | ADC1_CH5 |
| 3V3 | - | Potentiometers and tachometer pull-ups |
| GND | - | Common ground for ESP32, fan supply, and signals |

Important: 4-pin PC fans usually require a 12 V supply. The ESP32 3V3 rail is
only intended for signal levels, potentiometers, and pull-ups. The fan supply
ground must be connected to ESP32 GND. The firmware enables the ESP32 internal
pull-ups for the tachometer inputs; if high-RPM readings are still unstable, use
stronger external pull-ups such as 4.7 kOhm to 10 kOhm to 3V3.

## Firmware

The firmware lives in `esp32/` and is built with PlatformIO.

```bash
cd esp32
pio run
```

Upload:

```bash
cd esp32
pio run -t upload
```

On macOS, you can also use the included script. It uses the first detected port
matching `/dev/cu.usbserial-*`.

```bash
cd esp32
./upload.sh
```

Serial monitor:

```bash
cd esp32
pio device monitor -b 115200
```

### Firmware Behavior

- PWM frequency: 25 kHz
- PWM resolution: 8 bit
- Minimum automatic-mode duty: 20 %
- Tachometer calculation: ESP32 PCNT hardware counter, 2 pulses per revolution
- Automatic mode: Fan 1 follows the potentiometer on GPIO32; Fan 2 follows the
  potentiometer on GPIO33
- Startup behavior: both fans briefly run at 100 %, then fall back to 40 %
- Status output: once per second over Serial and BLE Notify

## BLE Protocol

The ESP32 advertises as:

```text
SolderFan
```

Service UUID:

```text
6e400001-b5a3-f393-e0a9-e50e24dcca9e
```

Write characteristic for commands:

```text
6e400002-b5a3-f393-e0a9-e50e24dcca9e
```

Read/Notify characteristic for status:

```text
6e400003-b5a3-f393-e0a9-e50e24dcca9e
```

Supported text commands:

| Command | Effect |
| --- | --- |
| `AUTO` | Enable automatic mode; the potentiometers control the fans |
| `STATUS` | Send the current status through Notify |
| `BOTH 80` | Manual mode, set both fans to 80 % |
| `MAN 1 70` | Manual mode, set Fan 1 to 70 % |
| `MAN 2 55` | Manual mode, set Fan 2 to 55 % |

Status format:

```text
fan1_duty=40,fan1_rpm=1230,fan2_duty=42,fan2_rpm=1260,mode=auto
```

For quick BLE testing, use a tool such as nRF Connect: scan for the `SolderFan`
device, connect to the service, and write commands as text to the write
characteristic.

## Flutter App

The app lives in `app/` and uses `flutter_blue_plus` and `permission_handler`.

```bash
cd app
flutter pub get
flutter run
```

The app scans for the SolderFan BLE service, connects to the ESP32, subscribes
to status notifications, and provides:

- Automatic-mode switch
- Manual sliders for Fan 1 and Fan 2
- Buttons to set both fans to 100 % or to their shared average
- Status display and a small connection/command log

### Android

The required BLE permissions are documented in
`app/android/AndroidManifest-permissions-snippet.xml`. Add them to
`app/android/app/src/main/AndroidManifest.xml` directly below the `<manifest>`
element.

### iOS

The required Bluetooth usage strings are documented in
`app/ios/Info.plist-snippet.xml`. Add them to `ios/Runner/Info.plist` inside the
main `<dict>`. BLE is only practical on real iOS hardware, not in the simulator.

### macOS

For macOS, Bluetooth permissions must be enabled in the Runner entitlements. The
file `app/macos/Runner/DebugProfile.entitlements` is the relevant starting point
in this project.

## STL Models

The `stl/` folder contains two 3d-models for using 120 mm fans with DN100
hoses:

```text
stl/120Fan2DN100.stl
stl/120Fan2DN100-B.stl
```

The models are intended as adapter or spacer parts for combining a 120 mm fan
with DN100 ducting. 

Practical printing notes:

- Check the model dimensions in the slicer before printing.
- Compare the fan mounting hole pattern and DN100 connection against the real
  parts.
- For ABS, ASA, or PETG, use enough wall thickness and consider the temperature
  of the operating environment.

## Development Notes

- Generated PlatformIO and Flutter artifacts are ignored through the root
  `.gitignore`.
- The root README is the central project documentation; there is intentionally
  no separate README in the app folder.
- Firmware and app share the BLE protocol. If UUIDs or commands change,
  `esp32/src/main.cpp` and `app/lib/main.dart` must be updated together.
