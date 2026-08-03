# DarkTunnel

GitHub-ready starter for the DarkTunnel iOS app.

## What is included

- SwiftUI interface prototype
- Dark MapKit background
- OFF state focused on Moscow
- Connected state camera animation to the selected server
- Glass connection and control cards
- Server selector
- Announcement banner
- Settings sheet
- Speed mode selector: 3 or 10 connections
- Wi-Fi / cellular transport status
- Sleep and APNs toggles
- GitHub Actions simulator build
- GitHub Actions signed IPA build

## Generate the Xcode project locally

```bash
brew install xcodegen
xcodegen generate
open DarkTunnel.xcodeproj
```

## GitHub Actions

`build-ui.yml` checks that the UI target compiles for the iOS Simulator.

`build-ipa.yml` creates a signed IPA after Apple signing secrets are configured.

Required repository secrets:

- `P12_BASE64`
- `P12_PASSWORD`
- `MOBILEPROVISION_BASE64`
- `KEYCHAIN_PASSWORD`

The workflow extracts the Team ID and bundle identifier from the provisioning profile automatically.

## Current limitation

This is the first UI foundation. The real Network Extension, WDTT/AWG engines, backend activation, Live Activities and Telegram admin system are not implemented yet.
