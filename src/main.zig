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
    if (is_debug)
        _ = debug_allocator.deinit();
}

const AppState = enum(u8) {
    awaiting_read_path,
    awaiting_write_path,
    inventorying,
    saving,
    finishing,
    err,
};

const Item = struct {
    name: std.ArrayList(u8) = .empty,
    quantity: ?u32 = null,
    unit: ?[16]u8 = null,
    price: ?f32 = null,

    fn deinit(self: *Item, gpa: std.mem.Allocator) void {
        self.name.deinit(gpa);
    }
};

const is_debug = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
const allocator: std.mem.Allocator = if (is_debug)
    debug_allocator.allocator()
else
    std.heap.smp_allocator;
var thread: std.Thread = undefined;
var is_done: std.atomic.Value(bool) = .init(false);
var state: AppState = .awaiting_read_path;
var has_select_dialog_showed: bool = false;
var items: std.ArrayList(Item) = .empty;
var skipped_files: std.ArrayList([]const u8) = .empty;
var err: anyerror = error.Undefined;

pub fn appFrame() !dvui.App.Result {
    {
        var scaler = dvui.scale(
            @src(),
            .{ .scale = &dvui.currentWindow().content_scale, .pinch_zoom = .global },
            .{ .rect = .cast(dvui.windowRect()) },
        );
        scaler.deinit();

        frame() catch |e| {
            err = e;
            state = .err;
        };
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

            if (is_done.load(.acquire)) {
                state = if (items.items.len == 0)
                    .awaiting_read_path
                else
                    .awaiting_write_path;
            }
        },
        .saving => {
            dvui.spinner(@src(), .{});

            if (is_done.load(.acquire))
                state = .finishing;
        },
        .finishing => {
            dvui.label(@src(), "Zapisano", .{}, .{});

            {
                var scroll = dvui.scrollArea(@src(), .{}, .{
                    .expand = .horizontal,
                    .background = false,
                    .max_size_content = .{ .w = 10000, .h = 200 },
                });
                defer scroll.deinit();
                for (skipped_files.items, 0..) |item, i| {
                    dvui.label(@src(), "{s}", .{item}, .{ .id_extra = i });
                }
            }

            if (dvui.button(@src(), "OK", .{}, .{})) {
                for (items.items) |*it| it.name.deinit(allocator);
                items.deinit(allocator);
                for (skipped_files.items) |it| allocator.free(it);
                skipped_files.deinit(allocator);
                state = .awaiting_read_path;
            }
        },
        .err => {
            dvui.label(@src(), "Błąd", .{}, .{});
            dvui.label(@src(), "Uruchom ponownie plikacje\n({s})\n", .{@errorName(err)}, .{});
            if (dvui.button(@src(), "OK", .{}, .{}))
                std.process.exit(1);
        },
    }
}

fn inventory_job(dir: []const u8) void {
    inventory(dir) catch |e| {
        err = e;
        state = .err;
    };
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
        if (!std.mem.endsWith(u8, entry.name, ".xml"))
            continue;

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
        try stdout.flush();

        var item: Item = .{};
        var net_from_gross_price: f32 = 0.0;

        while (true) {
            switch (try reader.read()) {
                .eof => break,
                .element_start => {
                    if (std.mem.eql(u8, "P_7", reader.elementNameNs().local)) {
                        const text = try switch (try reader.read()) {
                            .text => try reader.text(),
                            .element_end => "",
                            else => error.MalformedXml,
                        };

                        item.name.clearRetainingCapacity();
                        try item.name.appendSlice(allocator, text);
                    } else if (std.mem.eql(u8, "P_8B", reader.elementNameNs().local)) {
                        _ = try reader.read();
                        item.quantity = @intFromFloat(std.fmt.parseFloat(f32, try reader.text()) catch 0.0);
                    } else if (std.mem.eql(u8, "P_8A", reader.elementNameNs().local)) {
                        const text = try switch (try reader.read()) {
                            .text => try reader.text(),
                            .element_end => "",
                            else => error.MalformedXml,
                        };

                        item.unit = @splat(0);
                        const len = @min(text.len, item.unit.?.len);
                        @memcpy(item.unit.?[0..len], text[0..len]);
                    } else if (std.mem.eql(u8, "P_9A", reader.elementNameNs().local)) {
                        _ = try reader.read();
                        item.price = std.fmt.parseFloat(f32, try reader.text()) catch 0.0;
                    } else if (std.mem.eql(u8, "P_9B", reader.elementNameNs().local)) {
                        _ = try reader.read();

                        const gross_price = std.fmt.parseFloat(f32, try reader.text()) catch 0.0;
                        const net_price = gross_price - gross_price * 0.23;

                        net_from_gross_price = net_price;
                    }
                },
                .element_end => {
                    if (std.mem.eql(u8, reader.elementNameNs().local, "FaWiersz")) {
                        if (item.name.items.len != 0 and
                            item.quantity != null and
                            item.price != null or
                            net_from_gross_price != 0.0)
                        {
                            if (item.price == null and net_from_gross_price != 0.0)
                                item.price = net_from_gross_price;

                            try items.append(allocator, item);
                            item = .{};
                            net_from_gross_price = 0.0;
                        } else {
                            item.name.clearRetainingCapacity();
                            item.quantity = null;
                            item.unit = null;
                            item.price = null;
                            net_from_gross_price = 0.0;
                            const name_copy = try allocator.dupe(u8, entry.name);
                            try skipped_files.append(allocator, name_copy);
                            break;
                        }
                    }
                },
                else => {},
            }
        }
    }

    is_done.store(true, .release);
}

fn save_inventory_job(path: []const u8) void {
    save_inventory(path) catch |e| {
        err = e;
        state = .err;
    };
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
    const filepath = try std.Io.Dir.path.join(allocator, &.{ path, filename });
    defer allocator.free(filepath);

    var file = try std.Io.Dir.cwd().createFile(dvui.io, filepath, .{});
    defer file.close(dvui.io);
    var writer_buf: [4096]u8 = undefined;
    var file_writer = file.writer(dvui.io, &writer_buf);
    const w = &file_writer.interface;

    for (items.items) |*item| {
        try w.writeByte('"');
        try w.writeAll(item.name.items);
        try w.writeByte('"');
        try w.writeByte(',');

        var num_buf: [64]u8 = undefined;

        try w.writeAll(try std.fmt.bufPrint(&num_buf, "{}", .{item.quantity orelse 0}));
        try w.writeByte(',');

        try w.writeAll(&item.unit.?);
        try w.writeByte(',');

        try w.writeAll(try std.fmt.bufPrint(&num_buf, "{d:.2}", .{item.price orelse 0.0}));
        try w.writeByte('\n');
    }

    try w.flush();
    is_done.store(true, .release);
}
