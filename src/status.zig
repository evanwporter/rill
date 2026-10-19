const std = @import("std");
const types = @import("types.zig");

const Tile = struct { number: usize, window: usize, x: i32, width: i32, focused: bool, app_id: []const u8 };
const Workspace = struct {
    number: usize,
    active: bool,
    windows: usize,
    floating: bool,
    focused_window: ?usize,
    tiles: []Tile,
};
const Output = struct { index: usize, focused: bool, viewport: types.Rectangle, workspaces: []Workspace };

fn path(wm: *types.WindowManager, suffix: []const u8) !?[]u8 {
    const runtime = wm.environ_map.get("XDG_RUNTIME_DIR") orelse return null;
    // Keep separate River sessions from overwriting each other's status.
    const display = wm.environ_map.get("WAYLAND_DISPLAY") orelse "wayland-0";
    if (std.mem.indexOfScalar(u8, display, '/') != null) return null;
    return try std.fmt.allocPrint(wm.gpa, "{s}/rill-{s}-workspaces.json{s}", .{ runtime, display, suffix });
}

pub fn publish(wm: *types.WindowManager) !void {
    const destination = try path(wm, "") orelse return;
    defer wm.gpa.free(destination);
    const temporary = try path(wm, ".tmp") orelse return;
    defer wm.gpa.free(temporary);

    var arena = std.heap.ArenaAllocator.init(wm.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    var outputs: std.ArrayList(Output) = .empty;
    for (wm.output_list.items, 0..) |output, index| {
        if (output.river_output == null) continue;
        const workspaces = try allocator.alloc(Workspace, output.workspace_list.items.len);
        for (output.workspace_list.items, 0..) |workspace, i| {
            var tiles: std.ArrayList(Tile) = .empty;
            const focused_tile_idx = if (workspace.focused_window_idx) |j|
                if (workspace.is_floating)
                    j
                else
                    workspace.columnHead(j)
            else
                null;
            for (workspace.window_list.items, 0..) |window, j| {
                // A stacked column occupies one horizontal slot. Floating
                // workspaces still report each window.
                if (!workspace.is_floating and workspace.columnHead(j) != j) continue;
                const rect = window.finish_rect orelse window.current_rect;
                try tiles.append(allocator, .{ .number = tiles.items.len + 1, .window = j + 1, .x = rect.x, .width = rect.width, .focused = focused_tile_idx == j, .app_id = @import("window.zig").appId(window.river_window) });
            }
            workspaces[i] = .{
                .floating = workspace.is_floating,
                .focused_window = if (workspace.focused_window_idx) |j| j + 1 else null,
                .tiles = tiles.items,
                .number = i + 1,
                .active = i == output.focused_workspace_idx,
                .windows = workspace.window_list.items.len,
            };
        }
        try outputs.append(allocator, .{
            .viewport = output.non_exclusive orelse output.rect,
            .index = index + 1,
            .focused = wm.focused_output_idx == index,
            .workspaces = workspaces,
        });
    }
    const json = try std.json.Stringify.valueAlloc(allocator, .{ .outputs = outputs.items }, .{});
    // Animation frames usually leave workspace state unchanged.
    const old = std.Io.Dir.cwd().readFileAlloc(wm.io, destination, allocator, .limited(1024 * 1024)) catch null;
    if (old) |bytes| if (std.mem.eql(u8, bytes, json)) return;
    try std.Io.Dir.cwd().writeFile(wm.io, .{ .sub_path = temporary, .data = json });
    errdefer std.Io.Dir.cwd().deleteFile(wm.io, temporary) catch {};
    try std.Io.Dir.renameAbsolute(temporary, destination, wm.io);
}

pub fn clear(wm: *types.WindowManager) void {
    const destination = (path(wm, "") catch return) orelse return;
    defer wm.gpa.free(destination);
    std.Io.Dir.cwd().deleteFile(wm.io, destination) catch {};
}
