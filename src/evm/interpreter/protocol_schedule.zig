const std = @import("std");
const primitives = @import("primitives");
const bytecode_mod = @import("bytecode");
const gas_costs = @import("gas_costs.zig");
const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const InstructionFn = interpreter_mod.InstructionFn;
const InstructionContext = @import("instruction_context.zig").InstructionContext;
const opcodes = @import("opcodes/main.zig");

// Re-export dispatch table types so callers that previously used
// `protocol_schedule.InstructionTable` continue to compile unchanged.
pub const InstructionEntry = interpreter_mod.InstructionEntry;
pub const InstructionTable = interpreter_mod.InstructionTable;

// ---------------------------------------------------------------------------
// Prebuilt comptime instruction tables
// ---------------------------------------------------------------------------

/// Osaka instruction table (no Amsterdam extensions). Computed at comptime.
pub const OSAKA_TABLE: InstructionTable = makeInstructionTableComptime(primitives.OSAKA);

/// Amsterdam instruction table (Osaka + Amsterdam EIPs). Computed at comptime.
pub const AMSTERDAM_TABLE: InstructionTable = makeInstructionTableComptime(primitives.AMSTERDAM);

/// Select the appropriate prebuilt table for a runtime SpecId.
pub fn tableForSpec(spec_id: primitives.SpecId) *const InstructionTable {
    return if (primitives.isEnabledIn(spec_id, .amsterdam)) &AMSTERDAM_TABLE else &OSAKA_TABLE;
}

// ---------------------------------------------------------------------------
// Public API — backward-compatible wrapper
// ---------------------------------------------------------------------------

/// Build an instruction table for the given spec (copies from a prebuilt comptime table).
/// Callers that need a pointer should use tableForSpec() instead.
pub fn makeInstructionTable(spec_id: primitives.SpecId) InstructionTable {
    return if (primitives.isEnabledIn(spec_id, .amsterdam)) AMSTERDAM_TABLE else OSAKA_TABLE;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn entry(func: InstructionFn, static_gas: u64) InstructionEntry {
    return .{ .func = func, .static_gas = static_gas };
}

/// Wrap a spec-parameterized opcode function into an InstructionFn.
/// The spec is baked in at comptime, eliminating all runtime fork checks.
fn specialize(
    comptime spec: primitives.Spec,
    comptime func: anytype,
) InstructionFn {
    const S = struct {
        fn f(ctx: *InstructionContext) void {
            func(spec, ctx);
        }
    };
    return S.f;
}

fn makeInstructionTableComptime(comptime spec: primitives.Spec) InstructionTable {
    @setEvalBranchQuota(100000);
    var table = [_]InstructionEntry{InstructionEntry.unknown()} ** 256;

    // System
    table[bytecode_mod.STOP] = entry(opcodes.opStop, gas_costs.G_ZERO);

    // Arithmetic
    table[bytecode_mod.ADD] = entry(opcodes.opAdd, gas_costs.G_VERYLOW);
    table[bytecode_mod.MUL] = entry(opcodes.opMul, gas_costs.G_LOW);
    table[bytecode_mod.SUB] = entry(opcodes.opSub, gas_costs.G_VERYLOW);
    table[bytecode_mod.DIV] = entry(opcodes.opDiv, gas_costs.G_LOW);
    table[bytecode_mod.SDIV] = entry(opcodes.opSdiv, gas_costs.G_LOW);
    table[bytecode_mod.MOD] = entry(opcodes.opMod, gas_costs.G_LOW);
    table[bytecode_mod.SMOD] = entry(opcodes.opSmod, gas_costs.G_LOW);
    table[bytecode_mod.ADDMOD] = entry(opcodes.opAddmod, gas_costs.G_MID);
    table[bytecode_mod.MULMOD] = entry(opcodes.opMulmod, gas_costs.G_MID);
    table[bytecode_mod.EXP] = entry(opcodes.opExp, gas_costs.G_EXP);
    table[bytecode_mod.SIGNEXTEND] = entry(opcodes.opSignextend, gas_costs.G_LOW);

    // Comparison
    table[bytecode_mod.LT] = entry(opcodes.opLt, gas_costs.G_VERYLOW);
    table[bytecode_mod.GT] = entry(opcodes.opGt, gas_costs.G_VERYLOW);
    table[bytecode_mod.SLT] = entry(opcodes.opSlt, gas_costs.G_VERYLOW);
    table[bytecode_mod.SGT] = entry(opcodes.opSgt, gas_costs.G_VERYLOW);
    table[bytecode_mod.EQ] = entry(opcodes.opEq, gas_costs.G_VERYLOW);
    table[bytecode_mod.ISZERO] = entry(opcodes.opIsZero, gas_costs.G_VERYLOW);

    // Bitwise
    table[bytecode_mod.AND] = entry(opcodes.opAnd, gas_costs.G_VERYLOW);
    table[bytecode_mod.OR] = entry(opcodes.opOr, gas_costs.G_VERYLOW);
    table[bytecode_mod.XOR] = entry(opcodes.opXor, gas_costs.G_VERYLOW);
    table[bytecode_mod.NOT] = entry(opcodes.opNot, gas_costs.G_VERYLOW);
    table[bytecode_mod.BYTE] = entry(opcodes.opByte, gas_costs.G_VERYLOW);

    // Shifts (EIP-145 Constantinople, always active)
    table[bytecode_mod.SHL] = entry(opcodes.opShl, gas_costs.G_VERYLOW);
    table[bytecode_mod.SHR] = entry(opcodes.opShr, gas_costs.G_VERYLOW);
    table[bytecode_mod.SAR] = entry(opcodes.opSar, gas_costs.G_VERYLOW);

    // Osaka: CLZ (EIP-7939)
    table[bytecode_mod.CLZ] = entry(opcodes.opClz, gas_costs.G_LOW);

    // Keccak256
    table[bytecode_mod.KECCAK256] = entry(opcodes.opKeccak256, gas_costs.G_KECCAK256);

    // Stack
    table[bytecode_mod.POP] = entry(opcodes.opPop, gas_costs.G_BASE);
    table[bytecode_mod.PUSH0] = entry(opcodes.opPush0, gas_costs.G_BASE);

    // PUSH1..PUSH32
    inline for (0..32) |i| {
        table[bytecode_mod.PUSH1 + i] = entry(opcodes.makePushFn(i + 1), gas_costs.G_VERYLOW);
    }

    // DUP1..DUP16
    inline for (0..16) |i| {
        table[bytecode_mod.DUP1 + i] = entry(opcodes.makeDupFn(i + 1), gas_costs.G_VERYLOW);
    }

    // SWAP1..SWAP16
    inline for (0..16) |i| {
        table[bytecode_mod.SWAP1 + i] = entry(opcodes.makeSwapFn(i + 1), gas_costs.G_VERYLOW);
    }

    // Memory
    table[bytecode_mod.MLOAD] = entry(opcodes.opMload, gas_costs.G_VERYLOW);
    table[bytecode_mod.MSTORE] = entry(opcodes.opMstore, gas_costs.G_VERYLOW);
    table[bytecode_mod.MSTORE8] = entry(opcodes.opMstore8, gas_costs.G_VERYLOW);
    table[bytecode_mod.MSIZE] = entry(opcodes.opMsize, gas_costs.G_BASE);
    table[bytecode_mod.MCOPY] = entry(opcodes.opMcopy, gas_costs.G_VERYLOW);

    // Control flow
    table[bytecode_mod.JUMP] = entry(opcodes.opJump, gas_costs.G_MID);
    table[bytecode_mod.JUMPI] = entry(opcodes.opJumpi, gas_costs.G_HIGH);
    table[bytecode_mod.PC] = entry(opcodes.opPc, gas_costs.G_BASE);
    table[bytecode_mod.GAS] = entry(opcodes.opGas, gas_costs.G_BASE);
    table[bytecode_mod.JUMPDEST] = entry(opcodes.opJumpdest, gas_costs.G_JUMPDEST);

    // Environment: no-host opcodes
    table[bytecode_mod.ADDRESS] = entry(opcodes.opAddress, gas_costs.G_BASE);
    table[bytecode_mod.CALLER] = entry(opcodes.opCaller, gas_costs.G_BASE);
    table[bytecode_mod.CALLVALUE] = entry(opcodes.opCallvalue, gas_costs.G_BASE);
    table[bytecode_mod.CALLDATASIZE] = entry(opcodes.opCalldatasize, gas_costs.G_BASE);
    table[bytecode_mod.CALLDATALOAD] = entry(opcodes.opCalldataload, gas_costs.G_VERYLOW);
    table[bytecode_mod.CALLDATACOPY] = entry(opcodes.opCalldatacopy, gas_costs.G_VERYLOW);
    table[bytecode_mod.CODESIZE] = entry(opcodes.opCodesize, gas_costs.G_BASE);
    table[bytecode_mod.CODECOPY] = entry(opcodes.opCodecopy, gas_costs.G_VERYLOW);
    table[bytecode_mod.RETURNDATASIZE] = entry(opcodes.opReturndatasize, gas_costs.G_BASE);
    table[bytecode_mod.RETURNDATACOPY] = entry(opcodes.opReturndatacopy, gas_costs.G_VERYLOW);

    // Environment: host-requiring
    table[bytecode_mod.ORIGIN] = entry(opcodes.opOrigin, gas_costs.G_BASE);
    table[bytecode_mod.GASPRICE] = entry(opcodes.opGasprice, gas_costs.G_BASE);
    // Berlin+ dynamic gas: static_gas = 0
    table[bytecode_mod.EXTCODESIZE] = entry(opcodes.opExtcodesize, 0);
    table[bytecode_mod.EXTCODECOPY] = entry(opcodes.opExtcodecopy, 0);
    table[bytecode_mod.EXTCODEHASH] = entry(opcodes.opExtcodehash, 0);
    table[bytecode_mod.BLOCKHASH] = entry(opcodes.opBlockhash, 20);
    table[bytecode_mod.COINBASE] = entry(opcodes.opCoinbase, gas_costs.G_BASE);
    table[bytecode_mod.TIMESTAMP] = entry(opcodes.opTimestamp, gas_costs.G_BASE);
    table[bytecode_mod.NUMBER] = entry(opcodes.opNumber, gas_costs.G_BASE);
    table[bytecode_mod.DIFFICULTY] = entry(opcodes.opDifficulty, gas_costs.G_BASE);
    table[bytecode_mod.GASLIMIT] = entry(opcodes.opGaslimit, gas_costs.G_BASE);
    table[bytecode_mod.CHAINID] = entry(opcodes.opChainid, gas_costs.G_BASE);
    table[bytecode_mod.BASEFEE] = entry(opcodes.opBasefee, gas_costs.G_BASE);
    table[bytecode_mod.BLOBHASH] = entry(opcodes.opBlobhash, gas_costs.G_VERYLOW);
    table[bytecode_mod.BLOBBASEFEE] = entry(opcodes.opBlobbasefee, gas_costs.G_BASE);
    table[bytecode_mod.BALANCE] = entry(opcodes.opBalance, 0);
    table[bytecode_mod.SELFBALANCE] = entry(opcodes.opSelfbalance, gas_costs.G_LOW);

    // Storage — Berlin+ dynamic (static_gas = 0)
    table[bytecode_mod.SLOAD] = entry(opcodes.opSload, 0);
    table[bytecode_mod.SSTORE] = entry(specialize(spec, opcodes.opSstoreSpec), 0);

    // Transient storage (EIP-1153 Cancun, always active)
    table[bytecode_mod.TLOAD] = entry(opcodes.opTload, gas_costs.WARM_SLOAD);
    table[bytecode_mod.TSTORE] = entry(opcodes.opTstore, gas_costs.WARM_SLOAD);

    // Blob opcodes (EIP-4844 Cancun, always active)

    // Logs
    table[bytecode_mod.LOG0] = entry(opcodes.opLog0, gas_costs.G_LOG);
    table[bytecode_mod.LOG1] = entry(opcodes.opLog1, gas_costs.G_LOG);
    table[bytecode_mod.LOG2] = entry(opcodes.opLog2, gas_costs.G_LOG);
    table[bytecode_mod.LOG3] = entry(opcodes.opLog3, gas_costs.G_LOG);
    table[bytecode_mod.LOG4] = entry(opcodes.opLog4, gas_costs.G_LOG);

    // System
    table[bytecode_mod.RETURN] = entry(opcodes.opReturn, 0);
    table[bytecode_mod.REVERT] = entry(opcodes.opRevert, 0);
    table[bytecode_mod.INVALID] = entry(opcodes.opInvalid, 0);
    table[bytecode_mod.SELFDESTRUCT] = entry(specialize(spec, opcodes.opSelfdestructSpec), gas_costs.G_SELFDESTRUCT);

    // Calls — all dynamic gas; spec-sensitive for Amsterdam state gas
    table[bytecode_mod.CALL] = entry(specialize(spec, opcodes.opCallSpec), 0);
    table[bytecode_mod.CALLCODE] = entry(specialize(spec, opcodes.opCallcodeSpec), 0);
    table[bytecode_mod.DELEGATECALL] = entry(specialize(spec, opcodes.opDelegatecallSpec), 0);
    table[bytecode_mod.STATICCALL] = entry(specialize(spec, opcodes.opStaticcallSpec), 0);

    // Create — spec-sensitive for Amsterdam state gas and initcode limit
    table[bytecode_mod.CREATE] = entry(specialize(spec, opcodes.opCreateSpec), 0);
    table[bytecode_mod.CREATE2] = entry(specialize(spec, opcodes.opCreate2Spec), 0);

    // Amsterdam-only opcodes
    if (spec.amsterdam) {
        table[bytecode_mod.SLOTNUM] = entry(opcodes.opSlotnum, gas_costs.G_BASE);
        table[bytecode_mod.DUPN] = entry(opcodes.opDupN, gas_costs.G_VERYLOW);
        table[bytecode_mod.SWAPN] = entry(opcodes.opSwapN, gas_costs.G_VERYLOW);
        table[bytecode_mod.EXCHANGE] = entry(opcodes.opExchange, gas_costs.G_VERYLOW);
    }

    return table;
}
