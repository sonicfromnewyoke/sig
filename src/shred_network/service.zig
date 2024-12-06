const std = @import("std");
const network = @import("zig-network");
const sig = @import("../sig.zig");
const shred_network = @import("lib.zig");

const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;
const KeyPair = std.crypto.sign.Ed25519.KeyPair;
const Random = std.rand.Random;
const Socket = network.Socket;

const Channel = sig.sync.Channel;
const GossipTable = sig.gossip.GossipTable;
const ThreadSafeContactInfo = sig.gossip.data.ThreadSafeContactInfo;
const Logger = sig.trace.Logger;
const Packet = sig.net.Packet;
const Pubkey = sig.core.Pubkey;
const RwMux = sig.sync.RwMux;
const Registry = sig.prometheus.Registry;
const ServiceManager = sig.utils.service_manager.ServiceManager;
const Slot = sig.core.Slot;
const SlotLeaderProvider = sig.core.leader_schedule.SlotLeaderProvider;
const LeaderScheduleCache = sig.core.leader_schedule.LeaderScheduleCache;

const BasicShredTracker = shred_network.shred_tracker.BasicShredTracker;
const RepairPeerProvider = shred_network.repair_service.RepairPeerProvider;
const RepairRequester = shred_network.repair_service.RepairRequester;
const RepairService = shred_network.repair_service.RepairService;
const ShredReceiver = shred_network.shred_receiver.ShredReceiver;
const ShredReceiverMetrics = shred_network.shred_receiver.ShredReceiverMetrics;

/// Settings which instruct the Shred Collector how to behave.
pub const ShredCollectorConfig = struct {
    start_slot: ?Slot,
    repair_port: u16,
    /// tvu port in agave
    turbine_recv_port: u16,
};

/// Resources that are required for the Shred Collector to operate.
pub const ShredCollectorDependencies = struct {
    allocator: Allocator,
    logger: Logger,
    random: Random,
    registry: *Registry(.{}),
    /// This validator's keypair
    my_keypair: *const KeyPair,
    /// Shared exit indicator, used to shutdown the Shred Collector.
    exit: *Atomic(bool),
    /// Shared state that is read from gossip
    gossip_table_rw: *RwMux(GossipTable),
    /// Shared state that is read from gossip
    my_shred_version: *const Atomic(u16),
    my_contact_info: ThreadSafeContactInfo,
    leader_schedule: SlotLeaderProvider,
    shred_inserter: sig.ledger.ShredInserter,
    n_retransmit_threads: ?usize,
    overwrite_turbine_stake_for_testing: bool,
    leader_schedule_cache: *LeaderScheduleCache,
    bank_fields: *const sig.accounts_db.snapshots.BankFields,
};

/// Start the Shred Collector.
///
/// Initializes all state and spawns all threads.
/// Returns as soon as all the threads are running.
///
/// Returns a ServiceManager representing the Shred Collector.
/// This can be used to join and deinit the Shred Collector.
///
/// Analogous to a subset of [Tvu::new](https://github.com/anza-xyz/agave/blob/8c5a33a81a0504fd25d0465bed35d153ff84819f/core/src/turbine.rs#L119)
pub fn start(
    conf: ShredCollectorConfig,
    deps: ShredCollectorDependencies,
) !ServiceManager {
    var service_manager = ServiceManager.init(
        deps.allocator,
        deps.logger.unscoped(),
        deps.exit,
        "shred collector",
        .{},
        .{},
    );
    var arena = service_manager.arena.allocator();

    const repair_socket = try bindUdpReusable(conf.repair_port);
    const turbine_socket = try bindUdpReusable(conf.turbine_recv_port);

    var retransmit_channel = try sig.sync.Channel(sig.net.Packet).init(deps.allocator);
    defer retransmit_channel.deinit();

    // receiver (threads)
    const unverified_shred_channel = try Channel(Packet).create(deps.allocator);
    const verified_shred_channel = try Channel(Packet).create(deps.allocator);
    const shred_receiver = try arena.create(ShredReceiver);
    shred_receiver.* = .{
        .allocator = deps.allocator,
        .keypair = deps.my_keypair,
        .exit = deps.exit,
        .logger = deps.logger.withScope(@typeName(ShredReceiver)),
        .repair_socket = repair_socket,
        .turbine_socket = turbine_socket,
        .unverified_shred_sender = unverified_shred_channel,
        .shred_version = deps.my_shred_version,
        .metrics = try deps.registry.initStruct(ShredReceiverMetrics),
        .root_slot = if (conf.start_slot) |s| s - 1 else 0,
    };
    try service_manager.spawn(
        "Shred Receiver",
        ShredReceiver.run,
        .{shred_receiver},
    );

    // verifier (thread)
    try service_manager.spawn(
        "Shred Verifier",
        shred_network.shred_verifier.runShredVerifier,
        .{
            deps.exit,
            deps.registry,
            unverified_shred_channel,
            verified_shred_channel,
            &retransmit_channel,
            deps.leader_schedule,
        },
    );

    // tracker (shared state, internal to Shred Collector)
    const shred_tracker = try arena.create(BasicShredTracker);
    shred_tracker.* = try BasicShredTracker.init(
        conf.start_slot,
        deps.logger.unscoped(),
        deps.registry,
    );

    // processor (thread)
    try service_manager.spawn(
        "Shred Processor",
        shred_network.shred_processor.runShredProcessor,
        .{
            deps.allocator,
            deps.exit,
            deps.logger.unscoped(),
            deps.registry,
            verified_shred_channel,
            shred_tracker,
            deps.shred_inserter,
            deps.leader_schedule,
        },
    );

    // retransmitter (thread)
    try service_manager.spawn(
        "Shred Retransmitter",
        shred_network.shred_retransmitter.runShredRetransmitter,
        .{.{
            .allocator = deps.allocator,
            .my_contact_info = deps.my_contact_info,
            .bank_fields = deps.bank_fields,
            .leader_schedule_cache = deps.leader_schedule_cache,
            .gossip_table_rw = deps.gossip_table_rw,
            .receiver = &retransmit_channel,
            .maybe_num_retransmit_threads = deps.n_retransmit_threads,
            .overwrite_stake_for_testing = deps.overwrite_turbine_stake_for_testing,
            .exit = deps.exit,
            .rand = deps.random,
            .logger = deps.logger.unscoped(),
        }},
    );

    // repair (thread)
    const repair_peer_provider = try RepairPeerProvider.init(
        deps.allocator,
        deps.random,
        deps.registry,
        deps.gossip_table_rw,
        Pubkey.fromPublicKey(&deps.my_keypair.public_key),
        deps.my_shred_version,
    );
    const repair_requester = try RepairRequester.init(
        deps.allocator,
        deps.logger.unscoped(),
        deps.random,
        deps.registry,
        deps.my_keypair,
        repair_socket,
        deps.exit,
    );
    const repair_svc = try arena.create(RepairService);
    try service_manager.defers.deferCall(RepairService.deinit, .{repair_svc});
    repair_svc.* = try RepairService.init(
        deps.allocator,
        deps.logger.unscoped(),
        deps.exit,
        deps.registry,
        repair_requester,
        repair_peer_provider,
        shred_tracker,
    );
    try service_manager.spawn(
        "Repair Service",
        RepairService.run,
        .{repair_svc},
    );

    return service_manager;
}

fn bindUdpReusable(port: u16) !Socket {
    var socket = try Socket.create(network.AddressFamily.ipv4, network.Protocol.udp);
    try sig.net.enablePortReuse(&socket, true);
    try socket.bindToPort(port);
    try socket.setReadTimeout(sig.net.SOCKET_TIMEOUT_US);
    return socket;
}