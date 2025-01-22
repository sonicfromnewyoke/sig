const std = @import("std");
const builtin = @import("builtin");
const sig = @import("../sig.zig");
const network = @import("zig-network");

const Allocator = std.mem.Allocator;
const UdpSocket = network.Socket;

const Packet = sig.net.Packet;
const PACKET_DATA_SIZE = sig.net.PACKET_DATA_SIZE;
const Channel = sig.sync.Channel;
const Logger = sig.trace.Logger;
const ExitCondition = sig.sync.ExitCondition;

pub const SOCKET_TIMEOUT_US: usize = 1 * std.time.us_per_s;
pub const PACKETS_PER_BATCH: usize = 64;

// The identifier for the scoped logger used in this file.
const LOG_SCOPE: []const u8 = "socket_utils";

pub const SocketThread = struct {
    allocator: Allocator,
    handle: std.Thread,

    pub fn spawnSender(
        allocator: Allocator,
        logger: Logger,
        socket: UdpSocket,
        outgoing_channel: *Channel(Packet),
        exit: ExitCondition,
    ) !*SocketThread {
        return spawn(allocator, logger, socket, outgoing_channel, exit, runSender);
    }

    pub fn spawnReceiver(
        allocator: Allocator,
        logger: Logger,
        socket: UdpSocket,
        incoming_channel: *Channel(Packet),
        exit: ExitCondition,
    ) !*SocketThread {
        return spawn(allocator, logger, socket, incoming_channel, exit, runReceiver);
    }

    fn spawn(
        allocator: Allocator,
        logger: Logger,
        socket: UdpSocket,
        channel: *Channel(Packet),
        exit: ExitCondition,
        comptime runFn: anytype,
    ) !*SocketThread {
        // TODO(king): store event-loop data in SocketThread (hence, heap-alloc)..
        const self = try allocator.create(SocketThread);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .handle = try std.Thread.spawn(.{}, runFn, .{ logger, socket, channel, exit }),
        };

        return self;
    }

    pub fn join(self: *SocketThread) void {
        self.handle.join();
        self.allocator.destroy(self);
    }

    fn runReceiver(
        logger_: Logger,
        socket_: UdpSocket,
        incoming_channel: *Channel(Packet),
        exit: ExitCondition,
    ) !void {
        const logger = logger_.withScope(LOG_SCOPE);
        defer {
            exit.afterExit();
            logger.info().log("readSocket loop closed");
        }

        // NOTE: we set to non-blocking to periodically check if we should exit
        var socket = socket_;
        try socket.setReadTimeout(SOCKET_TIMEOUT_US);

        while (exit.shouldRun()) {
            var packet: Packet = Packet.default();
            const recv_meta = socket.receiveFrom(&packet.data) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => |e| {
                    logger.err().logf("readSocket error: {s}", .{@errorName(e)});
                    return e;
                },
            };
            const bytes_read = recv_meta.numberOfBytes;
            if (bytes_read == 0) return error.SocketClosed;
            packet.addr = recv_meta.sender;
            packet.size = bytes_read;
            try incoming_channel.send(packet);
        }
    }

    fn runSender(
        logger_: Logger,
        socket: UdpSocket,
        outgoing_channel: *Channel(Packet),
        exit: ExitCondition,
    ) !void {
        const logger = logger_.withScope(LOG_SCOPE);
        defer {
            // empty the channel
            while (outgoing_channel.tryReceive()) |_| {}
            exit.afterExit();
            logger.debug().log("sendSocket loop closed");
        }

        while (true) {
            outgoing_channel.waitToReceive(exit) catch break;

            while (outgoing_channel.tryReceive()) |p| {
                if (exit.shouldExit()) return; // drop the rest (like above) if exit prematurely.
                const bytes_sent = socket.sendTo(p.addr, p.data[0..p.size]) catch |e| {
                    logger.err().logf("sendSocket error: {s}", .{@errorName(e)});
                    continue;
                };
                std.debug.assert(bytes_sent == p.size);
            }
        }
    }
};

pub const BenchmarkPacketProcessing = struct {
    pub const min_iterations = 1;
    pub const max_iterations = 20;

    pub const BenchmarkArgs = struct {
        n_packets: usize,
        name: []const u8 = "",
    };

    pub const args = [_]BenchmarkArgs{
        BenchmarkArgs{
            .n_packets = 100_000,
            .name = "100k_msgs",
        },
    };

    pub fn benchmarkReadSocket(bench_args: BenchmarkArgs) !sig.time.Duration {
        const n_packets = bench_args.n_packets;
        const allocator = if (builtin.is_test) std.testing.allocator else std.heap.c_allocator;

        var socket = try UdpSocket.create(.ipv4, .udp);
        try socket.bindToPort(0);
        try socket.setReadTimeout(std.time.us_per_s); // 1 second

        const to_endpoint = try socket.getLocalEndPoint();

        var exit_flag = std.atomic.Value(bool).init(false);
        const exit_condition = ExitCondition{ .unordered = &exit_flag };

        // Setup incoming

        var incoming_channel = try Channel(Packet).init(allocator);
        defer incoming_channel.deinit();

        const incoming_pipe = try SocketThread.spawnReceiver(
            allocator,
            .noop,
            socket,
            &incoming_channel,
            exit_condition,
        );
        defer incoming_pipe.join();

        // Start outgoing

        const S = struct {
            fn sender(channel: *Channel(Packet), addr: network.EndPoint, e: ExitCondition) !void {
                var i: usize = 0;
                var packet: Packet = undefined;
                var prng = std.rand.DefaultPrng.init(0);
                var timer = try std.time.Timer.start();

                while (e.shouldRun()) {
                    prng.fill(&packet.data);
                    packet.addr = addr;
                    packet.size = PACKET_DATA_SIZE;
                    try channel.send(packet);

                    // 10Kb per second, until one second
                    // each packet is 1k bytes
                    // = 10 packets per second
                    i += 1;
                    if (i % 10 == 0) {
                        const elapsed = timer.read();
                        if (elapsed < std.time.ns_per_s) {
                            std.time.sleep(std.time.ns_per_s);
                        }
                    }
                }
            }
        };

        var outgoing_channel = try Channel(Packet).init(allocator);
        defer outgoing_channel.deinit();

        const outgoing_pipe = try SocketThread.spawnSender(
            allocator,
            .noop,
            socket,
            &outgoing_channel,
            exit_condition,
        );
        defer outgoing_pipe.join();

        const outgoing_handle = try std.Thread.spawn(
            .{},
            S.sender,
            .{ &outgoing_channel, to_endpoint, exit_condition },
        );
        defer outgoing_handle.join();

        // run incoming until received n_packets

        var packets_to_recv = n_packets;
        var timer = try sig.time.Timer.start();
        while (packets_to_recv > 0) {
            incoming_channel.waitToReceive(exit_condition) catch break;
            while (incoming_channel.tryReceive()) |_| {
                packets_to_recv -|= 1;
            }
        }

        exit_condition.setExit(); // kill benchSender and join it on defer.
        return timer.read();
    }
};

test "benchmark packet processing" {
    _ = try BenchmarkPacketProcessing.benchmarkReadSocket(.{
        .n_packets = 100_000,
    });
}
