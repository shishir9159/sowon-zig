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
pub const WS_EX_TOPMOST: DWORD = 0x0008;
pub const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x80000000));
pub const SW_SHOW: c_int = 5;
pub const SW_HIDE: c_int = 0;
pub const SW_RESTORE: c_int = 9;
pub const SIZE_MINIMIZED: WPARAM = 1;
pub const WM_APP: UINT = 0x8000;
pub const WM_LBUTTONUP: LPARAM = 0x0202;

// Virtual keys
pub const VK_ESCAPE: WPARAM = 0x1B;
pub const VK_SPACE: WPARAM = 0x20;
pub const VK_PRIOR: WPARAM = 0x21; // Page Up
pub const VK_NEXT: WPARAM = 0x22; // Page Down
pub const VK_END: WPARAM = 0x23;
pub const VK_HOME: WPARAM = 0x24;
pub const VK_UP: WPARAM = 0x26;
pub const VK_DOWN: WPARAM = 0x28;
pub const VK_F5: WPARAM = 0x74;

pub const WM_MOUSEWHEEL: UINT = 0x020A;

// GDI
pub const SRCCOPY: DWORD = 0x00CC0020;
pub const TRANSPARENT: c_int = 1;
pub const FW_NORMAL: c_int = 400;
pub const DEFAULT_CHARSET: DWORD = 1;
pub const CLEARTYPE_QUALITY: DWORD = 5;

// DIB / AlphaBlend
pub const BITMAPINFOHEADER = extern struct {
    biSize: DWORD,
    biWidth: i32,
    biHeight: i32,
    biPlanes: WORD,
    biBitCount: WORD,
    biCompression: DWORD,
    biSizeImage: DWORD,
    biXPelsPerMeter: i32,
    biYPelsPerMeter: i32,
    biClrUsed: DWORD,
    biClrImportant: DWORD,
};

pub const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]u32,
};

pub const BLENDFUNCTION = extern struct {
    BlendOp: u8,
    BlendFlags: u8,
    SourceConstantAlpha: u8,
    AlphaFormat: u8,
};

pub const BI_RGB: DWORD = 0;
pub const DIB_RGB_COLORS: UINT = 0;
pub const AC_SRC_OVER: u8 = 0;
pub const AC_SRC_ALPHA: u8 = 1;

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

pub extern "gdi32" fn CreateDIBSection(
    hdc: ?HDC,
    pbmi: *const BITMAPINFO,
    usage: UINT,
    ppvBits: *?*anyopaque,
    hSection: ?HANDLE,
    offset: DWORD,
) callconv(.winapi) ?HBITMAP;

// msimg32
pub extern "msimg32" fn AlphaBlend(
    hdcDest: HDC,
    xoriginDest: c_int,
    yoriginDest: c_int,
    wDest: c_int,
    hDest: c_int,
    hdcSrc: HDC,
    xoriginSrc: c_int,
    yoriginSrc: c_int,
    wSrc: c_int,
    hSrc: c_int,
    ftn: BLENDFUNCTION,
) callconv(.winapi) BOOL;

// kernel32
pub const HMODULE = *opaque {};
pub extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
pub extern "kernel32" fn LoadLibraryW([*:0]const u16) callconv(.winapi) ?HMODULE;
pub extern "kernel32" fn GetProcAddress(HMODULE, [*:0]const u8) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GetEnvironmentVariableW([*:0]const u16, [*]u16, DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn CreateDirectoryW([*:0]const u16, ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetLocalTime(*SYSTEMTIME) callconv(.winapi) void;
pub extern "kernel32" fn OpenProcess(DWORD, BOOL, DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn CloseHandle(HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryFullProcessImageNameW(HANDLE, DWORD, [*]u16, *DWORD) callconv(.winapi) BOOL;

// winmm
pub extern "winmm" fn PlaySoundW(?*const anyopaque, ?HINSTANCE, DWORD) callconv(.winapi) BOOL;

// Tray icon (Shell_NotifyIconW)
pub const NOTIFYICONDATAW = extern struct {
    cbSize: DWORD,
    hWnd: ?HWND,
    uID: UINT,
    uFlags: UINT,
    uCallbackMessage: UINT,
    hIcon: ?HICON,
    szTip: [128]u16,
    dwState: DWORD,
    dwStateMask: DWORD,
    szInfo: [256]u16,
    uTimeoutOrVersion: UINT,
    szInfoTitle: [64]u16,
    dwInfoFlags: DWORD,
    guidItem: [16]u8,
    hBalloonIcon: ?HICON,
};

pub const NIM_ADD: DWORD = 0;
pub const NIM_MODIFY: DWORD = 1;
pub const NIM_DELETE: DWORD = 2;
pub const NIF_MESSAGE: UINT = 0x01;
pub const NIF_ICON: UINT = 0x02;
pub const NIF_TIP: UINT = 0x04;
pub const NIF_INFO: UINT = 0x10;
pub const NIIF_INFO: DWORD = 1;
pub const IDI_APPLICATION: u16 = 32512;

pub extern "shell32" fn Shell_NotifyIconW(DWORD, *NOTIFYICONDATAW) callconv(.winapi) BOOL;
pub extern "user32" fn LoadIconW(?HINSTANCE, [*:0]const u16) callconv(.winapi) ?HICON;
pub extern "user32" fn SetForegroundWindow(HWND) callconv(.winapi) BOOL;

// Taskbar attention flash
pub const FLASHWINFO = extern struct {
    cbSize: UINT,
    hwnd: ?HWND,
    dwFlags: DWORD,
    uCount: UINT,
    dwTimeout: DWORD,
};
pub const FLASHW_ALL: DWORD = 3;
pub extern "user32" fn FlashWindowEx(*const FLASHWINFO) callconv(.winapi) BOOL;

// Slim reader/writer lock (used exclusively; a plain mutex)
pub const SRWLOCK = usize;
pub const SRWLOCK_INIT: SRWLOCK = 0;
pub extern "kernel32" fn AcquireSRWLockExclusive(*SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn ReleaseSRWLockExclusive(*SRWLOCK) callconv(.winapi) void;

// winsock
pub const SOCKET = usize;
pub const INVALID_SOCKET: SOCKET = ~@as(SOCKET, 0);
pub const AF_INET: u16 = 2;
pub const SOCK_STREAM: c_int = 1;
pub const IPPROTO_TCP: c_int = 6;

pub const sockaddr_in = extern struct {
    sin_family: u16,
    sin_port: u16, // big-endian
    sin_addr: u32, // network byte order in memory
    sin_zero: [8]u8,
};

pub extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *anyopaque) callconv(.winapi) c_int;
pub extern "ws2_32" fn socket(af: c_int, sock_type: c_int, protocol: c_int) callconv(.winapi) SOCKET;
pub extern "ws2_32" fn bind(s: SOCKET, name: *const sockaddr_in, namelen: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn listen(s: SOCKET, backlog: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn accept(s: SOCKET, addr: ?*anyopaque, addrlen: ?*c_int) callconv(.winapi) SOCKET;
pub extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) c_int;

pub fn rgb(r: u8, g: u8, b: u8) COLORREF {
    return @as(COLORREF, r) | (@as(COLORREF, g) << 8) | (@as(COLORREF, b) << 16);
}