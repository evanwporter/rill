const std = @import("std");

const wayland = @import("wayland");
const river = wayland.client.river;

pub const WindowManager = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    environ_map: *std.process.Environ.Map,

    river_window_manager: ?*river.WindowManagerV1,
    river_xkb_bindings: ?*river.XkbBindingsV1,
    river_layer_shell: ?*river.LayerShellV1,

    river_seat: ?*river.SeatV1,
    river_layer_shell_seat: ?*river.LayerShellSeatV1,

    output_list: std.ArrayList(Output),
    pending_windows_list: std.ArrayList(*river.WindowV1),

    xkb_binding_list: std.ArrayList(struct {
        river_xkb_binding: *river.XkbBindingV1,
        action: KeybindingAction,
    }),
    pointer_binding_list: std.ArrayList(struct {
        river_pointer_binding: *river.PointerBindingV1,
        action: PointerAction,
    }),

    config: Config,
    task: Task,
    focused_output_idx: ?usize,
    previous_workspace: ?struct { output_idx: usize, workspace_idx: usize },
    is_passthrough: bool,

    pub fn deinit(self: *WindowManager) void {
        for (self.output_list.items) |*output| {
            for (output.workspace_list.items) |*workspace| {
                workspace.window_list.deinit(self.gpa);
            }
            output.workspace_list.deinit(self.gpa);
        }

        self.output_list.deinit(self.gpa);
        self.pending_windows_list.deinit(self.gpa);
        self.xkb_binding_list.deinit(self.gpa);
        self.pointer_binding_list.deinit(self.gpa);
    }
};

pub const Output = struct {
    river_output: ?*river.OutputV1,
    river_layer_shell_output: ?*river.LayerShellOutputV1,
    workspace_list: std.ArrayList(Workspace),
    focused_workspace_idx: usize,
    rect: Rectangle,
    non_exclusive: ?Rectangle,
};

pub const Workspace = struct {
    column_list: std.ArrayList(Column) = .empty,
    window_list: std.ArrayList(Window) = .empty,
    focused_column_idx: ?usize = null,
    focused_window_idx: ?usize = null,
    is_floating: bool = false,
};

/// A column is a vertical tiling of one or more windows
pub const Column = struct {
    window_list: std.ArrayList(Window) = .empty,
};

pub const Window = struct {
    river_window: *river.WindowV1,
    river_node: *river.NodeV1,
    proportion: f32,
    should_close: bool,
    is_maximized: bool,
    is_fullscreen: bool,
    floating_rect: Rectangle,
    current_rect: Rectangle,
    start_rect: ?Rectangle,
    finish_rect: ?Rectangle,
};

pub const Rectangle = struct {
    width: i32,
    height: i32,
    x: i32,
    y: i32,
};

pub const Task = union(enum) {
    layout: void,
    animation: i64,
    pointer_action: PointerAction,
    setup_seat: void,
    prepare_window: void,
    toggle_passthrough: void,
    exit: void,
    none: void,
};

pub const Config = struct {
    vertical_gap: i32 = 9,
    horizontal_gap: i32 = 9,
    default_window_width: f32 = 0.5,
    center_focused_window: enum { never, always, single } = .never,
    dynamic_workspaces: bool = false,
    workspace_count: u32 = 10,

    border: Border = .{
        .width = 3,
        .focused_color = .{ .r = 141, .g = 214, .b = 0, .a = 1.0 },
        .unfocused_color = .{ .r = 160, .g = 160, .b = 160, .a = 1.0 },
    },

    no_csd: bool = true,
    animation_duration: u32 = 200,
    cursor: ?struct { theme: [:0]const u8, size: u32 } = null,

    spawn_at_startup: []const []const []const u8 = &.{},
    keybindings: []const Keybinding = &default_keybindings,
    pointer_bindings: []const PointerBinding = &.{
        .{ .button = .left, .modifiers = .{ .mod4 = true }, .action = .move_window },
        .{ .button = .right, .modifiers = .{ .mod4 = true }, .action = .resize_window },
    },
};

const Border = struct { width: u8, focused_color: Color, unfocused_color: Color };

const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: f32,

    pub fn toRiverColor(self: Color) struct { r: u32, g: u32, b: u32, a: u32 } {
        var r: f32 = @floatFromInt(self.r);
        var g: f32 = @floatFromInt(self.g);
        var b: f32 = @floatFromInt(self.b);

        r = self.a * r / 255;
        g = self.a * g / 255;
        b = self.a * b / 255;

        const max: f64 = @floatFromInt(std.math.maxInt(u32));
        return .{
            .r = @trunc(r * max),
            .g = @trunc(g * max),
            .b = @trunc(b * max),
            .a = @trunc(self.a * max),
        };
    }
};

pub const Keybinding = struct {
    key: [:0]const u8,
    modifiers: river.SeatV1.Modifiers,
    action: KeybindingAction,
};

pub const KeybindingAction = union(enum) {
    close_window: void,
    toggle_maximize: void,
    toggle_fullscreen: void,
    toggle_workspace_floating: void,
    adjust_window_width: f32,
    set_window_width: f32,

    exit: void,
    reload_config: void,
    toggle_passthrough: void,
    spawn: []const []const u8,

    focus_window_left: void,
    focus_window_right: void,
    focus_window_or_output_left: void,
    focus_window_or_output_right: void,

    move_window_left: void,
    move_window_right: void,
    move_window_left_or_to_output_left: void,
    move_window_right_or_to_output_right: void,

    focus_workspace_above: void,
    focus_workspace_below: void,
    focus_workspace_or_output_above: void,
    focus_workspace_or_output_below: void,
    focus_workspace_number: usize,
    focus_workspace_previous: void,

    move_window_to_workspace_above: void,
    move_window_to_workspace_below: void,
    move_window_to_workspace_or_output_above: void,
    move_window_to_workspace_or_output_below: void,
    move_window_to_workspace_number: usize,

    send_window_to_workspace_above: void,
    send_window_to_workspace_below: void,
    send_window_to_workspace_or_output_above: void,
    send_window_to_workspace_or_output_below: void,
    send_window_to_workspace_number: usize,

    focus_output_left: void,
    focus_output_right: void,
    focus_output_above: void,
    focus_output_below: void,

    move_window_to_output_left: void,
    move_window_to_output_right: void,
    move_window_to_output_above: void,
    move_window_to_output_below: void,

    send_window_to_output_left: void,
    send_window_to_output_right: void,
    send_window_to_output_above: void,
    send_window_to_output_below: void,
};

pub const PointerBinding = struct {
    button: Button,
    modifiers: river.SeatV1.Modifiers,
    action: PointerAction,
};

const Button = enum(u32) {
    left = 0x110,
    right = 0x111,
    middle = 0x112,
};

const PointerAction = enum { move_window, resize_window };

const default_keybindings = [_]Keybinding{
    .{ .key = "q", .modifiers = .{ .mod4 = true }, .action = .close_window },
    .{ .key = "f", .modifiers = .{ .mod4 = true }, .action = .toggle_maximize },
    .{ .key = "f", .modifiers = .{ .mod4 = true, .shift = true }, .action = .toggle_fullscreen },

    .{ .key = "minus", .modifiers = .{ .mod4 = true }, .action = .{ .adjust_window_width = -0.1 } },
    .{ .key = "equal", .modifiers = .{ .mod4 = true }, .action = .{ .adjust_window_width = 0.1 } },

    .{ .key = "Escape", .modifiers = .{ .mod4 = true }, .action = .exit },
    .{ .key = "r", .modifiers = .{ .mod4 = true }, .action = .reload_config },
    .{ .key = "t", .modifiers = .{ .mod4 = true }, .action = .{ .spawn = &[_][]const u8{"alacritty"} } },

    .{ .key = "Left", .modifiers = .{ .mod4 = true }, .action = .focus_window_left },
    .{ .key = "Right", .modifiers = .{ .mod4 = true }, .action = .focus_window_right },

    .{ .key = "Left", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_left },
    .{ .key = "Right", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_right },

    .{ .key = "Up", .modifiers = .{ .mod4 = true }, .action = .focus_workspace_above },
    .{ .key = "Down", .modifiers = .{ .mod4 = true }, .action = .focus_workspace_below },

    .{ .key = "1", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 1 } },
    .{ .key = "2", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 2 } },
    .{ .key = "3", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 3 } },
    .{ .key = "4", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 4 } },
    .{ .key = "5", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 5 } },
    .{ .key = "6", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 6 } },
    .{ .key = "7", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 7 } },
    .{ .key = "8", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 8 } },
    .{ .key = "9", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 9 } },
    .{ .key = "0", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 10 } },

    .{ .key = "Up", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_workspace_above },
    .{ .key = "Down", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_workspace_below },

    .{ .key = "1", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 1 } },
    .{ .key = "2", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 2 } },
    .{ .key = "3", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 3 } },
    .{ .key = "4", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 4 } },
    .{ .key = "5", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 5 } },
    .{ .key = "6", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 6 } },
    .{ .key = "7", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 7 } },
    .{ .key = "8", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 8 } },
    .{ .key = "9", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 9 } },
    .{ .key = "0", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 10 } },

    .{ .key = "Up", .modifiers = .{ .mod4 = true, .ctrl = true }, .action = .send_window_to_workspace_above },
    .{ .key = "Down", .modifiers = .{ .mod4 = true, .ctrl = true }, .action = .send_window_to_workspace_below },

    .{ .key = "1", .modifiers = .{ .mod4 = true, .ctrl = true }, .action = .{ .send_window_to_workspace_number = 1 } },
    .{ .key = "2", .modifiers = .{ .mod4 = true, .ctrl = true }, .action = .{ .send_window_to_workspace_number = 2 } },
    .{ .key = "3", .modifiers = .{ .mod4 = true, .ctrl = true }, .action = .{ .send_window_to_workspace_number = 3 } },
    .{ .key = "4", .modifiers = .{ .mod4 = true, .ctrl = true }, .action = .{ .send_window_to_workspace_number = 4 } },
    .{ .key = "5", .modifiers = .{ .mod4 = true, .ctrl = true }, .action = .{ .send_window_to_workspace_number = 5 } },
    .{ .key = "6", .modifiers = .{ .mod4 = true, .ctrl = true }, .action = .{ .send_window_to_workspace_number = 6 } },
    .{ .key = "7", .modifiers = .{ .mod4 = true, .ctrl = true }, .action = .{ .send_window_to_workspace_number = 7 } },
    .{ .key = "8", .modifiers = .{ .mod4 = true, .ctrl = true }, .action = .{ .send_window_to_workspace_number = 8 } },
    .{ .key = "9", .modifiers = .{ .mod4 = true, .ctrl = true }, .action = .{ .send_window_to_workspace_number = 9 } },
    .{ .key = "0", .modifiers = .{ .mod4 = true, .ctrl = true }, .action = .{ .send_window_to_workspace_number = 10 } },

    .{ .key = "h", .modifiers = .{ .mod4 = true }, .action = .focus_output_left },
    .{ .key = "l", .modifiers = .{ .mod4 = true }, .action = .focus_output_right },
    .{ .key = "k", .modifiers = .{ .mod4 = true }, .action = .focus_output_above },
    .{ .key = "j", .modifiers = .{ .mod4 = true }, .action = .focus_output_below },

    .{ .key = "h", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_output_left },
    .{ .key = "l", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_output_right },
    .{ .key = "k", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_output_above },
    .{ .key = "j", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_output_below },

    .{ .key = "h", .modifiers = .{ .mod4 = true, .ctrl = true }, .action = .send_window_to_output_left },
    .{ .key = "l", .modifiers = .{ .mod4 = true, .ctrl = true }, .action = .send_window_to_output_right },
    .{ .key = "k", .modifiers = .{ .mod4 = true, .ctrl = true }, .action = .send_window_to_output_above },
    .{ .key = "j", .modifiers = .{ .mod4 = true, .ctrl = true }, .action = .send_window_to_output_below },
};
