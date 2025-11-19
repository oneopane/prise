const std = @import("std");
const ziglua = @import("zlua");
const vaxis = @import("vaxis");

pub const Event = union(enum) {
    vaxis: vaxis.Event,
    pty_attach: u32,
};

pub fn pushEvent(lua: *ziglua.Lua, event: Event) !void {
    lua.createTable(0, 2);

    switch (event) {
        .pty_attach => |pty_id| {
            _ = lua.pushString("pty_attach");
            lua.setField(-2, "type");

            lua.createTable(0, 1);
            lua.pushInteger(@intCast(pty_id));
            lua.setField(-2, "pty");

            lua.setField(-2, "data");
        },

        .vaxis => |vaxis_event| switch (vaxis_event) {
            .key_press => |key| {
                _ = lua.pushString("key_press");
                lua.setField(-2, "type");

                lua.createTable(0, 5);

                if (key.codepoint != 0) {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(key.codepoint, &buf) catch 0;
                    if (len > 0) {
                        _ = lua.pushString(buf[0..len :0]);
                        lua.setField(-2, "key");
                    }
                }

                lua.pushBoolean(key.mods.ctrl);
                lua.setField(-2, "ctrl");

                lua.pushBoolean(key.mods.alt);
                lua.setField(-2, "alt");

                lua.pushBoolean(key.mods.shift);
                lua.setField(-2, "shift");

                lua.pushBoolean(key.mods.super);
                lua.setField(-2, "super");

                lua.setField(-2, "data");
            },

            .winsize => |ws| {
                _ = lua.pushString("winsize");
                lua.setField(-2, "type");

                lua.createTable(0, 4);
                lua.pushInteger(@intCast(ws.rows));
                lua.setField(-2, "rows");
                lua.pushInteger(@intCast(ws.cols));
                lua.setField(-2, "cols");
                lua.pushInteger(@intCast(ws.x_pixel));
                lua.setField(-2, "width");
                lua.pushInteger(@intCast(ws.y_pixel));
                lua.setField(-2, "height");

                lua.setField(-2, "data");
            },

            else => {
                _ = lua.pushString("unknown");
                lua.setField(-2, "type");
            },
        },
    }
}
