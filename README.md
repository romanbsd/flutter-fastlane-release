# Flutter Fastlane release lanes

Shared, app-neutral Fastlane lanes for Flutter apps. This repository contains no
app identifiers, credentials, signing material, store metadata, or release notes.
Each application imports a pinned Git submodule commit and keeps those values in
its own repository or environment.

## Install in an app

```sh
git submodule add https://github.com/romanbsd/flutter-fastlane-release.git vendor/flutter-fastlane-release
```

In the app's `fastlane/Fastfile`:

```ruby
import '../vendor/flutter-fastlane-release/Fastfile'
```

Keep a root `Gemfile` and lockfile with Fastlane, an app-specific
`fastlane/Appfile`, and `fastlane/.env.example`. CI must use
`git submodule update --init --recursive` before Bundler/Fastlane.

## Beta release

An upload lane with no `IOS_BUILD_NUMBER` or `ANDROID_BUILD_NUMBER` assigns the
next build itself: one above the latest build already on the stores being
shipped, and never below the pubspec build. The lane writes the selected build
to `pubspec.yaml` (also when both numbers are explicit), asks Codex for any
missing `fastlane/release_notes/<version>+<build>.txt`, and commits the pubspec
change and changelog before building. Notes are limited to 500 characters. The
Codex CLI must be installed and authenticated; generation is bounded by
`CODEX_NOTES_TIMEOUT_SECONDS` (default 300). Set a platform build number only to
reuse a specific build; that override must already exceed the store. Notes must
already be committed when every platform number is explicit; a mixed release
generates missing notes for the override. `PLAY_STORE_VALIDATE_ONLY` does not
change the repository, so it still requires the platform build number. Run one
release at a time: two concurrent runs can assign the same build.

Bump the version as part of the release with the `bump:` option, or set
`VERSION_BUMP`:

```sh
bundle exec fastlane beta_all bump:minor
VERSION_BUMP=patch bundle exec fastlane ios beta
```

`major` resets minor and patch to zero, `minor` resets patch, and any
pre-release suffix is dropped. A version bump generates notes for the new
version. Build-only lanes never bump the pubspec and never tag. After a
successful upload of a new major.minor.patch version the lane creates a local
`vX.Y.Z` git tag; build-only changes inside the same version are not tagged, and
`PLAY_STORE_VALIDATE_ONLY` runs never tag. Push tags explicitly with
`git push origin vX.Y.Z` (or `git push --tags`).
Build-only lanes also require their platform's explicit build number and do not
query the stores or edit pubspec. `bump_build_version` remains available when
you want to raise the pubspec build without deploying. `draft_release_notes`
can still draft notes for a chosen build without committing them.

Run `bundle exec fastlane beta_preflight`, then `bundle exec fastlane beta_all`
for a combined release, or `ios beta` / `android beta` separately. Preflight only
computes and validates the next numbers (stores, signing, toolchain, notes for
explicit releases); it does not write or commit, previews `bump:` in its output,
and `beta_all` assigns the numbers again. The combined lane analyzes/tests,
builds both artifacts, then uploads. It records the latest run in
`build/release/status.json` and keeps per-artifact receipts keyed by version and
build in `build/release/receipts.json`, so a receipt survives a later attempt
that fails before building. An upload interruption can leave an unknown store
outcome: check the store before retrying. `ios upload ipa:<path>` and
`android upload aab:<path>` require a matching receipt or an explicit
`sha256:<digest>`; they read the embedded version/build and use the matching
committed notes.

Android beta accepts only `internal`, `alpha`, or `beta` via
`PLAY_STORE_BETA_TRACK`. `PLAY_STORE_VALIDATE_ONLY=true` validates an Android
Play edit without releasing it. `android store_listing` uploads Play metadata
and optional images only; it targets `PLAY_STORE_VERSION_CODE` (or
`SUPPLY_VERSION_CODE`) and otherwise the latest release on the track. Changelogs
are uploaded only for an explicit version code. TestFlight distribution
uses `TESTFLIGHT_GROUPS` and `TESTFLIGHT_DISTRIBUTE_EXTERNAL`.
For external TestFlight testing, also provide the app-specific
`TESTFLIGHT_BETA_APP_DESCRIPTION` and `TESTFLIGHT_BETA_APP_FEEDBACK_EMAIL`,
and complete beta review contact/demo-account details in App Store Connect.
External builds may require Apple's beta review before testers can install them.
The current App Store upload minimum is Xcode 26 with an iOS 26 SDK, and
Google Play updates must target Android API 36 or later. Verify current store
requirements before each release. iOS signing uses
read-only `match`; `APPLE_TEAM_ID` and pre-provisioned signing assets are
required. Manual signing settings are applied to the `Runner` target only; apps
with extension targets keep their own signing configuration in the Xcode
project. The original `project.pbxproj` is backed up as
`project.pbxproj.fastlane-backup` before signing changes and removed after a
successful restore; if a run is killed, restore it manually.
`APP_STORE_CONNECT_API_KEY_PATH` is required in CI. App Store review
submission is a separate `ios release` lane, enabled by the app's
`IOS_RELEASE_MODE=app_store_submission` setting; it selects an existing build
and manual release after approval. Notes are written for `APP_STORE_NOTES_LOCALE`
(default `en-US`).
Apps that previously used `ios release` for TestFlight can set
`IOS_RELEASE_MODE=testflight_alias`; `ANDROID_RELEASE_MODE=beta_alias` likewise
retains an Android beta alias. `ENABLE_FIREBASE_DISTRIBUTION=true` enables
`ios firebase_beta` and `android firebase_beta`; they require the app's Firebase
config, explicit platform build number, committed notes, and Fastlane Firebase
plugin. `ios firebase_beta` builds an Ad Hoc export so testers can install the
IPA directly. App Store submission and Firebase distribution remain opt-in.

## Verification and upgrades

Run `bundle exec ruby test/release_check.rb` in this repository. Dependabot
checks the standalone test bundle and CI actions weekly; review its PRs and
the passing CI job before merging. Before
updating the submodule pin, review the shared commit range, run this test, and
run `bundle exec fastlane lanes` plus each app's release checks. Update the
submodule in each app through its master branch. No store upload is part of the
shared component's own CI.
