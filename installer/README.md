# installer

Packages the menu-bar app in [`../menu`](../menu) into a macOS `.app` bundle, and
into a downloadable `.dmg`.

## Download (recommended)

Grab `Millpond.dmg` from the [latest release](https://github.com/millrace/millpond/releases/latest)
(built by CI on every version tag), open it, drag **Millpond** onto
**Applications**, and launch it.

> **Gatekeeper:** these builds are *ad-hoc signed, not Apple-notarized* (that
> needs a paid Developer ID). On first launch macOS will say it "cannot verify
> the developer." Either **right-click the app → Open** once, or run
> `xattr -dr com.apple.quarantine /Applications/Millpond.app`. After that it
> launches normally.

## Build locally

```sh
./install.sh                 # build + install to /Applications/Millpond.app
./install.sh ~/Applications  # custom location
./make_dmg.sh Millpond.dmg   # build a drag-to-Applications .dmg
```

To run at login: System Settings > General > Login Items > **+** > pick
`Millpond.app`. To uninstall: `rm -rf /Applications/Millpond.app`.

## Files

- `bundle.sh` — `swift build -c release` + assemble `Millpond.app` (executable +
  [`Info.plist`](Info.plist), which sets `LSUIElement` for a Dock-less menu-bar
  agent) + ad-hoc codesign. Shared by the two scripts below.
- `install.sh` — bundle, then install into `/Applications` (or a given dir).
- `make_dmg.sh` — bundle into a staging folder with an `Applications` alias and
  `hdiutil create` a compressed `.dmg`. Headless (no Finder), so it's what CI runs.
- `Info.plist` — the bundle's `Contents/Info.plist`. Drop an icon at
  `Millpond.icns` here to ship one.

## CI

[`.github/workflows/release.yml`](../.github/workflows/release.yml) runs
`make_dmg.sh` on a `macos-14` runner: it builds `Millpond.dmg` on every push
(uploaded as a workflow artifact) and, on a `v*` tag, publishes a GitHub Release
with the `.dmg` attached. Cut a release with:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

## Making it "just works" (notarization)

To drop the Gatekeeper warning for downloaders, sign with a **Developer ID
Application** certificate and notarize. With the cert + an app-specific password
in repo secrets, extend `make_dmg.sh` / the workflow to:

```sh
codesign --force --options runtime --sign "Developer ID Application: …" Millpond.app
xcrun notarytool submit Millpond.dmg --apple-id … --team-id … --password … --wait
xcrun stapler staple Millpond.dmg
```
