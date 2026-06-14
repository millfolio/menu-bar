# Homebrew distribution — `millrace` CLI

The `millrace` CLI (same engine lifecycle as the menu-bar app, on the command
line) ships as a **prebuilt, Developer-ID-signed universal binary**, attached to
each GitHub Release as `millrace-macos.tar.gz` by `.github/workflows/release.yml`.

## Installing (once the tap exists)

```sh
brew install millrace/tap/millrace
millrace status
```

## Releasing a new version

1. Tag the app repo (`git tag v0.4.0 && git push origin v0.4.0`). CI builds the
   `.pkg` **and** the signed universal `millrace-macos.tar.gz`, attaching both to
   the Release. (The job log prints the tarball's sha256.)
2. Bump the formula to point at the new asset + checksum:

   ```sh
   dist/homebrew/update-formula.sh v0.4.0
   ```

3. Publish the formula to the tap repo (`millrace/homebrew-tap`) as
   `Formula/millrace.rb`. Either copy it by hand, or wire the optional auto-push
   step (a release-workflow step guarded by a `HOMEBREW_TAP_TOKEN` secret — a PAT
   with `contents:write` on the tap).

## Creating the tap (one-time)

A Homebrew tap is just a repo named `homebrew-<name>`:

```sh
# millrace/homebrew-tap, with the formula under Formula/
gh repo create millrace/homebrew-tap --public
git -C homebrew-tap add Formula/millrace.rb && git -C homebrew-tap commit -m "millrace 0.4.0" && git -C homebrew-tap push
```

`brew install millrace/tap/millrace` resolves `millrace/homebrew-tap` →
`Formula/millrace.rb`.

## Notes

- **Signing, not notarization.** The binary is signed with the Developer ID
  Application identity + hardened runtime. A signed CLI runs from the terminal
  without a Gatekeeper prompt, and Homebrew doesn't quarantine tap downloads, so
  notarization isn't required. (You can't staple a ticket to a bare Mach-O
  anyway.)
- **Shared state with the app.** The CLI and the menu-bar app use the same
  install tree (`~/Library/Application Support/Millrace`) and the same launchd
  job (`me.millrace.server`), so `millrace start` and the app's "Start server"
  drive one process — either can start/stop/observe it.
