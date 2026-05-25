# ScummVM WebOS Port — Build Guide and Porting Notes

This document describes how to build ScummVM for **HP webOS** (HP TouchPad,
Palm Pre, Palm Pixi, etc.) and how to forward-port the WebOS backend to a
new ScummVM release. It captures all hard-won lessons from the webos-2.2,
webos-2.5, and webos-2.6.1 porting efforts.

---

## Contents

1. [What this fork is](#what-this-fork-is)
2. [Branch history](#branch-history)
3. [Build environment requirements](#build-environment-requirements)
4. [Quick rebuild (source change only)](#quick-rebuild)
5. [Full build from scratch](#full-build-from-scratch)
6. [Forward-porting to a new ScummVM release](#forward-porting-to-a-new-scummvm-release)
7. [Known constraints and disabled features](#known-constraints-and-disabled-features)
8. [Device coordinate systems](#device-coordinate-systems)
9. [WebOS touch event model](#webos-touch-event-model)
10. [HP TouchPad bug fixes (not in upstream 2.1.0)](#hp-touchpad-bug-fixes)
11. [Palm Pre phantom-touch fix](#palm-pre-phantom-touch-fix)

---

## What this fork is

The official ScummVM project removed its WebOS backend in August 2020
(commit `eaa86f93334`). This fork (codepoet80) restores it, carrying forward
fixes for hardware quirks in aging webOS devices (HP TouchPad, Palm Pre).

The backend lives in:

| Path | Purpose |
|---|---|
| `backends/events/webossdl/` | Touch input handling |
| `backends/platform/webos/` | OSystem subclass, entry point, makefile |
| `dists/webos/` | App manifest, launcher script, icon, build script |

---

## Branch history

| Branch | Base | Plugins | Status |
|---|---|---|---|
| `webos-2.2` | ScummVM master (2026.x) | 87 | First working port; HP TouchPad + Palm Pre |
| `webos-2.5` | `v2.5.0` tag | 67 | Working; confirmed on HP TouchPad |
| `webos-2.6.1` | `v2.6.1` tag | 69 | Working; confirmed on HP TouchPad (**current**) |

---

## Build environment requirements

| Requirement | Location / notes |
|---|---|
| WebOS PDK | `/opt/PalmPDK` — ARM sysroot, SDL 1.2, freetype, PDL |
| WebOS SDK | `/opt/PalmSDK/0.2` — `palm-package`, `palm-install`, `palm-launch` |
| **Linaro GCC 4.9.4** cross-compiler | `~/Projects/qupzilla/toolchains/gcc-linaro/bin/` |
| `novacom` | In PATH — used to push/inspect device over USB |

### Why Linaro GCC 4.9.4 and not the system GCC?

The webOS device runs **glibc 2.5** (max versioned symbol: `GLIBC_2.4`).
GCC 5 and later generate references to newer glibc symbols that cause an
immediate crash at launch:

| Symbol | Introduced in | Effect |
|---|---|---|
| `__isoc23_strtol` | glibc 2.38 | Crash at startup |
| `clock_gettime` (wrapped) | glibc 2.17 | Crash at startup |
| `at_quick_exit`, `quick_exit` | glibc 2.10 | Link failure |
| C99 long-double math (`acoshl`, etc.) | glibc 2.1 | Compile failure with Linaro 4.9.4 `<cmath>` |

Linaro 4.9.4 targets the PDK's glibc 2.5 sysroot correctly and emits only
`GLIBC_2.4`-or-older versioned symbols.

### Critical: Linaro must be first on PATH

If the system also has `arm-linux-gnueabi-gcc` (e.g., from
`gcc-arm-linux-gnueabi`), the linker `collect2` may invoke the system
`arm-linux-gnueabi-ld` instead of Linaro's, contaminating the output.

```sh
export PATH=~/Projects/qupzilla/toolchains/gcc-linaro/bin:$PATH
```

Always set this before running `make`.

---

## Quick rebuild

After changing source files on an already-configured branch:

```sh
cd ~/Projects/scummvm-webos261-build          # or your build dir
export PATH=~/Projects/qupzilla/toolchains/gcc-linaro/bin:$PATH
make -j$(nproc)
make package
palm-install portdist/org.scummvm.scummvm_*.ipk
```

---

## Full build from scratch

```sh
BUILD_DIR=~/Projects/scummvm-webos261-build \
    ~/Projects/scummvm/dists/webos/build-package-webos.sh
```

The script:
1. Validates the PDK, SDK, and Linaro toolchain.
2. Runs `configure` (only if `config.mk` is stale) with all Linaro paths
   baked in via environment variables.
3. Applies two required `sed` patches to `config.mk` (see below).
4. Runs `make -j$(nproc)` and `make package`.

Override paths with environment variables:
```sh
WEBOS_PDK=/opt/PalmPDK \
WEBOS_SDK=/opt/PalmSDK/0.2 \
LINARO_BIN=~/Projects/qupzilla/toolchains/gcc-linaro/bin \
BUILD_DIR=~/Projects/scummvm-webos261-build \
    ~/Projects/scummvm/dists/webos/build-package-webos.sh
```

### Manual configure invocation

```sh
export WEBOS_PDK=/opt/PalmPDK
export WEBOS_SDK=/opt/PalmSDK/0.2
LINARO=~/Projects/qupzilla/toolchains/gcc-linaro/bin/arm-linux-gnueabi

cd ~/Projects/scummvm-webos261-build
CXX="$LINARO-g++" AR="$LINARO-ar cr" RANLIB="$LINARO-ranlib" \
    STRIP="$LINARO-strip" AS="$LINARO-as" \
    ~/Projects/scummvm/configure \
        --host=webos --enable-plugins --default-dynamic --enable-release

# Patch 1 — fix AR flag doubling (configure appends flags twice)
sed -i 's|arm-linux-gnueabi-ar cr cru|arm-linux-gnueabi-ar cr|g' config.mk
sed -i 's|arm-linux-gnueabi-ar cr cr|arm-linux-gnueabi-ar cr|g'  config.mk

# Patch 2 — strip stray host freetype/libpng include paths
# These point to the build machine's glibc 2.38 headers, not the PDK sysroot.
sed -i 's| -I/usr/include/freetype2 -I/usr/include/libpng[^ ]*||g' config.mk
sed -i 's| -I/usr/include/freetype2||g; s| -I/usr/include/libpng[^ ]*||g' config.mk
```

**Why pass toolchain via env vars?** `configure` bakes whatever compilers it
finds directly into `config.mk`. If you pass them as env vars, all paths are
absolute Linaro paths in `config.mk`. If you rely on PATH alone, the Makefile
re-runs `configure` when the script changes and the new `config.mk` picks up
whichever `arm-linux-gnueabi-g++` comes first — likely the system GCC 13.

---

## Forward-porting to a new ScummVM release

This is the step-by-step process used to port from `v2.5.0` → `v2.6.1`.
The same recipe applies for any future version.

### Step 1 — Create the branch

```sh
git checkout v2.X.Y -b webos-2.X.Y
```

### Step 2 — Try cherry-picking the prior branch's commits

```sh
git cherry-pick <oldest-webos-commit>..<newest-webos-commit>
```

In practice this has always produced conflicts in `configure`,
`posix-main.cpp`, `sdl-sys.h`, and `backends/module.mk` because those files
change between ScummVM releases. Abort the cherry-pick and do a manual port:

```sh
git cherry-pick --abort
```

### Step 3 — Copy the WebOS-specific files directly

These files are entirely WebOS-specific and copy clean every time:

```sh
git show webos-2.5:backends/events/webossdl/webossdl-events.cpp > backends/events/webossdl/webossdl-events.cpp
git show webos-2.5:backends/events/webossdl/webossdl-events.h   > backends/events/webossdl/webossdl-events.h
git show webos-2.5:backends/platform/webos/webos.cpp    > backends/platform/webos/webos.cpp
git show webos-2.5:backends/platform/webos/webos.h      > backends/platform/webos/webos.h
git show webos-2.5:backends/platform/webos/main.cpp     > backends/platform/webos/main.cpp
git show webos-2.5:backends/platform/webos/module.mk    > backends/platform/webos/module.mk
git show webos-2.5:backends/platform/webos/webos.mk     > backends/platform/webos/webos.mk
git show webos-2.5:dists/webos/                         # copy all files
```

Update `dists/webos/mojo/appinfo.json` — bump `"version"` to match the new release.

### Step 4 — Patch shared files

These four files require targeted patches each time.

#### `backends/module.mk`

Add after the `openpandora` block:

```makefile
ifeq ($(BACKEND),webos)
MODULE_OBJS += \
	events/webossdl/webossdl-events.o
endif
```

#### `backends/platform/sdl/posix/posix-main.cpp`

Add `!defined(WEBOS)` to the `#if` guard:

```cpp
// Find the line:
#if defined(POSIX) && !defined(MACOSX) && ... && !defined(NINTENDO_SWITCH) ...
// Add !defined(WEBOS) anywhere in the condition
```

#### `backends/platform/sdl/sdl-sys.h`

Add before `#include <SDL_syswm.h>`:

```cpp
// The WebOS PDK SDL_config.h incorrectly defines SDL_VIDEO_DRIVER_X11 (it was
// generated on a desktop Linux host). Undo that so SDL_syswm.h doesn't try to
// pull in X11/Xlib.h, which is not present in the WebOS device sysroot.
#ifdef WEBOS
#undef SDL_VIDEO_DRIVER_X11
#endif
```

#### `po/POTFILES`

Add after the `openpandora` entry:

```
backends/events/webossdl/webossdl-events.cpp
```

### Step 5 — Patch `configure`

Add WebOS support in each of the following locations. The exact line numbers
shift between releases; search for the anchor patterns shown.

#### 5a. Host detection (after `raspberrypi)` case)

```sh
webos)
	_host_os=webos
	_host_cpu=arm
	_host_alias=arm-linux-gnueabi
	test "x$prefix" = xNONE && prefix=/media/cryptofs/apps/usr/palm/applications/org.scummvm.scummvm
	datarootdir='${prefix}/data'
	datadir='${datarootdir}'
	docdir='${prefix}/doc'
	;;
```

#### 5b. Sanity checks (after `riscos)` case, before `*)`)

```sh
webos)
	if test -z "$WEBOS_SDK"; then
		echo "Please set WEBOS_SDK in your environment."
		exit 1
	fi
	if test -z "$WEBOS_PDK"; then
		echo "Please set WEBOS_PDK in your environment."
		exit 1
	fi
	;;
```

#### 5c. GNU extensions / pedantic check

WebOS PDK SDL1 headers use GNU extensions that cause compile errors under
`-std=c++11`. Add to the `std_variant` case:

```sh
webos)
	std_variant=gnu++
	pedantic=no
	;;
```

#### 5d. Host-specific CXXFLAGS/LDFLAGS (in the large nested `case $_host_os` block)

Add before `solaris*)`:

```sh
webos)
	_optimization_level=-O2
	append_var CXXFLAGS "--sysroot=$WEBOS_PDK/arm-gcc/sysroot"
	append_var CXXFLAGS "-I$WEBOS_PDK/include"
	append_var CXXFLAGS "-I$WEBOS_PDK/include/SDL"
	append_var CXXFLAGS "-I$WEBOS_PDK/arm-gcc/sysroot/usr/include"
	append_var CXXFLAGS "-I$WEBOS_SDK/include"
	append_var CXXFLAGS "-I$WEBOS_PDK/include/freetype2"
	append_var CXXFLAGS "-I$WEBOS_PDK/device/usr/include"
	append_var CXXFLAGS "-march=armv7-a -mfloat-abi=softfp -mfpu=neon -ffast-math"
	append_var CXXFLAGS "-fno-gnu-unique"
	append_var LDFLAGS "-Wl,-rpath-link,$WEBOS_PDK/device/lib"
	append_var LDFLAGS "-L$WEBOS_PDK/device/lib -L$WEBOS_PDK/device/usr/lib"
	append_var LDFLAGS "--sysroot=$WEBOS_PDK/arm-gcc/sysroot"
	append_var LIBS "-lSDL_net -lSDL -lpthread -lpdl -ldl -lm"
	append_var DEFINES "-DSDL_BACKEND"
	add_line_to_config_mk "SDL_BACKEND = 1"
	add_line_to_config_mk "WEBOS_SDK = $WEBOS_SDK"
	add_line_to_config_mk "SDL_NET_MAJOR = 1"
	add_line_to_config_mk "WITHOUT_SDL = 1"
	add_line_to_config_mk "USE_SDL_NET = 1"
	_backend="webos"
	_port_mk="backends/platform/webos/webos.mk"
	_vkeybd=yes
	_sdl=no
	_sdlnet=no
	# MT32EMU uses C99 long-double math (acoshl, etc.) absent in glibc 2.5
	_mt32emu=no
	if test "$_dynamic_modules" = yes; then
		_plugins_default=dynamic
	fi
	;;
```

> **Note on `-DSDL_BACKEND`:** WebOS skips SDL auto-detection (`_sdl=no`),
> so `SDL_BACKEND` is never set by the normal SDL detection path. It must be
> added explicitly here. Without it, `SDLPluginProvider` is not declared and
> the build fails with "expected type-specifier before 'SDLPluginProvider'".

> **Note on `_mt32emu=no`:** MT32EMU in ScummVM 2.6.x pulls in `<cmath>` and
> `<cstdlib>`, which reference C99 long-double functions (`acoshl`,
> `at_quick_exit`, etc.) that Linaro 4.9.4's libstdc++ headers declare as
> `using ::acoshl` — but these don't exist in the PDK sysroot's glibc 2.5.
> Disable MT32EMU to avoid compile failures.

#### 5e. 16-bit color support list

Add `webos` to the backend list:

```sh
3ds | android | ... | switch | webos | wii)
```

#### 5f. Backend DEFINES (add before the closing `*)` in `case $_backend`)

```sh
webos)
	append_var DEFINES "-DWEBOS"
	append_var MODULES "backends/platform/sdl"
	_sdl=no
	;;
```

#### 5g. POSIX compliance list

Add `webos` to the `_posix=yes` host_os list:

```sh
3ds | android | beos* | ... | uclinux* | webos)
	_posix=yes
	;;
```

#### 5h. Dynamic plugins (add before the closing `*)` that sets `_dynamic_modules=no`)

```sh
webos)
	_plugin_prefix="lib"
	_plugin_suffix=".so"
	append_var CXXFLAGS "-fPIC"
	append_var LIBS "-ldl"
_mak_plugins='
PLUGIN_EXTRA_DEPS =
PLUGIN_LDFLAGS  += -shared -static-libgcc
PRE_OBJS_FLAGS  := -Wl,-export-dynamic -Wl,-whole-archive
POST_OBJS_FLAGS := -Wl,-no-whole-archive
'
	;;
```

> **Note on `-static-libgcc`:** Linaro GCC 4.9.4 generates Thumb1
> switch-table helpers (`__gnu_thumb1_case_uqi`, etc.) from libgcc.a even in
> ARM mode with `-fpic`. These are statically linked into the main binary as
> LOCAL symbols. `-Wl,-export-dynamic` only exports GLOBAL symbols, so
> plugins can't resolve them from the main binary. `-static-libgcc` embeds a
> copy in each plugin instead.

#### 5i. PLUGIN_DIRECTORY (add before the closing `*)`)

```sh
webos)
	append_var DEFINES "-DPLUGIN_DIRECTORY=\\\"$libdir\\\""
	;;
```

### Step 6 — Commit and configure

```sh
git add -A
git commit -m "WEBOS: Restore WebOS backend port, updated for vX.Y.Z"
```

Then configure (see [Manual configure invocation](#manual-configure-invocation))
and apply the two `sed` patches to `config.mk`.

### Step 7 — Build and iterate

```sh
export PATH=~/Projects/qupzilla/toolchains/gcc-linaro/bin:$PATH
make -j$(nproc) 2>&1 | grep -E '^.*error:' | sort -u | head -20
```

New compile errors between ScummVM versions tend to fall into one of these
categories — see the [troubleshooting table](#common-forward-port-errors) below.

### Step 8 — Verify symbol cleanliness

```sh
NM=~/Projects/qupzilla/toolchains/gcc-linaro/bin/arm-linux-gnueabi-nm

# No GLIBC symbols beyond 2.4
$NM scummvm | grep '@GLIBC_' | grep -v '@GLIBC_2\.[0-4]"'   # should be empty

# No STB_GNU_UNIQUE (would fail on glibc < 2.11)
$NM scummvm | grep "^[0-9a-f]* u "                           # should be empty

# No unresolved __gnu_thumb1_case_* (Thumb1 helper symbols)
$NM plugins/libscumm.so | grep '__gnu_thumb1'                 # should be empty
```

### Step 9 — Install on device and verify

```sh
make package
palm-install portdist/org.scummvm.scummvm_*.ipk
palm-launch org.scummvm.scummvm
```

Check the device system log to confirm the process is running:

```sh
novacom run file:///bin/grep scumm /var/log/messages
```

Look for `powerlog:` lines showing `scummvm|<PID>|<CPU%>` to confirm the
process is alive and rendering.

---

## Common forward-port errors

| Error | Root cause | Fix |
|---|---|---|
| `expected type-specifier before 'SDLPluginProvider'` | `SDL_BACKEND` not defined — WebOS skips SDL auto-detect | Add `-DSDL_BACKEND` and `SDL_BACKEND = 1` to configure webos host section |
| `portdefs.h: No such file or directory` | `-DNONSTANDARD_PORT` was added (copied from another backend) | Remove it; WebOS uses the SDL code path, not a custom port |
| `cannot find -lPDL` | PDK library is lowercase `pdl` | Use `-lpdl` not `-lPDL` |
| `ar: illegal option -- cru` or doubled flags | `configure` appends AR flags twice when AR is passed via env | `sed -i 's|ar cr cr|ar cr|g'` and `sed -i 's|ar cr cru|ar cr|g'` on `config.mk` |
| `-I/usr/include/freetype2` in CXXFLAGS | `configure` finds host system freetype via `pkg-config` | Strip with `sed` post-configure (see build script) |
| `__isoc23_strtol` / `clock_gettime` undefined | System GCC 13 was used instead of Linaro 4.9.4 | Ensure `PATH` puts Linaro first; pass toolchain via env vars to `configure` |
| `::acoshl has not been declared` / `::at_quick_exit` | New engine (e.g. MT32EMU) uses C99 long-double math absent in glibc 2.5 sysroot | Add `_<feature>=no` to the webos configure section |
| All plugins fail: `undefined symbol: __gnu_thumb1_case_uqi` | Linaro emits Thumb1 helpers as LOCAL symbols; plugins can't resolve them | Add `-static-libgcc` to `PLUGIN_LDFLAGS` in dynamic plugin section |
| 10+ plugins fail: `undefined symbol` with `STB_GNU_UNIQUE` | GCC 4.6+ emits `u`-type ELF symbols; glibc's dynamic linker only resolves them from glibc ≥ 2.11 | Add `-fno-gnu-unique` to `CXXFLAGS` in configure webos host section |

---

## Known constraints and disabled features

| Feature | Status | Reason |
|---|---|---|
| OGG/Vorbis (libtremor) | ❌ Not built | Needs cross-compile against PDK sysroot |
| MP3 (libmad) | ❌ Not built | Needs cross-compile against PDK sysroot |
| FLAC | ❌ Not built | Needs cross-compile against PDK sysroot |
| Cloud / networking (libcurl) | ❌ Not built | Needs cross-compile against PDK sysroot |
| OpenGL / GLES2 | ❌ Not available | Not in WebOS PDK; TinyGL is used instead |
| MT32EMU (2.6.x+) | ❌ Disabled | Uses C99 long-double math absent in glibc 2.5 |
| Nancy Drew engine | ❌ Skipped | Requires Vorbis |
| Playground3D / Stark / Wintermute | ❌ Skipped | Require OpenGL shaders |

---

## Device coordinate systems

### HP TouchPad

- Physical screen: 1024×768 landscape
- SDL surface: 640×480 (PDK scales to fill — no letterboxing)
- Touch events from PDK are in SDL surface coordinates (0–639, 0–479)
- `convertWindowToVirtual` is an identity transform

### Palm Pre

- Physical screen: 320×480 portrait
- ScummVM scaleFactor=2 → 640×400 virtual overlay
- SDL surface: 640×400 (PDK scales to fit physical display)
- Overlay drawn in a 320×200 rect centered on the 480px height, with ~140px
  letterbox bands top and bottom
- `convertWindowToVirtual` maps physical (0–319, 140–339) → virtual (0–639, 0–399)

---

## WebOS touch event model

WebOS uses SDL 1.2 (PDK) with extensions:

- `SDL_MOUSEBUTTONDOWN` / `UP`: finger touch start/end; `ev.button.which` = finger slot (0–2)
- `SDL_MOUSEMOTION`: finger movement; `ev.motion.which` = finger slot
- `ev.motion.x/y`: absolute position in SDL surface coordinates
- `ev.motion.xrel/yrel`: relative motion from previous position
- `ev.button.x/y` and `ev.motion.x/y` alias the same offset in the SDL1 event union
- `float ratioX, ratioY`: PDK extension fields appended to both structs (unused)

---

## HP TouchPad bug fixes

These bugs exist in aging HP TouchPad hardware and are not present in the
original 2.1.0 WebOS port (which only targeted Palm Pre).

### 1. Stale `event.type` — clicks stop working after the first tap

**Symptom:** First tap works; every subsequent tap is ignored.

**Root cause:** `handleMouseButtonDown` checked
`if (event.type == Common::EVENT_LBUTTONDOWN)` to detect a double-tap drag
started in the same call. But `event` is a reference never reset between
events — after `handleMouseButtonUp` returns with `event.type = LBUTTONDOWN`,
the next DOWN call sees the stale type immediately, injecting an orphaned
`LBUTTONDOWN` on every tap after the first.

**Fix:** Replace the check with `if (_dragging)`. `_dragging` is only true
when a double-tap drag was just triggered in this exact call path.

### 2. Accelerometer drives cursor drift

**Symptom:** In trackpad mode the cursor drifts toward the top-left corner
with no finger on screen.

**Root cause:** The PDK registers the accelerometer as SDL joystick 0.
ScummVM's keymapper converts joystick axis events to virtual mouse movement;
gravity slowly pushes the cursor upward and left.

**Fix:** `WebOSSdlEventSource()` constructor calls `closeJoystick()`
immediately after the base class constructor, before any events arrive.

### 3. STB_GNU_UNIQUE symbols crash plugins on glibc 2.5

**Symptom:** ~10 plugins fail to load with undefined symbol errors.

**Root cause:** GCC 4.6+ emits `STB_GNU_UNIQUE` (`u`-type) bindings for
C++ static local variables. glibc's dynamic linker only supports resolving
these from glibc ≥ 2.11. Affected plugins silently fail at `dlopen`.

**Fix:** Add `-fno-gnu-unique` to `CXXFLAGS`. Forces regular weak symbols.

**Diagnosis:**
```sh
arm-linux-gnueabi-nm plugins/lib<engine>.so | grep "^[0-9a-f]* u "
```

### 4. `__gnu_thumb1_case_*` symbols missing from plugins

**Symptom:** All plugins fail with `undefined symbol: __gnu_thumb1_case_uqi`.

**Root cause:** Linaro GCC 4.9.4 generates Thumb1 switch-table helpers from
`libgcc.a` even in ARM mode with `-fpic`. These are linked into the main
binary as LOCAL symbols; plugins can't resolve them.

**Fix:** Add `-static-libgcc` to `PLUGIN_LDFLAGS`. Each plugin embeds its
own copy.

> **Note:** `make` does not relink plugins when only `PLUGIN_LDFLAGS` changes.
> After adding the flag, delete `plugins/*.so` and rebuild.

---

## Palm Pre phantom-touch fix

**Symptom:** In direct-touch mode, tapping a button highlights it but the
action never fires. In trackpad mode the cursor drifts left then slowly
upward with no finger on screen.

**Root cause:** Aging Palm Pre hardware generates phantom complete touch
cycles — `SDL_MOUSEBUTTONDOWN` + `SDL_MOUSEMOTION` + `SDL_MOUSEBUTTONUP`
for finger slot 0 with no actual finger present. Because `_fingerDown[0]`
is the guard for all slot-0 event processing:

1. The phantom `BUTTONDOWN` sets `_fingerDown[0]=true` and overwrites cursor position.
2. Phantom `MOTION` events move the cursor (trackpad) or corrupt coordinates (direct-touch).
3. Phantom `BUTTONUP` fires a click at the wrong position.
4. The real `BUTTONUP`, when it arrives, finds `_fingerDown[0]` already false and is skipped.

**Fix summary** (see `webossdl-events.cpp` for full implementation):

- `handleMouseButtonDown`: if slot 0 was already down when this DOWN arrives,
  set `_phantomSequenceActive = true` and return `false` (discard the phantom).
- `handleMouseMotion`: if `_phantomSequenceActive` and slot 0, return `false`
  **before** any `xrel/yrel` accumulation — phantom motion must never enter
  the drag delta or it can cancel a pending click.
- `handleMouseMotion`, trackpad deadzone cancellation: gate on `_trackpadMode`
  only; direct-touch uses absolute coordinates and must not cancel clicks on
  cumulative relative noise.
- `handleMouseMotion`, direct-touch branch: return `false` (not `break`) when
  `_doClick` is true — `break` re-dispatches a stale `event.type`.
- `handleMouseButtonUp`: when the guard `_fingerDown[which]` is already false,
  return `false` not `true`. Returning `true` re-dispatches the stale
  `event.type` as a spurious `LBUTTONDOWN` on every tap.

> **HP TouchPad note:** The TouchPad does **not** generate phantom events.
> All phantom-fix code is present and correct but `_phantomSequenceActive`
> stays false on TouchPad hardware.
