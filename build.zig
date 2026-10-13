const std = @import("std");

pub fn build(b: *std.Build) void {
    const tzdata_directory = b.option([]const u8, "tzdata-dir", "Absolute path to an immutable IANA TZif database") orelse "/usr/share/zoneinfo";
    const icu_prefix = b.option([]const u8, "icu-prefix", "Path to a specific ICU installation");
    const intl = b.option(bool, "intl", "Enable ICU calendars and localized formatting") orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "intl", intl);
    build_options.addOption([]const u8, "tzdataDirectory", tzdata_directory);
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zdate_dep = b.dependency("zdate", .{ .target = target, .optimize = optimize });
    const zdate_module = zdate_dep.module("zdate");

    const ztemporal_module = b.addModule("ztemporal", .{
        .root_source_file = b.path("src/ztemporal.zig"),
        .target = target,
        .optimize = optimize,
    });
    ztemporal_module.addImport("zdate", zdate_module);
    ztemporal_module.addOptions("build_options", build_options);
    if (intl) {
        if (icu_prefix) |prefix| {
            ztemporal_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
            ztemporal_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
            ztemporal_module.addRPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
        }
        ztemporal_module.addCSourceFile(.{ .file = b.path("src/intl/icu_bridge.c"), .flags = &.{"-std=c11"} });
        ztemporal_module.linkSystemLibrary("icui18n", .{ .use_pkg_config = if (icu_prefix == null) .yes else .no });
        ztemporal_module.linkSystemLibrary("icuuc", .{ .use_pkg_config = if (icu_prefix == null) .yes else .no });
        ztemporal_module.linkSystemLibrary("icudata", .{ .needed = true, .use_pkg_config = if (icu_prefix == null) .yes else .no });
        ztemporal_module.link_libc = true;
        ztemporal_module.addCSourceFile(.{ .file = b.path("src/intl/duration_bridge.cpp"), .flags = &.{"-std=c++17"} });
        ztemporal_module.link_libcpp = true;
    }

    const docs_library = b.addLibrary(.{ .name = "ztemporal", .root_module = ztemporal_module });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_library.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Generate Zig API documentation in zig-out/docs").dependOn(&install_docs.step);

    const test_step = b.step("test", "Run all tests");

    const test_files = [_][]const u8{
        "tests/conformance_test.zig",
        "tests/docs_examples_test.zig",
        "tests/iso_calendar_test.zig",
        "tests/plain_date_test.zig",
        "tests/plain_time_test.zig",
        "tests/plain_date_time_test.zig",
        "tests/duration_test.zig",
        "tests/plain_year_month_test.zig",
        "tests/plain_month_day_test.zig",
        "tests/instant_test.zig",
        "tests/now_test.zig",
        "tests/zoned_date_time_test.zig",
    };

    inline for (test_files) |test_file| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = target,
                .optimize = optimize,
            }),
        });
        unit_tests.root_module.addImport("ztemporal", ztemporal_module);
        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }

    const src_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ztemporal.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    src_tests.root_module.addImport("zdate", zdate_module);
    src_tests.root_module.addOptions("build_options", build_options);
    if (intl) {
        if (icu_prefix) |prefix| {
            src_tests.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
            src_tests.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
            src_tests.root_module.addRPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
        }
        src_tests.root_module.addCSourceFile(.{ .file = b.path("src/intl/icu_bridge.c"), .flags = &.{"-std=c11"} });
        src_tests.root_module.linkSystemLibrary("icui18n", .{ .use_pkg_config = if (icu_prefix == null) .yes else .no });
        src_tests.root_module.linkSystemLibrary("icuuc", .{ .use_pkg_config = if (icu_prefix == null) .yes else .no });
        src_tests.root_module.linkSystemLibrary("icudata", .{ .needed = true, .use_pkg_config = if (icu_prefix == null) .yes else .no });
        src_tests.root_module.link_libc = true;
        src_tests.root_module.addCSourceFile(.{ .file = b.path("src/intl/duration_bridge.cpp"), .flags = &.{"-std=c++17"} });
        src_tests.root_module.link_libcpp = true;
    }
    const run_src_tests = b.addRunArtifact(src_tests);
    test_step.dependOn(&run_src_tests.step);

    const parity = b.addExecutable(.{ .name = "temporal-parity", .root_module = b.createModule(.{ .root_source_file = b.path("tests/parity_runner.zig"), .target = target, .optimize = optimize }) });
    parity.root_module.addImport("ztemporal", ztemporal_module);
    const compare = b.addSystemCommand(&.{ "node", "scripts/parity.mjs" });
    compare.addArtifactArg(parity);
    if (intl) compare.addArg("intl");
    b.step("test-parity", "Compare Temporal behavior with Node").dependOn(&compare.step);
    b.default_step = test_step;
}
