# Releasing gemba

## Pre-release

1. Update version in `lib/gemba/version.rb`
2. Update `CHANGELOG.md` — move Unreleased items under new version heading
3. Commit: `git commit -am "Bump to vX.Y.Z"`

## Smoke test

```bash
rake release:smoke
```

This uninstalls previous versions, builds libmgba from source, builds and installs the gem, verifies the version, loads a test ROM, and runs one headless frame.

## Tag and push

```bash
git tag vX.Y.Z
git push origin main --tags
```

## Publish

```bash
gem push gemba-X.Y.Z.gem
```

## Post-release

- Trigger the docs workflow if needed: `gh workflow run docs.yml`
- Update `.github/mgba-version` if the mGBA pin changed
