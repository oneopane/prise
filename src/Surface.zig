const std = @import("std");
const vaxis = @import("vaxis");
const msgpack = @import("msgpack.zig");

const Surface = @This();

front: *vaxis.AllocatingScreen,
back: *vaxis.AllocatingScreen,
allocator: std.mem.Allocator,
rows: u16,
cols: u16,
cursor_shape: redraw.UIEvent.CursorShape.Shape = .block,
dirty: bool = false,
hl_attrs: std.AutoHashMap(u32, vaxis.Style),

const redraw = @import("redraw.zig");

pub fn init(allocator: std.mem.Allocator, rows: u16, cols: u16) !Surface {
    const front = try allocator.create(vaxis.AllocatingScreen);
    errdefer allocator.destroy(front);

    const back = try allocator.create(vaxis.AllocatingScreen);
    errdefer allocator.destroy(back);

    front.* = try vaxis.AllocatingScreen.init(allocator, cols, rows);
    errdefer front.deinit(allocator);

    back.* = try vaxis.AllocatingScreen.init(allocator, cols, rows);

    return .{
        .front = front,
        .back = back,
        .allocator = allocator,
        .rows = rows,
        .cols = cols,
        .hl_attrs = std.AutoHashMap(u32, vaxis.Style).init(allocator),
    };
}

pub fn deinit(self: *Surface) void {
    self.front.deinit(self.allocator);
    self.allocator.destroy(self.front);
    self.back.deinit(self.allocator);
    self.allocator.destroy(self.back);
    self.hl_attrs.deinit();
}

pub fn resize(self: *Surface, rows: u16, cols: u16) !void {
    // Deinit old screens
    self.front.deinit(self.allocator);
    self.back.deinit(self.allocator);

    // Reinit with new size
    self.front.* = try vaxis.AllocatingScreen.init(self.allocator, cols, rows);
    self.back.* = try vaxis.AllocatingScreen.init(self.allocator, cols, rows);

    self.rows = rows;
    self.cols = cols;
    self.dirty = true;
}

pub fn applyRedraw(self: *Surface, params: msgpack.Value) !void {
    if (params != .array) return error.InvalidRedrawParams;

    std.log.debug("applyRedraw: received params with {} events", .{params.array.len});

    var rows_updated = std.ArrayList(usize).empty;
    defer rows_updated.deinit(self.allocator);

    // Don't reset the arena or copy - back buffer already has the full state from last render
    // write events will update only changed rows
    // The arena keeps growing but only with new/changed cell text

    for (params.array) |event_val| {
        if (event_val != .array or event_val.array.len < 2) continue;

        const event_name = event_val.array[0];
        if (event_name != .string) continue;

        const event_params = event_val.array[1];
        if (event_params != .array) continue;

        if (std.mem.eql(u8, event_name.string, "resize")) {
            if (event_params.array.len < 3) continue;

            // args: [pty, rows, cols]
            const rows = switch (event_params.array[1]) {
                .unsigned => |u| @as(u16, @intCast(u)),
                .integer => |i| @as(u16, @intCast(i)),
                else => continue,
            };
            const cols = switch (event_params.array[2]) {
                .unsigned => |u| @as(u16, @intCast(u)),
                .integer => |i| @as(u16, @intCast(i)),
                else => continue,
            };

            // Only resize if dimensions actually changed
            if (rows != self.rows or cols != self.cols) {
                std.log.debug("resize: resizing from {}x{} to {}x{}", .{ self.cols, self.rows, cols, rows });
                try self.resize(rows, cols);
            }
        } else if (std.mem.eql(u8, event_name.string, "cursor_pos")) {
            if (event_params.array.len < 3) continue;

            // args: [pty, row, col]
            const row = switch (event_params.array[1]) {
                .unsigned => |u| @as(u16, @intCast(u)),
                .integer => |i| @as(u16, @intCast(i)),
                else => continue,
            };
            const col = switch (event_params.array[2]) {
                .unsigned => |u| @as(u16, @intCast(u)),
                .integer => |i| @as(u16, @intCast(i)),
                else => continue,
            };

            self.back.cursor_row = row;
            self.back.cursor_col = col;
            self.back.cursor_vis = true;
            self.dirty = true;
        } else if (std.mem.eql(u8, event_name.string, "cursor_shape")) {
            if (event_params.array.len < 2) continue;

            // args: [pty, shape]
            const shape_int = switch (event_params.array[1]) {
                .unsigned => |u| @as(u8, @intCast(u)),
                .integer => |i| @as(u8, @intCast(i)),
                else => continue,
            };

            self.cursor_shape = @enumFromInt(shape_int);
            self.dirty = true;
        } else if (std.mem.eql(u8, event_name.string, "write")) {
            if (event_params.array.len < 4) continue;

            // args: [pty, row, col, cells]
            const row = switch (event_params.array[1]) {
                .unsigned => |u| @as(usize, @intCast(u)),
                .integer => |i| @as(usize, @intCast(i)),
                else => continue,
            };
            var col = switch (event_params.array[2]) {
                .unsigned => |u| @as(usize, @intCast(u)),
                .integer => |i| @as(usize, @intCast(i)),
                else => continue,
            };

            const cells = event_params.array[3];
            if (cells != .array) continue;

            try rows_updated.append(self.allocator, row);

            var current_hl: u32 = 0;
            for (cells.array) |cell| {
                if (cell != .array or cell.array.len == 0) continue;

                // cell: [grapheme, style_id?, repeat?]
                const text = if (cell.array[0] == .string) cell.array[0].string else " ";

                if (cell.array.len > 1 and cell.array[1] != .nil) {
                    current_hl = switch (cell.array[1]) {
                        .unsigned => |u| @as(u32, @intCast(u)),
                        .integer => |i| @as(u32, @intCast(i)),
                        else => current_hl,
                    };
                }

                const repeat: usize = if (cell.array.len > 2 and cell.array[2] != .nil)
                    switch (cell.array[2]) {
                        .unsigned => |u| @intCast(u),
                        .integer => |i| @intCast(i),
                        else => 1,
                    }
                else
                    1;

                const style = self.hl_attrs.get(current_hl) orelse vaxis.Style{};

                var i: usize = 0;
                while (i < repeat) : (i += 1) {
                    if (col < self.cols and row < self.rows) {
                        self.back.writeCell(@intCast(col), @intCast(row), .{
                            .char = .{ .grapheme = text },
                            .style = style,
                        });
                    }
                    col += 1;
                }
            }
            self.dirty = true;
        } else if (std.mem.eql(u8, event_name.string, "style")) {
            if (event_params.array.len < 2) continue;

            // args: [id, map]
            const id = switch (event_params.array[0]) {
                .unsigned => |u| @as(u32, @intCast(u)),
                .integer => |i| @as(u32, @intCast(i)),
                else => continue,
            };

            const attrs = event_params.array[1];
            if (attrs != .map) continue;

            var style = vaxis.Style{};

            for (attrs.map) |kv| {
                if (kv.key != .string) continue;
                const key = kv.key.string;

                if (std.mem.eql(u8, key, "fg")) {
                    if (kv.value == .unsigned) {
                        const val = @as(u32, @intCast(kv.value.unsigned));
                        style.fg = .{ .rgb = .{
                            @intCast((val >> 16) & 0xFF),
                            @intCast((val >> 8) & 0xFF),
                            @intCast(val & 0xFF),
                        } };
                    }
                } else if (std.mem.eql(u8, key, "fg_idx")) {
                    if (kv.value == .unsigned) {
                        style.fg = .{ .index = @intCast(kv.value.unsigned) };
                    }
                } else if (std.mem.eql(u8, key, "bg")) {
                    if (kv.value == .unsigned) {
                        const val = @as(u32, @intCast(kv.value.unsigned));
                        style.bg = .{ .rgb = .{
                            @intCast((val >> 16) & 0xFF),
                            @intCast((val >> 8) & 0xFF),
                            @intCast(val & 0xFF),
                        } };
                    }
                } else if (std.mem.eql(u8, key, "bg_idx")) {
                    if (kv.value == .unsigned) {
                        style.bg = .{ .index = @intCast(kv.value.unsigned) };
                    }
                } else if (std.mem.eql(u8, key, "bold")) {
                    if (kv.value == .boolean) style.bold = kv.value.boolean;
                } else if (std.mem.eql(u8, key, "dim")) {
                    if (kv.value == .boolean) style.dim = kv.value.boolean;
                } else if (std.mem.eql(u8, key, "italic")) {
                    if (kv.value == .boolean) style.italic = kv.value.boolean;
                } else if (std.mem.eql(u8, key, "underline")) {
                    if (kv.value == .boolean and kv.value.boolean) {
                        style.ul_style = .single;
                    }
                } else if (std.mem.eql(u8, key, "reverse")) {
                    if (kv.value == .boolean) style.reverse = kv.value.boolean;
                } else if (std.mem.eql(u8, key, "blink")) {
                    if (kv.value == .boolean) style.blink = kv.value.boolean;
                }
            }

            try self.hl_attrs.put(id, style);
        } else if (std.mem.eql(u8, event_name.string, "flush")) {
            // Flush marks the end of a frame - copy back to front now

            std.log.debug("flush: copying back→front", .{});
            for (0..self.rows) |row| {
                for (0..self.cols) |col| {
                    if (self.back.readCell(@intCast(col), @intCast(row))) |cell| {
                        self.front.writeCell(@intCast(col), @intCast(row), cell);
                    }
                }
            }
            self.front.cursor_row = self.back.cursor_row;
            self.front.cursor_col = self.back.cursor_col;
            self.front.cursor_vis = self.back.cursor_vis;

            // Debug: check what got copied to front at (0,0)
            if (self.front.readCell(0, 0)) |cell| {
                std.log.debug("flush: front(0,0) after copy = '{s}'", .{cell.char.grapheme});
            }
        }
    }

    std.log.debug("applyRedraw: updated {} rows", .{rows_updated.items.len});
}

pub fn render(self: *Surface, win: vaxis.Window) void {
    if (!self.dirty) return;

    std.log.debug("render: copying front→vaxis window", .{});

    var cells_written: usize = 0;
    // Copy front buffer to vaxis window
    for (0..self.rows) |row| {
        for (0..self.cols) |col| {
            if (col < win.width and row < win.height) {
                const cell = self.front.readCell(@intCast(col), @intCast(row)) orelse continue;

                // Debug: log what we write to (0,0)
                if (row == 0 and col == 0) {
                    std.log.debug("render: writing to (0,0): '{s}'", .{cell.char.grapheme});
                }

                win.writeCell(@intCast(col), @intCast(row), cell);
                cells_written += 1;
            }
        }
    }
    std.log.debug("render: wrote {} cells to vaxis window", .{cells_written});

    // Copy cursor state to window
    if (self.front.cursor_vis and
        self.front.cursor_col < win.width and
        self.front.cursor_row < win.height)
    {
        win.showCursor(self.front.cursor_col, self.front.cursor_row);
        const shape: vaxis.Cell.CursorShape = switch (self.cursor_shape) {
            .block => .block,
            .beam => .beam,
            .underline => .underline,
        };
        win.setCursorShape(shape);
    } else {
        win.hideCursor();
    }

    self.dirty = false;
}
