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
adb install -r build/emulator/personel.apk
adb install -r build/emulator/yonetim.apk
shoot() { # package name mode
  adb shell am force-stop "$1" || true
  adb shell monkey -p "$1" -c android.intent.category.LAUNCHER 1 >/dev/null
  sleep 12
  adb exec-out screencap -p > "$out/$2-$3.png"
  adb shell dumpsys activity activities | grep -m1 -E "topResumedActivity|mResumedActivity" > "$out/$2-$3.activity.txt" || true
  adb logcat -d -s flutter:E AndroidRuntime:E > "$out/$2-$3.errors.txt" || true
  adb logcat -c || true
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
