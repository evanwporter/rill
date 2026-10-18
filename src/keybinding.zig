const std = @import("std");

const wayland = @import("wayland");
const xkbcommon = @import("xkbcommon");
const river = wayland.client.river;

const config = @import("config.zig");
const layout = @import("layout.zig");
const types = @import("types.zig");

const Direction = enum { left, right, above, below };

pub fn setupKeybindings(gpa: std.mem.Allocator, wm: *types.WindowManager) !void {
    const river_seat = wm.river_seat orelse return;
    const river_xkb_bindings = wm.river_xkb_bindings orelse return;

    for (wm.xkb_binding_list.items) |xkb_binding| {
        xkb_binding.river_xkb_binding.destroy();
    }
    wm.xkb_binding_list.clearRetainingCapacity();

    for (wm.config.keybindings) |keybinding| {
        const keysym = parseKey(keybinding.key) orelse {
            std.debug.print("Failed to parse key '{s}'\n", .{keybinding.key});
            continue;
        };

        const river_xkb_binding = try river_xkb_bindings.getXkbBinding(
            river_seat,
            @backingInt(keysym),
            keybinding.modifiers,
        );

        try wm.xkb_binding_list.append(
            gpa,
            .{ .river_xkb_binding = river_xkb_binding, .action = keybinding.action },
        );

        river_xkb_binding.setListener(*types.WindowManager, xkbBindingListener, wm);
        river_xkb_binding.enable();
    }
}

fn parseKey(key: [:0]const u8) ?xkbcommon.Keysym {
    const keysym = xkbcommon.Keysym.fromName(key, .case_insensitive);
    if (keysym != .NoSymbol) return keysym;
    return null;
}

fn xkbBindingListener(
    river_xkb_binding: *river.XkbBindingV1,
    event: river.XkbBindingV1.Event,
    wm: *types.WindowManager,
) void {
    if (wm.task == .pointer_action) return;

    for (wm.xkb_binding_list.items) |binding| {
        if (binding.river_xkb_binding != river_xkb_binding) continue;

        switch (event) {
            .pressed => {
                handleKeybindingAction(
                    wm.gpa,
                    wm.io,
                    binding.action,
                    wm,
                ) catch |err| {
                    std.debug.print("Failed to handle pressed keybinding: {}\n", .{err});
                };
            },
            else => {},
        }
        return;
    }
}

fn handleKeybindingAction(
    gpa: std.mem.Allocator,
    io: std.Io,
    action: types.KeybindingAction,
    wm: *types.WindowManager,
) !void {
    const output_idx = wm.focused_output_idx orelse return;
    const output = &wm.output_list.items[output_idx];

    const workspace_idx = output.focused_workspace_idx;
    const workspace = &output.workspace_list.items[workspace_idx];

    action_switch: switch (action) {
        .close_window => {
            const window_idx = workspace.focused_window_idx orelse return;
            const window = &workspace.window_list.items[window_idx];
            window.should_close = true;
        },
        .toggle_maximize => {
            const window_idx = workspace.focused_window_idx orelse return;
            var window = &workspace.window_list.items[window_idx];
            if (window.is_fullscreen) return;
            window.is_maximized = !window.is_maximized;
        },
        .toggle_fullscreen => {
            const window_idx = workspace.focused_window_idx orelse return;
            const window = &workspace.window_list.items[window_idx];
            window.is_fullscreen = !window.is_fullscreen;
        },
        .toggle_workspace_floating => workspace.is_floating = !workspace.is_floating,
        .adjust_window_width => |increment| {
            if (workspace.is_floating) return;
            const focused_idx = workspace.focused_window_idx orelse return;
            // A column's width comes from its head, so widening any member has
            // to widen the head or the change is invisible.
            const window_idx = workspace.columnHead(focused_idx);
            var window = &workspace.window_list.items[window_idx];
            if (window.is_fullscreen) return;

            var proportion = window.proportion;
            if (window.is_maximized) proportion = 1.0;

            const non_exclusive = output.non_exclusive orelse output.rect;
            const h_gap = wm.config.horizontal_gap;
            const base_width: f32 = @floatFromInt(non_exclusive.width - h_gap);
            const width_with_gap: i32 = @trunc(base_width * (proportion + increment));
            if (width_with_gap - h_gap < 2 * wm.config.border.width) return;

            window.is_maximized = false;
            window.proportion = proportion + increment;
        },
        .set_window_width => |proportion| {
            if (workspace.is_floating) return;
            const focused_idx = workspace.focused_window_idx orelse return;
            var window = &workspace.window_list.items[workspace.columnHead(focused_idx)];
            if (window.is_fullscreen) return;
            window.is_maximized = false;
            window.proportion = proportion;
        },
        .exit => {
            wm.task = .exit;
            return;
        },
        .reload_config => {
            _ = wm.arena.reset(.retain_capacity);
            wm.config = config.load(gpa, io, wm.arena, wm.environ_map);
            wm.task = .setup_seat;
            return;
        },
        .toggle_passthrough => {
            wm.is_passthrough = !wm.is_passthrough;
            wm.task = .toggle_passthrough;
            return;
        },
        .spawn => |command| {
            _ = try std.process.spawn(io, .{ .argv = command });
            return;
        },
        .focus_window_left => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            // Horizontal movement steps over a whole column; focus_window_up
            // and focus_window_down move inside one. Stepping from the column
            // head rather than from the focused window means leaving a column
            // lands on the neighbour, not on the top of the column just left.
            const head_idx = workspace.columnHead(window_idx);
            if (head_idx == 0) return;
            workspace.focused_window_idx = workspace.columnHead(head_idx - 1);
        },
        .focus_window_or_output_left => {
            const window_idx = workspace.focused_window_idx orelse return;
            // The edge of the chain is the edge of the leftmost *column*: a
            // member of it is at the edge too, even though its index is not 0.
            if (workspace.is_floating or workspace.columnHead(window_idx) == 0) {
                continue :action_switch .focus_output_left;
            }
            continue :action_switch .focus_window_left;
        },
        .focus_window_right => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const next_idx = workspace.columnEnd(window_idx);
            if (next_idx >= workspace.window_list.items.len) return;
            workspace.focused_window_idx = next_idx;
        },
        .focus_window_or_output_right => {
            const window_idx = workspace.focused_window_idx orelse return;
            if (workspace.is_floating or
                workspace.columnEnd(window_idx) >= workspace.window_list.items.len)
            {
                continue :action_switch .focus_output_right;
            }
            continue :action_switch .focus_window_right;
        },
        .focus_window_up => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const items = workspace.window_list.items;
            if (!types.hasAbove(items, window_idx)) return;
            workspace.focused_window_idx =
                types.previousTiled(items, window_idx) orelse return;
        },
        .focus_window_down => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const items = workspace.window_list.items;
            if (!types.hasBelow(items, window_idx)) return;
            workspace.focused_window_idx =
                types.nextTiled(items, window_idx) orelse return;
        },
        // Vertical movement that falls out of the column at its ends: inside a
        // stack these step between members, and at the top or bottom member
        // they carry on to the workspace above or below. A window that is not
        // stacked has neither, so this is plain workspace switching until a
        // column is built - which is what makes it safe to put on Super+J/K.
        .focus_window_or_workspace_up => {
            if (workspace.is_floating) continue :action_switch .focus_workspace_above;
            const window_idx = workspace.focused_window_idx orelse
                continue :action_switch .focus_workspace_above;
            if (!types.hasAbove(workspace.window_list.items, window_idx)) {
                continue :action_switch .focus_workspace_above;
            }
            continue :action_switch .focus_window_up;
        },
        .focus_window_or_workspace_down => {
            if (workspace.is_floating) continue :action_switch .focus_workspace_below;
            const window_idx = workspace.focused_window_idx orelse
                continue :action_switch .focus_workspace_below;
            if (!types.hasBelow(workspace.window_list.items, window_idx)) {
                continue :action_switch .focus_workspace_below;
            }
            continue :action_switch .focus_window_down;
        },
        .move_window_up => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const items = workspace.window_list.items;
            if (!types.hasAbove(items, window_idx)) return;
            const above_idx = types.previousTiled(items, window_idx) orelse return;
            swapWindows(items, window_idx, above_idx);
            workspace.focused_window_idx = above_idx;
        },
        .move_window_down => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const items = workspace.window_list.items;
            if (!types.hasBelow(items, window_idx)) return;
            const below_idx = types.nextTiled(items, window_idx) orelse return;
            swapWindows(items, window_idx, below_idx);
            workspace.focused_window_idx = below_idx;
        },
        .set_window_stacked => |stacked| {
            const window_idx = workspace.focused_window_idx orelse return;
            if (workspace.window_list.items[window_idx].stacked == stacked) return;
            continue :action_switch .toggle_window_stacked;
        },
        .toggle_window_stacked => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const window = &workspace.window_list.items[window_idx];
            if (window.stacked) {
                // Leaving a column mid-way starts a new one here; the members
                // below follow this window into it.
                window.stacked = false;
            } else {
                // Nothing to the left to stack onto.
                if (types.previousTiled(workspace.window_list.items, window_idx) == null) return;
                window.stacked = true;
            }
        },
        .move_window_left => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == 0) return;
            swapWindows(workspace.window_list.items, window_idx, window_idx - 1);
            workspace.focused_window_idx = window_idx - 1;
            workspace.normalizeColumns();
        },
        .move_window_right => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == workspace.window_list.items.len - 1) return;
            swapWindows(workspace.window_list.items, window_idx, window_idx + 1);
            workspace.focused_window_idx = window_idx + 1;
            workspace.normalizeColumns();
        },
        .move_window_left_or_to_output_left => {
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == 0) {
                continue :action_switch .move_window_to_output_left;
            }
            continue :action_switch .move_window_left;
        },
        .move_window_right_or_to_output_right => {
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == workspace.window_list.items.len - 1) {
                continue :action_switch .move_window_to_output_right;
            }
            continue :action_switch .move_window_right;
        },
        .focus_workspace_above => {
            if (workspace_idx == 0) return;
            output.focused_workspace_idx -= 1;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .focus_workspace_below => {
            if (workspace_idx == output.workspace_list.items.len - 1) return;
            output.focused_workspace_idx += 1;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .focus_workspace_or_output_above => {
            if (workspace_idx == 0) {
                continue :action_switch .focus_output_above;
            }
            continue :action_switch .focus_workspace_above;
        },
        .focus_workspace_or_output_below => {
            if (workspace_idx == output.workspace_list.items.len - 1) {
                continue :action_switch .focus_output_below;
            }
            continue :action_switch .focus_workspace_below;
        },
        .focus_workspace_number => |number| {
            if (number == 0 or number > output.workspace_list.items.len) return;
            if (workspace_idx == number - 1) return;

            output.focused_workspace_idx = number - 1;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .focus_workspace_previous => {
            const previous = wm.previous_workspace orelse return;

            const target_output = &wm.output_list.items[previous.output_idx];
            target_output.focused_workspace_idx = previous.workspace_idx;

            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .move_window_to_workspace_above => {
            if (workspace_idx == 0) return;

            try sendFocusedWindowToWorkspace(
                gpa,
                workspace,
                &output.workspace_list.items[workspace_idx - 1],
            );

            output.focused_workspace_idx = workspace_idx - 1;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .move_window_to_workspace_below => {
            if (workspace_idx == output.workspace_list.items.len - 1) return;

            try sendFocusedWindowToWorkspace(
                gpa,
                workspace,
                &output.workspace_list.items[workspace_idx + 1],
            );

            output.focused_workspace_idx = workspace_idx + 1;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .move_window_to_workspace_or_output_above => {
            if (workspace_idx == 0) {
                continue :action_switch .move_window_to_output_above;
            }
            continue :action_switch .move_window_to_workspace_above;
        },
        .move_window_to_workspace_or_output_below => {
            if (workspace_idx == output.workspace_list.items.len - 1) {
                continue :action_switch .move_window_to_output_below;
            }
            continue :action_switch .move_window_to_workspace_below;
        },
        .move_window_to_workspace_number => |number| {
            if (number == 0 or
                number > output.workspace_list.items.len or
                number - 1 == workspace_idx) return;

            try sendFocusedWindowToWorkspace(
                gpa,
                workspace,
                &output.workspace_list.items[number - 1],
            );

            output.focused_workspace_idx = number - 1;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .send_window_to_workspace_above => {
            if (workspace_idx == 0) return;

            try sendFocusedWindowToWorkspace(
                gpa,
                workspace,
                &output.workspace_list.items[workspace_idx - 1],
            );
        },
        .send_window_to_workspace_below => {
            if (workspace_idx == output.workspace_list.items.len - 1) return;

            try sendFocusedWindowToWorkspace(
                gpa,
                workspace,
                &output.workspace_list.items[workspace_idx + 1],
            );
        },
        .send_window_to_workspace_or_output_above => {
            if (workspace_idx == 0) {
                continue :action_switch .send_window_to_output_above;
            }
            continue :action_switch .send_window_to_workspace_above;
        },
        .send_window_to_workspace_or_output_below => {
            if (workspace_idx == output.workspace_list.items.len - 1) {
                continue :action_switch .send_window_to_output_below;
            }
            continue :action_switch .send_window_to_workspace_below;
        },
        .send_window_to_workspace_number => |number| {
            if (number == 0 or
                number > output.workspace_list.items.len or
                number - 1 == workspace_idx) return;

            try sendFocusedWindowToWorkspace(
                gpa,
                workspace,
                &output.workspace_list.items[number - 1],
            );
        },
        .focus_output_left => {
            const target_output_idx = getOutputInDirection(
                wm.output_list,
                output.rect,
                .left,
            ) orelse return;

            wm.focused_output_idx = target_output_idx;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .focus_output_right => {
            const target_output_idx = getOutputInDirection(
                wm.output_list,
                output.rect,
                .right,
            ) orelse return;

            wm.focused_output_idx = target_output_idx;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .focus_output_above => {
            const target_output_idx = getOutputInDirection(
                wm.output_list,
                output.rect,
                .above,
            ) orelse return;

            wm.focused_output_idx = target_output_idx;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .focus_output_below => {
            const target_output_idx = getOutputInDirection(
                wm.output_list,
                output.rect,
                .below,
            ) orelse return;

            wm.focused_output_idx = target_output_idx;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .move_window_to_output_left => {
            const target_output_idx = getOutputInDirection(
                wm.output_list,
                output.rect,
                .left,
            ) orelse return;

            const target_output = wm.output_list.items[target_output_idx];
            const target_workspace_idx = target_output.focused_workspace_idx;

            try sendFocusedWindowToWorkspace(
                gpa,
                workspace,
                &target_output.workspace_list.items[target_workspace_idx],
            );

            wm.focused_output_idx = target_output_idx;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .move_window_to_output_right => {
            const target_output_idx = getOutputInDirection(
                wm.output_list,
                output.rect,
                .right,
            ) orelse return;

            const target_output = wm.output_list.items[target_output_idx];
            const target_workspace_idx = target_output.focused_workspace_idx;

            try sendFocusedWindowToWorkspace(
                gpa,
                workspace,
                &target_output.workspace_list.items[target_workspace_idx],
            );

            wm.focused_output_idx = target_output_idx;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .move_window_to_output_above => {
            const target_output_idx = getOutputInDirection(
                wm.output_list,
                output.rect,
                .above,
            ) orelse return;

            const target_output = wm.output_list.items[target_output_idx];
            const target_workspace_idx = target_output.focused_workspace_idx;

            try sendFocusedWindowToWorkspace(
                gpa,
                workspace,
                &target_output.workspace_list.items[target_workspace_idx],
            );

            wm.focused_output_idx = target_output_idx;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .move_window_to_output_below => {
            const target_output_idx = getOutputInDirection(
                wm.output_list,
                output.rect,
                .below,
            ) orelse return;

            const target_output = wm.output_list.items[target_output_idx];
            const target_workspace_idx = target_output.focused_workspace_idx;

            try sendFocusedWindowToWorkspace(
                gpa,
                workspace,
                &target_output.workspace_list.items[target_workspace_idx],
            );

            wm.focused_output_idx = target_output_idx;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .send_window_to_output_left => {
            const target_output_idx = getOutputInDirection(
                wm.output_list,
                output.rect,
                .left,
            ) orelse return;

            const target_output = wm.output_list.items[target_output_idx];
            const target_workspace_idx = target_output.focused_workspace_idx;

            try sendFocusedWindowToWorkspace(
                gpa,
                workspace,
                &target_output.workspace_list.items[target_workspace_idx],
            );
        },
        .send_window_to_output_right => {
            const target_output_idx = getOutputInDirection(
                wm.output_list,
                output.rect,
                .right,
            ) orelse return;

            const target_output = wm.output_list.items[target_output_idx];
            const target_workspace_idx = target_output.focused_workspace_idx;

            try sendFocusedWindowToWorkspace(
                gpa,
                workspace,
                &target_output.workspace_list.items[target_workspace_idx],
            );
        },
        .send_window_to_output_above => {
            const target_output_idx = getOutputInDirection(
                wm.output_list,
                output.rect,
                .above,
            ) orelse return;

            const target_output = wm.output_list.items[target_output_idx];
            const target_workspace_idx = target_output.focused_workspace_idx;

            try sendFocusedWindowToWorkspace(
                gpa,
                workspace,
                &target_output.workspace_list.items[target_workspace_idx],
            );
        },
        .send_window_to_output_below => {
            const target_output_idx = getOutputInDirection(
                wm.output_list,
                output.rect,
                .below,
            ) orelse return;

            const target_output = wm.output_list.items[target_output_idx];
            const target_workspace_idx = target_output.focused_workspace_idx;

            try sendFocusedWindowToWorkspace(
                gpa,
                workspace,
                &target_output.workspace_list.items[target_workspace_idx],
            );
        },
    }

    wm.task = .layout;
}

fn swapWindows(items: []types.Window, a_idx: usize, b_idx: usize) void {
    const a_stacked = items[a_idx].stacked;
    const b_stacked = items[b_idx].stacked;
    std.mem.swap(types.Window, &items[a_idx], &items[b_idx]);
    items[a_idx].stacked = a_stacked;
    items[b_idx].stacked = b_stacked;
}

fn sendFocusedWindowToWorkspace(
    gpa: std.mem.Allocator,
    current: *types.Workspace,
    target: *types.Workspace,
) !void {
    const window_idx = current.focused_window_idx orelse return error.NoFocusedWindow;
    current.detachFromColumn(window_idx);
    var window = current.window_list.orderedRemove(window_idx);
    window.stacked = false;

    if (current.window_list.items.len == 0) {
        current.focused_window_idx = null;
    } else if (window_idx != 0) {
        current.focused_window_idx = window_idx - 1;
    }

    var target_window_idx: usize = 0;
    if (target.focused_window_idx) |idx| {
        target_window_idx = target.columnEnd(idx);
    }

    try target.window_list.insert(gpa, target_window_idx, window);
    target.focused_window_idx = target_window_idx;
}

fn getOutputInDirection(
    output_list: std.ArrayList(types.Output),
    current_rect: types.Rectangle,
    direction: Direction,
) ?usize {
    for (output_list.items, 0..) |output, output_idx| {
        const target_rect = output.rect;

        const is_adjacent = switch (direction) {
            .left => target_rect.x + target_rect.width == current_rect.x,
            .right => current_rect.x + current_rect.width == target_rect.x,
            .above => target_rect.y + target_rect.height == current_rect.y,
            .below => current_rect.y + current_rect.height == target_rect.y,
        };

        if (is_adjacent) return output_idx;
    }

    return null;
}
