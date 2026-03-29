# Releasing ScreenMuse

## Tagging a Release

```bash
# Ensure you're on main with a clean tree
git checkout main
git pull origin main
git status  # should be clean

# Tag with a signed, annotated tag
git tag -s v1.2.3 -m 'ScreenMuse 1.2.3'

# Push the tag — this triggers the release workflow
git push origin v1.2.3
```

The `.github/workflows/release.yml` workflow will:
1. Build universal (arm64 + x86_64) binaries
2. Package them into `screenmuse-1.2.3.zip`
3. Create a GitHub Release with auto-generated release notes

## Updating the Homebrew Formula

After the release workflow finishes:

1. Download the zip from the GitHub Release:
   ```bash
   curl -LO https://github.com/hnshah/screenmuse/releases/download/v1.2.3/screenmuse-1.2.3.zip
   ```

2. Compute the SHA256:
   ```bash
   shasum -a 256 screenmuse-1.2.3.zip
   ```

3. Update the formula in `homebrew-screenmuse` tap:
   ```bash
   cd homebrew-screenmuse
   # Edit screenmuse.rb — update version and sha256
   git commit -am 'screenmuse 1.2.3'
   git push
   ```

## Setting Up the Homebrew Tap

To create the `homebrew-screenmuse` tap repo on GitHub:

1. Create a new repo named `homebrew-screenmuse` under the `hnshah` org/user.

2. Copy the formula:
   ```bash
   mkdir homebrew-screenmuse
   cd homebrew-screenmuse
   git init
   cp /path/to/screenmuse/packages/homebrew/screenmuse.rb .
   git add screenmuse.rb
   git commit -m 'Add screenmuse formula'
   git remote add origin https://github.com/hnshah/homebrew-screenmuse.git
   git push -u origin main
   ```

3. Users can then install with:
   ```bash
   brew install hnshah/screenmuse/screenmuse
   ```

## Code Signing with Developer ID

Code signing is required for Gatekeeper on macOS. This needs an Apple Developer ID certificate.

### Prerequisites
- Apple Developer account ($99/year)
- Developer ID Application certificate in Keychain
- Developer ID Installer certificate (for `.pkg`)

### Signing the binaries

```bash
# Sign each binary with hardened runtime
codesign --force --options runtime \
  --sign "Developer ID Application: Your Name (TEAM_ID)" \
  .build/universal/ScreenMuseApp

codesign --force --options runtime \
  --sign "Developer ID Application: Your Name (TEAM_ID)" \
  .build/universal/screenmuse

codesign --force --options runtime \
  --sign "Developer ID Application: Your Name (TEAM_ID)" \
  .build/universal/ScreenMuseMCP
```

### Notarization

```bash
# Create a zip for notarization
zip screenmuse-notarize.zip \
  .build/universal/ScreenMuseApp \
  .build/universal/screenmuse \
  .build/universal/ScreenMuseMCP

# Submit for notarization
xcrun notarytool submit screenmuse-notarize.zip \
  --apple-id "your@email.com" \
  --team-id "TEAM_ID" \
  --password "app-specific-password" \
  --wait

# Staple the ticket (for .pkg and .app bundles only)
# Individual CLI binaries cannot be stapled — the notarization
# is checked online by Gatekeeper at first launch.
```

## Creating a .pkg Installer

The `.pkg` format installs binaries into standard paths.

```bash
VERSION=1.2.3

# Create a staging directory
mkdir -p pkg-root/usr/local/bin
cp .build/universal/screenmuse pkg-root/usr/local/bin/
cp .build/universal/ScreenMuseMCP pkg-root/usr/local/bin/
cp .build/universal/ScreenMuseApp pkg-root/usr/local/bin/

# Build the package
pkgbuild \
  --root pkg-root \
  --identifier com.hnshah.screenmuse \
  --version "$VERSION" \
  --install-location / \
  "screenmuse-${VERSION}.pkg"

# (Optional) Sign the package
productsign \
  --sign "Developer ID Installer: Your Name (TEAM_ID)" \
  "screenmuse-${VERSION}.pkg" \
  "screenmuse-${VERSION}-signed.pkg"
```

## Creating a .dmg Disk Image

The `.dmg` format is a drag-to-install experience for GUI apps.

```bash
VERSION=1.2.3

# Create a staging directory
mkdir -p dmg-staging
cp .build/universal/ScreenMuseApp dmg-staging/
cp .build/universal/screenmuse dmg-staging/
cp .build/universal/ScreenMuseMCP dmg-staging/

# Create the DMG
hdiutil create \
  -volname "ScreenMuse ${VERSION}" \
  -srcfolder dmg-staging \
  -ov \
  -format UDZO \
  "screenmuse-${VERSION}.dmg"

# (Optional) Sign the DMG
codesign --force \
  --sign "Developer ID Application: Your Name (TEAM_ID)" \
  "screenmuse-${VERSION}.dmg"
```

## Release Checklist

- [ ] All tests pass (`swift test`)
- [ ] Version number updated where applicable
- [ ] CHANGELOG.md updated
- [ ] Tag created and pushed
- [ ] GitHub Release created (automatic via workflow)
- [ ] Homebrew formula SHA256 updated
- [ ] (Future) Binaries code-signed and notarized
