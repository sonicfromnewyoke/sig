const std = @import("std");
const sig = @import("../sig.zig");

const shred_layout = sig.ledger.shred.layout;

const Atomic = std.atomic.Value;

const Channel = sig.sync.Channel;
const Counter = sig.prometheus.Counter;
const Histogram = sig.prometheus.Histogram;
const Packet = sig.net.Packet;
const Registry = sig.prometheus.Registry;
const SlotLeaders = sig.core.leader_schedule.SlotLeaders;
const VariantCounter = sig.prometheus.VariantCounter;

const VerifiedMerkleRoots = sig.utils.lru.LruCache(.non_locking, sig.core.Hash, void);

/// Analogous to [run_shred_sigverify](https://github.com/anza-xyz/agave/blob/8c5a33a81a0504fd25d0465bed35d153ff84819f/turbine/src/sigverify_shreds.rs#L82)
pub fn runShredVerifier(
    exit: *Atomic(bool),
    registry: *Registry(.{}),
    /// shred receiver --> me
    unverified_shred_receiver: *Channel(Packet),
    /// me --> shred processor
    verified_shred_sender: *Channel(Packet),
    /// me --> retransmit service
    maybe_retransmit_shred_sender: ?*Channel(Packet),
    leader_schedule: SlotLeaders,
) !void {
    const metrics = try registry.initStruct(Metrics);
    var verified_merkle_roots = try VerifiedMerkleRoots.init(std.heap.c_allocator, 1024);
    while (true) {
        unverified_shred_receiver.waitToReceive(.{ .unordered = exit }) catch break;

        var packet_count: usize = 0;
        while (unverified_shred_receiver.tryReceive()) |packet| {
            packet_count += 1;
            metrics.received_count.inc();
            if (verifyShred(&packet, leader_schedule, &verified_merkle_roots, metrics)) |_| {
                metrics.verified_count.inc();
                try verified_shred_sender.send(packet);
                if (maybe_retransmit_shred_sender) |retransmit_shred_sender| {
                    try retransmit_shred_sender.send(packet);
                }
            } else |err| {
                metrics.fail.observe(err);
            }
        }
        metrics.batch_size.observe(packet_count);
    }
}

/// Analogous to [verify_shred_cpu](https://github.com/anza-xyz/agave/blob/83e7d84bcc4cf438905d07279bc07e012a49afd9/ledger/src/sigverify_shreds.rs#L35)
fn verifyShred(
    packet: *const Packet,
    leader_schedule: SlotLeaders,
    verified_merkle_roots: *VerifiedMerkleRoots,
    metrics: Metrics,
) ShredVerificationFailure!void {
    const shred = shred_layout.getShred(packet) orelse return error.insufficient_shred_size;
    const slot = shred_layout.getSlot(shred) orelse return error.slot_missing;
    const signature = shred_layout.getLeaderSignature(shred) orelse return error.signature_missing;
    const signed_data = shred_layout.merkleRoot(shred) orelse return error.signed_data_missing;

    if (verified_merkle_roots.get(signed_data)) |_| {
        return;
    }
    metrics.cache_miss_count.inc();
    const leader = leader_schedule.get(slot) orelse return error.leader_unknown;
    const valid = signature.verify(leader, &signed_data.data) catch
        return error.failed_verification;
    if (!valid) return error.failed_verification;
    verified_merkle_roots.insert(signed_data, {}) catch return error.failed_caching;
}

pub const ShredVerificationFailure = error{
    insufficient_shred_size,
    slot_missing,
    signature_missing,
    signed_data_missing,
    leader_unknown,
    failed_verification,
    failed_caching,
};

const Metrics = struct {
    received_count: *Counter,
    verified_count: *Counter,
    cache_miss_count: *Counter,
    batch_size: *Histogram,
    fail: *VariantCounter(ShredVerificationFailure),

    pub const prefix = "shred_verifier";
    pub const histogram_buckets = sig.prometheus.histogram.exponentialBuckets(2, -1, 8);
};
