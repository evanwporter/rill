const std = @import("std");

const types = @import("types.zig");

/// Advances window animations by interpolating between their starting and
/// finishing rectangles using a cubic ease-out function.
pub fn apply(
    output_list: std.ArrayList(types.Output),
    focused_output_idx: usize,
    config: types.Config,
    start_time: i64,
    now: i64,
) types.Task {
    const duration = config.animation_duration;
    const is_last_frame = now - start_time >= duration;

    const elapsed: f32 = @floatFromInt(now - start_time);
    const progress = elapsed / @as(f32, @floatFromInt(duration));
    const eased = 1 - std.math.pow(f32, 1 - progress, 3);

    for (output_list.items, 0..) |*output, output_idx| {
        const river_output = output.river_output orelse continue;

        for (output.workspace_list.items, 0..) |*workspace, workspace_idx| {
            for (workspace.window_list.items, 0..) |*window, window_idx| {
                const start = window.start_rect orelse continue;
                const finish = window.finish_rect orelse continue;

                if (!is_last_frame) {
                    const width_distance: f32 = @floatFromInt(finish.width - start.width);
                    const height_distance: f32 = @floatFromInt(finish.height - start.height);
                    const x_distance: f32 = @floatFromInt(finish.x - start.x);
                    const y_distance: f32 = @floatFromInt(finish.y - start.y);

                    const width_progress: i32 = @trunc(width_distance * eased);
                    const height_progress: i32 = @trunc(height_distance * eased);
                    const x_progress: i32 = @trunc(x_distance * eased);
                    const y_progress: i32 = @trunc(y_distance * eased);

                    window.current_rect = .{
                        .width = start.width + width_progress,
                        .height = start.height + height_progress,
                        .x = start.x + x_progress,
                        .y = start.y + y_progress,
                    };
                    placeWindow(window, output.rect, config);
                } else {
                    window.current_rect = finish;
                    placeWindow(window, output.rect, config);

                    if (window.is_fullscreen) {
                        const is_focused = output_idx == focused_output_idx and
                            workspace_idx == output.focused_workspace_idx and
                            window_idx == workspace.focused_window_idx;

                        if (is_focused) window.river_window.fullscreen(river_output);
                        window.river_window.informFullscreen();
                    } else {
                        window.river_window.informNotFullscreen();
                    }

                    window.start_rect = null;
                    window.finish_rect = null;
                }
            }
        }
    }

    if (is_last_frame) {
        return .none;
    } else {
        return .{ .animation = start_time };
    }
}

/// Applies a window's current geometry to its River window and scene node.
fn placeWindow(
    window: *types.Window,
    output_rect: types.Rectangle,
    config: types.Config,
) void {
    var border_width = config.border.width;
    if (window.is_fullscreen) border_width = 0;

    window.river_window.proposeDimensions(
        @max(0, window.current_rect.width - 2 * border_width),
        @max(0, window.current_rect.height - 2 * border_width),
    );
    window.river_node.setPosition(
        window.current_rect.x + border_width,
        window.current_rect.y + border_width,
    );

    const window_left = window.current_rect.x;
    const window_right = window.current_rect.x + window.current_rect.width;
    const window_top = window.current_rect.y;
    const window_bottom = window.current_rect.y + window.current_rect.height;

    const output_left = output_rect.x;
    const output_right = output_rect.x + output_rect.width;
    const output_top = output_rect.y;
    const output_bottom = output_rect.y + output_rect.height;

    if (output_left >= window_right or output_right <= window_left or
        output_top >= window_bottom or output_bottom <= window_top)
    {
        window.river_window.hide();
    } else {
        window.river_window.show();
    }

    var clip_width = window.current_rect.width;
    var clip_height = window.current_rect.height;
    var clip_x: i32 = 0;
    var clip_y: i32 = 0;

    if (output_left < window_right and output_left > window_left) {
        clip_x = output_left - window_left;
        clip_width = @min(window_right - output_left, output_rect.width);
    } else if (output_right > window_left and output_right < window_right) {
        clip_width = output_right - window_left;
    }

    if (output_top < window_bottom and output_top > window_top) {
        clip_y = output_top - window_top;
        clip_height = window_bottom - output_top;
    } else if (output_bottom > window_top and output_bottom < window_bottom) {
        clip_height = output_bottom - window_top;
    }

    window.river_window.setClipBox(
        clip_x - border_width,
        clip_y - border_width,
        clip_width,
        clip_height,
    );
}
