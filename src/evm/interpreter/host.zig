const std = @import("std");
const primitives = @import("primitives");
const accel = @import("accelerators");
const bytecode_mod = @import("bytecode");
const context_mod = @import("context");
const state_mod = @import("state");
const database_mod = @import("database");
const alloc_mod = @import("zesu_allocator");
const Interpreter = @import("interpreter.zig").Interpreter;
const InputsImpl = @import("interpreter.zig").InputsImpl;
const ExtBytecode = @import("interpreter.zig").ExtBytecode;
const Memory = @import("memory.zig").Memory;
const InstructionResult = @import("instruction_result.zig").InstructionResult;
const CallScheme = @import("interpreter_action.zig").CallScheme;
const gas_costs = @import("gas_costs.zig");
const precompile_mod = @import("precompile");
const protocol_schedule = @import("protocol_schedule.zig");
const JournalCheckpoint = context_mod.JournalCheckpoint;

/// Result of a sub-call dispatched via Host.call()
pub const CallResult = struct {
    success: bool,
    return_data: []const u8,
    gas_used: u64,
    gas_remaining: u64,
    /// Refund counter accumulated inside the sub-call (SSTORE clears, etc.).
    /// Must be added to the parent frame's gas.refunded on return.
    gas_refunded: i64,
    /// EIP-7702: gas charged for loading the delegation target (if any).
    /// Must be deducted from the parent frame's remaining gas after the call.
    delegation_gas: u64,
    /// EIP-8037 (Amsterdam+): state gas charged in the sub-call.
    /// Must be added to parent frame's gas.state_gas_used on return.
    state_gas_used: u64,
    /// EIP-8037 (Amsterdam+): reservoir remaining in the child after execution.
    /// On success: returned to parent's reservoir.
    /// On failure: added with state_gas_used to restore all state gas to parent's reservoir.
    state_gas_remaining: u64,

    /// Sub-call failed after execution (all gas consumed).
    pub fn failure(gas_limit: u64) CallResult {
        return .{ .success = false, .return_data = &[_]u8{}, .gas_used = gas_limit, .gas_remaining = 0, .gas_refunded = 0, .delegation_gas = 0, .state_gas_used = 0, .state_gas_remaining = 0 };
    }

    /// Sub-call failed BEFORE execution (depth limit, value-transfer failure).
    /// Per EVM spec: when no sub-code runs, all forwarded gas is returned to caller.
    pub fn preExecFailure(gas_limit: u64) CallResult {
        return .{ .success = false, .return_data = &[_]u8{}, .gas_used = 0, .gas_remaining = gas_limit, .gas_refunded = 0, .delegation_gas = 0, .state_gas_used = 0, .state_gas_remaining = 0 };
    }
};

/// Inputs for a sub-call
pub const CallInputs = struct {
    /// Sender of the call (msg.sender in callee)
    caller: primitives.Address,
    /// Execution context address (storage/balance ownership)
    target: primitives.Address,
    /// Contract whose code is executed
    callee: primitives.Address,
    /// Value transferred
    value: primitives.U256,
    /// Call data
    data: []const u8,
    /// Gas limit for the sub-call
    gas_limit: u64,
    /// Call scheme
    scheme: CallScheme,
    /// Whether this is a static (read-only) call
    is_static: bool,
    /// EIP-8037 (Amsterdam+): state gas reservoir forwarded from parent to child.
    reservoir: u64,
    /// Pre-loaded callee bytecode from accountInfoWithCode — skips the redundant
    /// loadAccountWithCode in setupCallCore for the common (non-precompile) path.
    preloaded_code: ?bytecode_mod.Bytecode = null,
    /// Pre-EIP-161 (Frontier/Homestead): zero-value CALL to non-existent address must touch it.
    /// Computed in callImpl from callee_info.is_empty; passed through so setupCallCore can act
    /// on it without re-loading the account.
    needs_pre_eip161_touch: bool = false,
};

/// Result of a selfdestruct operation
pub const SelfDestructLoadResult = struct {
    had_value: bool,
    target_exists: bool,
    previously_destroyed: bool,
    is_cold: bool,
};

/// Result of a CREATE / CREATE2 operation
pub const CreateResult = struct {
    success: bool,
    /// True when the init-code explicitly executed REVERT (gas is returned, revert reason in
    /// return_data). False for any other failure (OOG, bad opcode, pre-execution guard, etc.).
    is_revert: bool,
    address: primitives.Address,
    gas_remaining: u64,
    return_data: []const u8,
    /// Refund counter accumulated inside the init-code sub-interpreter.
    gas_refunded: i64,
    /// EIP-8037 (Amsterdam+): state gas charged in the sub-call.
    /// Must be added to parent frame's gas.state_gas_used on return.
    state_gas_used: u64,
    /// EIP-8037 (Amsterdam+): reservoir remaining in the child after execution.
    state_gas_remaining: u64,
    /// EIP-8037 (Amsterdam+): code-deposit state gas that spilled from the child's
    /// regular gas (reservoir was insufficient). Recorded so the parent's LIFO refill
    /// on halt/revert treats it as gas_left-drawn (burned on halt) rather than
    /// reservoir-drawn — otherwise it would inflate the parent reservoir. Defaults to 0.
    state_gas_spilled: u64 = 0,

    /// Pre-execution failure: no sub-interpreter ran, return all forwarded gas.
    pub fn preExecFailure(gas_limit: u64) CreateResult {
        return .{ .success = false, .is_revert = false, .address = [_]u8{0} ** 20, .gas_remaining = gas_limit, .return_data = &[_]u8{}, .gas_refunded = 0, .state_gas_used = 0, .state_gas_remaining = 0 };
    }

    /// Post-execution failure: sub-interpreter ran and consumed gas.
    pub fn failure() CreateResult {
        return .{ .success = false, .is_revert = false, .address = [_]u8{0} ** 20, .gas_remaining = 0, .return_data = &[_]u8{}, .gas_refunded = 0, .state_gas_used = 0, .state_gas_remaining = 0 };
    }
};

// ─── Host ───────────────────────────────────────────────────────────────────

/// The Host bridges opcode handlers to the EVM execution context.
/// It stores direct pointers to the context's block/tx/cfg/error fields,
/// plus a concrete pointer to the Journal(DB). Comptime-generic over DB: every
/// Journal call below compiles to a direct, inlinable call — there is no
/// runtime dispatch layer. The set of DB implementations (InMemoryDB,
/// WitnessDatabase, …) is closed and known at compile time, so this is the
/// idiomatic Zig shape for "one of a known set of concrete types" — the
/// alternative (a hand-rolled *anyopaque + function-pointer vtable) is the
/// tool for an open/unbounded set of implementations, which this isn't.
pub fn Host(comptime DB: type) type {
    return struct {
        const Self = @This();

        block: *context_mod.BlockEnv,
        tx: *context_mod.TxEnv,
        cfg: *const context_mod.CfgEnv,
        ctx_error: *context_mod.ContextError,
        /// Concrete journal pointer — no type erasure, no vtable.
        js: *context_mod.Journal(DB),
        /// Precompile set for the current spec. Null disables precompile dispatch (benchmarks/unit tests).
        precompiles: ?*const precompile_mod.Precompiles = null,

        /// Create a Host from a Context(DB).
        pub fn init(ctx: *context_mod.Context(DB), prec: ?*const precompile_mod.Precompiles) Self {
            return .{
                .block = &ctx.block,
                .tx = &ctx.tx,
                .cfg = &ctx.cfg,
                .ctx_error = &ctx.ctx_error,
                .js = &ctx.journaled_state,
                .precompiles = prec,
            };
        }

        // -----------------------------------------------------------------------
        // Block / transaction environment (no state access required)
        // -----------------------------------------------------------------------

        pub fn origin(self: *Self) primitives.Address {
            return self.tx.caller;
        }

        pub fn gasPrice(self: *Self) primitives.U256 {
            const max_fee = self.tx.gas_price;
            if (self.tx.gas_priority_fee) |priority_fee| {
                const base_fee: u128 = @intCast(self.block.basefee);
                const effective = @min(max_fee, base_fee + priority_fee);
                return @as(primitives.U256, effective);
            }
            return @as(primitives.U256, max_fee);
        }

        pub fn coinbase(self: *Self) primitives.Address {
            return self.block.beneficiary;
        }

        pub fn blockNumber(self: *Self) primitives.U256 {
            return self.block.number;
        }

        pub fn timestamp(self: *Self) primitives.U256 {
            return self.block.timestamp;
        }

        pub fn blockGasLimit(self: *Self) u64 {
            return self.block.gas_limit;
        }

        pub fn difficulty(self: *Self) primitives.U256 {
            return self.block.difficulty;
        }

        pub fn prevrandao(self: *Self) ?primitives.Hash {
            return self.block.prevrandao;
        }

        pub fn chainId(self: *Self) u64 {
            return self.cfg.chain_id;
        }

        pub fn basefee(self: *Self) u64 {
            return self.block.basefee;
        }

        pub fn blobBasefee(self: *Self) u128 {
            if (self.block.blob_excess_gas_and_price) |b| return b.blob_gasprice;
            return 0;
        }

        pub fn blobHash(self: *Self, index: usize) ?primitives.U256 {
            const blob_hashes = self.tx.blob_hashes orelse return null;
            if (index >= blob_hashes.items.len) return null;
            return hashToU256(blob_hashes.items[index]);
        }

        pub fn blockHash(self: *Self, number: u64) ?primitives.Hash {
            const current: u64 = @intCast(self.block.number);
            if (number >= current) return [_]u8{0} ** 32;
            if (current - number > primitives.BLOCK_HASH_HISTORY) return [_]u8{0} ** 32;
            return self.js.getDbMut().blockHash(number) catch {
                self.ctx_error.* = context_mod.ContextError.database_error;
                return null;
            };
        }

        pub fn slotNumber(self: *Self) ?u64 {
            return self.block.slot_number;
        }

        // -----------------------------------------------------------------------
        // Account state access (via journaled_state)
        // -----------------------------------------------------------------------

        /// Check whether an address is cold WITHOUT loading it from the database.
        pub fn isAddressCold(self: *Self, addr: primitives.Address) bool {
            return self.js.isAddressCold(addr);
        }

        /// Check whether a storage slot is cold WITHOUT loading it from the database.
        pub fn isStorageCold(self: *Self, addr: primitives.Address, key: primitives.StorageKey) bool {
            return self.js.isStorageCold(addr, key);
        }

        /// Check whether an address is already in the EVM state cache.
        pub fn isAddressLoaded(self: *const Self, addr: primitives.Address) bool {
            return self.js.isAddressLoaded(addr);
        }

        /// Load account info. Returns null on database error.
        pub fn accountInfo(self: *Self, addr: primitives.Address) ?struct { balance: primitives.U256, is_cold: bool, is_empty: bool } {
            const load = self.js.loadAccountInfoSkipColdLoad(addr, false, false) catch return null;
            return .{
                .balance = load.info.balance,
                .is_cold = load.is_cold,
                .is_empty = load.is_empty,
            };
        }

        /// Load account with code. On any database error, marks ctx_error so the block is
        /// rejected and returns null.
        pub fn codeInfo(self: *Self, addr: primitives.Address) ?struct { bytecode: bytecode_mod.Bytecode, code_hash: primitives.Hash, is_cold: bool } {
            const load = self.js.loadAccountWithCode(addr) catch {
                self.ctx_error.* = context_mod.ContextError.database_error;
                return null;
            };
            const acc = load.data;
            const code = if (acc.info.code) |c| c else bytecode_mod.Bytecode.new();
            const code_hash = acc.info.code_hash;
            return .{
                .bytecode = code,
                .code_hash = code_hash,
                .is_cold = load.is_cold,
            };
        }

        /// Load account info and code in one journal lookup.
        /// Merges accountInfo + codeInfo into a single loadAccountWithCode call,
        /// avoiding the redundant basic-info fetch that codeInfo would otherwise repeat.
        pub fn accountInfoWithCode(self: *Self, addr: primitives.Address) ?struct {
            balance: primitives.U256,
            is_cold: bool,
            is_empty: bool,
            bytecode: bytecode_mod.Bytecode,
            code_hash: primitives.Hash,
        } {
            const load = self.js.loadAccountWithCode(addr) catch {
                self.ctx_error.* = context_mod.ContextError.database_error;
                return null;
            };
            const acc = load.data;
            return .{
                .balance = acc.info.balance,
                .is_cold = load.is_cold,
                .is_empty = acc.stateClearAwareIsEmpty(self.cfg.spec),
                .bytecode = if (acc.info.code) |c| c else bytecode_mod.Bytecode.new(),
                .code_hash = acc.info.code_hash,
            };
        }

        /// Load account for EXTCODEHASH. Returns null on database error.
        /// Uses accountInfo (no code loading) since EXTCODEHASH only needs the hash stored
        /// in the account — it does not read or execute the bytecode itself.
        pub fn extCodeHash(self: *Self, addr: primitives.Address) ?struct { hash: primitives.Hash, is_cold: bool, is_empty: bool } {
            const load = self.js.loadAccountInfoSkipColdLoad(addr, false, false) catch {
                self.ctx_error.* = context_mod.ContextError.database_error;
                return null;
            };
            return .{
                .hash = load.info.code_hash,
                .is_cold = load.is_cold,
                .is_empty = load.is_empty,
            };
        }

        pub fn sload(self: *Self, addr: primitives.Address, key: primitives.U256) ?struct { value: primitives.U256, is_cold: bool } {
            const load = self.js.sload(addr, key) catch return null;
            return .{ .value = load.data, .is_cold = load.is_cold };
        }

        pub fn sstore(self: *Self, addr: primitives.Address, key: primitives.U256, val: primitives.U256) ?struct { original: primitives.U256, current: primitives.U256, new: primitives.U256, is_cold: bool } {
            const result = self.js.sstore(addr, key, val) catch return null;
            return .{
                .original = result.data.original_value,
                .current = result.data.present_value,
                .new = result.data.new_value,
                .is_cold = result.is_cold,
            };
        }

        pub fn tload(self: *Self, addr: primitives.Address, key: primitives.U256) primitives.U256 {
            return self.js.tload(addr, key);
        }

        pub fn tstore(self: *Self, addr: primitives.Address, key: primitives.U256, val: primitives.U256) void {
            self.js.tstore(addr, key, val);
        }

        pub fn emitLog(self: *Self, log_entry: primitives.Log) void {
            self.js.log(log_entry);
        }

        pub fn selfdestruct(self: *Self, addr: primitives.Address, target: primitives.Address) ?SelfDestructLoadResult {
            const result = self.js.selfdestruct(addr, target) catch return null;
            return .{
                .had_value = result.data.had_value,
                .target_exists = result.data.target_exists,
                .previously_destroyed = result.data.previously_destroyed,
                .is_cold = result.is_cold,
            };
        }

        // -----------------------------------------------------------------------
        // Sub-call dispatch: setup/finalize split for iterative frame runner
        // -----------------------------------------------------------------------

        /// Result of setupCall: either already resolved (precompile or failure),
        /// or ready to launch a sub-frame.
        pub const CallSetupResult = union(enum) {
            /// Pre-execution failure (depth, value transfer, etc.): all gas returned.
            failed: CallResult,
            /// Precompile executed synchronously: result is final.
            precompile: CallResult,
            /// Sub-frame needed: checkpoint taken, code loaded, delegation_gas computed.
            ready: struct {
                checkpoint: JournalCheckpoint,
                code: bytecode_mod.Bytecode,
                delegation_gas: u64,
            },
        };

        /// Result of setupCreate: either already resolved (failure) or ready to launch.
        pub const CreateSetupResult = union(enum) {
            failed: CreateResult,
            ready: struct {
                checkpoint: JournalCheckpoint,
                new_addr: primitives.Address,
                /// EIP-8037 (Amsterdam+): target address was alive (pre-funded) before creation.
                target_alive: bool = false,
            },
        };

        /// Performs all pre-execution steps for a CALL.
        pub fn setupCall(self: *Self, inputs: CallInputs, frame_depth: usize) CallSetupResult {
            return setupCallCore(DB, self.js, self, inputs, frame_depth);
        }

        /// Commits or reverts a call checkpoint and builds the final CallResult.
        pub fn finalizeCall(
            self: *Self,
            checkpoint: JournalCheckpoint,
            result: InstructionResult,
            gas_limit: u64,
            gas_remaining: u64,
            gas_refunded: i64,
            return_data: []const u8,
        ) CallResult {
            return finalizeCallCore(DB, self.js, checkpoint, result, gas_limit, gas_remaining, gas_refunded, return_data);
        }

        /// Performs all pre-execution steps for a CREATE/CREATE2.
        pub fn setupCreate(
            self: *Self,
            caller: primitives.Address,
            value: primitives.U256,
            init_code: []const u8,
            gas_limit: u64,
            is_create2: bool,
            salt: primitives.U256,
            skip_nonce_bump: bool,
            frame_depth: usize,
            is_opcode_create: bool,
        ) CreateSetupResult {
            return setupCreateCore(DB, self.js, self, caller, value, init_code, gas_limit, is_create2, salt, skip_nonce_bump, frame_depth, is_opcode_create);
        }

        /// EIP-7928 (Amsterdam+): record the create target address in the block access list
        /// BEFORE the NEW_ACCOUNT state-gas charge (reference generic_create:
        /// accessed_addresses.add(contract_address) precedes charge_state_gas). Read-only —
        /// no nonce bump, collision check, or checkpoint — so a subsequent NEW_ACCOUNT OOG
        /// still leaves the address in the BAL. Gated by the same pre-checks that make
        /// setupCreate return without accessing the address (depth, initcode size, balance,
        /// nonce overflow), so no phantom entries are created.
        /// Returns whether the create target account is already alive (has balance, nonce, or
        /// code), so the caller can skip the NEW_ACCOUNT charge (reference is_account_alive gate).
        pub fn recordCreateTarget(
            self: *Self,
            caller: primitives.Address,
            value: primitives.U256,
            init_code: []const u8,
            is_create2: bool,
            salt: primitives.U256,
            frame_depth: usize,
        ) ?bool {
            return recordCreateTargetCore(DB, self.js, self, caller, value, init_code, is_create2, salt, frame_depth);
        }

        /// Validates deployed code, applies deposit gas, stores bytecode, and commits/reverts.
        pub fn finalizeCreate(
            self: *Self,
            checkpoint: JournalCheckpoint,
            new_addr: primitives.Address,
            result: InstructionResult,
            gas_remaining: u64,
            gas_refunded: i64,
            return_data: []const u8,
            spec_id: primitives.SpecId,
            is_opcode_create: bool,
            gas_reservoir: u64,
        ) CreateResult {
            return finalizeCreateCore(DB, self.js, self, checkpoint, new_addr, result, gas_remaining, gas_refunded, return_data, spec_id, is_opcode_create, gas_reservoir);
        }

        // -----------------------------------------------------------------------
        // TEST PATH — synchronous helpers used by unit tests only.
        // Production execution goes through executeIterative in mainnet_builder.zig,
        // which builds the instruction table once before the frame loop.
        // These helpers rebuild the table per call; do not use on hot paths.
        // -----------------------------------------------------------------------

        /// Synchronous CALL — runs a complete sub-frame inline. For use in tests and
        /// simple callers that do not need the iterative frame runner.
        pub fn call(self: *Self, inputs: CallInputs) CallResult {
            const setup = self.setupCall(inputs, 0);
            switch (setup) {
                .failed => |r| return r,
                .precompile => |r| return r,
                .ready => |s| {
                    const spec_id = self.cfg.spec;
                    var sub_interp = Interpreter.new(
                        Memory.new(),
                        ExtBytecode.new(s.code),
                        InputsImpl.new(inputs.caller, inputs.target, inputs.value, @constCast(inputs.data), inputs.gas_limit, inputs.scheme, inputs.is_static, 1),
                        inputs.is_static,
                        spec_id,
                        inputs.gas_limit,
                    );
                    sub_interp.gas.reservoir = inputs.reservoir;
                    defer sub_interp.deinit();
                    const table = protocol_schedule.makeInstructionTable(DB, spec_id);
                    _ = sub_interp.runWithHost(DB, &table, self);
                    const rd: []const u8 = if (sub_interp.result.isSuccess() or sub_interp.result == .revert)
                        sub_interp.return_data.data
                    else
                        &[_]u8{};
                    var rd_buf: std.ArrayList(u8) = .empty;
                    defer rd_buf.deinit(alloc_mod.get());
                    rd_buf.appendSlice(alloc_mod.get(), rd) catch {};
                    var call_result = self.finalizeCall(s.checkpoint, sub_interp.result, inputs.gas_limit, sub_interp.gas.remaining, sub_interp.gas.refunded, rd_buf.items);
                    const sub_state_gas = sub_interp.gas.state_gas_used;
                    const sub_reservoir = sub_interp.gas.reservoir;
                    if (call_result.success) {
                        call_result.state_gas_used = sub_state_gas;
                        call_result.state_gas_remaining = sub_reservoir;
                    } else {
                        call_result.state_gas_used = 0;
                        call_result.state_gas_remaining = sub_state_gas + sub_reservoir;
                    }
                    return call_result;
                },
            }
        }

        /// Synchronous CREATE/CREATE2 — runs a complete init-code frame inline. For tests only.
        pub fn create(
            self: *Self,
            caller: primitives.Address,
            value: primitives.U256,
            init_code: []const u8,
            gas_limit: u64,
            is_create2: bool,
            salt: primitives.U256,
            skip_nonce_bump: bool,
        ) CreateResult {
            const setup = self.setupCreate(caller, value, init_code, gas_limit, is_create2, salt, skip_nonce_bump, 0, true);
            switch (setup) {
                .failed => |r| return r,
                .ready => |s| {
                    const spec_id = self.cfg.spec;
                    const init_bytecode = bytecode_mod.Bytecode.newRaw(init_code);
                    var sub_interp = Interpreter.new(
                        Memory.new(),
                        ExtBytecode.newOwned(init_bytecode),
                        InputsImpl.new(caller, s.new_addr, value, @constCast(&[_]u8{}), gas_limit, .call, false, 1),
                        false,
                        spec_id,
                        gas_limit,
                    );
                    defer sub_interp.deinit();
                    const table = protocol_schedule.makeInstructionTable(DB, spec_id);
                    _ = sub_interp.runWithHost(DB, &table, self);
                    const rd: []const u8 = if (sub_interp.result.isSuccess() or sub_interp.result == .revert)
                        sub_interp.return_data.data
                    else
                        &[_]u8{};
                    var rd_buf: std.ArrayList(u8) = .empty;
                    defer rd_buf.deinit(alloc_mod.get());
                    rd_buf.appendSlice(alloc_mod.get(), rd) catch {};
                    const sub_state_gas = sub_interp.gas.state_gas_used;
                    const sub_reservoir = sub_interp.gas.reservoir;
                    var create_result = self.finalizeCreate(s.checkpoint, s.new_addr, sub_interp.result, sub_interp.gas.remaining, sub_interp.gas.refunded, rd_buf.items, spec_id, true, sub_reservoir);
                    if (create_result.success) {
                        create_result.state_gas_used += sub_state_gas;
                    } else {
                        create_result.state_gas_remaining += sub_state_gas;
                    }
                    return create_result;
                },
            }
        }
    };
}

/// Convenience constructor for the default InMemoryDB context. Kept outside
/// Host(DB) since its `ctx` parameter type is concretely `Context(InMemoryDB)`
/// and would not typecheck as a generic Host(DB) method for other DB types.
pub fn fromCtx(ctx: *context_mod.DefaultContext, prec: ?*const precompile_mod.Precompiles) Host(database_mod.InMemoryDB) {
    return Host(database_mod.InMemoryDB).init(ctx, prec);
}

// ─── Core implementations (anytype journal — shared across DB types) ─────────

/// Core logic for setupCall. `js`/`host` are concretely typed once DB is bound,
/// so this compiles to direct calls; the function itself is still shared across
/// all DB instantiations since it's a plain generic function.
fn setupCallCore(comptime DB: type, js: *context_mod.Journal(DB), host: *Host(DB), inputs: CallInputs, frame_depth: usize) Host(DB).CallSetupResult {
    const MAX_CALL_DEPTH = 1024;

    // 1. Depth check
    if (frame_depth >= MAX_CALL_DEPTH) {
        return .{ .failed = CallResult.preExecFailure(inputs.gas_limit) };
    }

    // 2. Precompile dispatch
    if (host.precompiles) |pcs| {
        if (pcs.get(inputs.callee)) |pc| {
            // EIP-7928 (Amsterdam+): record the precompile callee in the BAL.
            // Precompiles have no account state, so this records an empty pre-state
            // entry — matching how EELS includes invoked precompiles in the BAL.
            // Without this, the post-execution BAL comparison fails because the
            // declared BAL contains the precompile address but the computed one
            // doesn't (precompile dispatch normally skips loadAccount).
            _ = js.loadAccount(inputs.callee) catch {
                return .{ .failed = CallResult.preExecFailure(inputs.gas_limit) };
            };
            const cp = js.getCheckpoint();
            if (inputs.value > 0 and inputs.scheme != .delegatecall) {
                const xfer_err = js.transfer(inputs.caller, inputs.target, inputs.value) catch {
                    js.checkpointRevert(cp);
                    var r = CallResult.preExecFailure(inputs.gas_limit);
                    r.state_gas_remaining = inputs.reservoir;
                    return .{ .precompile = r };
                };
                if (xfer_err != null) {
                    js.checkpointRevert(cp);
                    var r = CallResult.preExecFailure(inputs.gas_limit);
                    r.state_gas_remaining = inputs.reservoir;
                    return .{ .precompile = r };
                }
                // EIP-7708 (Amsterdam+): emit Transfer log for ETH sent to precompile.
                if (primitives.isEnabledIn(host.cfg.spec, .amsterdam) and
                    !std.mem.eql(u8, &inputs.caller, &inputs.target))
                {
                    js.emitTransferLog(inputs.caller, inputs.target, inputs.value);
                }
            }
            const pc_result = pc.execute(inputs.data, inputs.gas_limit);
            switch (pc_result) {
                .success => |out| {
                    if (out.reverted) {
                        js.checkpointRevert(cp);
                        return .{ .precompile = .{ .success = false, .return_data = out.bytes, .gas_used = inputs.gas_limit, .gas_remaining = 0, .gas_refunded = 0, .delegation_gas = 0, .state_gas_used = 0, .state_gas_remaining = inputs.reservoir } };
                    }
                    js.checkpointCommit();
                    js.touchAccount(inputs.callee);
                    return .{ .precompile = .{ .success = true, .return_data = out.bytes, .gas_used = out.gas_used, .gas_remaining = inputs.gas_limit - out.gas_used, .gas_refunded = 0, .delegation_gas = 0, .state_gas_used = 0, .state_gas_remaining = inputs.reservoir } };
                },
                .err => {
                    // EIP-8037: precompiles never consume state gas. On OOG/failure, the caller's
                    // reservoir must be restored in full (state_gas_remaining = inputs.reservoir).
                    js.checkpointRevert(cp);
                    var r = CallResult.failure(inputs.gas_limit);
                    r.state_gas_remaining = inputs.reservoir;
                    return .{ .precompile = r };
                },
            }
        }
    }

    // 3. Load callee code + EIP-7702 delegation.
    // Fast path: use pre-loaded bytecode from callImpl (already fetched for gas computation),
    // skipping the redundant loadAccountWithCode. Fall back to a fresh load when not available
    // (e.g. direct setupCall invocations from tests, system calls, etc.).
    var code: bytecode_mod.Bytecode = undefined;
    var needs_pre_eip161_touch = false;
    if (inputs.preloaded_code) |preloaded| {
        code = preloaded;
        needs_pre_eip161_touch = inputs.needs_pre_eip161_touch;
    } else {
        const callee_load = js.loadAccountWithCode(inputs.callee) catch {
            host.ctx_error.* = context_mod.ContextError.database_error;
            return .{ .failed = CallResult.failure(inputs.gas_limit) };
        };
        const callee_acc = callee_load.data;
        code = if (callee_acc.info.code) |c| c else bytecode_mod.Bytecode.new();
        needs_pre_eip161_touch = inputs.value == 0 and inputs.scheme == .call and
            !primitives.isEnabledIn(host.cfg.spec, .spurious_dragon) and
            callee_acc.isLoadedAsNotExistingNotTouched();
    }
    var delegation_gas: u64 = 0;
    if (code.isEip7702()) {
        const delegation_addr = code.eip7702.address;
        if (js.loadAccountWithCode(delegation_addr)) |del_load| {
            delegation_gas = if (del_load.is_cold)
                gas_costs.COLD_ACCOUNT_ACCESS
            else
                gas_costs.WARM_ACCOUNT_ACCESS;
            code = if (del_load.data.info.code) |del_code| del_code else bytecode_mod.Bytecode.new();
        } else |_| {
            host.ctx_error.* = context_mod.ContextError.database_error;
            code = bytecode_mod.Bytecode.new();
        }
    }

    // 4. Checkpoint
    const checkpoint = js.getCheckpoint();

    // 5. Value transfer
    if (inputs.value > 0 and inputs.scheme != .delegatecall) {
        const transfer_err = js.transfer(inputs.caller, inputs.target, inputs.value) catch {
            js.checkpointRevert(checkpoint);
            return .{ .failed = CallResult.preExecFailure(inputs.gas_limit) };
        };
        if (transfer_err != null) {
            js.checkpointRevert(checkpoint);
            return .{ .failed = CallResult.preExecFailure(inputs.gas_limit) };
        }
        // EIP-7708 (Amsterdam+): emit Transfer log for ETH sent via CALL.
        if (primitives.isEnabledIn(host.cfg.spec, .amsterdam) and
            !std.mem.eql(u8, &inputs.caller, &inputs.target))
        {
            js.emitTransferLog(inputs.caller, inputs.target, inputs.value);
        }
    } else if (needs_pre_eip161_touch) {
        // Pre-EIP-161 (Frontier/Homestead): a zero-value CALL to a non-existent address
        // still creates it as an empty account ("touches" it). EIP-161 (Spurious Dragon)
        // removed empty accounts on touch, making this a no-op; we skip it for those forks.
        js.touchAccount(inputs.callee);
    }

    return .{ .ready = .{ .checkpoint = checkpoint, .code = code, .delegation_gas = delegation_gas } };
}

/// Core logic for finalizeCall.
fn finalizeCallCore(comptime DB: type, js: *context_mod.Journal(DB), checkpoint: JournalCheckpoint, result: InstructionResult, gas_limit: u64, gas_remaining: u64, gas_refunded: i64, return_data: []const u8) CallResult {
    if (result.isSuccess()) {
        js.checkpointCommit();
    } else {
        js.checkpointRevert(checkpoint);
    }
    const gas_rem: u64 = if (result.isSuccess() or result == .revert) gas_remaining else 0;
    const gas_used = if (gas_limit > gas_rem) gas_limit - gas_rem else 0;
    const refunded: i64 = if (result.isSuccess()) gas_refunded else 0;
    return .{
        .success = result.isSuccess(),
        .return_data = if (result.isSuccess() or result == .revert) return_data else &[_]u8{},
        .gas_used = gas_used,
        .gas_remaining = gas_rem,
        .gas_refunded = refunded,
        .delegation_gas = 0,
        .state_gas_used = 0,
        .state_gas_remaining = 0,
    };
}

/// Core logic for setupCreate.
/// EIP-7928 (Amsterdam+): record the create target address (read-only) before the
/// NEW_ACCOUNT charge. Mirrors setupCreateCore's pre-checks so it only records when
/// setupCreate would actually reach the address access — no nonce bump / checkpoint.
fn recordCreateTargetCore(
    comptime DB: type,
    js: *context_mod.Journal(DB),
    host: *Host(DB),
    caller: primitives.Address,
    value: primitives.U256,
    init_code: []const u8,
    is_create2: bool,
    salt: primitives.U256,
    frame_depth: usize,
) ?bool {
    const spec_id = host.cfg.spec;
    if (!primitives.isEnabledIn(spec_id, .amsterdam)) return null; // BAL is Amsterdam+ only
    // Reference generic_create returns 0 BEFORE accessing the address or charging NEW_ACCOUNT
    // when a pre-check fails (depth, nonce overflow, insufficient balance). Return null so the
    // caller records nothing and charges no NEW_ACCOUNT.
    const MAX_CALL_DEPTH = 1024;
    if (frame_depth >= MAX_CALL_DEPTH) return null;
    const max_initcode: usize = primitives.AMSTERDAM_MAX_INITCODE_SIZE;
    if (init_code.len > max_initcode) return null;
    const caller_acc = js.inner.evm_state.getPtr(caller) orelse return null;
    if (value > 0 and caller_acc.info.balance < value) return null;
    const nonce = caller_acc.info.nonce;
    if (nonce == std.math.maxInt(u64)) return null;
    const new_addr: primitives.Address = if (is_create2) blk: {
        var init_hash: [32]u8 = undefined;
        accel.keccak256(init_code, &init_hash);
        break :blk create2Address(caller, salt, init_hash);
    } else createAddress(caller, nonce);
    const load = js.loadAccount(new_addr) catch return null;
    // is_account_alive: reference generic_create charges NEW_ACCOUNT only when the target
    // leaf does not already exist (balance/nonce/code present).
    const info = load.data.info;
    return info.balance > 0 or info.nonce > 0 or
        !std.mem.eql(u8, &info.code_hash, &primitives.KECCAK_EMPTY);
}

fn setupCreateCore(
    comptime DB: type,
    js: *context_mod.Journal(DB),
    host: *Host(DB),
    caller: primitives.Address,
    value: primitives.U256,
    init_code: []const u8,
    gas_limit: u64,
    is_create2: bool,
    salt: primitives.U256,
    skip_nonce_bump: bool,
    frame_depth: usize,
    is_opcode_create: bool,
) Host(DB).CreateSetupResult {
    const MAX_CALL_DEPTH = 1024;
    const spec_id = host.cfg.spec;

    if (frame_depth >= MAX_CALL_DEPTH) return .{ .failed = CreateResult.preExecFailure(gas_limit) };

    if (primitives.isEnabledIn(spec_id, .shanghai)) {
        const max_initcode: usize = if (primitives.isEnabledIn(spec_id, .amsterdam))
            primitives.AMSTERDAM_MAX_INITCODE_SIZE
        else
            primitives.MAX_INITCODE_SIZE;
        if (init_code.len > max_initcode) return .{ .failed = CreateResult.preExecFailure(gas_limit) };
    }

    // Pre-Amsterdam: check balance BEFORE nonce bump (original EVM behavior).
    if (!primitives.isEnabledIn(spec_id, .amsterdam) and value > 0) {
        const acct = js.inner.evm_state.getPtr(caller) orelse
            return .{ .failed = CreateResult.preExecFailure(gas_limit) };
        if (acct.info.balance < value)
            return .{ .failed = CreateResult.preExecFailure(gas_limit) };
    }

    const caller_acc = js.inner.evm_state.getPtr(caller) orelse return .{ .failed = CreateResult.preExecFailure(gas_limit) };
    const pre_bump_checkpoint = if (is_opcode_create and primitives.isEnabledIn(spec_id, .amsterdam))
        js.getCheckpoint()
    else
        @as(@TypeOf(js.getCheckpoint()), undefined);
    const caller_nonce: u64 = if (skip_nonce_bump)
        caller_acc.info.nonce -| 1
    else blk: {
        const n = caller_acc.info.nonce;
        if (n == std.math.maxInt(u64)) return .{ .failed = CreateResult.preExecFailure(gas_limit) };
        caller_acc.info.nonce = n + 1;
        js.nonceBumpJournalEntry(caller);
        break :blk n;
    };

    const new_addr: primitives.Address = if (is_create2) blk: {
        var init_hash: [32]u8 = undefined;
        accel.keccak256(init_code, &init_hash);
        break :blk create2Address(caller, salt, init_hash);
    } else createAddress(caller, caller_nonce);

    // Balance check BEFORE loading new_addr to avoid phantom BAL entries.
    // Pre-Amsterdam already checked balance before the nonce bump (above); this handles
    // Amsterdam (checked after nonce bump) without needing an untrackAddress on failure.
    if (primitives.isEnabledIn(spec_id, .amsterdam) and value > 0) {
        const ca = js.inner.evm_state.getPtr(caller) orelse {
            if (is_opcode_create) js.checkpointRevert(pre_bump_checkpoint);
            return .{ .failed = CreateResult.preExecFailure(gas_limit) };
        };
        if (ca.info.balance < value) {
            if (is_opcode_create) js.checkpointRevert(pre_bump_checkpoint);
            return .{ .failed = CreateResult.preExecFailure(gas_limit) };
        }
    }

    _ = js.loadAccount(new_addr) catch return .{ .failed = CreateResult.preExecFailure(gas_limit) };

    // EIP-8037 (Amsterdam+): was the target already alive (pre-funded) before creation?
    // Captured before createAccountCheckpoint transfers value / bumps nonce. A deployable
    // target has nonce 0 and no code, so aliveness reduces to a pre-existing balance.
    const target_alive: bool = if (primitives.isEnabledIn(spec_id, .amsterdam)) blk: {
        if (js.inner.evm_state.get(new_addr)) |acct| {
            break :blk acct.info.balance > 0 or acct.info.nonce > 0 or
                !std.mem.eql(u8, &acct.info.code_hash, &primitives.KECCAK_EMPTY);
        }
        break :blk false;
    } else false;

    // Address collision: storage already exists at the target address.
    if (js.inner.evm_state.get(new_addr)) |acct| {
        var slot_it = acct.storage.valueIterator();
        while (slot_it.next()) |slot| {
            if (slot.presentValue() != 0) {
                return .{ .failed = CreateResult.failure() };
            }
        }
    }
    {
        const storage_wiped = if (js.inner.evm_state.get(new_addr)) |acct| acct.status.storage_wiped else false;
        if (!storage_wiped) {
            if (js.hasNonZeroStorageForAddress(new_addr)) {
                return .{ .failed = CreateResult.failure() };
            }
        }
    }

    const checkpoint = js.createAccountCheckpoint(caller, new_addr, value, spec_id) catch {
        return .{ .failed = CreateResult.failure() };
    };

    // EIP-7708 (Amsterdam+): emit Transfer log for ETH sent to the new contract.
    if (value > 0 and primitives.isEnabledIn(spec_id, .amsterdam)) {
        js.emitTransferLog(caller, new_addr, value);
    }

    return .{ .ready = .{ .checkpoint = checkpoint, .new_addr = new_addr, .target_alive = target_alive } };
}

/// Core logic for finalizeCreate.
fn finalizeCreateCore(
    comptime DB: type,
    js: *context_mod.Journal(DB),
    host: *Host(DB),
    checkpoint: JournalCheckpoint,
    new_addr: primitives.Address,
    result: InstructionResult,
    gas_remaining: u64,
    gas_refunded: i64,
    return_data: []const u8,
    spec_id: primitives.SpecId,
    is_opcode_create: bool,
    gas_reservoir: u64,
) CreateResult {
    const MAX_CODE_SIZE: usize = if (primitives.isEnabledIn(spec_id, .amsterdam)) primitives.AMSTERDAM_MAX_CODE_SIZE else primitives.MAX_CODE_SIZE;

    if (!result.isSuccess()) {
        js.checkpointRevert(checkpoint);
        const gas_rem = if (result == .revert) gas_remaining else @as(u64, 0);
        const rd = if (result == .revert) return_data else &[_]u8{};
        return .{ .success = false, .is_revert = (result == .revert), .address = [_]u8{0} ** 20, .gas_remaining = gas_rem, .return_data = rd, .gas_refunded = 0, .state_gas_used = 0, .state_gas_remaining = gas_reservoir };
    }

    // SELFDESTRUCT in init code: no code is deployed (account is deleted).
    // return_data may contain stale call return data from STATICCALLs; ignore it.
    const deployed_raw: []const u8 = if (result == .selfdestruct) &[_]u8{} else return_data;
    if (deployed_raw.len > MAX_CODE_SIZE) {
        js.checkpointRevert(checkpoint);
        return .{ .success = false, .is_revert = false, .address = [_]u8{0} ** 20, .gas_remaining = 0, .return_data = &[_]u8{}, .gas_refunded = 0, .state_gas_used = 0, .state_gas_remaining = gas_reservoir };
    }
    if (primitives.isEnabledIn(spec_id, .london)) {
        if (deployed_raw.len > 0 and deployed_raw[0] == 0xEF) {
            js.checkpointRevert(checkpoint);
            return .{ .success = false, .is_revert = false, .address = [_]u8{0} ** 20, .gas_remaining = 0, .return_data = &[_]u8{}, .gas_refunded = 0, .state_gas_used = 0, .state_gas_remaining = gas_reservoir };
        }
    }

    var gas_after_deposit: u64 = undefined;
    var remaining_reservoir = gas_reservoir;
    var code_deposit_state_gas: u64 = 0;
    var code_deposit_spilled: u64 = 0;
    if (primitives.isEnabledIn(spec_id, .amsterdam)) {
        const code_words = (deployed_raw.len + 31) / 32;
        const regular_deposit = gas_costs.G_KECCAK256WORD * @as(u64, code_words);
        if (gas_remaining < regular_deposit) {
            js.checkpointRevert(checkpoint);
            return .{ .success = false, .is_revert = false, .address = [_]u8{0} ** 20, .gas_remaining = 0, .return_data = &[_]u8{}, .gas_refunded = 0, .state_gas_used = 0, .state_gas_remaining = remaining_reservoir };
        }
        var gas_after_regular = gas_remaining - regular_deposit;
        const cpsb = gas_costs.costPerStateByte(host.block.gas_limit);
        code_deposit_state_gas = @as(u64, deployed_raw.len) * cpsb;
        if (code_deposit_state_gas > 0) {
            if (remaining_reservoir >= code_deposit_state_gas) {
                remaining_reservoir -= code_deposit_state_gas;
            } else if (remaining_reservoir + gas_after_regular >= code_deposit_state_gas) {
                const spill = code_deposit_state_gas - remaining_reservoir;
                remaining_reservoir = 0;
                gas_after_regular -= spill;
                code_deposit_spilled = spill;
            } else {
                js.checkpointRevert(checkpoint);
                return .{ .success = false, .is_revert = false, .address = [_]u8{0} ** 20, .gas_remaining = 0, .return_data = &[_]u8{}, .gas_refunded = 0, .state_gas_used = 0, .state_gas_remaining = remaining_reservoir };
            }
        }
        _ = is_opcode_create;
        gas_after_deposit = gas_after_regular;
    } else {
        const deposit_cost = gas_costs.G_CODEDEPOSIT * @as(u64, @intCast(deployed_raw.len));
        if (gas_remaining < deposit_cost) {
            if (primitives.isEnabledIn(spec_id, .homestead)) {
                js.checkpointRevert(checkpoint);
                return CreateResult.failure();
            } else {
                js.checkpointCommit();
                return .{ .success = true, .is_revert = false, .address = new_addr, .gas_remaining = gas_remaining, .return_data = &[_]u8{}, .gas_refunded = gas_refunded, .state_gas_used = 0, .state_gas_remaining = 0 };
            }
        }
        gas_after_deposit = gas_remaining - deposit_cost;
    }

    if (deployed_raw.len > 0) {
        const deployed_copy = alloc_mod.get().dupe(u8, deployed_raw) catch {
            js.checkpointRevert(checkpoint);
            return CreateResult.failure();
        };
        var code_hash: [32]u8 = undefined;
        accel.keccak256(deployed_copy, &code_hash);
        const bc = bytecode_mod.Bytecode.newRaw(deployed_copy);
        js.setCodeWithHash(new_addr, bc, code_hash);
    }

    js.checkpointCommit();
    return .{ .success = true, .is_revert = false, .address = new_addr, .gas_remaining = gas_after_deposit, .return_data = &[_]u8{}, .gas_refunded = gas_refunded, .state_gas_used = code_deposit_state_gas, .state_gas_remaining = remaining_reservoir, .state_gas_spilled = code_deposit_spilled };
}

// ---------------------------------------------------------------------------
// Conversion helpers (exported for use by opcode handlers)
// ---------------------------------------------------------------------------

/// Convert an Address (20 bytes big-endian) to U256
pub fn addressToU256(addr: primitives.Address) primitives.U256 {
    var result: primitives.U256 = 0;
    for (addr) |byte| {
        result = (result << 8) | byte;
    }
    return result;
}

/// Convert U256 to Address (take low 20 bytes)
pub fn u256ToAddress(val: primitives.U256) primitives.Address {
    var addr: primitives.Address = [_]u8{0} ** 20;
    var v = val;
    var i: usize = 20;
    while (i > 0) {
        i -= 1;
        addr[i] = @intCast(v & 0xFF);
        v >>= 8;
    }
    return addr;
}

/// Convert a 32-byte Hash to U256 (big-endian)
pub fn hashToU256(h: primitives.Hash) primitives.U256 {
    var result: primitives.U256 = 0;
    for (h) |byte| {
        result = (result << 8) | byte;
    }
    return result;
}

/// Convert U256 to a 32-byte Hash (big-endian)
pub fn u256ToHash(val: primitives.U256) primitives.Hash {
    var h: primitives.Hash = [_]u8{0} ** 32;
    var v = val;
    var i: usize = 32;
    while (i > 0) {
        i -= 1;
        h[i] = @intCast(v & 0xFF);
        v >>= 8;
    }
    return h;
}

/// Derive CREATE contract address: keccak256(rlp([sender, nonce]))[12:]
pub fn createAddress(sender: primitives.Address, nonce: u64) primitives.Address {
    var buf: [30]u8 = undefined;
    var pos: usize = 0;
    buf[pos] = 0x94;
    pos += 1;
    @memcpy(buf[pos .. pos + 20], &sender);
    pos += 20;
    if (nonce == 0) {
        buf[pos] = 0x80;
        pos += 1;
    } else if (nonce < 0x80) {
        buf[pos] = @intCast(nonce);
        pos += 1;
    } else {
        var tmp: [8]u8 = undefined;
        var len: usize = 0;
        var n = nonce;
        while (n > 0) : (n >>= 8) {
            len += 1;
        }
        var m = nonce;
        var idx: usize = len;
        while (idx > 0) : (idx -= 1) {
            tmp[idx - 1] = @intCast(m & 0xFF);
            m >>= 8;
        }
        buf[pos] = @intCast(0x80 + len);
        pos += 1;
        @memcpy(buf[pos .. pos + len], tmp[0..len]);
        pos += len;
    }
    var rlp: [31]u8 = undefined;
    rlp[0] = @intCast(0xC0 + pos);
    @memcpy(rlp[1 .. 1 + pos], buf[0..pos]);
    var hash: [32]u8 = undefined;
    accel.keccak256(rlp[0 .. 1 + pos], &hash);
    var addr: primitives.Address = undefined;
    @memcpy(&addr, hash[12..32]);
    return addr;
}

/// Derive CREATE2 contract address: keccak256(0xff ++ sender ++ salt ++ keccak256(init_code))[12:]
pub fn create2Address(sender: primitives.Address, salt: primitives.U256, init_code_hash: [32]u8) primitives.Address {
    var preimage: [85]u8 = undefined;
    preimage[0] = 0xFF;
    @memcpy(preimage[1..21], &sender);
    var salt_bytes: [32]u8 = undefined;
    var s = salt;
    var i: usize = 32;
    while (i > 0) : (i -= 1) {
        salt_bytes[i - 1] = @intCast(s & 0xFF);
        s >>= 8;
    }
    @memcpy(preimage[21..53], &salt_bytes);
    @memcpy(preimage[53..85], &init_code_hash);
    var hash: [32]u8 = undefined;
    accel.keccak256(&preimage, &hash);
    var addr: primitives.Address = undefined;
    @memcpy(&addr, hash[12..32]);
    return addr;
}
