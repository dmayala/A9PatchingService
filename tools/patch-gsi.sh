#!/usr/bin/env bash
#
# patch-gsi.sh — run patch_system_img.py against a GSI with the right toolchain
#                and the A16 feature gates.
#
#   ./tools/patch-gsi.sh /path/to/system.img
#
# Bootstraps apktool 3.x into tools/bin (see WHY below), then runs the patcher
# as root (it loop-mounts the image and sets SELinux xattrs).
# Output: system_patched.img next to patch_system_img.py, plus patch-report.json.
#
# WHY apktool 3.x: apktool 2.10.x maps -api N onto a dex version and overflows
# at api 36 ("dexVersion must be within [0, 999]"). apktool 3.x removed -api
# entirely and derives the dex version from the input, which is what we want.
# It also renamed -c to --copy-original. smali_patcher.py targets 3.x.
#
# ------------------------------------------------------------------ gates ---
# Each gate is written below with its NON-default value, so what you see is what
# you would have to pass to change things. Defaults as of 2026-08-13:
#   ON  : A9_PATCH_VIBRATOR, A9_PATCH_COLORFADE, A9_DISABLE_COLORFADE,
#         A9_PATCH_TREBLE_OVERLAY, A9_PATCH_SERVICES
#   OFF : A9_PATCH_SYSTEMUI, A9_PATCH_DIALER, A9_PATCH_TREBLEAPP
# Each exists because the patch is either broken on Android 16, needs a key we
# may not want to use, or pairs with another gate.
#
#   A9_PATCH_SYSTEMUI=1    SystemUI.apk patches (AOD scrims, doze sensors,
#                          ImageWallpaper ambient redraw). Re-signed with
#                          A9_SIGN_KEY. NO LONGER RESTRICTED TO TESTKEY BASES --
#                          see "re-signing" below.
#   A9_PATCH_DIALER=1      Dialer tint. Same mechanism.
#   A9_PATCH_TREBLEAPP=1   Replace TrebleApp.apk + treble overlay. Both are
#                          pre-signed with the AOSP test key. me.phh.treble.app
#                          declares a sharedUserId, so on any other base this
#                          BOOTLOOPS with "Signature mismatch on system package
#                          me.phh.treble.app for shared user". TESTKEY ONLY.
#   A9_PATCH_VIBRATOR=0    Skip the haptics patch. DEFAULTS ON since 2026-08-13.
#                          It writes the A9's three LRA waveforms into vndk.rc
#                          and routes startVibrationLocked to them by
#                          VibrationAttributes usage. Turning it off also drops
#                          the waveforms, since add_pattern_to_initrc is called
#                          from patch_startVibrationLocked -- so "off" means no
#                          custom haptics at all.
#                          It was off 2026-08-11..13 after soft-rebooting the
#                          device on the first haptic. Cause was NOT a removed
#                          field: callerInfo was RETYPED (Vibration$CallerInfo
#                          -> VibrationSession$CallerInfo) and the parameter
#                          became SingleVibrationSession. Both are handled now.
#   BOTH COLORFADE GATES DEFAULT ON, and you almost always want both. They are
#   NOT alternatives -- despite the names, they do different halves of the job:
#
#   A9_PATCH_COLORFADE=0   Skip the shader list. This is what DRAWS mode 1: the
#                          96 SHADER_LIST variants and the moon/pause glyph,
#                          indexed by sys.linevibrator_type. Without it mode 1
#                          has nothing to render, so "static AOD" silently falls
#                          back to stock fade-to-black no matter what the app is
#                          set to. (Dropped by accident 2026-08-13; every build
#                          for a day was overlay-only and static looked broken.)
#   A9_DISABLE_COLORFADE=0 Skip the runtime switch. Despite the name this does
#                          not hard-disable anything: it rewrites every read of
#                          DisplayPowerController.mColorFadeEnabled to consult
#                          sys.linevibrator_type, so 96 means "overlay AOD, do
#                          not run ColorFade" and any real index means "run it".
#                          That is what makes the two modes switchable at all.
#
#   With both on, one image carries mode 1 and mode 2 and the app chooses at
#   runtime. With only PATCH, ColorFade always runs and the overlay AOD is
#   painted over. With only DISABLE, mode 1 has no shader to draw.
#
#   A9_PATCH_SERVICES=0    Skip services.jar entirely (stock framework).
#
# ------------------------------------------------------------- two AODs -----
#   mode 1  A9_PATCH_COLORFADE=1   + sys.linevibrator_type = a passthrough index
#           -> panel retains your last screen, with a small moon/pause glyph.
#              Passthrough indices (no fade to black/white):
#                moon  6 7 14 15 22 23 30 31 38 39 46 47
#                pause 54 55 62 63 70 71 78 79 86 87 94 95
#
#   mode 2  A9_DISABLE_COLORFADE=1 + doze enabled + a9service overlay AOD
#           -> panel shows the drawn clock / chess / battery / music screen.
#              ALSO needs, at runtime: doze_always_on=1, doze_enabled=1, the
#              phh aod_systemui overlay enabled, animator_duration_scale=1, and
#              "Refresh AOD after screen off" ON in the app.
#              In doze the display stays in a low-power ON state so
#              SurfaceFlinger keeps compositing; on a full screen-off it stops
#              before the overlay is drawn and the panel latches the old frame.
#
# ---------------------------------------------------------- re-signing ------
# Patching SystemUI.apk means repacking and re-signing it, and we do not hold
# the base GSI's platform key (LineageOS 23.2 builds are signed by crDroid).
# Previously that made A9_PATCH_SYSTEMUI testkey-bases-only. It no longer is.
#
# When any package is re-signed the patcher automatically also:
#   1. patches AppIdPermissionPolicy.shouldGrantPermissionBySignature in
#      services.jar to grant that package its signature permissions by NAME
#      rather than by certificate, and
#   2. adds A9_SIGN_CERT to /system/etc/selinux/plat_mac_permissions.xml with
#      seinfo="platform", so it stays in the platform_app SELinux domain.
# Both are required; the patcher refuses to build with A9_PATCH_SERVICES=0.
#
# The sharedUserId problem that makes TrebleApp fatal does NOT apply to
# SystemUI: it declares android.uid.systemui, not android.uid.system, and it is
# the only member of it.
#
#   A9_SIGN_KEY / A9_SIGN_CERT   default to this repo's AOSP platform TEST key.
#      Override with a private key. The test key's private half is published in
#      AOSP, so entering its certificate into plat_mac_permissions.xml would put
#      any APK signed with it into the platform SELinux domain.
#
#   A9_SIGN_KEY=/home/nixos/A9/keys/daniel.pk8 \
#   A9_SIGN_CERT=/home/nixos/A9/keys/daniel.x509.pem \
#   A9_PATCH_SYSTEMUI=1 ./tools/patch-gsi.sh base.img
#
set -euo pipefail

IMG="${1:?usage: patch-gsi.sh /path/to/system.img}"
[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 1; }
IMG="$(readlink -f "$IMG")"

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PATCHER="$REPO/app/external_scripts/system_img_patcher"
BIN="$REPO/tools/bin"
APKTOOL_VER="${APKTOOL_VER:-3.0.3}"

mkdir -p "$BIN"
if [ ! -f "$BIN/apktool.jar" ]; then
  echo "fetching apktool $APKTOOL_VER..."
  curl -sfL -o "$BIN/apktool.jar" \
    "https://github.com/iBotPeaches/Apktool/releases/download/v${APKTOOL_VER}/apktool_${APKTOOL_VER}.jar"
fi
if [ ! -x "$BIN/apktool" ]; then
  printf '#!/usr/bin/env bash\nexec java -jar "$(dirname "$(readlink -f "$0")")/apktool.jar" "$@"\n' > "$BIN/apktool"
  chmod +x "$BIN/apktool"
fi

for t in java python3 e2fsck resize2fs setfattr; do
  command -v "$t" >/dev/null || { echo "missing required tool: $t" >&2; exit 1; }
done

cd "$PATCHER"
sudo rm -rf TMP patch-report.json system_patched.img

# The patcher chdir's into TMP, so a relative key path would break. Absolutise
# whatever the caller gave us; the defaults are already TMP-relative ("../").
SIGN_KEY="${A9_SIGN_KEY:+$(readlink -f "$A9_SIGN_KEY")}"
SIGN_CERT="${A9_SIGN_CERT:+$(readlink -f "$A9_SIGN_CERT")}"

exec sudo env \
  PATH="$BIN:$PATH" \
  ${SIGN_KEY:+A9_SIGN_KEY="$SIGN_KEY"} \
  ${SIGN_CERT:+A9_SIGN_CERT="$SIGN_CERT"} \
  A9_PATCH_SYSTEMUI="${A9_PATCH_SYSTEMUI:-0}" \
  A9_SUI_SKIP="${A9_SUI_SKIP:-}" \
  A9_FORCE_RESIGN_SUPPORT="${A9_FORCE_RESIGN_SUPPORT:-}" \
  A9_RESIGN_ONLY="${A9_RESIGN_ONLY:-}" \
  A9_PATCH_DIALER="${A9_PATCH_DIALER:-0}" \
  A9_PATCH_TREBLEAPP="${A9_PATCH_TREBLEAPP:-0}" \
  A9_PATCH_VIBRATOR="${A9_PATCH_VIBRATOR:-1}" \
  A9_PATCH_COLORFADE="${A9_PATCH_COLORFADE:-1}" \
  A9_DISABLE_COLORFADE="${A9_DISABLE_COLORFADE:-1}" \
  A9_PATCH_TREBLE_OVERLAY="${A9_PATCH_TREBLE_OVERLAY:-1}" \
  A9_PATCH_SERVICES="${A9_PATCH_SERVICES:-1}" \
  python3 patch_system_img.py "$IMG"
