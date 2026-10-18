//! Column arithmetic for the scroll chain.
//!
//! A column is a run of consecutive tiled windows: a head with `stacked`
//! clear, followed by its members with `stacked` set. The members divide the
//! head's slot vertically instead of taking slots of their own.
//!
//! Everything here is deliberately free of wayland types and takes a plain
//! slice, so it can be tested without a compositor or generated protocol
//! bindings: `zig test src/column.zig`. The window type only has to expose
//! `stacked`.

const std = @import("std");

/// Nearest tiled window before `idx`.
pub fn previousTiled(items: anytype, idx: usize) ?usize {
    _ = items;
    return if (idx > 0) idx - 1 else null;
}

/// Nearest tiled window after `idx`.
pub fn nextTiled(items: anytype, idx: usize) ?usize {
    return if (idx + 1 < items.len) idx + 1 else null;
}

/// Head of the column containing `idx`. A window that is `stacked` with no
/// tiled window before it is treated as its own head, so a list that has not
/// been normalised still lays out sensibly instead of looping forever.
pub fn head(items: anytype, idx: usize) usize {
    var i = idx;
    while (items[i].stacked) {
        i = previousTiled(items, i) orelse return i;
    }
    return i;
}

/// Number of windows sharing the column headed by `head_idx`.
pub fn len(items: anytype, head_idx: usize) usize {
    var count: usize = 1;
    var i = head_idx;
    while (nextTiled(items, i)) |j| {
        if (!items[j].stacked) break;
        count += 1;
        i = j;
    }
    return count;
}

/// Index one past the last member of the column containing `idx`: where a
/// window has to be inserted for it to start a new column. Landing anywhere
/// inside an existing column would make the members after the insertion point
/// adopt the newcomer as their head, silently splitting the column in two.
/// With nothing stacked this is just `idx + 1`.
pub fn end(items: anytype, idx: usize) usize {
    var i = head(items, idx);
    while (nextTiled(items, i)) |j| {
        if (!items[j].stacked) break;
        i = j;
    }
    return i + 1;
}

/// Head of the column before the one containing `idx`.
pub fn previous(items: anytype, idx: usize) ?usize {
    const before = previousTiled(items, head(items, idx)) orelse return null;
    return head(items, before);
}

/// Head of the column after the one containing `idx`.
pub fn next(items: anytype, idx: usize) ?usize {
    var i = head(items, idx);
    while (nextTiled(items, i)) |j| {
        if (!items[j].stacked) return j;
        i = j;
    }
    return null;
}

/// Detach the window at `idx` from its column, promoting the member below it
/// when it was the head. Call this *before* removing a window: without it the
/// orphaned members keep `stacked` set and are adopted by whatever column now
/// precedes them, so closing a column head would merge its contents into the
/// column on its left.
pub fn detach(items: anytype, idx: usize) void {
    if (items[idx].stacked) return;
    const next_idx = nextTiled(items, idx) orelse return;
    if (items[next_idx].stacked) items[next_idx].stacked = false;
}

/// Ensure the first window starts its own column after reordering.
pub fn normalize(items: anytype) void {
    if (items.len > 0) items[0].stacked = false;
}

/// Whether the window at `idx` has another window above it inside its own
/// column. False for a head, which is already the top. This decides whether vertical
/// movement stays in the stack or falls through to the workspace above.
pub fn hasAbove(items: anytype, idx: usize) bool {
    return items[idx].stacked;
}

/// Whether the window at `idx` has another window below it inside its own
/// column. The next tiled window starts a new column unless it is stacked.
pub fn hasBelow(items: anytype, idx: usize) bool {
    const below = nextTiled(items, idx) orelse return false;
    return items[below].stacked;
}

/// Height of the next slot when `remaining` windows still have to fit into
/// `remaining_height`, with `gap` between each pair.
///
/// Recomputed from the space still unassigned on every step rather than taken
/// as a single `height / count`: that spreads the rounding error over the
/// members instead of accumulating it, and makes the last slot land exactly on
/// the bottom edge of the column rather than leaving a stray pixel.
pub fn slotHeight(remaining_height: i32, gap: i32, remaining: i32) i32 {
    return @divTrunc(remaining_height - gap * (remaining - 1), remaining);
}

// -- tests -------------------------------------------------------------------

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
