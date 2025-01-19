comptime {
    @export(start, .{ .name = "start", .section = ".text.start" });
}

const stack_top = @extern([*]u8, .{ .name = "__stack_top" });

const common = @import("common.zig");

fn start() callconv(.Naked) void {
    asm volatile (
        \\mv sp, %[stack_top]
        \\call %[shell] 
        :
        : [stack_top] "r" (stack_top),
          [shell] "X" (&shell),
    );
}

fn shell() !void {
    // const bad_ptr: *volatile usize = @ptrFromInt(0x80200000);
    // bad_ptr.* = 5;

    common.print("hello from shell.zig! (press 'q' to exit the process)\n", .{});
    // common.Syscall.one(.putchar, 'x');

    while (true) {
        const c = common.readByte();
        common.print("read: '{c}'\n", .{c});

        if (c == 'q') {
            common.print("exting...\n", .{});
            common.exit(42);
        }
    }
}
