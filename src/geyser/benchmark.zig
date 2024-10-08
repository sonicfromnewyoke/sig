const std = @import("std");
const sig = @import("../sig.zig");
const geyser = sig.geyser;

const Account = sig.core.Account;
const Slot = sig.core.time.Slot;
const Pubkey = sig.core.pubkey.Pubkey;
const GeyserWriter = sig.geyser.GeyserWriter;
const VersionedAccountPayload = sig.geyser.core.VersionedAccountPayload;

const MEASURE_RATE = sig.time.Duration.fromSecs(2);
const PIPE_PATH = "../sig/" ++ sig.TEST_DATA_DIR ++ "accountsdb_fuzz.pipe";

pub fn streamWriter(allocator: std.mem.Allocator, exit: *std.atomic.Value(bool)) !void {
    // 4gb
    var geyser_writer = try GeyserWriter.init(allocator, PIPE_PATH, exit, 1 << 32);
    defer geyser_writer.deinit();

    try geyser_writer.spawnIOLoop();

    var prng = std.rand.DefaultPrng.init(19);
    const random = prng.random();

    // PERF: one allocation slice
    const N_ACCOUNTS_PER_SLOT = 700;
    const accounts = try allocator.alloc(Account, N_ACCOUNTS_PER_SLOT);
    const pubkeys = try allocator.alloc(Pubkey, N_ACCOUNTS_PER_SLOT);
    for (0..N_ACCOUNTS_PER_SLOT) |i| {
        const data_len = random.intRangeAtMost(u64, 2000, 10_000);
        accounts[i] = try Account.random(allocator, random, data_len);
        pubkeys[i] = Pubkey.random(random);
    }
    var slot: Slot = 0;

    while (!exit.load(.acquire)) {
        // since the i/o happens in another thread, we cant easily track bytes/second here
        geyser_writer.writePayloadToPipe(
            VersionedAccountPayload{
                .AccountPayloadV1 = .{
                    .accounts = accounts,
                    .pubkeys = pubkeys,
                    .slot = slot,
                },
            },
        ) catch |err| {
            if (err == error.MemoryBlockedWithExitSignaled) {
                break;
            } else {
                return err;
            }
        };
        slot += 1;
    }
}

pub fn runBenchmark() !void {
    const allocator = std.heap.c_allocator;

    const exit = try allocator.create(std.atomic.Value(bool));
    defer allocator.destroy(exit);

    exit.* = std.atomic.Value(bool).init(false);

    const reader_handle = try std.Thread.spawn(
        .{},
        geyser.core.streamReader,
        .{ allocator, exit, PIPE_PATH, MEASURE_RATE, null },
    );
    const writer_handle = try std.Thread.spawn(.{}, streamWriter, .{ allocator, exit });

    // let it run for ~4 measurements
    const NUM_MEAUSUREMENTS = 4;
    std.time.sleep(MEASURE_RATE.asNanos() * NUM_MEAUSUREMENTS);
    std.debug.print("exiting\n", .{});
    exit.store(true, .release);

    reader_handle.join();
    writer_handle.join();
}
