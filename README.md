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

Set `IOS_BUILD_NUMBER` and `ANDROID_BUILD_NUMBER` independently, each above the
corresponding live store number and at least the pubspec build. Google Play
requires a new version code across tracks. Add and commit
`fastlane/release_notes/<version>+<build>.txt` for each selected number. If the
numbers differ, provide both files. Notes are limited to 500 characters and
must match committed bytes. `draft_release_notes build_number:<number>` can
draft notes for review, but deployment never generates or commits them.
Build-only lanes also require their platform's explicit build number, so no
release artifact silently reuses the pubspec number. Check store uniqueness
before a later upload; build-only lanes do not query the stores.
`bump_build_version` is an explicit maintenance lane backed by the shared
`bump_pubspec_build` action. It changes only pubspec and requires a subsequent
review/commit; beta lanes never invoke it.

Run `bundle exec fastlane beta_preflight`, then `bundle exec fastlane beta_all`
for a combined release, or `ios beta` / `android beta` separately. The combined
lane analyzes/tests, builds both artifacts, then uploads. It records artifact
hashes and per-platform upload outcomes in `build/release/status.json`. An
upload interruption can leave an unknown store outcome: check the store before
retrying. `ios upload ipa:<path>` and `android upload aab:<path>` require a
matching local receipt or an explicit `sha256:<digest>`; they read the embedded
version/build and use the matching committed notes.

Android beta accepts only `internal`, `alpha`, or `beta` via
`PLAY_STORE_BETA_TRACK`. `PLAY_STORE_VALIDATE_ONLY=true` validates an Android
Play edit without releasing it. TestFlight distribution uses
`TESTFLIGHT_GROUPS` and `TESTFLIGHT_DISTRIBUTE_EXTERNAL`. iOS signing uses
read-only `match`; `APPLE_TEAM_ID` and pre-provisioned signing assets are
required. `APP_STORE_CONNECT_API_KEY_PATH` is required in CI. App Store review
submission is a separate `ios release` lane, enabled by the app's
`IOS_RELEASE_MODE=app_store_submission` setting; it selects an existing build
and manual release after approval.
Apps that previously used `ios release` for TestFlight can set
`IOS_RELEASE_MODE=testflight_alias`; `ANDROID_RELEASE_MODE=beta_alias` likewise
retains an Android beta alias. `ENABLE_FIREBASE_DISTRIBUTION=true` enables
`ios firebase_beta` and `android firebase_beta`; they require the app's Firebase
config, explicit platform build number, committed notes, and Fastlane Firebase
plugin. App Store submission and Firebase distribution remain opt-in.

## Verification and upgrades

Run `ruby test/release_check.rb` with the app's Ruby/Fastlane bundle. Before
updating the submodule pin, review the shared commit range, run this test, and
run `bundle exec fastlane lanes` plus each app's release checks. Update the
submodule in each app through its master branch. No store upload is part of the
shared component's own CI.
