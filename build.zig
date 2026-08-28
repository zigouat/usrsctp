const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const usrsctp_dep = b.dependency("usrsctp", .{ .target = target, .optimize = optimize });

    const usrsctp = b.addLibrary(.{
        .name = "sctp",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const flags = &.{
        "-std=c99",
        "-Wall",
        "-Wextra",
        "-pedantic",
    };

    usrsctp.root_module.addIncludePath(usrsctp_dep.path("usrsctplib"));
    usrsctp.root_module.addCSourceFiles(.{
        .root = usrsctp_dep.path("usrsctplib"),
        .files = srcs,
        .flags = flags,
    });

    usrsctp.root_module.addCMacro("__Userspace__", "");
    usrsctp.root_module.addCMacro("SCTP_SIMPLE_ALLOCATOR", "");
    usrsctp.root_module.addCMacro("SCTP_PROCESS_LEVEL_LOCKS", "");

    switch (target.result.os.tag) {
        .linux => usrsctp.root_module.addCMacro("_GNU_SOURCE", ""),
        .macos, .tvos, .ios => usrsctp.root_module.addCMacro("__APPLE_USE_RFC_2292", ""),
        .windows => {
            usrsctp.root_module.linkSystemLibrary("iphlpapi", .{});
            usrsctp.root_module.linkSystemLibrary("ws2_32", .{});
            usrsctp.root_module.addCMacro("__USE_MINGW_ANSI_STDIO", "");
        },
        else => {},
    }

    if (target.result.cpu.arch.endian() == .big) {
        usrsctp.root_module.addCMacro("WORDS_BIGENDIAN", "");
    }

    switch (target.result.os.tag) {
        .macos, .ios, .tvos, .freebsd, .openbsd, .netbsd, .dragonfly => {
            usrsctp.root_module.addCMacro("HAVE_SA_LEN", "");
            usrsctp.root_module.addCMacro("HAVE_SIN_LEN", "");
            usrsctp.root_module.addCMacro("HAVE_SIN6_LEN", "");
            usrsctp.root_module.addCMacro("HAVE_SCONN_LEN", "");
        },
        else => {},
    }

    usrsctp.installHeader(usrsctp_dep.path("usrsctplib/usrsctp.h"), "usrsctp.h");
    b.installArtifact(usrsctp);

    const tc = b.addTranslateC(.{
        .root_source_file = usrsctp_dep.path("usrsctplib/usrsctp.h"),
        .target = target,
        .optimize = optimize,
    });

    const tc_mod = b.addModule("usrsctp", .{
        .root_source_file = tc.getOutput(),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("sctp", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "usrsctp", .module = tc_mod },
        },
    });
    mod.linkLibrary(usrsctp);
}

const srcs: []const []const u8 = &.{
    "user_environment.c",
    "user_mbuf.c",
    "user_recv_thread.c",
    "user_socket.c",
    "netinet/sctp_asconf.c",
    "netinet/sctp_auth.c",
    "netinet/sctp_bsd_addr.c",
    "netinet/sctp_callout.c",
    "netinet/sctp_cc_functions.c",
    "netinet/sctp_crc32.c",
    "netinet/sctp_indata.c",
    "netinet/sctp_input.c",
    "netinet/sctp_output.c",
    "netinet/sctp_pcb.c",
    "netinet/sctp_peeloff.c",
    "netinet/sctp_sha1.c",
    "netinet/sctp_ss_functions.c",
    "netinet/sctp_sysctl.c",
    "netinet/sctp_userspace.c",
    "netinet/sctp_timer.c",
    "netinet/sctp_usrreq.c",
    "netinet/sctputil.c",
    "netinet6/sctp6_usrreq.c",
};
