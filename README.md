# Complete Step-by-Step Guide: Compiling VoiceDebt into an Android APK on macOS

## ⚡ Mac Fast-Track: 1-Minute Automated Terminal Setup
If you downloaded `voicedebt_flutter_offline_app.zip` into your Mac's **Downloads** folder, open your Mac **Terminal** (press `Cmd + Space`, type `Terminal`, and hit Enter), then copy & paste this single command block:

```bash
# 1. Go to Downloads and extract the downloaded zip
cd ~/Downloads
unzip -o voicedebt_flutter_offline_app.zip -d voicedebt_extracted

# 2. Create the full Flutter Android project scaffolding
flutter create --org com.voicedebt voicedebt_app
cd voicedebt_app

# 3. Copy the VoiceDebt code and permissions into the project
cp ~/Downloads/voicedebt_extracted/pubspec.yaml ./pubspec.yaml
cp ~/Downloads/voicedebt_extracted/lib/main.dart ./lib/main.dart
cp ~/Downloads/voicedebt_extracted/android/app/src/main/AndroidManifest.xml ./android/app/src/main/AndroidManifest.xml

# 4. Fetch packages and build your release APK
flutter pub get
flutter build apk --release

# 5. Open the folder containing your finished APK in Finder
open build/app/outputs/flutter-apk/
```

---

## 🛠️ Prerequisites Checklist on Mac
Before running the build command, make sure Flutter and Android tools are installed:
1. **Check if Flutter is installed**:
   ```bash
   flutter --version
   ```
   - If not installed, run with Homebrew: `brew install --cask flutter`
   - Or download Flutter SDK directly from [flutter.dev](https://docs.flutter.dev/get-started/install/macos).
2. **Check Android environment**:
   ```bash
   flutter doctor
   ```
   - If prompted for Android licenses:
     ```bash
     flutter doctor --android-licenses
     ```
     *(Press `y` and Enter to accept all licenses).*
## ☁️ Free Cloud Build with GitHub Actions (Fixes v1 embedding error)
The reason you got **"Build failed due to use of deleted Android v1 embedding"** is that your repo contains the partial skeleton `android/app/src/main/AndroidManifest.xml` without the full Gradle project and `MainActivity.kt`. When Flutter ran, it detected the existing `android` directory, skipped creating the missing Kotlin files, and assumed it was legacy v1.

Here is the exact **`build_apk.yml`** that removes the partial directory, creates the clean modern v2 scaffold, and builds the release APK:

Place this file in your repository at:
```
.github/workflows/build_apk.yml
```

```yaml
name: Build Android APK
on: [push, workflow_dispatch]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Set up Java 17
        uses: actions/setup-java@v4
        with:
          distribution: 'zulu'
          java-version: '17'

      - name: Set up Flutter
        uses: subosito/flutter-action@v2
        with:
          channel: 'stable'
          cache: true

      - name: Recreate Clean Android Scaffold (Fix v1 embedding)
        run: |
          # Remove incomplete skeleton android directory
          rm -rf android
          # Generate clean modern v2 embedding Android project
          flutter create --org com.voicedebt --project-name voicedebt --platforms=android .

      - name: Inject Microphone Permissions & Speech Queries
        run: |
          python3 -c "
          with open('android/app/src/main/AndroidManifest.xml', 'r') as f:
              c = f.read()
          perms = '''    <uses-permission android:name="android.permission.RECORD_AUDIO" />
              <queries>
                  <intent>
                      <action android:name="android.speech.RecognitionService" />
                  </intent>
              </queries>
          '''
          c = c.replace('<application', perms + '    <application')
          with open('android/app/src/main/AndroidManifest.xml', 'w') as f:
              f.write(c)
          "

      - name: Install Dependencies
        run: flutter pub get

      - name: Build Release APK
        run: flutter build apk --release

      - name: Upload APK Artifact
        uses: actions/upload-artifact@v4
        with:
          name: voicedebt-app-release
          path: build/app/outputs/flutter-apk/app-release.apk
```

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

## 🎙️ Step 9: Offline Speech Recognition: Why Bangla Isn't in the List & How to Solve It

### The Issue: Why isn't Bangla (বাংলা) in Android's "Offline Speech Recognition" download list?
Google's system speech engine (**Google Speech Services** on Android) only packages offline downloadable neural models for a select tier of languages (e.g. English, Hindi, Spanish, French, German, Japanese, Chinese). **Google does NOT provide an offline downloadable model for Bengali (`bn_BD` / `bn_IN`)** on standard Android.

---

### Solution 1: Use Banglish with the English Offline Model (100% OFFLINE & 0ms Latency)
Every single Android phone in the world comes with the **English (US)** or **English (India)** offline speech recognition model pre-installed (or downloadable with 1 tap in Settings).

When VoiceDebt is set to **English / Banglish** mode:
1. Speak phonetically in **Banglish**:
   - *"Rahim ke 5000 taka dilam"*
   - *"Rahim 2000 ferot dilo"*
   - *"Zaman theke 2000 dhar nilam"*
   - *"Zaman ke 500 taka ferot dilam"*
   - *"Tanvir theke 1500 dhar nilam"*
2. The phone's English offline speech model transcribes these exact Latin phonetic words.
3. Our offline VoiceDebt parser automatically recognizes the Bengali grammar, auto-corrects misheard sounds (e.g., `delam` -> `dilam`, `pherot` -> `ferot`, `shod` -> `shodh`), detaches suffixes (`Rahimke` -> `Rahim`), and logs the debt with **zero internet connection**!

### Solution 2: Free Online Speech Recognition for Bengali Script (When Wi-Fi or Mobile Data is on)
When your phone has internet (Wi-Fi or Mobile Data) turned on:
- Switch the language toggle to **🇧🇩 বাংলা (bn_BD)**.
- Speak naturally in Bengali:
  - *"আমি রহিমকে ৫০০০ টাকা দিয়েছি"*
  - *"রহিম আমাকে ২০০০ টাকা ফেরত দিল"*
  - *"জামান থেকে ২০০০ ধার নিলাম"*
- Android transcribes this using Google's live server **100% free with NO paid API keys or subscription fees**!

### Solution 3: Gboard On-Device Voice Typing
If your phone runs Android 12+ (Google Pixel, Samsung Galaxy S/A series, Xiaomi):
1. Open **Settings** -> **System** -> **Keyboard** -> **Gboard**.
2. Tap **Voice typing** -> Enable **Faster voice typing** (On-device speech recognition).
3. Under **Languages**, add **বাংলা (বাংলাদেশ)**.
4. When inside any manual text entry field, tap the microphone button on the Gboard keyboard to dictate in Bengali script directly!

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
