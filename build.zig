const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ztemporal_module = b.addModule("ztemporal", .{
        .root_source_file = b.path("src/ztemporal.zig"),
    });

    const test_step = b.step("test", "Run all tests");

    const test_files = [_][]const u8{
        "tests/iso_calendar_test.zig",
        "tests/plain_date_test.zig",
        "tests/plain_time_test.zig",
        "tests/plain_date_time_test.zig",
        "tests/duration_test.zig",
        "tests/plain_year_month_test.zig",
        "tests/plain_month_day_test.zig",
        "tests/instant_test.zig",
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
    const run_src_tests = b.addRunArtifact(src_tests);
    test_step.dependOn(&run_src_tests.step);

    b.default_step = test_step;
}
