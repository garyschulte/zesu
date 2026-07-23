const std = @import("std");
const primitives = @import("primitives");
const bytecode_mod = @import("bytecode");
const gas_costs = @import("gas_costs.zig");
const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const opcodes = @import("opcodes/main.zig");

// Re-export dispatch table types so callers that previously used
// `protocol_schedule.InstructionTable` continue to compile unchanged.
pub const InstructionEntry = interpreter_mod.InstructionEntry;
pub const InstructionTable = interpreter_mod.InstructionTable;

// ---------------------------------------------------------------------------
// Instruction table construction
// ---------------------------------------------------------------------------

fn entry(comptime DB: type, func: interpreter_mod.InstructionFn(DB), static_gas: u64) InstructionEntry(DB) {
    return .{ .func = func, .static_gas = static_gas };
}

pub fn makeInstructionTable(comptime DB: type, spec: primitives.SpecId) InstructionTable(DB) {
    var table = makeFrontierTable(DB);

    if (primitives.isEnabledIn(spec, .homestead)) applyHomesteadChanges(DB, &table);
    if (primitives.isEnabledIn(spec, .tangerine)) applyTangerineChanges(DB, &table);
    if (primitives.isEnabledIn(spec, .byzantium)) applyByzantiumChanges(DB, &table);
    if (primitives.isEnabledIn(spec, .constantinople)) applyConstantinopleChanges(DB, &table);
    if (primitives.isEnabledIn(spec, .istanbul)) applyIstanbulChanges(DB, &table);
    if (primitives.isEnabledIn(spec, .berlin)) applyBerlinChanges(DB, &table);
    if (primitives.isEnabledIn(spec, .london)) applyLondonChanges(DB, &table);
    if (primitives.isEnabledIn(spec, .shanghai)) applyShanghaiChanges(DB, &table);
    if (primitives.isEnabledIn(spec, .cancun)) applyCancunChanges(DB, &table);
    if (primitives.isEnabledIn(spec, .osaka)) applyOsakaChanges(DB, &table);
    if (primitives.isEnabledIn(spec, .amsterdam)) applyAmsterdamChanges(DB, &table);

    return table;
}

fn makeFrontierTable(comptime DB: type) InstructionTable(DB) {
    const ops = opcodes.Ops(DB);
    var table = [_]InstructionEntry(DB){InstructionEntry(DB).unknown()} ** 256;

    // System
    table[bytecode_mod.STOP] = entry(DB, ops.opStop, gas_costs.G_ZERO);

    // Arithmetic
    table[bytecode_mod.ADD] = entry(DB, ops.opAdd, gas_costs.G_VERYLOW);
    table[bytecode_mod.MUL] = entry(DB, ops.opMul, gas_costs.G_LOW);
    table[bytecode_mod.SUB] = entry(DB, ops.opSub, gas_costs.G_VERYLOW);
    table[bytecode_mod.DIV] = entry(DB, ops.opDiv, gas_costs.G_LOW);
    table[bytecode_mod.SDIV] = entry(DB, ops.opSdiv, gas_costs.G_LOW);
    table[bytecode_mod.MOD] = entry(DB, ops.opMod, gas_costs.G_LOW);
    table[bytecode_mod.SMOD] = entry(DB, ops.opSmod, gas_costs.G_LOW);
    table[bytecode_mod.ADDMOD] = entry(DB, ops.opAddmod, gas_costs.G_MID);
    table[bytecode_mod.MULMOD] = entry(DB, ops.opMulmod, gas_costs.G_MID);
    table[bytecode_mod.EXP] = entry(DB, ops.opExp, gas_costs.G_EXP);
    table[bytecode_mod.SIGNEXTEND] = entry(DB, ops.opSignextend, gas_costs.G_LOW);

    // Comparison
    table[bytecode_mod.LT] = entry(DB, ops.opLt, gas_costs.G_VERYLOW);
    table[bytecode_mod.GT] = entry(DB, ops.opGt, gas_costs.G_VERYLOW);
    table[bytecode_mod.SLT] = entry(DB, ops.opSlt, gas_costs.G_VERYLOW);
    table[bytecode_mod.SGT] = entry(DB, ops.opSgt, gas_costs.G_VERYLOW);
    table[bytecode_mod.EQ] = entry(DB, ops.opEq, gas_costs.G_VERYLOW);
    table[bytecode_mod.ISZERO] = entry(DB, ops.opIsZero, gas_costs.G_VERYLOW);

    // Bitwise
    table[bytecode_mod.AND] = entry(DB, ops.opAnd, gas_costs.G_VERYLOW);
    table[bytecode_mod.OR] = entry(DB, ops.opOr, gas_costs.G_VERYLOW);
    table[bytecode_mod.XOR] = entry(DB, ops.opXor, gas_costs.G_VERYLOW);
    table[bytecode_mod.NOT] = entry(DB, ops.opNot, gas_costs.G_VERYLOW);
    table[bytecode_mod.BYTE] = entry(DB, ops.opByte, gas_costs.G_VERYLOW);

    // Keccak256
    table[bytecode_mod.KECCAK256] = entry(DB, ops.opKeccak256, gas_costs.G_KECCAK256);

    // Stack
    table[bytecode_mod.POP] = entry(DB, ops.opPop, gas_costs.G_BASE);

    // Memory
    table[bytecode_mod.MLOAD] = entry(DB, ops.opMload, gas_costs.G_VERYLOW);
    table[bytecode_mod.MSTORE] = entry(DB, ops.opMstore, gas_costs.G_VERYLOW);
    table[bytecode_mod.MSTORE8] = entry(DB, ops.opMstore8, gas_costs.G_VERYLOW);
    table[bytecode_mod.MSIZE] = entry(DB, ops.opMsize, gas_costs.G_BASE);

    // Control flow
    table[bytecode_mod.JUMP] = entry(DB, ops.opJump, gas_costs.G_MID);
    table[bytecode_mod.JUMPI] = entry(DB, ops.opJumpi, gas_costs.G_HIGH);
    table[bytecode_mod.PC] = entry(DB, ops.opPc, gas_costs.G_BASE);
    table[bytecode_mod.GAS] = entry(DB, ops.opGas, gas_costs.G_BASE);
    table[bytecode_mod.JUMPDEST] = entry(DB, ops.opJumpdest, gas_costs.G_JUMPDEST);

    // PUSH1..PUSH32
    inline for (0..32) |i| {
        table[bytecode_mod.PUSH1 + i] = entry(DB, ops.makePushFn(i + 1), gas_costs.G_VERYLOW);
    }

    // DUP1..DUP16
    inline for (0..16) |i| {
        table[bytecode_mod.DUP1 + i] = entry(DB, ops.makeDupFn(i + 1), gas_costs.G_VERYLOW);
    }

    // SWAP1..SWAP16
    inline for (0..16) |i| {
        table[bytecode_mod.SWAP1 + i] = entry(DB, ops.makeSwapFn(i + 1), gas_costs.G_VERYLOW);
    }

    // Environment: no-host opcodes (interpreter.input fields)
    table[bytecode_mod.ADDRESS] = entry(DB, ops.opAddress, gas_costs.G_BASE);
    table[bytecode_mod.CALLER] = entry(DB, ops.opCaller, gas_costs.G_BASE);
    table[bytecode_mod.CALLVALUE] = entry(DB, ops.opCallvalue, gas_costs.G_BASE);
    table[bytecode_mod.CALLDATASIZE] = entry(DB, ops.opCalldatasize, gas_costs.G_BASE);
    table[bytecode_mod.CALLDATALOAD] = entry(DB, ops.opCalldataload, gas_costs.G_VERYLOW);
    table[bytecode_mod.CALLDATACOPY] = entry(DB, ops.opCalldatacopy, gas_costs.G_VERYLOW);
    table[bytecode_mod.CODESIZE] = entry(DB, ops.opCodesize, gas_costs.G_BASE);
    table[bytecode_mod.CODECOPY] = entry(DB, ops.opCodecopy, gas_costs.G_VERYLOW);
    // Environment: host-requiring opcodes
    table[bytecode_mod.ORIGIN] = entry(DB, ops.opOrigin, gas_costs.G_BASE);
    table[bytecode_mod.GASPRICE] = entry(DB, ops.opGasprice, gas_costs.G_BASE);
    // Frontier/Homestead gas (20 each); Tangerine Whistle (EIP-150) raises these to 700/700/400.
    table[bytecode_mod.EXTCODESIZE] = entry(DB, ops.opExtcodesize, 20);
    table[bytecode_mod.EXTCODECOPY] = entry(DB, ops.opExtcodecopy, 20);
    table[bytecode_mod.BLOCKHASH] = entry(DB, ops.opBlockhash, 20);
    table[bytecode_mod.COINBASE] = entry(DB, ops.opCoinbase, gas_costs.G_BASE);
    table[bytecode_mod.TIMESTAMP] = entry(DB, ops.opTimestamp, gas_costs.G_BASE);
    table[bytecode_mod.NUMBER] = entry(DB, ops.opNumber, gas_costs.G_BASE);
    table[bytecode_mod.DIFFICULTY] = entry(DB, ops.opDifficulty, gas_costs.G_BASE);
    table[bytecode_mod.GASLIMIT] = entry(DB, ops.opGaslimit, gas_costs.G_BASE);
    table[bytecode_mod.BALANCE] = entry(DB, ops.opBalance, 20);

    // Storage — Frontier gas (50); Tangerine reprices to 200, Istanbul to 800, Berlin to dynamic.
    table[bytecode_mod.SLOAD] = entry(DB, ops.opSload, gas_costs.G_SLOAD_FRONTIER);
    table[bytecode_mod.SSTORE] = entry(DB, ops.opSstore, 0);

    // Logs
    table[bytecode_mod.LOG0] = entry(DB, ops.opLog0, gas_costs.G_LOG);
    table[bytecode_mod.LOG1] = entry(DB, ops.opLog1, gas_costs.G_LOG);
    table[bytecode_mod.LOG2] = entry(DB, ops.opLog2, gas_costs.G_LOG);
    table[bytecode_mod.LOG3] = entry(DB, ops.opLog3, gas_costs.G_LOG);
    table[bytecode_mod.LOG4] = entry(DB, ops.opLog4, gas_costs.G_LOG);

    // System
    table[bytecode_mod.RETURN] = entry(DB, ops.opReturn, 0);
    table[bytecode_mod.INVALID] = entry(DB, ops.opInvalid, 0);
    // SELFDESTRUCT: static_gas=0 for Frontier/Homestead; EIP-150 (Tangerine) raises it to 5000.
    table[bytecode_mod.SELFDESTRUCT] = entry(DB, ops.opSelfdestruct, 0);

    // Calls (all-dynamic gas, static_gas=0)
    table[bytecode_mod.CALL] = entry(DB, ops.opCall, 0);
    table[bytecode_mod.CALLCODE] = entry(DB, ops.opCallcode, 0);

    // CREATE: all gas is dynamic (G_CREATE base + initcode word gas charged inside opCreate)
    // CREATE2 added in Constantinople (EIP-1014)
    table[bytecode_mod.CREATE] = entry(DB, ops.opCreate, 0);

    return table;
}

fn applyHomesteadChanges(comptime DB: type, table: *InstructionTable(DB)) void {
    // DELEGATECALL added in Homestead
    table[bytecode_mod.DELEGATECALL] = entry(DB, opcodes.Ops(DB).opDelegatecall, 0);
}

fn applyTangerineChanges(comptime DB: type, table: *InstructionTable(DB)) void {
    // EIP-150: repricing
    table[bytecode_mod.SLOAD].static_gas = gas_costs.G_SLOAD_TANGERINE;
    table[bytecode_mod.EXTCODESIZE].static_gas = 700;
    table[bytecode_mod.EXTCODECOPY].static_gas = 700;
    table[bytecode_mod.BALANCE].static_gas = 400;
    // EIP-150: SELFDESTRUCT raised from 0 to 5000
    table[bytecode_mod.SELFDESTRUCT].static_gas = gas_costs.G_SELFDESTRUCT;
}

fn applyByzantiumChanges(comptime DB: type, table: *InstructionTable(DB)) void {
    const ops = opcodes.Ops(DB);
    // EIP-211: RETURNDATASIZE / RETURNDATACOPY added in Byzantium
    table[bytecode_mod.RETURNDATASIZE] = entry(DB, ops.opReturndatasize, gas_costs.G_BASE);
    table[bytecode_mod.RETURNDATACOPY] = entry(DB, ops.opReturndatacopy, gas_costs.G_VERYLOW);
    // EIP-140: REVERT
    table[bytecode_mod.REVERT] = entry(DB, ops.opRevert, 0);
    // STATICCALL added
    table[bytecode_mod.STATICCALL] = entry(DB, ops.opStaticcall, 0);
}

fn applyConstantinopleChanges(comptime DB: type, table: *InstructionTable(DB)) void {
    const ops = opcodes.Ops(DB);
    // EXTCODEHASH added
    table[bytecode_mod.EXTCODEHASH] = entry(DB, ops.opExtcodehash, 400);
    // EIP-1014: CREATE2 — all gas is dynamic (charged inside opCreate2)
    table[bytecode_mod.CREATE2] = entry(DB, ops.opCreate2, 0);
    // EIP-145: Bitwise shifts
    table[bytecode_mod.SHL] = entry(DB, ops.opShl, gas_costs.G_VERYLOW);
    table[bytecode_mod.SHR] = entry(DB, ops.opShr, gas_costs.G_VERYLOW);
    table[bytecode_mod.SAR] = entry(DB, ops.opSar, gas_costs.G_VERYLOW);
}

fn applyIstanbulChanges(comptime DB: type, table: *InstructionTable(DB)) void {
    // EIP-1344: CHAINID
    table[bytecode_mod.CHAINID] = entry(DB, opcodes.Ops(DB).opChainid, gas_costs.G_BASE);
    // EIP-1884: Repricing
    table[bytecode_mod.SLOAD].static_gas = gas_costs.G_SLOAD_ISTANBUL;
    table[bytecode_mod.BALANCE].static_gas = 700;
    table[bytecode_mod.EXTCODEHASH].static_gas = 700;
    // EIP-1884: SELFBALANCE
    table[bytecode_mod.SELFBALANCE] = entry(DB, opcodes.Ops(DB).opSelfbalance, gas_costs.G_LOW);
}

fn applyBerlinChanges(comptime DB: type, table: *InstructionTable(DB)) void {
    // EIP-2929: cold/warm account and storage access; all gas is now dynamic
    table[bytecode_mod.SLOAD].static_gas = 0;
    table[bytecode_mod.BALANCE].static_gas = 0;
    table[bytecode_mod.EXTCODESIZE].static_gas = 0;
    table[bytecode_mod.EXTCODECOPY].static_gas = 0;
    table[bytecode_mod.EXTCODEHASH].static_gas = 0;
}

fn applyLondonChanges(comptime DB: type, table: *InstructionTable(DB)) void {
    // EIP-3198: BASEFEE
    table[bytecode_mod.BASEFEE] = entry(DB, opcodes.Ops(DB).opBasefee, gas_costs.G_BASE);
}

fn applyShanghaiChanges(comptime DB: type, table: *InstructionTable(DB)) void {
    // EIP-3855: PUSH0
    table[bytecode_mod.PUSH0] = entry(DB, opcodes.Ops(DB).opPush0, gas_costs.G_BASE);
}

fn applyCancunChanges(comptime DB: type, table: *InstructionTable(DB)) void {
    const ops = opcodes.Ops(DB);
    // EIP-5656: MCOPY
    table[bytecode_mod.MCOPY] = entry(DB, ops.opMcopy, gas_costs.G_VERYLOW);
    // EIP-1153: Transient storage
    table[bytecode_mod.TLOAD] = entry(DB, ops.opTload, gas_costs.WARM_SLOAD);
    table[bytecode_mod.TSTORE] = entry(DB, ops.opTstore, gas_costs.WARM_SLOAD);
    // EIP-4844: Blob opcodes
    table[bytecode_mod.BLOBHASH] = entry(DB, ops.opBlobhash, gas_costs.G_VERYLOW);
    table[bytecode_mod.BLOBBASEFEE] = entry(DB, ops.opBlobbasefee, gas_costs.G_BASE);
}

fn applyOsakaChanges(comptime DB: type, table: *InstructionTable(DB)) void {
    // EIP-7939: CLZ (Count Leading Zeros), gas cost = G_LOW (5)
    table[bytecode_mod.CLZ] = entry(DB, opcodes.Ops(DB).opClz, gas_costs.G_LOW);
}

fn applyAmsterdamChanges(comptime DB: type, table: *InstructionTable(DB)) void {
    const ops = opcodes.Ops(DB);
    // EIP-7843: SLOTNUM opcode — push beacon chain slot number
    table[bytecode_mod.SLOTNUM] = entry(DB, ops.opSlotnum, gas_costs.G_BASE);
    // EIP-8024: DUPN/SWAPN/EXCHANGE — generalized stack manipulation with 1-byte immediate
    table[bytecode_mod.DUPN] = entry(DB, ops.opDupN, gas_costs.G_VERYLOW);
    table[bytecode_mod.SWAPN] = entry(DB, ops.opSwapN, gas_costs.G_VERYLOW);
    table[bytecode_mod.EXCHANGE] = entry(DB, ops.opExchange, gas_costs.G_VERYLOW);
}
