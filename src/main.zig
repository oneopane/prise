const std = @import("std");
const loop = @import("loop.zig");
const server = @import("server.zig");
const posix = std.posix;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const uid = posix.getuid();
    var buffer: [256]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&buffer, "/tmp/prise-{d}.sock", .{uid});

    // Check if socket exists
    std.fs.accessAbsolute(socket_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            const pid = try posix.fork();
            if (pid == 0) {
                // Child process - daemonize
                _ = posix.setsid() catch |e| {
                    std.debug.print("setsid failed: {}\n", .{e});
                    std.posix.exit(1);
                };

                // Fork again to prevent acquiring controlling terminal
                const pid2 = try posix.fork();
                if (pid2 != 0) {
                    // First child exits
                    std.posix.exit(0);
                }

                // Grandchild - actual server daemon
                // Close stdio
                posix.close(posix.STDIN_FILENO);
                posix.close(posix.STDOUT_FILENO);
                posix.close(posix.STDERR_FILENO);

                // Start server
                try server.startServer(allocator, socket_path);
                return;
            } else {
                // Parent process - wait for socket to appear
                std.debug.print("Forked server with PID {}\n", .{pid});
                var retries: u8 = 0;
                while (retries < 10) : (retries += 1) {
                    std.Thread.sleep(50 * std.time.ns_per_ms);
                    std.fs.accessAbsolute(socket_path, .{}) catch continue;
                    break;
                }
            }
        } else {
            return err;
        }
    };

    std.debug.print("Connecting to server at {s}\n", .{socket_path});

    var rt = try loop.Loop.init(allocator);
    defer rt.deinit();

    const App = struct {
        connected: bool = false,
        connection_refused: bool = false,
        fd: posix.fd_t = undefined,

        fn onConnected(_: *loop.Loop, completion: loop.Completion) anyerror!void {
            const app = completion.userdataCast(@This());

            switch (completion.result) {
                .socket => |fd| {
                    app.fd = fd;
                    app.connected = true;
                    std.debug.print("Connected! fd={}\n", .{app.fd});
                },
                .err => |err| {
                    if (err == error.ConnectionRefused) {
                        app.connection_refused = true;
                    } else {
                        std.debug.print("Connection failed: {}\n", .{err});
                    }
                },
                else => unreachable,
            }
        }
    };

    var app: App = .{};

    _ = try connectUnixSocket(
        &rt,
        socket_path,
        .{ .ptr = &app, .cb = App.onConnected },
    );

    try rt.run(.until_done);

    if (app.connection_refused) {
        // Stale socket - remove it and fork server
        std.debug.print("Stale socket detected, removing and starting server\n", .{});
        posix.unlink(socket_path) catch {};

        const pid = try posix.fork();
        if (pid == 0) {
            // Child process - daemonize
            _ = posix.setsid() catch |e| {
                std.debug.print("setsid failed: {}\n", .{e});
                std.posix.exit(1);
            };

            // Fork again to prevent acquiring controlling terminal
            const pid2 = try posix.fork();
            if (pid2 != 0) {
                // First child exits
                std.posix.exit(0);
            }

            // Grandchild - actual server daemon
            // Close stdio
            posix.close(posix.STDIN_FILENO);
            posix.close(posix.STDOUT_FILENO);
            posix.close(posix.STDERR_FILENO);

            // Start server
            try server.startServer(allocator, socket_path);
            return;
        } else {
            // Parent process - wait for socket to appear then retry
            std.debug.print("Forked server with PID {}\n", .{pid});
            var retries: u8 = 0;
            while (retries < 10) : (retries += 1) {
                std.Thread.sleep(50 * std.time.ns_per_ms);
                std.fs.accessAbsolute(socket_path, .{}) catch continue;
                break;
            }

            // Retry connection
            rt = try loop.Loop.init(allocator);
            app = .{};
            _ = try connectUnixSocket(
                &rt,
                socket_path,
                .{ .ptr = &app, .cb = App.onConnected },
            );
            try rt.run(.until_done);
        }
    }

    if (app.connected) {
        defer posix.close(app.fd);
        std.debug.print("Connection successful!\n", .{});
    }
}

const UnixSocketClient = struct {
    allocator: std.mem.Allocator,
    fd: ?posix.fd_t = null,
    ctx: loop.Context,
    addr: posix.sockaddr.un,

    const Msg = enum {
        socket,
        connect,
    };

    fn handleMsg(rt: *loop.Loop, completion: loop.Completion) anyerror!void {
        const self = completion.userdataCast(UnixSocketClient);

        switch (completion.msgToEnum(Msg)) {
            .socket => {
                switch (completion.result) {
                    .socket => |fd| {
                        self.fd = fd;
                        _ = try rt.connect(
                            fd,
                            @ptrCast(&self.addr),
                            @sizeOf(posix.sockaddr.un),
                            .{
                                .ptr = self,
                                .msg = @intFromEnum(Msg.connect),
                                .cb = UnixSocketClient.handleMsg,
                            },
                        );
                    },
                    .err => |err| {
                        defer self.allocator.destroy(self);
                        try self.ctx.cb(rt, .{
                            .userdata = self.ctx.ptr,
                            .msg = self.ctx.msg,
                            .callback = self.ctx.cb,
                            .result = .{ .err = err },
                        });
                    },
                    else => unreachable,
                }
            },

            .connect => {
                defer self.allocator.destroy(self);

                switch (completion.result) {
                    .connect => {
                        try self.ctx.cb(rt, .{
                            .userdata = self.ctx.ptr,
                            .msg = self.ctx.msg,
                            .callback = self.ctx.cb,
                            .result = .{ .socket = self.fd.? },
                        });
                    },
                    .err => |err| {
                        try self.ctx.cb(rt, .{
                            .userdata = self.ctx.ptr,
                            .msg = self.ctx.msg,
                            .callback = self.ctx.cb,
                            .result = .{ .err = err },
                        });
                        if (self.fd) |fd| {
                            _ = try rt.close(fd, .{
                                .ptr = null,
                                .cb = struct {
                                    fn noop(_: *loop.Loop, _: loop.Completion) anyerror!void {}
                                }.noop,
                            });
                        }
                    },
                    else => unreachable,
                }
            },
        }
    }
};

fn connectUnixSocket(
    rt: *loop.Loop,
    socket_path: []const u8,
    ctx: loop.Context,
) !*UnixSocketClient {
    const client = try rt.allocator.create(UnixSocketClient);
    errdefer rt.allocator.destroy(client);

    var addr: posix.sockaddr.un = undefined;
    addr.family = posix.AF.UNIX;
    @memcpy(addr.path[0..socket_path.len], socket_path);
    addr.path[socket_path.len] = 0;

    client.* = .{
        .allocator = rt.allocator,
        .ctx = ctx,
        .addr = addr,
        .fd = null,
    };

    _ = try rt.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        0,
        .{
            .ptr = client,
            .msg = @intFromEnum(UnixSocketClient.Msg.socket),
            .cb = UnixSocketClient.handleMsg,
        },
    );

    return client;
}
