const std = @import("std");

const bss = @extern([*]u8, .{ .name = "__bss" });
const bss_end = @extern([*]u8, .{ .name = "__bss_end" });
const stack_top = @extern([*]u8, .{ .name = "__stack_top" });

export fn kernel_main() noreturn {
    const bss_len = @intFromPtr(bss_end) - @intFromPtr(bss);
    @memset(bss[0..bss_len], 0);

    const hello = "Hello Kernel!\n";
    console.print("{s}", .{hello}) catch {};

    write_csr("stvec", @intFromPtr(&kernel_entry));
    asm volatile ("unimp");

    while (true) asm volatile ("wfi");
}

pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    _ = error_return_trace;
    _ = ret_addr;

    console.print("PANIC: {s}\n", .{msg}) catch {};
    while (true) asm volatile ("");
}

export fn boot() linksection(".text.boot") callconv(.Naked) void {
    asm volatile (
        \\mv sp, %[stack_top]
        \\j kernel_main
        :
        : [stack_top] "r" (stack_top),
    );
}

const SbiRet = struct {
    err: usize,
    value: usize,
};

const console: std.io.AnyWriter = .{
    .context = undefined,
    .writeFn = write_fn,
};

fn write_fn(_: *const anyopaque, bytes: []const u8) !usize {
    for (bytes) |c| _ = sbi(c, 0, 0, 0, 0, 0, 0, 1);
    return bytes.len;
}

pub fn sbi(
    arg0: usize,
    arg1: usize,
    arg2: usize,
    arg3: usize,
    arg4: usize,
    arg5: usize,
    arg6: usize,
    arg7: usize,
) SbiRet {
    var err: usize = undefined;
    var value: usize = undefined;

    asm volatile ("ecall"
        : [err] "={a0}" (err),
          [value] "={a1}" (value),
        : [arg0] "{a0}" (arg0),
          [arg1] "{a1}" (arg1),
          [arg2] "{a2}" (arg2),
          [arg3] "{a3}" (arg3),
          [arg4] "{a4}" (arg4),
          [arg5] "{a5}" (arg5),
          [arg6] "{a6}" (arg6),
          [arg7] "{a7}" (arg7),
        : "memory"
    );

    return .{ .err = err, .value = value };
}

const registers = std.meta.fieldNames(TrapFrame);

export fn kernel_entry() align(4) callconv(.Naked) void {
    asm volatile (std.fmt.comptimePrint("addi sp, sp, -{d}", .{@sizeOf(usize) * registers.len}));
    defer asm volatile (std.fmt.comptimePrint("addi sp, sp, {d}", .{@sizeOf(usize) * registers.len}));

    inline for (registers, 0..) |register, offset| {
        asm volatile (std.fmt.comptimePrint("sw {s}, {d}(sp)", .{ register, offset * @sizeOf(usize) }));
    }
    defer inline for (registers, 0..) |register, offset| {
        asm volatile (std.fmt.comptimePrint("lw {s}, {d}(sp)", .{ register, offset * @sizeOf(usize) }));
    };

    asm volatile ("call handle_trap");
}

const TrapFrame = extern struct {
    ra: usize,
    gp: usize,
    tp: usize,
    t0: usize,
    t1: usize,
    t2: usize,
    t3: usize,
    t4: usize,
    t5: usize,
    t6: usize,
    a0: usize,
    a1: usize,
    a2: usize,
    a3: usize,
    a4: usize,
    a5: usize,
    a6: usize,
    a7: usize,
    s0: usize,
    s1: usize,
    s2: usize,
    s3: usize,
    s4: usize,
    s5: usize,
    s6: usize,
    s7: usize,
    s8: usize,
    s9: usize,
    s10: usize,
    s11: usize,
    sp: usize,
};

export fn handle_trap(tf: *TrapFrame) void {
    _ = tf;
    const scause = read_csr("scause");
    const stval = read_csr("stval");
    const user_pc = read_csr("sepc");

    std.debug.panic("Unexpected trap scause={x}, stval={x}, user_pc={x}", .{
        scause, stval, user_pc,
    });
}

fn read_csr(comptime reg: []const u8) usize {
    return asm ("csrr %[ret], " ++ reg
        : [ret] "=r" (-> usize),
    );
}

fn write_csr(comptime reg: []const u8, val: usize) void {
    asm volatile ("csrw " ++ reg ++ ", %[val]"
        :
        : [val] "r" (val),
    );
}
