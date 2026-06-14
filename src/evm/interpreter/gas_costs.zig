const std = @import("std");
const primitives = @import("primitives");

// Base gas costs
pub const G_ZERO = 0;
pub const G_BASE = 2;
pub const G_VERYLOW = 3;
pub const G_LOW = 5;
pub const G_MID = 8;
pub const G_HIGH = 10;

// Special operation costs
pub const G_JUMPDEST = 1;
pub const G_SSET = 20000; // Storage set (from zero to non-zero)
pub const G_SRESET = 5000; // Storage reset (non-zero to non-zero or zero)

// Call costs
pub const G_CALL_FRONTIER = 40; // Frontier/Homestead CALL base gas
pub const G_CALL = 700; // Tangerine+ (EIP-150) through pre-Berlin CALL base gas
pub const COLD_ACCOUNT_ACCESS = 2600;
pub const WARM_ACCOUNT_ACCESS = 100;
pub const COLD_SLOAD = 2100;
pub const WARM_SLOAD = 100;
pub const CALL_STIPEND = 2300; // Gas gifted to callee on value-bearing CALL (not deducted from caller)

// Storage costs - Pre-Berlin
pub const G_SLOAD_FRONTIER = 50; // Frontier/Homestead SLOAD gas
pub const G_SLOAD_TANGERINE = 200; // Tangerine (EIP-150) through pre-Istanbul SLOAD gas
pub const G_SLOAD_ISTANBUL = 800; // Istanbul (EIP-1884) SLOAD gas

// Storage costs - Berlin and later (EIP-2929)
pub const G_SLOAD_BERLIN_COLD = 2100;
pub const G_SLOAD_BERLIN_WARM = 100;

// SSTORE costs (EIP-2200, EIP-2929, EIP-3529)
pub const SSTORE_SET = 20000;
pub const SSTORE_RESET = 5000;
pub const SSTORE_CLEARS_SCHEDULE = 15000; // Istanbul refund for clearing storage
// EIP-3529 (London): R_sclear reduced from 15000 → 4800 = SSTORE_RESET_GAS + ACCESS_LIST_STORAGE_KEY_COST (2900+1900)
pub const SSTORE_CLEARS_SCHEDULE_LONDON = 4800;

// EIP-8037 (Amsterdam): State creation gas constants
// GAS_STORAGE_UPDATE replaces SSTORE_SET for 0→nonzero writes (regular portion only)
pub const GAS_STORAGE_UPDATE: u64 = 5000;
// State bytes charged per operation (used with cost_per_state_byte)
pub const STATE_BYTES_PER_STORAGE_SET: u64 = 64;
pub const STATE_BYTES_PER_NEW_ACCOUNT: u64 = 120;
pub const STATE_BYTES_PER_AUTH_BASE: u64 = 23;
// EIP-8037: cap of upfront SSTOREs per system call; used to size system call reservoir.
pub const SYSTEM_MAX_SSTORES_PER_CALL: u64 = 16;
// EIP-7825: TX gas limit boundary for state gas reservoir split
pub const TX_MAX_GAS_LIMIT: u64 = 1 << 24; // 16,777,216

/// EIP-8037: cost_per_state_byte. bal-devnet-7 pins this to a fixed 1530.
pub fn costPerStateByte(block_gas_limit: u64) u64 {
    _ = block_gas_limit;
    return 1530;
}

// Create costs
pub const G_CREATE = 32000;
pub const G_CODEDEPOSIT = 200; // Per byte of deployed code

// Transaction costs
pub const G_TRANSACTION = 21000;
pub const G_TXCREATE = 32000;
pub const G_TXDATAZERO = 4;
pub const G_TXDATANONZERO = 16; // Pre-Istanbul
pub const G_TXDATANONZERO_ISTANBUL = 16; // Actually same
pub const G_TXDATANONZERO_EIP2028 = 16; // After EIP-2028

// Memory expansion cost
pub const G_MEMORY = 3; // Per word

// Copy operations
pub const G_COPY = 3; // Per word

// Log costs
pub const G_LOG = 375;
pub const G_LOGDATA = 8;
pub const G_LOGTOPIC = 375;

// SHA3/Keccak costs
pub const G_KECCAK256 = 30;
pub const G_KECCAK256WORD = 6;

// EXP costs
pub const G_EXP = 10;
pub const G_EXPBYTE = 50; // Post-Spurious Dragon (EIP-160)
pub const G_EXPBYTE_FRONTIER = 10; // Pre-Spurious Dragon

// SELFDESTRUCT
pub const G_SELFDESTRUCT = 5000;
pub const R_SELFDESTRUCT = 24000; // Refund

// Memory expansion cost formula
// cost = memory_size_word * G_MEMORY + (memory_size_word ^ 2) / 512
pub fn memoryExpansionCost(current_words: usize, new_words: usize) u64 {
    if (new_words <= current_words) return 0;

    const new_cost = memoryCost(new_words);
    const current_cost = memoryCost(current_words);

    return new_cost - current_cost;
}

fn memoryCost(num_words: usize) u64 {
    const n: u64 = @intCast(num_words);
    const linear = std.math.mul(u64, n, G_MEMORY) catch return std.math.maxInt(u64);
    const quadratic = (std.math.mul(u64, n, n) catch return std.math.maxInt(u64)) / 512;
    return std.math.add(u64, linear, quadratic) catch std.math.maxInt(u64);
}

// Calculate memory size in words (rounded up)
pub fn toWordSize(size: usize) usize {
    return (size + 31) / 32;
}

// Get SLOAD gas cost (always Berlin+ cold/warm access model post-Osaka)
pub fn getSloadCost(is_cold: bool) u64 {
    return if (is_cold) COLD_SLOAD else WARM_SLOAD;
}

// SSTORE gas cost result
pub const SstoreGas = struct {
    gas_cost: u64,
    gas_refund: i64,
    /// EIP-8037 (Amsterdam+): state gas to charge via spendStateGas. 0 for pre-Amsterdam.
    state_gas: u64 = 0,
    /// EIP-8037 (Amsterdam+): state gas to refund back to reservoir (SSTORE restores zero).
    state_gas_refund: u64 = 0,
};

/// Always returns London+ R_sclear = 4800 (pre-Osaka forks are not supported).
fn sstoreClearsRefund() i64 {
    return SSTORE_CLEARS_SCHEDULE_LONDON;
}

/// Calculate SSTORE gas cost (EIP-2200/EIP-2929/EIP-8037).
/// Pre-Osaka forks are not supported; all Berlin/London/Istanbul behavior is unconditional.
pub fn getSstoreCost(
    is_amsterdam: bool,
    original: primitives.U256,
    current: primitives.U256,
    new: primitives.U256,
    is_cold: bool,
    block_gas_limit: u64,
) SstoreGas {
    // Always Berlin+: cold slot surcharge added to base cost.
    const cold_cost: u64 = if (is_cold) COLD_SLOAD else 0;
    // Always Berlin+: base SSTORE_RESET reduced by COLD_SLOAD (avoids double-counting).
    const sstore_reset_cost: u64 = SSTORE_RESET - COLD_SLOAD;
    // Always London+: R_sclear = 4800.
    const clears_refund: i64 = SSTORE_CLEARS_SCHEDULE_LONDON;

    if (current == new) {
        // EIP-2200 no-op: warm SLOAD cost (always Berlin+: WARM_SLOAD = 100).
        return .{ .gas_cost = WARM_SLOAD + cold_cost, .gas_refund = 0 };
    }

    if (original == current) {
        if (original == 0) {
            if (is_amsterdam) {
                // EIP-8037: regular gas = GAS_STORAGE_UPDATE; state gas = STATE_BYTES * cpsb.
                const cpsb = costPerStateByte(block_gas_limit);
                const state_gas = STATE_BYTES_PER_STORAGE_SET * cpsb;
                return .{ .gas_cost = sstore_reset_cost + cold_cost, .gas_refund = 0, .state_gas = state_gas };
            }
            return .{ .gas_cost = SSTORE_SET + cold_cost, .gas_refund = 0 };
        } else {
            if (new == 0) {
                return .{ .gas_cost = sstore_reset_cost + cold_cost, .gas_refund = clears_refund };
            } else {
                return .{ .gas_cost = sstore_reset_cost + cold_cost, .gas_refund = 0 };
            }
        }
    }

    // Subsequent modification (dirty slot)
    var refund: i64 = 0;
    if (original != 0) {
        if (current == 0) {
            refund -= clears_refund;
        } else if (new == 0) {
            refund += clears_refund;
        }
    }

    // Always Berlin+: dirty base = WARM_SLOAD = 100.
    var state_gas_refund: u64 = 0;
    if (original == new) {
        if (original == 0) {
            if (is_amsterdam) {
                // EIP-8037: state gas portion returns to reservoir.
                const cpsb = costPerStateByte(block_gas_limit);
                state_gas_refund = STATE_BYTES_PER_STORAGE_SET * cpsb;
                refund += @as(i64, @intCast(GAS_STORAGE_UPDATE)) -
                    @as(i64, @intCast(COLD_SLOAD)) -
                    @as(i64, @intCast(WARM_SLOAD));
            } else {
                refund += @as(i64, @intCast(SSTORE_SET)) - @as(i64, @intCast(WARM_SLOAD));
            }
        } else {
            refund += @as(i64, @intCast(sstore_reset_cost)) - @as(i64, @intCast(WARM_SLOAD));
        }
    }

    return .{ .gas_cost = WARM_SLOAD + cold_cost, .gas_refund = refund, .state_gas_refund = state_gas_refund };
}

/// Calculate CALL base gas cost (EIP-2929 + EIP-8037).
/// Pre-Osaka forks not supported; Berlin cold/warm access model is unconditional.
pub fn getCallGasCost(
    is_amsterdam: bool,
    is_cold: bool,
    transfers_value: bool,
    account_exists: bool,
) u64 {
    // Always Berlin+: cold/warm account access cost.
    var cost: u64 = if (is_cold) COLD_ACCOUNT_ACCESS else WARM_ACCOUNT_ACCESS;

    if (transfers_value) {
        cost += 9000;
        // EIP-8037 (Amsterdam+): G_NEWACCOUNT replaced with state gas (charged separately).
        // Pre-Amsterdam: G_NEWACCOUNT = 25000 still applies for value-to-new-account.
        if (!account_exists and !is_amsterdam) {
            cost += 25000;
        }
    }
    // Pre-Spurious Dragon zero-value G_NEWACCOUNT path deleted (always post-Osaka).

    return cost;
}
