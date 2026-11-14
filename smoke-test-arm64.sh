#!/usr/bin/env bash
# 8 Ball Pool ARM64 emulator smoke test (run #4 — first arm64 attempt).
# Runs INSIDE the android-emulator-runner step as a single file
# (bash smoke-test-arm64.sh), because the runner executes its `script:`
# input LINE BY LINE via `sh -c <line>`, which breaks multi-line
# if/then/fi blocks (run #1 died on exactly that).
# Runs on runs-on: ubuntu-24.04-arm with arch: arm64-v8a, target:
# google_apis, API 34. The game is arm64-only, so this is the first run
# with NO translation: if the game still dies, the cause is the game's
# own anti-emulator checks, not ARM translation.
# The APK is NOT downloaded from APKPure (it blocks GitHub runners: run #1
# got a 5.5 KB HTML page instead of the APK). It is fetched as 5 chunks
# from Muse storage (the 172 MB APK exceeds the single-upload limit) and
# reassembled here. Chunk URLs below were re-uploaded 2026-11-14 ~01:43 UTC
# with a 24h TTL — they expire 2026-11-15 ~01:43 UTC (06:43 PKT Nov 15).
# Re-upload from ~/workspace/production/8ball-pool-rea/apk-chunks/ if the
# run is triggered after that.
# Expected APK: 8 Ball Pool v56.35.0 (versionCode 4077), 172,596,975 bytes,
# SHA256 cb7d591318c0b23b9d84caf766ee219b68bb68d3958aadf0e66e5e505303db34.
set -x
mkdir -p dump logs

echo "=== Host + emulator info ==="
uname -m
adb shell getprop ro.build.version.sdk
adb shell getprop ro.product.model
adb shell getprop ro.build.fingerprint
adb shell getprop ro.kernel.qemu || true
adb shell getprop ro.secure || true
adb root
adb shell id

echo "=== Download 8 Ball Pool APK (Muse storage chunks, reassemble) ==="
curl -L --fail --max-time 300 -o part-00 "https://muse.ai/files/1245929901946388/1152868927084185/6t61r6yz1bfme8hcmiyh736h/part-00"
curl -L --fail --max-time 300 -o part-01 "https://muse.ai/files/1245929901946388/1368370131901685/czt23l6ubpzxu27jdaiot3vr/part-01"
curl -L --fail --max-time 300 -o part-02 "https://muse.ai/files/1245929901946388/1399787165331646/cagqc11m1y5d0vol55jk0wy8/part-02"
curl -L --fail --max-time 300 -o part-03 "https://muse.ai/files/1245929901946388/1847977439587549/3lj1wwkax5t55p4hmkakq7v3/part-03"
curl -L --fail --max-time 300 -o part-04 "https://muse.ai/files/1245929901946388/1578300277673044/ewd82gi3xhiddxoee5vyyis2/part-04"
cat part-00 part-01 part-02 part-03 part-04 > eightball.apk
rm -f part-00 part-01 part-02 part-03 part-04
ls -la eightball.apk
sha256sum eightball.apk | tee logs/apk-sha256.txt
file eightball.apk || true
# Fail fast if the download is not the genuine APK (wrong size/hash = blocked page).
EXPECTED_SHA="cb7d591318c0b23b9d84caf766ee219b68bb68d3958aadf0e66e5e505303db34"
ACTUAL_SHA=$(sha256sum eightball.apk | awk '{print $1}')
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
  echo "APK SHA256 MISMATCH: got $ACTUAL_SHA, expected $EXPECTED_SHA" | tee logs/apk-sha256-mismatch.txt
  exit 1
fi
echo "APK verified: 8 Ball Pool v56.35.0, hash matches."

echo "=== Install APK ==="
adb install -r -g eightball.apk 2>&1 | tee logs/install.log
adb shell pm list packages | grep eightball || true

echo "=== PHASE A: launch game, check it boots ==="
# Primary: explicit LAUNCHER activity from the manifest (EightBallPoolActivity,
# exported). Run #2 used MainActivity, which does not exist — the game never
# launched (install itself succeeded). NOTE: `adb shell am start` returns exit 0
# even when the activity does not exist, so the old `|| monkey` fallback never
# fired; launch success is checked with pidof below, not with the exit code.
adb shell am start -n com.miniclip.eightballpool/com.miniclip.eightballpool.EightBallPoolActivity || true
sleep 15
GAME_PID=$(adb shell pidof com.miniclip.eightballpool | tr -d '\r' | head -1 || true)
if [ -z "$GAME_PID" ]; then
  echo "Explicit launch did not start a process; trying monkey (resolves LAUNCHER from manifest)." | tee logs/launch-retry.txt
  adb shell monkey -p com.miniclip.eightballpool -c android.intent.category.LAUNCHER 1 || true
  sleep 15
fi
# Long settle: on software-emulated ARM (no /dev/kvm) the DexGuard loader is
# slow; give the game up to ~2.5 min after launch before judging it dead.
sleep 120
adb shell ps -A | grep -i eightball | tee logs/game-ps.txt || echo "GAME PROCESS NOT FOUND" | tee logs/game-ps.txt
adb shell screencap -p /sdcard/boot.png
adb pull /sdcard/boot.png logs/boot.png || true
GAME_PID=$(adb shell pidof com.miniclip.eightballpool | tr -d '\r' | head -1 || true)
echo "GAME_PID=$GAME_PID" | tee logs/game-pid.txt
if [ -n "$GAME_PID" ]; then
  adb shell "cat /proc/$GAME_PID/maps" | grep -i libgame | tee logs/libgame-maps.txt || echo "libgame NOT in maps (yet)" | tee logs/libgame-maps.txt
  adb shell "cat /proc/$GAME_PID/maps" | grep -i libloader | tee logs/libloader-maps.txt || true
  if ! grep -qi libgame logs/libgame-maps.txt 2>/dev/null; then
    echo "Game alive but libgame not mapped yet; waiting 60s and re-checking." | tee -a logs/libgame-maps.txt
    sleep 60
    adb shell "cat /proc/$GAME_PID/maps" | grep -i libgame | tee logs/libgame-maps-2.txt || echo "libgame STILL not in maps" | tee logs/libgame-maps-2.txt
  fi
else
  echo "No game PID: the game did not stay alive on real ARM64 (no translation)." | tee logs/boot-failed.txt
  adb shell logcat -d 2>/dev/null | grep -iE "eightball|miniclip|AndroidRuntime|FATAL" | tail -80 | tee logs/logcat.txt || true
  echo "=== DONE (boot failed) ==="
  ls -la logs/ dump/ || true
  exit 1
fi

echo "=== PHASE B: Frida dump (only if game is alive + libgame mapped) ==="
if [ -n "$GAME_PID" ] && { grep -qi libgame logs/libgame-maps.txt 2>/dev/null || grep -qi libgame logs/libgame-maps-2.txt 2>/dev/null; }; then
  FRIDA_VERSION="17.26.2"
  git clone --depth 1 https://github.com/ByteSnipers/fridump-bs
  python3 -m pip install -q -r fridump-bs/requirements.txt
  python3 -m pip install -q "frida==${FRIDA_VERSION}"
  curl -L --max-time 120 -o frida-server.xz "https://github.com/frida/frida/releases/download/${FRIDA_VERSION}/frida-server-${FRIDA_VERSION}-android-arm64.xz"
  xz -d frida-server.xz
  adb push frida-server /data/local/tmp/frida-server
  adb shell chmod 755 /data/local/tmp/frida-server
  adb shell /data/local/tmp/frida-server &
  sleep 5
  adb shell /data/local/tmp/frida-server --version || true
  python3 fridump-bs/fridump-bs.py -U -v "$GAME_PID" -o dump/ 2>&1 | tee logs/frida-dump.log || echo "Frida dump step failed (see log)" | tee -a logs/frida-dump.log
  ls -la dump/ || true
  if [ -z "$(ls -A dump/ 2>/dev/null)" ]; then
    echo "Frida dump produced no files." | tee logs/dump-empty.txt
    echo "=== DONE (dump empty) ==="
    ls -la logs/ dump/ || true
    exit 1
  fi
else
  echo "Skipping Frida dump: game not alive or libgame not mapped." | tee logs/dump-skipped.txt
  echo "=== DONE (dump skipped) ==="
  ls -la logs/ dump/ || true
  exit 1
fi
echo "=== DONE (success) ==="
ls -la logs/ dump/ || true
