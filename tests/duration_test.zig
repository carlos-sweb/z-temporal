const std = @import("std");
const ztemporal = @import("ztemporal");
const Duration = ztemporal.Duration;
const PlainDate = ztemporal.PlainDate;

fn expectIso(expected: []const u8, d: Duration) !void {
    const allocator = std.testing.allocator;
    const s = try d.toIsoString(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings(expected, s);
}

test "public API: create, sign, toIsoString round-trip" {
    const d = try Duration.create(1, 2, 3, 4, 5, 6, 7, 0, 0, 0);
    try std.testing.expectEqual(@as(i8, 1), d.sign());
    try std.testing.expect(!d.blank());

    const allocator = std.testing.allocator;
    const s = try d.toIsoString(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("P1Y2M3W4DT5H6M7S", s);

    const parsed = try Duration.parseIso(s);
    try std.testing.expectEqual(d.years, parsed.years);
    try std.testing.expectEqual(d.seconds, parsed.seconds);
}

test "public API: mixed-sign construction rejected" {
    try std.testing.expectError(ztemporal.TemporalError.InvalidRange, Duration.create(1, -1, 0, 0, 0, 0, 0, 0, 0, 0));
}

test "public API: withFields overrides only the given fields" {
    const d = try Duration.create(1, 2, 0, 0, 0, 0, 0, 0, 0, 0);
    const d2 = try d.withFields(.{ .months = 9 });
    try std.testing.expectEqual(@as(i64, 1), d2.years);
    try std.testing.expectEqual(@as(i64, 9), d2.months);
}

test "public API: add balances non-calendar durations, rejects calendar-unit operands" {
    const a = try Duration.create(0, 0, 0, 1, 0, 0, 0, 0, 0, 0);
    const b = try Duration.create(0, 0, 0, 0, 30, 0, 0, 0, 0, 0);
    const r = try a.add(b);
    try std.testing.expectEqual(@as(i64, 2), r.days);
    try std.testing.expectEqual(@as(i64, 6), r.hours);

    const with_years = try Duration.create(1, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    try std.testing.expectError(ztemporal.TemporalError.MixedCalendarUnits, a.add(with_years));
}

test "public API: compare needs relativeTo for unequal calendar-unit durations" {
    const a = try Duration.create(2, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    const b = try Duration.create(1, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    try std.testing.expectError(ztemporal.TemporalError.NeedsRelativeTo, Duration.compare(a, b));
    try std.testing.expectEqual(std.math.Order.eq, try Duration.compare(a, a));
}

test "round: no relativeTo needed without calendar units, halfExpand default" {
    const d = try Duration.create(0, 0, 0, 0, 25, 30, 0, 0, 0, 0);
    try expectIso("P1D", try d.round(null, .{ .smallest_unit = .day }));
    try expectIso("PT2H", try (try Duration.create(0, 0, 0, 0, 0, 90, 0, 0, 0, 0)).round(null, .{ .smallest_unit = .hour }));
}

test "round: calendar-unit duration needs relativeTo, matches add-then-until" {
    const d = try Duration.create(1, 6, 0, 20, 0, 0, 0, 0, 0, 0);
    try std.testing.expectError(ztemporal.TemporalError.NeedsRelativeTo, d.round(null, .{ .smallest_unit = .month }));

    const rt = try PlainDate.create(2024, 1, 1, .reject);
    try expectIso("P1Y6M20D", try d.round(rt, .{ .largest_unit = .year }));
    try expectIso("P1Y7M", try d.round(rt, .{ .smallest_unit = .month }));
}

test "round: negative duration matches add-then-until" {
    const d = try Duration.create(0, -7, 0, -20, 0, 0, 0, 0, 0, 0);
    const rt = try PlainDate.create(2024, 6, 15, .reject);
    try expectIso("-P8M", try d.round(rt, .{ .smallest_unit = .month }));
}

test "round: week-only unit still needs relativeTo even with no calendar field on self" {
    const d = try Duration.create(0, 0, 0, 0, 100, 0, 0, 0, 0, 0);
    try std.testing.expectError(ztemporal.TemporalError.NeedsRelativeTo, d.round(null, .{ .smallest_unit = .week }));
    try std.testing.expectError(ztemporal.TemporalError.InvalidRange, d.round(null, .{}));
}

test "round: largestUnit auto-resolves to the coarser of self's field and smallestUnit" {
    // self's largest field (hour) is finer than the requested smallestUnit
    // (day) -> largestUnit becomes day too (a flat single-field result).
    const d = try Duration.create(0, 0, 0, 0, 25, 30, 0, 0, 0, 0);
    try expectIso("P1D", try d.round(null, .{ .smallest_unit = .day }));
}

test "round: mixed calendar+time duration needs PlainDateTime-level balance" {
    const d = try Duration.create(1, 0, 0, 0, 30, 0, 0, 0, 0, 0);
    const rt = try PlainDate.create(2024, 1, 1, .reject);
    try expectIso("P1Y1DT6H", try d.round(rt, .{ .smallest_unit = .hour }));
}

test "total: no relativeTo needed without calendar units, returns a fraction" {
    const d = try Duration.create(0, 0, 0, 1, 12, 30, 0, 0, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5208333333333333), try d.total(null, .day), 1e-12);
    try std.testing.expectError(ztemporal.TemporalError.NeedsRelativeTo, d.total(null, .month));
}

test "total: relativeTo, fractional month/year result" {
    const d = try Duration.create(0, 0, 0, 45, 0, 0, 0, 0, 0, 0);
    const rt = try PlainDate.create(2024, 1, 1, .reject);
    try std.testing.expectApproxEqAbs(@as(f64, 1.4827586206896552), try d.total(rt, .month), 1e-12);
}

test "round: random-batch differential against real Node" {
    const Case = struct { rt: [3]i32, dur: [7]i64, smallest: ztemporal.Unit, mode: ztemporal.RoundingMode, result: []const u8 };
    const cases = [_]Case{
        .{ .rt = .{ 2025, 4, 7 }, .dur = .{ 0, 17, 0, 33, 0, 32, 0 }, .smallest = .week, .mode = .expand, .result = "P18M1W" },
        .{ .rt = .{ 2017, 9, 10 }, .dur = .{ 0, -17, 0, -32, -19, 0, -33 }, .smallest = .week, .mode = .floor, .result = "-P18M1W" },
        .{ .rt = .{ 2048, 11, 3 }, .dur = .{ 37, 0, 0, 0, 0, 0, 0 }, .smallest = .week, .mode = .floor, .result = "P37Y" },
        .{ .rt = .{ 2012, 1, 23 }, .dur = .{ -28, 0, 0, 0, -40, 0, 0 }, .smallest = .day, .mode = .floor, .result = "-P28Y2D" },
        .{ .rt = .{ 2006, 7, 23 }, .dur = .{ 11, 0, 0, 0, 0, 0, 0 }, .smallest = .minute, .mode = .half_floor, .result = "P11Y" },
        .{ .rt = .{ 1963, 1, 7 }, .dur = .{ 0, 24, 0, 0, 4, 1, 0 }, .smallest = .month, .mode = .half_even, .result = "P24M" },
        .{ .rt = .{ 2089, 4, 16 }, .dur = .{ 0, 0, 3, 0, 24, 0, 0 }, .smallest = .year, .mode = .half_ceil, .result = "PT0S" },
        .{ .rt = .{ 2008, 3, 7 }, .dur = .{ 0, -36, 0, -18, -29, -11, -27 }, .smallest = .day, .mode = .half_even, .result = "-P36M19D" },
        .{ .rt = .{ 2037, 5, 26 }, .dur = .{ -28, 0, 0, -11, 0, -21, 0 }, .smallest = .month, .mode = .trunc, .result = "-P28Y" },
        .{ .rt = .{ 2000, 10, 20 }, .dur = .{ 7, 0, 0, 0, 0, 5, 23 }, .smallest = .hour, .mode = .floor, .result = "P7Y" },
        .{ .rt = .{ 2036, 8, 6 }, .dur = .{ -27, -25, 0, -30, 0, 0, -4 }, .smallest = .year, .mode = .ceil, .result = "-P29Y" },
        .{ .rt = .{ 2041, 7, 31 }, .dur = .{ 0, 29, 0, 0, 0, 18, 0 }, .smallest = .day, .mode = .floor, .result = "P29M" },
        .{ .rt = .{ 1964, 12, 1 }, .dur = .{ 0, 0, -30, 0, 0, 0, 0 }, .smallest = .second, .mode = .half_floor, .result = "-P30W" },
        .{ .rt = .{ 2049, 7, 29 }, .dur = .{ 31, 21, 38, 0, 0, 20, 0 }, .smallest = .second, .mode = .trunc, .result = "P33Y5M22DT20M" },
        .{ .rt = .{ 2096, 4, 28 }, .dur = .{ 0, 3, 0, 0, 0, 0, 0 }, .smallest = .day, .mode = .expand, .result = "P3M" },
        .{ .rt = .{ 1995, 12, 18 }, .dur = .{ 0, 0, -21, 0, -26, -38, -7 }, .smallest = .month, .mode = .half_trunc, .result = "-P5M" },
        .{ .rt = .{ 1952, 8, 16 }, .dur = .{ 0, 33, 0, 30, 0, 18, 37 }, .smallest = .day, .mode = .half_expand, .result = "P33M30D" },
        .{ .rt = .{ 2036, 11, 5 }, .dur = .{ -25, 0, 0, -16, 0, 0, -40 }, .smallest = .year, .mode = .half_floor, .result = "-P25Y" },
        .{ .rt = .{ 2039, 10, 2 }, .dur = .{ 0, 5, 0, 2, 0, 31, 19 }, .smallest = .minute, .mode = .half_ceil, .result = "P5M2DT31M" },
        .{ .rt = .{ 1978, 12, 3 }, .dur = .{ 0, -3, -7, -35, 0, -29, -24 }, .smallest = .second, .mode = .expand, .result = "-P5M22DT29M24S" },
    };
    for (cases) |c| {
        const rt = try PlainDate.create(c.rt[0], c.rt[1], c.rt[2], .reject);
        const d = try Duration.create(c.dur[0], c.dur[1], c.dur[2], c.dur[3], c.dur[4], c.dur[5], c.dur[6], 0, 0, 0);
        try expectIso(c.result, try d.round(rt, .{ .smallest_unit = c.smallest, .rounding_mode = c.mode }));
    }
}

test "total: random-batch differential against real Node" {
    const Case = struct { rt: [3]i32, dur: [7]i64, unit: ztemporal.Unit, result: f64 };
    const cases = [_]Case{
        .{ .rt = .{ 2083, 7, 28 }, .dur = .{ 0, -35, 0, 0, 0, -21, 0 }, .unit = .minute, .result = -1532181 },
        .{ .rt = .{ 1984, 4, 13 }, .dur = .{ 0, 0, 0, 0, 1, 11, 0 }, .unit = .week, .result = 0.007043650793650794 },
        .{ .rt = .{ 2020, 1, 1 }, .dur = .{ 0, 8, 0, 12, 0, 0, 0 }, .unit = .year, .result = 0.6994535519125683 },
        .{ .rt = .{ 2049, 11, 12 }, .dur = .{ 30, 4, 12, 0, 22, 11, 0 }, .unit = .minute, .result = 16074611 },
        .{ .rt = .{ 2065, 8, 30 }, .dur = .{ 14, 0, 0, 0, 15, 28, 0 }, .unit = .second, .result = 441818880 },
        .{ .rt = .{ 2028, 12, 1 }, .dur = .{ 0, 40, 0, 0, 0, 0, 0 }, .unit = .week, .result = 173.85714285714286 },
        .{ .rt = .{ 1981, 3, 20 }, .dur = .{ -17, 0, -20, 0, -17, 0, -33 }, .unit = .second, .result = -548614833 },
        .{ .rt = .{ 2019, 10, 1 }, .dur = .{ 23, 38, 17, 0, 10, 1, 0 }, .unit = .hour, .result = 232258.01666666666 },
        .{ .rt = .{ 1953, 3, 22 }, .dur = .{ 0, 0, 7, 0, 24, 0, 40 }, .unit = .week, .result = 7.142923280423281 },
        .{ .rt = .{ 1971, 10, 12 }, .dur = .{ 36, 23, 7, 0, 0, 0, 0 }, .unit = .year, .result = 38.05205479452055 },
    };
    for (cases) |c| {
        const rt = try PlainDate.create(c.rt[0], c.rt[1], c.rt[2], .reject);
        const d = try Duration.create(c.dur[0], c.dur[1], c.dur[2], c.dur[3], c.dur[4], c.dur[5], c.dur[6], 0, 0, 0);
        try std.testing.expectApproxEqAbs(c.result, try d.total(rt, c.unit), 1e-6);
    }
}
