# Release Process

TokenBar releases are distributed through GitHub Releases as zipped macOS app bundles.

## Versioning

- Use semantic version tags with a leading `v`, for example `v0.0.1`.
- Keep `Bundle/Info.plist` in sync:
  - `CFBundleShortVersionString` is the public version, for example `0.0.1`.
  - `CFBundleVersion` is the build number. Increment it when shipping another build for the same public version.

## Build And Verify

From the repository root:

```bash
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.0.1" Bundle/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 1" Bundle/Info.plist
swift build -c release
swift run -c release TokenBar --print-today
zsh Scripts/build-app.sh
codesign --verify --deep --strict .build/release/TokenBar.app TokenBar.app
```

The app is currently ad-hoc signed by `Scripts/build-app.sh`. That verifies bundle integrity, but it is not the same as Apple Developer ID signing and notarization.

## Package Release Assets

```bash
rm -rf dist
mkdir -p dist
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent TokenBar.app dist/TokenBar-0.0.1-macos-arm64.zip
(cd dist && shasum -a 256 TokenBar-0.0.1-macos-arm64.zip > TokenBar-0.0.1-macos-arm64.zip.sha256)
```

Use `macos-arm64` because the default SwiftPM release build on Apple Silicon produces an ARM64 binary. Build a universal binary before changing the artifact name.

## Commit, Tag, Push

```bash
git add Bundle/Info.plist README.md RELEASE.md .gitignore
git commit -m "Release 0.0.1"
git tag -a v0.0.1 -m "TokenBar 0.0.1"
git push origin main --tags
```

## Create GitHub Release

```bash
gh release create v0.0.1 \
  dist/TokenBar-0.0.1-macos-arm64.zip \
  dist/TokenBar-0.0.1-macos-arm64.zip.sha256 \
  --title "TokenBar 0.0.1" \
  --notes-file release-notes.md
```

Do not commit `dist/`; GitHub Releases are the distribution location for built artifacts.

## Gatekeeper Note

Until TokenBar is Developer ID signed and notarized, macOS may show a warning for downloaded builds. Users can open it with Control-click or right-click, then Open. Fully frictionless public downloads require an Apple Developer account, Developer ID signing, and notarization.
