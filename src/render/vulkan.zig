//! Vulkan rendering backend — not implemented yet. The build plumbing
//! (-Drenderer=vulkan, -Dshader-backend=slang) is in place; implement
//! the interface documented in frame.zig.

const message = "the 'vulkan' renderer is not implemented yet; build with -Drenderer=gdi (default)";

pub const init = @compileError(message);
pub const paint = @compileError(message);
pub const reportVisibleLines = @compileError(message);
