# DarkTunnel

DarkTunnel is an iOS VPN client under active development.

## Version 0.2 scaffold

This revision adds:

- a real Network Extension target;
- a `PacketTunnelProvider` target;
- `NETunnelProviderManager` configuration;
- the fixed test server `31.77.148.80`;
- local 30-day test activation;
- Wi-Fi/cellular path monitoring;
- bundle identifiers matching the supplied provisioning profile;
- a signed IPA workflow prepared to test one provisioning profile.

## Important limitation

The repository now contains the native iOS VPN structure, but it does **not** yet contain the WDTT or AmneziaWG packet engines. The Packet Tunnel target is currently a safe scaffold and does not route user traffic. A successful IPA proves project generation, signing, installation, entitlement acceptance and Network Extension startup only.

## Signing identifiers

Main application:

```text
app.lavender3512.currant6944
```

Packet Tunnel extension:

```text
app.lavender3512.currant6944.PacketTunnel
```

Apple normally requires a provisioning profile matching each bundle identifier. The experimental workflow below can attempt to use one supplied profile for both targets; installation or extension signing may fail if the profile contains only the explicit main-app identifier.

## Generate locally

```bash
brew install xcodegen
xcodegen generate
open DarkTunnel.xcodeproj
```

## IPA secrets

- `P12_BASE64`
- `P12_PASSWORD`
- `MOBILEPROVISION_BASE64`
- `KEYCHAIN_PASSWORD`

Never commit certificates or passwords to the repository.
