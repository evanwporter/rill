//! Column arithmetic for the scroll chain.
//!
//! A column is a run of consecutive tiled windows: a head with `stacked`
//! clear, followed by its members with `stacked` set. The members divide the
//! head's slot vertically instead of taking slots of their own.
//!
//! Everything here is deliberately free of wayland types and takes a plain
//! slice, so it can be tested without a compositor or generated protocol
//! bindings: `zig build test`. The window type only has to expose
//! `stacked`.

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
