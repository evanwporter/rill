const std = @import("std");

const types = @import("types.zig");

pub fn load(
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    environ_map: *std.process.Environ.Map,
) types.Config {
    if (loadConfigFrom(gpa, io, arena, environ_map)) |config| {
        return config;
    } else |err| {
        std.debug.print("Failed to load config from $HOME/.config/rill/config.zon: {}\n", .{err});
    }

    return .{};
}

fn loadConfigFrom(
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    environ_map: *std.process.Environ.Map,
) !types.Config {
    const path = try std.Io.Dir.path.join(gpa, &.{
        environ_map.get("HOME") orelse return error.EnvironmentVariableNotFound,
        ".config",
        "rill",
        "config.zon",
    });
    defer gpa.free(path);

    const content = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .unlimited,
        .@"16",
        0,
    );
    defer gpa.free(content);

    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const config = try std.zon.parse.fromSlice(
        types.Config,
        .{
            .gpa = gpa,
            .arena = arena.allocator(),
            .source = content,
            .diagnostics = &diagnostics,
        },
    );

    return config;
}
