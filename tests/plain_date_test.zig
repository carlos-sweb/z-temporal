const std = @import("std");
const ztemporal = @import("ztemporal");
const PlainDate = ztemporal.PlainDate;
const Duration = ztemporal.Duration;
const RoundingOptions = ztemporal.RoundingOptions;

fn expectIso(expected: []const u8, d: Duration) !void {
    const allocator = std.testing.allocator;
    const s = try d.toIsoString(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings(expected, s);
}

test "public API: create, compare, toIsoString round-trip" {
    const d = try PlainDate.create(2024, 2, 29, .reject);
    try std.testing.expectEqual(@as(i32, 2024), d.year());
    try std.testing.expectEqual(@as(u8, 2), d.month());
    try std.testing.expectEqual(@as(u8, 29), d.day());
    try std.testing.expectEqual(@as(u8, 4), d.dayOfWeek()); // Thursday

    const allocator = std.testing.allocator;
    const s = try d.toIsoString(allocator, false);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("2024-02-29", s);

    const parsed = try PlainDate.parseIso(s);
    try std.testing.expect(PlainDate.equals(d, parsed));
}

test "public API: overflow constrain/reject via .from()-style create" {
    const clamped = try PlainDate.create(2023, 2, 30, .constrain);
    try std.testing.expectEqual(@as(u8, 28), clamped.day());
    try std.testing.expectError(ztemporal.TemporalError.InvalidRange, PlainDate.create(2023, 2, 30, .reject));
}

test "public API: withFields overrides only the given fields" {
    const d = try PlainDate.create(2024, 2, 29, .reject);
    const d2 = try d.withFields(null, 3, null, .reject);
    try std.testing.expectEqual(@as(i32, 2024), d2.year());
    try std.testing.expectEqual(@as(u8, 3), d2.month());
    try std.testing.expectEqual(@as(u8, 29), d2.day());
}

test "public API: add/subtract via Duration" {
    const d = try PlainDate.create(2024, 1, 31, .reject);
    const added = try d.add(try Duration.create(0, 1, 0, 0, 0, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(u8, 2), added.month());
    try std.testing.expectEqual(@as(u8, 29), added.day());

    // subtract is not necessarily add's exact inverse when clamping
    // occurred (Jan 31 -> Feb 29 clamped; Feb 29 - 1 month -> Jan 29, not
    // back to 31) -- ground-truthed against real Node, not assumed.
    const back = try added.subtract(try Duration.create(0, 1, 0, 0, 0, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(i32, 2024), back.year());
    try std.testing.expectEqual(@as(u8, 1), back.month());
    try std.testing.expectEqual(@as(u8, 29), back.day());
}

test "until: default (largestUnit=day) matches real Node" {
    const a = try PlainDate.create(2024, 1, 1, .reject);
    const b = try PlainDate.create(2025, 3, 15, .reject);
    try expectIso("P439D", try a.until(b, .{}));
    try expectIso("-P439D", try a.since(b, .{}));
}

test "until: all 4 largestUnit variants agree on the same span" {
    const a = try PlainDate.create(2024, 1, 1, .reject);
    const b = try PlainDate.create(2025, 3, 15, .reject);
    try expectIso("P1Y2M14D", try a.until(b, .{ .largest_unit = .year }));
    try expectIso("P14M14D", try a.until(b, .{ .largest_unit = .month }));
    try expectIso("P62W5D", try a.until(b, .{ .largest_unit = .week }));
    try expectIso("P439D", try a.until(b, .{ .largest_unit = .day }));
}

test "until: leap-year day-of-month borrow (no naive Y/M/D subtraction)" {
    const a = try PlainDate.create(2023, 1, 31, .reject);
    const b = try PlainDate.create(2024, 2, 29, .reject);
    try expectIso("P1Y29D", try a.until(b, .{ .largest_unit = .year }));
}

test "until/since: direction-dependent balance, not a simple negation on reverse" {
    const a = try PlainDate.create(2024, 1, 30, .reject);
    const b = try PlainDate.create(2024, 3, 1, .reject);
    try expectIso("P1M1D", try a.until(b, .{ .largest_unit = .month }));
    try expectIso("-P1M2D", try b.until(a, .{ .largest_unit = .month }));
    try expectIso("-P1M1D", try a.since(b, .{ .largest_unit = .month }));
    try expectIso("P1M2D", try b.since(a, .{ .largest_unit = .month }));
}

test "until/since: rounding-tie asymmetry matches real Node on both sides" {
    // Ground-truthed via 2024-04-01 -> 2024-02-15 (15/29 > 0.5, since Feb
    // 2024 is the month one step further back from March, the
    // intermediate -- not March's own 31 days).
    const start = try PlainDate.create(2024, 4, 1, .reject);
    const end = try PlainDate.create(2024, 2, 15, .reject);
    const opts = RoundingOptions{ .largest_unit = .month, .smallest_unit = .month };
    try expectIso("-P2M", try start.until(end, .{ .largest_unit = .month, .smallest_unit = .month, .rounding_mode = .half_expand }));
    try expectIso("P2M", try start.since(end, .{ .largest_unit = .month, .smallest_unit = .month, .rounding_mode = .half_expand }));
    try expectIso("-P1M", try start.until(end, opts));
    try expectIso("P1M", try start.since(end, opts));
}

test "until: smallestUnit week folds day remainder into weeks (mixes with years/months)" {
    const a = try PlainDate.create(2024, 1, 1, .reject);
    const b = try PlainDate.create(2025, 3, 15, .reject);
    try expectIso("P1Y2M2W", try a.until(b, .{ .largest_unit = .year, .smallest_unit = .week }));
    try expectIso("-P1Y2M2W", try a.since(b, .{ .largest_unit = .year, .smallest_unit = .week }));
    try expectIso("P62W", try a.until(b, .{ .largest_unit = .week, .smallest_unit = .week }));
}

test "roundingIncrement: calendar units uncapped, matches real Node" {
    const a = try PlainDate.create(2024, 1, 1, .reject);
    const b = try PlainDate.create(2027, 5, 15, .reject);
    try expectIso("P2Y", try a.until(b, .{ .largest_unit = .year, .smallest_unit = .year, .rounding_increment = 2 }));
}

test "roundingIncrement: week grouping matches real Node, both directions" {
    const a = try PlainDate.create(2024, 1, 1, .reject);
    const b = try PlainDate.create(2025, 3, 15, .reject);
    const opts = RoundingOptions{ .largest_unit = .week, .smallest_unit = .week, .rounding_increment = 3 };
    try expectIso("P60W", try a.until(b, opts));
    try expectIso("-P60W", try b.until(a, opts));
}

test "until/since: random-batch differential against real Node" {
    const Case = struct { a: [3]i32, b: [3]i32, largest: ztemporal.Unit, smallest: ztemporal.Unit, mode: ztemporal.RoundingMode, until_s: []const u8, since_s: []const u8 };
    const cases = [_]Case{
        .{ .a = .{ 2197, 4, 5 }, .b = .{ 2074, 1, 12 }, .largest = .week, .smallest = .day, .mode = .ceil, .until_s = "-P6429W5D", .since_s = "P6429W5D" },
        .{ .a = .{ 2166, 3, 18 }, .b = .{ 1900, 12, 30 }, .largest = .week, .smallest = .day, .mode = .ceil, .until_s = "-P13838W2D", .since_s = "P13838W2D" },
        .{ .a = .{ 2111, 2, 1 }, .b = .{ 1921, 1, 22 }, .largest = .year, .smallest = .year, .mode = .half_expand, .until_s = "-P190Y", .since_s = "P190Y" },
        .{ .a = .{ 1982, 1, 8 }, .b = .{ 1935, 3, 25 }, .largest = .month, .smallest = .week, .mode = .half_even, .until_s = "-P561M2W", .since_s = "P561M2W" },
        .{ .a = .{ 1929, 3, 14 }, .b = .{ 2173, 12, 4 }, .largest = .day, .smallest = .day, .mode = .trunc, .until_s = "P89385D", .since_s = "-P89385D" },
        .{ .a = .{ 1986, 5, 17 }, .b = .{ 1999, 1, 4 }, .largest = .month, .smallest = .day, .mode = .ceil, .until_s = "P151M18D", .since_s = "-P151M18D" },
        .{ .a = .{ 1954, 9, 1 }, .b = .{ 2178, 11, 26 }, .largest = .week, .smallest = .week, .mode = .half_even, .until_s = "P11700W", .since_s = "-P11700W" },
        .{ .a = .{ 2078, 6, 28 }, .b = .{ 1995, 1, 25 }, .largest = .year, .smallest = .year, .mode = .half_expand, .until_s = "-P83Y", .since_s = "P83Y" },
        .{ .a = .{ 2056, 5, 16 }, .b = .{ 1988, 10, 31 }, .largest = .week, .smallest = .week, .mode = .floor, .until_s = "-P3525W", .since_s = "P3524W" },
        .{ .a = .{ 1905, 8, 18 }, .b = .{ 1937, 6, 10 }, .largest = .month, .smallest = .day, .mode = .ceil, .until_s = "P381M23D", .since_s = "-P381M23D" },
        .{ .a = .{ 2033, 4, 1 }, .b = .{ 2094, 5, 3 }, .largest = .month, .smallest = .month, .mode = .expand, .until_s = "P734M", .since_s = "-P734M" },
        .{ .a = .{ 1963, 12, 8 }, .b = .{ 2018, 2, 28 }, .largest = .week, .smallest = .day, .mode = .half_trunc, .until_s = "P2829W3D", .since_s = "-P2829W3D" },
        .{ .a = .{ 2111, 6, 9 }, .b = .{ 1923, 11, 8 }, .largest = .day, .smallest = .day, .mode = .half_expand, .until_s = "-P68514D", .since_s = "P68514D" },
        .{ .a = .{ 1991, 6, 5 }, .b = .{ 2005, 10, 16 }, .largest = .day, .smallest = .day, .mode = .ceil, .until_s = "P5247D", .since_s = "-P5247D" },
        .{ .a = .{ 1996, 5, 24 }, .b = .{ 2177, 3, 16 }, .largest = .month, .smallest = .month, .mode = .ceil, .until_s = "P2170M", .since_s = "-P2169M" },
        .{ .a = .{ 2081, 9, 13 }, .b = .{ 2088, 2, 19 }, .largest = .week, .smallest = .day, .mode = .half_expand, .until_s = "P335W5D", .since_s = "-P335W5D" },
        .{ .a = .{ 2055, 10, 23 }, .b = .{ 2013, 1, 20 }, .largest = .week, .smallest = .week, .mode = .half_trunc, .until_s = "-P2231W", .since_s = "P2231W" },
        .{ .a = .{ 2160, 4, 6 }, .b = .{ 2102, 2, 12 }, .largest = .month, .smallest = .month, .mode = .expand, .until_s = "-P698M", .since_s = "P698M" },
        .{ .a = .{ 2002, 10, 23 }, .b = .{ 2184, 7, 19 }, .largest = .year, .smallest = .day, .mode = .trunc, .until_s = "P181Y8M26D", .since_s = "-P181Y8M26D" },
        .{ .a = .{ 2040, 5, 26 }, .b = .{ 2015, 7, 2 }, .largest = .day, .smallest = .day, .mode = .trunc, .until_s = "-P9095D", .since_s = "P9095D" },
        .{ .a = .{ 1947, 8, 1 }, .b = .{ 2120, 12, 2 }, .largest = .day, .smallest = .day, .mode = .trunc, .until_s = "P63311D", .since_s = "-P63311D" },
        .{ .a = .{ 2065, 10, 30 }, .b = .{ 1914, 3, 22 }, .largest = .day, .smallest = .day, .mode = .half_ceil, .until_s = "-P55375D", .since_s = "P55375D" },
        .{ .a = .{ 1949, 9, 9 }, .b = .{ 1901, 4, 26 }, .largest = .week, .smallest = .day, .mode = .expand, .until_s = "-P2524W", .since_s = "P2524W" },
        .{ .a = .{ 2123, 4, 16 }, .b = .{ 2179, 2, 13 }, .largest = .week, .smallest = .day, .mode = .half_trunc, .until_s = "P2913W1D", .since_s = "-P2913W1D" },
        .{ .a = .{ 2179, 12, 5 }, .b = .{ 1905, 5, 4 }, .largest = .year, .smallest = .year, .mode = .half_expand, .until_s = "-P275Y", .since_s = "P275Y" },
    };
    for (cases) |c| {
        const a = try PlainDate.create(c.a[0], c.a[1], c.a[2], .reject);
        const b = try PlainDate.create(c.b[0], c.b[1], c.b[2], .reject);
        const opts = RoundingOptions{ .largest_unit = c.largest, .smallest_unit = c.smallest, .rounding_mode = c.mode };
        try expectIso(c.until_s, try a.until(b, opts));
        try expectIso(c.since_s, try a.since(b, opts));
    }
}

test "until: rejects a time unit (PlainDate has no time component)" {
    const a = try PlainDate.create(2024, 1, 1, .reject);
    const b = try PlainDate.create(2024, 2, 1, .reject);
    try std.testing.expectError(error.InvalidRange, a.until(b, .{ .largest_unit = .hour }));
}
