# 🔄 Bridge — How to Update, Rebuild & Distribute

> Keep this file handy. Whenever you make code changes, fix bugs, or add features, follow these copy-paste steps to rebuild and deliver the new versions to your users.

---

## Table of Contents
1. [Do I Need to Send the Updated Files to Others?](#1-do-i-need-to-send-the-updated-files-to-others)
2. [Step 1: Bump the Versions (Required Before Rebuilding)](#step-1-bump-the-versions)
3. [Step 2: Rebuild Android (`bridge_app`)](#step-2-rebuild-android)
4. [Step 3: Rebuild Windows (`bridge-agent`)](#step-3-rebuild-windows)
5. [Step 4: Distribute & Share the Updates](#step-4-distribute--share-the-updates)
6. [Copy-Paste One-Liner Script (Rebuild Both at Once)](#copy-paste-one-liner-script)

---

## 1. Do I Need to Send the Updated Files to Others?

### **Yes!** 
Because **Bridge** connects phone and PC directly without a central cloud server, updates work as follows:

| Distribution Channel | Do you manually send files? | How users get the update |
| :--- | :--- | :--- |
| **Direct Sharing** *(Google Drive / WhatsApp)* | **Yes** | You share the new `.apk` and `.exe`. Users install right over the existing version — paired devices and settings are automatically preserved! |
| **GitHub Releases** *(Recommended)* | **Yes (once)** | You upload `.apk` and `.exe` to GitHub. Users download from `https://github.com/sairiteshdomakuntla/android-continuity/releases/latest`. |
| **Google Play Store** *(Phase 2)* | **No** | You upload the new `.aab` to Play Console. Google Play **automatically auto-updates** users' phones in the background! |

> [!TIP]
> **Apps update cleanly in place**: Users do **NOT** need to uninstall the old version first. Installing the new `.apk` or running the new `Setup.exe` upgrades the app in place.

---

## Step 1: Bump the Versions

Before compiling a new build, increment the version numbers:

### 📱 Android — `bridge_app/pubspec.yaml`
Find line 19 and increment:
```yaml
# Change from:
version: 1.0.0+1

# Change to (for your next release):
version: 1.0.1+2
```
* **`1.0.1`** = Version name displayed to users.
* **`+2`** = Build number (`versionCode`). **Must increase by +1 every release** (strictly enforced by Android and Play Store).

### 💻 Windows — `bridge-agent/package.json`
Find line 4 and increment:
```json
// Change from:
"version": "1.0.0",

// Change to:
"version": "1.0.1",
```

---

## Step 2: Rebuild Android

Open PowerShell and run:

```powershell
# 1. Go to mobile app folder
cd d:\proj\android-continuity\bridge_app

# 2. Build signed release APK
flutter build apk --release
```

✅ **Your updated file is ready at:**
```
bridge_app\build\app\outputs\flutter-apk\app-release.apk
```

*(Optional: For Google Play Store submission)*:
```powershell
flutter build appbundle --release
# Output: bridge_app\build\app\outputs\bundle\release\app-release.aab
```

---

## Step 3: Rebuild Windows

Open PowerShell and run:

```powershell
# 1. Go to desktop agent folder
cd d:\proj\android-continuity\bridge-agent

# 2. Build desktop installer
npm run build
```

✅ **Your updated installer is ready at:**
```
bridge-agent\release\1.0.1\Bridge-Windows-1.0.1-Setup.exe
```

*(The subfolder name matches whatever version number you entered in `package.json`).*

---

## Step 4: Distribute & Share the Updates

### Method A: GitHub Releases (Best & Easiest) ⭐

1. Go to: [github.com/sairiteshdomakuntla/android-continuity/releases](https://github.com/sairiteshdomakuntla/android-continuity/releases)
2. Click **"Draft a new release"** (or "Create a new release").
3. Click **"Choose a tag"** ➔ type your version tag (e.g. `v1.0.1`) ➔ click **"Create new tag"**.
4. Release title: `Bridge v1.0.1`
5. In the description box, write release notes (what you changed/fixed).
6. Drag and drop both files into the upload box:
   * `app-release.apk` (you can rename it to `Bridge-Android-v1.0.1.apk`)
   * `Bridge-Windows-1.0.1-Setup.exe`
7. Click **"Publish release"**.

Users can always download the latest version directly from:
👉 `https://github.com/sairiteshdomakuntla/android-continuity/releases/latest`

---

### Method B: Google Drive / OneDrive (Direct Share)

1. Upload the files to a folder in Google Drive:
   * `Bridge-v1.0.1.apk`
   * `Bridge-Windows-1.0.1-Setup.exe`
2. Set link sharing to: *"Anyone with the link can view/download"*.
3. Send the link to your users.

---

## Copy-Paste One-Liner Script

Want to build **both** Android and Windows with one single command?

Paste this into PowerShell:

```powershell
Write-Host "🔨 1/2 Building Android Release APK..." -ForegroundColor Cyan
cd d:\proj\android-continuity\bridge_app
flutter build apk --release

if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ Android APK built successfully!" -ForegroundColor Green
    Write-Host "🔨 2/2 Building Windows Installer..." -ForegroundColor Cyan
    cd d:\proj\android-continuity\bridge-agent
    npm run build
    if ($LASTEXITCODE -eq 0) {
        Write-Host "🎉 BOTH APPS BUILT SUCCESSFULLY!" -ForegroundColor Green
        Write-Host "📱 Android APK: d:\proj\android-continuity\bridge_app\build\app\outputs\flutter-apk\app-release.apk" -ForegroundColor Yellow
        Write-Host "💻 Windows EXE: d:\proj\android-continuity\bridge-agent\release\" -ForegroundColor Yellow
    } else {
        Write-Host "❌ Windows build failed!" -ForegroundColor Red
    }
} else {
    Write-Host "❌ Android build failed!" -ForegroundColor Red
}
```
