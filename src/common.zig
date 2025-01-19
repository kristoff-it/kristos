const std = @import("std");

pub const Syscall = enum(u32) {
    putchar,
    getchar,
    exit,

    pub fn zero(s: Syscall) usize {
        const id: u32 = @intFromEnum(s);
        return asm volatile (
            \\ecall
            : [ret] "={a0}" (-> usize),
            : [id] "{a0}" (id),
        );
    }

    pub fn one(s: Syscall, arg: u32) usize {
        const id: u32 = @intFromEnum(s);
        return asm volatile (
            \\ecall
            : [ret] "={a0}" (-> usize),
            : [id] "{a0}" (id),
              [arg] "{a1}" (arg),
        );
    }
};

const console: std.io.AnyWriter = .{
    .writeFn = writeFn,
    .context = undefined,
};

fn writeFn(ctx: *const anyopaque, bytes: []const u8) !usize {
    _ = ctx;
    for (bytes) |b| _ = Syscall.one(.putchar, b);
    return bytes.len;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    console.print(fmt, args) catch {};
}

pub fn readByte() u8 {
    const val = Syscall.zero(.getchar);
    return @intCast(val);
}

pub fn exit(code: usize) void {
    _ = Syscall.one(.exit, code);
}
