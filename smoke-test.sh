#!/usr/bin/env bash
# 8 Ball Pool emulator smoke test (run #2).
# Runs INSIDE the android-emulator-runner step as a single file (bash smoke-test.sh),
# because the runner executes its `script:` input LINE BY LINE via `sh -c <line>`,
# which breaks multi-line if/then/fi blocks (run #1 died on exactly that).
# The APK is NOT downloaded from APKPure (it blocks GitHub runners: run #1 got a
# 5.5 KB HTML page instead of the APK). It is fetched as 5 chunks from Muse
# storage (the 172 MB APK exceeds the single-upload limit) and reassembled here.
# Expected APK: 8 Ball Pool v56.35.0 (versionCode 4077), 172,596,975 bytes,
# SHA256 cb7d591318c0b23b9d84caf766ee219b68bb68d3958aadf0e66e5e505303db34.
set -x
mkdir -p dump logs

echo "=== Emulator info ==="
adb shell getprop ro.build.version.sdk
adb shell getprop ro.product.model
adb root
adb shell id

echo "=== Download 8 Ball Pool APK (Muse storage chunks, reassemble) ==="
curl -L --fail --max-time 300 -o part-00 "https://muse.ai/files/1245929901946388/1482992667014240/q3pxsr9ewda77ygi4c0oxg2t/part-00"
curl -L --fail --max-time 300 -o part-01 "https://muse.ai/files/1245929901946388/1667362591598520/3fsfi875cnnd1xzn20bb8bh1/part-01"
curl -L --fail --max-time 300 -o part-02 "https://muse.ai/files/1245929901946388/1833184514287519/qnn95czmozoc4dxc3ruekngc/part-02"
curl -L --fail --max-time 300 -o part-03 "https://muse.ai/files/1245929901946388/1109593191836765/v9dtmsmosrrf9idt41q5hd5l/part-03"
curl -L --fail --max-time 300 -o part-04 "https://muse.ai/files/1245929901946388/1170163125432747/svctty81idegk1cmgh8tdctq/part-04"
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
adb shell am start -n com.miniclip.eightballpool/com.miniclip.eightballpool.MainActivity || adb shell monkey -p com.miniclip.eightballpool -c android.intent.category.LAUNCHER 1
sleep 90
adb shell ps -A | grep -i eightball | tee logs/game-ps.txt || echo "GAME PROCESS NOT FOUND" | tee logs/game-ps.txt
adb shell screencap -p /sdcard/boot.png
adb pull /sdcard/boot.png logs/boot.png || true
GAME_PID=$(adb shell pidof com.miniclip.eightballpool | tr -d '\r' | head -1 || true)
echo "GAME_PID=$GAME_PID" | tee logs/game-pid.txt
if [ -n "$GAME_PID" ]; then
  adb shell "cat /proc/$GAME_PID/maps" | grep -i libgame | tee logs/libgame-maps.txt || echo "libgame NOT in maps (yet)" | tee logs/libgame-maps.txt
  adb shell "cat /proc/$GAME_PID/maps" | grep -i libloader | tee logs/libloader-maps.txt || true
else
  echo "No game PID: the game did not stay alive under ARM translation." | tee logs/boot-failed.txt
  echo "=== DONE (boot failed) ==="
  ls -la logs/ dump/ || true
  exit 1
fi

echo "=== PHASE B: Frida dump (only if game is alive + libgame mapped) ==="
if [ -n "$GAME_PID" ] && grep -qi libgame logs/libgame-maps.txt 2>/dev/null; then
  FRIDA_VERSION="17.26.2"
  git clone --depth 1 https://github.com/ByteSnipers/fridump-bs
  python3 -m pip install -q -r fridump-bs/requirements.txt
  python3 -m pip install -q "frida==${FRIDA_VERSION}"
  curl -L --max-time 120 -o frida-server.xz "https://github.com/frida/frida/releases/download/${FRIDA_VERSION}/frida-server-${FRIDA_VERSION}-android-x86_64.xz"
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
