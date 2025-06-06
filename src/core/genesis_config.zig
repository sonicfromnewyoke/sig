//! genesis config fields

const std = @import("std");
const sig = @import("../sig.zig");
const bincode = sig.bincode;

const AutoHashMap = std.AutoHashMap;
const Account = sig.core.Account;
const Epoch = sig.core.Epoch;
const EpochSchedule = sig.core.EpochSchedule;
const Pubkey = sig.core.Pubkey;
const UnixTimestamp = sig.core.UnixTimestamp;

pub const Rent = sig.runtime.sysvar.Rent;

pub const String = std.ArrayList(u8);

pub const RustDuration = struct {
    secs: u64,
    nanos: u32,
};

/// Analogous to [PohConfig](https://github.com/anza-xyz/agave/blob/cadba689cb44db93e9c625770cafd2fc0ae89e33/sdk/src/poh_config.rs#L10)
pub const PohConfig = struct {
    /// The target tick rate of the cluster.
    target_tick_duration: RustDuration,

    /// The target total tick count to be produced; used for testing only
    target_tick_count: ?u64,

    /// How many hashes to roll before emitting the next tick entry.
    /// None enables "Low power mode", which makes the validator sleep
    /// for `target_tick_duration` instead of hashing
    hashes_per_tick: ?u64,
};

/// Analogous to [FeeRateGovernor](https://github.com/anza-xyz/agave/blob/ec9bd798492c3b15d62942f2d9b5923b99042350/sdk/program/src/fee_calculator.rs#L55)
pub const FeeRateGovernor = struct {
    /// The current cost of a signature  This amount may increase/decrease over time based on
    /// cluster processing load.
    lamports_per_signature: u64 = 0,

    /// The target cost of a signature when the cluster is operating around target_signatures_per_slot
    /// signatures.
    target_lamports_per_signature: u64,

    /// Used to estimate the desired processing capacity of the cluster.  As the signatures for
    /// recent slots are fewer/greater than this value, lamports_per_signature will decrease/increase
    /// for the next slot.  A value of 0 disables lamports_per_signature fee adjustments.
    target_signatures_per_slot: u64,

    min_lamports_per_signature: u64,
    max_lamports_per_signature: u64,

    /// What portion of collected fees are to be destroyed, as a fraction of std::u8::MAX.
    burn_percent: u8,

    pub const @"!bincode-config:lamports_per_signature" = bincode.FieldConfig(u64){ .skip = true };

    pub fn initRandom(random: std.Random) FeeRateGovernor {
        return .{
            .lamports_per_signature = random.int(u64),
            .target_lamports_per_signature = random.int(u64),
            .target_signatures_per_slot = random.int(u64),
            .min_lamports_per_signature = random.int(u64),
            .max_lamports_per_signature = random.int(u64),
            .burn_percent = random.uintAtMost(u8, 100),
        };
    }
};

/// Analogous to [Inflation](https://github.com/anza-xyz/agave/blob/55aff7288e596e93d1184ba827048b1e3dc98061/sdk/src/inflation.rs#L6)
pub const Inflation = struct {
    /// Initial inflation percentage, from time=0
    initial: f64,

    /// Terminal inflation percentage, to time=INF
    terminal: f64,

    /// Rate per year, at which inflation is lowered until reaching terminal
    ///  i.e. inflation(year) == MAX(terminal, initial*((1-taper)^year))
    taper: f64,

    /// Percentage of total inflation allocated to the foundation
    foundation: f64,
    /// Duration of foundation pool inflation, in years
    foundation_term: f64,

    /// DEPRECATED, this field is currently unused
    __unused: f64,

    pub fn initRandom(random: std.Random) Inflation {
        return .{
            .initial = random.float(f64),
            .terminal = random.float(f64),
            .taper = random.float(f64),
            .foundation = random.float(f64),
            .foundation_term = random.float(f64),
            .__unused = random.float(f64),
        };
    }
};

/// Analogous to [ClusterType](https://github.com/anza-xyz/agave/blob/cadba689cb44db93e9c625770cafd2fc0ae89e33/sdk/src/genesis_config.rs#L46)
/// Explicit numbers are added to ensure we don't mess up the order of the fields and break bincode reading.
pub const ClusterType = union(enum(u8)) {
    Testnet = 0,
    MainnetBeta = 1,
    Devnet = 2,
    Development = 3,
    LocalHost,
    Custom: struct {
        url: []const u8,
    },
};

/// Analogous to [GenesisConfig](https://github.com/anza-xyz/agave/blob/cadba689cb44db93e9c625770cafd2fc0ae89e33/sdk/src/genesis_config.rs#L93)
pub const GenesisConfig = struct {
    // when the network (bootstrap validator) was started relative to the UNIX Epoch
    creation_time: UnixTimestamp,
    // initial accounts
    accounts: AutoHashMap(Pubkey, Account),
    // /// built-in programs
    native_instruction_processors: std.ArrayList(struct { String, Pubkey }),
    /// accounts for network rewards, these do not count towards capitalization
    rewards_pools: AutoHashMap(Pubkey, Account),
    ticks_per_slot: u64,
    unused: u64,
    /// network speed configuration
    poh_config: PohConfig,
    /// this field exists only to ensure that the binary layout of GenesisConfig remains compatible
    /// with the Solana v0.23 release line
    __backwards_compat_with_v0_23: u64,
    /// transaction fee config
    fee_rate_governor: FeeRateGovernor,
    /// rent config
    rent: Rent,
    /// inflation config
    inflation: Inflation,
    /// how slots map to epochs
    epoch_schedule: EpochSchedule,
    /// network runlevel
    cluster_type: ClusterType,

    pub fn init(
        allocator: std.mem.Allocator,
        genesis_path: []const u8,
    ) !GenesisConfig {
        var file = try std.fs.cwd().openFile(genesis_path, .{});
        defer file.close();

        return try bincode.read(allocator, GenesisConfig, file.reader(), .{});
    }

    pub fn deinit(self: GenesisConfig, allocator: std.mem.Allocator) void {
        bincode.free(allocator, self);
    }
};

test "genesis_config deserialize development config" {
    const allocator = std.testing.allocator;

    const genesis_path = sig.TEST_DATA_DIR ++ "genesis.bin";
    const config = try GenesisConfig.init(allocator, genesis_path);
    defer config.deinit(allocator);

    try std.testing.expectEqual(ClusterType.Development, config.cluster_type);
}

test "genesis_config deserialize testnet config" {
    const allocator = std.testing.allocator;

    const genesis_path = sig.GENESIS_DIR ++ "testnet_genesis.bin";
    const config = try GenesisConfig.init(allocator, genesis_path);
    defer config.deinit(allocator);

    try std.testing.expectEqual(ClusterType.Testnet, config.cluster_type);
}

test "genesis_config deserialize devnet config" {
    const allocator = std.testing.allocator;

    const genesis_path = sig.GENESIS_DIR ++ "devnet_genesis.bin";
    const config = try GenesisConfig.init(allocator, genesis_path);
    defer config.deinit(allocator);

    try std.testing.expectEqual(ClusterType.Devnet, config.cluster_type);
}

test "genesis_config deserialize mainnet config" {
    const allocator = std.testing.allocator;

    const genesis_path = sig.GENESIS_DIR ++ "mainnet_genesis.bin";
    const config = try GenesisConfig.init(allocator, genesis_path);
    defer config.deinit(allocator);

    try std.testing.expectEqual(ClusterType.MainnetBeta, config.cluster_type);
}
