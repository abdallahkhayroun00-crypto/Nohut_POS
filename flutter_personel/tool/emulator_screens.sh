#!/usr/bin/env bash
# Installs both real APKs on the CI emulator and captures their screens in
# light and dark mode. Evidence only: no Windows server is reachable here, so
# the apps show their first-run (pairing) screens. Never a physical-device test.
set -euo pipefail
out="${1:-screens}"
mkdir -p "$out"
adb wait-for-device
adb shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done'
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0
# The 17:5x run captured only a "Pixel Launcher isn't responding" dialog over
# the notification-permission prompt. Hide system error dialogs, let the
# launcher settle, and pre-grant notifications so the real screens show.
adb shell settings put global hide_error_dialogs 1 || true
adb shell settings put secure anr_show_background 0 || true
sleep 30
adb shell input keyevent KEYCODE_HOME || true
adb install -r build/emulator/personel.apk
adb install -r build/emulator/yonetim.apk
for pkg in com.nohutfalafel.nohut_personel com.nohutfalafel.nohut_yonetim; do
  adb shell pm grant "$pkg" android.permission.POST_NOTIFICATIONS || true
done
shoot() { # package name mode
  adb shell am force-stop "$1" || true
  adb shell monkey -p "$1" -c android.intent.category.LAUNCHER 1 >/dev/null
  sleep 25
  # Close any leftover system dialog (ANR, permission) before capturing.
  if adb shell dumpsys window | grep -qE "mCurrentFocus=.*(Application Not Responding|GrantPermissions)"; then
    adb shell input keyevent KEYCODE_ENTER || true; sleep 2
  fi
  adb exec-out screencap -p > "$out/$2-$3.png"
  adb shell dumpsys activity activities | grep -m1 -E "topResumedActivity|mResumedActivity" > "$out/$2-$3.activity.txt" || true
  adb logcat -d -s flutter:E AndroidRuntime:E > "$out/$2-$3.errors.txt" || true
}
for mode in light dark; do
  if [ "$mode" = dark ]; then adb shell cmd uimode night yes; else adb shell cmd uimode night no; fi
  sleep 2
  shoot com.nohutfalafel.nohut_personel personel "$mode"
  shoot com.nohutfalafel.nohut_yonetim yonetim "$mode"
done
# Fail if either app crashed at startup.
if grep -l "FATAL EXCEPTION" "$out"/*.errors.txt; then echo "::error::An APK crashed on the emulator"; exit 1; fi
ls -la "$out"
# Real Flutter screens with synthetic data (integration test on the emulator).
# `flutter drive` never reconnected on the API 34 emulator (runs hung for
# 25+ min), so run the integration test directly, bounded, and collect the
# PNGs the test prints into the log.
# "The log reader stopped unexpectedly" ended the previous run: keep the
# logcat buffer large, don't clear it under the tool, and retry once.
adb logcat -G 16M || true
for attempt in 1 2; do
  if timeout 600 flutter test integration_test/screens_test.dart -d emulator-5554 --reporter expanded \
      > "$out/flutter-test.log" 2>&1 && grep -q NOHUT_FLUTTER_SHOT "$out/flutter-test.log"; then
    break
  fi
  echo "::warning::Flutter screen capture attempt $attempt failed or timed out"
  grep -v NOHUT_FLUTTER_SHOT "$out/flutter-test.log" | tail -15 || true
done
grep -v NOHUT_FLUTTER_SHOT "$out/flutter-test.log" | tail -40 || true
python3 tool/collect_flutter_shots.py "$out/flutter-test.log" "$out" || true
ls -la "$out"
# Small copies in the job log, so reviewers without artifact access can see them.
python3 tool/print_shots.py "$out"
