const std = @import("std");
const ziglua = @import("zlua");

pub const BoxConstraints = struct {
    min_width: u16,
    max_width: ?u16,
    min_height: u16,
    max_height: ?u16,
};

pub const Size = struct {
    width: u16,
    height: u16,
};

pub const Widget = struct {
    x: u16 = 0,
    y: u16 = 0,
    width: u16 = 0,
    height: u16 = 0,
    kind: WidgetKind,

    pub fn deinit(self: *Widget, allocator: std.mem.Allocator) void {
        _ = allocator;
        switch (self.kind) {
            .surface => {},
        }
    }

    pub fn layout(self: *Widget, constraints: BoxConstraints) Size {
        const size = switch (self.kind) {
            .surface => Size{
                .width = constraints.max_width.?,
                .height = constraints.max_height.?,
            },
        };
        self.width = size.width;
        self.height = size.height;
        return size;
    }

    pub fn paint(self: *const Widget) !void {
        switch (self.kind) {
            .surface => |surface| {
                _ = surface;
                // TODO: paint surface at self.x, self.y, self.width, self.height
            },
        }
    }
};

pub const WidgetKind = union(enum) {
    surface: Surface,
};

pub const Surface = struct {
    pty_id: u32,
};

pub fn parseWidget(lua: *ziglua.Lua, allocator: std.mem.Allocator, index: i32) !Widget {
    _ = allocator;

    if (lua.typeOf(index) != .table) {
        return error.InvalidWidget;
    }

    _ = lua.getField(index, "type");
    if (lua.typeOf(-1) != .string) {
        lua.pop(1);
        return error.MissingWidgetType;
    }
    const widget_type = try lua.toString(-1);
    lua.pop(1);

    if (std.mem.eql(u8, widget_type, "surface")) {
        _ = lua.getField(index, "pty");

        if (lua.typeOf(-1) != .number) {
            lua.pop(1);
            return error.MissingPtyId;
        }

        const pty_id = try lua.toInteger(-1);
        lua.pop(1);

        return .{ .kind = .{ .surface = .{ .pty_id = @intCast(pty_id) } } };
    }

    return error.UnknownWidgetType;
}
