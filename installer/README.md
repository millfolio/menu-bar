# installer

Packages the menu-bar app in [`../menu`](../menu) into a macOS `.app` bundle, and
into a downloadable, signed, notarized `.pkg` installer.

## Download (recommended)

Grab `Millfolio.pkg` from the [latest release](https://github.com/millfolio/app/releases/latest)
(built by CI on every version tag) and open it. The installer puts **Millfolio**
in `/Applications` and, via its `preinstall` step, **quits any running copy
first** — so updating over a running app works instead of failing with "app is in
use." Signed + notarized, so it installs without a Gatekeeper warning.

## Build locally

```sh
./install.sh                 # build + install to /Applications/Millfolio.app
./install.sh ~/Applications  # custom location
./make_pkg.sh Millfolio.pkg   # build the installer .pkg (unsigned unless a cert is set)
```

To run at login: System Settings > General > Login Items > **+** > pick
`Millfolio.app`. To uninstall: `rm -rf /Applications/Millfolio.app`.

## Files

- `bundle.sh` — `swift build -c release` + assemble `Millfolio.app` (executable +
  [`Info.plist`](Info.plist), which sets `LSUIElement` for a Dock-less menu-bar
  agent) + codesign (Developer ID with `MILLFOLIO_SIGN_IDENTITY`, else ad-hoc).
- `install.sh` — bundle, then install into `/Applications` (or a given dir).
- `make_pkg.sh` — bundle into a payload root, `pkgbuild` (with the `scripts/`
  lifecycle scripts) + `productbuild` a product archive, then `productsign` it
  with the Developer ID Installer identity (`MILLFOLIO_INSTALLER_IDENTITY`).
  Headless, so it's what CI runs.
- `scripts/preinstall` — runs before the payload is written: quits a running
  Millfolio (and any engine server it launched) so the bundle can be replaced.
- `Info.plist` — the bundle's `Contents/Info.plist`. Drop an icon at
  `Millfolio.icns` here to ship one.

## CI

[`.github/workflows/release.yml`](../.github/workflows/release.yml) runs
`make_pkg.sh` on a `macos-14` runner: it builds `Millfolio.pkg` on every push
(uploaded as a workflow artifact) and, on a `v*` tag, publishes a GitHub Release
with the `.pkg` attached (its version is taken from the tag). Cut a release with:

```sh
git tag v0.3.1 && git push origin v0.3.1
```

## Signing & notarization

A `.pkg` is signed with a **Developer ID Installer** certificate
(`productsign`) — a *different* cert from the **Developer ID Application** one
that signs the `.app`. The Installer cert is **required**: the workflow fails
fast without it. All of these repo secrets (Settings -> Secrets and variables ->
Actions) are needed; they require a paid Apple Developer account:

| secret                          | what                                                                       |
|---------------------------------|----------------------------------------------------------------------------|
| `MACOS_CERT_P12`                | base64 of your **Developer ID Application** cert exported as `.p12`        |
| `MACOS_CERT_PASSWORD`           | the password set when exporting that `.p12`                                |
| `MACOS_INSTALLER_CERT_P12`      | base64 of your **Developer ID Installer** cert exported as `.p12`         |
| `MACOS_INSTALLER_CERT_PASSWORD` | the password set when exporting the Installer `.p12`                       |
| `APPLE_ID`                      | your Apple ID email                                                        |
| `APPLE_APP_PASSWORD`            | an **app-specific password** (appleid.apple.com -> Sign-In & Security)     |
| `APPLE_TEAM_ID`                 | your 10-character Team ID (Apple Developer -> Membership)                  |

Export each cert + base64 it (after creating the certs in Xcode or
developer.apple.com so they're in your login keychain):

```sh
# Keychain Access -> My Certificates -> right-click the cert -> Export -> .p12
# (set a password; that's the *_PASSWORD secret). Then base64-encode and copy:
base64 -i DeveloperID_Application.p12 | pbcopy   # -> MACOS_CERT_P12
base64 -i DeveloperID_Installer.p12   | pbcopy   # -> MACOS_INSTALLER_CERT_P12
```

`bundle.sh` reads `MILLFOLIO_SIGN_IDENTITY` to sign the app (hardened runtime +
timestamp); `make_pkg.sh` reads `MILLFOLIO_INSTALLER_IDENTITY` to `productsign`
the `.pkg`; the workflow then `notarytool submit --wait`s and `stapler staple`s it.
