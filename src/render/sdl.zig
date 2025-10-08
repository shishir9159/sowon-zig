//! SDL rendering backend — not implemented yet. Requires vendoring or
//! linking SDL; implement the interface documented in frame.zig.

const message = "the 'sdl' renderer is not implemented yet; build with -Drenderer=gdi (default)";

pub const init = @compileError(message);
pub const paint = @compileError(message);
pub const reportVisibleLines = @compileError(message);
