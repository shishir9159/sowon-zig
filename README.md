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
| `-Drenderer=gdi\|opengl\|vulkan\|sdl\|glfw` | Rendering backend to compile in. Only `gdi` is implemented; the others are compile-checked stubs. Only the selected backend is compiled. |
| `-Dshader-backend=none\|slang` | Shader toolchain for GPU renderers. Rejected with `gdi`. |
| `SOWON_SAMPLE_INTERVAL=<seconds>` (env var) | Foreground-app sampling interval, baked in at build time. Default `10`. |

Run the unit tests (pure helpers + protobuf decoder):

```powershell
zig build test
```

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
