const std = @import("std");
const sig = @import("../sig.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

/// A list that recycles items that were removed from the list.
///
/// Useful for types that are expensive to instantiate, like
/// those that include allocations.
///
/// When you call `addOne`, it returns a pointer to an item of type
/// type T, which could either be a new item created with initBlank,
/// or one that was previously removed from the list and had
/// resetItem called on it.
pub fn RecyclingList(
    comptime T: type,
    comptime initBlank: fn (Allocator) T,
    comptime resetItem: fn (*T) void,
    comptime deinitOne: fn (T) void,
) type {
    return struct {
        /// Contains valid items up to `len`
        /// Any other items beyond len in this arraylist are not valid.
        private: ArrayList(T),
        len: usize = 0,

        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return .{ .private = ArrayList(T).init(allocator) };
        }

        pub fn deinit(self: Self) void {
            for (self.private.items) |item| deinitOne(item);
            self.private.deinit();
        }

        pub fn items(self: *const Self) []const T {
            return self.private.items[0..self.len];
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.len = 0;
        }

        pub fn addOne(self: *Self) Allocator.Error!*T {
            if (self.len < self.private.items.len) {
                const item = &self.private.items[self.len];
                resetItem(item);
                self.len += 1;
                return item;
            } else {
                const item = try self.private.addOne();
                item.* = initBlank(self.private.allocator);
                self.len += 1;
                return item;
            }
        }

        pub fn drop(self: *Self, n: usize) void {
            self.len -|= n;
        }
    };
}

/// A set that guarantees the contained items will be sorted whenever
/// accessed through public methods like `items` and `range`.
///
/// Compatible with numbers, slices of numbers, and types that have an "order" method
pub fn SortedSet(comptime T: type) type {
    return SortedSetCustom(T, .{});
}

/// A set that guarantees the contained items will be sorted whenever
/// accessed through public methods like `items` and `range`.
pub fn SortedSetCustom(comptime T: type, comptime config: SortedMapConfig(T)) type {
    return struct {
        map: SortedMapCustom(T, void, config),

        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return .{ .map = SortedMapCustom(T, void, config).init(allocator) };
        }

        pub fn deinit(self: Self) void {
            self.map.deinit();
        }

        pub fn clone(self: Self) !Self {
            return .{ .map = try self.map.clone() };
        }

        pub fn eql(self: *Self, other: *Self) bool {
            return self.map.eql(&other.map);
        }

        pub fn put(self: *Self, item: T) !void {
            try self.map.put(item, {});
        }

        pub fn remove(self: *Self, item: T) bool {
            return self.map.remove(item);
        }

        pub fn contains(self: Self, item: T) bool {
            return self.map.contains(item);
        }

        pub fn count(self: Self) usize {
            return self.map.count();
        }

        pub fn items(self: *Self) []const T {
            return self.map.keys();
        }

        /// subslice of items ranging from start (inclusive) to end (exclusive)
        pub fn range(self: *Self, start: ?T, end: ?T) []const T {
            return self.map.range(start, end)[0];
        }

        /// subslice of items ranging from start (inclusive) to end (exclusive)
        pub fn rangeCustom(self: *Self, start: ?Bound(T), end: ?Bound(T)) []const T {
            return self.map.rangeCustom(start, end)[0];
        }
    };
}

/// A map that guarantees the contained items will be sorted by key
/// whenever accessed through public methods like `keys` and `range`.
///
/// Compatible with numbers, slices of numbers, and types that have an "order" method
pub fn SortedMap(comptime K: type, comptime V: type) type {
    return SortedMapCustom(K, V, .{});
}

/// A map that guarantees the contained items will be sorted by key
/// whenever accessed through public methods like `keys` and `range`.
///
/// TODO consider reimplementing with something faster (e.g. binary tree)
pub fn SortedMapCustom(
    comptime K: type,
    comptime V: type,
    comptime config: SortedMapConfig(K),
) type {
    return struct {
        inner: Inner,
        max: ?K = null,
        is_sorted: bool = true,

        const Inner = std.ArrayHashMap(K, V, config.Context, config.store_hash);

        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return .{
                .inner = Inner.init(allocator),
            };
        }

        pub fn deinit(self: Self) void {
            var self_mut = self;
            self_mut.inner.deinit();
        }

        pub fn clone(self: Self) !Self {
            return .{
                .inner = try self.inner.clone(),
                .max = self.max,
                .is_sorted = self.is_sorted,
            };
        }

        pub fn eql(self: *Self, other: *Self) bool {
            if (self.count() != other.count()) return false;
            self.sort();
            other.sort();
            for (
                self.inner.keys(),
                self.inner.values(),
                other.inner.keys(),
                other.inner.values(),
            ) |sk, sv, ok, ov| {
                if (sk != ok or sv != ov) return false;
            }
            return true;
        }

        pub fn get(self: Self, key: K) ?V {
            return self.inner.get(key);
        }

        pub fn getEntry(self: Self, key: K) ?Inner.Entry {
            return self.inner.getEntry(key);
        }

        pub fn fetchSwapRemove(self: *Self, key: K) ?Inner.KV {
            const item = self.inner.fetchSwapRemove(key);
            self.resetMaxOnRemove(key);
            return item;
        }

        pub fn getOrPut(self: *Self, key: K) !std.AutoArrayHashMap(K, V).GetOrPutResult {
            const result = try self.inner.getOrPut(key);
            if (self.max == null or order(key, self.max.?) == .gt) {
                self.max = key;
            } else {
                self.is_sorted = false;
            }
            return result;
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            try self.inner.put(key, value);
            if (self.max == null or order(key, self.max.?) == .gt) {
                self.max = key;
            } else {
                self.is_sorted = false;
            }
        }

        pub fn remove(self: *Self, key: K) bool {
            const item = self.inner.orderedRemove(key);
            self.resetMaxOnRemove(key);
            return item;
        }

        fn resetMaxOnRemove(self: *Self, removed_key: K) void {
            if (self.max) |max| {
                if (self.count() == 0) {
                    self.max = null;
                } else if (order(removed_key, max) == .eq) {
                    self.sort();
                    const sorted_keys = self.keys();
                    self.max = sorted_keys[sorted_keys.len - 1];
                }
            }
        }

        pub fn contains(self: Self, key: K) bool {
            return self.inner.contains(key);
        }

        pub fn count(self: Self) usize {
            return self.inner.count();
        }

        pub fn keys(self: *Self) []const K {
            self.sort();
            return self.inner.keys();
        }

        pub fn items(self: *Self) struct { []const K, []const V } {
            self.sort();
            return .{ self.inner.keys(), self.inner.values() };
        }

        pub fn iterator(self: *Self) Inner.Iterator {
            self.sort();
            return self.inner.iterator();
        }

        /// subslice of items ranging from start (inclusive) to end (exclusive)
        pub fn range(self: *Self, start: ?K, end: ?K) struct { []const K, []const V } {
            return self.rangeCustom(
                if (start) |b| .{ .inclusive = b } else null,
                if (end) |b| .{ .exclusive = b } else null,
            );
        }

        /// subslice of items ranging from start to end
        pub fn rangeCustom(
            self: *Self,
            start_bound: ?Bound(K),
            end_bound: ?Bound(K),
        ) struct { []const K, []const V } {
            // TODO: can the code in this fn be simplified while retaining identical logic?
            const len = self.count();
            if (len == 0) return .{ &.{}, &.{} };

            // extract relevant info from bounds
            const start, const incl_start = if (start_bound) |b|
                .{ b.val(), b == .inclusive }
            else
                .{ null, false };
            const end, const excl_end = if (end_bound) |b|
                .{ b.val(), b == .exclusive }
            else
                .{ null, false };

            // edge case: check if bounds could permit any items
            if (start) |s| if (end) |e| {
                if (incl_start and !excl_end) {
                    if (order(e, s) == .lt) return .{ &.{}, &.{} };
                } else if (order(e, s) != .gt) return .{ &.{}, &.{} };
            };

            self.sort();
            var keys_ = self.inner.keys();
            var values_ = self.inner.values();
            if (start) |start_| {
                // .any instead of .first because uniqueness is guaranteed
                const start_index = switch (binarySearch(K, keys_, start_, .any, order)) {
                    .found => |index| if (incl_start) index else @min(len - 1, index + 1),
                    .after => |index| index + 1,
                    .less => 0,
                    .greater => return .{ &.{}, &.{} },
                    .empty => unreachable, // count checked above
                };
                keys_ = keys_[start_index..];
                values_ = values_[start_index..];
            }
            if (end) |end_| {
                // .any instead of .last because uniqueness is guaranteed
                const end_index = switch (binarySearch(K, keys_, end_, .any, order)) {
                    .found => |index| if (excl_end) index else index + 1,
                    .after => |index| index + 1,
                    .less => return .{ &.{}, &.{} },
                    .greater => keys_.len,
                    .empty => unreachable, // count checked above
                };
                keys_ = keys_[0..end_index];
                values_ = values_[0..end_index];
            }
            return .{ keys_, values_ };
        }

        fn sort(self: *Self) void {
            if (self.is_sorted) return;
            self.inner.sort(struct {
                items: std.MultiArrayList(Inner.Unmanaged.Data).Slice,
                pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                    return order(ctx.items.get(a_index).key, ctx.items.get(b_index).key) == .lt;
                }
            }{ .items = self.inner.unmanaged.entries.slice() });
            self.is_sorted = true;
        }
    };
}

pub fn Bound(comptime T: type) type {
    return union(enum) {
        inclusive: T,
        exclusive: T,

        pub fn val(self: @This()) T {
            return switch (self) {
                inline .inclusive, .exclusive => |x| x,
            };
        }
    };
}

pub fn SortedMapConfig(comptime K: type) type {
    const default_Context, const default_store_hash = if (K == []const u8 or K == []u8)
        .{ std.array_hash_map.StringContext, true }
    else
        .{ std.array_hash_map.AutoContext(K), !std.array_hash_map.autoEqlIsCheap(K) };

    return struct {
        orderFn: fn (a: anytype, b: anytype) std.math.Order = order,
        /// passthrough to std.ArrayHashMap
        Context: type = default_Context,
        /// passthrough to std.ArrayHashMap
        store_hash: bool = default_store_hash,
    };
}

pub fn order(a: anytype, b: anytype) std.math.Order {
    const T: type = @TypeOf(a);
    if (T != @TypeOf(b)) @compileError("types do not match");
    const info = @typeInfo(T);
    switch (info) {
        .Int, .Float => return std.math.order(a, b),
        .Struct, .Enum, .Union, .Opaque => {
            if (@hasDecl(T, "order") and
                (@TypeOf(T.order) == fn (a: T, b: T) std.math.Order or
                @TypeOf(T.order) == fn (a: anytype, b: anytype) std.math.Order))
            {
                return T.order(a, b);
            }
        },
        .Pointer => {
            const child = @typeInfo(info.Pointer.child);
            if (info.Pointer.size == .Slice and (child == .Int or child == .Float)) {
                return orderSlices(info.Pointer.child, std.math.order, a, b);
            }
        },
        else => {},
    }
    @compileError(std.fmt.comptimePrint("`order` not supported for {}", .{T}));
}

pub const BinarySearchResult = union(enum) {
    /// item was found at this index
    found: usize,
    /// not found, but it's between this and the next index
    after: usize,
    /// the search term is less than all items in the slice
    less,
    /// the search term is greater than all items in the slice
    greater,
    /// the input slice is empty
    empty,
};

/// binary search that is very specific about the outcome.
/// only works with numbers
pub fn binarySearch(
    comptime T: type,
    /// slice to look for the item
    items: []const T,
    /// item to search for
    search_term: T,
    /// If the number appears multiple times in the list,
    /// this decides which one to return.
    comptime which: enum { any, first, last },
    /// should have one of the following types:
    /// - fn(a: T, b: T) std.math.Order
    /// - fn(a: anytype, b: anytype) std.math.Order
    comptime orderFn: anytype,
) BinarySearchResult {
    if (items.len == 0) return .empty;

    // binary search for the item
    var left: usize = 0;
    var right: usize = items.len;
    const maybe_index = while (left < right) {
        const mid = left + (right - left) / 2;
        switch (orderFn(search_term, items[mid])) {
            .eq => break mid,
            .gt => left = mid + 1,
            .lt => right = mid,
        }
    } else null;

    // handle no match
    if (maybe_index == null) {
        return if (right == 0)
            .less
        else if (left == items.len)
            .greater
        else if (orderFn(items[left], search_term) == .gt)
            .{ .after = left - 1 }
        else if (orderFn(items[left], search_term) == .lt)
            .{ .after = left }
        else
            unreachable;
    }
    var index = maybe_index.?;

    // match found, move to edge if there are duplicates
    switch (which) {
        .any => {},
        .first => while (index > 0 and items[index - 1] == search_term) {
            index -= 1;
        },
        .last => while (index < items.len - 1 and items[index + 1] == search_term) {
            index += 1;
        },
    }

    return .{ .found = index };
}

pub fn orderSlices(
    comptime T: type,
    /// should have one of the following types:
    /// - fn(a: T, b: T) std.math.Order
    /// - fn(a: anytype, b: anytype) std.math.Order
    comptime orderElem: anytype,
    a: []const T,
    b: []const T,
) std.math.Order {
    var i: usize = 0;
    while (i < a.len and i < b.len) : (i += 1) {
        const order_ = orderElem(a[i], b[i]);
        if (order_ == .eq) {
            continue;
        } else {
            return order_;
        }
    }
    return if (a.len == b.len) .eq else if (a.len > b.len) .gt else .lt;
}

/// Stores a range of values centered at a particular index that may
/// change with respect to time.
///
/// This is useful when you are tracking multiple different states
/// that occur in a sequence, and they each have a predefined lifetime.
///
/// For example, let's say you need to create a new data structure to
/// represent every Epoch. At any point in time, you'd like store to
/// the struct for the current Epoch as well as the next Epoch and
/// the prior Epoch. You can create a Window with a size of 3 centered
/// at the current Epoch. It will allow you to store all three of the
/// Epochs you care about. When transitioning Epochs, call `realign`
/// to adjust the center to the new Epoch. This will delete the state
/// from the old Epoch out of the Window, and open up a slot for you
/// to insert the next Epoch.
pub fn Window(T: type) type {
    return struct {
        state: []?T,
        center: usize,
        offset: usize,

        const Self = @This();

        pub fn init(allocator: Allocator, len: usize, start: usize) !Self {
            const state = try allocator.alloc(?T, len);
            @memset(state, null);
            return .{
                .state = state,
                .center = start,
                .offset = len - (start % len),
            };
        }

        pub fn deinit(self: Self, allocator: Allocator) void {
            allocator.free(self.state);
        }

        /// Inserts the item into the Window, as long as its index
        /// is within the current allowed bounds of the Window.
        pub fn put(self: *Self, index: usize, item: T) error{OutOfBounds}!?T {
            if (!self.isInRange(index)) {
                return error.OutOfBounds;
            }
            const ptr = self.getAssumed(index);
            const old = ptr.*;
            ptr.* = item;
            return old;
        }

        /// Returns the requested value if its index is within the
        /// bounds and has been populated by `put`.
        pub fn get(self: *Self, index: usize) ?T {
            return if (self.isInRange(index)) self.getAssumed(index).* else null;
        }

        pub fn contains(self: *Self, index: usize) bool {
            return self.isInRange(index) and self.getAssumed(index).* != null;
        }

        /// Changes the center of the window, deleting any evicted values.
        /// The evicted values will be populated in the deletion_buf with
        /// the relevant subslice returned.
        pub fn realignGet(self: *Self, new_center: usize, deletion_buf: []?T) []?T {
            return self.realignImpl(new_center, deletion_buf).?;
        }

        /// Changes the center of the window, removing any evicted values.
        pub fn realign(self: *Self, new_center: usize) void {
            _ = self.realignImpl(new_center, null);
        }

        fn realignImpl(self: *Self, new_center: usize, optional_deletion_buf: ?[]?T) ?[]?T {
            var return_buf: ?[]?T = null;
            if (self.center < new_center) {
                const num_to_delete = @min(new_center - self.center, self.state.len);
                const low = self.lowest();
                return_buf = self.deleteRange(low, low + num_to_delete, optional_deletion_buf);
            } else if (self.center > new_center) {
                const num_to_delete = @min(self.center - new_center, self.state.len);
                const top = self.highest() + 1;
                return_buf = self.deleteRange(top - num_to_delete, top, optional_deletion_buf);
            }
            self.center = new_center;
            return return_buf;
        }

        fn isInRange(self: *const Self, index: usize) bool {
            return index <= self.highest() and index >= self.lowest();
        }

        fn highest(self: *const Self) usize {
            return self.center + self.state.len / 2 - (self.state.len + 1) % 2;
        }

        fn lowest(self: *const Self) usize {
            return self.center -| self.state.len / 2;
        }

        fn getAssumed(self: *Self, index: usize) *?T {
            return &self.state[(index + self.offset) % self.state.len];
        }

        fn deleteRange(self: *Self, start: usize, end: usize, optional_deletion_buf: ?[]?T) ?[]?T {
            for (start..end, 0..) |in_index, out_index| {
                const item = self.getAssumed(in_index);
                if (optional_deletion_buf) |deletion_buf| {
                    deletion_buf[out_index] = item.*;
                }
                item.* = null;
            }
            return if (optional_deletion_buf) |buf| buf[0 .. end - start] else null;
        }
    };
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

test SortedSet {
    var set = SortedSet(u64).init(std.testing.allocator);
    defer set.deinit();

    // add/contains
    try expect(!set.contains(3));
    try set.put(3);
    try expect(set.contains(3));
    try set.put(0);
    try set.put(2);
    try set.put(1);
    try set.put(4);
    try set.put(5);

    // remove
    try expect(set.remove(5));
    try expect(!set.contains(5));
    try expect(!set.remove(5));
    try set.put(5);
    try expect(set.contains(5));

    // ordering
    for (set.items(), 0..) |key, i| {
        try expect(key == i);
    }
}

test "SortedSet range" {
    var set = SortedSet(u8).init(std.testing.allocator);
    defer set.deinit();

    try set.put(5);
    try set.put(3);
    try set.put(1);
    try set.put(3);

    try expectEqualSlices(u8, &.{ 1, 3, 5 }, set.range(null, null));
    try expectEqualSlices(u8, &.{}, set.range(0, 0));
    try expectEqualSlices(u8, &.{}, set.range(10, 10));
    try expectEqualSlices(u8, &.{}, set.range(10, 11));
    try expectEqualSlices(u8, &.{}, set.range(12, 11));
    try expectEqualSlices(u8, &.{1}, set.range(null, 3));
    try expectEqualSlices(u8, &.{ 1, 3 }, set.range(null, 4));
    try expectEqualSlices(u8, &.{ 1, 3 }, set.range(null, 5));
    try expectEqualSlices(u8, &.{ 1, 3, 5 }, set.range(null, 6));
    try expectEqualSlices(u8, &.{ 1, 3, 5 }, set.range(0, null));
    try expectEqualSlices(u8, &.{ 1, 3, 5 }, set.range(1, null));
    try expectEqualSlices(u8, &.{ 3, 5 }, set.range(2, null));
    try expectEqualSlices(u8, &.{ 3, 5 }, set.range(3, null));
    try expectEqualSlices(u8, &.{5}, set.range(4, null));
    try expectEqualSlices(u8, &.{5}, set.range(5, null));
    try expectEqualSlices(u8, &.{ 1, 3, 5 }, set.range(1, 6));
    try expectEqualSlices(u8, &.{ 1, 3 }, set.range(1, 5));
    try expectEqualSlices(u8, &.{ 1, 3 }, set.range(1, 4));
    try expectEqualSlices(u8, &.{1}, set.range(1, 3));
    try expectEqualSlices(u8, &.{1}, set.range(1, 2));
    try expectEqualSlices(u8, &.{}, set.range(1, 1));
    try expectEqualSlices(u8, &.{ 3, 5 }, set.range(2, 6));
    try expectEqualSlices(u8, &.{ 3, 5 }, set.range(3, 6));
    try expectEqualSlices(u8, &.{5}, set.range(4, 6));
    try expectEqualSlices(u8, &.{5}, set.range(5, 6));
    try expectEqualSlices(u8, &.{3}, set.range(3, 4));
    try expectEqualSlices(u8, &.{}, set.range(3, 3));
    try expectEqualSlices(u8, &.{}, set.range(2, 3));
    try expectEqualSlices(u8, &.{}, set.range(2, 2));
}

test binarySearch {
    const items: [4]u8 = .{ 1, 3, 3, 5 };
    inline for (.{ .any, .first, .last }) |w| {
        try expectEqual(binarySearch(u8, &items, 0, w, std.math.order), .less);
        try expectEqual(binarySearch(u8, &items, 1, w, std.math.order).found, 0);
        try expectEqual(binarySearch(u8, &items, 2, w, std.math.order).after, 0);
        try expectEqual(binarySearch(u8, &items, 4, w, std.math.order).after, 2);
        try expectEqual(binarySearch(u8, &items, 5, w, std.math.order).found, 3);
        try expectEqual(binarySearch(u8, &items, 6, w, std.math.order), .greater);
    }
    expect(binarySearch(u8, &items, 3, .any, std.math.order).found == 1) catch {
        try expectEqual(binarySearch(u8, &items, 3, .any, std.math.order).found, 2);
    };
    try expectEqual(binarySearch(u8, &items, 3, .first, std.math.order).found, 1);
    try expectEqual(binarySearch(u8, &items, 3, .last, std.math.order).found, 2);
}

test "order slices" {
    const a: [3]u8 = .{ 1, 2, 3 };
    const b: [3]u8 = .{ 2, 2, 3 };
    const c: [3]u8 = .{ 1, 2, 4 };
    const d: [3]u8 = .{ 1, 2, 3 };
    const e: [4]u8 = .{ 1, 2, 3, 4 };
    try expectEqual(orderSlices(u8, std.math.order, &a, &b), .lt);
    try expectEqual(orderSlices(u8, std.math.order, &b, &a), .gt);
    try expectEqual(orderSlices(u8, std.math.order, &a, &c), .lt);
    try expectEqual(orderSlices(u8, std.math.order, &c, &a), .gt);
    try expectEqual(orderSlices(u8, std.math.order, &a, &d), .eq);
    try expectEqual(orderSlices(u8, std.math.order, &d, &a), .eq);
    try expectEqual(orderSlices(u8, std.math.order, &a, &e), .lt);
    try expectEqual(orderSlices(u8, std.math.order, &e, &a), .gt);

    try expectEqual(orderSlices(u8, std.math.order, &b, &c), .gt);
    try expectEqual(orderSlices(u8, std.math.order, &c, &b), .lt);
    try expectEqual(orderSlices(u8, std.math.order, &b, &e), .gt);
    try expectEqual(orderSlices(u8, std.math.order, &e, &b), .lt);
}

test "sorted set slice range" {
    var set = SortedSet([]const u8).init(std.testing.allocator);
    defer set.deinit();
    try set.put(&.{ 0, 0, 10 });
    try set.put(&.{ 0, 0, 20 });
    try set.put(&.{ 0, 0, 30 });
    try set.put(&.{ 0, 0, 40 });

    const range = set.rangeCustom(null, .{ .inclusive = &.{ 0, 0, 40 } });

    try std.testing.expectEqual(4, range.len);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 10 }, range[0]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 20 }, range[1]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 30 }, range[2]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 40 }, range[3]);
}

test "binarySearch slice of slices" {
    const slices = [4][]const u8{
        &.{ 0, 0, 10 },
        &.{ 0, 0, 20 },
        &.{ 0, 0, 30 },
        &.{ 0, 0, 40 },
    };

    try std.testing.expectEqual(
        BinarySearchResult{ .found = 3 },
        binarySearch([]const u8, &slices, &.{ 0, 0, 40 }, .any, order),
    );
    try std.testing.expectEqual(
        BinarySearchResult{ .after = 2 },
        binarySearch([]const u8, &slices, &.{ 0, 0, 39 }, .any, order),
    );
    try std.testing.expectEqual(
        BinarySearchResult.greater,
        binarySearch([]const u8, &slices, &.{ 0, 0, 41 }, .any, order),
    );

    try std.testing.expectEqual(
        BinarySearchResult{ .found = 0 },
        binarySearch([]const u8, &slices, &.{ 0, 0, 10 }, .any, order),
    );
    try std.testing.expectEqual(
        BinarySearchResult{ .after = 0 },
        binarySearch([]const u8, &slices, &.{ 0, 0, 11 }, .any, order),
    );
    try std.testing.expectEqual(
        BinarySearchResult.less,
        binarySearch([]const u8, &slices, &.{ 0, 0, 9 }, .any, order),
    );

    try std.testing.expectEqual(
        BinarySearchResult{ .found = 1 },
        binarySearch([]const u8, &slices, &.{ 0, 0, 20 }, .any, order),
    );
    try std.testing.expectEqual(
        BinarySearchResult{ .after = 1 },
        binarySearch([]const u8, &slices, &.{ 0, 0, 21 }, .any, order),
    );
}

test "Window starts empty" {
    var window = try Window(u64).init(std.testing.allocator, 5, 7);
    defer window.deinit(std.testing.allocator);
    for (0..20) |i| {
        try std.testing.expect(null == window.get(i));
    }
}

test "Window populates and repopulates (odd)" {
    var window = try Window(u64).init(std.testing.allocator, 5, 7);
    defer window.deinit(std.testing.allocator);
    for (0..20) |i| {
        const result = window.put(i, i * 10);
        if (i < 5 or i > 9) {
            try std.testing.expectError(error.OutOfBounds, result);
        } else {
            try std.testing.expectEqual(null, try result);
        }
    }
    for (0..20) |i| {
        const result = window.put(i, i * 100);
        if (i < 5 or i > 9) {
            try std.testing.expectError(error.OutOfBounds, result);
        } else {
            try std.testing.expectEqual(i * 10, try result);
        }
    }
    for (0..20) |i| {
        const result = window.get(i);
        if (i < 5 or i > 9) {
            try std.testing.expectEqual(null, result);
        } else {
            try std.testing.expectEqual(i * 100, result);
        }
    }
}

test "Window populates (even)" {
    var window = try Window(u64).init(std.testing.allocator, 4, 7);
    defer window.deinit(std.testing.allocator);
    for (0..20) |i| {
        const result = window.put(i, i * 10);
        if (i < 5 or i > 8) {
            try std.testing.expectError(error.OutOfBounds, result);
        } else {
            try std.testing.expectEqual(null, try result);
        }
    }
    for (0..20) |i| {
        const result = window.get(i);
        if (i < 5 or i > 8) {
            try std.testing.expectEqual(null, result);
        } else {
            try std.testing.expectEqual(i * 10, result);
        }
    }
}

test "Window realigns" {
    var window = try Window(u64).init(std.testing.allocator, 4, 0);
    defer window.deinit(std.testing.allocator);
    window.realign(7);
    for (5..9) |i| {
        _ = try window.put(i, i * 10);
    }
    var deletion_buf: [4]?u64 = undefined;

    const deletion = window.realignGet(8, deletion_buf[0..]);
    try std.testing.expectEqual(1, deletion.len);
    try std.testing.expectEqual(50, deletion[0]);

    const deletion2 = window.realignGet(6, deletion_buf[0..]);
    try std.testing.expectEqual(2, deletion2.len);
    try std.testing.expectEqual(80, deletion2[0]);
    try std.testing.expectEqual(null, deletion2[1]);

    for (0..20) |i| {
        const result = window.get(i);
        if (i < 6 or i > 7) {
            try std.testing.expectEqual(null, result);
        } else {
            try std.testing.expectEqual(i * 10, result);
        }
    }

    const deletion3 = window.realignGet(20, deletion_buf[0..]);
    try std.testing.expectEqual(4, deletion3.len);
    try std.testing.expectEqual(null, deletion3[0]);
    try std.testing.expectEqual(null, deletion3[1]);
    try std.testing.expectEqual(60, deletion3[2]);
    try std.testing.expectEqual(70, deletion3[3]);

    for (0..40) |i| {
        try std.testing.expectEqual(null, window.get(i));
    }
}
