const std = @import("std");
const column = @import("column");

const head = column.head;
const len = column.len;
const end = column.end;
const next = column.next;
const previous = column.previous;
const detach = column.detach;
const normalize = column.normalize;
const hasAbove = column.hasAbove;
const hasBelow = column.hasBelow;
const slotHeight = column.slotHeight;

const TestWindow = struct { stacked: bool = false };

/// Build a list from a compact spec, one character per window:
///   'h' tiled column head, 's' tiled stacked member
fn build(comptime spec: []const u8) [spec.len]TestWindow {
    var items: [spec.len]TestWindow = undefined;
    for (spec, 0..) |c, i| {
        items[i] = switch (c) {
            'h' => .{},
            's' => .{ .stacked = true },
            else => unreachable,
        };
    }
    return items;
}

test "a list with nothing stacked is one column per window" {
    var items = build("hhh");
    for (0..3) |i| {
        try std.testing.expectEqual(i, head(&items, i));
        try std.testing.expectEqual(@as(usize, 1), len(&items, i));
        try std.testing.expectEqual(i + 1, end(&items, i));
    }
    try std.testing.expectEqual(@as(?usize, 1), next(&items, 0));
    try std.testing.expectEqual(@as(?usize, null), next(&items, 2));
    try std.testing.expectEqual(@as(?usize, 1), previous(&items, 2));
    try std.testing.expectEqual(@as(?usize, null), previous(&items, 0));
}

test "members resolve to their head and are counted" {
    // column A = {0,1,2}, column B = {3}
    var items = build("hssh");
    for (0..3) |i| try std.testing.expectEqual(@as(usize, 0), head(&items, i));
    try std.testing.expectEqual(@as(usize, 3), head(&items, 3));
    try std.testing.expectEqual(@as(usize, 3), len(&items, 0));
    try std.testing.expectEqual(@as(usize, 1), len(&items, 3));
}

test "a new window inserts after the whole column, never inside it" {
    var items = build("hssh");
    // Focus anywhere in the first column: insertion point is past its members.
    for (0..3) |i| try std.testing.expectEqual(@as(usize, 3), end(&items, i));
    try std.testing.expectEqual(@as(usize, 4), end(&items, 3));
}

test "horizontal movement steps over a whole column" {
    var items = build("hssh");
    try std.testing.expectEqual(@as(?usize, 3), next(&items, 0));
    try std.testing.expectEqual(@as(?usize, 3), next(&items, 2));
    try std.testing.expectEqual(@as(?usize, 0), previous(&items, 3));
}

test "detaching a head promotes the member below it" {
    var items = build("hhss");
    // Column {1,2,3}; removing window 1 must promote 2, or 2 and 3 would be
    // adopted by the column at 0.
    detach(&items, 1);
    try std.testing.expect(!items[2].stacked);
    try std.testing.expect(items[3].stacked);
    // With window 1 gone, {2,3} is a column of its own.
    var after = build("hhs");
    try std.testing.expectEqual(@as(usize, 1), head(&after, 2));
    try std.testing.expectEqual(@as(usize, 2), len(&after, 1));
}

test "detaching a member leaves the column alone" {
    var items = build("hss");
    detach(&items, 1);
    try std.testing.expect(items[1].stacked);
    try std.testing.expect(items[2].stacked);
}

test "normalize repairs an orphaned member" {
    var items = build("shs");
    normalize(&items);
    try std.testing.expect(!items[0].stacked);
    try std.testing.expect(items[2].stacked);
}

test "vertical movement falls through only at the ends of a column" {
    // column A = {0,1,2}, column B = {3}
    var items = build("hssh");

    // Top member: nothing above, so up leaves the workspace; down stays.
    try std.testing.expect(!hasAbove(&items, 0));
    try std.testing.expect(hasBelow(&items, 0));
    // Middle member: stays in the column both ways.
    try std.testing.expect(hasAbove(&items, 1));
    try std.testing.expect(hasBelow(&items, 1));
    // Bottom member: down leaves the workspace.
    try std.testing.expect(hasAbove(&items, 2));
    try std.testing.expect(!hasBelow(&items, 2));
    // A column of one falls through in both directions, which is what makes
    // this safe to bind over plain workspace switching.
    try std.testing.expect(!hasAbove(&items, 3));
    try std.testing.expect(!hasBelow(&items, 3));
}

test "an unstacked workspace always falls through" {
    var items = build("hhh");
    for (0..3) |i| {
        try std.testing.expect(!hasAbove(&items, i));
        try std.testing.expect(!hasBelow(&items, i));
    }
}

test "a split column tiles its slot exactly, whatever the rounding" {
    // The property that matters: the members plus the gaps between them fill
    // the column exactly -- no overlap, no stray pixel at the bottom.
    const heights = [_]i32{ 1080, 1081, 1000, 997, 100 };
    const gaps = [_]i32{ 0, 5, 8, 13 };
    const counts = [_]i32{ 2, 3, 4, 7 };

    for (heights) |total| {
        for (gaps) |gap| {
            for (counts) |count| {
                if (total < count * (gap + 1)) continue;

                var y: i32 = 0;
                var placed: i32 = 0;
                while (placed < count) : (placed += 1) {
                    const remaining = count - placed;
                    const height = slotHeight(total - y, gap, remaining);
                    try std.testing.expect(height > 0);
                    y += height;
                    if (placed + 1 < count) y += gap;
                }
                try std.testing.expectEqual(total, y);
            }
        }
    }
}

test "head terminates on an unnormalised list" {
    // Leading member with nothing before it: must resolve to itself, not loop.
    var items = build("ss");
    try std.testing.expectEqual(@as(usize, 0), head(&items, 0));
    try std.testing.expectEqual(@as(usize, 0), head(&items, 1));
}
