# sowon-zig

A Windows-first port of [sowon](https://github.com/tsoding/sowon) to pure Zig.
No C dependencies, no OpenGL, no asset files: the digits are seven-segment
shapes drawn with GDI, and the end-of-timer chime is synthesized at startup.

## Build

Requires Zig 0.14 or newer (tested style targets 0.14/0.15). On Windows:

```console
> cd sowon-zig
> zig build -Doptimize=ReleaseSafe
> .\zig-out\bin\sowon.exe 25m
```

## Usage

| Command | Meaning |
| --- | --- |
| `sowon` | clock mode (local time) |
| `sowon clock` | clock mode, explicit |
| `sowon 25m` | 25-minute countdown |
| `sowon 1h30m`, `sowon 90s`, `sowon 1.5h` | duration units combine like the original |

| Key | Description |
| --- | --- |
| <kbd>SPACE</kbd> | pause / resume (timer mode; digits turn red while paused) |
| <kbd>ESC</kbd> | quit |

## Focus tracking

In timer mode the app samples the foreground window once per second and
records which executable owns it (`chrome.exe`, `explorer.exe`, `Code.exe`,
...). Sampling pauses while the timer is paused.

When the countdown reaches zero:

1. a rising C-major chime plays (synthesized, no sound file needed),
2. the window switches to a per-app usage report sorted by time,
3. the same report is printed to the console if you launched from one.

Notes on Windows quirks:

- Store/UWP apps may show up as `ApplicationFrameHost.exe`.
- Seconds with no focused window (e.g. on the lock screen) are recorded
  under `(no focused window)`.

## Chrome tabs / tab groups

Per-tab and tab-group tracking is **not** possible from the outside: Chrome
does not expose the active tab or `tabGroups` to other processes. The planned
follow-up is a small Chrome extension (`chrome.tabs` + `chrome.tabGroups` +
native messaging to this app). Until then, Chrome is tracked as one app like
everything else. A zero-setup middle ground — reading the focused Chrome
window's title, which equals the active tab's page title — is possible if
wanted later.
