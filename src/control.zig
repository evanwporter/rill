const std = @import("std");
const types = @import("types.zig");

// A session-local datagram socket lets bar buttons focus a specific window
// without synthesizing keyboard input or polling the filesystem.
const Address = extern struct { family: u16 = 1, path: [108]u8 = @splat(0) };
const PollFd = extern struct { fd: c_int, events: c_short = 1, revents: c_short = 0 };
extern "c" fn socket(c_int, c_int, c_int) c_int;
extern "c" fn bind(c_int, *const Address, u32) c_int;
extern "c" fn sendto(c_int, [*]const u8, usize, c_int, *const Address, u32) isize;
extern "c" fn recv(c_int, [*]u8, usize, c_int) isize;
extern "c" fn close(c_int) c_int;
extern "c" fn unlink([*:0]const u8) c_int;
extern "c" fn chmod([*:0]const u8, c_uint) c_int;
extern "c" fn poll([*]PollFd, usize, c_int) c_int;

fn address(env: *std.process.Environ.Map) !Address {
    const runtime = env.get("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDirectory;
    const display = env.get("WAYLAND_DISPLAY") orelse "wayland-0";
    if (std.mem.indexOfScalar(u8, display, '/') != null) return error.InvalidDisplay;
    var addr: Address = .{};
    _ = try std.fmt.bufPrint(addr.path[0 .. addr.path.len - 1], "{s}/rill-{s}-control.sock", .{ runtime, display });
    return addr;
}

pub fn client(init: std.process.Init) !bool {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or !std.mem.eql(u8, args[1], "msg")) return false;
    if (args.len < 5 or args.len > 6) return error.UsageRillMsgFocusWindowOutputWorkspaceWindow;
    const is_window = std.mem.eql(u8, args[2], "focus-window");
    if ((!is_window and !std.mem.eql(u8, args[2], "focus-workspace")) or
        args.len != (if (is_window) @as(usize, 6) else 5)) return error.InvalidCommand;
    for (args[3..]) |arg| {
        if (try std.fmt.parseInt(usize, arg, 10) == 0) return error.InvalidIndex;
    }
    const addr = try address(init.environ_map);
    const fd = socket(1, 2 | 0x80000, 0); // AF_UNIX, SOCK_DGRAM | CLOEXEC
    if (fd < 0) return error.SocketFailed;
    defer _ = close(fd);
    const message = try std.mem.join(init.arena.allocator(), " ", args[2..]);
    if (sendto(fd, message.ptr, message.len, 0, &addr, @sizeOf(Address)) != message.len)
        return error.RillControlUnavailable;
    return true;
}

pub const Server = struct {
    fd: c_int,
    addr: Address,

    pub fn init(wm: *types.WindowManager) !Server {
        const addr = try address(wm.environ_map);
        const fd = socket(1, 2 | 0x800 | 0x80000, 0); // NONBLOCK | CLOEXEC
        if (fd < 0) return error.SocketFailed;
        errdefer _ = close(fd);
        _ = unlink(@ptrCast(&addr.path));
        if (bind(fd, &addr, @sizeOf(Address)) != 0) return error.BindFailed;
        errdefer _ = unlink(@ptrCast(&addr.path));
        if (chmod(@ptrCast(&addr.path), 0o600) != 0) return error.ChmodFailed;
        return .{ .fd = fd, .addr = addr };
    }

    pub fn deinit(self: *Server) void {
        _ = close(self.fd);
        _ = unlink(@ptrCast(&self.addr.path));
    }

    pub fn wait(self: *Server, display_fd: c_int) struct { wayland: bool, command: bool } {
        var fds = [_]PollFd{ .{ .fd = display_fd }, .{ .fd = self.fd } };
        if (poll(&fds, fds.len, -1) < 0) return .{ .wayland = false, .command = false };
        return .{ .wayland = fds[0].revents != 0, .command = fds[1].revents & 1 != 0 };
    }

    pub fn receive(self: *Server, wm: *types.WindowManager) void {
        var buffer: [256]u8 = undefined;
        while (true) {
            const len = recv(self.fd, &buffer, buffer.len, 0);
            if (len <= 0) return;
            apply(wm, buffer[0..@intCast(len)]);
        }
    }
};

fn apply(wm: *types.WindowManager, message: []const u8) void {
    if (wm.task == .exit or wm.task == .pointer_action) return;
    var words = std.mem.tokenizeScalar(u8, message, ' ');
    const verb = words.next() orelse return;
    const is_window = std.mem.eql(u8, verb, "focus-window");
    if (!is_window and !std.mem.eql(u8, verb, "focus-workspace"))
        return;
    const output_number = std.fmt.parseInt(usize, words.next() orelse return, 10) catch return;
    const workspace_number = std.fmt.parseInt(usize, words.next() orelse return, 10) catch return;

    const window_number = if (is_window)
        (std.fmt.parseInt(usize, words.next() orelse return, 10) catch return)
    else
        0;
    if (words.next() != null or output_number == 0 or workspace_number == 0) return;
    if (output_number > wm.output_list.items.len) return;
    const output = &wm.output_list.items[output_number - 1];
    if (output.river_output == null or workspace_number > output.workspace_list.items.len) return;
    const workspace = &output.workspace_list.items[workspace_number - 1];
    if (is_window and (window_number == 0 or window_number > workspace.window_list.items.len)) return;
    wm.previous_workspace = if (wm.focused_output_idx) |idx| .{
        .output_idx = idx,
        .workspace_idx = wm.output_list.items[idx].focused_workspace_idx,
    } else null;
    wm.focused_output_idx = output_number - 1;
    output.focused_workspace_idx = workspace_number - 1;
    if (is_window) workspace.focused_window_idx = window_number - 1;
    wm.task = .layout;
    if (wm.river_window_manager) |manager| manager.manageDirty();
}
