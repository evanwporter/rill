const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Strip debug information") orelse false;
    const pie = b.option(bool, "pie", "Build position independent executable") orelse true;

    const scanner = Scanner.create(b, .{});
    const river_protocol = b.dependency("river_protocol", .{});

    scanner.addCustomProtocol(river_protocol.path("river-window-management-v1.xml"));
    scanner.addCustomProtocol(river_protocol.path("river-xkb-bindings-v1.xml"));
    scanner.addCustomProtocol(river_protocol.path("river-layer-shell-v1.xml"));

    scanner.generate("river_window_manager_v1", 4);
    scanner.generate("river_xkb_bindings_v1", 1);
    scanner.generate("river_layer_shell_v1", 1);

    const wayland = b.createModule(.{ .root_source_file = scanner.result });
    const xkbcommon = b.dependency("xkbcommon", .{}).module("xkbcommon");

    const imports = [_]std.Build.Module.Import{
        .{ .name = "wayland", .module = wayland },
        .{ .name = "xkbcommon", .module = xkbcommon },
    };

    const rill = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
        .strip = strip,
    });

    rill.linkSystemLibrary("wayland-client", .{});
    rill.linkSystemLibrary("xkbcommon", .{});

    const exe = b.addExecutable(.{
        .name = "rill",
        .root_module = rill,
    });
    exe.pie = pie;

    b.installArtifact(exe);

    const column = b.createModule(.{
        .root_source_file = b.path("src/column.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/column.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "column", .module = column }},
        }),
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
