//! Minimal hand-written Win32 bindings — only what sowon needs.
//! Self-contained on purpose: no dependency on std.os.windows types,
//! so it survives std churn between Zig releases.

pub const BOOL = c_int;
pub const WORD = u16;
pub const DWORD = u32;
pub const UINT = u32;
pub const ATOM = u16;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const COLORREF = u32;

pub const HANDLE = *anyopaque;
pub const HWND = *opaque {};
pub const HINSTANCE = *opaque {};
pub const HICON = *opaque {};
pub const HCURSOR = *opaque {};
pub const HMENU = *opaque {};
pub const HDC = *opaque {};
pub const HGDIOBJ = *anyopaque;
pub const HBRUSH = *opaque {};
pub const HBITMAP = *opaque {};
pub const HFONT = *opaque {};

pub const POINT = extern struct { x: i32, y: i32 };
pub const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

pub const SYSTEMTIME = extern struct {
    wYear: WORD,
    wMonth: WORD,
    wDayOfWeek: WORD,
    wDay: WORD,
    wHour: WORD,
    wMinute: WORD,
    wSecond: WORD,
    wMilliseconds: WORD,
};

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
    lPrivate: DWORD,
};

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int,
    cbWndExtra: c_int,
    hInstance: ?HINSTANCE,
    hIcon: ?HICON,
    hCursor: ?HCURSOR,
    hbrBackground: ?HBRUSH,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
    hIconSm: ?HICON,
};

pub const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

// Window messages
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_PAINT: UINT = 0x000F;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_ERASEBKGND: UINT = 0x0014;
pub const WM_KEYDOWN: UINT = 0x0100;
pub const WM_TIMER: UINT = 0x0113;

// Class / window styles
pub const CS_VREDRAW: UINT = 0x0001;
pub const CS_HREDRAW: UINT = 0x0002;
pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
pub const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x80000000));
pub const SW_SHOW: c_int = 5;

// Virtual keys
pub const VK_ESCAPE: WPARAM = 0x1B;
pub const VK_SPACE: WPARAM = 0x20;

// GDI
pub const SRCCOPY: DWORD = 0x00CC0020;
pub const TRANSPARENT: c_int = 1;
pub const FW_NORMAL: c_int = 400;
pub const DEFAULT_CHARSET: DWORD = 1;
pub const CLEARTYPE_QUALITY: DWORD = 5;

// PlaySound
pub const SND_ASYNC: DWORD = 0x0001;
pub const SND_NODEFAULT: DWORD = 0x0002;
pub const SND_MEMORY: DWORD = 0x0004;

// Process access
pub const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;

pub const IDC_ARROW: u16 = 32512;

pub fn makeIntResourceW(id: u16) [*:0]const u16 {
    return @ptrFromInt(id);
}

// user32
pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) ATOM;
pub extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: [*:0]const u16,
    lpWindowName: [*:0]const u16,
    dwStyle: DWORD,
    x: c_int,
    y: c_int,
    nWidth: c_int,
    nHeight: c_int,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: ?HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn ShowWindow(HWND, c_int) callconv(.winapi) BOOL;
pub extern "user32" fn GetMessageW(*MSG, ?HWND, UINT, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostQuitMessage(c_int) callconv(.winapi) void;
pub extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn LoadCursorW(?HINSTANCE, [*:0]const u16) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(.winapi) ?HDC;
pub extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn InvalidateRect(HWND, ?*const RECT, BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn FillRect(HDC, *const RECT, HBRUSH) callconv(.winapi) c_int;
pub extern "user32" fn SetTimer(?HWND, usize, UINT, ?*anyopaque) callconv(.winapi) usize;
pub extern "user32" fn KillTimer(?HWND, usize) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowTextW(HWND, [*:0]const u16) callconv(.winapi) BOOL;
pub extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
pub extern "user32" fn GetWindowThreadProcessId(HWND, ?*DWORD) callconv(.winapi) DWORD;

// gdi32
pub extern "gdi32" fn CreateSolidBrush(COLORREF) callconv(.winapi) ?HBRUSH;
pub extern "gdi32" fn DeleteObject(HGDIOBJ) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateCompatibleDC(?HDC) callconv(.winapi) ?HDC;
pub extern "gdi32" fn DeleteDC(HDC) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateCompatibleBitmap(HDC, c_int, c_int) callconv(.winapi) ?HBITMAP;
pub extern "gdi32" fn SelectObject(HDC, HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn BitBlt(HDC, c_int, c_int, c_int, c_int, HDC, c_int, c_int, DWORD) callconv(.winapi) BOOL;
pub extern "gdi32" fn SetBkMode(HDC, c_int) callconv(.winapi) c_int;
pub extern "gdi32" fn SetTextColor(HDC, COLORREF) callconv(.winapi) COLORREF;
pub extern "gdi32" fn TextOutW(HDC, c_int, c_int, [*]const u16, c_int) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateFontW(
    cHeight: c_int,
    cWidth: c_int,
    cEscapement: c_int,
    cOrientation: c_int,
    cWeight: c_int,
    bItalic: DWORD,
    bUnderline: DWORD,
    bStrikeOut: DWORD,
    iCharSet: DWORD,
    iOutPrecision: DWORD,
    iClipPrecision: DWORD,
    iQuality: DWORD,
    iPitchAndFamily: DWORD,
    pszFaceName: ?[*:0]const u16,
) callconv(.winapi) ?HFONT;

// kernel32
pub extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
pub extern "kernel32" fn GetLocalTime(*SYSTEMTIME) callconv(.winapi) void;
pub extern "kernel32" fn OpenProcess(DWORD, BOOL, DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn CloseHandle(HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryFullProcessImageNameW(HANDLE, DWORD, [*]u16, *DWORD) callconv(.winapi) BOOL;

// winmm
pub extern "winmm" fn PlaySoundW(?*const anyopaque, ?HINSTANCE, DWORD) callconv(.winapi) BOOL;

pub fn rgb(r: u8, g: u8, b: u8) COLORREF {
    return @as(COLORREF, r) | (@as(COLORREF, g) << 8) | (@as(COLORREF, b) << 16);
}
