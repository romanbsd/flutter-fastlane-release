#!/usr/bin/env bash
# Captures Google Play phone screenshots of a Flutter app on a running Android emulator or device.
# Run from the app root (the `android screenshots` lane does): scripts/play_screenshots.sh [adb-serial]
#
# The app's driver (PLAY_SCREENSHOTS_TEST) prints `PLAY_SHOT <name>` once a screen is ready and then holds it for
# a few seconds; each marker becomes <name>.png from a real device capture, so blur and shaders render as on a phone.
# PLAY_SCREENSHOTS lists the expected names; the committed set is replaced only when every one was captured.
# The display is set to 1080x1920 (Play allows at most 2:1) with a clean demo status bar, then reset to the
# device defaults (display size, density, demo mode off).
set -euo pipefail
[ -f pubspec.yaml ] || { echo 'Run from the Flutter app root.' >&2; exit 1; }
IFS=', ' read -r -a shots <<< "${PLAY_SCREENSHOTS:-}"
[ "${#shots[@]}" -gt 0 ] || { echo 'Set PLAY_SCREENSHOTS to the expected screenshot names, e.g. 01-home,02-detail.' >&2; exit 1; }
test_file="${PLAY_SCREENSHOTS_TEST:-integration_test/store_screenshots_test.dart}"
[ -f "$test_file" ] || { echo "Screenshot driver $test_file not found." >&2; exit 1; }

serial="${1:-$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')}"
[ -n "$serial" ] || { echo 'No Android device or emulator attached.' >&2; exit 1; }
out="fastlane/metadata/android/${PLAY_SCREENSHOTS_LOCALE:-en-US}/images/phoneScreenshots"
adb_() { adb -s "$serial" "$@"; }
demo() { adb_ shell am broadcast -a com.android.systemui.demo -e command "$@" >/dev/null; }

tmp=$(mktemp -d)

restore() {
  rm -rf "$tmp"
  demo exit || true
  adb_ shell settings put global sysui_demo_allowed 0 || true
  adb_ shell wm size reset || true
  adb_ shell wm density reset || true
}
trap restore EXIT

adb_ shell wm size 1080x1920
adb_ shell wm density 420
adb_ shell settings put global sysui_demo_allowed 1
demo enter
demo clock -e hhmm 0941
demo battery -e level 100 -e plugged false
demo network -e wifi show -e level 4
demo network -e mobile hide
demo notifications -e visible false

# Capture into a scratch folder; the committed set is replaced only by a complete run.
status=0
flutter test --no-pub "$test_file" -d "$serial" 2>&1 | while IFS= read -r line; do
  echo "$line"
  if [[ "$line" =~ PLAY_SHOT\ ([0-9a-z-]+) ]]; then
    adb_ exec-out screencap -p > "$tmp/${BASH_REMATCH[1]}.png"
    echo "captured ${BASH_REMATCH[1]}"
  fi
done || status=$?
[ "$status" -eq 0 ] || exit "$status"
for shot in "${shots[@]}"; do
  [ -s "$tmp/$shot.png" ] || { echo "Missing screenshot $shot; kept the existing set." >&2; exit 1; }
done
rm -rf "$out" && mkdir -p "$out" && cp "$tmp"/*.png "$out"/
ls "$out"
