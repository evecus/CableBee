# CableBee 🐝

**Android ADB Assistant** — Control Android devices from your phone.

> Connect to any Android device via Wi-Fi or USB OTG, then run shell commands,
> manage apps, browse files, view logcat, and more — all from a single app.

---

## Screenshots

| Home | Shell | Apps | Files | Tools |
|------|-------|------|-------|-------|
| Device list, quick actions | Interactive shell terminal | Install/uninstall/manage APKs | Push/pull, directory browser | Screenshot, display tweaks, reboot |

---

## Features

### Connection
| Mode | How |
|------|-----|
| **Wi-Fi TCP** | `adb connect <ip>:5555` — device must have Wireless Debugging on |
| **Wi-Fi Pairing** | Android 11+ one-time pairing code |
| **USB** | Via USB OTG adapter — auto-detected |

### Core Tools
- **Shell** — interactive terminal with history, quick-command chips
- **Apps** — list user/system apps, install APK, uninstall, force-stop, clear data
- **Files** — browse device filesystem, push files to device, pull files to phone
- **Logcat** — real-time log stream with level filter (V/D/I/W/E) and text search
- **Tools** — device info panel, screenshot, animation scale, screen resolution, reboot modes
- **Fastboot** — flash/erase partitions, bootloader unlock/lock, device variables

---

## How it works

CableBee downloads the [AndroidIDEOfficial/platform-tools](https://github.com/AndroidIDEOfficial/platform-tools)
static `adb` and `fastboot` binaries (ARM64 / armeabi-v7a) at first launch,
stores them in the app's private directory, and executes them as a child process.

No root required for Wi-Fi mode. USB mode requires USB OTG hardware support.

---

## Build

### Prerequisites
- Flutter 3.22+
- Java 17
- Android SDK (API 34)

### Local build
```bash
flutter pub get
flutter build apk --release --split-per-abi
```

### GitHub Actions
Push a tag `v*` to trigger a release build:
```bash
git tag v1.0.0
git push origin v1.0.0
```

Secrets required for signed release APK:
| Secret | Description |
|--------|-------------|
| `KEYSTORE_BASE64` | Base64-encoded `.jks` keystore |
| `KEY_ALIAS` | Key alias |
| `KEY_PASSWORD` | Key password |
| `STORE_PASSWORD` | Keystore password |

Unsigned APKs are built automatically on every push (no secrets needed).

---

## Generating a keystore

```bash
keytool -genkey -v \
  -keystore cablebee.jks \
  -keyalg RSA -keysize 2048 \
  -validity 10000 \
  -alias cablebee

# Encode for GitHub Secret:
base64 -i cablebee.jks | pbcopy   # macOS
base64 cablebee.jks               # Linux
```

---

## Architecture

```
lib/
├── main.dart                   # Entry point, providers, splash gate
├── utils/
│   └── theme.dart              # Design system: colors, typography
├── models/
│   └── device.dart             # AdbDevice model
├── services/
│   ├── binary_manager.dart     # Download + manage adb/fastboot binaries
│   ├── adb_service.dart        # All ADB operations
│   ├── fastboot_service.dart   # Fastboot operations
│   └── usb_service.dart        # Android USB Host API bridge
├── widgets/
│   ├── common.dart             # Shared UI: cards, dialogs, terminal box
│   └── device_card.dart        # Device card, header bar, pulse dot
└── screens/
    ├── home_screen.dart        # Main nav + home tab
    ├── connect_screen.dart     # TCP / pairing / USB guide
    ├── shell_screen.dart       # Interactive ADB shell
    ├── apps_screen.dart        # App manager
    ├── files_screen.dart       # File browser + push/pull
    ├── tools_screen.dart       # Device info, screenshot, tweaks
    ├── logcat_screen.dart      # Real-time logcat viewer
    ├── fastboot_screen.dart    # Fastboot flash/erase/unlock
    └── settings_screen.dart   # Settings + about
```

---

## Requirements

- Android 8.0+ (API 26) on **this** phone (the controller)
- Target device: USB Debugging or Wireless Debugging enabled
- USB OTG support for USB mode

---

## Credits

- [AndroidIDEOfficial/platform-tools](https://github.com/AndroidIDEOfficial/platform-tools) — static adb/fastboot binaries for Android
