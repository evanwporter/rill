const std = @import("std");

const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");

pub var pending_windows = std.ArrayList(*river.WindowV1).empty;

// App IDs can arrive before the first dimensions event creates the window.
var app_ids: std.AutoHashMapUnmanaged(*river.WindowV1, []const u8) = .empty;

pub fn appId(window: *river.WindowV1) []const u8 {
    return app_ids.get(window) orelse "";
}

pub fn windowListener(
    river_window: *river.WindowV1,
    event: river.WindowV1.Event,
    wm: *types.WindowManager,
) void {
    if (event == .app_id) {
        const id = if (event.app_id.app_id) |value| std.mem.span(value) else "";
        const copy = wm.gpa.dupe(u8, id) catch return;
        const entry = app_ids.getOrPut(wm.gpa, river_window) catch {
            wm.gpa.free(copy);
            return;
        };
        if (entry.found_existing) wm.gpa.free(entry.value_ptr.*);
        entry.value_ptr.* = copy;
        return;
    }
    if (event == .closed) {
        if (app_ids.fetchRemove(river_window)) |entry| wm.gpa.free(entry.value);
    }
    if (event == .dimensions) {
        const river_window_manager = wm.river_window_manager orelse return;
        const output_idx = wm.focused_output_idx orelse return;
        const output = wm.output_list.items[output_idx];

        for (pending_windows.items, 0..) |window, idx| {
            if (window != river_window) continue;

            addWindow(wm.gpa, window, output, wm.config) catch |err| {
                std.debug.print("Failed to add window: {}\n", .{err});
                return;
            };
            _ = pending_windows.swapRemove(idx);

            wm.task = .layout;
            river_window_manager.manageDirty();

            return;
        }
    }

    for (wm.output_list.items) |output| {
        for (output.workspace_list.items) |*workspace| {
            const focused_idx = workspace.focused_window_idx orelse continue;

            for (workspace.window_list.items, 0..) |*window, idx| {
                if (window.river_window != river_window) continue;

                switch (event) {
                    .closed => {
                        workspace.detachFromColumn(idx);
                        _ = workspace.window_list.orderedRemove(idx);
                        river_window.destroy();

                        if (workspace.window_list.items.len == 0) {
                            workspace.focused_window_idx = null;
                        } else if (idx <= focused_idx and focused_idx != 0) {
                            workspace.focused_window_idx = focused_idx - 1;
                        }
                    },
                    .fullscreen_requested => {
                        if (wm.task != .none) return;
                        window.is_fullscreen = true;
                    },
                    .exit_fullscreen_requested => {
                        if (wm.task != .none) return;
                        window.is_fullscreen = false;
                    },
                    else => return,
                }

                wm.task = .layout;
                return;
            }
        }
    }
}

fn addWindow(
    gpa: std.mem.Allocator,
    river_window: *river.WindowV1,
    output: types.Output,
    config: types.Config,
) !void {
    const non_exclusive = output.non_exclusive orelse output.rect;
    const h_gap = config.horizontal_gap;
    const v_gap = config.vertical_gap;

    const base_width: f32 = @floatFromInt(non_exclusive.width - h_gap);
    const width_with_gap: i32 = @trunc(base_width * config.default_window_width);

    const initial_rect = types.Rectangle{
        .width = width_with_gap - h_gap,
        .height = non_exclusive.height - 2 * v_gap,
        .x = non_exclusive.x + non_exclusive.width - width_with_gap,
        .y = non_exclusive.y + v_gap,
    };

    const window = types.Window{
        .river_window = river_window,
        .river_node = try river_window.getNode(),
        .proportion = config.default_window_width,
        .should_close = false,
        .is_maximized = false,
        .is_fullscreen = false,
        .stacked = false,
        .floating_rect = initial_rect,
        .current_rect = initial_rect,
        .start_rect = null,
        .finish_rect = null,
    };

    const workspace = &output.workspace_list.items[output.focused_workspace_idx];
    var window_idx: usize = 0;
    if (workspace.focused_window_idx) |idx| {
        window_idx = workspace.columnEnd(idx);
    }

    try workspace.window_list.insert(gpa, window_idx, window);
    workspace.focused_window_idx = window_idx;
}
