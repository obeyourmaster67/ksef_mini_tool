const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 800.0, .h = 600.0 },
            .min_size = .{ .w = 250.0, .h = 350.0 },
            .title = "microinvKSEF",
            .window_init_options = .{
                .keybinds_zoom = true,
            },
        },
    },
    .frameFn = appFrame,
    .initFn = appInit,
    .deinitFn = appDeinit,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

var orig_content_scale: f32 = 1.0;
var warn_on_quit: bool = false;
var warn_on_quit_closing: bool = false;
var extra_os_win: bool = false;

pub fn appInit(win: *dvui.Window) !void {
    orig_content_scale = win.content_scale;
}

pub fn appDeinit(win: *dvui.Window) void {
    _ = win;
}

pub fn appFrame() !dvui.App.Result {
    {
        var scaler = dvui.scale(@src(), .{ .scale = &dvui.currentWindow().content_scale, .pinch_zoom = .global }, .{ .rect = .cast(dvui.windowRect()) });
        scaler.deinit();

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .window });
        defer scroll.deinit();
    }

    return .ok;
}
