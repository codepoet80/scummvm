# ScummVM – WebOS Port (codepoet80 fork)

This is a personal fork of ScummVM that restores the WebOS backend
removed upstream in August 2020 (commit eaa86f93334). The active work
branch is **webos-2.2**, based on current master.

---

## Build environment

| Thing | Location |
|---|---|
| Source tree | `/home/jonwise/Projects/scummvm` |
| Build directory | `/home/jonwise/Projects/scummvm-webos-build` |
| WebOS PDK | `/opt/PalmPDK` |
| WebOS SDK | `/opt/PalmSDK/0.2` |
| Linaro GCC 4.9.4 | `~/Projects/qupzilla/toolchains/gcc-linaro/bin/` |
| IPK output | `scummvm-webos-build/portdist/org.scummvm.scummvm_*.ipk` |

**Always use the Linaro GCC 4.9.4 cross-compiler, never system GCC.**
The device has glibc 2.5 (max symbol GLIBC_2.4). GCC 5+ emits
GLIBC_2.17+ symbols (clock_gettime wrappers, strtol variants) that
crash at launch with "symbol not found." Linaro 4.9.4 stays clean.

Quick rebuild after a source change:

```sh
cd ~/Projects/scummvm-webos-build
make -j$(nproc)
make package
```

The configure invocation that produced the current config.mk:

```sh
export WEBOS_PDK=/opt/PalmPDK
export WEBOS_SDK=/opt/PalmSDK/0.2
cd ~/Projects/scummvm-webos-build
~/Projects/scummvm/configure \
  --host=webos --enable-plugins --default-dynamic --enable-release
# Then patch config.mk tool paths to full Linaro paths (see below)
```

After configure, `config.mk` tool names must be replaced with full
Linaro paths because the short names (arm-linux-gnueabi-g++) may
resolve to system GCC on the build host:

```
CXX  := .../gcc-linaro/bin/arm-linux-gnueabi-g++
AR   := .../gcc-linaro/bin/arm-linux-gnueabi-ar cr
LD   := .../gcc-linaro/bin/arm-linux-gnueabi-g++
NM   := .../gcc-linaro/bin/arm-linux-gnueabi-nm
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

**These changes are NOT present in 2.1.0 code and are the only logic
differences from the original port.** Everything else is identical to
the 2.1.0 WebOS backend.

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

**Works:**
- All ScummVM engines (current master, ~2026.x — more than 2.5.0)
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

## coordinate system notes

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
