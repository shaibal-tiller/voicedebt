# Complete Step-by-Step Guide: Compiling VoiceDebt into an Android APK

Follow this foolproof, step-by-step guide to compile the VoiceDebt app into a production-ready, standalone, 100% offline APK for your Android phone.

---

## 🛠️ Step 1: Prerequisites
Ensure you have the following installed on your computer:
1. **Flutter SDK** (Version 3.2.0 or higher):
   - Check via: `flutter doctor`
   - Download from [flutter.dev](https://docs.flutter.dev/get-started/install)
2. **Android Studio** (or Android Command Line Tools):
   - Android SDK Tools, Android SDK Platform-Tools, and Android SDK Build-Tools (API 34 recommended)
   - Java Development Kit (JDK 17 recommended)
3. An Android phone with **USB Debugging** enabled or an Android Emulator.

---

## 📁 Step 2: Create a New Flutter Project
Open your terminal / command prompt and run:

```bash
# 1. Create a fresh Flutter project
flutter create --org com.voicedebt voicedebt

# 2. Navigate into the project folder
cd voicedebt
```

---

## 📦 Step 3: Configure Dependencies (`pubspec.yaml`)
Replace the contents of `pubspec.yaml` with the provided configuration:

```yaml
name: voicedebt
description: "100% free, offline, voice-first debt and borrowing tracker built with Flutter and SQLite."
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: '>=3.2.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter
  speech_to_text: ^7.0.0      # Native Android offline voice recognition
  sqflite: ^2.4.1             # Local SQLite database
  path: ^1.9.0                # File paths for SQLite
  provider: ^6.1.2            # State management
  quick_actions: ^1.0.7       # Android App Shortcuts & hardware gestures
  intl: ^0.19.0               # Currency & date formatting
  cupertino_icons: ^1.0.8

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^5.0.0

flutter:
  uses-material-design: true
```

Now download the packages:
```bash
flutter pub get
```

---

## 🛡️ Step 4: Configure Android Permissions (`AndroidManifest.xml`)
Open `android/app/src/main/AndroidManifest.xml` and make sure:
1. **RECORD_AUDIO permission** is present above `<application>`.
2. **<queries>** block is included for Android 11+ (API 30+) speech recognition service visibility.

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- Required for speech_to_text offline voice recording -->
    <uses-permission android:name="android.permission.RECORD_AUDIO" />
    <uses-permission android:name="android.permission.BLUETOOTH" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />

    <!-- Queries section required on Android 11+ (API 30+) for SpeechRecognitionService -->
    <queries>
        <intent>
            <action android:name="android.speech.RecognitionService" />
        </intent>
    </queries>

    <application
        android:label="VoiceDebt"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher">
        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTop"
            ...
```

*(Note: Verify in `android/app/build.gradle` that `minSdkVersion` is at least 21 or higher, preferably 23).*

---

## 💻 Step 5: Replace `lib/main.dart`
Replace everything inside `lib/main.dart` with the complete `main.dart` code provided in the application.

---

## 🚀 Step 6: Test Running on Device or Emulator
Connect your Android phone via USB (with USB Debugging turned ON):

```bash
flutter devices
flutter run
```

Test saying:
- *"I lent Rahim 5000"*
- *"I borrowed 2000 from Zaman"*
- *"Rahim returned 2000"*
- *"I paid Zaman 500"*

---

## ⚡ Step 7: Compile Standalone Release APK
When ready to install permanently or share the APK:

### Option A: Standard Universal Release APK (Works on any Android phone)
```bash
flutter build apk --release
```
The generated APK will be located at:
```
build/app/outputs/flutter-apk/app-release.apk
```

### Option B: Split ABI APKs (Smaller file size, e.g. ~15MB each)
```bash
flutter build apk --split-per-abi --release
```
This produces optimized APKs:
- `app-arm64-v8a-release.apk` (For modern 64-bit phones)
- `app-armeabi-v7a-release.apk` (For older 32-bit phones)

---

## 📲 Step 8: Installing the APK on your Phone
1. **Via USB (ADB)**:
   ```bash
   adb install -r build/app/outputs/flutter-apk/app-release.apk
   ```
2. **Via File Transfer**:
   - Copy `app-release.apk` to your Google Drive, WhatsApp, Telegram, or via USB cable to your phone's *Downloads* folder.
   - Open Files app on your Android phone, tap `app-release.apk`, and tap **Install**.
   - If prompted, allow "Install from Unknown Sources" for your file manager.

---

## 🎙️ Step 9: Enable 100% OFFLINE Speech Recognition on Android
To ensure speech recognition works in the middle of nowhere without internet:
1. Open your Android phone's **Settings**.
2. Go to **Google** -> **Settings for Google Apps** -> **Voice** (or **Search, Assistant & Voice**).
3. Tap **Offline speech recognition**.
4. In the **All** tab, download your language (e.g. *English (US)* or *English (India)* or *Bengali*).
5. Voice recognition will now work with 0ms latency and zero data usage!

---

## ⚡ Step 10: Map Hardware Gestures (Double-Tap Power Button)
You can launch VoiceDebt directly into listening mode with one of the following:

- **Samsung Galaxy**:
  1. Go to **Settings** -> **Advanced features** -> **Side key**.
  2. Under *Double press*, select **Open app**.
  3. Select **VoiceDebt**.
- **Google Pixel / Motorola / Stock Android**:
  1. Go to **Settings** -> **System** -> **Gestures** -> **Quick Tap to start actions**.
  2. Select **Open app** -> Tap the gear next to **VoiceDebt** and select the Quick Action shortcut.
- **Home Screen App Shortcut**:
  - Long press the VoiceDebt app icon on your home screen.
  - You will see the **Quick Voice Log** popup shortcut.
  - Drag it directly onto your home screen for instant 1-tap recording!
# voicedebt
