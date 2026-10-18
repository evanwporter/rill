const std = @import("std");

const wayland = @import("wayland");
const river = wayland.client.river;

const animation = @import("animation.zig");
const config = @import("config.zig");
const keybinding = @import("keybinding.zig");
const layout = @import("layout.zig");
const output = @import("output.zig");
const seat = @import("seat.zig");
const types = @import("types.zig");
const window = @import("window.zig");
const control = @import("control.zig");
const workspace_status = @import("status.zig");

pub fn main(init: std.process.Init) !void {
    if (try control.client(init)) return;
    _ = std.os.linux.prctl(
        @backingInt(std.os.linux.PR.SET_PDEATHSIG),
        @backingInt(std.posix.SIG.TERM),
        0,
        0,
        0,
    );

    const sa = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.NOCLDWAIT,
    };
    std.posix.sigaction(std.posix.SIG.CHLD, &sa, null);

    const display = try wayland.client.wl.Display.connect(null);
    defer display.disconnect();

    const registry = try display.getRegistry();
    defer registry.destroy();

    var wm = types.WindowManager{
        .gpa = init.gpa,
        .io = init.io,
        .arena = init.arena,
        .environ_map = init.environ_map,
        .river_window_manager = null,
        .river_xkb_bindings = null,
        .river_layer_shell = null,
        .river_seat = null,
        .river_layer_shell_seat = null,
        .output_list = .empty,
        .xkb_binding_list = .empty,
        .pointer_binding_list = .empty,
        .config = config.load(init.gpa, init.io, init.arena, init.environ_map),
        .task = .none,
        .focused_output_idx = null,
        .previous_workspace = null,
        .is_passthrough = false,
    };
    defer wm.deinit();
    defer workspace_status.clear(&wm);

    registry.setListener(*types.WindowManager, registryListener, &wm);
    _ = display.roundtrip();

    const window_manager = wm.river_window_manager orelse return;
    window_manager.setListener(*types.WindowManager, windowManagerListener, &wm);

    for (wm.config.spawn_at_startup) |command| {
        _ = std.process.spawn(wm.io, .{ .argv = command }) catch |err| {
            std.debug.print("Failed to spawn {s}: {}\n", .{ command[0], err });
        };
    }

    var commands = try control.Server.init(&wm);
    defer commands.deinit();
    while (true) {
        while (!display.prepareRead()) {
            if (display.dispatchPending() != .SUCCESS) return error.WaylandDispatch;
        }
        _ = display.flush();
        const ready = commands.wait(display.getFd());
        if (ready.wayland) {
            if (display.readEvents() != .SUCCESS) return error.WaylandRead;
        } else display.cancelRead();
        if (ready.command) commands.receive(&wm);
        const status = display.dispatchPending();
        if (status != .SUCCESS) {
            std.debug.print("Window manager stopped with status: {}\n", .{status});
            break;
        }
        if (wm.task == .animation) window_manager.manageDirty();
    }
}

fn registryListener(
    registry: *wayland.client.wl.Registry,
    event: wayland.client.wl.Registry.Event,
    wm: *types.WindowManager,
) void {
    switch (event) {
        .global => |global| {
            const interface_name = std.mem.span(global.interface);

            if (std.mem.eql(u8, interface_name, "river_window_manager_v1")) {
                wm.river_window_manager =
                    registry.bind(global.name, river.WindowManagerV1, 4) catch |err| {
                        std.debug.print("Failed to find river window manager: {}\n", .{err});
                        return;
                    };
            } else if (std.mem.eql(u8, interface_name, "river_xkb_bindings_v1")) {
                wm.river_xkb_bindings =
                    registry.bind(global.name, river.XkbBindingsV1, 1) catch |err| {
                        std.debug.print("Failed to find river xkb bindings: {}\n", .{err});
                        return;
                    };
            } else if (std.mem.eql(u8, interface_name, "river_layer_shell_v1")) {
                wm.river_layer_shell =
                    registry.bind(global.name, river.LayerShellV1, 1) catch |err| {
                        std.debug.print("Failed to find river layer shell {}\n", .{err});
                        return;
                    };
            }
        },
        .global_remove => {},
    }
}

fn windowManagerListener(
    river_window_manager: *river.WindowManagerV1,
    event: river.WindowManagerV1.Event,
    wm: *types.WindowManager,
) void {
    handleWindowManagerEvent(river_window_manager, event, wm) catch |err| {
        std.debug.print("Failed to handle window manager event: {}\n", .{err});
    };
}

fn handleWindowManagerEvent(
    river_window_manager: *river.WindowManagerV1,
    event: river.WindowManagerV1.Event,
    wm: *types.WindowManager,
) !void {
    switch (event) {
        .output => |output_event| {
            try output.add(wm.gpa, output_event.id, wm);
        },
        .seat => |seat_event| {
            seat_event.id.setListener(*types.WindowManager, seat.seatListener, wm);

            wm.river_seat = seat_event.id;
            wm.task = .setup_seat;

            const river_layer_shell = wm.river_layer_shell orelse return;
            const river_layer_shell_seat = try river_layer_shell.getSeat(seat_event.id);

            river_layer_shell_seat.setListener(
                *types.WindowManager,
                seat.layerShellSeatListener,
                wm,
            );
            wm.river_layer_shell_seat = river_layer_shell_seat;
        },
        .window => |window_event| {
            try window.pending_windows.append(wm.gpa, window_event.id);
            window_event.id.setListener(*types.WindowManager, window.windowListener, wm);
            wm.task = .prepare_window;
        },
        .manage_start => {
            const exiting = wm.task == .exit;
            try manage(wm.gpa, wm.io, wm);
            if (exiting) {
                workspace_status.clear(wm);
            } else {
                workspace_status.publish(wm) catch |err| {
                    std.debug.print("Failed to publish workspace status: {}\n", .{err});
                };
            }
            river_window_manager.manageFinish();
        },
        .render_start => river_window_manager.renderFinish(),
        .finished => river_window_manager.destroy(),
        else => {},
    }
}

fn manage(gpa: std.mem.Allocator, io: std.Io, wm: *types.WindowManager) !void {
    const focused_output_idx = wm.focused_output_idx orelse return;
    const river_window_manager = wm.river_window_manager orelse return;
    const river_seat = wm.river_seat orelse return;

    switch (wm.task) {
        .layout => {
            try layout.apply(
                gpa,
                wm.output_list,
                focused_output_idx,
                wm.config,
                river_seat,
            );
            wm.task = .{
                .animation = std.Io.Clock.awake.now(io).toMilliseconds(),
            };
        },
        .animation => |start_time| {
            wm.task = animation.apply(
                wm.output_list,
                focused_output_idx,
                wm.config,
                start_time,
                std.Io.Clock.awake.now(io).toMilliseconds(),
            );
        },
        .pointer_action => {
            river_seat.opStartPointer();
            seat.pointerAction(
                wm.output_list,
                focused_output_idx,
                wm.config.border.width,
            );
        },
        .setup_seat => {
            try keybinding.setupKeybindings(gpa, wm);
            try seat.setupPointerBindings(gpa, wm);

            if (wm.config.cursor) |cursor| {
                river_seat.setXcursorTheme(cursor.theme, cursor.size);
            }

            wm.task = .layout;
            river_window_manager.manageDirty();
        },
        .prepare_window => {
            for (window.pending_windows.items) |pending_window| {
                if (wm.config.no_csd) pending_window.useSsd();
                pending_window.setTiled(layout.edges);
                pending_window.hide();
                pending_window.proposeDimensions(0, 0);
            }
        },
        .toggle_passthrough => {
            if (wm.is_passthrough) {
                for (wm.xkb_binding_list.items) |xkb_binding| {
                    if (xkb_binding.action == .toggle_passthrough) continue;
                    xkb_binding.river_xkb_binding.disable();
                }
                for (wm.pointer_binding_list.items) |pointer_binding| {
                    pointer_binding.river_pointer_binding.disable();
                }
            } else {
                for (wm.xkb_binding_list.items) |xkb_binding| {
                    xkb_binding.river_xkb_binding.enable();
                }
                for (wm.pointer_binding_list.items) |pointer_binding| {
                    pointer_binding.river_pointer_binding.enable();
                }
            }
            wm.task = .none;
        },
        .exit => {
            river_window_manager.exitSession();
            wm.deinit();
        },
        .none => river_seat.opEnd(),
    }
}
