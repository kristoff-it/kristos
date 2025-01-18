const std = @import("std");

const kernel_base = @extern([*]u8, .{ .name = "__kernel_base" });
const bss = @extern([*]u8, .{ .name = "__bss" });
const bss_end = @extern([*]u8, .{ .name = "__bss_end" });
const stack_top = @extern([*]u8, .{ .name = "__stack_top" });

const ram_start = @extern([*]u8, .{ .name = "__free_ram" });
const ram_end = @extern([*]u8, .{ .name = "__free_ram_end" });

const page_size = 4096;
var used_mem: usize = 0;
fn allocPages(pages: usize) []u8 {
    const ram = ram_start[0 .. @intFromPtr(ram_end) - @intFromPtr(ram_start)];
    const alloc_size = pages * page_size;

    if (used_mem + alloc_size > ram.len) {
        @panic("out of memory");
    }

    const result = ram[used_mem..][0..alloc_size];
    used_mem += alloc_size;

    @memset(result, 0);

    return result;
}

const Process = struct {
    pid: usize = 0,
    state: enum { unused, runnable } = .unused,
    sp: *usize = undefined, // stack pointer
    page_table: [*]PageEntry = undefined,
    stack: [1024]u8 align(4) = undefined,
};

var procs = [_]Process{.{}} ** 8;

fn createProcess(pc: *const anyopaque) *Process {
    const p = for (&procs, 0..) |*p, i| {
        if (p.state == .unused) {
            p.pid = i;
            break p;
        }
    } else @panic("too many processes!");

    const regs: []usize = blk: {
        const ptr: [*]usize = @alignCast(@ptrCast(&p.stack));
        break :blk ptr[0 .. p.stack.len / @sizeOf(usize)];
    };

    const sp = regs[regs.len - 13 ..];
    sp[0] = @intFromPtr(pc);

    std.debug.assert(sp.len == 13);

    for (sp[1..]) |*reg| {
        reg.* = 0;
    }

    const page = allocPages(1);
    p.page_table = @alignCast(@ptrCast(page));

    console.print("new top level page table: {*}\n", .{page.ptr}) catch {};

    const pages_count = @divFloor((@intFromPtr(ram_end) - @intFromPtr(kernel_base)), page_size);
    const pages: [*][page_size]u8 = @ptrCast(kernel_base);

    for (pages[0..pages_count]) |*paddr| {
        const flags: PageEntry = .{
            .read = true,
            .write = true,
            .execute = true,
            .user = false,
            .valid = false,
        };

        mapPage(p.page_table, @intFromPtr(paddr), @intFromPtr(paddr), flags);
    }

    p.sp = &sp.ptr[0];
    p.state = .runnable;
    return p;
}

export fn processA() void {
    console.print("starting process A\n\n", .{}) catch {};
    while (true) {
        console.print("A", .{}) catch {};
        yield();
        for (3_000_000_000) |_| asm volatile ("nop");
    }
}

export fn processB() void {
    console.print("starting process B\n\n", .{}) catch {};
    while (true) {
        console.print("B", .{}) catch {};
        yield();
        for (3_000_000_000) |_| asm volatile ("nop");
    }
}

var current_proc: *Process = undefined;
var idle_proc: *Process = undefined;

noinline fn yield() void {
    const start_idx = (current_proc.pid + 1) % procs.len;
    const next = for (procs[start_idx..]) |*p| {
        if (p.state == .runnable and p.pid > 0) {
            break p;
        }
    } else for (procs[0..start_idx]) |*p| {
        if (p.state == .runnable and p.pid > 0) {
            break p;
        }
    } else idle_proc;

    if (next == current_proc) return;

    // console.print("swapping active page table: {*}\n", .{next.page_table}) catch {};

    const satp = Satp.fromPageTableAddr(next.page_table);
    const satp_u32: u32 = @bitCast(satp);
    asm volatile (
        \\sfence.vma
        \\csrw satp, %[satp]
        \\sfence.vma
        \\csrw sscratch, %[sscratch]
        :
        : [satp] "r" (satp_u32),
          [sscratch] "r" (next.stack[0..].ptr[next.stack.len]),
    );

    const prev = current_proc;
    current_proc = next;
    context_switch(&prev.sp, &next.sp);
}

noinline fn context_switch(
    cur: **usize,
    next: **usize,
) callconv(.C) void {
    asm volatile (
        \\addi sp, sp, -4 * 13
        \\sw ra, 4 * 0(sp)
        \\sw s0, 4 * 1(sp)
        \\sw s1, 4 * 2(sp)
        \\sw s2, 4 * 3(sp)
        \\sw s3, 4 * 4(sp)
        \\sw s4, 4 * 5(sp)
        \\sw s5, 4 * 6(sp)
        \\sw s6, 4 * 7(sp)
        \\sw s7, 4 * 8(sp)
        \\sw s8, 4 * 9(sp)
        \\sw s9, 4 * 10(sp)
        \\sw s10, 4 * 11(sp)
        \\sw s11, 4 * 12(sp)
        \\
        \\sw sp, (%[cur])
        \\lw sp, (%[next])
        \\
        \\lw ra, 4 * 0(sp)
        \\lw s0, 4 * 1(sp)
        \\lw s1, 4 * 2(sp)
        \\lw s2, 4 * 3(sp)
        \\lw s3, 4 * 4(sp)
        \\lw s4, 4 * 5(sp)
        \\lw s5, 4 * 6(sp)
        \\lw s6, 4 * 7(sp)
        \\lw s7, 4 * 8(sp)
        \\lw s8, 4 * 9(sp)
        \\lw s9, 4 * 10(sp)
        \\lw s10, 4 * 11(sp)
        \\lw s11, 4 * 12(sp)
        \\addi sp, sp, 4 * 13
        \\ret
        :
        : [cur] "r" (cur),
          [next] "r" (next),
    );
}

export fn kernel_main() noreturn {
    main() catch |err| std.debug.panic("{s}", .{@errorName(err)});
    while (true) asm volatile ("wfi");
}

fn main() !void {
    const bss_len = @intFromPtr(bss_end) - @intFromPtr(bss);
    @memset(bss[0..bss_len], 0);

    const hello = "Hello Kernel!\n";
    try console.print("{s}", .{hello});

    // exception handling
    {
        write_csr("stvec", @intFromPtr(&kernel_entry));
        // Uncomment to trigger a cpu exception
        // asm volatile ("unimp");
    }

    // page allocation
    {
        // const one = allocPages(1);
        // const two = allocPages(2);

        // try console.print("one: {*} ({}), two: {*} ({})\n", .{
        //     one.ptr,
        //     one.len,
        //     two.ptr,
        //     two.len,
        // });
    }

    // processes
    {
        try console.print("creating processes...\n", .{});

        idle_proc = createProcess(undefined);
        _ = createProcess(&processA);
        _ = createProcess(&processB);

        current_proc = idle_proc;

        try console.print("processes created, yielding\n", .{});

        yield();

        @panic("switched to idle process");

        // asm volatile (
        //     \\mv sp, %[pAs]
        //     \\call processA
        //     :
        //     : [pAs] "r" (pA.sp),
        // );
    }
}

pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    _ = error_return_trace;
    _ = ret_addr;

    console.print("KERNEL PANIC: {s}\n", .{msg}) catch {};
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

export fn kernel_entry() align(4) callconv(.Naked) void {
    asm volatile (
        \\csrrw sp, sscratch, sp
        \\
        \\addi sp, sp, -4 * 31
        \\sw ra, 4 * 0(sp)
        \\sw gp, 4 * 1(sp)
        \\sw tp, 4 * 2(sp)
        \\sw t0, 4 * 3(sp)
        \\sw t1, 4 * 4(sp)
        \\sw t2, 4 * 5(sp)
        \\sw t3, 4 * 6(sp)
        \\sw t4, 4 * 7(sp)
        \\sw t5, 4 * 8(sp)
        \\sw t6, 4 * 9(sp)
        \\sw a0, 4 * 10(sp)
        \\sw a1, 4 * 11(sp)
        \\sw a2, 4 * 12(sp)
        \\sw a3, 4 * 13(sp)
        \\sw a4, 4 * 14(sp)
        \\sw a5, 4 * 15(sp)
        \\sw a6, 4 * 16(sp)
        \\sw a7, 4 * 17(sp)
        \\sw s0, 4 * 18(sp)
        \\sw s1, 4 * 19(sp)
        \\sw s2, 4 * 20(sp)
        \\sw s3, 4 * 21(sp)
        \\sw s4, 4 * 22(sp)
        \\sw s5, 4 * 23(sp)
        \\sw s6, 4 * 24(sp)
        \\sw s7, 4 * 25(sp)
        \\sw s8, 4 * 26(sp)
        \\sw s9, 4 * 27(sp)
        \\sw s10, 4 * 28(sp)
        \\sw s11, 4 * 29(sp)
        \\
        \\addi a0, sp, 4 * 31
        \\sw a0, -4(a0)
        \\
        // Retrieve and save the sp at the time of exception.
        \\csrr a0, sscratch
        \\sw a0,  4 * 30(sp)
        // Reset the kernel stack.
        \\addi a0, sp, 4 * 31
        \\csrw sscratch, a0       
        \\
        \\mv a0, sp
        \\call handle_trap
        \\
        \\lw ra, 4 * 0(sp)
        \\lw gp, 4 * 1(sp)
        \\lw tp, 4 * 2(sp)
        \\lw t0, 4 * 3(sp)
        \\lw t1, 4 * 4(sp)
        \\lw t2, 4 * 5(sp)
        \\lw t3, 4 * 6(sp)
        \\lw t4, 4 * 7(sp)
        \\lw t5, 4 * 8(sp)
        \\lw t6, 4 * 9(sp)
        \\lw a0, 4 * 10(sp)
        \\lw a1, 4 * 11(sp)
        \\lw a2, 4 * 12(sp)
        \\lw a3, 4 * 13(sp)
        \\lw a4, 4 * 14(sp)
        \\lw a5, 4 * 15(sp)
        \\lw a6, 4 * 16(sp)
        \\lw a7, 4 * 17(sp)
        \\lw s0, 4 * 18(sp)
        \\lw s1, 4 * 19(sp)
        \\lw s2, 4 * 20(sp)
        \\lw s3, 4 * 21(sp)
        \\lw s4, 4 * 22(sp)
        \\lw s5, 4 * 23(sp)
        \\lw s6, 4 * 24(sp)
        \\lw s7, 4 * 25(sp)
        \\lw s8, 4 * 26(sp)
        \\lw s9, 4 * 27(sp)
        \\lw s10, 4 * 28(sp)
        \\lw s11, 4 * 29(sp)
        \\lw sp, 4 * 30(sp)
        \\sret
    );
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

// Virtual memory

const Satp = packed struct {
    reserved: u31,
    sv32: bool,

    fn fromPageTableAddr(pta: [*]PageEntry) Satp {
        return .{
            .reserved = @intCast(@intFromPtr(pta) >> 12),
            .sv32 = true,
        };
    }
};

const PageEntry = packed struct(u32) {
    valid: bool,
    read: bool,
    write: bool,
    execute: bool,
    user: bool,
    other_flags: u5 = 0,
    ppn: u22 = 0,
};

const Vpn = packed struct(u32) {
    offset: u12,
    zero: u10,
    one: u10,
};

fn mapPage(
    table1: [*]PageEntry,
    vaddr: usize,
    paddr: usize,
    flags: PageEntry,
) void {
    // console.print("mapPage({*}, {x}, {x}, ...)\n", .{ table1, vaddr, paddr }) catch {};

    if (vaddr % page_size != 0) {
        std.debug.panic("unaligned vaddr: {}", .{vaddr});
    }

    if (paddr % page_size != 0) {
        std.debug.panic("unaligned paddr: {}", .{paddr});
    }

    const vpn: Vpn = @bitCast(vaddr);

    if (!table1[vpn.one].valid) {
        var pt_addr: PageEntry = @bitCast(@intFromPtr(allocPages(1).ptr));

        pt_addr.valid = true;
        pt_addr.ppn >>= 2;
        table1[vpn.one] = pt_addr;
    }

    const table0u32: u32 = @intCast(table1[vpn.one].ppn);
    const table0: [*]PageEntry = @ptrFromInt(table0u32 << 12);

    const paddr_as_pe: PageEntry = @bitCast((paddr / page_size) << 10);
    var new_pe = flags;
    new_pe.ppn = paddr_as_pe.ppn;
    new_pe.valid = true;

    table0[vpn.zero] = new_pe;
}
