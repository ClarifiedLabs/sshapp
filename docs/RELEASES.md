# Releases

SSH App ships to TestFlight from release tags.

## Release Workflow

`.github/workflows/deploy-ios.yml` runs on `v*.*.*` tags, on the `release-ci`
branch, and by manual dispatch. Tag builds verify the release commit is already
on `origin/main`, then archive, sign, export, upload to TestFlight, and upload
dSYMs. `release-ci` and manual runs exercise the same archive/export path;
manual runs upload only when `upload_to_testflight=true`.

## Cut a Release

```bash
make release VERSION=patch AUTOPUSH=1
```

With no existing release tags, `VERSION=patch` resolves to `v0.0.1`. Supported
values are:

- `VERSION=patch`
- `VERSION=minor`
- `VERSION=major`
- `VERSION=X.Y.Z`

Omit `AUTOPUSH=1` to create the tag locally first. Use `DRY_RUN=1` to preview
the version and tag without changing files, commits, tags, or remotes:

```bash
make release VERSION=patch DRY_RUN=1
```

The helper runs release regression tests unless `SKIP_TESTS=1` is set.

When needed, `tools/release.py` updates `MARKETING_VERSION` in
`SSHApp.xcodeproj/project.pbxproj` and commits:

```text
chore(release): bump version to vX.Y.Z
```

## Versioning

The release workflow uses:

- Tag semver as `MARKETING_VERSION`
- GitHub Actions run number as `CURRENT_PROJECT_VERSION`

## Manual Dry Run

A manual workflow run can exercise signing and artifact creation without a
TestFlight upload:

```bash
gh workflow run deploy-ios.yml -f upload_to_testflight=false
gh run watch
```

## Required GitHub Actions Secrets

- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY`
- `APPLE_TEAM_ID`
- `IOS_DISTRIBUTION_CERTIFICATE_BASE64`
- `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`
- `IOS_PROVISIONING_PROFILE_BASE64`
