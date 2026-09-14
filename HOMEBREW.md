# Installing Notchly with Homebrew

Notchly ships as a Homebrew **cask** (a universal build that runs on both Intel
and Apple Silicon Macs, macOS Sonoma or newer).

## For users

```bash
brew tap gronker22/notchly
brew trust gronker22/notchly      # Homebrew 7+ requires trusting third-party taps once
brew install --cask notchly
```

Notchly installs to `/Applications`. Because the build is **unsigned**, the first
launch needs a right-click → **Open** (or System Settings → Privacy & Security →
**Open Anyway**) — the same one-time step as the direct download. Update later with:

```bash
brew upgrade --cask notchly
```

## Publishing the tap (one-time, maintainer)

Homebrew finds third-party casks in a "tap" — a repo named `homebrew-<tap>`.

1. Create a public repo **`gronker22/homebrew-notchly`**.
2. Copy [`Casks/notchly.rb`](Casks/notchly.rb) from this repo into `Casks/notchly.rb` in the tap repo.
3. Commit & push.

Users can then run the install command above. (The bare `Casks/notchly.rb` in
*this* repo is the source of truth — copy it to the tap on each release, or make
the tap a submodule.)

## On each release

1. Cut the GitHub release with the `Notchly-Intel-Universal.zip` asset.
2. Update `version` in `Casks/notchly.rb`.
3. Update `sha256`:
   ```bash
   shasum -a 256 dist/Notchly-Intel-Universal.zip
   ```
4. Copy the cask into the `homebrew-notchly` tap and push.

## Note on signing

Because the app isn't notarized, the cask strips the quarantine attribute in a
`postflight` so it opens without the right-click dance. If Notchly ever gets an
Apple Developer signature + notarization, that `postflight` can be removed.
