# installer

Packages the menu-bar app in [`../menu`](../menu) into a macOS `.app` bundle and
installs it.

## Quick install

```sh
./install.sh                 # → /Applications/Millpond.app
./install.sh ~/Applications  # custom location
open /Applications/Millpond.app
```

`install.sh` runs `swift build -c release` on the menu app, assembles a `.app`
bundle (the executable + [`Info.plist`](Info.plist), which sets `LSUIElement` so
it's a menu-bar agent with no Dock icon), ad-hoc code-signs it so Gatekeeper
allows it locally, and copies it into place.

To run at login: System Settings → General → Login Items → **+** → pick
`Millpond.app`. To uninstall: `rm -rf /Applications/Millpond.app`.

## Files

- `install.sh` — build + bundle + install.
- `Info.plist` — the bundle's `Contents/Info.plist` (bundle id, version,
  `LSUIElement`). Drop an icon at `Millpond.icns` here to ship one.

## Roadmap (distributable installer)

The current script is for local builds. For a shippable installer:

- **`.dmg`** — `create-dmg Millpond.app` for a drag-to-Applications image.
- **`.pkg`** — `pkgbuild --component Millpond.app --install-location /Applications`
  (+ `productbuild`) for a guided installer.
- **Signing / notarization** — sign with a Developer ID certificate and
  `xcrun notarytool submit` so the app runs without Gatekeeper warnings on other
  machines.
