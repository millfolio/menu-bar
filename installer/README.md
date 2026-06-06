# installer

Packages the menu-bar app in [`../menu`](../menu) into a macOS `.app` bundle, and
into a downloadable `.dmg`.

## Download (recommended)

Grab `Millrace.dmg` from the [latest release](https://github.com/millrace/app/releases/latest)
(built by CI on every version tag), open it, drag **Millrace** onto
**Applications**, and launch it.

> **Gatekeeper:** these builds are *ad-hoc signed, not Apple-notarized* (that
> needs a paid Developer ID). On first launch macOS will say it "cannot verify
> the developer." Either **right-click the app → Open** once, or run
> `xattr -dr com.apple.quarantine /Applications/Millrace.app`. After that it
> launches normally.

## Build locally

```sh
./install.sh                 # build + install to /Applications/Millrace.app
./install.sh ~/Applications  # custom location
./make_dmg.sh Millrace.dmg   # build a drag-to-Applications .dmg
```

To run at login: System Settings > General > Login Items > **+** > pick
`Millrace.app`. To uninstall: `rm -rf /Applications/Millrace.app`.

## Files

- `bundle.sh` — `swift build -c release` + assemble `Millrace.app` (executable +
  [`Info.plist`](Info.plist), which sets `LSUIElement` for a Dock-less menu-bar
  agent) + ad-hoc codesign. Shared by the two scripts below.
- `install.sh` — bundle, then install into `/Applications` (or a given dir).
- `make_dmg.sh` — bundle into a staging folder with an `Applications` alias and
  `hdiutil create` a compressed `.dmg`. Headless (no Finder), so it's what CI runs.
- `Info.plist` — the bundle's `Contents/Info.plist`. Drop an icon at
  `Millrace.icns` here to ship one.

## CI

[`.github/workflows/release.yml`](../.github/workflows/release.yml) runs
`make_dmg.sh` on a `macos-14` runner: it builds `Millrace.dmg` on every push
(uploaded as a workflow artifact) and, on a `v*` tag, publishes a GitHub Release
with the `.dmg` attached. Cut a release with:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

## Signing & notarization (make it "just open")

The workflow signs with **Developer ID** + **notarizes** automatically *when these
repo secrets are present* (Settings -> Secrets and variables -> Actions). With
none set, it falls back to an ad-hoc build (the Gatekeeper note above). All five
are required to enable it; needs a paid Apple Developer account:

| secret                | what                                                                 |
|-----------------------|----------------------------------------------------------------------|
| `MACOS_CERT_P12`      | base64 of your **Developer ID Application** cert exported as `.p12`  |
| `MACOS_CERT_PASSWORD` | the password you set when exporting the `.p12`                       |
| `APPLE_ID`            | your Apple ID email                                                  |
| `APPLE_APP_PASSWORD`  | an **app-specific password** (appleid.apple.com -> Sign-In & Security) |
| `APPLE_TEAM_ID`       | your 10-character Team ID (Apple Developer -> Membership)            |

Export the cert + base64 it (after creating a "Developer ID Application" cert in
Xcode or developer.apple.com and it's in your login keychain):

```sh
# Keychain Access -> My Certificates -> right-click the "Developer ID Application"
# cert -> Export -> .p12 (set a password; that password is MACOS_CERT_PASSWORD).
# Then base64-encode the .p12 and copy it — paste as the MACOS_CERT_P12 value:
base64 -i DeveloperID.p12 | pbcopy
```

`bundle.sh` reads `MILLRACE_SIGN_IDENTITY` (set by the workflow from the imported
cert) to sign with the hardened runtime + timestamp; the workflow then signs,
`notarytool submit --wait`s, and `stapler staple`s the `.dmg`.
