//! OpenGL rendering backend — not implemented yet. The build plumbing
//! (-Drenderer=opengl, opengl32/gdi32 linking, shader-backend option)
//! is in place; port the original sowon GL renderer here, honoring the
//! interface documented in frame.zig.

const message = "the 'opengl' renderer is not implemented yet; build with -Drenderer=gdi (default)";

pub const init = @compileError(message);
pub const paint = @compileError(message);
pub const reportVisibleLines = @compileError(message);
