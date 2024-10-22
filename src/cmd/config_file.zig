const ConfigFile = @This();

const std = @import("std");
const sig = @import("sig.zig");
const IpAddr = sig.net.IpAddr;

const Level = sig.trace.Level;

pub const SnapshotArchiveFormat = enum {
    zstd,
    lz4,
};

const PortRange = std.meta.Tuple(&.{ u16, u16 });

pub const Network = enum {
    mainnet,
    devnet,
    testnet,

    pub fn entrypoints(self: Network) []const []const u8 {
        return switch (self) {
            .mainnet => &.{
                "entrypoint.mainnet-beta.solana.com:8001",
                "entrypoint2.mainnet-beta.solana.com:8001",
                "entrypoint3.mainnet-beta.solana.com:8001",
                "entrypoint4.mainnet-beta.solana.com:8001",
                "entrypoint5.mainnet-beta.solana.com:8001",
            },
            .testnet => &.{
                "entrypoint.testnet.solana.com:8001",
                "entrypoint2.testnet.solana.com:8001",
                "entrypoint3.testnet.solana.com:8001",
            },
            .devnet => &.{
                "entrypoint.devnet.solana.com:8001",
                "entrypoint2.devnet.solana.com:8001",
                "entrypoint3.devnet.solana.com:8001",
                "entrypoint4.devnet.solana.com:8001",
                "entrypoint5.devnet.solana.com:8001",
            },
        };
    }
};

const LogConfig = struct {
    // If no path is provided, the default is to place the log file in
    // /tmp with a name that will be unique.  If specified as "-", the
    // permanent log will be written to stdout.
    path: ?[]const u8 = null,
    // The minimum log level which will be written to the log file.  Log
    // levels lower than this will be skipped
    level: Level = .info,
};

const MetricsConfig = struct {
    port: u16 = 12345,
};

const GeyserConfig = struct {
    enable: bool = false,
    pipe_path: []const u8 = sig.VALIDATOR_DIR ++ "geyser.pipe",
    writer_fba_bytes: usize = 1 << 32, // 4gb
};

const LedgerConfig = struct {
    // Use DIR as ledger location
    path: []const u8 = "ledger",
    // Absolute directory path to place the accounts database in
    accounts_path: []const u8 = "ledger/accounts",
    // Maximum number of shreds to keep in root slots in the ledger
    // before discarding.
    limit_size: u64 = 200_000_000,
    // If nonempty, enable an accounts index indexed by the specified
    // field.  The account field must be one of "program-id",
    // "spl-token-owner", or "spl-token-mint"
    account_indexes: [][]const u8 = &.{},
    // If account indexes are enabled, exclude these keys from the index.
    account_index_exclude_keys: [][]const u8 = &.{},
    // If account indexes are enabled, only include these keys in the
    // index.  This overrides `account_index_exclude_keys` if specified
    // and that value will be ignored.
    account_index_include_keys: [][]const u8 = &.{},
    // Snapshot archive format to use
    snapshot_archive_format: SnapshotArchiveFormat = .zstd,
};

const GossipConfig = struct {
    // Routable DNS name or IP address and port number to use to
    // rendezvous with the gossip cluster
    entrypoints: [][]const u8 = &.{},
    // Gossip port number for the validator
    port: u16 = 8001,
    // Turbine port number for the validator
    turbine_recv_port: u16 = 8002,
    // Repair port number for the validator
    repair_port: u16 = 8003,
    // Gossip DNS name or IP address for the validator to advertise in gossip
    // default: ask --entrypoint, or 127.0.0.1 when --entrypoint is not provided
    host: ?[]const u8 = null,
    // Network to connect to
    network: ?[]const u8 = null,
    // Run as a gossip spy node (minimize outgoing packets)
    spy: bool = false,
    // Periodically dump gossip table to csv files and logs
    dump: bool = false,

    pub fn getHost(config: GossipConfig) ?sig.net.SocketAddr.ParseIpError!IpAddr {
        const host_str = config.host orelse return null;
        const socket = try sig.net.SocketAddr.parse(host_str);
        return switch (socket) {
            .V4 => |v4| .{ .ipv4 = v4.ip },
            .V6 => |v6| .{ .ipv6 = v6.ip },
        };
    }

    pub fn getNetwork(self: GossipConfig) error{UnknownNetwork}!?Network {
        return if (self.network) |network_str|
            std.meta.stringToEnum(Network, network_str) orelse
                error.UnknownNetwork
        else
            null;
    }
};

const RPCConfig = struct {
    // RPC port number for the validator
    port: u16 = 8899,
    // Enable the full RPC API
    full_api: bool = false,
    // Do not publish the RPC port for use by others
    private: bool = false,
    // Enable historical transaction info over JSON RPC, including the 'getConfirmedBlock' API.
    // This will cause an increase in disk usage and IOPS
    transaction_history: bool = false,
    // Include CPI inner instructions, logs, and return data in the historical transaction info stored
    extended_tx_metadata_storage: bool = false,
    // Use the RPC service of known validators only
    only_known: bool = true,
    // Enable the unstable RPC PubSub `blockSubscribe` subscription
    pubsub_enable_block_subscription: bool = false,
    // Enable the unstable RPC PubSub `voteSubscribe` subscription
    pubsub_enable_vote_subscription: bool = false,
    // Fetch historical transaction info from a BigTable instance as a fallback to local ledger data
    bigtable_ledger_storage: bool = false,
};

const SnapshotsConfig = struct {
    // Use DIR as the base location for snapshots. A subdirectory named "snapshots" will be created.
    path: []const u8 = "ledger/snapshots",
    // Use DIR as incremental snapshot archives location
    incremental_path: []const u8 = "ledger/snapshots/incremental",
    // Disable incremental snapshots
    no_incremental_snapshots: bool = false,
    // Number of slots between generating full snapshots.
    // Must be a multiple of the incremental snapshot interval.
    // Only used when incremental snapshots are enabled.
    full_snapshot_interval_slots: u64 = 25_000,
    // Number of slots between generating snapshots.
    // If incremental snapshots are enabled, this sets the incremental snapshot interval.
    // If incremental snapshots are disabled, this sets the full snapshot interval.
    // Setting this to 0 disables all snapshots.
    snapshot_interval_slots: u64 = 100,
    // The maximum number of full snapshot archives to hold on to when purging older snapshots.
    maximum_full_snapshots_to_retain: u16 = 2,
    // The maximum number of incremental snapshot archives to hold on to when purging older snapshots.
    maximum_incremental_snapshots_to_retain: u16 = 4,
    // The minimal speed of snapshot downloads measured in bytes/second. If the initial download speed falls below
    // this threshold, the system will retry the download against a different rpc node
    minimal_snapshot_download_speed: u64 = 10_485_760,
    // Do not attempt to fetch a snapshot from the cluster, start from a local snapshot if present
    no_snapshot_fetch: bool = false,
};

const ConsensusConfig = struct {
    // Validator identity keypair
    identity_path: []const u8 = "~/.sig/identity.key",
    // Validator vote account public key. If unspecified, voting will be disabled.
    // The authorized voter for the  account must either be the `identity_path` keypair
    // or set by the `authorized_voter_paths` field.
    vote_account_path: []const u8 = "",
    // Include an additional authorized voter keypair.
    // May be specified multiple times.
    authorized_voter_paths: [][]const u8 = &.{},
    //  Do not fetch genesis from the cluster
    no_genesis_fetch: bool = false,
    // Require the genesis have this hash
    expected_genesis_hash: ?[]const u8 = null,
    // After processing the ledger and the next slot is SLOT,
    // wait until a supermajority of stake is visible on gossip before starting PoH
    wait_for_supermajority_at_slot: u64 = 0,
    // When wait-for-supermajority <x>, require the bank at <x> to have this hash
    expected_bank_hash: ?[]const u8 = null,
    // Require the shred version be this value
    expected_shred_version: u16 = 0,
    // Add a hard fork at this slot
    hard_fork_at_slots: ?u64 = null,
    // A snapshot hash must be published in gossip by this validator to be accepted.
    // If unspecified any snapshot hash will be accepted
    trusted_validators: [][]const u8 = &.{},
};

// Range to use for dynamically assigned ports [default: 8000-10000]
dynamic_port_range: PortRange = .{ 8_000, 10_000 },

log: LogConfig = .{},
metrics: MetricsConfig = .{},
geyser: GeyserConfig = .{},
ledger: LedgerConfig = .{},
gossip: GossipConfig = .{},
rpc: RPCConfig = .{},
snapshots: SnapshotsConfig = .{},
consensus: ConsensusConfig = .{},
