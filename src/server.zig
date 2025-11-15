const std = @import("std");
const loop = @import("loop.zig");
const posix = std.posix;

const Client = struct {
    fd: posix.fd_t,
    server: *Server,
    recv_buffer: [4096]u8 = undefined,

    fn onRecv(rt: *loop.Loop, completion: loop.Completion) anyerror!void {
        const client = completion.userdataCast(Client);

        switch (completion.result) {
            .recv => |bytes_read| {
                if (bytes_read == 0) {
                    // EOF - client disconnected
                    client.server.removeClient(client);
                } else {
                    // Got data, ignore for now and keep receiving
                    _ = try rt.recv(client.fd, &client.recv_buffer, .{
                        .ptr = client,
                        .cb = onRecv,
                    });
                }
            },
            .err => |err| {
                std.debug.print("Recv error: {}\n", .{err});
                client.server.removeClient(client);
            },
            else => unreachable,
        }
    }
};

const Server = struct {
    allocator: std.mem.Allocator,
    rt: *loop.Loop,
    listen_fd: posix.fd_t,
    socket_path: []const u8,
    clients: std.ArrayList(*Client),
    pty_count: usize = 0,
    accepting: bool = true,
    accept_task: ?loop.Task = null,

    fn shouldExit(self: *Server) bool {
        return self.clients.items.len == 0 and self.pty_count == 0;
    }

    fn checkExit(self: *Server) !void {
        if (self.shouldExit() and self.accepting) {
            self.accepting = false;
            if (self.accept_task) |*task| {
                try task.cancel(self.rt);
                self.accept_task = null;
            }
        }
    }

    fn onAccept(rt: *loop.Loop, completion: loop.Completion) anyerror!void {
        const self = completion.userdataCast(Server);

        switch (completion.result) {
            .accept => |client_fd| {
                const client = try self.allocator.create(Client);
                client.* = .{
                    .fd = client_fd,
                    .server = self,
                };
                try self.clients.append(self.allocator, client);

                // Start recv to detect disconnect
                _ = try rt.recv(client_fd, &client.recv_buffer, .{
                    .ptr = client,
                    .cb = Client.onRecv,
                });

                // Queue next accept if still accepting
                if (self.accepting) {
                    self.accept_task = try rt.accept(self.listen_fd, .{
                        .ptr = self,
                        .cb = onAccept,
                    });
                }
            },
            .err => |err| {
                std.debug.print("Accept error: {}\n", .{err});
            },
            else => unreachable,
        }
    }

    fn removeClient(self: *Server, client: *Client) void {
        for (self.clients.items, 0..) |c, i| {
            if (c == client) {
                _ = self.clients.swapRemove(i);
                break;
            }
        }
        posix.close(client.fd);
        self.allocator.destroy(client);
        try self.checkExit();
    }
};

pub fn startServer(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    var rt = try loop.Loop.init(allocator);
    defer rt.deinit();

    // Create socket
    const listen_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(listen_fd);

    // Bind to socket path
    var addr: posix.sockaddr.un = undefined;
    addr.family = posix.AF.UNIX;
    @memcpy(addr.path[0..socket_path.len], socket_path);
    addr.path[socket_path.len] = 0;

    try posix.bind(listen_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

    // Listen
    try posix.listen(listen_fd, 128);

    var server: Server = .{
        .allocator = allocator,
        .rt = &rt,
        .listen_fd = listen_fd,
        .socket_path = socket_path,
        .clients = std.ArrayList(*Client).empty,
    };
    defer {
        for (server.clients.items) |client| {
            posix.close(client.fd);
            allocator.destroy(client);
        }
        server.clients.deinit(allocator);
    }

    // Start accepting connections
    server.accept_task = try rt.accept(listen_fd, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    // Run until server decides to exit
    try rt.run(.until_done);

    // Cleanup
    posix.close(listen_fd);
    posix.unlink(socket_path) catch {};
}
