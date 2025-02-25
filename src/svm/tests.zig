const std = @import("std");
const sig = @import("../sig.zig");
const lib = @import("lib.zig");
const memory = @import("memory.zig");
const Vm = @import("vm.zig").Vm;
const syscalls = @import("syscalls.zig");
const sbpf = @import("sbpf.zig");
const Elf = @import("elf.zig").Elf;

const Executable = lib.Executable;
const BuiltinProgram = lib.BuiltinProgram;
const Config = lib.Config;
const Region = memory.Region;
const MemoryMap = memory.MemoryMap;
const OpCode = sbpf.Instruction.OpCode;
const expectEqual = std.testing.expectEqual;

fn testAsm(config: Config, source: []const u8, expected: anytype) !void {
    return testAsmWithMemory(config, source, &.{}, expected);
}

fn testAsmWithMemory(
    config: Config,
    source: []const u8,
    program_memory: []const u8,
    expected: anytype,
) !void {
    const allocator = std.testing.allocator;
    var executable = try Executable.fromAsm(allocator, source, config);
    defer executable.deinit(allocator);

    const mutable = try allocator.dupe(u8, program_memory);
    defer allocator.free(mutable);

    const stack_memory = try allocator.alloc(u8, config.stackSize());
    defer allocator.free(stack_memory);

    const m = try MemoryMap.init(&.{
        Region.init(.constant, &.{}, memory.RODATA_START),
        Region.init(.mutable, stack_memory, memory.STACK_START),
        Region.init(.constant, &.{}, memory.HEAP_START),
        Region.init(.mutable, mutable, memory.INPUT_START),
    }, .v0);

    var loader: BuiltinProgram = .{};
    var vm = try Vm.init(
        allocator,
        &executable,
        m,
        &loader,
        .noop,
        stack_memory.len,
    );
    defer vm.deinit();

    const result = vm.run();
    try expectEqual(expected, result);
}

test "basic mov" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov r1, 1
        \\  mov r0, r1
        \\  return
    , 1);
}

test "mov32 imm large" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov32 r0, -1
        \\  return
    , 0xFFFFFFFF);
}

test "mov large" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov32 r1, -1
        \\  mov32 r0, r1
        \\  return
    , 0xFFFFFFFF);
}

test "bounce" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov r0, 1
        \\  mov r6, r0
        \\  mov r7, r6
        \\  mov r8, r7
        \\  mov r9, r8
        \\  mov r0, r9
        \\  return
    , 1);
}

test "add32" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov32 r0, 0
        \\  mov32 r1, 2
        \\  add32 r0, 1
        \\  add32 r0, r1
        \\  return
    , 3);
}

test "add64" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  lddw r0, 0x300000fff
        \\  add r0, -1
        \\  exit
    , 0x300000FFE);
}

test "alu32 logic" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov32 r0, 0
        \\  mov32 r1, 1
        \\  mov32 r2, 2
        \\  mov32 r3, 3
        \\  mov32 r4, 4
        \\  mov32 r5, 5
        \\  mov32 r6, 6
        \\  mov32 r7, 7
        \\  mov32 r8, 8
        \\  or32 r0, r5
        \\  or32 r0, 0xa0
        \\  and32 r0, 0xa3
        \\  mov32 r9, 0x91
        \\  and32 r0, r9
        \\  lsh32 r0, 22
        \\  lsh32 r0, r8
        \\  rsh32 r0, 19
        \\  rsh32 r0, r7
        \\  xor32 r0, 0x03
        \\  xor32 r0, r2
        \\  return
    , 0x11);
}

test "alu32 arithmetic" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov32 r0, 0
        \\  mov32 r1, 1
        \\  mov32 r2, 2
        \\  mov32 r3, 3
        \\  mov32 r4, 4
        \\  mov32 r5, 5
        \\  mov32 r6, 6
        \\  mov32 r7, 7
        \\  mov32 r8, 8
        \\  mov32 r9, 9
        \\  sub32 r0, 13
        \\  sub32 r0, r1
        \\  add32 r0, 23
        \\  add32 r0, r7
        \\  lmul32 r0, 7
        \\  lmul32 r0, r3
        \\  udiv32 r0, 2
        \\  udiv32 r0, r4
        \\  return
    , 110);
}

test "alu64 logic" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov r0, 0
        \\  mov r1, 1
        \\  mov r2, 2
        \\  mov r3, 3
        \\  mov r4, 4
        \\  mov r5, 5
        \\  mov r6, 6
        \\  mov r7, 7
        \\  mov r8, 8
        \\  or r0, r5
        \\  or r0, 0xa0
        \\  and r0, 0xa3
        \\  mov r9, 0x91
        \\  and r0, r9
        \\  lsh r0, 32
        \\  lsh r0, 22
        \\  lsh r0, r8
        \\  rsh r0, 32
        \\  rsh r0, 19
        \\  rsh r0, r7
        \\  xor r0, 0x03
        \\  xor r0, r2
        \\  return
    , 0x11);
}

test "mul32 imm" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  mov r0, 3
        \\  mul32 r0, 4
        \\  exit
    , 12);
}

test "mul32 reg" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  mov r0, 3
        \\  mov r1, 4
        \\  mul32 r0, r1
        \\  exit
    , 12);
}

test "mul32 overflow" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  mov r0, 0x40000001
        \\  mov r1, 4
        \\  mul32 r0, r1
        \\  exit
    , 4);
}

test "mul64 imm" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  mov r0, 0x40000001
        \\  mul r0, 4
        \\  exit
    , 0x100000004);
}

test "mul64 reg" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  mov r0, 0x40000001
        \\  mov r1, 4
        \\  mul r0, r1
        \\  exit
    , 0x100000004);
}

test "mul32 negative" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  mov r0, -1
        \\  mul32 r0, 4
        \\  exit
    , 0xFFFFFFFFFFFFFFFC);
}

test "div32 imm" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  lddw r0, 0x10000000c
        \\  div32 r0, 4
        \\  exit
    , 0x3);
}

test "div32 reg" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  mov r0, 12
        \\  lddw r1, 0x100000004
        \\  div32 r0, r1
        \\  exit
    , 0x3);
}

test "div32 small" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  lddw r0, 0x10000000c
        \\  mov r1, 4
        \\  div32 r0, r1
        \\  exit
    , 0x3);
}

test "div64 imm" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  mov r0, 0xc
        \\  lsh r0, 32
        \\  div r0, 4
        \\  exit
    , 0x300000000);
}

test "div64 reg" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  mov r0, 0xc
        \\  lsh r0, 32
        \\  mov r1, 4
        \\  div r0, r1
        \\  exit
    , 0x300000000);
}

test "div division by zero" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  mov32 r0, 1
        \\  mov32 r1, 0
        \\  div r0, r1
        \\  exit
    , error.DivisionByZero);
}

test "div32 division by zero" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  mov32 r0, 1
        \\  mov32 r1, 0
        \\  div32 r0, r1
        \\  exit
    , error.DivisionByZero);
}

test "neg32" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  mov32 r0, 2
        \\  neg32 r0
        \\  exit
    , 0xFFFFFFFE);
}

test "neg64" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  mov r0, 2
        \\  neg r0
        \\  exit
    , 0xFFFFFFFFFFFFFFFE);
}

test "neg invalid on v3" {
    try expectEqual(
        error.UnknownInstruction,
        testAsm(.{},
            \\entrypoint:
            \\  neg32 r0
            \\  return
        , 0),
    );

    try expectEqual(
        error.UnknownInstruction,
        testAsm(.{},
            \\entrypoint:
            \\  neg64 r0
            \\  return
        , 0),
    );

    try expectEqual(
        error.UnknownInstruction,
        testAsm(.{},
            \\entrypoint:
            \\  neg r0
            \\  return
        , 0),
    );
}

test "sub32 imm" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov32 r0, 3
        \\  sub32 r0, 1
        \\  return
    , 0xFFFFFFFFFFFFFFFE);
}

test "sub32 reg" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov32 r0, 4
        \\  mov32 r1, 2
        \\  sub32 r0, r1
        \\  return
    , 2);
}

test "sub64 imm" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov r0, 3
        \\  sub r0, 1
        \\  return
    , 0xFFFFFFFFFFFFFFFE);
}

test "sub64 imm negative" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov r0, 3
        \\  sub r0, -1
        \\  return
    , 0xFFFFFFFFFFFFFFFC);
}

test "sub64 reg" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov r0, 4
        \\  mov r1, 2
        \\  sub r0, r1
        \\  return
    , 2);
}

test "mod32" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  mov32 r0, 5748
        \\  mod32 r0, 92
        \\  mov32 r1, 13
        \\  mod32 r0, r1
        \\  exit
    , 0x5);
}

test "mod32 overflow" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  lddw r0, 0x100000003
        \\  mod32 r0, 3
        \\  exit
    , 0x0);
}

test "mod32 all" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  mov32 r0, -1316649930
        \\  lsh r0, 32
        \\  or r0, 0x100dc5c8
        \\  mov32 r1, 0xdde263e
        \\  lsh r1, 32
        \\  or r1, 0x3cbef7f3
        \\  mod r0, r1
        \\  mod r0, 0x658f1778
        \\  exit
    , 0x30ba5a04);
}

test "mod64 divide by zero" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  mov32 r0, 1
        \\  mov32 r1, 0
        \\  mod r0, r1
        \\  exit
    , error.DivisionByZero);
}

test "mod32 divide by zero" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  mov32 r0, 1
        \\  mov32 r1, 0
        \\  mod32 r0, r1
        \\  exit
    , error.DivisionByZero);
}

test "arsh32 high shift" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov r0, 8
        \\  mov32 r1, 0x00000001
        \\  hor64 r1, 0x00000001
        \\  arsh32 r0, r1
        \\  return
    , 0x4);
}

test "arsh32 imm" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov32 r0, 0xf8
        \\  lsh32 r0, 28
        \\  arsh32 r0, 16
        \\  return
    , 0xffff8000);
}

test "arsh32 reg" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov32 r0, 0xf8
        \\  mov32 r1, 16
        \\  lsh32 r0, 28
        \\  arsh32 r0, r1
        \\  return
    , 0xffff8000);
}

test "arsh64" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov32 r0, 1
        \\  lsh r0, 63
        \\  arsh r0, 55
        \\  mov32 r1, 5
        \\  arsh r0, r1
        \\  return
    , 0xfffffffffffffff8);
}

test "hor64" {
    try testAsm(.{},
        \\entrypoint:
        \\  hor64 r0, 0x10203040
        \\  hor64 r0, 0x01020304
        \\  return
    , 0x1122334400000000);
}

test "lddw" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  lddw r0, 0x1122334455667788
        \\  exit
    , 0x1122334455667788);
}

test "lddw bottom" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  lddw r0, 0x0000000080000000
        \\  exit
    , 0x80000000);
}

test "lddw logic" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  mov r0, 0
        \\  mov r1, 0
        \\  mov r2, 0
        \\  lddw r0, 0x1
        \\  ja +2
        \\  lddw r1, 0x1
        \\  lddw r2, 0x1
        \\  add r1, r2
        \\  add r0, r1
        \\  exit
    , 0x2);
}

test "lddw invalid on v3" {
    try expectEqual(
        error.UnknownInstruction,
        testAsm(.{},
            \\entrypoint:
            \\  lddw r0, 0x1122334455667788
            \\  return
        , 0),
    );
}

test "le16" {
    try testAsmWithMemory(
        .{ .maximum_version = .v0 },
        \\  ldxh r0, [r1]
        \\  le16 r0
        \\  exit
    ,
        &.{ 0x22, 0x11 },
        0x1122,
    );
}

test "le16 high" {
    try testAsmWithMemory(
        .{ .maximum_version = .v0 },
        \\  ldxdw r0, [r1]
        \\  le16 r0
        \\  exit
    ,
        &.{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 },
        0x2211,
    );
}

test "le32" {
    try testAsmWithMemory(
        .{ .maximum_version = .v0 },
        \\  ldxw r0, [r1]
        \\  le32 r0
        \\  exit
    ,
        &.{ 0x44, 0x33, 0x22, 0x11 },
        0x11223344,
    );
}

test "le32 high" {
    try testAsmWithMemory(
        .{ .maximum_version = .v0 },
        \\  ldxdw r0, [r1]
        \\  le32 r0
        \\  exit
    ,
        &.{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 },
        0x44332211,
    );
}

test "le64" {
    try testAsmWithMemory(
        .{ .maximum_version = .v0 },
        \\  ldxdw r0, [r1]
        \\  le64 r0
        \\  exit
    ,
        &.{ 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11 },
        0x1122334455667788,
    );
}

test "le invalid on v3" {
    try expectEqual(
        error.UnknownInstruction,
        testAsm(.{},
            \\  le16 r0
            \\  return
        , 0),
    );
    try expectEqual(
        error.UnknownInstruction,
        testAsm(.{},
            \\  le32 r0
            \\  return
        , 0),
    );

    try expectEqual(
        error.UnknownInstruction,
        testAsm(.{},
            \\  le64 r0
            \\  return
        , 0),
    );
}

test "be16" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  ldxh r0, [r1]
        \\  be16 r0
        \\  return
    ,
        &.{ 0x11, 0x22 },
        0x1122,
    );
}

test "be16 high" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  ldxdw r0, [r1]
        \\  be16 r0
        \\  return
    ,
        &.{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 },
        0x1122,
    );
}

test "be32" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  ldxw r0, [r1]
        \\  be32 r0
        \\  return
    ,
        &.{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 },
        0x11223344,
    );
}

test "be32 high" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  ldxdw r0, [r1]
        \\  be32 r0
        \\  return
    ,
        &.{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 },
        0x11223344,
    );
}

test "be64" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  ldxdw r0, [r1]
        \\  be64 r0
        \\  return
    ,
        &.{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 },
        0x1122334455667788,
    );
}

test "lsh64 reg" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov r0, 0x1
        \\  mov r7, 4
        \\  lsh r0, r7
        \\  return
    , 0x10);
}

test "rhs32 imm" {
    try testAsm(.{},
        \\entrypoint:
        \\  xor r0, r0
        \\  add r0, -1
        \\  rsh32 r0, 8
        \\  return
    , 0x00ffffff);
}

test "rhs64 reg" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov r0, 0x10
        \\  mov r7, 4
        \\  rsh r0, r7
        \\  return
    , 0x1);
}

test "ldxb" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  ldxb r0, [r1+2]
        \\  return
    ,
        &.{ 0xaa, 0xbb, 0x11, 0xcc, 0xdd },
        0x11,
    );
}

test "ldxh" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  ldxh r0, [r1+2]
        \\  return
    ,
        &.{ 0xaa, 0xbb, 0x11, 0x22, 0xcc, 0xdd },
        0x2211,
    );
}

test "ldxw" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  ldxw r0, [r1+2]
        \\  return
    ,
        &.{ 0xaa, 0xbb, 0x11, 0x22, 0x33, 0x44, 0xcc, 0xdd },
        0x44332211,
    );
}

test "ldxw same reg" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  mov r0, r1
        \\  sth [r0], 0x1234
        \\  ldxh r0, [r0]
        \\  return
    ,
        &.{ 0xff, 0xff },
        0x1234,
    );
}

test "ldxdw" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  ldxdw r0, [r1+2]
        \\  return
    ,
        &.{
            0xaa, 0xbb, 0x11, 0x22, 0x33, 0x44,
            0x55, 0x66, 0x77, 0x88, 0xcc, 0xdd,
        },
        0x8877665544332211,
    );
}

test "ldxdw oob" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  ldxdw r0, [r1+6]
        \\  return
    ,
        &.{
            0xaa, 0xbb, 0x11, 0x22, 0x33, 0x44,
            0x55, 0x66, 0x77, 0x88, 0xcc, 0xdd,
        },
        error.VirtualAccessTooLong,
    );
}

test "ldxdw oom" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  ldxdw r0, [r1+6]
        \\  return
    ,
        &.{},
        error.AccessNotMapped,
    );
}

test "ldxb all" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  mov r0, r1
        \\  ldxb r9, [r0+0]
        \\  lsh r9, 0
        \\  ldxb r8, [r0+1]
        \\  lsh r8, 4
        \\  ldxb r7, [r0+2]
        \\  lsh r7, 8
        \\  ldxb r6, [r0+3]
        \\  lsh r6, 12
        \\  ldxb r5, [r0+4]
        \\  lsh r5, 16
        \\  ldxb r4, [r0+5]
        \\  lsh r4, 20
        \\  ldxb r3, [r0+6]
        \\  lsh r3, 24
        \\  ldxb r2, [r0+7]
        \\  lsh r2, 28
        \\  ldxb r1, [r0+8]
        \\  lsh r1, 32
        \\  ldxb r0, [r0+9]
        \\  lsh r0, 36
        \\  or r0, r1
        \\  or r0, r2
        \\  or r0, r3
        \\  or r0, r4
        \\  or r0, r5
        \\  or r0, r6
        \\  or r0, r7
        \\  or r0, r8
        \\  or r0, r9
        \\  return
    ,
        &.{
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
            0x07, 0x08, 0x09,
        },
        0x9876543210,
    );
}

test "ldxh all" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  mov r0, r1
        \\  ldxh r9, [r0+0]
        \\  be16 r9
        \\  lsh r9, 0
        \\  ldxh r8, [r0+2]
        \\  be16 r8
        \\  lsh r8, 4
        \\  ldxh r7, [r0+4]
        \\  be16 r7
        \\  lsh r7, 8
        \\  ldxh r6, [r0+6]
        \\  be16 r6
        \\  lsh r6, 12
        \\  ldxh r5, [r0+8]
        \\  be16 r5
        \\  lsh r5, 16
        \\  ldxh r4, [r0+10]
        \\  be16 r4
        \\  lsh r4, 20
        \\  ldxh r3, [r0+12]
        \\  be16 r3
        \\  lsh r3, 24
        \\  ldxh r2, [r0+14]
        \\  be16 r2
        \\  lsh r2, 28
        \\  ldxh r1, [r0+16]
        \\  be16 r1
        \\  lsh r1, 32
        \\  ldxh r0, [r0+18]
        \\  be16 r0
        \\  lsh r0, 36
        \\  or r0, r1
        \\  or r0, r2
        \\  or r0, r3
        \\  or r0, r4
        \\  or r0, r5
        \\  or r0, r6
        \\  or r0, r7
        \\  or r0, r8
        \\  or r0, r9
        \\  return
    ,
        &.{
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x02, 0x00, 0x03,
            0x00, 0x04, 0x00, 0x05,
            0x00, 0x06, 0x00, 0x07,
            0x00, 0x08, 0x00, 0x09,
        },
        0x9876543210,
    );

    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  mov r0, r1
        \\  ldxh r9, [r0+0]
        \\  be16 r9
        \\  ldxh r8, [r0+2]
        \\  be16 r8
        \\  ldxh r7, [r0+4]
        \\  be16 r7
        \\  ldxh r6, [r0+6]
        \\  be16 r6
        \\  ldxh r5, [r0+8]
        \\  be16 r5
        \\  ldxh r4, [r0+10]
        \\  be16 r4
        \\  ldxh r3, [r0+12]
        \\  be16 r3
        \\  ldxh r2, [r0+14]
        \\  be16 r2
        \\  ldxh r1, [r0+16]
        \\  be16 r1
        \\  ldxh r0, [r0+18]
        \\  be16 r0
        \\  or r0, r1
        \\  or r0, r2
        \\  or r0, r3
        \\  or r0, r4
        \\  or r0, r5
        \\  or r0, r6
        \\  or r0, r7
        \\  or r0, r8
        \\  or r0, r9
        \\  return
    ,
        &.{
            0x00, 0x01, 0x00, 0x02, 0x00, 0x04, 0x00, 0x08,
            0x00, 0x10, 0x00, 0x20, 0x00, 0x40, 0x00, 0x80,
            0x01, 0x00, 0x02, 0x00,
        },
        0x3FF,
    );
}

test "ldxw all" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  mov r0, r1
        \\  ldxw r9, [r0+0]
        \\  be32 r9
        \\  ldxw r8, [r0+4]
        \\  be32 r8
        \\  ldxw r7, [r0+8]
        \\  be32 r7
        \\  ldxw r6, [r0+12]
        \\  be32 r6
        \\  ldxw r5, [r0+16]
        \\  be32 r5
        \\  ldxw r4, [r0+20]
        \\  be32 r4
        \\  ldxw r3, [r0+24]
        \\  be32 r3
        \\  ldxw r2, [r0+28]
        \\  be32 r2
        \\  ldxw r1, [r0+32]
        \\  be32 r1
        \\  ldxw r0, [r0+36]
        \\  be32 r0
        \\  or r0, r1
        \\  or r0, r2
        \\  or r0, r3
        \\  or r0, r4
        \\  or r0, r5
        \\  or r0, r6
        \\  or r0, r7
        \\  or r0, r8
        \\  or r0, r9
        \\  return
    ,
        &.{
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02,
            0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x08,
            0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00,
            0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x08, 0x00,
            0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00,
        },
        0x030F0F,
    );
}

test "stb" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  stb [r1+2], 0x11
        \\  ldxb r0, [r1+2]
        \\  return
    ,
        &.{ 0xaa, 0xbb, 0xff, 0xcc, 0xdd },
        0x11,
    );
}

test "sth" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\ sth [r1+2], 0x2211
        \\ ldxh r0, [r1+2]
        \\ return
    ,
        &.{
            0xaa, 0xbb, 0xff, 0xff,
            0xff, 0xff, 0xcc, 0xdd,
        },
        0x2211,
    );
}

test "stw" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  stw [r1+2], 0x44332211
        \\  ldxw r0, [r1+2]
        \\  return
    ,
        &.{
            0xaa, 0xbb, 0xff, 0xff,
            0xff, 0xff, 0xcc, 0xdd,
        },
        0x44332211,
    );
}

test "stdw" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  stdw [r1+2], 0x44332211
        \\  ldxdw r0, [r1+2]
        \\  return
    ,
        &.{
            0xaa, 0xbb, 0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff, 0xcc, 0xdd,
        },
        0x44332211,
    );
}

test "stxb" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  mov32 r2, 0x11
        \\  stxb [r1+2], r2
        \\  ldxb r0, [r1+2]
        \\  return
    ,
        &.{ 0xaa, 0xbb, 0xff, 0xcc, 0xdd },
        0x11,
    );
}

test "stxh" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  mov32 r2, 0x2211
        \\  stxh [r1+2], r2
        \\  ldxh r0, [r1+2]
        \\  return
    ,
        &.{ 0xaa, 0xbb, 0xff, 0xff, 0xcc, 0xdd },
        0x2211,
    );
}

test "stxw" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  mov32 r2, 0x44332211
        \\  stxw [r1+2], r2
        \\  ldxw r0, [r1+2]
        \\  return
    ,
        &.{ 0xaa, 0xbb, 0xff, 0xff, 0xff, 0xff, 0xcc, 0xdd },
        0x44332211,
    );
}

test "stxdw" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  mov r2, -2005440939
        \\  lsh r2, 32
        \\  or r2, 0x44332211
        \\  stxdw [r1+2], r2
        \\  ldxdw r0, [r1+2]
        \\  return
    ,
        &.{
            0xaa, 0xbb, 0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff, 0xcc, 0xdd,
        },
        0x8877665544332211,
    );
}

test "stxb all" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  mov r0, 0xf0
        \\  mov r2, 0xf2
        \\  mov r3, 0xf3
        \\  mov r4, 0xf4
        \\  mov r5, 0xf5
        \\  mov r6, 0xf6
        \\  mov r7, 0xf7
        \\  mov r8, 0xf8
        \\  stxb [r1], r0
        \\  stxb [r1+1], r2
        \\  stxb [r1+2], r3
        \\  stxb [r1+3], r4
        \\  stxb [r1+4], r5
        \\  stxb [r1+5], r6
        \\  stxb [r1+6], r7
        \\  stxb [r1+7], r8
        \\  ldxdw r0, [r1]
        \\  be64 r0
        \\  return
    ,
        &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
        0xf0f2f3f4f5f6f7f8,
    );

    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  mov r0, r1
        \\  mov r1, 0xf1
        \\  mov r9, 0xf9
        \\  stxb [r0], r1
        \\  stxb [r0+1], r9
        \\  ldxh r0, [r0]
        \\  be16 r0
        \\  return
    ,
        &.{ 0xff, 0xff },
        0xf1f9,
    );
}

test "stxb chain" {
    try testAsmWithMemory(
        .{},
        \\entrypoint:
        \\  mov r0, r1
        \\  ldxb r9, [r0+0]
        \\  stxb [r0+1], r9
        \\  ldxb r8, [r0+1]
        \\  stxb [r0+2], r8
        \\  ldxb r7, [r0+2]
        \\  stxb [r0+3], r7
        \\  ldxb r6, [r0+3]
        \\  stxb [r0+4], r6
        \\  ldxb r5, [r0+4]
        \\  stxb [r0+5], r5
        \\  ldxb r4, [r0+5]
        \\  stxb [r0+6], r4
        \\  ldxb r3, [r0+6]
        \\  stxb [r0+7], r3
        \\  ldxb r2, [r0+7]
        \\  stxb [r0+8], r2
        \\  ldxb r1, [r0+8]
        \\  stxb [r0+9], r1
        \\  ldxb r0, [r0+9]
        \\  return
    ,
        &.{
            0x2a, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00,
        },
        0x2a,
    );
}

test "return without value" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  return
    ,
        0x0,
    );
}

test "return" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov r0, 0
        \\  return
    , 0x0);
}

test "early return" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov r0, 3
        \\  return
        \\  mov r0, 4
        \\  return
    , 3);
}

test "ja" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov r0, 1
        \\  ja +1
        \\  mov r0, 2
        \\  return
    ,
        0x1,
    );
}

test "jeq imm" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov32 r0, 0
        \\  mov32 r1, 0xa
        \\  jeq r1, 0xb, +4
        \\  mov32 r0, 1
        \\  mov32 r1, 0xb
        \\  jeq r1, 0xb, +1
        \\  mov32 r0, 2
        \\  return
    ,
        0x1,
    );
}

test "jeq reg" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov32 r0, 0
        \\  mov32 r1, 0xa
        \\  mov32 r2, 0xb
        \\  jeq r1, r2, +4
        \\  mov32 r0, 1
        \\  mov32 r1, 0xb
        \\  jeq r1, r2, +1
        \\  mov32 r0, 2
        \\  return
    ,
        0x1,
    );
}

test "jge imm" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov32 r0, 0
        \\  mov32 r1, 0xa
        \\  jge r1, 0xb, +4
        \\  mov32 r0, 1
        \\  mov32 r1, 0xc
        \\  jge r1, 0xb, +1
        \\  mov32 r0, 2
        \\  return
    ,
        0x1,
    );
}

test "jge reg" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov32 r0, 0
        \\  mov32 r1, 0xa
        \\  mov32 r2, 0xb
        \\  jge r1, r2, +4
        \\  mov32 r0, 1
        \\  mov32 r1, 0xb
        \\  jge r1, r2, +1
        \\  mov32 r0, 2
        \\  return
    ,
        0x1,
    );
}

test "jle imm" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov32 r0, 0
        \\  mov32 r1, 5
        \\  jle r1, 4, +1
        \\  jle r1, 6, +1
        \\  return
        \\  jle r1, 5, +1
        \\  return
        \\  mov32 r0, 1
        \\  return
    ,
        0x1,
    );
}

test "jle reg" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov r0, 0
        \\  mov r1, 5
        \\  mov r2, 4
        \\  mov r3, 6
        \\  jle r1, r2, +2
        \\  jle r1, r1, +1
        \\  return
        \\  jle r1, r3, +1
        \\  return
        \\  mov r0, 1
        \\  return
    ,
        0x1,
    );
}

test "jgt imm" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov32 r0, 0
        \\  mov32 r1, 5
        \\  jgt r1, 6, +2
        \\  jgt r1, 5, +1
        \\  jgt r1, 4, +1
        \\  return
        \\  mov32 r0, 1
        \\  return
    ,
        0x1,
    );
}

test "jgt reg" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov r0, 0
        \\  mov r1, 5
        \\  mov r2, 6
        \\  mov r3, 4
        \\  jgt r1, r2, +2
        \\  jgt r1, r1, +1
        \\  jgt r1, r3, +1
        \\  return
        \\  mov r0, 1
        \\  return
    ,
        0x1,
    );
}

test "jlt imm" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov32 r0, 0
        \\  mov32 r1, 5
        \\  jlt r1, 4, +2
        \\  jlt r1, 5, +1
        \\  jlt r1, 6, +1
        \\  return
        \\  mov32 r0, 1
        \\  return
    ,
        0x1,
    );
}

test "jlt reg" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov r0, 0
        \\  mov r1, 5
        \\  mov r2, 4
        \\  mov r3, 6
        \\  jlt r1, r2, +2
        \\  jlt r1, r1, +1
        \\  jlt r1, r3, +1
        \\  return
        \\  mov r0, 1
        \\  return
    ,
        0x1,
    );
}

test "jlt extend" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov r0, 0
        \\  add r0, -3  
        \\  jlt r0, -2, +2 
        \\  mov r0, 1             
        \\  return                 
        \\  mov r0, 2           
        \\  return    
    ,
        2,
    );
}

test "jne imm" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov32 r0, 0
        \\  mov32 r1, 0xb
        \\  jne r1, 0xb, +4
        \\  mov32 r0, 1
        \\  mov32 r1, 0xa
        \\  jne r1, 0xb, +1
        \\  mov32 r0, 2
        \\  return
    ,
        0x1,
    );
}

test "jne reg" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov32 r0, 0
        \\  mov32 r1, 0xb
        \\  mov32 r2, 0xb
        \\  jne r1, r2, +4
        \\  mov32 r0, 1
        \\  mov32 r1, 0xa
        \\  jne r1, r2, +1
        \\  mov32 r0, 2
        \\  return
    ,
        0x1,
    );
}

test "jset imm" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov32 r0, 0
        \\  mov32 r1, 0x7
        \\  jset r1, 0x8, +4
        \\  mov32 r0, 1
        \\  mov32 r1, 0x9
        \\  jset r1, 0x8, +1
        \\  mov32 r0, 2
        \\  return
    ,
        0x1,
    );
}

test "jset reg" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov32 r0, 0
        \\  mov32 r1, 0x7
        \\  mov32 r2, 0x8
        \\  jset r1, r2, +4
        \\  mov32 r0, 1
        \\  mov32 r1, 0x9
        \\  jset r1, r2, +1
        \\  mov32 r0, 2
        \\  return
    ,
        0x1,
    );
}

test "jsge imm" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov32 r0, 0
        \\  mov r1, -2
        \\  jsge r1, -1, +5
        \\  jsge r1, 0, +4
        \\  mov32 r0, 1
        \\  mov r1, -1
        \\  jsge r1, -1, +1
        \\  mov32 r0, 2
        \\  return
    ,
        0x1,
    );
}

test "jsge reg" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov32 r0, 0
        \\  mov r1, -2
        \\  mov r2, -1
        \\  mov32 r3, 0
        \\  jsge r1, r2, +5
        \\  jsge r1, r3, +4
        \\  mov32 r0, 1
        \\  mov  r1, r2
        \\  jsge r1, r2, +1
        \\  mov32 r0, 2
        \\ return
    ,
        0x1,
    );
}

test "jsle imm" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov32 r0, 0
        \\  mov r1, -2
        \\  jsle r1, -3, +1
        \\  jsle r1, -1, +1
        \\  return
        \\  mov32 r0, 1
        \\  jsle r1, -2, +1
        \\  mov32 r0, 2
        \\  return
    ,
        0x1,
    );
}

test "jsle reg" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov32 r0, 0
        \\  mov r1, -1
        \\  mov r2, -2
        \\  mov32 r3, 0
        \\  jsle r1, r2, +1
        \\  jsle r1, r3, +1
        \\  return
        \\  mov32 r0, 1
        \\  mov r1, r2
        \\  jsle r1, r2, +1
        \\  mov32 r0, 2
        \\  return
    ,
        0x1,
    );
}

test "jsgt imm" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov32 r0, 0
        \\  mov r1, -2
        \\  jsgt r1, -1, +4
        \\  mov32 r0, 1
        \\  mov32 r1, 0
        \\  jsgt r1, -1, +1
        \\  mov32 r0, 2
        \\  return
    ,
        0x1,
    );
}

test "jsgt reg" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov32 r0, 0
        \\  mov r1, -2
        \\  mov r2, -1
        \\  jsgt r1, r2, +4
        \\  mov32 r0, 1
        \\  mov32 r1, 0
        \\  jsgt r1, r2, +1
        \\  mov32 r0, 2
        \\  return
    ,
        0x1,
    );
}

test "jslt imm" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov32 r0, 0
        \\  mov r1, -2
        \\  jslt r1, -3, +2
        \\  jslt r1, -2, +1
        \\  jslt r1, -1, +1
        \\  return
        \\  mov32 r0, 1
        \\  return
    ,
        0x1,
    );
}

test "jslt reg" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov32 r0, 0
        \\  mov r1, -2
        \\  mov r2, -3
        \\  mov r3, -1
        \\  jslt r1, r1, +2
        \\  jslt r1, r2, +1
        \\  jslt r1, r3, +1
        \\  return
        \\  mov32 r0, 1
        \\  return
    ,
        0x1,
    );
}

test "lmul loop" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov r0, 0x7
        \\  add r1, 0xa
        \\  lsh r1, 0x20
        \\  rsh r1, 0x20
        \\  jeq r1, 0x0, +4
        \\  mov r0, 0x7
        \\  lmul r0, 0x7
        \\  add r1, -1
        \\  jne r1, 0x0, -3
        \\  return
    ,
        0x75db9c97,
    );
}

test "lmul128" {
    try testAsmWithMemory(.{},
        \\entrypoint:
        \\  mov r0, r1
        \\  mov r2, 30
        \\  mov r3, 0
        \\  mov r4, 20
        \\  mov r5, 0
        \\  lmul64 r3, r4
        \\  lmul64 r5, r2
        \\  add64 r5, r3
        \\  mov64 r0, r2
        \\  rsh64 r0, 0x20
        \\  mov64 r3, r4
        \\  rsh64 r3, 0x20
        \\  mov64 r6, r3
        \\  lmul64 r6, r0
        \\  add64 r5, r6
        \\  lsh64 r4, 0x20
        \\  rsh64 r4, 0x20
        \\  mov64 r6, r4
        \\  lmul64 r6, r0
        \\  lsh64 r2, 0x20
        \\  rsh64 r2, 0x20
        \\  lmul64 r4, r2
        \\  mov64 r0, r4
        \\  rsh64 r0, 0x20
        \\  add64 r0, r6
        \\  mov64 r6, r0
        \\  rsh64 r6, 0x20
        \\  add64 r5, r6
        \\  lmul64 r3, r2
        \\  lsh64 r0, 0x20
        \\  rsh64 r0, 0x20
        \\  add64 r0, r3
        \\  mov64 r2, r0
        \\  rsh64 r2, 0x20
        \\  add64 r5, r2
        \\  stxdw [r1+0x8], r5
        \\  lsh64 r0, 0x20
        \\  lsh64 r4, 0x20
        \\  rsh64 r4, 0x20
        \\  or64 r0, r4
        \\  stxdw [r1+0x0], r0
        \\  return
    , &(.{0} ** 16), 600);
}

test "prime" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov r1, 67
        \\  mov r0, 0x1
        \\  mov r2, 0x2
        \\  jgt r1, 0x2, +4
        \\  ja +10
        \\  add r2, 0x1
        \\  mov r0, 0x1
        \\  jge r2, r1, +7
        \\  mov r3, r1
        \\  udiv r3, r2
        \\  lmul r3, r2
        \\  mov r4, r1
        \\  sub r4, r3
        \\  mov r0, 0x0
        \\  jne r4, 0x0, -10
        \\  return
    , 1);
}

test "subnet" {
    try testAsmWithMemory(.{},
        \\entrypoint:
        \\  mov r2, 0xe
        \\  ldxh r3, [r1+12]
        \\  jne r3, 0x81, +2
        \\  mov r2, 0x12
        \\  ldxh r3, [r1+16]
        \\  and r3, 0xffff
        \\  jne r3, 0x8, +5
        \\  add r1, r2
        \\  mov r0, 0x1
        \\  ldxw r1, [r1+16]
        \\  and r1, 0xffffff
        \\  jeq r1, 0x1a8c0, +1
        \\  mov r0, 0x0
        \\  return
    , &.{
        0x00, 0x00, 0xc0, 0x9f, 0xa0, 0x97, 0x00, 0xa0, 0xcc, 0x3b,
        0xbf, 0xfa, 0x08, 0x00, 0x45, 0x10, 0x00, 0x3c, 0x46, 0x3c,
        0x40, 0x00, 0x40, 0x06, 0x73, 0x1c, 0xc0, 0xa8, 0x01, 0x02,
        0xc0, 0xa8, 0x01, 0x01, 0x06, 0x0e, 0x00, 0x17, 0x99, 0xc5,
        0xa0, 0xec, 0x00, 0x00, 0x00, 0x00, 0xa0, 0x02, 0x7d, 0x78,
        0xe0, 0xa3, 0x00, 0x00, 0x02, 0x04, 0x05, 0xb4, 0x04, 0x02,
        0x08, 0x0a, 0x00, 0x9c, 0x27, 0x24, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x03, 0x03, 0x00,
    }, 0x1);
}

test "pqr" {
    const allocator = std.testing.allocator;
    var program: [48]u8 = .{0} ** 48;
    // mov64 r0, X
    program[0] = @intFromEnum(OpCode.mov64_imm);
    // hor64 r0, X
    program[8] = @intFromEnum(OpCode.hor64_imm);

    // mov64 r1, X
    program[16] = @intFromEnum(OpCode.mov64_imm);
    program[17] = 1; // dst = r1
    // hor64 r1, X
    program[24] = @intFromEnum(OpCode.hor64_imm);
    program[25] = 1; // dst = r1

    // set the instruction we're testing to use r1 as the src
    program[33] = 16; // src = r1
    program[40] = @intFromEnum(OpCode.exit);

    const max_int = std.math.maxInt(u64);
    inline for (
        // zig fmt: off
        [_]struct { OpCode, u64, u64, u64 }{
            .{ OpCode.udiv32_reg,  13, 4, 3 },
            .{ OpCode.uhmul64_reg, 13, 4, 0 },
            .{ OpCode.udiv32_reg,  13, 4, 3 },
            .{ OpCode.udiv64_reg,  13, 4, 3 },
            .{ OpCode.urem32_reg,  13, 4, 1 },
            .{ OpCode.urem64_reg,  13, 4, 1 },

            .{ OpCode.uhmul64_reg, 13, max_int, 12 },
            .{ OpCode.udiv32_reg,  13, max_int, 0 },
            .{ OpCode.udiv64_reg,  13, max_int, 0 },
            .{ OpCode.urem32_reg,  13, max_int, 13 },
            .{ OpCode.urem64_reg,  13, max_int, 13 },

            .{ OpCode.uhmul64_reg, max_int, 4, 3 },
            .{ OpCode.udiv32_reg,  max_int, 4, std.math.maxInt(u32) / 4 },
            .{ OpCode.udiv64_reg,  max_int, 4, max_int / 4 },
            .{ OpCode.urem32_reg,  max_int, 4, 3 },
            .{ OpCode.urem64_reg,  max_int, 4, 3 },

            .{ OpCode.uhmul64_reg, max_int, max_int, max_int - 1 },
            .{ OpCode.udiv32_reg,  max_int, max_int, 1 },
            .{ OpCode.udiv64_reg,  max_int, max_int, 1 },
            .{ OpCode.urem32_reg,  max_int, max_int, 0 },
            .{ OpCode.urem64_reg,  max_int, max_int, 0 },

            .{ OpCode.lmul32_reg,  13, 4, 52 },
            .{ OpCode.lmul64_reg,  13, 4, 52 },
            .{ OpCode.shmul64_reg, 13, 4, 0 },
            .{ OpCode.sdiv32_reg,  13, 4, 3 },
            .{ OpCode.sdiv64_reg,  13, 4, 3 },
            .{ OpCode.srem32_reg,  13, 4, 1 },
            .{ OpCode.srem64_reg,  13, 4, 1 },

            .{ OpCode.lmul32_reg,  13, ~@as(u64, 3), ~@as(u64, 51) },
            .{ OpCode.lmul64_reg,  13, ~@as(u64, 3), ~@as(u64, 51) },
            .{ OpCode.shmul64_reg, 13, ~@as(u64, 3), ~@as(u64, 0) },
            .{ OpCode.sdiv32_reg,  13, ~@as(u64, 3), ~@as(u64, 2) },
            .{ OpCode.sdiv64_reg,  13, ~@as(u64, 3), ~@as(u64, 2) },
            .{ OpCode.srem32_reg,  13, ~@as(u64, 3), 1 },
            .{ OpCode.srem64_reg,  13, ~@as(u64, 3), 1 },

            .{ OpCode.lmul32_reg,  ~@as(u64, 12), 4, ~@as(u64, 51) },
            .{ OpCode.lmul64_reg,  ~@as(u64, 12), 4, ~@as(u64, 51) },
            .{ OpCode.shmul64_reg, ~@as(u64, 12), 4, ~@as(u64, 0) },
            .{ OpCode.sdiv32_reg,  ~@as(u64, 12), 4, ~@as(u64, 2) },
            .{ OpCode.sdiv64_reg,  ~@as(u64, 12), 4, ~@as(u64, 2) },
            .{ OpCode.srem32_reg,  ~@as(u64, 12), 4, ~@as(u64, 0) },
            .{ OpCode.srem64_reg,  ~@as(u64, 12), 4, ~@as(u64, 0) },

            .{ OpCode.lmul32_reg,  ~@as(u64, 12), ~@as(u64, 3), 52 },
            .{ OpCode.lmul64_reg,  ~@as(u64, 12), ~@as(u64, 3), 52 },
            .{ OpCode.shmul64_reg, ~@as(u64, 12), ~@as(u64, 3), 0 },
            .{ OpCode.sdiv32_reg,  ~@as(u64, 12), ~@as(u64, 3), 3 },
            .{ OpCode.sdiv64_reg,  ~@as(u64, 12), ~@as(u64, 3), 3 },
            .{ OpCode.srem32_reg,  ~@as(u64, 12), ~@as(u64, 3), ~@as(u64, 0) },
            .{ OpCode.srem64_reg,  ~@as(u64, 12), ~@as(u64, 3), ~@as(u64, 0) },
        },
        // zig fmt: on
    ) |entry| {
        const opc, const dst, const src, const expected = entry;
        std.mem.writeInt(u32, program[4..][0..4], @truncate(dst), .little);
        std.mem.writeInt(u32, program[12..][0..4], @truncate(dst >> 32), .little);
        std.mem.writeInt(u32, program[20..][0..4], @truncate(src), .little);
        std.mem.writeInt(u32, program[28..][0..4], @truncate(src >> 32), .little);
        std.mem.writeInt(u32, program[36..][0..4], @truncate(src), .little);
        program[32] = @intFromEnum(opc);

        const config: Config = .{ .maximum_version = .v2 };

        var registry: lib.Registry(u64) = .{};
        defer registry.deinit(allocator);

        var loader: BuiltinProgram = .{};
        var executable = try Executable.fromTextBytes(
            allocator,
            &program,
            &loader,
            &registry,
            config,
        );
        const map = try MemoryMap.init(&.{}, .v2);

        var vm = try Vm.init(
            allocator,
            &executable,
            map,
            &loader,
            .noop,
            0,
        );
        defer vm.deinit();

        const unsigned_expected: u64 = expected;
        try expectEqual(unsigned_expected, try vm.run());
    }
}

test "pqr divide by zero" {
    const allocator = std.testing.allocator;
    var program: [24]u8 = .{0} ** 24;
    program[0] = @intFromEnum(OpCode.mov32_imm);
    program[16] = @intFromEnum(OpCode.exit);

    inline for (.{
        OpCode.udiv32_reg,
        OpCode.udiv64_reg,
        OpCode.urem32_reg,
        OpCode.urem64_reg,
        OpCode.sdiv32_reg,
        OpCode.sdiv64_reg,
        OpCode.srem32_reg,
        OpCode.srem64_reg,
    }) |opcode| {
        program[8] = @intFromEnum(opcode);

        const config: Config = .{ .maximum_version = .v2 };

        var registry: lib.Registry(u64) = .{};
        defer registry.deinit(allocator);

        var loader: BuiltinProgram = .{};
        var executable = try Executable.fromTextBytes(
            allocator,
            &program,
            &loader,
            &registry,
            config,
        );

        const map = try MemoryMap.init(&.{}, .v3);
        var vm = try Vm.init(
            allocator,
            &executable,
            map,
            &loader,
            .noop,
            0,
        );
        defer vm.deinit();

        try expectEqual(error.DivisionByZero, vm.run());
    }
}

test "stack1" {
    try testAsm(
        .{},
        \\entrypoint:
        \\  mov r1, 51
        \\  stdw [r10-16], 0xab
        \\  stdw [r10-8], 0xcd
        \\  and r1, 1
        \\  lsh r1, 3
        \\  mov r2, r10
        \\  add r2, r1
        \\  ldxdw r0, [r2-16]
        \\  return
    ,
        0xcd,
    );
}

test "entrypoint return" {
    try testAsm(.{},
        \\entrypoint:
        \\  call function_foo
        \\  mov r0, 42
        \\  return
        \\function_foo:
        \\  mov r0, 12
        \\  return
    , 42);
}

test "call depth in bounds" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov r1, 0
        \\  mov r2, 63
        \\  call function_foo
        \\  mov r0, r1
        \\  return
        \\function_foo:
        \\  add r1, 1
        \\  jeq r1, r2, +1
        \\  call function_foo
        \\  return
    , 63);
}

test "call depth out of bounds" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov r1, 0
        \\  mov r2, 64
        \\  call function_foo
        \\  mov r0, r1
        \\  return
        \\function_foo:
        \\  add r1, 1
        \\  jeq r1, r2, +1
        \\  call function_foo
        \\  return
    , error.CallDepthExceeded);
}

test "callx imm" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  mov64 r0, 0x0
        \\  mov64 r8, 0x1
        \\  lsh64 r8, 0x20
        \\  or64 r8, 0x30
        \\  callx r8
        \\  exit
        \\function_foo:
        \\  mov64 r0, 0x2A
        \\  exit
    , 42);
}

test "callx out of bounds low" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  mov64 r0, 0x3
        \\  callx r0
        \\  exit
    , error.PcOutOfBounds);
}

test "callx out of bounds high" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov64 r0, -0x1
        \\  lsh64 r0, 0x20
        \\  or64 r0, 0x3
        \\  callx r0
        \\  return
    , error.PcOutOfBounds);
}

test "callx out of bounds max" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov64 r0, -0x8
        \\  hor64 r0, -0x1
        \\  callx r0
        \\  return
    , error.PcOutOfBounds);
}

test "call bpf 2 bpf" {
    try testAsm(.{},
        \\entrypoint:
        \\  mov64 r6, 0x11
        \\  mov64 r7, 0x22
        \\  mov64 r8, 0x44
        \\  mov64 r9, 0x88
        \\  call function_foo
        \\  mov64 r0, r6
        \\  add64 r0, r7
        \\  add64 r0, r8
        \\  add64 r0, r9
        \\  return
        \\function_foo:
        \\  mov64 r6, 0x00
        \\  mov64 r7, 0x00
        \\  mov64 r8, 0x00
        \\  mov64 r9, 0x00
        \\  return
    , 255);
}

test "fixed stack out of bounds" {
    try testAsm(.{ .maximum_version = .v0 },
        \\entrypoint:
        \\  stb [r10-0x4000], 0
        \\  exit
    , error.AccessNotMapped);
}

test "dynamic frame pointer" {
    const config: Config = .{};
    try testAsm(config,
        \\entrypoint: 
        \\  add r10, -64
        \\  stxdw [r10+8], r10
        \\  call function_foo
        \\  ldxdw r0, [r10+8]
        \\  return
        \\function_foo:
        \\  return
    , memory.STACK_START + config.stackSize() - 64);

    try testAsm(config,
        \\entrypoint: 
        \\  add r10, -64
        \\  call function_foo
        \\  return
        \\function_foo:
        \\  mov r0, r10
        \\  return
    , memory.STACK_START + config.stackSize() - 64);

    try testAsm(config,
        \\entrypoint: 
        \\  call function_foo
        \\  mov r0, r10
        \\  return
        \\function_foo:
        \\  add r10, -64
        \\  return
    , memory.STACK_START + config.stackSize());
}

fn testElf(config: Config, path: []const u8, expected: anytype) !void {
    return testElfWithSyscalls(config, path, &.{}, expected);
}

pub fn testElfWithSyscalls(
    config: Config,
    path: []const u8,
    extra_syscalls: []const syscalls.Syscall,
    expected: anytype,
) !void {
    const allocator = std.testing.allocator;

    const input_file = try std.fs.cwd().openFile(path, .{});
    const bytes = try input_file.readToEndAlloc(allocator, sbpf.MAX_FILE_SIZE);
    defer allocator.free(bytes);

    var loader: BuiltinProgram = .{};
    defer loader.deinit(allocator);

    for (extra_syscalls) |syscall| {
        _ = try loader.functions.registerHashed(
            allocator,
            syscall.name,
            syscall.builtin_fn,
        );
    }

    var executable = exec: {
        const elf = try Elf.parse(allocator, bytes, &loader, config);
        errdefer elf.deinit(allocator);
        break :exec try Executable.fromElf(elf);
    };
    defer executable.deinit(allocator);

    const stack_memory = try allocator.alloc(u8, config.stackSize());
    defer allocator.free(stack_memory);

    const m = try MemoryMap.init(&.{
        executable.getProgramRegion(),
        Region.init(.mutable, stack_memory, memory.STACK_START),
        Region.init(.constant, &.{}, memory.HEAP_START),
        Region.init(.mutable, &.{}, memory.INPUT_START),
    }, .v0);

    var vm = try Vm.init(
        allocator,
        &executable,
        m,
        &loader,
        .noop,
        stack_memory.len,
    );
    defer vm.deinit();

    const result = vm.run();
    try expectEqual(expected, result);
}

test "BPF_64_64 sbpfv0" {
    // [ 1] .text             PROGBITS        0000000000000120 000120 000018 00  AX  0   0  8
    // prints the address of the first byte in the .text section
    try testElf(
        .{ .maximum_version = .v0 },
        sig.ELF_DATA_DIR ++ "reloc_64_64_sbpfv0.so",
        memory.RODATA_START + 0x120,
    );
}

test "BPF_64_64" {
    // 0000000100000000  0000000100000001 R_SBF_64_64            0000000100000000 entrypoint
    try testElf(
        .{},
        sig.ELF_DATA_DIR ++ "reloc_64_64.so",
        memory.BYTECODE_START,
    );
}

test "BPF_64_RELATIVE data sbpv0" {
    // 4: 0000000000000140     8 OBJECT  LOCAL  DEFAULT     3 reloc_64_relative_data.DATA
    // 0000000000000140  0000000000000008 R_BPF_64_RELATIVE
    try testElf(
        .{ .maximum_version = .v0 },
        sig.ELF_DATA_DIR ++ "reloc_64_relative_data_sbpfv0.so",
        memory.RODATA_START + 0x140,
    );
}

test "BPF_64_RELATIVE data" {
    // 2: 0000000100000008     8 OBJECT  LOCAL  DEFAULT     2 reloc_64_relative_data.DATA
    try testElf(
        .{},
        sig.ELF_DATA_DIR ++ "reloc_64_relative_data.so",
        memory.RODATA_START + 0x8,
    );
}

test "BPF_64_RELATIVE sbpv0" {
    try testElf(
        .{ .maximum_version = .v0 },
        sig.ELF_DATA_DIR ++ "reloc_64_relative_sbpfv0.so",
        memory.RODATA_START + 0x138,
    );
}

test "load elf rodata sbpfv0" {
    try testElf(
        .{ .maximum_version = .v0 },
        sig.ELF_DATA_DIR ++ "rodata_section_sbpfv0.so",
        42,
    );
}

test "load elf rodata" {
    try testElf(
        .{ .optimize_rodata = false },
        sig.ELF_DATA_DIR ++ "rodata_section.so",
        42,
    );
}

test "syscall reloc 64_32" {
    try testElfWithSyscalls(
        .{ .maximum_version = .v0 },
        sig.ELF_DATA_DIR ++ "syscall_reloc_64_32_sbpfv0.so",
        &.{.{ .name = "log", .builtin_fn = syscalls.log }},
        0,
    );
}

test "static syscall" {
    try testElfWithSyscalls(
        .{},
        sig.ELF_DATA_DIR ++ "syscall_static.so",
        &.{.{ .name = "log", .builtin_fn = syscalls.log }},
        0,
    );
}

test "struct func pointer" {
    try testElfWithSyscalls(
        .{},
        sig.ELF_DATA_DIR ++ "struct_func_pointer.so",
        &.{},
        0x0102030405060708,
    );
}

test "struct func pointer sbpfv0" {
    try testElfWithSyscalls(
        .{ .maximum_version = .v0 },
        sig.ELF_DATA_DIR ++ "struct_func_pointer_sbpfv0.so",
        &.{},
        0x0102030405060708,
    );
}

test "data section" {
    // [ 6] .data             PROGBITS        0000000000000250 000250 000004 00  WA  0   0  4
    try expectEqual(
        error.WritableSectionsNotSupported,
        testElfWithSyscalls(
            .{ .maximum_version = .v0 },
            sig.ELF_DATA_DIR ++ "data_section_sbpfv0.so",
            &.{},
            0,
        ),
    );
}

test "bss section" {
    // [ 6] .bss              NOBITS          0000000000000250 000250 000004 00  WA  0   0  4
    try expectEqual(
        error.WritableSectionsNotSupported,
        testElfWithSyscalls(
            .{ .maximum_version = .v0 },
            sig.ELF_DATA_DIR ++ "bss_section_sbpfv0.so",
            &.{},
            0,
        ),
    );
}

test "hash collision" {
    // Mined Murmur3_32 hashes until I found one that collided with
    // `hashSymbolName(&std.mem.toBytes(@as(u64, 0)))`
    const colliding_name: []const u8 = &.{
        0x6b, 0x2b, 0xad, 0xc9, 0xea, 0x56, 0xe0, 0x18, 0x4e, 0xf9, 0xce, 0x29,
        0xf6, 0x48, 0x40, 0x80, 0xc2, 0xb2, 0x2e, 0xca, 0x1b, 0x4d, 0xc1, 0x22,
        0xd5, 0x59, 0x39, 0xeb, 0xfb, 0x86, 0xc2, 0xe3, 0x18, 0xbc, 0xdc, 0x2e,
        0x68, 0x23, 0x1,  0xb4, 0x86, 0x65, 0xb0, 0xc4, 0x71, 0x65, 0x26, 0x89,
        0x5d, 0xbe, 0xbc, 0x4f, 0xd6, 0xe9, 0xff, 0x9e, 0xf6, 0x76, 0x81, 0x1d,
        0xb6, 0xb0, 0x99, 0x95,
    };

    try expectEqual(
        error.SymbolHashCollision,
        testElfWithSyscalls(
            .{ .maximum_version = .v0 },
            sig.ELF_DATA_DIR ++ "hash_collision_sbpfv0.so",
            &.{.{ .name = colliding_name, .builtin_fn = syscalls.abort }},
            0,
        ),
    );
}
