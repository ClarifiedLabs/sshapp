# Releases

SSH App ships to TestFlight from release tags.

## Release Workflow

`.github/workflows/test-ios.yml` is the pipeline entry point. It runs iOS tests
on pushes to `main`, `release-ci`, and `v*.*.*` tags, plus pull requests and
manual dispatch.

After tests pass, branch and tag pushes and manual runs call the reusable
`.github/workflows/deploy-ios.yml` to archive, sign, export, validate IPA metadata,
and upload IPA/dSYM workflow artifacts. Main and `release-ci` run the same full
validation path. Pull requests and manual runs on feature branches run tests
only and never receive signing secrets. Manual signed validation is restricted
to `main`, `release-ci`, and release tags.

Only `v*.*.*` tag pushes publish to TestFlight and upload dSYMs to App Store
Connect. Tag builds verify the release commit is already on `origin/main`.
GitHub schedules the release job through `needs: test`; no runner polls or
dispatches another test run. A tag push runs its own tests for the tagged commit,
even if that commit previously passed on `main`.

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

A manual pipeline run exercises tests, signing, and artifact creation without a
TestFlight upload (even when manually dispatched on a tag):

```bash
gh workflow run test-ios.yml --ref main
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
