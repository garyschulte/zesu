const Interpreter = @import("interpreter.zig").Interpreter;
const host_module = @import("host.zig");

pub const Host = host_module.Host;

/// Minimal context passed to every opcode handler.
/// Handlers access stack, gas, memory, and PC through interpreter.
/// Handlers that need block/tx/state access use the optional host pointer.
/// Comptime-generic over DB — see host.zig's Host(DB) doc comment.
pub fn InstructionContext(comptime DB: type) type {
    return struct {
        interpreter: *Interpreter,
        /// Optional host providing block/tx environment and account state.
        /// Null in hostless execution (e.g. benchmarks, pure arithmetic tests).
        /// Handlers that require a host halt with .invalid_opcode when host is null.
        host: ?*Host(DB) = null,
    };
}

/// Function pointer type for all opcode handlers, once DB is bound.
pub fn InstructionFn(comptime DB: type) type {
    return *const fn (ctx: *InstructionContext(DB)) void;
}
