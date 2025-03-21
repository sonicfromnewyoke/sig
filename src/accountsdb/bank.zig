//! minimal logic for bank (still being built out)
const std = @import("std");
const sig = @import("../sig.zig");

const AccountsDB = sig.accounts_db.AccountsDB;
const BankFields = sig.accounts_db.snapshots.BankFields;
const GenesisConfig = sig.accounts_db.GenesisConfig;
const SnapshotManifest = sig.accounts_db.snapshots.Manifest;

// TODO: we can likley come up with a better name for this struct
/// Analogous to [Bank](https://github.com/anza-xyz/agave/blob/ad0a48c7311b08dbb6c81babaf66c136ac092e79/runtime/src/bank.rs#L718)
pub const Bank = struct {
    accounts_db: *AccountsDB,
    bank_fields: *const BankFields,

    pub fn init(accounts_db: *AccountsDB, bank_fields: *const BankFields) Bank {
        return .{
            .accounts_db = accounts_db,
            .bank_fields = bank_fields,
        };
    }

    pub fn validateBankFields(
        bank_fields: *const BankFields,
        genesis_config: *const GenesisConfig,
    ) !void {
        // self validation
        if (bank_fields.max_tick_height != (bank_fields.slot + 1) * bank_fields.ticks_per_slot) {
            return error.InvalidBankFields;
        }
        if (bank_fields.epoch_schedule.getEpoch(bank_fields.slot) != bank_fields.epoch) {
            return error.InvalidBankFields;
        }

        // cross validation against genesis
        if (genesis_config.creation_time != bank_fields.genesis_creation_time) {
            return error.BankAndGenesisMismatch;
        }
        if (genesis_config.ticks_per_slot != bank_fields.ticks_per_slot) {
            return error.BankAndGenesisMismatch;
        }
        const genesis_ns_per_slot = genesis_config.poh_config.target_tick_duration.nanos * @as(u128, genesis_config.ticks_per_slot);
        if (bank_fields.ns_per_slot != genesis_ns_per_slot) {
            return error.BankAndGenesisMismatch;
        }

        const genesis_slots_per_year = yearsAsSlots(1, genesis_config.poh_config.target_tick_duration.nanos, bank_fields.ticks_per_slot);
        if (genesis_slots_per_year != bank_fields.slots_per_year) {
            return error.BankAndGenesisMismatch;
        }
        if (!std.meta.eql(bank_fields.epoch_schedule, genesis_config.epoch_schedule)) {
            return error.BankAndGenesisMismatch;
        }
    }
};

pub const SECONDS_PER_YEAR: f64 = 365.242_199 * 24.0 * 60.0 * 60.0;

pub fn yearsAsSlots(years: f64, tick_duration_ns: u32, ticks_per_slot: u64) f64 {
    return years * SECONDS_PER_YEAR * (1_000_000_000.0 / @as(f64, @floatFromInt(tick_duration_ns))) / @as(f64, @floatFromInt(ticks_per_slot));
}

test "core.bank: load and validate from test snapshot" {
    const allocator = std.testing.allocator;

    var test_data_dir = try std.fs.cwd().openDir(sig.TEST_DATA_DIR, .{});
    defer test_data_dir.close();

    var tmp_dir_root = std.testing.tmpDir(.{});
    defer tmp_dir_root.cleanup();
    const snapdir = tmp_dir_root.dir;

    const snapshot_files = try sig.accounts_db.db.findAndUnpackTestSnapshots(1, snapdir);

    const boundedFmt = sig.utils.fmt.boundedFmt;
    const full_manifest_path = boundedFmt("snapshots/{0}/{0}", .{snapshot_files.full.slot});
    const full_manifest_file = try snapdir.openFile(full_manifest_path.constSlice(), .{});
    defer full_manifest_file.close();

    const full_manifest = try SnapshotManifest.readFromFile(allocator, full_manifest_file);
    defer full_manifest.deinit(allocator);

    // use the genesis to verify loading
    const genesis_path = sig.TEST_DATA_DIR ++ "genesis.bin";
    const genesis_config = try GenesisConfig.init(allocator, genesis_path);
    defer genesis_config.deinit(allocator);

    try Bank.validateBankFields(
        &full_manifest.bank_fields,
        &genesis_config,
    );
}
