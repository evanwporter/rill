const std = @import("std");

const wayland = @import("wayland");
const river = wayland.client.river;

const layout = @import("layout.zig");
const types = @import("types.zig");

/// Listens for changes in windows.
pub fn windowListener(
    river_window: *river.WindowV1,
    event: river.WindowV1.Event,
    wm: *types.WindowManager,
) void {
    if (event == .dimensions) {
        const river_window_manager = wm.river_window_manager orelse return;
        const output_idx = wm.focused_output_idx orelse return;
        const output = wm.output_list.items[output_idx];

        for (wm.pending_windows_list.items, 0..) |window, idx| {
            if (window != river_window) continue;

            addWindow(wm.gpa, window, output, wm.config) catch |err| {
                std.debug.print("Failed to add window: {}\n", .{err});
                return;
            };
            _ = wm.pending_windows_list.swapRemove(idx);

            wm.task = .layout;
            river_window_manager.manageDirty();

            return;
        }
    }

    for (wm.output_list.items) |output| {
        for (output.workspace_list.items) |*workspace| { // for each workspace
            for (workspace.column_list.items, 0..) |*column, col_idx| { // for each column in the workspace
                const focused_idx = workspace.focused_window_idx orelse continue;

                // for each window in the column
                for (column.window_list.items, 0..) |*window, win_idx| {
                    if (window.river_window != river_window) continue;

                    switch (event) {
                        .closed => {
                            _ = column.window_list.orderedRemove(win_idx);
                            river_window.destroy();

                            // If column is now empty, remove it
                            if (column.window_list.items.len == 0) {
                                _ = workspace.column_list.orderedRemove(col_idx);

                                // Update focused column index
                                if (workspace.column_list.items.len == 0) {
                                    workspace.focused_column_idx = null;
                                } else if (workspace.focused_column_idx) |focused_col| {
                                    if (col_idx <= focused_col and focused_col != 0) {
                                        workspace.focused_column_idx = focused_col - 1;
                                    }
                                }
                            }

                            // Update focused window index
                            if (win_idx <= focused_idx and focused_idx != 0) {
                                workspace.focused_window_idx = focused_idx - 1;
                            }
                        },
                        .fullscreen_requested => window.is_fullscreen = true,
                        .exit_fullscreen_requested => window.is_fullscreen = false,
                        else => return,
                    }

                    wm.task = .layout;
                    return;
                }
            }
        }
    }
}

/// Adds a new column with a single window at the focused column position
fn addColumn(
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
        .floating_rect = initial_rect,
        .current_rect = initial_rect,
        .start_rect = null,
        .finish_rect = null,
    };

    var column = types.Column{
        .window_list = std.ArrayList(types.Window).init(gpa),
    };
    try column.window_list.append(window);

    const workspace = &output.workspace_list.items[output.focused_workspace_idx];
    var column_idx: usize = 0;
    if (workspace.focused_column_idx) |idx| {
        column_idx = idx + 1;
    }

    try workspace.column_list.insert(column_idx, column);
    workspace.focused_column_idx = column_idx;
}

