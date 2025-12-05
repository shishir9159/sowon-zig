# sowon-zig

A Windows-first port of [sowon](https://github.com/tsoding/sowon) to pure Zig —
grown into a focus timer. The stylized digits are the original sprite sheet
(embedded, no asset files); the end-of-timer chime is synthesized at startup;
sessions are logged to SQLite; and an optional Chrome
extension can break Chrome time down by tab group and site.

No C dependencies and no vendored libraries: SQLite is the copy Windows already
ships (`winsqlite3.dll`, loaded at runtime), and rendering uses Win32/GDI.

## Build

Requires **Zig 0.16**.

```powershell
cd sowon-zig
zig build -Doptimize=ReleaseSafe
.\zig-out\bin\sowon.exe 25m -r 4 -b 5m -t deep-work -m "Stretch!" -a Code.exe -a ziglang.org -n 40s --top
```

Build options:

| Option | Meaning |
| --- | --- |
| `-Drenderer=gdi\|opengl\|spirv\|sdl\|glfw` | Rendering backend to compile in. Only the selected backend is compiled. `gdi` is complete; `spirv` has working shaders but no Vulkan host layer yet (see below); the rest are compile-checked stubs. |
| `-Dshader-backend=none\|zig` | Shader toolchain. `zig` compiles the shaders with the Zig compiler itself; it is the default for `-Drenderer=spirv`. Rejected with `gdi`. |
| `SOWON_SAMPLE_INTERVAL=<seconds>` (env var) | Foreground-app sampling interval, baked in at build time. Default `10`. |

## Tests

```powershell
zig build test
```

Covers the modules that run headless:

| Module | What is tested |
| --- | --- |
| `src/util.zig` | duration parsing, duration formatting, allow-list matching |
| `src/server.zig` | HTTP request framing, gRPC-Web frames, protobuf decoding, UTF-8 truncation, focus-snapshot formatting |
| `src/chime.zig` | RIFF/WAV header correctness, sample counts, normalisation without clipping |
| `src/digits.zig` | sprite-atlas tint + premultiplied-alpha maths |

`main.zig` and the renderers need a live window, so they are exercised by
running the app rather than by unit tests. The browser extension has its own
suite in `bell-bearer/tests/` (open `tests/index.html` in Chrome).

The protobuf `FocusUpdate` wire format is pinned from **both** sides: the Zig
`decodeFocusUpdate` test and the extension's `encodeFocusUpdateFrame` test
assert the same byte sequence, so the two halves cannot drift apart silently.

## SPIR-V renderer

`-Drenderer=spirv` selects a Vulkan backend whose shaders are written **in Zig**
([src/render/shaders/sprite.zig](src/render/shaders/sprite.zig)) and compiled to
SPIR-V by the Zig compiler itself:

```powershell
zig build -Drenderer=spirv
```

That produces a real Vulkan SPIR-V module — both entry points in one binary,
with `BuiltIn Position` / `BuiltIn VertexIndex`, `Location` varyings, and
`DescriptorSet`/`Binding` for the glyph atlas. The module is embedded in the
executable and its magic number is asserted at compile time, so a broken shader
toolchain fails the build instead of showing a black window.

**Status:** the shader half is done and verified. The Vulkan *host* layer
(instance, surface, swapchain, pipeline, command buffers, atlas upload) is not
written yet, so running a `spirv` build prints a clear message and exits. Use
`-Drenderer=gdi` for day-to-day use.

### Dev dependencies for SPIR-V

The short version: **you do not need the Vulkan SDK to build.**

| Requirement | Needed for | How to get it |
| --- | --- | --- |
| Zig 0.16 | Compiling the shaders to SPIR-V | Already required to build sowon |
| GPU driver with Vulkan (`vulkan-1.dll`) | *Running* a `spirv` build | Ships with any current NVIDIA / AMD / Intel driver. Verify with `vulkaninfo --summary` |
| Vulkan SDK | Optional — validation layers, `spirv-dis`, `spirv-val` | <https://vulkan.lunarg.com/sdk/home> |

Notes:

- **No `glslc`, `DXC` or `slangc`.** Shaders are Zig source compiled with
  `zig build-obj -target spirv64-vulkan -ofmt=spirv`, driven by `build.zig`.
- **No `vulkan-1.lib`.** The host layer loads `vulkan-1.dll` at runtime with
  `LoadLibrary`/`GetProcAddress` (the same trick [db.zig](src/db.zig) uses for
  `winsqlite3.dll`), so the SDK's import library is not required either.
- Install the SDK only if you want validation layers while developing the host
  layer — strongly recommended for that work, since Vulkan errors are otherwise
  silent. After installing, `VULKAN_SDK` is set and `spirv-val` / `spirv-dis`
  land on `PATH`:

  ```powershell
  spirv-val  .\.zig-cache\o\<hash>\sprite.spv   # validate the module
  spirv-dis  .\.zig-cache\o\<hash>\sprite.spv   # human-readable SPIR-V
  ```

### Zig 0.16 SPIR-V caveats

Two compiler bugs are worked around in `build.zig` (see the comment on the
shader step) so they can be lifted when upstream fixes them:

1. **Shaders must be built in `Debug`.** Every release mode
   (`ReleaseFast`/`ReleaseSafe`/`ReleaseSmall`) crashes the SPIR-V backend and
   silently emits a **0-byte** module. Harmless in practice — drivers optimise
   SPIR-V themselves.
2. **The build server can't emit SPIR-V.** Going through `b.addObject` fails
   with `error: failed to write: NotOpenForWriting`, so `build.zig` invokes
   `zig build-obj … -femit-bin=…` as a plain subprocess instead.

Also note `std.gpu.executionMode()` is currently broken (`cannot set execution
mode in assembly`), but it isn't needed: the compiler emits `OpExecutionMode`
for fragment entry points automatically.

## Timer usage

```
sowon                        clock mode (local time)
sowon clock                  clock mode, explicit
sowon 25m                    25-minute countdown (also 90s, 1.5h, 1h30m)
```

Timer flags:

| Flag | Meaning |
| --- | --- |
| `-m "Take a walk"` | message shown (title bar, toast, report) when time runs out |
| `-t deep-work` | tag the session, for tagged reports |
| `-r 4` | repeat: 4 work sessions (pomodoro) |
| `-b 5m` | break between work sessions |
| `-a <pattern>` | allow an app (`Code.exe`), Chrome tab group (`Research`), or domain (`ziglang.org`) in focus mode; repeatable. Also saved to the persistent allow list. |
| `-n 30s` | nudge (taskbar flash + soft tick) after being distracted this long; needs an allow list |
| `--top` | keep the window always on top |

Keys:

| Key | Description |
| --- | --- |
| <kbd>SPACE</kbd> | pause / resume (digits turn red while paused) |
| <kbd>F5</kbd> | restart from the first cycle |
| <kbd>↑</kbd>/<kbd>↓</kbd>, <kbd>PgUp</kbd>/<kbd>PgDn</kbd>, <kbd>Home</kbd>/<kbd>End</kbd>, mouse wheel | scroll the end-of-run report |
| <kbd>ESC</kbd> | quit |

Minimizing hides the window to the tray; the tray icon restores it. When the
timer finishes the report is brought back to the foreground automatically.

## Reports (CLI subcommands)

Output goes to **stdout**, so it can be piped or redirected.

```
sowon history [N]            the last N sessions (default 15)
sowon report today           aggregate report for today
sowon report week            aggregate report for the last 7 days
sowon report today -t deep-work   ... only sessions with this tag
```

Each finished work session records: start time, planned **active** duration,
actual **elapsed** wall-clock (which is larger when you pause), the custom
message, tag, cycle number, focused/distracted seconds, and a per-app
breakdown.

## Persistent allow list

Patterns passed with `-a` are saved and reused on later runs. Manage them
directly:

```
sowon allow list
sowon allow add ziglang.org
sowon allow remove Code.exe
```

At timer start, the effective allow list is the saved set plus any `-a` flags
from that run (which are themselves saved).

## Focus tracking

While a work session runs, the foreground app is sampled every
`SOWON_SAMPLE_INTERVAL` seconds (default 10). Allowed apps count as focused,
everything else as distracted; the report shows a focus score.

- If there is no keyboard/mouse input for 2 minutes, time is credited to
  `(idle)` instead of the focused window, and excluded from the focus score.
- Store/UWP apps may show up as `ApplicationFrameHost.exe`.
- Seconds with no focused window (e.g. the lock screen) are recorded under
  `(no focused window)`.
- Breaks and paused time are never sampled.

## Chrome integration (optional)

With the **bell-bearer** extension's "Connect to sowon" setting enabled, the
extension reports the focused tab's group and site to sowon over gRPC-Web on
`127.0.0.1:41414` (see [proto/bell-bearer.proto](proto/bell-bearer.proto)).
Chrome time is then split as `chrome [Group] domain`, and allow-list patterns
can match a tab group or a domain. If sowon isn't running, the extension backs
off automatically.

## Storage

Everything is in `%LOCALAPPDATA%\sowon\sowon.db` (SQLite):
`sessions`, `app_usage`, `allow_list`.
