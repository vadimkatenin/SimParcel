# SimParcel

<img src="Artwork/AppIcon-Source.png" alt="SimParcel app icon" width="128">

**[katenin.dev/simparcel](https://katenin.dev/simparcel)** · [Download](https://github.com/vadimkatenin/SimParcel/releases/latest/download/SimParcel.dmg) · `brew install --cask vadimkatenin/tap/simparcel`

**Drag and drop for the iOS Simulator.** Send photos, videos, Live Photos, contacts, `.app` builds, `.apns` push notifications, deep links and any other file to one simulator or to all running simulators at once.

Xcode 27 replaced Simulator.app with Device Hub, which no longer accepts files dropped from Finder. SimParcel is a small native macOS app that brings that workflow back: pick a simulator, drop your files, click **Send to Simulator**. No terminal, no `xcrun simctl addmedia` by hand.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Artwork/Screenshot-Dark.png">
  <img src="Artwork/Screenshot.png" alt="SimParcel window with a queue of an app, a Live Photo, a contact, photos, a video, a PDF, a push payload and a link" width="720">
</picture>

## Features

Drop files or whole folders onto the window, or choose them with **File → Choose Files…** (⌘O):

| You drop | The simulator gets |
| --- | --- |
| Photos and videos | New items in Photos |
| A still image and a video with the same name | One Live Photo |
| `.vcf` contact cards | New contacts |
| `.app` simulator builds | The app, installed |
| `.apns` push payloads | A push notification |
| Web links and deep links | The link, opened (drag it from a browser or use **File → Add Link…**, ⌘L) |
| Any other file (PDF, JSON, ZIP, …) | A copy in **Files → On My iPhone** |

- Send to one simulator, or choose **All Running Simulators** to send everything to each running simulator at once.
- Simulators are grouped by iOS version, and running ones are listed first.
- A simulator that isn't running starts automatically and opens in Simulator.
- Items that are sent leave the queue. Items that fail stay there, show the error, and can be retried.

### Push payloads

A payload needs an `aps` dictionary and a `Simulator Target Bundle` key with your app's bundle ID. The app must be allowed to show notifications in the simulator.

```json
{
  "Simulator Target Bundle": "com.example.MyApp",
  "aps": {
    "alert": { "title": "Hello", "body": "Sent from SimParcel" }
  }
}
```

## Requirements

- macOS 14 or later
- Xcode with at least one iOS Simulator runtime installed
- **Xcode → Settings → Locations → Command Line Tools** set to the Xcode you want to use

## Installation

### Homebrew

```bash
brew install --cask vadimkatenin/tap/simparcel
```

### Download

Download [SimParcel.dmg](https://github.com/vadimkatenin/SimParcel/releases/latest/download/SimParcel.dmg) (or pick a version on [Releases](https://github.com/vadimkatenin/SimParcel/releases)), open it and drag SimParcel to Applications. The app is signed with Developer ID and notarized by Apple.

### Updates

SimParcel checks for updates once a day with [Sparkle](https://sparkle-project.org) and installs them when you agree. You can also choose **SimParcel → Check for Updates…**. Updates are signed, and the app installs only updates signed with the project's key.

### Build from source

```bash
git clone https://github.com/vadimkatenin/SimParcel.git
cd SimParcel
open SimParcel.xcodeproj
```

Run the **SimParcel** scheme on **My Mac**. Xcode fetches [Sparkle](https://github.com/sparkle-project/Sparkle), the only dependency, with Swift Package Manager.

To build and test from the command line:

```bash
xcodebuild -project SimParcel.xcodeproj -scheme SimParcel -destination 'platform=macOS' test
```

## How it works

The app runs Apple's command line tools:

- `xcrun simctl list devices available --json` lists the simulators.
- `xcrun simctl bootstatus <udid> -b` boots a simulator that isn't running.
- `xcrun simctl addmedia <udid> <files…>` imports photos, videos and contacts. SimParcel first copies the files to a temporary folder so Simulator can read them even when the originals are in protected folders such as Downloads. The files of a Live Photo keep their names and go in a single call, which is how `simctl` pairs them. The temporary copies are removed when the command finishes; the originals stay in place.
- `xcrun simctl install`, `push` and `openurl` handle apps, push payloads and links. Apps are installed first, so pushes and links in the same batch can reach them.
- Other files are copied into the Files app's local storage (the `group.com.apple.FileProvider.LocalStorage` app group, found with `xcrun simctl get_app_container` or, on runtimes where that fails, by its container metadata). Each file is written under a temporary name and then renamed, so Files never shows a partial copy. A name that's taken gets a number: `report 2.pdf`.

Because the app runs `xcrun`, it can't use the App Sandbox and isn't distributed through the Mac App Store.

## Troubleshooting

- **No simulators listed:** check that an iOS runtime is installed (**Xcode → Settings → Components**) and that Command Line Tools point to that Xcode. Then click Refresh (⌘R).
- **Something else?** Open an [issue](https://github.com/vadimkatenin/SimParcel/issues) or write to [support@katenin.dev](mailto:support@katenin.dev).
- **Imports go to Photos, not your app:** `addmedia` writes to the simulator's Photos library. Use your app's photo picker to reach the files.
- **A push fails with "isn't allowed to show notifications":** open the app in the simulator and allow notifications first.
- **"The Files app isn't available":** some simulator runtimes don't include Files. Try a simulator with another iOS version.
- **An app fails to install:** only builds for the iOS Simulator work (`Debug-iphonesimulator`), not device builds or `.ipa` files.

## Releasing

Write the release notes to `release-notes/<version>.md`, then run:

```bash
scripts/release.sh 1.1.0
```

The script sets the version, builds a universal app, signs it with Developer ID, notarizes and staples the app and the DMG, and writes a Sparkle appcast. After you confirm, it tags the release, publishes it on GitHub with the zip, DMG and appcast, and updates the Homebrew cask. The one-time setup it needs is listed at the top of the script.

## License

[MIT](LICENSE)
