const std = @import("std");

pub fn build(b: *std.Build) void {
    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_source_file = b.path("src/kernel.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .riscv32,
            .os_tag = .freestanding,
            .abi = .none,
        }),
        .optimize = .ReleaseSmall,
        .strip = false,
    });

    kernel.entry = .disabled;
    kernel.setLinkerScript(b.path("src/kernel.ld"));
    b.installArtifact(kernel);

    const shell = b.addExecutable(.{
        .name = "shell.elf",
        .root_source_file = b.path("src/shell.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .riscv32,
            .os_tag = .freestanding,
            .abi = .none,
        }),
        .optimize = .ReleaseSmall,
        .strip = false,
    });

    shell.entry = .disabled;
    shell.setLinkerScript(b.path("src/user.ld"));
    b.installArtifact(shell);

    // const bin = b.addObjCopy(shell.getEmittedBin(), .{
    //     .basename = "shell.bin",
    //     .format = .bin,

    // });

    const elf2bin = b.addSystemCommand(&.{
        "llvm-objcopy",

        "--set-section-flags",
        ".bss=alloc,contents",
        "-O",
        "binary",
    });

    elf2bin.addArtifactArg(shell);
    const bin_file_name = "shell.bin";
    const bin = elf2bin.addOutputFileArg(bin_file_name);

    kernel.root_module.addAnonymousImport("shell.bin", .{
        .root_source_file = bin,
    });

    // const bin2o = b.addSystemCommand(&.{
    //     "llvm-objcopy",

    //     "-Ibinary",
    //     "-Oelf32-littleriscv",
    //     bin_file_name,
    // });

    // // Done because otherwise objcopy will mangle symbols by adding the full path
    // // to the symbol name.
    // bin2o.setCwd(bin.dirname());
    // const shell_obj = bin2o.addOutputFileArg("shell.bin.o");

    // const patch = b.addSystemCommand(&.{
    //     "dd",
    //     "bs=1",
    //     "seek=36",
    //     "count=4",
    //     "conv=notrunc",
    // });

    // patch.addPrefixedFileArg("if=", b.path("src/elf.patch"));
    // patch.addPrefixedFileArg("of=", shell_obj);

    // kernel.step.dependOn(&patch.step);
    // kernel.addObjectFile(shell_obj);

    const run_cmd = b.addSystemCommand(&.{
        "qemu-system-riscv32",
    });

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addArgs(&.{
        "-machine",    "virt",
        "-bios",       "default",
        "-serial",     "mon:stdio",
        "--no-reboot", "-nographic",
        "-kernel",
    });

    run_cmd.addArtifactArg(kernel);
    const run_step = b.step("run", "Run QEMU");
    run_step.dependOn(&run_cmd.step);
}
