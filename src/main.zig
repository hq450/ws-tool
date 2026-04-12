const std = @import("std");

const Allocator = std.mem.Allocator;
const http = std.http;
const net = std.net;
const process = std.process;

const version_text = "0.1.0";

const default_port: u16 = 8080;
const max_header_value_len: usize = 4096;
const max_line_len: usize = 16384;

const Config = struct {
    allocator: Allocator,
    address: []const u8 = "0.0.0.0",
    port: u16 = default_port,
    passenv: []const []const u8 = &.{ "PATH", "DYLD_LIBRARY_PATH" },
    command_argv: []const []const u8,
};

const Shared = struct {
    allocator: Allocator,
    ws: *http.Server.WebSocket,
    stream: net.Stream,
    child: process.Child,
    child_exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    pipe_threads_done: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    stream_closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    write_mutex: std.Thread.Mutex = .{},
    close_mutex: std.Thread.Mutex = .{},

    fn closeStream(self: *Shared) void {
        self.close_mutex.lock();
        defer self.close_mutex.unlock();
        if (self.stream_closed.load(.acquire)) return;
        self.stream_closed.store(true, .release);
        self.stream.close();
    }

    fn gracefulCloseStream(self: *Shared) void {
        self.close_mutex.lock();
        defer self.close_mutex.unlock();
        if (self.stream_closed.load(.acquire)) return;
        std.Thread.sleep(1000 * std.time.ns_per_ms);
        self.stream_closed.store(true, .release);
        self.stream.close();
    }

    fn terminateChild(self: *Shared) void {
        if (self.child_exited.load(.acquire)) return;
        if (self.child.stdin) |*stdin_file| {
            stdin_file.close();
            self.child.stdin = null;
        }
        if (builtin.os.tag != .windows) {
            std.posix.kill(self.child.id, std.posix.SIG.TERM) catch {};
        }
    }

    fn writeFrame(self: *Shared, data: []const u8, opcode: http.Server.WebSocket.Opcode) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        if (self.stream_closed.load(.acquire)) return error.ConnectionClosed;
        try self.ws.writeMessage(data, opcode);
        try self.ws.flush();
    }

    fn markPipeDoneAndMaybeClose(self: *Shared) void {
        const done = self.pipe_threads_done.fetchAdd(1, .acq_rel) + 1;
        if (done >= 2 and self.child_exited.load(.acquire)) {
            self.gracefulCloseStream();
        }
    }
};

const builtin = @import("builtin");

const ConnectionThreadArgs = struct {
    config: *const Config,
    connection: net.Server.Connection,
};

const PipeThreadArgs = struct {
    shared: *Shared,
    file: *std.fs.File,
};

const WaitThreadArgs = struct {
    shared: *Shared,
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const config = try parseArgs(allocator, args);

    const listen_addr = try parseListenAddress(config.address, config.port);
    var server = try listen_addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    while (true) {
        const connection = server.accept() catch |err| {
            std.log.err("accept failed: {s}", .{@errorName(err)});
            continue;
        };
        const thread = try std.Thread.spawn(.{}, connectionThreadMain, .{ConnectionThreadArgs{
            .config = config,
            .connection = connection,
        }});
        thread.detach();
    }
}

fn parseArgs(allocator: Allocator, args: []const [:0]u8) !*Config {
    const cfg = try allocator.create(Config);
    errdefer allocator.destroy(cfg);
    cfg.* = .{
        .allocator = allocator,
        .command_argv = &.{},
    };

    var passenv_list = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    defer if (cfg.command_argv.len == 0) passenv_list.deinit(allocator);
    try passenv_list.append(allocator, "PATH");
    try passenv_list.append(allocator, "DYLD_LIBRARY_PATH");

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try std.fs.File.stdout().deprecatedWriter().print("{s}\n", .{version_text});
            std.process.exit(0);
        }
        if (std.mem.startsWith(u8, arg, "--port=")) {
            cfg.port = try parsePort(arg["--port=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) return error.MissingPortValue;
            cfg.port = try parsePort(args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--address=")) {
            cfg.address = arg["--address=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--address")) {
            i += 1;
            if (i >= args.len) return error.MissingAddressValue;
            cfg.address = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--passenv=")) {
            passenv_list.clearRetainingCapacity();
            try parsePassenvList(allocator, &passenv_list, arg["--passenv=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--passenv")) {
            i += 1;
            if (i >= args.len) return error.MissingPassenvValue;
            passenv_list.clearRetainingCapacity();
            try parsePassenvList(allocator, &passenv_list, args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnsupportedOption;
        }
        const cmd_list = try allocator.alloc([]const u8, args.len - i);
        for (args[i..], 0..) |item, idx| {
            cmd_list[idx] = item;
        }
        cfg.command_argv = cmd_list;
        break;
    }

    if (cfg.command_argv.len == 0) {
        printHelp();
        return error.MissingCommand;
    }

    cfg.passenv = try passenv_list.toOwnedSlice(allocator);
    return cfg;
}

fn parsePassenvList(allocator: Allocator, list: *std.ArrayList([]const u8), raw: []const u8) !void {
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) continue;
        try list.append(allocator, trimmed);
    }
}

fn parsePort(raw: []const u8) !u16 {
    return try std.fmt.parseInt(u16, raw, 10);
}

fn parseListenAddress(addr: []const u8, port: u16) !net.Address {
    if (std.mem.indexOfScalar(u8, addr, ':') != null) {
        return try net.Address.parseIp6(addr, port);
    }
    return try net.Address.parseIp4(addr, port);
}

fn printHelp() void {
    const out = std.fs.File.stdout().deprecatedWriter();
    out.print(
        \\Usage:
        \\  websocketd [--address ADDR] [--port PORT] [--passenv VAR1,VAR2] command [args...]
        \\
        \\Supported options:
        \\  --address ADDR         Listen address, default 0.0.0.0
        \\  --port PORT            Listen port, default 8080
        \\  --passenv LIST         Comma-separated env names to pass through
        \\  --help, -h             Show this help
        \\  --version, -v          Show version
        \\
        \\This implementation focuses on fancyss websocketd compatibility.
        \\
    , .{}) catch {};
}

fn connectionThreadMain(args: ConnectionThreadArgs) void {
    defer args.connection.stream.close();

    var send_buffer: [4096]u8 = undefined;
    var recv_buffer: [4096]u8 = undefined;
    var connection_reader = args.connection.stream.reader(&recv_buffer);
    var connection_writer = args.connection.stream.writer(&send_buffer);
    var server: http.Server = .init(connection_reader.interface(), &connection_writer.interface);

    var request = server.receiveHead() catch return;
    switch (request.upgradeRequested()) {
        .websocket => |opt_key| {
            const key = opt_key orelse return;
            var ws = request.respondWebSocket(.{ .key = key }) catch return;
            ws.flush() catch return;
            serveWebSocket(args.config, &ws, args.connection, &request) catch {};
        },
        else => {
            request.respond("ws-tool websocketd replacement\n", .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
                },
            }) catch {};
        },
    }
}

fn serveWebSocket(config: *const Config, ws: *http.Server.WebSocket, connection: net.Server.Connection, request: *http.Server.Request) !void {
    var arena_state = std.heap.ArenaAllocator.init(config.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env_map = try buildChildEnv(arena, config, connection, request);
    var child = process.Child.init(config.command_argv, arena);
    child.env_map = &env_map;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var shared = Shared{
        .allocator = arena,
        .ws = ws,
        .stream = connection.stream,
        .child = child,
    };

    var stdout_file = shared.child.stdout.?;
    var stderr_file = shared.child.stderr.?;

    const stdout_thread = try std.Thread.spawn(.{}, pipeThreadMain, .{PipeThreadArgs{ .shared = &shared, .file = &stdout_file }});
    const stderr_thread = try std.Thread.spawn(.{}, pipeThreadMain, .{PipeThreadArgs{ .shared = &shared, .file = &stderr_file }});
    const wait_thread = try std.Thread.spawn(.{}, waitThreadMain, .{WaitThreadArgs{ .shared = &shared }});

    readLoop(&shared);

    shared.terminateChild();

    wait_thread.join();
    stdout_thread.join();
    stderr_thread.join();
    shared.gracefulCloseStream();
}

fn readLoop(shared: *Shared) void {
    while (true) {
        const msg = shared.ws.readSmallMessage() catch break;
        switch (msg.opcode) {
            .ping => {
                shared.writeFrame(msg.data, .pong) catch break;
            },
            .text, .binary => {
                if (shared.child.stdin) |*stdin_file| {
                    stdin_file.writeAll(msg.data) catch break;
                    stdin_file.writeAll("\n") catch break;
                } else break;
            },
            else => {},
        }
    }
}

fn pipeThreadMain(args: PipeThreadArgs) void {
    defer args.shared.markPipeDoneAndMaybeClose();
    var buf: [4096]u8 = undefined;
    var line_buf: [max_line_len]u8 = undefined;
    var line_len: usize = 0;
    var overflow = false;
    while (true) {
        const n = args.file.read(&buf) catch break;
        if (n == 0) break;
        for (buf[0..n]) |byte| {
            if (byte == '\n') {
                if (overflow) {
                    args.shared.writeFrame("[ws-tool] output line too long", .text) catch {};
                    overflow = false;
                    line_len = 0;
                    continue;
                }
                var clean = line_buf[0..line_len];
                if (clean.len > 0 and clean[clean.len - 1] == '\r') {
                    clean = clean[0 .. clean.len - 1];
                }
                if (clean.len > 0) {
                    args.shared.writeFrame(clean, .text) catch return;
                }
                line_len = 0;
                continue;
            }
            if (overflow) continue;
            if (line_len >= line_buf.len) {
                overflow = true;
                continue;
            }
            line_buf[line_len] = byte;
            line_len += 1;
        }
        // fancyss also uses websocketd as a lightweight command transport, and
        // some commands intentionally print a single line without a trailing newline.
        // Flush only the valid UTF-8 prefix so text frames never split a multibyte rune.
        if (!overflow and line_len > 0) {
            flushValidUtf8Prefix(args.shared, &line_buf, &line_len) catch return;
        }
    }
    if (overflow) {
        args.shared.writeFrame("[ws-tool] output line too long", .text) catch {};
    } else if (line_len > 0) {
        var clean = line_buf[0..line_len];
        if (clean.len > 0 and clean[clean.len - 1] == '\r') {
            clean = clean[0 .. clean.len - 1];
        }
        if (clean.len > 0) {
            args.shared.writeFrame(clean, .text) catch {};
        }
    }
}

fn flushValidUtf8Prefix(shared: *Shared, line_buf: *[max_line_len]u8, line_len: *usize) !void {
    const current = line_buf[0..line_len.*];
    const prefix_len = validUtf8PrefixLen(current);
    if (prefix_len == 0) return;

    try shared.writeFrame(current[0..prefix_len], .text);

    const remain = line_len.* - prefix_len;
    if (remain > 0) {
        std.mem.copyForwards(u8, line_buf[0..remain], line_buf[prefix_len..line_len.*]);
    }
    line_len.* = remain;
}

fn validUtf8PrefixLen(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes.len;

    var trim: usize = 1;
    while (trim <= 3 and trim < bytes.len) : (trim += 1) {
        const candidate_len = bytes.len - trim;
        if (std.unicode.utf8ValidateSlice(bytes[0..candidate_len])) {
            return candidate_len;
        }
    }
    return 0;
}

fn waitThreadMain(args: WaitThreadArgs) void {
    _ = args.shared.child.wait() catch {};
    args.shared.child_exited.store(true, .release);
    if (args.shared.pipe_threads_done.load(.acquire) >= 2) {
        args.shared.gracefulCloseStream();
    }
}

fn buildChildEnv(arena: Allocator, config: *const Config, connection: net.Server.Connection, request: *http.Server.Request) !process.EnvMap {
    var env_map = process.EnvMap.init(arena);

    var current_env = try process.getEnvMap(arena);
    defer current_env.deinit();

    for (config.passenv) |name| {
        if (current_env.get(name)) |value| {
            try env_map.put(name, value);
        }
    }

    const request_uri = request.head.target;
    const path_info = request_uri[0 .. std.mem.indexOfScalar(u8, request_uri, '?') orelse request_uri.len];
    const query_string = if (std.mem.indexOfScalar(u8, request_uri, '?')) |idx| request_uri[idx + 1 ..] else "";

    const remote_addr = try formatRemoteAddr(arena, connection.address);
    const remote_port = try std.fmt.allocPrint(arena, "{d}", .{connection.address.getPort()});

    const host_header = getHeader(request, "host");
    const server_name = try deriveServerName(arena, host_header orelse config.address);
    const server_port = try std.fmt.allocPrint(arena, "{d}", .{config.port});

    try env_map.put("GATEWAY_INTERFACE", "CGI/1.1");
    try env_map.put("SERVER_SOFTWARE", "ws-tool/0.1");
    try env_map.put("SERVER_PROTOCOL", "HTTP/1.1");
    try env_map.put("REQUEST_METHOD", "GET");
    try env_map.put("REQUEST_URI", request_uri);
    try env_map.put("PATH_INFO", path_info);
    try env_map.put("QUERY_STRING", query_string);
    try env_map.put("REMOTE_ADDR", remote_addr);
    try env_map.put("REMOTE_PORT", remote_port);
    try env_map.put("SERVER_NAME", server_name);
    try env_map.put("SERVER_PORT", server_port);

    var header_it = request.iterateHeaders();
    while (header_it.next()) |header| {
        try putHeaderEnv(arena, &env_map, header.name, header.value);
    }

    return env_map;
}

fn getHeader(request: *http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn putHeaderEnv(arena: Allocator, env_map: *process.EnvMap, name: []const u8, value: []const u8) !void {
    var key_buf = try arena.alloc(u8, 5 + name.len);
    @memcpy(key_buf[0..5], "HTTP_");
    for (name, 0..) |c, idx| {
        key_buf[5 + idx] = switch (c) {
            '-' => '_',
            'a'...'z' => c - ('a' - 'A'),
            else => c,
        };
    }
    try env_map.put(key_buf, value);
}

fn deriveServerName(arena: Allocator, raw: []const u8) ![]const u8 {
    if (raw.len == 0) return arena.dupe(u8, "localhost");
    if (raw[0] == '[') {
        if (std.mem.indexOfScalar(u8, raw, ']')) |idx| {
            return arena.dupe(u8, raw[1..idx]);
        }
    }
    if (std.mem.lastIndexOfScalar(u8, raw, ':')) |idx| {
        if (std.mem.indexOfScalar(u8, raw, ':') == idx) {
            return arena.dupe(u8, raw[0..idx]);
        }
    }
    return arena.dupe(u8, raw);
}

fn formatRemoteAddr(arena: Allocator, address: net.Address) ![]const u8 {
    return switch (address.any.family) {
        std.posix.AF.INET => blk: {
            const bytes: *const [4]u8 = @ptrCast(&address.in.sa.addr);
            break :blk std.fmt.allocPrint(arena, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
        },
        std.posix.AF.INET6 => blk: {
            var full = try std.fmt.allocPrint(arena, "{f}", .{address});
            if (full.len >= 2 and full[0] == '[') {
                if (std.mem.indexOfScalar(u8, full, ']')) |idx| {
                    break :blk arena.dupe(u8, full[1..idx]);
                }
            }
            break :blk arena.dupe(u8, full);
        },
        else => arena.dupe(u8, "unknown"),
    };
}
