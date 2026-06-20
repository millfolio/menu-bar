# Homebrew distribution — `millfolio` CLI

The `millfolio` CLI (same engine lifecycle as the menu-bar app, on the command
line) ships as a **prebuilt, Developer-ID-signed universal binary**, attached to
each GitHub Release as `millfolio-macos.tar.gz` by `.github/workflows/release.yml`.

## Installing (once the tap exists)

```sh
brew install millfolio/tap/millfolio
millfolio status
```

## Releasing a new version

1. Tag the app repo (`git tag v0.4.0 && git push origin v0.4.0`). CI builds the
   `.pkg` **and** the signed universal `millfolio-macos.tar.gz`, attaching both to
   the Release. (The job log prints the tarball's sha256.)
2. Bump the formula to point at the new asset + checksum:

   ```sh
   dist/homebrew/update-formula.sh v0.4.0
   ```

3. Publish the formula to the tap repo (`millfolio/homebrew-tap`) as
   `Formula/millfolio.rb`. Either copy it by hand, or wire the optional auto-push
   step (a release-workflow step guarded by a `HOMEBREW_TAP_TOKEN` secret — a PAT
   with `contents:write` on the tap).

## Creating the tap (one-time)

A Homebrew tap is just a repo named `homebrew-<name>`:

```sh
# millfolio/homebrew-tap, with the formula under Formula/
gh repo create millfolio/homebrew-tap --public
git -C homebrew-tap add Formula/millfolio.rb && git -C homebrew-tap commit -m "millfolio 0.4.0" && git -C homebrew-tap push
```

`brew install millfolio/tap/millfolio` resolves `millfolio/homebrew-tap` →
`Formula/millfolio.rb`.

## Notes

- **Signing, not notarization.** The binary is signed with the Developer ID
  Application identity + hardened runtime. A signed CLI runs from the terminal
  without a Gatekeeper prompt, and Homebrew doesn't quarantine tap downloads, so
  notarization isn't required. (You can't staple a ticket to a bare Mach-O
  anyway.)
- **Shared state with the app.** The CLI and the menu-bar app use the same
  install tree (`~/Library/Application Support/Millfolio`) and the same launchd
  job (`me.millfolio.server`), so `millfolio start` and the app's "Start server"
  drive one process — either can start/stop/observe it.
