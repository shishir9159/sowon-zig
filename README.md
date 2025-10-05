# sowon-zig

A Windows-first port of [sowon](https://github.com/tsoding/sowon) to pure Zig.
No C dependencies, no OpenGL, and the end-of-timer chime is synthesized at startup.

## Build

Requires Zig 0.15 nightly:

```POWERSHELL
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

Notes on Windows quirks:

- Store/UWP apps may show up as `ApplicationFrameHost.exe`.
- Seconds with no focused window (e.g. on the lock screen) are recorded
  under `(no focused window)`.