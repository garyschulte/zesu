const arithmetic = @import("arithmetic.zig");
const bitwise = @import("bitwise.zig");
const comparison = @import("comparison.zig");
const stack = @import("stack.zig");
const control = @import("control.zig");
const memory = @import("memory.zig");
const keccak = @import("keccak.zig");
const environment = @import("environment.zig");
const host_ops = @import("host_ops.zig");
const system = @import("system.zig");
/// Exposed as `pub` (unlike the other per-file imports above) so callers
/// (e.g. mainnet_builder.zig's frame runner) can reach call.zig's
/// DB-agnostic resumeCall/resumeCreate/refundNewAccountLifo, which live
/// outside Ops(DB) since they never touch Host or InstructionContext.
pub const call_ops = @import("call.zig");

/// Flat re-export of every opcode handler, comptime-generic over DB — see
/// host.zig's Host(DB) doc comment. Each opXxx below is Ops(DB) from its
/// owning file; protocol_schedule.zig builds the dispatch table by calling
/// through this single generic namespace.
pub fn Ops(comptime DB: type) type {
    return struct {
        // Arithmetic operations
        pub const opAdd = arithmetic.Ops(DB).opAdd;
        pub const opSub = arithmetic.Ops(DB).opSub;
        pub const opMul = arithmetic.Ops(DB).opMul;
        pub const opDiv = arithmetic.Ops(DB).opDiv;
        pub const opSdiv = arithmetic.Ops(DB).opSdiv;
        pub const opMod = arithmetic.Ops(DB).opMod;
        pub const opSmod = arithmetic.Ops(DB).opSmod;
        pub const opAddmod = arithmetic.Ops(DB).opAddmod;
        pub const opMulmod = arithmetic.Ops(DB).opMulmod;
        pub const opExp = arithmetic.Ops(DB).opExp;
        pub const opSignextend = arithmetic.Ops(DB).opSignextend;

        // Bitwise operations
        pub const opAnd = bitwise.Ops(DB).opAnd;
        pub const opOr = bitwise.Ops(DB).opOr;
        pub const opXor = bitwise.Ops(DB).opXor;
        pub const opNot = bitwise.Ops(DB).opNot;
        pub const opByte = bitwise.Ops(DB).opByte;
        pub const opShl = bitwise.Ops(DB).opShl;
        pub const opShr = bitwise.Ops(DB).opShr;
        pub const opSar = bitwise.Ops(DB).opSar;
        pub const opClz = bitwise.Ops(DB).opClz;

        // Comparison operations
        pub const opLt = comparison.Ops(DB).opLt;
        pub const opGt = comparison.Ops(DB).opGt;
        pub const opSlt = comparison.Ops(DB).opSlt;
        pub const opSgt = comparison.Ops(DB).opSgt;
        pub const opEq = comparison.Ops(DB).opEq;
        pub const opIsZero = comparison.Ops(DB).opIsZero;

        // Stack operations — comptime generators for PUSH/DUP/SWAP families
        pub const opPop = stack.Ops(DB).opPop;
        pub const opPush0 = stack.Ops(DB).opPush0;
        pub const makePushFn = stack.Ops(DB).makePushFn;
        pub const makeDupFn = stack.Ops(DB).makeDupFn;
        pub const makeSwapFn = stack.Ops(DB).makeSwapFn;
        pub const opPushNImpl = stack.Ops(DB).opPushNImpl;
        pub const opDupNImpl = stack.Ops(DB).opDupNImpl;
        pub const opSwapNImpl = stack.Ops(DB).opSwapNImpl;
        pub const opDupN = stack.Ops(DB).opDupN;
        pub const opSwapN = stack.Ops(DB).opSwapN;
        pub const opExchange = stack.Ops(DB).opExchange;

        // Control flow operations
        pub const opStop = control.Ops(DB).opStop;
        pub const opJump = control.Ops(DB).opJump;
        pub const opJumpi = control.Ops(DB).opJumpi;
        pub const opJumpdest = control.Ops(DB).opJumpdest;
        pub const opPc = control.Ops(DB).opPc;
        pub const opGas = control.Ops(DB).opGas;

        // Memory operations
        pub const opMload = memory.Ops(DB).opMload;
        pub const opMstore = memory.Ops(DB).opMstore;
        pub const opMstore8 = memory.Ops(DB).opMstore8;
        pub const opMsize = memory.Ops(DB).opMsize;
        pub const opMcopy = memory.Ops(DB).opMcopy;

        // Keccak256 operation
        pub const opKeccak256 = keccak.Ops(DB).opKeccak256;

        // Environment opcodes (block/tx info, calldata, code access)
        pub const opAddress = environment.Ops(DB).opAddress;
        pub const opCaller = environment.Ops(DB).opCaller;
        pub const opCallvalue = environment.Ops(DB).opCallvalue;
        pub const opCalldatasize = environment.Ops(DB).opCalldatasize;
        pub const opCalldataload = environment.Ops(DB).opCalldataload;
        pub const opCalldatacopy = environment.Ops(DB).opCalldatacopy;
        pub const opCodesize = environment.Ops(DB).opCodesize;
        pub const opCodecopy = environment.Ops(DB).opCodecopy;
        pub const opReturndatasize = environment.Ops(DB).opReturndatasize;
        pub const opReturndatacopy = environment.Ops(DB).opReturndatacopy;
        pub const opOrigin = environment.Ops(DB).opOrigin;
        pub const opGasprice = environment.Ops(DB).opGasprice;
        pub const opCoinbase = environment.Ops(DB).opCoinbase;
        pub const opTimestamp = environment.Ops(DB).opTimestamp;
        pub const opNumber = environment.Ops(DB).opNumber;
        pub const opDifficulty = environment.Ops(DB).opDifficulty;
        pub const opGaslimit = environment.Ops(DB).opGaslimit;
        pub const opChainid = environment.Ops(DB).opChainid;
        pub const opBasefee = environment.Ops(DB).opBasefee;
        pub const opBlobhash = environment.Ops(DB).opBlobhash;
        pub const opBlobbasefee = environment.Ops(DB).opBlobbasefee;
        pub const opSlotnum = environment.Ops(DB).opSlotnum;

        // Host-requiring opcodes (account state, storage, logs, selfdestruct)
        pub const opBalance = host_ops.Ops(DB).opBalance;
        pub const opSelfbalance = host_ops.Ops(DB).opSelfbalance;
        pub const opExtcodesize = host_ops.Ops(DB).opExtcodesize;
        pub const opExtcodecopy = host_ops.Ops(DB).opExtcodecopy;
        pub const opExtcodehash = host_ops.Ops(DB).opExtcodehash;
        pub const opBlockhash = host_ops.Ops(DB).opBlockhash;
        pub const opSload = host_ops.Ops(DB).opSload;
        pub const opSstore = host_ops.Ops(DB).opSstore;
        pub const opTload = host_ops.Ops(DB).opTload;
        pub const opTstore = host_ops.Ops(DB).opTstore;
        pub const opLog0 = host_ops.Ops(DB).opLog0;
        pub const opLog1 = host_ops.Ops(DB).opLog1;
        pub const opLog2 = host_ops.Ops(DB).opLog2;
        pub const opLog3 = host_ops.Ops(DB).opLog3;
        pub const opLog4 = host_ops.Ops(DB).opLog4;
        pub const opSelfdestruct = host_ops.Ops(DB).opSelfdestruct;

        // System opcodes (RETURN, REVERT, INVALID)
        pub const opReturn = system.Ops(DB).opReturn;
        pub const opRevert = system.Ops(DB).opRevert;
        pub const opInvalid = system.Ops(DB).opInvalid;

        // Call family opcodes
        pub const opCall = call_ops.Ops(DB).opCall;
        pub const opCallcode = call_ops.Ops(DB).opCallcode;
        pub const opDelegatecall = call_ops.Ops(DB).opDelegatecall;
        pub const opStaticcall = call_ops.Ops(DB).opStaticcall;
        pub const opCreate = call_ops.Ops(DB).opCreate;
        pub const opCreate2 = call_ops.Ops(DB).opCreate2;
    };
}

// Gas constants re-exported from the single source of truth (DB-independent).
const gas_costs = @import("../gas_costs.zig");
pub const GAS_BASE = gas_costs.G_BASE;
pub const GAS_VERYLOW = gas_costs.G_VERYLOW;
pub const GAS_LOW = gas_costs.G_LOW;
pub const GAS_MID = gas_costs.G_MID;
pub const GAS_HIGH = gas_costs.G_HIGH;
pub const GAS_JUMPDEST = gas_costs.G_JUMPDEST;
pub const GAS_EXP = gas_costs.G_EXP;
pub const GAS_EXP_BYTE = gas_costs.G_EXPBYTE;
pub const GAS_KECCAK256 = gas_costs.G_KECCAK256;
pub const GAS_KECCAK256WORD = gas_costs.G_KECCAK256WORD;
pub const GAS_MEMORY = gas_costs.G_MEMORY;
