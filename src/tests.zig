const std = @import("std");
const sig = @import("sig.zig");

comptime {
    refAllDeclsRecursive(sig, 2);
    refAllDeclsRecursive(sig.ledger, 2);
}

/// Like std.testing.refAllDeclsRecursive, except:
/// - you can specify depth to avoid infinite or unnecessary recursion.
/// - runs at comptime to avoid compiler errors for hypothetical
///   code paths that would never actually run.
pub inline fn refAllDeclsRecursive(comptime T: type, comptime depth: usize) void {
    if (depth == 0) return;
    inline for (comptime std.meta.declarations(T)) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .Struct,
                .Enum,
                .Union,
                .Opaque,
                => refAllDeclsRecursive(@field(T, decl.name), depth - 1),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}
