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

App settings: "Disable Overlay AOD" **ON**.

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

App settings: "Disable Overlay AOD" **OFF**, "Chess AOD" **ON**,
**"Refresh AOD after screen off" ON** — that one sends `FORCE_CLEAR` 150 ms
after screen-off so the EPD takes a new frame. Its XML `defaultValue="true"`
never applies, because the code reads it with a `false` default until the
settings screen has been opened, so on a fresh install it is effectively OFF.

If you flip only `debug.a9.colorfade` and leave doze on, you get **stock
Android's AOD** (black background, corner clock, notification icons) — wrong on
E Ink. Change both together.

### switching

```sh
setprop debug.a9.colorfade 1   # + doze off  -> mode 1
setprop debug.a9.colorfade 0   # + doze on   -> mode 2
```

`debug.*` is used because SELinux lets a plain adb shell write it;
`sys.*` and `persist.sys.*` are both denied. It does not survive a reboot —
`tools/finalize-image.sh` bakes the boot default into `vndk.rc` (4th argument).

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
