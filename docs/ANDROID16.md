# Android 16 on the Hisense A9 — patching notes

Measured on **Doze-off LineageOS 23.2 (A16 QPR2, SDK 36)** on a Hisense A9
(HLTE556N) with its stock **Android 11** vendor. Everything here is from a live
device unless labelled otherwise.

---

## Quick start

```sh
# mode 2 (drawn overlay AOD: clock / chess / battery / music)
A9_PATCH_COLORFADE=1 A9_DISABLE_COLORFADE=1 \
  ./tools/patch-gsi.sh /path/to/system.img
./tools/finalize-image.sh out.img 47 /path/to/a9_eink_server 0

adb reboot fastboot && fastboot flash system out.img && fastboot reboot
```

Build with **both** ColorFade flags and the image carries both AOD modes,
switchable at runtime (below).

---

## The two AODs

E Ink retains its last image at zero power. "AOD" therefore means *what image is
left on the glass* — nothing is drawn continuously. There are two completely
different ways to control that, and they need **opposite sleep behaviour**.

### mode 1 — static AOD: retain the last screen

`debug.a9.colorfade=1`, **doze OFF** (`doze_always_on=0`, `doze_enabled=0`).

ColorFade screenshots the display when screen-off begins and renders it through
one of 96 baked-in shader variants; that painted frame is the last thing drawn,
so the panel latches it.

Index comes from `sys.linevibrator_type`, which **the app sets** via the
daemon's `stl` command (so configure it in E-Ink Settings, not with setprop):

```
index = shape(0 moon | 48 pause)
      + size(0 large | 24 small)
      + glyph opacity(0 opaque | 8 semi | 16 transparent)
      + bg opacity(0 opaque | 2 semi-opaque | 4 semi-transparent | 6 transparent)
      + colour(0 white | 1 black)
```

**Only `bg = 6` is passthrough** (last screen visible). Everything else
deliberately fades the panel to black or white. Passthrough indices:

```
moon  :  6  7 14 15 22 23 30 31 38 39 46 47
pause : 54 55 62 63 70 71 78 79 86 87 94 95
```

Gotcha: index 22 draws a *white, nearly transparent* glyph — invisible on a
white E Ink screen. Use **Black Logo on White Background** + **Opaque** icon
opacity (index 7) to actually see it.

Selected by: "Disable Overlay AOD" **ON** (the app then sends the real
shader index, re-enabling ColorFade, and turns doze off).

### mode 2 — overlay AOD: clock / chess / battery / music

`debug.a9.colorfade=0`, **doze ON** (`doze_always_on=1`, `doze_enabled=1`,
`me.phh.treble.overlay.misc.aod_systemui` enabled).

a9service draws a `TYPE_ACCESSIBILITY_OVERLAY` on `ACTION_SCREEN_OFF`. Two
non-obvious requirements:

1. **ColorFade must be off.** It snapshots the display *before* the overlay
   becomes visible (the broadcast reaches apps in parallel with the transition),
   so the panel latches the snapshot — your last app screen — not the overlay.
2. **The device must DOZE, not sleep.** In doze the display stays in a
   low-power ON state and SurfaceFlinger keeps compositing, so the overlay
   reaches the panel. On a full screen-off, compositing stops before the
   overlay is drawn. This was the single hardest thing to find.

Selected by: "Disable Overlay AOD" **OFF** (the app then sends sentinel 96,
disabling ColorFade, and turns doze on). Also set "Chess AOD" **ON**,
**"Refresh AOD after screen off" ON** — that one sends `FORCE_CLEAR` 150 ms
after screen-off so the EPD takes a new frame. Its XML `defaultValue="true"`
never applies, because the code reads it with a `false` default until the
settings screen has been opened, so on a fresh install it is effectively OFF.

If doze is left on while ColorFade is enabled you get **stock Android's AOD**
(black background, corner clock, notification icons) — wrong on E Ink. The app
toggle handles this; only the manual `setprop` path can get it wrong.

### switching

**Use the app: E-Ink Settings -> Overlay AOD -> "Disable Overlay AOD".**

    OFF -> mode 2 (overlay: clock / chess / battery / music)
    ON  -> mode 1 (static: last screen + moon/pause glyph)

That one toggle drives all three things a mode change needs:

| | how |
|---|---|
| the app's overlay | directly |
| doze vs full sleep | the app holds `WRITE_SECURE_SETTINGS` (it is in priv-app) and writes `doze_always_on` / `doze_enabled` |
| ColorFade | apps cannot `setprop`, but the daemon can, and `stl<n>` already is a property write. The app sends **sentinel 96** — one past the 96-entry SHADER_LIST — which the patched `a9ColorFadeEnabled()` reads as "do not run ColorFade" |

Debug override, when you want to force one mode regardless of the app:

```sh
adb shell setprop debug.a9.colorfade 1    # force ColorFade on
adb shell setprop debug.a9.colorfade 0    # force ColorFade off
adb shell setprop debug.a9.colorfade ""   # release; app drives again
```

The helper is `SystemProperties.getBoolean("debug.a9.colorfade", <sentinel>)`,
so an explicitly-set value **always wins**. That is why
`tools/finalize-image.sh` must NOT bake this property into `vndk.rc` — doing so
pins the mode and the in-app toggle stops working. Its 4th argument defaults to
empty for exactly this reason; set the boot state with the shader index instead
(pass **96** when mode 2 is the normal state, so the first screen-off after a
flash is already correct).

---

## Feature gates

| Gate | Default | Notes |
|---|---|---|
| `A9_PATCH_SYSTEMUI` | 0 | Re-signs SystemUI. **Testkey-signed bases only.** |
| `A9_PATCH_DIALER` | 0 | Same restriction. |
| `A9_PATCH_TREBLEAPP` | 0 | Ships a **pre-signed** TrebleApp. `me.phh.treble.app` has a sharedUserId, so on any other base this **bootloops**: `IllegalStateException: Signature mismatch on system package me.phh.treble.app for shared user` in `initSystemApps`. |
| `A9_PATCH_VIBRATOR` | 0 | **Broken on A16.** Emits `Vibration->callerInfo`, removed in A16. Boots, then the first haptic (opening the app drawer) throws `NoSuchFieldError` in system_server and soft-reboots. |
| `A9_PATCH_COLORFADE` | 0 | Bakes the 96-variant SHADER_LIST (mode 1). |
| `A9_DISABLE_COLORFADE` | 0 | Routes `mColorFadeEnabled` through `debug.a9.colorfade`. |
| `A9_PATCH_SERVICES` | 1 | 0 = stock framework. |

---

## Toolchain

**apktool 3.x is required.** 2.10.0 maps `-api N` onto a dex version and
overflows at api 36 (`dexVersion must be within [0, 999]`). 3.x removed `-api`
entirely — the dex version comes from the input, which is correct — and renamed
`-c` to `--copy-original`. Passing the old flags makes apktool print usage and
exit 1, which surfaces only as "returned non-zero exit status 1".

`tools/patch-gsi.sh` bootstraps the right version automatically.

**Injected `invoke-*` / `move` must respect register width.**
`get_n_free_registers()` returns whatever is free, frequently above v15, but
`invoke-static {vA, vB}` and `move vA, vB` encode registers in 4 bits:
`Invalid register: v17. Must be between v0 and v15, inclusive.` It can also hand
back the destination register itself (`move v7, v7`). Route through a
**zero-argument static helper** instead — `invoke-static {}` needs no registers
and `move-result vAA` is 8-bit. See `add_a9ColorFadeEnabled_helper`.

---

## Other traps

**app / daemon pairing.** Mixing generations degrades silently — same socket
name (`a9_eink_socket`), no error, features just stop working:

| a9service | a9_eink_server | |
|---|---|---|
| v1.4.1 | **47,224** (May 2024) | no `smb`, `stl`, `wov` |
| v3.x | **43,216** (Sept 2024) | full set |

Running v3.x against the May daemon breaks the brightness/temperature slider
(`smb` absent) and pins the shader index (`stl` absent).

**A screen lock delays the whole service after every reboot.** With a PIN or
fingerprint set, user 0 stays credential-locked until you authenticate, and
Android will not run non-`directBootAware` apps in that state. Until the first
unlock: a9service does not start, the accessibility service never binds
(`dumpsys accessibility` shows `Bound services:{}` while still listing it under
Enabled), `am start` reports "Activity class ... does not exist", and `/sdcard`
is not writable. So AOD, refresh modes and the e-ink button all appear broken,
and it looks exactly like a bad build. The tell is
`Failed to find provider info for ... (user not unlocked)` in logcat.
Nothing to fix in the ROM -- but marking the service `directBootAware` would be
a legitimate improvement.

**`unshare_blocks` is mandatory.** GSIs ship deduplicated blocks;
`mount -o loop,rw` fails outright until `e2fsck -E unshare_blocks` has run.

**`vndk.rc` re-disables doze after a `/data` wipe** via a one-shot guarded by
`/data/local/tmp/disable_ambient_display`, silently breaking mode 2.

**64-bit Vulkan does not exist on this device.** `/vendor/lib/hw/vulkan.adreno.so`
is 32-bit only; there is no `lib64` equivalent and `ro.hardware.vulkan` is empty.
No GSI choice fixes it. GLES 3.2 works normally.

**Signing.** This fork signs with its own key (`keys/daniel.x509.pem`), which
differs from upstream `CN=Damian`. Builds therefore cannot be installed over a
Damian-signed install (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`), and dropping one
into `/system/priv-app` on a device whose `/data` still records the old
signature makes PackageManager reject it. Ship it in the image **and wipe
`/data`**, or change `applicationId`.
