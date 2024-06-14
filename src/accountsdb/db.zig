const std = @import("std");
const sig = @import("../lib.zig");
const builtin = @import("builtin");

const bincode = @import("../bincode/bincode.zig");
const sysvars = @import("../accountsdb/sysvars.zig");

const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Blake3 = std.crypto.hash.Blake3;

const spawnThreadTasks = sig.utils.thread.spawnThreadTasks;
const Account = sig.core.Account;
const Hash = @import("../core/hash.zig").Hash;
const Slot = @import("../core/time.zig").Slot;
const Epoch = @import("../core/time.zig").Epoch;
const Pubkey = @import("../core/pubkey.zig").Pubkey;
const AccountsDbFields = @import("../accountsdb/snapshots.zig").AccountsDbFields;
const AccountFileInfo = @import("../accountsdb/snapshots.zig").AccountFileInfo;
const AccountFile = @import("../accountsdb/accounts_file.zig").AccountFile;
const FileId = @import("../accountsdb/accounts_file.zig").FileId;
const AccountInFile = @import("../accountsdb/accounts_file.zig").AccountInFile;
const ThreadPool = @import("../sync/thread_pool.zig").ThreadPool;
const NestedHashTree = @import("../common/merkle_tree.zig").NestedHashTree;
const SnapshotFields = @import("../accountsdb/snapshots.zig").SnapshotFields;
const BankIncrementalSnapshotPersistence = @import("../accountsdb/snapshots.zig").BankIncrementalSnapshotPersistence;
const Bank = @import("bank.zig").Bank;
const readDirectory = @import("../utils/directory.zig").readDirectory;
const SnapshotFiles = @import("../accountsdb/snapshots.zig").SnapshotFiles;
const AllSnapshotFields = @import("../accountsdb/snapshots.zig").AllSnapshotFields;
const SnapshotFieldsAndPaths = @import("../accountsdb/snapshots.zig").SnapshotFieldsAndPaths;
const parallelUnpackZstdTarBall = @import("snapshots.zig").parallelUnpackZstdTarBall;
const Logger = @import("../trace/log.zig").Logger;
const printTimeEstimate = @import("../time/estimate.zig").printTimeEstimate;

const AccountsDBConfig = @import("../cmd/config.zig").AccountsDBConfig;
const AccountIndex = sig.accounts_db.index.AccountIndex;
const AccountRef = sig.accounts_db.index.AccountRef;
const DiskMemoryAllocator = sig.accounts_db.index.DiskMemoryAllocator;

const RwMux = sig.sync.RwMux;

// NOTE: this constant has a large impact on performance due to allocations (best to overestimate)
pub const ACCOUNTS_PER_FILE_EST: usize = 1500;

pub const DB_PROGRESS_UPDATES_NS = 5 * std.time.ns_per_s;
pub const DB_MANAGER_UPDATE_NS = 5 * std.time.ns_per_s;

pub const MERKLE_FANOUT: usize = 16;
pub const ACCOUNT_INDEX_BINS: usize = 8192;
pub const ACCOUNT_FILE_SHRINK_THRESHOLD = 70; // shrink account files with more than X% dead bytes
pub const MAX_FLUSH_SLOTS_PER_ITER = 10;

const PubkeysAndAccounts = struct { []Pubkey, []Account };
const AccountCache = std.AutoHashMap(Slot, PubkeysAndAccounts);
const FileMap = std.AutoArrayHashMap(FileId, RwMux(AccountFile));

/// database for accounts
pub const AccountsDB = struct {
    allocator: std.mem.Allocator,

    // maps a pubkey to the account location
    account_index: AccountIndex,
    disk_allocator_ptr: ?*DiskMemoryAllocator = null,

    // track per-slot for purge/flush
    account_cache: RwMux(AccountCache),
    file_map: RwMux(FileMap),

    // files which have been flushed but not cleaned yet (old-state or zero-lamport accounts)
    unclean_account_files: std.ArrayList(FileId),
    // files which have a small number of accounts alive and should be shrunk
    shrink_account_files: std.AutoArrayHashMap(FileId, void),
    // files which have zero accounts and should be deleted
    delete_account_files: std.AutoArrayHashMap(FileId, void),
    // used for filenames when flushing accounts to disk
    // TODO: do we need this? since flushed slots will be unique
    largest_file_id: FileId = FileId.fromInt(0),

    // used for flushing/cleaning/purging/shrinking
    // TODO: when working on consensus, we'll swap this out
    largest_root_slot: std.atomic.Value(Slot) = std.atomic.Value(Slot).init(0),

    logger: Logger,
    config: AccountsDBConfig,
    fields: ?AccountsDbFields = null,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        logger: Logger,
        config: AccountsDBConfig,
    ) !Self {
        const maybe_disk_allocator_ptr: ?*DiskMemoryAllocator, //
        const reference_allocator: std.mem.Allocator //
        = blk: {
            if (config.use_disk_index) {
                // make the disk directory
                const disk_dir = try std.fmt.allocPrint(allocator, "{s}/index", .{config.snapshot_dir});
                defer allocator.free(disk_dir);
                try std.fs.cwd().makePath(disk_dir);

                const disk_file_suffix = try std.fmt.allocPrint(allocator, "{s}/bin", .{disk_dir});
                logger.infof("using disk index in {s}", .{disk_file_suffix});

                const ptr = try allocator.create(DiskMemoryAllocator);
                ptr.* = try DiskMemoryAllocator.init(disk_file_suffix);

                break :blk .{ ptr, ptr.allocator() };
            } else {
                break :blk .{ null, std.heap.page_allocator };
            }
        };

        const account_index = try AccountIndex.init(
            allocator,
            reference_allocator,
            config.num_index_bins,
        );

        return .{
            .allocator = allocator,
            .disk_allocator_ptr = maybe_disk_allocator_ptr,
            .account_index = account_index,
            .logger = logger,
            .config = config,
            .account_cache = RwMux(AccountCache).init(AccountCache.init(allocator)),
            .file_map = RwMux(FileMap).init(FileMap.init(allocator)),
            .unclean_account_files = std.ArrayList(FileId).init(allocator),
            .shrink_account_files = std.AutoArrayHashMap(FileId, void).init(allocator),
            .delete_account_files = std.AutoArrayHashMap(FileId, void).init(allocator),
        };
    }

    pub fn deinit(self: *Self, delete_index_files: bool) void {
        self.account_index.deinit(true);
        if (self.disk_allocator_ptr) |ptr| {
            // note: we dont always deinit the allocator so we keep the index files
            // because they are expensive to generate
            if (delete_index_files) {
                ptr.deinit(self.allocator);
            } else {
                self.allocator.free(ptr.filepath);
            }
            self.allocator.destroy(ptr);
        }

        {
            const account_cache, var account_cache_lg = self.account_cache.writeWithLock();
            defer account_cache_lg.unlock();
            account_cache.deinit();
        }
        {
            const file_map, var file_map_lg = self.file_map.writeWithLock();
            defer file_map_lg.unlock();
            file_map.deinit();
        }

        self.unclean_account_files.deinit();
        self.shrink_account_files.deinit();
        self.delete_account_files.deinit();
    }

    /// easier to use load function
    pub fn loadWithDefaults(
        self: *Self,
        snapshot_fields_and_paths: *SnapshotFieldsAndPaths,
        snapshot_dir: []const u8,
        n_threads: u32,
        validate: bool,
    ) !SnapshotFields {
        const snapshot_fields = try snapshot_fields_and_paths.all_fields.collapse();
        const accounts_path = try std.fmt.allocPrint(self.allocator, "{s}/accounts/", .{snapshot_dir});
        defer self.allocator.free(accounts_path);

        var timer = try std.time.Timer.start();
        self.logger.infof("loading from snapshot...", .{});
        try self.loadFromSnapshot(
            snapshot_fields.accounts_db_fields,
            accounts_path,
            n_threads,
            std.heap.page_allocator,
        );
        self.logger.infof("loaded from snapshot in {s}", .{std.fmt.fmtDuration(timer.read())});

        if (validate) {
            timer.reset();
            const full_snapshot = snapshot_fields_and_paths.all_fields.full;
            try self.validateLoadFromSnapshot(
                snapshot_fields.bank_fields.incremental_snapshot_persistence,
                full_snapshot.bank_fields.slot,
                full_snapshot.bank_fields.capitalization,
            );
            self.logger.infof("validated from snapshot in {s}", .{std.fmt.fmtDuration(timer.read())});
        }

        return snapshot_fields;
    }

    /// loads the account files and gernates the account index from a snapshot
    pub fn loadFromSnapshot(
        self: *Self,
        // fields from the snapshot
        fields: AccountsDbFields,
        // where the account files are
        accounts_path: []const u8,
        n_threads: u32,
        per_thread_allocator: std.mem.Allocator,
    ) !void {
        self.fields = fields;

        // used to read account files
        const n_parse_threads = n_threads;
        // used to merge thread results
        const n_combine_threads = n_threads;

        var timer = std.time.Timer.start() catch unreachable;
        timer.reset();

        // read the account files
        var accounts_dir = try std.fs.cwd().openDir(accounts_path, .{ .iterate = true });
        defer accounts_dir.close();

        const accounts_dir_iter = accounts_dir.iterate();

        var files = try readDirectory(self.allocator, accounts_dir_iter);
        const filenames = files.filenames;
        defer {
            files.filenames.deinit();
            self.allocator.free(files.filename_memory);
        }

        var n_account_files: usize = 0;
        for (filenames.items) |filename| {
            var fiter = std.mem.tokenizeSequence(u8, filename, ".");
            const slot = std.fmt.parseInt(Slot, fiter.next().?, 10) catch continue;
            if (fields.file_map.contains(slot)) {
                n_account_files += 1;
            }
        }
        self.logger.infof("found {d} account files", .{n_account_files});
        std.debug.assert(n_account_files > 0);

        const use_disk_index = self.config.use_disk_index;
        if (self.config.use_disk_index) {
            self.logger.info("using disk index");
        } else {
            self.logger.info("using ram index");
        }

        // short path
        if (n_threads == 1) {
            try self.loadAndVerifyAccountsFiles(
                accounts_path,
                filenames.items,
                ACCOUNTS_PER_FILE_EST,
                true,
            );
            return;
        }

        // setup the parallel indexing
        var loading_threads = try ArrayList(AccountsDB).initCapacity(
            self.allocator,
            n_parse_threads,
        );
        for (0..n_parse_threads) |_| {
            var thread_db = try AccountsDB.init(
                per_thread_allocator,
                self.logger,
                .{ .num_index_bins = self.config.num_index_bins },
            );

            thread_db.fields = self.fields;
            // set the disk allocator after init() doesnt create a new one
            if (use_disk_index) {
                thread_db.disk_allocator_ptr = self.disk_allocator_ptr;
            }
            loading_threads.appendAssumeCapacity(thread_db);
        }
        defer {
            // at this defer point, there are three memory components we care about
            // 1) the account references (AccountRef)
            // 2) the hashmap of refs (Map(Pubkey, *AccountRef))
            // and 3) the file maps Map(FileId, AccountFile)
            // each loading thread will have its own copy of these
            // what happens:
            // 2) and 3) will be copied into the main index thread and so we can deinit them
            // 1) will continue to exist on the heap and its ownership is given
            // the the main accounts-db index
            for (loading_threads.items) |*loading_thread| {
                // NOTE: deinit hashmap, dont close the files
                const file_map, var file_map_lg = self.file_map.writeWithLock();
                defer file_map_lg.unlock();
                file_map.deinit();
                // NOTE: important `false` (ie, 1))
                loading_thread.account_index.deinit(false);
            }
            loading_threads.deinit();
        }

        self.logger.infof("reading and indexing accounts...", .{});

        {
            var handles = std.ArrayList(std.Thread).init(self.allocator);
            defer {
                for (handles.items) |*h| h.join();
                handles.deinit();
            }
            try spawnThreadTasks(
                &handles,
                loadAndVerifyAccountsFilesMultiThread,
                .{
                    loading_threads.items,
                    filenames.items,
                    accounts_path,
                },
                filenames.items.len,
                n_parse_threads,
            );
        }

        self.logger.infof("total time: {s}", .{std.fmt.fmtDuration(timer.read())});
        timer.reset();

        self.logger.infof("combining thread accounts...", .{});
        try self.mergeMultipleDBs(loading_threads.items, n_combine_threads);
        self.logger.debugf("combining thread indexes took: {s}", .{std.fmt.fmtDuration(timer.read())});
        timer.reset();
    }

    /// multithread entrypoint into parseAndBinAccountFiles.
    /// Assumes that `loading_threads[thread_id].fields != null`.
    pub fn loadAndVerifyAccountsFilesMultiThread(
        loading_threads: []AccountsDB,
        filenames: [][]const u8,
        accounts_dir_path: []const u8,
        // task specific
        start_index: usize,
        end_index: usize,
        thread_id: usize,
    ) !void {
        const thread_db = &loading_threads[thread_id];
        const thread_filenames = filenames[start_index..end_index];

        try thread_db.loadAndVerifyAccountsFiles(
            accounts_dir_path,
            thread_filenames,
            ACCOUNTS_PER_FILE_EST,
            thread_id == 0,
        );
    }

    /// loads and verifies the account files into the threads file map
    /// and stores the accounts into the threads index
    /// Assumes `self.fields != null`.
    pub fn loadAndVerifyAccountsFiles(
        self: *Self,
        accounts_dir_path: []const u8,
        file_names: [][]const u8,
        accounts_per_file_est: usize,
        // when we multithread this function we only want to print on the first thread
        print_progress: bool,
    ) !void {
        std.debug.assert(self.fields != null);

        // NOTE: we can hold this lock for the entire function
        // because nothing else should be access the filemap
        // while loading from a snapshot
        const file_map, var file_map_lg = self.file_map.writeWithLock();
        defer file_map_lg.unlock();
        try file_map.ensureTotalCapacity(file_names.len);

        const bin_counts = try self.allocator.alloc(usize, self.account_index.numberOfBins());
        defer self.allocator.free(bin_counts);
        @memset(bin_counts, 0);

        // allocate all the references in one shot with a wrapper allocator
        // without this large allocation, snapshot loading is very slow
        var references = try ArrayList(AccountRef).initCapacity(
            self.account_index.reference_allocator,
            file_names.len * accounts_per_file_est,
        );
        const references_ptr = references.items.ptr;
        defer {
            // rn we dont support resizing - something went wrong if we resized
            std.debug.assert(references.items.ptr == references_ptr);
        }

        const counting_alloc_ptr = try self.allocator.create(CountingAllocator);
        counting_alloc_ptr.* = .{
            .deinit_self_allocator = self.allocator,
            .references = references,
            .alloc_count = 0,
        };

        // NOTE: might need to be longer depending on abs path length
        var buf: [1024]u8 = undefined;
        var timer = try std.time.Timer.start();
        var progress_timer = try std.time.Timer.start();

        try self.account_index.reference_memory.ensureTotalCapacity(@intCast(file_names.len));

        for (file_names, 1..) |file_name, file_count| {
            // parse "{slot}.{id}" from the file_name
            var fiter = std.mem.tokenizeSequence(u8, file_name, ".");
            const slot = std.fmt.parseInt(Slot, fiter.next().?, 10) catch |err| {
                self.logger.warnf("failed to parse slot from {s}", .{file_name});
                return err;
            };
            const file_id_usize = try std.fmt.parseInt(usize, fiter.next().?, 10);

            // read metadata
            const file_infos: ArrayList(AccountFileInfo) = self.fields.?.file_map.get(slot) orelse {
                // dont read account files which are not in the file_map
                // note: this can happen when we load from a snapshot and there are extra account files
                // in the directory which dont correspond to the snapshot were loading
                self.logger.warnf("failed to read metadata for slot {d}", .{slot});
                continue;
            };
            // if this is hit, its likely an old snapshot
            if (file_infos.items.len != 1) {
                std.debug.panic("incorrect file_info count for slot {d}, likley trying to load from an unsupported snapshot\n", .{slot});
            }
            const file_info = file_infos.items[0];
            if (file_info.id != file_id_usize) {
                std.debug.panic("file_info.id ({d}) != file_id ({d})\n", .{ file_info.id, file_id_usize });
            }

            // read accounts file
            const abs_path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ accounts_dir_path, file_name });
            const accounts_file_file = try std.fs.cwd().openFile(abs_path, .{ .mode = .read_write });
            var accounts_file = AccountFile.init(accounts_file_file, file_info, slot) catch |err| {
                std.debug.panic("failed to *open* AccountsFile {s}: {s}\n", .{ file_name, @errorName(err) });
            };

            const reference_slice_start = references.items.len;
            self.account_index.validateAccountFile(&accounts_file, bin_counts, &references) catch |err| {
                if (err == error.OutOfReferenceMemory) {
                    // TODO: support retry - panic for now
                    std.debug.panic(
                        "out of reference memory set ACCOUNTS_PER_FILE_EST larger and retry\n",
                        .{},
                    );
                }
                std.debug.panic("failed to *sanitize* AccountsFile: {d}.{d}: {s}\n", .{ accounts_file.slot, accounts_file.id, @errorName(err) });
            };

            const reference_slice_end = references.items.len;
            if (reference_slice_end > reference_slice_start) {
                const ref_slice = references.items[reference_slice_start..reference_slice_end];
                const ref_list = ArrayList(AccountRef).fromOwnedSlice(
                    // deinit allocator uses the counting allocator
                    counting_alloc_ptr.allocator(),
                    ref_slice,
                );
                counting_alloc_ptr.alloc_count += 1;
                try self.account_index.reference_memory.putNoClobber(slot, ref_list);
            }

            const file_id = FileId.fromInt(@intCast(file_id_usize));

            file_map.putAssumeCapacityNoClobber(file_id, RwMux(AccountFile).init(accounts_file));
            self.largest_file_id = FileId.max(self.largest_file_id, file_id);

            if (print_progress and progress_timer.read() > DB_PROGRESS_UPDATES_NS) {
                printTimeEstimate(
                    self.logger,
                    &timer,
                    file_names.len,
                    file_count,
                    "loading account files",
                    "thread0",
                );
                progress_timer.reset();
            }
        }

        // allocate enough memory for the bins
        var total_accounts: usize = 0;
        for (bin_counts, 0..) |count, bin_index| {
            if (count > 0) {
                try self.account_index.getBin(bin_index).ensureTotalCapacity(@intCast(count));
                total_accounts += count;
            }
        }

        // // NOTE: this is good for debugging what to set `accounts_per_file_est` to
        // std.debug.print("n_accounts vs estimated: {d} vs {d}", .{ total_accounts, n_accounts_est });

        // TODO: PERF: can probs be faster if you sort the pubkeys first, and then you know
        // it will always be a search for a free spot, and not search for a match

        var ref_count: usize = 0;
        timer.reset();
        var slot_iter = self.account_index.reference_memory.keyIterator();
        while (slot_iter.next()) |slot| {
            const refs = self.account_index.reference_memory.get(slot.*).?;
            for (refs.items) |*ref| {
                _ = self.account_index.indexRefIfNotDuplicateSlot(ref);
                ref_count += 1;
            }

            if (print_progress and progress_timer.read() > DB_PROGRESS_UPDATES_NS) {
                printTimeEstimate(
                    self.logger,
                    &timer,
                    total_accounts,
                    ref_count,
                    "building index",
                    null,
                );
                progress_timer.reset();
            }
        }
    }

    /// merges multiple thread accounts-dbs into self.
    /// index merging happens in parallel using `n_threads`.
    pub fn mergeMultipleDBs(
        self: *Self,
        thread_dbs: []AccountsDB,
        n_threads: usize,
    ) !void {
        var handles = std.ArrayList(std.Thread).init(self.allocator);
        defer {
            for (handles.items) |*h| h.join();
            handles.deinit();
        }
        try spawnThreadTasks(
            &handles,
            combineThreadIndexesMultiThread,
            .{
                self.logger,
                &self.account_index,
                thread_dbs,
            },
            self.account_index.numberOfBins(),
            n_threads,
        );

        // ensure enough capacity
        var m: u32 = 0;
        for (thread_dbs) |*thread_db| {
            m += thread_db.account_index.reference_memory.count();
        }
        try self.account_index.reference_memory.ensureTotalCapacity(m);

        // NOTE: nothing else should try to access the file_map
        // while we are merging so this long hold is ok.
        const file_map, var file_map_lg = self.file_map.writeWithLock();
        defer file_map_lg.unlock();

        for (thread_dbs) |*thread_db| {
            // combine file maps
            {
                var thread_file_map_lg = self.file_map.write();
                defer thread_file_map_lg.unlock();
                var thread_file_map: *FileMap = thread_file_map_lg.mut();

                var iter = thread_file_map.iterator();
                while (iter.next()) |entry| {
                    try file_map.putNoClobber(entry.key_ptr.*, entry.value_ptr.*);
                }
            }
            self.largest_file_id = FileId.max(self.largest_file_id, thread_db.largest_file_id);

            // combine underlying memory
            var ref_iter = thread_db.account_index.reference_memory.iterator();
            while (ref_iter.next()) |entry| {
                self.account_index.reference_memory.putAssumeCapacityNoClobber(
                    entry.key_ptr.*,
                    entry.value_ptr.*,
                );
            }
        }

        var largest_account_file_rw = file_map.get(self.largest_file_id).?;
        const largest_slot = largest_account_file_rw.readField("slot");
        self.largest_root_slot.store(largest_slot, .unordered);
    }

    /// combines multiple thread indexes into the given index.
    /// each bin is also sorted by pubkey.
    pub fn combineThreadIndexesMultiThread(
        logger: Logger,
        index: *AccountIndex,
        thread_dbs: []AccountsDB,
        // task specific
        bin_start_index: usize,
        bin_end_index: usize,
        thread_id: usize,
    ) !void {
        const total_bins = bin_end_index - bin_start_index;
        var timer = try std.time.Timer.start();
        var progress_timer = try std.time.Timer.start();
        const print_progress = thread_id == 0;

        for (bin_start_index..bin_end_index, 1..) |bin_index, iteration_count| {
            const index_bin = index.getBin(bin_index);

            // sum size across threads
            var bin_n_accounts: usize = 0;
            for (thread_dbs) |*thread_db| {
                bin_n_accounts += thread_db.account_index.getBin(bin_index).count();
            }
            // prealloc
            if (bin_n_accounts > 0) {
                try index_bin.ensureTotalCapacity(@intCast(bin_n_accounts));
            }

            for (thread_dbs) |*thread_db| {
                const thread_refs = thread_db.account_index.getBin(bin_index);
                // insert all of the thread entries into the main index
                var iter = thread_refs.iterator();
                while (iter.next()) |thread_entry| {
                    const thread_ref_ptr = thread_entry.value_ptr.*;
                    // NOTE: we dont have to check for duplicates because the duplicate
                    // slots have already been handled in the prev step
                    index.indexRef(thread_ref_ptr);
                }
            }

            if (print_progress and progress_timer.read() > DB_PROGRESS_UPDATES_NS) {
                printTimeEstimate(
                    logger,
                    &timer,
                    total_bins,
                    iteration_count,
                    "combining thread indexes",
                    "thread0",
                );
                progress_timer.reset();
            }
        }
    }

    pub const AccountHashesConfig = union(enum) {
        // compute hash from (..., max_slot]
        FullAccountHash: struct {
            max_slot: Slot,
        },
        // compute hash from (min_slot, ...)
        IncrementalAccountHash: struct {
            min_slot: Slot,
        },
    };

    /// computes a hash across all accounts in the db, and total lamports of those accounts
    /// using index data. depending on the config, this can compute
    /// either full or incremental snapshot values.
    pub fn computeAccountHashesAndLamports(self: *Self, config: AccountHashesConfig) !struct { accounts_hash: Hash, total_lamports: u64 } {
        var timer = try std.time.Timer.start();
        const n_threads = @as(u32, @truncate(try std.Thread.getCpuCount())) * 2;

        // alloc the result
        const hashes = try self.allocator.alloc(ArrayListUnmanaged(Hash), n_threads);
        defer self.allocator.free(hashes);

        @memset(hashes, .{});
        defer for (hashes) |*h| h.deinit(self.allocator);

        const lamports = try self.allocator.alloc(u64, n_threads);
        defer self.allocator.free(lamports);
        @memset(lamports, 0);

        // split processing the bins over muliple threads
        self.logger.infof("collecting hashes from accounts...", .{});

        {
            var handles = std.ArrayList(std.Thread).init(self.allocator);
            defer {
                for (handles.items) |*h| h.join();
                handles.deinit();
            }
            try spawnThreadTasks(
                &handles,
                getHashesFromIndexMultiThread,
                .{
                    self,
                    config,
                    self.allocator,
                    hashes,
                    lamports,
                },
                self.account_index.numberOfBins(),
                n_threads,
            );
        }

        self.logger.debugf("took: {s}", .{std.fmt.fmtDuration(timer.read())});
        timer.reset();

        self.logger.infof("computing the merkle root over accounts...", .{});
        var hash_tree = NestedHashTree{ .hashes = hashes };
        const accounts_hash = try hash_tree.computeMerkleRoot(MERKLE_FANOUT);
        self.logger.debugf("took {s}", .{std.fmt.fmtDuration(timer.read())});
        timer.reset();

        var total_lamports: u64 = 0;
        for (lamports) |lamport| {
            total_lamports += lamport;
        }

        return .{
            .accounts_hash = accounts_hash.*,
            .total_lamports = total_lamports,
        };
    }

    /// validates the accounts_db which was loaded from a snapshot (
    /// including the accounts hash and total lamports matches the expected values)
    pub fn validateLoadFromSnapshot(
        self: *Self,
        // used to verify the incremental snapshot
        incremental_snapshot_persistence: ?BankIncrementalSnapshotPersistence,
        // used to verify the full snapshot
        full_snapshot_slot: Slot,
        expected_full_lamports: u64,
    ) !void {
        const expected_accounts_hash = self.fields.?.bank_hash_info.accounts_hash;

        // validate the full snapshot
        self.logger.infof("validating the full snapshot", .{});
        const full_result = try self.computeAccountHashesAndLamports(AccountHashesConfig{
            .FullAccountHash = .{
                .max_slot = full_snapshot_slot,
            },
        });

        const total_lamports = full_result.total_lamports;
        const accounts_hash = full_result.accounts_hash;

        if (expected_accounts_hash.order(&accounts_hash) != .eq) {
            self.logger.errf(
                \\ incorrect accounts hash
                \\ expected vs calculated: {d} vs {d}
            , .{ expected_accounts_hash, accounts_hash });
            return error.IncorrectAccountsHash;
        }
        if (expected_full_lamports != total_lamports) {
            self.logger.errf(
                \\ incorrect total lamports
                \\ expected vs calculated: {d} vs {d}
            , .{ expected_full_lamports, total_lamports });
            return error.IncorrectTotalLamports;
        }

        // validate the incremental snapshot
        if (incremental_snapshot_persistence == null) return;
        self.logger.infof("validating the incremental snapshot", .{});
        const expected_accounts_delta_hash = incremental_snapshot_persistence.?.incremental_hash;
        const expected_incremental_lamports = incremental_snapshot_persistence.?.incremental_capitalization;

        const incremental_result = try self.computeAccountHashesAndLamports(AccountHashesConfig{
            .IncrementalAccountHash = .{
                .min_slot = full_snapshot_slot,
            },
        });
        const incremental_lamports = incremental_result.total_lamports;
        const accounts_delta_hash = incremental_result.accounts_hash;

        if (expected_incremental_lamports != incremental_lamports) {
            self.logger.errf(
                \\ incorrect incremental lamports
                \\ expected vs calculated: {d} vs {d}
            , .{ expected_incremental_lamports, incremental_lamports });
            return error.IncorrectIncrementalLamports;
        }

        if (expected_accounts_delta_hash.order(&accounts_delta_hash) != .eq) {
            self.logger.errf(
                \\ incorrect accounts delta hash
                \\ expected vs calculated: {d} vs {d}
            , .{ expected_accounts_delta_hash, accounts_delta_hash });
            return error.IncorrectAccountsDeltaHash;
        }
    }

    /// multithread entrypoint for getHashesFromIndex
    pub fn getHashesFromIndexMultiThread(
        self: *AccountsDB,
        config: AccountsDB.AccountHashesConfig,
        /// Allocator shared by all the arraylists in `hashes`.
        hashes_allocator: std.mem.Allocator,
        hashes: []ArrayListUnmanaged(Hash),
        total_lamports: []u64,
        // spawing thread specific params
        bin_start_index: usize,
        bin_end_index: usize,
        thread_index: usize,
    ) !void {
        try getHashesFromIndex(
            self,
            config,
            self.account_index.bins[bin_start_index..bin_end_index],
            hashes_allocator,
            &hashes[thread_index],
            &total_lamports[thread_index],
            thread_index == 0,
        );
    }

    /// populates the account hashes and total lamports for a given bin range
    /// from bin_start_index to bin_end_index.
    pub fn getHashesFromIndex(
        self: *AccountsDB,
        config: AccountsDB.AccountHashesConfig,
        thread_bins: []const AccountIndex.RefMap,
        hashes_allocator: std.mem.Allocator,
        hashes: *ArrayListUnmanaged(Hash),
        total_lamports: *u64,
        // when we multithread this function we only want to print on the first thread
        print_progress: bool,
    ) !void {
        var total_n_pubkeys: usize = 0;
        for (thread_bins) |*bin| {
            total_n_pubkeys += bin.count();
        }
        try hashes.ensureTotalCapacity(hashes_allocator, total_n_pubkeys);

        // well reuse this over time so this is ok (even if 1k is an under estimate)
        var keys = try self.allocator.alloc(Pubkey, 1_000);
        defer self.allocator.free(keys);

        var local_total_lamports: u64 = 0;
        var timer = try std.time.Timer.start();
        var progress_timer = try std.time.Timer.start();
        for (thread_bins, 1..) |*bin_ptr, count| {
            // get and sort pubkeys in bin
            const bin_refs = bin_ptr;
            const n_pubkeys_in_bin = bin_refs.count();
            if (n_pubkeys_in_bin == 0) {
                continue;
            }
            if (n_pubkeys_in_bin > keys.len) {
                if (!self.allocator.resize(keys, n_pubkeys_in_bin)) {
                    self.allocator.free(keys);
                    const new_keys = try self.allocator.alloc(Pubkey, n_pubkeys_in_bin);
                    keys.ptr = new_keys.ptr;
                    keys.len = new_keys.len;
                } else {
                    keys.len = n_pubkeys_in_bin;
                }
            }

            var i: usize = 0;
            var key_iter = bin_refs.iterator();
            while (key_iter.next()) |entry| {
                keys[i] = entry.key_ptr.*;
                i += 1;
            }
            const bin_pubkeys = keys[0..n_pubkeys_in_bin];

            std.mem.sort(Pubkey, bin_pubkeys, {}, struct {
                fn lessThan(_: void, lhs: Pubkey, rhs: Pubkey) bool {
                    return std.mem.lessThan(u8, &lhs.data, &rhs.data);
                }
            }.lessThan);

            // get the hashes
            for (bin_pubkeys) |key| {
                const ref_ptr = bin_refs.get(key).?;

                // get the most recent state of the account
                const max_slot_ref = switch (config) {
                    .FullAccountHash => |full_config| slotListMaxWithinBounds(ref_ptr, null, full_config.max_slot),
                    .IncrementalAccountHash => |inc_config| slotListMaxWithinBounds(ref_ptr, inc_config.min_slot, null),
                } orelse continue;
                const result = try self.getAccountHashAndLamportsFromRef(max_slot_ref);

                const lamports = result.lamports;
                var account_hash = result.hash;
                if (lamports == 0) {
                    switch (config) {
                        // for full snapshots, only include non-zero lamport accounts
                        .FullAccountHash => continue,
                        // zero-lamport accounts for incrementals = hash(pubkey)
                        .IncrementalAccountHash => Blake3.hash(&key.data, &account_hash.data, .{}),
                    }
                } else {
                    // hashes arent always stored correctly in snapshots
                    if (account_hash.order(&Hash.default()) == .eq) {
                        const account = try self.getAccountFromRef(max_slot_ref);
                        account_hash = account.hash(&key);
                    }
                }

                hashes.appendAssumeCapacity(account_hash);
                local_total_lamports += lamports;
            }

            if (print_progress and progress_timer.read() > DB_PROGRESS_UPDATES_NS) {
                printTimeEstimate(
                    self.logger,
                    &timer,
                    thread_bins.len,
                    count,
                    "gathering account hashes",
                    "thread0",
                );
                progress_timer.reset();
            }
        }
        total_lamports.* = local_total_lamports;
    }

    /// writes a batch of accounts to storage and updates the index
    pub fn putAccountBatch(
        self: *Self,
        accounts: []Account,
        pubkeys: []Pubkey,
        slot: Slot,
    ) !void {
        std.debug.assert(accounts.len == pubkeys.len);
        if (accounts.len == 0) return;

        {
            const account_cache, var account_cache_lg = self.account_cache.writeWithLock();
            defer account_cache_lg.unlock();
            // TODO: handle when slot already exists in the index
            try account_cache.putNoClobber(slot, .{ pubkeys, accounts });
        }

        // prealloc the bins
        const n_bins = self.account_index.numberOfBins();
        var bin_counts = try self.allocator.alloc(usize, n_bins);
        defer self.allocator.free(bin_counts);
        @memset(bin_counts, 0);

        for (pubkeys) |*pubkey| {
            const bin_index = self.account_index.getBinIndex(pubkey);
            bin_counts[bin_index] += 1;
        }

        for (0..n_bins) |bin_index| {
            const bin = self.account_index.getBin(bin_index);
            const new_len = bin_counts[bin_index] + bin.count();
            if (new_len > 0) {
                try bin.ensureTotalCapacity(@intCast(new_len));
            }
        }

        // update index
        const refs_ptr = try self.account_index.allocReferenceBlock(slot, accounts.len);
        for (0..accounts.len) |i| {
            const account_ref = AccountRef{
                .pubkey = pubkeys[i],
                .slot = slot,
                .location = .{ .Cache = .{ .index = i } },
            };
            refs_ptr.appendAssumeCapacity(account_ref);
            self.account_index.indexRef(&refs_ptr.items[i]);
        }
    }

    pub fn createAccountFile(self: *Self, size: usize, slot: Slot) !struct {
        std.fs.File,
        FileId,
        []u8,
    } {
        self.largest_file_id = self.largest_file_id.increment();
        const file_id = self.largest_file_id;

        const accounts_file_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/accounts/{d}.{d}",
            .{ self.config.snapshot_dir, slot, file_id.toInt() },
        );
        defer self.allocator.free(accounts_file_path);
        self.logger.infof("writing slot accounts file: {s} with {d} bytes", .{ accounts_file_path, size });

        const file = try std.fs.cwd().createFile(accounts_file_path, .{ .read = true });
        errdefer file.close();

        // resize the file
        const file_size = (try file.stat()).size;
        if (file_size < size) {
            try file.seekTo(size - 1);
            _ = try file.write(&[_]u8{1});
            try file.seekTo(0);
        }

        const memory = try std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            std.posix.MAP{ .TYPE = .SHARED },
            file.handle,
            0,
        );

        return .{ file, file_id, memory };
    }

    /// periodically runs flush/clean/shrink
    pub fn runManagerLoop(self: *Self) !void {
        // TODO: decide the best value for this
        const flush_slots_buf: [MAX_FLUSH_SLOTS_PER_ITER]Slot = undefined;
        var flush_slots = std.ArrayListUnmanaged(Slot).fromOwnedSlice(&flush_slots_buf);

        while (true) {
            var timer = try std.time.Timer.start();
            defer {
                const elapsed = timer.read();
                if (elapsed < DB_MANAGER_UPDATE_NS) {
                    const delay = DB_MANAGER_UPDATE_NS - elapsed;
                    std.time.sleep(delay);
                }
                timer.reset();
            }

            const root_slot = self.largest_root_slot.load(.unordered);

            // flush slots <= root slot
            {
                const account_cache, var account_cache_lg = self.account_cache.readWithLock();
                defer account_cache_lg.unlock();

                var cache_slot_iter = account_cache.keyIterator();
                while (cache_slot_iter.next()) |cache_slot| {
                    // at capacity - stop
                    if (flush_slots.items.len == flush_slots.capacity) break;
                    if (cache_slot <= root_slot) {
                        flush_slots.appendAssumeCapacity(cache_slot);
                    }
                }
            }

            for (flush_slots.items) |flush_slot| {
                self.flushSlot(flush_slot) catch |err| {
                    // flush fail = loss of account data on slot -- should never happen
                    std.debug.panic("flushing slot {d} error: {s}", .{ flush_slot, @errorName(err) });
                };
            }

            // clean the flushed slots account files
            if (flush_slots.items.len > 0) {
                self.cleanAccountFiles(root_slot);
            }

            self.shrinkAccountFiles();

            // TODO: check for files to delete
        }
    }

    /// flushes a slot account data from the cache onto disk, and updates the index
    /// note: this deallocates the []account and []pubkey data from the cache, as well
    /// as the data field ([]u8) for each account.
    pub fn flushSlot(self: *Self, slot: Slot) !void {
        const pubkeys, const accounts = blk: {
            const account_cache, var account_cache_lg = self.account_cache.writeWithLock();
            defer account_cache_lg.unlock();

            const pubkeys, const accounts = account_cache.get(slot) orelse return error.SlotNotFound;
            _ = account_cache.remove(slot);

            break :blk .{ pubkeys, accounts };
        };
        std.debug.assert(accounts.len == pubkeys.len);

        defer {
            self.allocator.free(pubkeys);
            for (accounts) |account| {
                self.allocator.free(account.data);
            }
            self.allocator.free(accounts);
        }

        // create account file which is big enough
        var size: usize = 0;
        for (accounts) |*account| {
            size += std.mem.alignForward(
                usize,
                AccountInFile.STATIC_SIZE + account.data.len,
                @sizeOf(u64),
            );
        }
        const file, const file_id, const memory = try self.createAccountFile(size, slot);

        // TODO: will likely need locks here when updating the references
        var offset: usize = 0;
        for (0..accounts.len) |i| {
            // update the reference
            const ref = self.account_index.getSlotReference(&pubkeys[i], slot) orelse unreachable;
            ref.location = .{ .File = .{ .file_id = file_id, .offset = offset } };

            // write the account to the file
            offset += accounts[i].writeToBuf(&pubkeys[i], memory[offset..]);
        }
        try file.sync();

        var account_file = try AccountFile.init(file, .{
            .id = @intCast(file_id.toInt()),
            .length = offset,
        }, slot);
        // fill in metadata such as alive_bytes, n_accounts, etc.
        // validation would fail because it may contain zero lamport accounts
        // TODO: maybe remove zero-lamports before flushing
        account_file.populateMetadata();

        // update the file map
        {
            const file_map, var file_map_lg = self.file_map.writeWithLock();
            defer file_map_lg.unlock();
            try file_map.putNoClobber(file_id, RwMux(AccountFile).init(account_file));
        }

        // queue for cleaning
        try self.unclean_account_files.append(file_id);
    }

    /// removes stale accounts and zero-lamport accounts from disk
    /// including removing the account from the index and updating the account files
    /// dead bytes. this also queues accounts for shrink or deletion if they contain
    /// a small number of 'alive' accounts.
    ///
    /// note: this method should not be called in parallel to shrink or delete.
    pub fn cleanAccountFiles(self: *Self, highest_rooted_slot: Slot) !struct {
        num_zero_lamports: usize,
        num_old_states: usize,
    } {
        defer self.unclean_account_files.clearRetainingCapacity();

        var num_zero_lamports: usize = 0;
        var num_old_states: usize = 0;

        // track then delete all to avoid deleting while iterating
        var references_to_delete = std.ArrayList(*AccountRef).init(self.allocator);
        defer references_to_delete.deinit();

        // track so we dont double delete
        var cleaned_pubkeys = std.AutoArrayHashMap(Pubkey, void).init(self.allocator);
        defer cleaned_pubkeys.deinit();

        for (self.unclean_account_files.items) |file_id| {
            // SAFE: this should always succeed or something is wrong

            // NOTE: reading account_files without a lock is safe
            // because only shrink or delete modifies the account files
            // in the file map (which never run in parallel to clean)
            var account_file_rw = blk: {
                const file_map, var file_map_lg = self.file_map.writeWithLock();
                defer file_map_lg.unlock();

                break :blk file_map.get(file_id).?;
            };

            // NOTE: this read-lock is held for a while but
            // is not expensive since modifications only happen
            // during shrink/delete
            const account_file, var account_file_lg = account_file_rw.readWithLock();
            defer account_file_lg.unlock();

            var account_iter = account_file.iterator();
            while (account_iter.next()) |account| {
                const pubkey = account.pubkey().*;

                // check if already cleaned
                if (cleaned_pubkeys.get(pubkey)) |_| continue;
                try cleaned_pubkeys.put(pubkey, {});

                // SAFE: this should always succeed or something is wrong
                const reference = self.account_index.getReference(&pubkey).?;

                // get the highest slot <= highest_rooted_slot
                var highest_ref_slot: usize = 0;
                var rooted_ref_count: usize = 0;
                var curr: ?*AccountRef = reference;
                while (curr) |ref| : (curr = ref.next_ptr) {
                    // only track states less than the rooted slot (ie, they are also rooted)
                    const is_not_rooted = ref.slot > highest_rooted_slot;
                    if (is_not_rooted) continue;

                    const is_larger_slot = ref.slot > highest_ref_slot or rooted_ref_count == 0;
                    if (is_larger_slot) {
                        highest_ref_slot = ref.slot;
                    }
                    rooted_ref_count += 1;
                }

                // short exit because nothing else to do
                if (rooted_ref_count == 0) continue;

                // if there are extra references, remove them
                curr = reference;
                while (curr) |ref| : (curr = ref.next_ptr) {
                    const is_not_rooted = ref.slot > highest_rooted_slot;
                    if (is_not_rooted) continue;

                    // the only reason to delete the highest ref is if it is zero-lamports
                    const is_highest_ref_slot = ref.slot == highest_ref_slot;
                    var is_zero_lamports = false;
                    if (is_highest_ref_slot) {
                        // check if account is zero-lamports
                        const ref_info = try self.getAccountHashAndLamportsFromRef(ref);
                        is_zero_lamports = ref_info.lamports == 0;
                    }

                    const is_old_state = ref.slot < highest_ref_slot;

                    if (is_old_state) num_old_states += 1;
                    if (is_zero_lamports) num_zero_lamports += 1;

                    const should_delete_ref = is_zero_lamports or is_old_state;
                    if (should_delete_ref) {
                        // queeue for deletion
                        try references_to_delete.append(ref);

                        // increment dead bytes
                        var ref_account = blk: {
                            if (ref.location.File.file_id == file_id) {
                                const account_in_file = try account_file.readAccount(
                                    ref.location.File.offset,
                                );
                                break :blk try account_in_file.toAccount().clone(self.allocator);
                            } else {
                                break :blk try self.getAccountInFile(
                                    ref.location.File.file_id,
                                    ref.location.File.offset,
                                );
                            }
                        };
                        defer ref_account.deinit(self.allocator);

                        var ref_account_length = AccountInFile.STATIC_SIZE + ref_account.data.len;
                        ref_account_length = std.mem.alignForward(usize, ref_account_length, @sizeOf(u64));
                        // SAFE: this is the **only** place where dead_bytes is modified
                        account_file_lg.private.v.dead_bytes += ref_account_length;
                        const dead_bytes = account_file_lg.private.v.dead_bytes;

                        const dead_percentage = dead_bytes * 100 / account_file.account_bytes;
                        if (dead_percentage == 100) {
                            // queue for delete
                            try self.delete_account_files.put(file_id, {});
                        } else if (dead_percentage >= ACCOUNT_FILE_SHRINK_THRESHOLD) {
                            // queue for shrink
                            try self.shrink_account_files.put(file_id, {});
                        }
                    }
                }

                // remove from index
                for (references_to_delete.items) |ref| {
                    try self.account_index.removeReference(&ref.pubkey, ref.slot);
                }
                references_to_delete.clearRetainingCapacity();
            }
        }

        return .{
            .num_zero_lamports = num_zero_lamports,
            .num_old_states = num_old_states,
        };
    }

    /// should only be called when all the accounts are dead (ie, no longer
    /// exist in the index).
    pub fn deleteAccountFiles(self: *Self) void {
        defer self.delete_account_files.clearRetainingCapacity();

        for (self.delete_account_files.keys()) |file_id| {
            var account_file_rw = blk: {
                const file_map, var file_map_lg = self.file_map.writeWithLock();
                defer file_map_lg.unlock();

                // remove file from map
                const account_file = file_map.get(file_id).?;
                _ = file_map.swapRemove(file_id);

                // return slot
                break :blk account_file;
            };

            const account_file, var account_file_lg = account_file_rw.writeWithLock();
            account_file.deinit();
            account_file_lg.unlock();

            // NOTE: this should always succeed or something is wrong
            // remove from map - delete file from disk
            self.deleteAccountFile(account_file.slot, file_id) catch |err| {
                self.logger.errf(
                    "failed to delete account file slot.file_id: {d}.{d}: {s}",
                    .{ account_file.slot, file_id.toInt(), @errorName(err) },
                );
            };
        }
    }

    pub fn deleteAccountFile(
        self: *const Self,
        slot: Slot,
        file_id: FileId,
    ) !void {
        const accounts_file_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/accounts/{d}.{d}",
            .{ self.config.snapshot_dir, slot, file_id.toInt() },
        );
        defer self.allocator.free(accounts_file_path);

        // ensure it exists before deleting
        std.fs.cwd().access(accounts_file_path, .{}) catch {
            self.logger.warnf("trying to delete accounts file which does not exist: {s}", .{accounts_file_path});
            return;
        };

        try std.fs.cwd().deleteFile(accounts_file_path);
    }

    /// resizes account files to reduce disk usage and remove dead accounts.
    pub fn shrinkAccountFiles(self: *Self) !struct { num_accounts_deleted: usize } {
        defer self.shrink_account_files.clearRetainingCapacity();

        var total_accounts_deleted: u64 = 0;
        for (self.shrink_account_files.keys()) |shrink_file_id| {
            var shrink_account_file_rw = blk: {
                const file_map, var file_map_lg = self.file_map.readWithLock();
                defer file_map_lg.unlock();

                break :blk file_map.get(shrink_file_id).?;
            };

            // compute size of alive accounts (read)
            const alive_accounts_size, const num_alive_accounts, const num_accounts_deleted, const slot = blk: {
                const shrink_account_file, var shrink_account_file_lg = shrink_account_file_rw.readWithLock();
                defer shrink_account_file_lg.unlock();

                var num_accounts_deleted: u64 = 0;
                var alive_accounts_size: u64 = 0;
                var num_alive_accounts: u64 = 0;
                var account_iter = shrink_account_file.iterator();
                while (account_iter.next()) |*account| {
                    const pubkey = account.pubkey();
                    // account is dead if it is not in the index; dead accounts
                    // are removed from the index during cleaning
                    const is_account_alive = self.account_index.getSlotReference(pubkey, shrink_account_file.slot) != null;
                    if (is_account_alive) {
                        alive_accounts_size += std.mem.alignForward(
                            usize,
                            AccountInFile.STATIC_SIZE + account.data.len,
                            @sizeOf(u64),
                        );
                        num_alive_accounts += 1;
                    } else {
                        num_accounts_deleted += 1;
                    }
                }
                // if there are no alive accounts, it should have been queued for deletion
                std.debug.assert(num_alive_accounts > 0);

                break :blk .{
                    alive_accounts_size,
                    num_alive_accounts,
                    num_accounts_deleted,
                    shrink_account_file.slot,
                };
            };
            total_accounts_deleted += num_accounts_deleted;

            // alloc account file for accounts
            const new_file, const new_file_id, const new_memory = try self.createAccountFile(
                alive_accounts_size,
                slot,
            );

            // alloc new reference memory block
            var new_ref_list = try ArrayList(AccountRef).initCapacity(
                self.account_index.reference_allocator,
                num_alive_accounts,
            );

            // update the index
            const file_length = blk: {
                const shrink_account_file, var shrink_account_file_lg = shrink_account_file_rw.readWithLock();
                defer shrink_account_file_lg.unlock();

                var account_iter = shrink_account_file.iterator();
                var offset: usize = 0;
                while (account_iter.next()) |*account| {
                    // write the alive accounts
                    if (self.account_index.getSlotReference(account.pubkey(), slot)) |old_ref_ptr| {
                        // copy + update the values
                        var new_ref = old_ref_ptr.*;
                        new_ref.location.File.offset = offset;
                        new_ref.location.File.file_id = new_file_id;
                        // copy the reference
                        new_ref_list.appendAssumeCapacity(new_ref);
                        // this is our new ptr value
                        const new_ref_ptr = &new_ref_list.items[new_ref_list.items.len - 1];

                        // update the reference value to be new_ref_ptr
                        const pubkey = account.pubkey();
                        const bin = self.account_index.getBinFromPubkey(pubkey);
                        // this is the old ptr value
                        // NOTE: we NEED a double pointer so that we can update it to *point* to the new value
                        // - this means either updating the hashmap pointer
                        // - or updating the linked list next_ptr field
                        const ref_ptr_ptr: **AccountRef = bin.getPtr(pubkey.*) orelse unreachable;

                        // base case: element is at the head
                        if (ref_ptr_ptr.*.slot == slot) {
                            // note: this is ok because new_ref_ptr has the same next_ptr already
                            ref_ptr_ptr.* = new_ref_ptr;
                        } else {
                            // other cases: element is not at the head - need to update next pointer
                            var prev_ptr = ref_ptr_ptr.*;
                            // SAFE: we know this next_ptr is non_null because `slot` is not at the head and must exist
                            var curr_ptr = prev_ptr.next_ptr.?;
                            while (true) {
                                if (curr_ptr.slot == slot) {
                                    // a -> b*
                                    prev_ptr.next_ptr = new_ref_ptr;
                                    // b* -> c
                                    new_ref_ptr.next_ptr = curr_ptr.next_ptr;
                                    break;
                                }
                                // SAFE: we know this next_ptr is non_null because `slot` was not found yet and must exist
                                prev_ptr = curr_ptr;
                                curr_ptr = curr_ptr.next_ptr.?;
                            }
                        }

                        // write to new account file
                        offset += account.writeToBuf(new_memory[offset..]);
                    }
                }
                break :blk offset;
            };

            // update slot's reference memory
            const ref_memory_entry = self.account_index.reference_memory.getEntry(slot) orelse {
                std.debug.panic("missing corresponding reference memory for slot {d}\n", .{slot});
            };
            // deinit old block of reference memory
            ref_memory_entry.value_ptr.deinit();
            // point to new block
            ref_memory_entry.value_ptr.* = new_ref_list;

            var new_account_file = try AccountFile.init(
                new_file,
                .{ .id = @intCast(new_file_id.toInt()), .length = file_length },
                slot,
            );
            new_account_file.populateMetadata();

            // update the file map
            {
                const file_map, var file_map_lg = self.file_map.writeWithLock();
                defer file_map_lg.unlock();

                const file_map_entry = file_map.getEntry(shrink_file_id).?;
                file_map_entry.value_ptr.* = RwMux(AccountFile).init(new_account_file);
                file_map_entry.key_ptr.* = new_file_id;
            }

            // delete old account file
            {
                const shrink_account_file, var shrink_account_file_lg = shrink_account_file_rw.writeWithLock();
                defer shrink_account_file_lg.unlock();
                shrink_account_file.deinit();
            }
            self.deleteAccountFile(slot, shrink_file_id) catch |err| {
                self.logger.errf(
                    "failed to delete account file slot.file_id: {d}.{d}: {s}",
                    .{ slot, shrink_file_id.toInt(), @errorName(err) },
                );
            };
        }

        return .{
            .num_accounts_deleted = total_accounts_deleted,
        };
    }

    /// remove all accounts and associated reference memory.
    /// note: should only be called on non-rooted slots (ie, slots which
    /// only exist in the cache, and not on disk).
    pub fn purgeSlot(self: *Self, slot: Slot, allocator: std.mem.Allocator) void {
        const pubkeys, const accounts = blk: {
            const account_cache, var account_cache_lg = self.account_cache.writeWithLock();
            defer account_cache_lg.unlock();

            const pubkeys, const accounts = account_cache.get(slot) orelse {
                // the way it works right now, account files only exist for rooted slots
                // rooted slots should never need to be purged so we should never get here
                @panic("purging an account file not supported");
            };
            _ = account_cache.remove(slot);

            break :blk .{ pubkeys, accounts };
        };

        // remove the account_ref from the index
        for (pubkeys) |*pubkey| {
            self.account_index.removeReference(pubkey, slot) catch |err| {
                switch (err) {
                    error.PubkeyNotFound => {
                        std.debug.panic("pubkey not found in index while purging: {any}", .{pubkey});
                    },
                    error.SlotNotFound => {
                        std.debug.panic(
                            "pubkey @ slot not found in index while purging: {any} @ {d}",
                            .{ pubkey, slot },
                        );
                    },
                }
            };
        }

        // free the account memory
        for (accounts) |*account| {
            allocator.free(account.data);
        }
        allocator.free(accounts);
        allocator.free(pubkeys);

        // free the reference memory
        self.account_index.freeReferenceBlock(slot) catch |err| {
            switch (err) {
                error.MemoryNotFound => {
                    std.debug.panic("memory block @ slot not found: {d}", .{slot});
                },
            }
        };
    }

    // NOTE: we need to acquire locks which requires `self: *Self` but we never modify any data
    pub fn getAccountFromRef(self: *Self, account_ref: *const AccountRef) !Account {
        switch (account_ref.location) {
            .File => |ref_info| {
                const account = try self.getAccountInFile(
                    ref_info.file_id,
                    ref_info.offset,
                );

                return account;
            },
            .Cache => |ref_info| {
                const account_cache, var account_cache_lg = self.account_cache.readWithLock();
                defer account_cache_lg.unlock();

                _, const accounts = account_cache.get(account_ref.slot) orelse return error.SlotNotFound;
                const account = accounts[ref_info.index];

                return account.clone(self.allocator);
            },
        }
    }

    /// gets an account given an file_id and offset value
    pub fn getAccountInFile(
        self: *Self,
        file_id: FileId,
        offset: usize,
    ) !Account {
        var account_file_rw: RwMux(AccountFile) = blk: {
            const file_map, var file_map_lg = self.file_map.readWithLock();
            defer file_map_lg.unlock();

            break :blk file_map.get(file_id) orelse {
                return error.FileIdNotFound;
            };
        };

        const account_file, var account_file_lg = account_file_rw.readWithLock();
        defer account_file_lg.unlock();

        // NOTE: if this happens, it may be because the shrink happened
        // here: we get account_file_rw
        // shrink: update file_map, deinit() account_file_rw, set length to zero
        // here: exists == false
        if (account_file.deinit_was_called) {
            return error.AccountFileEmpty;
        }
        const account_in_file = account_file.readAccount(offset) catch {
            return error.InvalidOffset;
        };
        const account = account_in_file.toAccount().clone(self.allocator);
        return account;
    }

    pub fn getAccountHashAndLamportsFromRef(
        self: *Self,
        account_ref: *const AccountRef,
    ) !struct { hash: Hash, lamports: u64 } {
        switch (account_ref.location) {
            .File => |ref_info| {
                var account_file_rw = blk: {
                    const file_map, var file_map_lg = self.file_map.readWithLock();
                    defer file_map_lg.unlock();

                    break :blk file_map.get(ref_info.file_id) orelse {
                        return error.FileIdNotFound;
                    };
                };

                const account_file, var account_file_lg = account_file_rw.readWithLock();
                defer account_file_lg.unlock();

                const result = account_file.getAccountHashAndLamports(
                    ref_info.offset,
                ) catch return error.InvalidOffset;

                return .{
                    .hash = result.hash.*,
                    .lamports = result.lamports.*,
                };
            },
            .Cache => |_| {
                // we dont use this method for cache
                return error.NotImplemented;
            },
        }
    }

    /// gets an account given an associated pubkey. mut ref is required for locks.
    pub fn getAccount(self: *Self, pubkey: *const Pubkey) !Account {
        const bin = self.account_index.getBinFromPubkey(pubkey);
        const ref = bin.get(pubkey.*) orelse return error.PubkeyNotInIndex;
        // NOTE: this will always be a safe unwrap since both bounds are null
        const max_ref = slotListMaxWithinBounds(ref, null, null).?;
        const account = try self.getAccountFromRef(max_ref);
        return account;
    }

    pub fn getTypeFromAccount(self: *Self, comptime T: type, pubkey: *const Pubkey) !T {
        var account = try self.getAccount(pubkey);
        defer account.deinit(self.allocator);

        const t = bincode.readFromSlice(self.allocator, T, account.data, .{}) catch {
            return error.DeserializationError;
        };
        return t;
    }

    pub fn getSlotHistory(self: *Self) !sysvars.SlotHistory {
        return try self.getTypeFromAccount(
            sysvars.SlotHistory,
            &sysvars.IDS.slot_history,
        );
    }

    pub fn putAccountFile(
        self: *Self,
        account_file: *AccountFile,
        n_accounts: usize,
    ) !void {
        const bin_counts = try self.allocator.alloc(usize, self.account_index.numberOfBins());
        defer self.allocator.free(bin_counts);
        @memset(bin_counts, 0);

        const refs_ptr = try self.account_index.allocReferenceBlock(account_file.slot, n_accounts);
        try self.account_index.validateAccountFile(account_file, bin_counts, refs_ptr);
        {
            const file_map, var file_map_lg = self.file_map.writeWithLock();
            defer file_map_lg.unlock();

            try file_map.put(
                FileId.fromInt(@intCast(account_file.id)),
                RwMux(AccountFile).init(account_file.*),
            );
        }

        // allocate enough memory here
        var total_accounts: usize = 0;
        for (bin_counts, 0..) |count, bin_index| {
            if (count > 0) {
                const bin = self.account_index.getBin(bin_index);
                try bin.ensureTotalCapacity(bin.count() + count);
                total_accounts += count;
            }
        }

        // compute how many account_references for each pubkey
        for (refs_ptr.items) |*ref| {
            self.account_index.indexRef(ref);
        }
    }

    pub inline fn slotListMaxWithinBounds(
        ref_ptr: *AccountRef,
        min_slot: ?Slot,
        max_slot: ?Slot,
    ) ?*AccountRef {
        var biggest: ?*AccountRef = null;
        if (inBoundsIf(ref_ptr.slot, min_slot, max_slot)) {
            biggest = ref_ptr;
        }

        var curr = ref_ptr;
        while (curr.next_ptr) |ref| {
            if (inBoundsIf(ref.slot, min_slot, max_slot) and (biggest == null or ref.slot > biggest.?.slot)) {
                biggest = ref;
            }
            curr = ref;
        }
        return biggest;
    }

    inline fn lessThanIf(
        slot: Slot,
        max_slot: ?Slot,
    ) bool {
        if (max_slot) |max| {
            if (slot <= max) {
                return true;
            } else {
                return false;
            }
        } else {
            return true;
        }
    }

    inline fn greaterThanIf(
        slot: Slot,
        min_slot: ?Slot,
    ) bool {
        if (min_slot) |min| {
            if (slot > min) {
                return true;
            } else {
                return false;
            }
        } else {
            return true;
        }
    }

    inline fn inBoundsIf(
        slot: Slot,
        min_slot: ?Slot,
        max_slot: ?Slot,
    ) bool {
        return lessThanIf(slot, max_slot) and greaterThanIf(slot, min_slot);
    }
};

/// allocator which frees the underlying arraylist after multiple free calls.
/// useful for when you want to allocate a large Arraylist and split it across
/// multiple different ArrayLists -- alloc and resize are not implemented.
const CountingAllocator = struct {
    /// optional heap allocator to deinit the ptr on deinit
    deinit_self_allocator: std.mem.Allocator,
    references: ArrayList(AccountRef),
    alloc_count: usize,

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return std.mem.Allocator{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    pub fn deinit(self: *CountingAllocator) void {
        // this shouldnt happen often but just in case
        if (self.alloc_count != 0) {
            std.debug.print(
                "Reference Counting Allocator deinit with count = {}\n",
                .{self.alloc_count},
            );
        }
        self.references.deinit();
        // free pointer
        self.deinit_self_allocator.destroy(self);
    }

    pub fn alloc(ctx: *anyopaque, n: usize, log2_align: u8, return_address: usize) ?[*]u8 {
        _ = ctx;
        _ = n;
        _ = log2_align;
        _ = return_address;
        @panic("not implemented");
    }

    pub fn resize(ctx: *anyopaque, buf: []u8, log2_align: u8, new_len: usize, return_address: usize) bool {
        _ = ctx;
        _ = buf;
        _ = log2_align;
        _ = new_len;
        _ = return_address;
        @panic("not implemented");
    }

    pub fn free(ctx: *anyopaque, buf: []u8, log2_align: u8, return_address: usize) void {
        _ = buf;
        _ = log2_align;
        _ = return_address;

        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.alloc_count -|= 1;
        if (self.alloc_count == 0) {
            self.deinit();
        }
    }
};

fn loadTestAccountsDB(allocator: std.mem.Allocator, use_disk: bool) !struct { AccountsDB, AllSnapshotFields } {
    const dir_path = "test_data";
    const dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });

    // unpack both snapshots to get the acccount files
    try parallelUnpackZstdTarBall(
        allocator,
        .noop,
        "test_data/snapshot-10-6ExseAZAVJsAZjhimxHTR7N8p6VGXiDNdsajYh1ipjAD.tar.zst",
        dir,
        1,
        true,
    );
    try parallelUnpackZstdTarBall(
        allocator,
        .noop,
        "test_data/incremental-snapshot-10-25-GXgKvm3NMAPgGdv2verVaNXmKTHQgfy2TAxLVEfAvdCS.tar.zst",
        dir,
        1,
        true,
    );

    var snapshot_files = try SnapshotFiles.find(allocator, dir_path);
    defer snapshot_files.deinit(allocator);

    var snapshots = try AllSnapshotFields.fromFiles(allocator, dir_path, snapshot_files);
    defer {
        allocator.free(snapshots.full_path);
        if (snapshots.incremental_path) |inc_path| {
            allocator.free(inc_path);
        }
    }

    const snapshot = try snapshots.all_fields.collapse();
    const logger = Logger{ .noop = {} };
    // var logger = Logger.init(std.heap.page_allocator, .debug);
    var accounts_db = try AccountsDB.init(allocator, logger, .{
        .num_index_bins = 4,
        .use_disk_index = use_disk,
        .snapshot_dir = "test_data/tmp",
    });

    const accounts_path = "test_data/accounts";
    try accounts_db.loadFromSnapshot(
        snapshot.accounts_db_fields,
        accounts_path,
        1,
        allocator,
    );

    return .{
        accounts_db,
        snapshots.all_fields,
    };
}

test "write and read an account" {
    const allocator = std.testing.allocator;

    var accounts_db, var snapshots = try loadTestAccountsDB(std.testing.allocator, false);
    defer {
        accounts_db.deinit(true);
        snapshots.deinit(allocator);
    }

    var rng = std.rand.DefaultPrng.init(0);
    const pubkey = Pubkey.random(rng.random());
    var data = [_]u8{ 1, 2, 3 };
    const test_account = Account{
        .data = &data,
        .executable = false,
        .lamports = 100,
        .owner = Pubkey.default(),
        .rent_epoch = 0,
    };

    // initial account
    var accounts = [_]Account{test_account};
    var pubkeys = [_]Pubkey{pubkey};
    try accounts_db.putAccountBatch(&accounts, &pubkeys, 19);

    var account = try accounts_db.getAccount(&pubkey);
    defer account.deinit(allocator);
    try std.testing.expect(test_account.equals(&account));

    // new account
    accounts[0].lamports = 20;
    try accounts_db.putAccountBatch(&accounts, &pubkeys, 28);
    var account_2 = try accounts_db.getAccount(&pubkey);
    defer account_2.deinit(allocator);
    try std.testing.expect(accounts[0].equals(&account_2));
}

test "load and validate from test snapshot using disk index" {
    const allocator = std.testing.allocator;

    var accounts_db, var snapshots = try loadTestAccountsDB(std.testing.allocator, false);
    defer {
        accounts_db.deinit(true);
        snapshots.deinit(allocator);
    }

    try accounts_db.validateLoadFromSnapshot(
        snapshots.incremental.?.bank_fields.incremental_snapshot_persistence,
        snapshots.full.bank_fields.slot,
        snapshots.full.bank_fields.capitalization,
    );
}

test "load and validate from test snapshot" {
    const allocator = std.testing.allocator;

    var accounts_db, var snapshots = try loadTestAccountsDB(std.testing.allocator, false);
    defer {
        accounts_db.deinit(true);
        snapshots.deinit(allocator);
    }

    try accounts_db.validateLoadFromSnapshot(
        snapshots.incremental.?.bank_fields.incremental_snapshot_persistence,
        snapshots.full.bank_fields.slot,
        snapshots.full.bank_fields.capitalization,
    );
}

test "load clock sysvar" {
    const allocator = std.testing.allocator;

    var accounts_db, var snapshots = try loadTestAccountsDB(std.testing.allocator, false);
    defer {
        accounts_db.deinit(true);
        snapshots.deinit(allocator);
    }

    const clock = try accounts_db.getTypeFromAccount(sysvars.Clock, &sysvars.IDS.clock);
    const expected_clock = sysvars.Clock{
        .slot = 25,
        .epoch_start_timestamp = 1702587901,
        .epoch = 0,
        .leader_schedule_epoch = 1,
        .unix_timestamp = 1702587915,
    };
    try std.testing.expectEqual(clock, expected_clock);
}

test "load other sysvars" {
    const allocator = std.testing.allocator;

    var accounts_db, var snapshots = try loadTestAccountsDB(std.testing.allocator, false);
    defer {
        accounts_db.deinit(true);
        snapshots.deinit(allocator);
    }

    const SlotAndHash = @import("./snapshots.zig").SlotAndHash;
    _ = try accounts_db.getTypeFromAccount(sysvars.EpochSchedule, &sysvars.IDS.epoch_schedule);
    _ = try accounts_db.getTypeFromAccount(sysvars.Rent, &sysvars.IDS.rent);
    _ = try accounts_db.getTypeFromAccount(SlotAndHash, &sysvars.IDS.slot_hashes);
    _ = try accounts_db.getTypeFromAccount(sysvars.StakeHistory, &sysvars.IDS.stake_history);

    const slot_history = try accounts_db.getTypeFromAccount(sysvars.SlotHistory, &sysvars.IDS.slot_history);
    defer bincode.free(allocator, slot_history);

    // // not always included in local snapshot
    // _ = try accounts_db.getTypeFromAccount(sysvars.LastRestartSlot, &sysvars.IDS.last_restart_slot);
    // _ = try accounts_db.getTypeFromAccount(sysvars.EpochRewards, &sysvars.IDS.epoch_rewards);
}

test "flushing slots works" {
    const allocator = std.testing.allocator;
    const logger = Logger{ .noop = {} };
    var accounts_db = try AccountsDB.init(allocator, logger, .{
        .num_index_bins = 4,
        .snapshot_dir = "test_data",
    });
    defer accounts_db.deinit(true);

    var random = std.rand.DefaultPrng.init(19);
    const rng = random.random();
    const n_accounts = 3;

    // we dont defer deinit to make sure that they are cleared on purge
    var pubkeys = try allocator.alloc(Pubkey, n_accounts);
    var accounts = try allocator.alloc(Account, n_accounts);
    for (0..n_accounts) |i| {
        pubkeys[i] = Pubkey.random(rng);
        accounts[i] = try Account.random(allocator, rng, i % 1_000);
    }

    // this gets written to cache
    const slot = @as(u64, @intCast(200));
    try accounts_db.putAccountBatch(
        accounts,
        pubkeys,
        slot,
    );

    // this writes to disk
    try accounts_db.flushSlot(slot);

    // try the validation
    const file_map, var file_map_lg = accounts_db.file_map.readWithLock();
    defer file_map_lg.unlock();

    const file_id = file_map.keys()[0];
    var account_file_rw = file_map.get(file_id).?;

    var account_file_lg = account_file_rw.write();
    defer account_file_lg.unlock();
    const account_file = account_file_lg.mut();
    try account_file.validate();

    try std.testing.expect(account_file.number_of_accounts == n_accounts);

    try std.testing.expect(accounts_db.unclean_account_files.items.len == 1);
    try std.testing.expect(accounts_db.unclean_account_files.items[0] == file_id);
}

test "purge accounts in cache works" {
    const allocator = std.testing.allocator;
    const logger = Logger{ .noop = {} };
    var accounts_db = try AccountsDB.init(allocator, logger, .{
        .num_index_bins = 4,
    });
    defer accounts_db.deinit(true);

    var random = std.rand.DefaultPrng.init(19);
    const rng = random.random();
    const n_accounts = 3;

    // we dont defer deinit to make sure that they are cleared on purge
    var pubkeys = try allocator.alloc(Pubkey, n_accounts);
    var accounts = try allocator.alloc(Account, n_accounts);

    for (0..n_accounts) |i| {
        pubkeys[i] = Pubkey.random(rng);
        accounts[i] = try Account.random(allocator, rng, i % 1_000);
    }

    const pubkey_copy = try allocator.alloc(Pubkey, n_accounts);
    defer allocator.free(pubkey_copy);
    @memcpy(pubkey_copy, pubkeys);

    const slot = @as(u64, @intCast(200));
    try accounts_db.putAccountBatch(
        accounts,
        pubkeys,
        slot,
    );

    for (0..n_accounts) |i| {
        try std.testing.expect(
            accounts_db.account_index.getReference(&pubkeys[i]) != null,
        );
    }

    accounts_db.purgeSlot(slot, allocator);

    // ref backing memory is cleared
    try std.testing.expect(accounts_db.account_index.reference_memory.count() == 0);
    // account cache is cleared
    {
        var lg = accounts_db.account_cache.read();
        defer lg.unlock();
        try std.testing.expect(lg.get().count() == 0);
    }

    // ref hashmap is cleared
    for (0..n_accounts) |i| {
        try std.testing.expect(accounts_db.account_index.getReference(&pubkey_copy[i]) == null);
    }
}

test "clean to shrink account file works with zero-lamports" {
    const allocator = std.testing.allocator;
    const logger = Logger{ .noop = {} };
    var accounts_db = try AccountsDB.init(allocator, logger, .{
        .num_index_bins = 4,
        .snapshot_dir = "test_data",
    });
    defer accounts_db.deinit(true);

    var random = std.rand.DefaultPrng.init(19);
    const rng = random.random();
    const n_accounts = 10;

    // generate the account file for slot 0
    const pubkeys = try allocator.alloc(Pubkey, n_accounts);
    const accounts = try allocator.alloc(Account, n_accounts);
    for (0..n_accounts) |i| {
        pubkeys[i] = Pubkey.random(rng);
        accounts[i] = try Account.random(allocator, rng, 100);
    }
    const slot = @as(u64, @intCast(200));
    try accounts_db.putAccountBatch(
        accounts,
        pubkeys,
        slot,
    );

    // test to make sure we can still read it
    const pubkey_remain = pubkeys[pubkeys.len - 1];

    // duplicate some before the flush/deinit
    const new_len = n_accounts - 1; // one new root with zero lamports
    const pubkeys2 = try allocator.alloc(Pubkey, new_len);
    const accounts2 = try allocator.alloc(Account, new_len);
    @memcpy(pubkeys2, pubkeys[0..new_len]);
    for (0..new_len) |i| {
        accounts2[i] = try Account.random(allocator, rng, i % 1_000);
        accounts2[i].lamports = 0; // !
    }
    try accounts_db.flushSlot(slot);

    // write new state
    const new_slot = @as(u64, @intCast(500));
    try accounts_db.putAccountBatch(
        accounts2,
        pubkeys2,
        new_slot,
    );
    try accounts_db.flushSlot(new_slot);

    const r = try accounts_db.cleanAccountFiles(new_slot + 100);
    try std.testing.expect(r.num_old_states == new_len);
    try std.testing.expect(r.num_zero_lamports == new_len);
    // shrink
    try std.testing.expect(accounts_db.shrink_account_files.count() == 1);
    try std.testing.expect(accounts_db.delete_account_files.count() == 0);

    var account = try accounts_db.getAccount(&pubkey_remain);
    defer account.deinit(allocator);
}

test "clean to shrink account file works" {
    const allocator = std.testing.allocator;
    const logger = Logger{ .noop = {} };
    var accounts_db = try AccountsDB.init(allocator, logger, .{
        .num_index_bins = 4,
        .snapshot_dir = "test_data",
    });
    defer accounts_db.deinit(true);

    var random = std.rand.DefaultPrng.init(19);
    const rng = random.random();
    const n_accounts = 10;

    // generate the account file for slot 0
    const pubkeys = try allocator.alloc(Pubkey, n_accounts);
    const accounts = try allocator.alloc(Account, n_accounts);
    for (0..n_accounts) |i| {
        pubkeys[i] = Pubkey.random(rng);
        accounts[i] = try Account.random(allocator, rng, 100);
    }
    const slot = @as(u64, @intCast(200));
    try accounts_db.putAccountBatch(
        accounts,
        pubkeys,
        slot,
    );

    // duplicate HALF before the flush/deinit
    const new_len = n_accounts - 1; // 90% delete = shrink
    const pubkeys2 = try allocator.alloc(Pubkey, new_len);
    const accounts2 = try allocator.alloc(Account, new_len);
    @memcpy(pubkeys2, pubkeys[0..new_len]);
    for (0..new_len) |i| {
        accounts2[i] = try Account.random(allocator, rng, i % 1_000);
    }
    try accounts_db.flushSlot(slot);

    // write new state
    const new_slot = @as(u64, @intCast(500));
    try accounts_db.putAccountBatch(
        accounts2,
        pubkeys2,
        new_slot,
    );
    try accounts_db.flushSlot(new_slot);

    const r = try accounts_db.cleanAccountFiles(new_slot + 100);
    try std.testing.expect(r.num_old_states == new_len);
    try std.testing.expect(r.num_zero_lamports == 0);
    // shrink
    try std.testing.expect(accounts_db.shrink_account_files.count() == 1);
    try std.testing.expect(accounts_db.delete_account_files.count() == 0);
}

test "full clean account file works" {
    const allocator = std.testing.allocator;
    const logger = Logger{ .noop = {} };
    var accounts_db = try AccountsDB.init(allocator, logger, .{
        .num_index_bins = 4,
        .snapshot_dir = "test_data",
    });
    defer accounts_db.deinit(true);

    var random = std.rand.DefaultPrng.init(19);
    const rng = random.random();
    const n_accounts = 3;

    // generate the account file for slot 0
    const pubkeys = try allocator.alloc(Pubkey, n_accounts);
    const accounts = try allocator.alloc(Account, n_accounts);
    for (0..n_accounts) |i| {
        pubkeys[i] = Pubkey.random(rng);
        accounts[i] = try Account.random(allocator, rng, i % 1_000);
    }
    const slot = @as(u64, @intCast(200));
    try accounts_db.putAccountBatch(
        accounts,
        pubkeys,
        slot,
    );

    // duplicate before the flush/deinit
    const pubkeys2 = try allocator.alloc(Pubkey, n_accounts);
    const accounts2 = try allocator.alloc(Account, n_accounts);
    @memcpy(pubkeys2, pubkeys);
    for (0..n_accounts) |i| {
        accounts2[i] = try Account.random(allocator, rng, i % 1_000);
    }

    try accounts_db.flushSlot(slot);

    var r = try accounts_db.cleanAccountFiles(0); // zero is rooted so no files should be cleaned
    try std.testing.expect(r.num_old_states == 0);
    try std.testing.expect(r.num_zero_lamports == 0);

    r = try accounts_db.cleanAccountFiles(1); // zero has no old state so no files should be cleaned
    try std.testing.expect(r.num_old_states == 0);
    try std.testing.expect(r.num_zero_lamports == 0);

    // write new state
    const new_slot = @as(u64, @intCast(500));
    try accounts_db.putAccountBatch(
        accounts2,
        pubkeys2,
        new_slot,
    );
    try accounts_db.flushSlot(new_slot);

    r = try accounts_db.cleanAccountFiles(new_slot + 100);
    try std.testing.expect(r.num_old_states == n_accounts);
    try std.testing.expect(r.num_zero_lamports == 0);
    // full delete
    try std.testing.expect(accounts_db.delete_account_files.count() == 1);

    // test delete
    {
        const file_map, var file_map_lg = accounts_db.file_map.readWithLock();
        defer file_map_lg.unlock();
        try std.testing.expect(file_map.get(FileId.fromInt(2)) != null);
    }

    accounts_db.deleteAccountFiles();

    {
        const file_map, var file_map_lg = accounts_db.file_map.readWithLock();
        defer file_map_lg.unlock();
        try std.testing.expect(file_map.get(FileId.fromInt(2)) == null);
    }
}

test "shrink account file works" {
    const allocator = std.testing.allocator;
    const logger = Logger{ .noop = {} };
    var accounts_db = try AccountsDB.init(allocator, logger, .{
        .num_index_bins = 4,
        .snapshot_dir = "test_data",
    });
    defer accounts_db.deinit(true);

    var random = std.rand.DefaultPrng.init(19);
    const rng = random.random();
    const n_accounts = 10;

    // generate the account file for slot 0
    const pubkeys = try allocator.alloc(Pubkey, n_accounts);
    const accounts = try allocator.alloc(Account, n_accounts);
    for (0..n_accounts) |i| {
        pubkeys[i] = Pubkey.random(rng);
        accounts[i] = try Account.random(allocator, rng, 100);
    }

    const slot = @as(u64, @intCast(200));
    try accounts_db.putAccountBatch(
        accounts,
        pubkeys,
        slot,
    );

    // test to make sure we can still read it
    const pubkey_remain = pubkeys[pubkeys.len - 1];

    // duplicate some before the flush/deinit
    const new_len = n_accounts - 1; // 90% delete = shrink
    const pubkeys2 = try allocator.alloc(Pubkey, new_len);
    const accounts2 = try allocator.alloc(Account, new_len);
    @memcpy(pubkeys2, pubkeys[0..new_len]);
    for (0..new_len) |i| {
        accounts2[i] = try Account.random(allocator, rng, i % 1_000);
    }
    try accounts_db.flushSlot(slot);

    // write new state
    const new_slot = @as(u64, @intCast(500));
    try accounts_db.putAccountBatch(
        accounts2,
        pubkeys2,
        new_slot,
    );
    try accounts_db.flushSlot(new_slot);

    // clean the account files - slot is queued for shrink
    _ = try accounts_db.cleanAccountFiles(new_slot + 100);
    try std.testing.expect(accounts_db.shrink_account_files.count() == 1);

    const file_map, var file_map_lg = accounts_db.file_map.readWithLock();
    const slot_file_id: FileId = for (file_map.keys()) |file_id| {
        var account_file_rw = file_map.get(file_id).?;
        if (account_file_rw.readField("slot") == slot) {
            break file_id;
        }
    } else return error.NoSlotFile;
    var v = file_map.get(slot_file_id).?;
    const pre_shrink_size = v.readField("file_size");
    file_map_lg.unlock();

    // full memory block
    const ref_mem = accounts_db.account_index.reference_memory.get(new_slot).?;
    try std.testing.expect(ref_mem.items.len == accounts2.len);

    // test: files were shrunk
    const r = try accounts_db.shrinkAccountFiles();
    try std.testing.expect(accounts_db.shrink_account_files.count() == 0);
    try std.testing.expect(r.num_accounts_deleted == 9);

    // test: new account file is shrunk
    const file_map2, var file_map_lg2 = accounts_db.file_map.readWithLock();
    defer file_map_lg2.unlock();

    const new_slot_file_id: FileId = for (file_map2.keys()) |file_id| {
        var account_file_rw = file_map2.get(file_id).?;
        if (account_file_rw.readField("slot") == slot) {
            break file_id;
        }
    } else return error.NoSlotFile;
    var new_account_file = file_map2.get(new_slot_file_id).?;
    const post_shrink_size = new_account_file.readField("file_size");
    try std.testing.expect(post_shrink_size < pre_shrink_size);

    // test: memory block is shrunk too
    const ref_mem_small = accounts_db.account_index.reference_memory.get(slot).?;
    try std.testing.expectEqual(1, ref_mem_small.items.len);

    // last account ref should still be accessible
    var account = try accounts_db.getAccount(&pubkey_remain);
    account.deinit(allocator);
}

pub const BenchmarkAccountsDBSnapshotLoad = struct {
    pub const min_iterations = 1;
    pub const max_iterations = 1;

    pub const BenchArgs = struct {
        use_disk: bool,
        n_threads: u32,
        name: []const u8,
    };

    pub const args = [_]BenchArgs{
        BenchArgs{
            .use_disk = false,
            .n_threads = 2,
            .name = "RAM (2 threads)",
        },
        BenchArgs{
            .use_disk = true,
            .n_threads = 2,
            .name = "DISK (2 threads)",
        },
    };

    pub fn loadSnapshot(bench_args: BenchArgs) !u64 {
        const allocator = std.heap.page_allocator;

        // unpack the snapshot
        // NOTE: usually this will be an incremental snapshot
        // renamed as a full snapshot (mv {inc-snap-fmt}.tar.zstd {full-snap-fmt}.tar.zstd)
        // (because test snapshots are too small and full snapshots are too big)
        const dir_path = "test_data/bench_snapshot/";
        const accounts_path = dir_path ++ "accounts";

        // const logger = Logger{ .noop = {} };
        const logger = Logger.init(allocator, .debug);
        defer logger.deinit();
        logger.spawn();

        const snapshot_dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
            std.debug.print("need to setup a snapshot in {s} for this benchmark...\n", .{dir_path});
            return 0;
        };

        var snapshot_files = try SnapshotFiles.find(allocator, dir_path);
        defer snapshot_files.deinit(allocator);

        std.fs.cwd().access(accounts_path, .{}) catch {
            try parallelUnpackZstdTarBall(
                allocator,
                logger,
                snapshot_files.full_snapshot.filename,
                snapshot_dir,
                try std.Thread.getCpuCount() / 2,
                true,
            );
        };

        var snapshots = try AllSnapshotFields.fromFiles(allocator, dir_path, snapshot_files);
        defer {
            allocator.free(snapshots.full_path);
            if (snapshots.incremental_path) |inc_path| {
                allocator.free(inc_path);
            }
        }
        const snapshot = try snapshots.all_fields.collapse();

        var accounts_db = try AccountsDB.init(allocator, logger, .{
            .num_index_bins = 32,
            .use_disk_index = bench_args.use_disk,
            .snapshot_dir = dir_path,
        });
        // defer accounts_db.deinit(false);

        var timer = try std.time.Timer.start();
        try accounts_db.loadFromSnapshot(
            snapshot.accounts_db_fields,
            accounts_path,
            bench_args.n_threads,
            allocator,
        );
        const elapsed = timer.read();

        // sanity check
        const r = try accounts_db.computeAccountHashesAndLamports(.{ .FullAccountHash = .{
            .max_slot = accounts_db.largest_root_slot.raw,
        } });
        std.debug.print("r: {any}\n", .{r});

        return elapsed;
    }
};

pub const BenchmarkAccountsDB = struct {
    pub const min_iterations = 1;
    pub const max_iterations = 1;

    pub const MemoryType = enum {
        ram,
        disk,
    };

    pub const BenchArgs = struct {
        /// the number of accounts to store in the database (for each slot)
        n_accounts: usize,
        /// the number of slots to store (each slot is one batch write)
        slot_list_len: usize,
        /// the accounts memory type (ram (as a ArrayList) or disk (as a file))
        accounts: MemoryType,
        /// the index memory type (ram or disk (disk-memory allocator))
        index: MemoryType,
        /// the number of accounts to prepopulate the index with as a multiple of n_accounts
        /// ie, if n_accounts = 100 and n_accounts_multiple = 10, then the index will have 10x100=1000 accounts prepopulated
        n_accounts_multiple: usize = 0,
        /// the name of the benchmark
        name: []const u8 = "",
    };

    pub const args = [_]BenchArgs{
        BenchArgs{
            .n_accounts = 100_000,
            .slot_list_len = 1,
            .accounts = .ram,
            .index = .ram,
            .name = "100k accounts (1_slot - ram index - ram accounts)",
        },
        BenchArgs{
            .n_accounts = 100_000,
            .slot_list_len = 1,
            .accounts = .ram,
            .index = .disk,
            .name = "100k accounts (1_slot - disk index - ram accounts)",
        },
        BenchArgs{
            .n_accounts = 100_000,
            .slot_list_len = 1,
            .accounts = .disk,
            .index = .ram,
            .name = "100k accounts (1_slot - ram index - disk accounts)",
        },
        BenchArgs{
            .n_accounts = 100_000,
            .slot_list_len = 1,
            .accounts = .disk,
            .index = .disk,
            .name = "100k accounts (1_slot - disk index - disk accounts)",
        },

        // // test accounts in ram
        // BenchArgs{
        //     .n_accounts = 100_000,
        //     .slot_list_len = 1,
        //     .accounts = .ram,
        //     .index = .ram,
        //     .name = "100k accounts (1_slot - ram index - ram accounts)",
        // },
        // BenchArgs{
        //     .n_accounts = 10_000,
        //     .slot_list_len = 10,
        //     .accounts = .ram,
        //     .index = .ram,
        //     .name = "10k accounts (10_slots - ram index - ram accounts)",
        // },

        // // tests large number of accounts on disk
        // BenchArgs{
        //     .n_accounts = 10_000,
        //     .slot_list_len = 10,
        //     .accounts = .disk,
        //     .index = .ram,
        //     .name = "10k accounts (10_slots - ram index - disk accounts)",
        // },
        // BenchArgs{
        //     .n_accounts = 500_000,
        //     .slot_list_len = 1,
        //     .accounts = .disk,
        //     .index = .ram,
        //     .name = "500k accounts (1_slot - ram index - disk accounts)",
        // },
        // BenchArgs{
        //     .n_accounts = 500_000,
        //     .slot_list_len = 3,
        //     .accounts = .disk,
        //     .index = .ram,
        //     .name = "500k accounts (3_slot - ram index - disk accounts)",
        // },
        // BenchArgs{
        //     .n_accounts = 3_000_000,
        //     .slot_list_len = 1,
        //     .accounts = .disk,
        //     .index = .ram,
        //     .name = "3M accounts (1_slot - ram index - disk accounts)",
        // },
        // BenchArgs{
        //     .n_accounts = 3_000_000,
        //     .slot_list_len = 3,
        //     .accounts = .disk,
        //     .index = .ram,
        //     .name = "3M accounts (3_slot - ram index - disk accounts)",
        // },
        // BenchArgs{
        //     .n_accounts = 500_000,
        //     .slot_list_len = 1,
        //     .accounts = .disk,
        //     .n_accounts_multiple = 2, // 1 mill accounts init
        //     .index = .ram,
        //     .name = "3M accounts (3_slot - ram index - disk accounts)",
        // },

        // // testing disk indexes
        // BenchArgs{
        //     .n_accounts = 500_000,
        //     .slot_list_len = 1,
        //     .accounts = .disk,
        //     .index = .disk,
        //     .name = "500k accounts (1_slot - disk index - disk accounts)",
        // },
        // BenchArgs{
        //     .n_accounts = 3_000_000,
        //     .slot_list_len = 1,
        //     .accounts = .disk,
        //     .index = .disk,
        //     .name = "3m accounts (1_slot - disk index - disk accounts)",
        // },
        // BenchArgs{
        //     .n_accounts = 500_000,
        //     .slot_list_len = 1,
        //     .accounts = .disk,
        //     .index = .disk,
        //     .n_accounts_multiple = 2,
        //     .name = "500k accounts (1_slot - disk index - disk accounts)",
        // },
    };

    pub fn readAccounts(bench_args: BenchArgs) !u64 {
        const n_accounts = bench_args.n_accounts;
        const slot_list_len = bench_args.slot_list_len;
        const total_n_accounts = n_accounts * slot_list_len;

        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        var allocator = gpa.allocator();

        const disk_path = "test_data/tmp/";
        std.fs.cwd().makeDir(disk_path) catch {};

        const logger = Logger{ .noop = {} };
        var accounts_db: AccountsDB = undefined;
        if (bench_args.index == .disk) {
            accounts_db = try AccountsDB.init(allocator, logger, .{
                .use_disk_index = true,
            });
        } else {
            accounts_db = try AccountsDB.init(allocator, logger, .{});
        }
        defer accounts_db.deinit(true);

        var random = std.rand.DefaultPrng.init(19);
        const rng = random.random();

        var pubkeys = try allocator.alloc(Pubkey, n_accounts);
        defer allocator.free(pubkeys);
        for (0..n_accounts) |i| {
            pubkeys[i] = Pubkey.random(rng);
        }

        var all_filenames = try ArrayList([]const u8).initCapacity(allocator, slot_list_len + bench_args.n_accounts_multiple);
        defer all_filenames.deinit();
        defer {
            for (all_filenames.items) |filepath| {
                std.fs.cwd().deleteFile(filepath) catch {
                    std.debug.print("failed to delete file: {s}\n", .{filepath});
                };
            }
        }

        if (bench_args.accounts == .ram) {
            const n_accounts_init = bench_args.n_accounts_multiple * bench_args.n_accounts;
            var accounts = try allocator.alloc(Account, (total_n_accounts + n_accounts_init));
            for (0..(total_n_accounts + n_accounts_init)) |i| {
                accounts[i] = try Account.random(allocator, rng, i % 1_000);
            }

            if (n_accounts_init > 0) {
                try accounts_db.putAccountBatch(
                    accounts[total_n_accounts..(total_n_accounts + n_accounts_init)],
                    pubkeys,
                    @as(u64, @intCast(0)),
                );
            }

            var timer = try std.time.Timer.start();
            for (0..slot_list_len) |i| {
                const start_index = i * n_accounts;
                const end_index = start_index + n_accounts;
                try accounts_db.putAccountBatch(
                    accounts[start_index..end_index],
                    pubkeys,
                    @as(u64, @intCast(i)),
                );
            }
            const elapsed = timer.read();
            std.debug.print("WRITE: {d}\n", .{elapsed});
        } else {
            var account_files = try ArrayList(AccountFile).initCapacity(allocator, slot_list_len);
            defer account_files.deinit();

            for (0..(slot_list_len + bench_args.n_accounts_multiple)) |s| {
                var size: usize = 0;
                for (0..total_n_accounts) |i| {
                    const data_len = i % 1_000;
                    size += std.mem.alignForward(
                        usize,
                        AccountInFile.STATIC_SIZE + data_len,
                        @sizeOf(u64),
                    );
                }
                const aligned_size = std.mem.alignForward(usize, size, std.mem.page_size);
                const filepath = try std.fmt.allocPrint(allocator, disk_path ++ "slot{d}.bin", .{s});

                const length = blk: {
                    var file = try std.fs.cwd().createFile(filepath, .{ .read = true });
                    defer file.close();

                    // resize the file
                    const file_size = (try file.stat()).size;
                    if (file_size < aligned_size) {
                        try file.seekTo(aligned_size - 1);
                        _ = try file.write(&[_]u8{1});
                        try file.seekTo(0);
                    }

                    var memory = try std.posix.mmap(
                        null,
                        aligned_size,
                        std.posix.PROT.READ | std.posix.PROT.WRITE,
                        std.posix.MAP{ .TYPE = .SHARED }, // need it written to the file before it can be used
                        file.handle,
                        0,
                    );

                    var offset: usize = 0;
                    for (0..n_accounts) |i| {
                        const account = try Account.random(allocator, rng, i % 1_000);
                        defer allocator.free(account.data);
                        var pubkey = pubkeys[i % n_accounts];
                        offset += account.writeToBuf(&pubkey, memory[offset..]);
                    }
                    break :blk offset;
                };

                var account_file = blk: {
                    const file = try std.fs.cwd().openFile(filepath, .{ .mode = .read_write });
                    errdefer file.close();
                    break :blk try AccountFile.init(file, .{ .id = s, .length = length }, s);
                };
                errdefer account_file.deinit();

                if (s < bench_args.n_accounts_multiple) {
                    try accounts_db.putAccountFile(&account_file, n_accounts);
                } else {
                    // to be indexed later (and timed)
                    account_files.appendAssumeCapacity(account_file);
                }
                all_filenames.appendAssumeCapacity(filepath);
            }

            var timer = try std.time.Timer.start();
            for (account_files.items) |*account_file| {
                try accounts_db.putAccountFile(account_file, n_accounts);
            }
            const elapsed = timer.read();

            std.debug.print("WRITE: {d}\n", .{elapsed});
        }

        var timer = try std.time.Timer.start();
        for (0..n_accounts) |i| {
            const pubkey = &pubkeys[i];
            const account = try accounts_db.getAccount(pubkey);
            if (account.data.len != (i % 1_000)) {
                std.debug.panic("account data len dnm {}: {} != {}", .{ i, account.data.len, (i % 1_000) });
            }
        }
        const elapsed = timer.read();
        return elapsed;
    }
};
