# ScummVM – WebOS Port (codepoet80 fork)

This is a personal fork of ScummVM that restores the WebOS backend
removed upstream in August 2020 (commit eaa86f93334). The active work
branch is **webos-2.5**, based on ScummVM v2.5.0.

Branch history:
- **webos-2.2**: based on ScummVM master (2026.x), version 2.2.2026 — first
  working port. All 67–87 plugins load, touch input works on HP TouchPad.
- **webos-2.5**: based on ScummVM v2.5.0 tag — current branch. Same backend
  code as webos-2.2, tested working (67 plugins, launcher runs on device).

---

## Build environment

| Thing | Location |
|---|---|
| Source tree | `/home/jonwise/Projects/scummvm` |
| Build directory | `/home/jonwise/Projects/scummvm-webos25-build` |
| WebOS PDK | `/opt/PalmPDK` |
| WebOS SDK | `/opt/PalmSDK/0.2` |
| Linaro GCC 4.9.4 | `~/Projects/qupzilla/toolchains/gcc-linaro/bin/` |
| IPK output | `scummvm-webos25-build/portdist/org.scummvm.scummvm_*.ipk` |

**Always use the Linaro GCC 4.9.4 cross-compiler, never system GCC.**
The device has glibc ≤ 2.8 (conservative safe target: GLIBC_2.4).
GCC 5+ emits GLIBC_2.17+ / GLIBC_2.38+ symbols (__isoc23_strtol,
clock_gettime wrappers) that crash at launch. Linaro 4.9.4 stays clean.

**Pass Linaro toolchain via env to configure** so config.mk is generated
with the full paths directly (prevents Makefile reconfigure from reverting
to the system compiler):

Quick rebuild after a source change:

```sh
cd ~/Projects/scummvm-webos25-build
make -j$(nproc)
make package
```

The configure invocation that produced the current config.mk:

```sh
export WEBOS_PDK=/opt/PalmPDK
export WEBOS_SDK=/opt/PalmSDK/0.2
LINARO=~/Projects/qupzilla/toolchains/gcc-linaro/bin/arm-linux-gnueabi
cd ~/Projects/scummvm-webos25-build
CXX="$LINARO-g++" AR="$LINARO-ar cr" RANLIB="$LINARO-ranlib" \
  STRIP="$LINARO-strip" AS="$LINARO-as" \
  ~/Projects/scummvm/configure \
  --host=webos --enable-plugins --default-dynamic --enable-release
# Then remove stray host includes from CXXFLAGS in config.mk:
sed -i 's| -I/usr/include/freetype2 -I/usr/include/libpng16||g' config.mk
# Fix doubled AR (configure appends "cru" again):
sed -i 's|arm-linux-gnueabi-ar cr cru|arm-linux-gnueabi-ar cr|g' config.mk
```

Passing toolchain via env bakes the full Linaro paths into config.mk
directly. The Makefile re-runs configure when the configure script changes;
without env-var baking, the new config.mk would use the system GCC.

The stray `-I/usr/include/freetype2 -I/usr/include/libpng16` appear when
configure finds host freetype/libpng via `freetype-config` or `pkg-config`.
Those headers reference glibc 2.38+ symbols; they must be stripped.

```
CXX  := .../gcc-linaro/bin/arm-linux-gnueabi-g++
AR   := .../gcc-linaro/bin/arm-linux-gnueabi-ar cr
LD   := .../gcc-linaro/bin/arm-linux-gnueabi-g++
RANLIB := .../gcc-linaro/bin/arm-linux-gnueabi-ranlib
STRIP  := .../gcc-linaro/bin/arm-linux-gnueabi-strip
```

---

## Key files

| File | Purpose |
|---|---|
| `backends/events/webossdl/webossdl-events.cpp` | Touch input handling — the phantom-event fix lives here |
| `backends/events/webossdl/webossdl-events.h` | Event source class, constants (MOUSE_DEADZONE_PIXELS=5, QUEUED_DRAG_DELAY=500ms) |
| `backends/platform/webos/webos.cpp` | OSystem subclass; creates WebOSSdlEventSource |
| `backends/platform/webos/webos.mk` | Platform makefile fragment |
| `backends/platform/webos/webos.h` | OSystem_SDL_WebOS declaration |
| `backends/platform/webos/main.cpp` | Entry point; inits PDL and plugin provider |
| `dists/webos/README.WebOS` | User-facing build and controls documentation |
| `dists/webos/mojo/` | WebOS app manifest, icon, launcher script |
| `configure` | WebOS host section added around line 2000 |
| `backends/module.mk` | webossdl-events.o added for BACKEND=webos |
| `backends/platform/sdl/sdl-sys.h` | Undefs SDL_VIDEO_DRIVER_X11 for WEBOS (PDK header bug) |
| `backends/platform/sdl/posix/posix-main.cpp` | Excludes WEBOS from generic POSIX main |

---

## The phantom touch event problem (key discovery)

**Symptom:** In non-trackpad (direct-touch) mode, tapping a button
highlights it but the action never fires. In trackpad mode the cursor
drifts left and then slowly upward with no finger on screen.

**Root cause:** Aging Palm Pre hardware generates phantom complete touch
cycles — SDL_MOUSEBUTTONDOWN + SDL_MOUSEMOTION(s) + SDL_MOUSEBUTTONUP
for finger slot 0, with no actual finger present. Because
`_fingerDown[0]` is the guard for all finger-0 event processing:

1. The phantom BUTTONDOWN sets `_fingerDown[0]=true` and overwrites
   `_curX/_curY` with phantom coordinates.
2. The phantom MOTION events move the cursor (in trackpad mode) or
   corrupt `_curX/_curY` (in direct-touch mode).
3. The phantom BUTTONUP fires the "click" at the phantom position,
   which is not on any button.
4. When the real finger lifts, `_fingerDown[0]` is already false
   (cleared by the phantom BUTTONUP) so `handleMouseButtonUp` skips
   entirely.

**Fix** (in `webossdl-events.cpp` and `webossdl-events.h`):

```
handleMouseButtonDown:
  Save wasFingerDown before setting _fingerDown[which]=true.
  If (which==0 && wasFingerDown && _doClick):
    Set _phantomSequenceActive = true, then return false.
    This prevents phantom BUTTONDOWN from relocating _curX/_curY
    and arms the guard for subsequent phantom MOTION events.

handleMouseMotion (before _dragDiffX/Y accumulation):
  If (ev.motion.which==0 && _phantomSequenceActive): return false.
  This must happen BEFORE the accumulation step so phantom xrel
  never enters _dragDiffX/Y — if it did, it could exceed the deadzone
  and cancel _doClick (trackpad mode) or corrupt the drag total.

handleMouseMotion, case 0, direct-touch branch:
  If _doClick is true: return false (not break).
  Handles residual real-finger motion in direct-touch mode (phantom
  motion was already blocked above). Returning false discards cleanly;
  break returns true with a stale event.type from the previous iteration.

handleMouseMotion, case 0, _doClick cancellation:
  Gate on _trackpadMode only. In direct-touch mode the cursor snaps
  to absolute position; cumulative relative noise from phantom events
  must not cancel the pending click.

handleMouseButtonUp:
  When _fingerDown[which] is false (guard fails): return false, not true.
  The original 2.1.0 code always returned true here; this was harmless
  because the guard only failed after gesture handlers manually cleared
  _fingerDown. The phantom fix introduced a new common case: phantom
  BUTTONUP clears _fingerDown[0], so the real BUTTONUP always hits the
  guard. Without this fix, the stale event.type = EVENT_LBUTTONDOWN
  (left by the phantom BUTTONUP handler) was re-dispatched as a spurious
  unmatched press on every tap, accumulating N extra presses across N
  taps until the UI treated buttons as permanently held.
  After clearing _fingerDown[which], if which==0: also clear
  _phantomSequenceActive to end the phantom sequence guard.
```

The original 2.1.0 code had the same deadzone logic but worked because
the hardware was newer and generated less noise. The phantom-event
problem is a hardware aging issue; devices used since 2019 require
this hardening.

**NOTE: The HP TouchPad does NOT generate phantom events.** The
phantom-event fix code is present and correct but never activates on
TouchPad hardware (`_phantomSequenceActive` stays false).

---

## HP TouchPad–specific bugs (fixed in this port)

### 1. Stale event.type causes clicks to stop working after first tap

**Symptom:** First tap in the ScummVM launcher works; every subsequent
tap is ignored.

**Root cause:** `handleMouseButtonDown` contained the check
`if (event.type == Common::EVENT_LBUTTONDOWN)`, which was intended to
detect a double-tap drag that was just initiated within the same call.
But `event` is a reference passed down from the SDL event loop and is
never reset between events — so after `handleMouseButtonUp` returns
with `event.type = LBUTTONDOWN`, the next DOWN call immediately sees
the stale type as true. This pushes an extra orphaned `LBUTTONDOWN`
into the event queue on every tap after the first. After N taps, N-1
orphaned down-events accumulate and the GUI treats buttons as
permanently held.

**Fix:** Replace `if (event.type == Common::EVENT_LBUTTONDOWN)` with
`if (_dragging)`. `_dragging` is set to true only when a double-tap
drag was just triggered in this specific call path (non-autoDrag mode),
which is the intended guard condition. In auto-drag mode (the default),
`_dragging` is always false at this point, so the block correctly never
executes.

### 2. Accelerometer registered as joystick drives cursor drift

**Symptom:** In trackpad mode the cursor continuously drifts toward the
top-left corner with no finger on screen.

**Root cause:** The WebOS PDK registers the device accelerometer as
SDL joystick 0. `SdlEventSource`'s constructor opens joystick 0 by
default (`joystick_num=0` in config). The ScummVM keymapper converts
joystick axis events to virtual mouse movement, so gravity slowly
pushes the cursor toward the top-left corner.

**Fix:** `WebOSSdlEventSource()` constructor calls `closeJoystick()`
immediately after the base-class constructor runs. This closes the
accelerometer before it can send events. We will never want
accelerometer-as-joystick on WebOS.

### 3. Plugins failing with STB_GNU_UNIQUE symbols on glibc 2.5

**Symptom:** 10 plugins (scumm, sci, awe, director, grim, hadesch,
kyra, mtropolis, sword2, ultima) fail to load with undefined symbol
errors. 77 other plugins load fine.

**Root cause:** GCC 4.6+ emits `STB_GNU_UNIQUE` symbol binding (ELF
`u` type) for C++ static local variables. glibc's dynamic linker only
supports resolving `STB_GNU_UNIQUE` from glibc 2.11 onward. WebOS uses
glibc 2.5 — dlopen silently fails for any plugin containing `u` symbols.
The 10 failing engines used C++ static locals; the passing 77 did not.

**Fix:** Added `-fno-gnu-unique` to `CXXFLAGS` in config.mk. Forces
GCC to emit regular weak symbols instead. After adding the flag, delete
the affected engines' `.o` files and `.so` files and rebuild.

**Diagnosis command:**
```sh
arm-linux-gnueabi-nm plugins/lib<engine>.so | grep "^[0-9a-f]* u "
```
Zero `u` symbols = safe for glibc 2.5.

### 4. Plugins failing with __gnu_thumb1_case_* symbols

**Symptom:** All 87 plugins fail to load with `undefined symbol:
__gnu_thumb1_case_uqi` (and sqi, uhi, shi variants).

**Root cause:** Linaro GCC 4.9.4 generates Thumb1 switch-table dispatch
helpers from libgcc.a even in ARM mode with `-fpic`. These helpers are
statically linked into the main binary as LOCAL (`t`) symbols.
`-Wl,-export-dynamic` only exports GLOBAL symbols, so plugins cannot
resolve them from the main binary. The device's libgcc.so also lacks
them.

**Fix:** Add `-static-libgcc` to `PLUGIN_LDFLAGS` in config.mk. Each
plugin then embeds its own copy of the libgcc helpers.

**Note:** `make` does not relink plugins when `PLUGIN_LDFLAGS` changes
(no dependency). After changing PLUGIN_LDFLAGS, manually delete all
`plugins/*.so` and rebuild.

**These 4 fixes are NOT present in 2.1.0 code.** The phantom-event fix
applies to Palm Pre hardware; bugs 1–4 are TouchPad-specific.

---

## WebOS touch event model (SDL1 PDK)

- `SDL_MOUSEBUTTONDOWN/UP`: finger touch start/end; `ev.button.which`
  = finger slot (0, 1, 2 for up to 3 simultaneous touches)
- `SDL_MOUSEMOTION`: finger movement; `ev.motion.which` = finger slot
- `ev.motion.x/y`: absolute position in SDL surface coordinates
- `ev.motion.xrel/yrel`: relative motion from previous position
- `ev.button.x/y` and `ev.motion.x/y` alias the same byte offset in
  the SDL1 event union (verified from PDK SDL_events.h)
- `float ratioX, ratioY`: webOS PDK extension fields appended to both
  structs (not used by our code)

---

## What works / what doesn't

**Works (tested on HP TouchPad with webos-2.5 / ScummVM 2.5.0):**
- 67 engine plugins load and work (all from the v2.5.0 engine set)
- Dynamic plugin loading from /lib/*.so
- Direct-touch (default) and trackpad input modes
- All two-finger and three-finger gestures
- MIDI, PCM/WAV audio
- JPEG, freetype font rendering

**Does not work (not built):**
- OGG/Vorbis music: needs libtremor cross-compiled from PDK sysroot
- MP3 music: needs libmad
- FLAC: needs libFLAC
- Cloud/networking: needs libcurl
- OpenGL: not present in PDK

**Scoped but not implemented — audio codec addition:**
- ~13–22 hours: cross-compile libogg + libtremor + libmad (+ optionally
  libFLAC) against the PDK ARM sysroot using Linaro GCC 4.9.4, then
  enable USE_TREMOR/USE_MAD/USE_FLAC in configure and rebuild.
- Static linkage preferred (no extra .so files in IPK).
- See `dists/webos/README.WebOS` for full scope breakdown.

---

## Coordinate system notes

HP TouchPad screen: 1024×768 landscape. Same 4:3 aspect ratio as
ScummVM's default overlay, so the PDK scales the SDL surface to fill
the screen with no letterboxing.
SDL surface (for launcher): 640×480. Touch events from the PDK are in
SDL surface coordinates (0–639, 0–479). `_screenX=640, _screenY=480`.
`convertWindowToVirtual` is an identity transform (drawRect = overlay).

Palm Pre screen: 320×480 physical pixels (portrait).
ScummVM default scaleFactor=2 → 640×400 virtual overlay.
SDL surface: 640×400 (PDK scales to fit physical display).
Overlay draw rect: 320×200 area centered on 320×480 screen,
  with ~140px letterbox bands top and bottom.
convertWindowToVirtual: maps physical (0–319, 140–339) → virtual (0–639, 0–399).
Taps in the letterbox bands are clipped to the overlay boundary.

---

## Upstream notes

The upstream ScummVM project has AI contribution guidelines in
`AI-GUIDELINES.md`. This fork is a personal build; if submitting
upstream, remove the Co-Authored-By lines and follow their attribution
format (Assisted-by: Claude:claude-sonnet-4-6).
