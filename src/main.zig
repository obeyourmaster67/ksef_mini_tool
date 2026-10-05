const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const xml = @import("xml");

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

pub fn appInit(win: *dvui.Window) !void {
    _ = win;
}

pub fn appDeinit(win: *dvui.Window) void {
    _ = win;
    thread.join();
    inventory_list.deinit(allocator);
}

const AppState = enum(u8) {
    awaiting_read_path,
    awaiting_write_path,
    inventorying,
    saving,
    finishing,
};

const Item = struct {
    name: ?[4096]u8,
    quantity: ?u32,
    price: ?f32,
};

var allocator = std.heap.smp_allocator;
var thread: std.Thread = undefined;
var is_done: std.atomic.Value(bool) = .init(false);
var state: AppState = .awaiting_read_path;
var has_select_dialog_showed: bool = false;
var inventory_list: std.ArrayList(Item) = .empty;
var filepath: []u8 = undefined;

pub fn appFrame() !dvui.App.Result {
    {
        var scaler = dvui.scale(
            @src(),
            .{ .scale = &dvui.currentWindow().content_scale, .pinch_zoom = .global },
            .{ .rect = .cast(dvui.windowRect()) },
        );
        scaler.deinit();

        frame() catch |e| err(e);
    }

    return .ok;
}

fn frame() !void {
    var center_box = dvui.box(
        @src(),
        .{ .dir = .vertical },
        .{
            .gravity_x = 0.5,
            .gravity_y = 0.5,
        },
    );
    defer center_box.deinit();

    switch (state) {
        .awaiting_read_path => {
            if (dvui.button(@src(), "Wybierz folder z fakturami (.xml)", .{}, .{})) {
                const dir_path = try dvui.dialogNativeFolderSelect(allocator, .{
                    .title = "Wybierz folder z fakturami",
                    .path = ".",
                });

                if (dir_path) |path| {
                    is_done.store(false, .release);
                    thread = try std.Thread.spawn(.{}, inventory_job, .{path});
                    state = .inventorying;
                }
            }
        },
        .awaiting_write_path => {
            if (dvui.button(@src(), "Wybierz miejsce zapisu", .{}, .{}) or !has_select_dialog_showed) {
                has_select_dialog_showed = true;

                const dir_path = try dvui.dialogNativeFolderSelect(allocator, .{
                    .title = "Wybierz miejsce zapisu",
                    .path = ".",
                });

                if (dir_path) |path| {
                    is_done.store(false, .release);
                    thread = try std.Thread.spawn(.{}, save_inventory_job, .{path});
                    state = .saving;
                    has_select_dialog_showed = false;
                }
            }
        },
        .inventorying => {
            dvui.spinner(@src(), .{});

            if (is_done.load(.acquire))
                state = .awaiting_write_path;
        },
        .saving => {
            dvui.spinner(@src(), .{});

            if (is_done.load(.acquire))
                state = .finishing;
        },
        .finishing => {
            dvui.label(@src(), "Zapisano", .{}, .{});
            if (dvui.button(@src(), "OK", .{}, .{}))
                state = .awaiting_read_path;
        },
    }
}

fn inventory_job(dir: []const u8) void {
    inventory(dir) catch |e| err(e);
}

fn inventory(dir: []const u8) !void {
    defer allocator.free(dir);

    var target_dir = try std.Io.Dir.openDir(
        std.Io.Dir.cwd(),
        dvui.io,
        dir,
        .{ .iterate = true },
    );
    defer target_dir.close(dvui.io);
    var iterator = target_dir.iterate();

    while (try iterator.next(dvui.io)) |entry| {
        const path = try std.Io.Dir.path.join(allocator, &.{ dir, entry.name });
        defer allocator.free(path);

        var input_file = try std.Io.Dir.cwd().openFile(dvui.io, path, .{});
        defer input_file.close(dvui.io);
        var input_buf: [4096]u8 = undefined;
        var input_reader = input_file.reader(dvui.io, &input_buf);
        var streaming_reader: xml.Reader.Streaming = .init(
            allocator,
            &input_reader.interface,
            .{},
        );
        defer streaming_reader.deinit();
        const reader = &streaming_reader.interface;

        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(dvui.io, &stdout_buf);
        const stdout = &stdout_writer.interface;

        var p7_occured = false;
        var p11_occured = false;
        var p8b_occured = false;
        var item: Item = Item{
            .name = null,
            .quantity = null,
            .price = null,
        };

        while (true) {
            const node = reader.read() catch |e| {
                try stdout.flush();
                if (e == error.OutOfMemory) {
                    return e;
                } else {
                    break;
                }
            };
            switch (node) {
                .eof => break,
                .element_start => {
                    if (std.mem.eql(u8, "P_11", reader.elementName())) {
                        p11_occured = true;
                    } else if (std.mem.eql(u8, "P_8B", reader.elementName())) {
                        p8b_occured = true;
                    } else if (std.mem.eql(u8, "P_7", reader.elementName())) {
                        p7_occured = true;
                    }
                },
                .text => {
                    if (p11_occured) {
                        item.price = std.fmt.parseFloat(f32, try reader.text()) catch 0.0;
                        p11_occured = false;
                    } else if (p8b_occured) {
                        item.quantity = std.fmt.parseInt(u32, try reader.text(), 10) catch 0.0;
                        p8b_occured = false;
                    } else if (p7_occured) {
                        const text = try reader.text();
                        item.name = undefined;
                        @memset(&item.name.?, 0);
                        @memcpy(item.name.?[0..text.len], text);
                        p7_occured = false;
                    }
                    if (item.name != null and item.price != null and item.quantity != null) {
                        try inventory_list.append(allocator, item);
                        item = Item{ .name = null, .quantity = null, .price = null };
                    }
                },
                else => {},
            }
        }

        try stdout.flush();
    }

    is_done.store(true, .release);
}

fn save_inventory_job(path: []const u8) void {
    save_inventory(path) catch |e| err(e);
}

fn save_inventory(path: []const u8) !void {
    defer allocator.free(path);

    const epoch_secs = std.time.epoch.EpochSeconds{
        .secs = @intCast(std.Io.Clock.real.now(dvui.io).toSeconds()),
    };
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var x: u64 = undefined;
    std.Io.random(dvui.io, std.mem.asBytes(&x));
    var name_buf: [96]u8 = undefined;
    const filename = try std.fmt.bufPrint(&name_buf, "{}-{}-{}_{}.csv", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        x,
    });
    filepath = try std.Io.Dir.path.join(allocator, &.{ path, filename });

    var file = try std.Io.Dir.cwd().createFile(dvui.io, filepath, .{});
    defer file.close(dvui.io);
    var writer_buf: [4096]u8 = undefined;
    var file_writer = file.writer(dvui.io, &writer_buf);
    const w = &file_writer.interface;

    for (inventory_list.items) |*item| {
        try w.writeByte('"');
        try w.writeAll(std.mem.sliceTo(&item.name.?, 0));
        try w.writeByte('"');
        try w.writeByte(',');

        var num_buf: [64]u8 = undefined;
        try w.writeAll(try std.fmt.bufPrint(&num_buf, "{}", .{item.quantity.?}));
        try w.writeByte(',');
        try w.writeAll(try std.fmt.bufPrint(&num_buf, "{d:.2}", .{item.price.?}));
        try w.writeByte('\n');
    }

    try w.flush();
    is_done.store(true, .release);
}

fn err(e: anyerror) void {
    var win = dvui.floatingWindow(@src(), .{ .modal = true }, .{});
    defer win.deinit();

    _ = dvui.windowHeader("Błąd", "", null);
    dvui.label(@src(), "Uruchom ponownie plikacje\n{s}", .{@errorName(e)}, .{});

    if (dvui.button(@src(), "OK", .{}, .{})) {
        std.process.exit(1);
    }
}
