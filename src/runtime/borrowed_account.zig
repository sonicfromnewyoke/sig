const std = @import("std");
const sig = @import("../sig.zig");

const bincode = sig.bincode;

const InstructionError = sig.core.instruction.InstructionError;
const Pubkey = sig.core.Pubkey;

const AccountSharedData = sig.runtime.AccountSharedData;
const TransactionContext = sig.runtime.TransactionContext;
const WLockGuard = sig.runtime.TransactionAccount.WLockGuard;

const MAX_PERMITTED_ACCOUNTS_DATA_ALLOCATIONS_PER_TRANSACTION =
    sig.runtime.program.system_program.MAX_PERMITTED_ACCOUNTS_DATA_ALLOCATIONS_PER_TRANSACTION;

const MAX_PERMITTED_DATA_LENGTH = sig.runtime.program.system_program.MAX_PERMITTED_DATA_LENGTH;

/// [agave] https://github.com/anza-xyz/agave/blob/0d34a1a160129c4293dac248e14231e9e773b4ce/program-runtime/src/compute_budget.rs#L139
pub const MAX_INSTRUCTION_TRACE_LENGTH: usize = 100;

/// [agave] https://github.com/anza-xyz/agave/blob/8db563d3bba4d03edf0eb2737fba87f394c32b64/compute-budget/src/compute_budget.rs#L11-L12
pub const MAX_INSTRUCTION_STACK_DEPTH: usize = 5;

/// `BorrowedAccount` represents an account which has been 'borrowed' from the `TransactionContext`
/// It provides methods for accessing and modifying account state with the required checks.
///
/// The `borrow_context` holds the context under which the account was borrowed:
///    - `program_id: Pubkey`: the program which borrowed the account
///    - `is_writable: bool`: whether the account is writable within the program instruction which borrowed the account
///
/// TODO: add remaining methods as required by the runtime
///
/// [agave] https://github.com/anza-xyz/agave/blob/faea52f338df8521864ab7ce97b120b2abb5ce13/sdk/src/transaction_context.rs#L706
pub const BorrowedAccount = struct {
    /// The public key of the account
    pubkey: Pubkey,
    /// mutable reference to the account which has been borrowed
    account: *AccountSharedData,
    /// write guard for the account which has been borrowed
    account_write_guard: WLockGuard,
    /// the context under which the account was borrowed
    borrow_context: struct {
        program_id: Pubkey,
        is_writable: bool,
    },

    pub fn release(self: *BorrowedAccount) void {
        self.account_write_guard.release();
    }

    pub fn getData(self: BorrowedAccount) []const u8 {
        return self.account.data;
    }

    /// [agave] https://github.com/anza-xyz/agave/blob/faea52f338df8521864ab7ce97b120b2abb5ce13/sdk/src/transaction_context.rs#L1068
    pub fn isOwnedByCurrentProgram(self: BorrowedAccount) bool {
        return self.account.owner.equals(&self.borrow_context.program_id);
    }

    /// [agave] https://github.com/anza-xyz/agave/blob/faea52f338df8521864ab7ce97b120b2abb5ce13/sdk/src/transaction_context.rs#L1168
    pub fn isZeroed(self: BorrowedAccount) bool {
        return self.account.isZeroed();
    }

    /// [agave] https://github.com/anza-xyz/agave/blob/faea52f338df8521864ab7ce97b120b2abb5ce13/sdk/src/transaction_context.rs#L1055
    pub fn isWritable(self: BorrowedAccount) bool {
        return self.borrow_context.is_writable;
    }

    /// [agave] https://github.com/anza-xyz/agave/blob/faea52f338df8521864ab7ce97b120b2abb5ce13/sdk/src/transaction_context.rs#L1077
    pub fn checkDataIsMutable(self: BorrowedAccount) InstructionError!void {
        if (self.account.executable) return InstructionError.ExecutableDataModified;
        if (!self.isWritable()) return InstructionError.ReadonlyDataModified;
        if (!self.isOwnedByCurrentProgram()) return InstructionError.ExternalAccountDataModified;
    }

    /// [agave] https://github.com/anza-xyz/agave/blob/faea52f338df8521864ab7ce97b120b2abb5ce13/sdk/src/transaction_context.rs#L1095
    pub fn checkCanSetDataLength(
        self: BorrowedAccount,
        etc: *TransactionContext,
        length: usize,
    ) InstructionError!void {
        const old_length = self.getData().len;

        if (length != old_length and !self.isOwnedByCurrentProgram())
            return InstructionError.AccountDataSizeChanged;

        if (length > MAX_PERMITTED_DATA_LENGTH)
            return InstructionError.InvalidRealloc;

        // Safe since length and old_length <= MAX_PERMITTED_DATA_LENGTH
        const resize_delta: i64 = @intCast(length -| old_length);
        const new_accounts_resize_delta = etc.accounts_resize_delta +| resize_delta;

        if (new_accounts_resize_delta > MAX_PERMITTED_ACCOUNTS_DATA_ALLOCATIONS_PER_TRANSACTION)
            return InstructionError.MaxAccountsDataAllocationsExceeded;
    }

    /// Deserialize the account data into a type `T`.
    /// [agave] https://github.com/anza-xyz/agave/blob/faea52f338df8521864ab7ce97b120b2abb5ce13/sdk/src/transaction_context.rs#L968
    pub fn deserializeFromAccountData(
        self: BorrowedAccount,
        allocator: std.mem.Allocator,
        comptime T: type,
    ) error{InvalidAccountData}!T {
        return bincode.readFromSlice(allocator, T, self.account.data, .{}) catch {
            return InstructionError.InvalidAccountData;
        };
    }

    /// [agave] https://github.com/anza-xyz/agave/blob/faea52f338df8521864ab7ce97b120b2abb5ce13/sdk/src/transaction_context.rs#L976
    /// `state` must implement member function `pub fn serializedSize(state: T) usize`\
    /// `state` must support bincode serialization
    pub fn serializeIntoAccountData(
        self: *BorrowedAccount,
        state: anytype,
    ) InstructionError!void {
        try self.checkDataIsMutable();

        const serialized_size = try state.serializedSize();
        if (serialized_size > self.account.data.len)
            return InstructionError.AccountDataTooSmall;

        const written = bincode.writeToSlice(self.account.data, state, .{}) catch
            return InstructionError.GenericError;

        if (written.len != serialized_size)
            return InstructionError.GenericError;
    }

    /// [agave] https://github.com/anza-xyz/agave/blob/faea52f338df8521864ab7ce97b120b2abb5ce13/sdk/src/transaction_context.rs#L885
    pub fn setDataLength(
        self: *BorrowedAccount,
        allocator: std.mem.Allocator,
        tc: *TransactionContext,
        new_length: usize,
    ) InstructionError!void {
        try self.checkCanSetDataLength(tc, new_length);
        try self.checkDataIsMutable();
        if (self.getData().len == new_length) return;
        const old_length_signed: i64 = @intCast(self.getData().len);
        const new_length_signed: i64 = @intCast(new_length);
        tc.accounts_resize_delta +|= new_length_signed -| old_length_signed;
        self.account.resize(allocator, new_length) catch |err| {
            // TODO: confirm if this is the correct approach
            tc.custom_error = @intFromError(err);
            return InstructionError.Custom;
        };
    }

    /// [agave] https://github.com/anza-xyz/agave/blob/faea52f338df8521864ab7ce97b120b2abb5ce13/sdk/src/transaction_context.rs#L742
    pub fn setOwner(self: *BorrowedAccount, pubkey: Pubkey) InstructionError!void {
        if (!self.isOwnedByCurrentProgram()) return InstructionError.ModifiedProgramId;
        if (!self.isWritable()) return InstructionError.ModifiedProgramId;
        if (self.account.executable) return InstructionError.ModifiedProgramId;
        if (!self.account.isZeroed()) return InstructionError.ModifiedProgramId;
        self.account.owner = pubkey;
    }

    /// [agave] https://github.com/anza-xyz/agave/blob/faea52f338df8521864ab7ce97b120b2abb5ce13/sdk/src/transaction_context.rs#L800
    pub fn addLamports(
        self: *BorrowedAccount,
        lamports: u64,
    ) error{ArithmeticOverflow}!void {
        self.account.lamports = std.math.add(
            u64,
            self.account.lamports,
            lamports,
        ) catch {
            return InstructionError.ArithmeticOverflow;
        };
    }

    /// [agave] https://github.com/anza-xyz/agave/blob/faea52f338df8521864ab7ce97b120b2abb5ce13/sdk/src/transaction_context.rs#L808
    pub fn subtractLamports(
        self: *BorrowedAccount,
        lamports: u64,
    ) error{ArithmeticOverflow}!void {
        self.account.lamports = std.math.sub(
            u64,
            self.account.lamports,
            lamports,
        ) catch {
            return InstructionError.ArithmeticOverflow;
        };
    }
};
