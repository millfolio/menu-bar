# Sparkle auto-update

The Millfolio menu-bar app auto-updates with [Sparkle](https://sparkle-project.org)
2.x. First install stays the Developer-ID-signed, notarized **`.pkg`**; in-place
updates come through Sparkle as a **zipped, EdDSA-signed `Millfolio.app`** referenced
by an **appcast**.

## How it fits together

| Piece | Where |
|-------|-------|
| Sparkle package | `menu/Package.swift` → `github.com/sparkle-project/Sparkle` (2.9.4), linked into the `Millfolio` product only |
| Updater controller | `menu/Sources/Millfolio/Updater.swift` — `SPUStandardUpdaterController`, started automatically |
| "Check for Updates…" | the `MenuBarExtra` menu (`MillfolioApp.swift`) **and** the native App menu (`AppDelegate.swift` → `MenuBuilder`) |
| Feed / key / interval | `installer/Info.plist` (`SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`) |
| Framework embedding + version stamp | `installer/bundle.sh` |
| Update artifact + appcast | `.github/workflows/release.yml` |
| Hosted appcast | `https://millfolio.app/appcast.xml` (committed to `millfolio/website` `public/`, Cloudflare auto-deploys) |

### Info.plist keys

```
SUFeedURL                = https://millfolio.app/appcast.xml
SUPublicEDKey            = UugYFpDtw08kzTIocCokisDnrFfgxw4ZuWBaG/xVIns=
SUEnableAutomaticChecks  = true         # check on launch + on schedule
SUScheduledCheckInterval = 86400        # once a day; user-adjustable in Sparkle prefs
```

### Framework embedding (bundle.sh)

Sparkle ships (via SPM) as a binary `Sparkle.framework` that also contains helper
code — `Autoupdate`, `Updater.app`, `Downloader.xpc`, `Installer.xpc`. Our `.app` is
hand-assembled (not `xcodebuild`), so `bundle.sh` now:

1. Copies `Sparkle.framework` into `Millfolio.app/Contents/Frameworks/`.
2. Adds the `@executable_path/../Frameworks` rpath to the app binary.
3. Stamps `CFBundleShortVersionString` / `CFBundleVersion` from `$MILLFOLIO_VERSION`
   (the release tag) so Sparkle can compare the running app against the appcast.
4. **Signs inside-out**: the two XPC services, `Autoupdate`, `Updater.app`, then the
   framework, then the app last — hardened runtime + secure timestamp for Developer
   ID (ad-hoc locally). Verified with `codesign --verify --deep --strict`.

## Release pipeline (release.yml, on a `v*` tag)

1. Existing flow unchanged: build + sign + notarize + staple the **`.pkg`** (first
   install), build the signed CLI tarball.
2. New "Build & sign Sparkle update" step (guarded `if: …env.APPLE_ID != ''`):
   - `bundle.sh` builds a standalone Developer-ID-signed `Millfolio.app` at the tag
     version.
   - Notarize **the app** (submit a zip, staple the `.app`) so it launches offline
     after an update.
   - `ditto -c -k --keepParent` → `Millfolio-<ver>.zip` (the update archive).
   - `generate_appcast --ed-key-file -` (private key piped from the
     `SPARKLE_PRIVATE_KEY` secret via **stdin — never written to disk**),
     `--download-url-prefix` pointing at this release's asset download → `appcast.xml`.
3. Attach `Millfolio-<ver>.zip` + `appcast.xml` to the GitHub Release (alongside the
   `.pkg` + CLI tarball).
4. Publish `appcast.xml` to `millfolio.app/appcast.xml` by committing it to the
   website repo's `public/` (needs `WEBSITE_PUSH_TOKEN`); Cloudflare auto-deploys.

### Why this hosting choice

`SUFeedURL` is a fixed `https://millfolio.app/appcast.xml`, so the feed must live at
the site root (same place `demo-vault.zip` is served from). The **binary** update
zip is a **GitHub Release asset** (versioned, stable URL, no repo bloat); only the
small text `appcast.xml` is committed to the website. The enclosure URL in the
appcast points back at the release asset. This keeps binaries out of git while
serving the feed from the required host.

## One-time human step: the EdDSA private key + CI secret

Sparkle signs every update with an **EdDSA (ed25519) private key**. The key pair was
created with Sparkle's `generate_keys`; the **private key is stored in the login
keychain** and the **public key** is already in `installer/Info.plist`
(`SUPublicEDKey` above). **The private key must never be printed, committed, or
logged.**

For CI to sign updates, a human must export it **once** and store it as a repo
secret:

```bash
# From menu/ after a build has fetched Sparkle:
./.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private_key.txt
# → macOS will prompt to authorize reading the key from your keychain.

gh secret set SPARKLE_PRIVATE_KEY -R millfolio/menu-bar < sparkle_private_key.txt
shred -u sparkle_private_key.txt      # or: rm -P
```

Also configure (once):

- `SPARKLE_PRIVATE_KEY` — as above.
- `WEBSITE_PUSH_TOKEN` — a fine-grained PAT with **contents: write** on
  `millfolio/website`, so the pipeline can publish `appcast.xml`.

If either secret is missing, the pipeline still ships the notarized `.pkg`; only the
Sparkle update step no-ops / fails loud (`SPARKLE_PRIVATE_KEY` is required once the
Sparkle step runs on a tag with Apple creds present).

## What still needs a live two-release test

A full update cycle can't be exercised in one build. After the **first** tagged
release that includes Sparkle is installed, cut a **second, higher** tag and confirm:

1. The installed app finds the update ("Check for Updates…" and the scheduled check).
2. Sparkle downloads `Millfolio-<ver>.zip`, verifies the EdDSA signature against
   `SUPublicEDKey`, and installs it (relaunching the new version).
3. The updated app passes Gatekeeper on launch (stapled notarization).
4. `curl https://millfolio.app/appcast.xml` returns the freshly published feed.
