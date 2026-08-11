#!/usr/bin/env bash
#
# finalize-image.sh — bake device-specific bits into system_patched.img that
#                     cannot be set at runtime, and emit a flashable image.
#
#   ./tools/finalize-image.sh out.img [shader-index] [path/to/a9_eink_server]
#
# 1. adb/root properties. ALWAYS. Flashing an image without these can leave the
#    device unreachable: on a `user` build USB debugging is off, so if the panel
#    is not usable there is no way in except the hardware key combo.
#    (On some bases these are overridden earlier in the property load order and
#    will not take effect - verify with `adb shell getprop ro.debuggable`.)
#
# 2. a9_eink_server. Two builds exist and they pair with different app versions:
#      47224 B (May 2024)  - no stl/wov commands; pairs with a9service v1.4.1
#      43216 B (Sep 2024)  - has stl/wov; pairs with a9service v3.x
#    Both speak the same abstract socket "a9_eink_socket".
#
# 3. sys.linevibrator_type via vndk.rc. MUST be set by init: SELinux confines
#    sys.linevibrator_* to phhsu_daemon, so `setprop` from a shell is denied.
#    This is the ColorFade SHADER_LIST index (only meaningful with
#    A9_PATCH_COLORFADE=1). Passthrough (no fade to black) indices:
#      moon  6 7 14 15 22 23 30 31 38 39 46 47
#      pause 54 55 62 63 70 71 78 79 86 87 94 95
#    Any other index deliberately fades the panel to black or white.
#    SENTINEL 96 (one past the list) means "overlay AOD active, do not run
#    ColorFade at all" - use it as the boot default when mode 2 is the norm.
#
# Also note: GSI images ship deduplicated blocks, so `mount -o loop,rw` fails
# outright until `e2fsck -E unshare_blocks` has run. That is done here.
#
set -euo pipefail

OUT="${1:?usage: finalize-image.sh out.img [shader-index] [daemon] [aod-mode]}"
IDX="${2:-47}"
DAEMON="${3:-}"
MODE="${4:-}"    # OPTIONAL hard override of debug.a9.colorfade. LEAVE EMPTY.
                 # Empty = the app drives the mode via the stl sentinel, which
                 # is what makes the in-app "Disable Overlay AOD" toggle work.
                 # Setting it to 0 or 1 PINS the mode and the app can no longer
                 # switch, because the patched helper consults
                 # SystemProperties.getBoolean("debug.a9.colorfade", <sentinel>)
                 # and an explicitly-set value always wins. Debug use only.

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SRC="$REPO/app/external_scripts/system_img_patcher/system_patched.img"
[ -f "$SRC" ] || { echo "no system_patched.img - run tools/patch-gsi.sh first" >&2; exit 1; }

WORK="$(dirname "$(readlink -f "$OUT")")"
MNT="$WORK/.finalize-mnt"

rm -f "$OUT"
sudo cp "$SRC" "$OUT"
sudo chown "$(id -u):$(id -g)" "$OUT"

e2fsck -fy "$OUT" >/dev/null 2>&1 || true
resize2fs "$OUT" 3000M >/dev/null 2>&1
e2fsck -E unshare_blocks -y -f "$OUT" >/dev/null 2>&1 || true

mkdir -p "$MNT"
sudo mount -o loop,rw "$OUT" "$MNT"
cleanup() { sudo umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

BP="$MNT/system/build.prop"
for kv in ro.build.type=userdebug ro.debuggable=1 ro.secure=0 ro.adb.secure=0 persist.sys.usb.config=adb; do
  k="${kv%%=*}"; ek="$(printf '%s' "$k" | sed 's/\./\\./g')"
  if sudo grep -q "^$ek=" "$BP"; then
    sudo sed -i "s|^$ek=.*|$kv|" "$BP"
  else
    echo "$kv" | sudo tee -a "$BP" >/dev/null
  fi
done

V="$MNT/system/etc/init/vndk.rc"
if sudo grep -q "sys.linevibrator_type" "$V"; then
  sudo sed -i "s|setprop sys.linevibrator_type .*|setprop sys.linevibrator_type $IDX|" "$V"
else
  sudo sed -i "0,/on property:sys.boot_completed=1/s||on property:sys.boot_completed=1\n    setprop sys.linevibrator_type $IDX|" "$V"
fi

# Boot default for the runtime AOD mode switch (see A9_DISABLE_COLORFADE).
#   1 = ColorFade on  -> mode 1, retain last screen + moon/pause glyph
#   0 = ColorFade off -> mode 2, a9service overlay AOD (clock/chess/battery)
# debug.* is used because a plain adb shell can write it; sys.* and persist.sys.*
# are SELinux-denied. debug.* does not survive a reboot, hence this line.
# Only write the override if one was explicitly requested; otherwise strip any
# existing line so the app-driven sentinel decides the mode.
if [ -n "$MODE" ]; then
  if sudo grep -q "debug.a9.colorfade" "$V"; then
    sudo sed -i "s|setprop debug.a9.colorfade .*|setprop debug.a9.colorfade $MODE|" "$V"
  else
    sudo sed -i "0,/on property:sys.boot_completed=1/s||on property:sys.boot_completed=1\n    setprop debug.a9.colorfade $MODE|" "$V"
  fi
else
  sudo sed -i "/setprop debug.a9.colorfade/d" "$V"
fi

if [ -n "$DAEMON" ]; then
  sudo cp "$DAEMON" "$MNT/system/bin/a9_eink_server"
  sudo chmod 755 "$MNT/system/bin/a9_eink_server"
  sudo chown 0:2000 "$MNT/system/bin/a9_eink_server"
  sudo setfattr -n security.selinux -v u:object_r:phhsu_exec:s0 "$MNT/system/bin/a9_eink_server"
fi

echo "--- verification ---"
printf 'adb props    : %s/5\n' "$(sudo grep -cE '^(ro\.build\.type=userdebug|ro\.debuggable=1|ro\.secure=0|ro\.adb\.secure=0|persist\.sys\.usb\.config=adb)$' "$BP")"
printf 'aod override : %s\n' "${MODE:-<unset - app drives via stl sentinel>}"
printf 'shader index : %s\n'   "$(sudo grep -oE 'setprop sys\.linevibrator_type [0-9]+' "$V" | head -1)"
printf 'a9_eink_server: %s\n'  "$(sudo stat -c%s "$MNT/system/bin/a9_eink_server")"
printf 'a9service.apk : %s\n'  "$(sudo stat -c%s "$MNT/system/priv-app/a9service.apk")"
printf 'services.jar  : %s\n'  "$(sudo stat -c%s "$MNT/system/framework/services.jar")"

cleanup
trap - EXIT
e2fsck -fy "$OUT" >/dev/null 2>&1 || true
echo "done -> $OUT ($(stat -c%s "$OUT") bytes)"
echo
echo "Flash the LOGICAL system partition from fastbootd (NOT bootloader fastboot):"
echo "  adb reboot fastboot && fastboot flash system $OUT && fastboot reboot"
