const std = @import("std");
const ztemporal = @import("ztemporal");
const PlainDateTime = ztemporal.PlainDateTime;
const PlainDate = ztemporal.PlainDate;
const PlainTime = ztemporal.PlainTime;
const Duration = ztemporal.Duration;
const RoundingOptions = ztemporal.RoundingOptions;

fn expectIso(expected: []const u8, d: Duration) !void {
    const allocator = std.testing.allocator;
    const s = try d.toIsoString(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings(expected, s);
}

test "public API: create, toPlainDate/toPlainTime, toIsoString round-trip" {
    const dt = try PlainDateTime.create(2024, 2, 29, 1, 2, 3, 4, 5, 6, .reject);
    const allocator = std.testing.allocator;
    const s = try dt.toIsoString(allocator, false);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("2024-02-29T01:02:03.004005006", s);

    const parsed = try PlainDateTime.parseIso(s);
    try std.testing.expect(PlainDateTime.equals(dt, parsed));

    try std.testing.expect(PlainDate.equals(dt.toPlainDate(), try PlainDate.create(2024, 2, 29, .reject)));
    try std.testing.expect(PlainTime.equals(dt.toPlainTime(), try PlainTime.create(1, 2, 3, 4, 5, 6, .reject)));
}

test "public API: date-only string defaults time to midnight" {
    const dt = try PlainDateTime.parseIso("2024-02-29");
    try std.testing.expect(PlainTime.equals(dt.toPlainTime(), .{}));
}

test "public API: compare orders by date then time" {
    const a = try PlainDateTime.create(2024, 1, 1, 23, 0, 0, 0, 0, 0, .reject);
    const b = try PlainDateTime.create(2024, 1, 2, 0, 0, 0, 0, 0, 0, .reject);
    try std.testing.expectEqual(std.math.Order.lt, PlainDateTime.compare(a, b));
}

test "public API: add/subtract via Duration carries across the date boundary" {
    const dt = try PlainDateTime.create(2024, 1, 31, 23, 0, 0, 0, 0, 0, .reject);
    const r = try dt.add(try Duration.create(0, 0, 0, 0, 2, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(u8, 2), r.date.iso_month);
    try std.testing.expectEqual(@as(u8, 1), r.date.iso_day);
    try std.testing.expectEqual(@as(u8, 1), r.time.hour);

    const back = try r.subtract(try Duration.create(0, 0, 0, 0, 2, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expect(PlainDateTime.equals(dt, back));
}

test "until: default (largestUnit=day) matches real Node" {
    const a = try PlainDateTime.create(2024, 1, 1, 0, 0, 0, 0, 0, 0, .reject);
    const b = try PlainDateTime.create(2025, 3, 15, 5, 30, 0, 0, 0, 0, .reject);
    try expectIso("P439DT5H30M", try a.until(b, .{}));
    try expectIso("-P439DT5H30M", try a.since(b, .{}));
}

test "until: largestUnit=hour flattens the whole interval, no date/time split" {
    const a = try PlainDateTime.create(2024, 1, 1, 0, 0, 0, 0, 0, 0, .reject);
    const b = try PlainDateTime.create(2025, 3, 15, 5, 30, 0, 0, 0, 0, .reject);
    try expectIso("PT10541H30M", try a.until(b, .{ .largest_unit = .hour }));
}

test "until: date/time borrow across a leap-day month boundary" {
    const a = try PlainDateTime.create(2023, 1, 31, 20, 0, 0, 0, 0, 0, .reject);
    const b = try PlainDateTime.create(2024, 3, 2, 4, 0, 0, 0, 0, 0, .reject);
    try expectIso("P1Y1M1DT8H", try a.until(b, .{ .largest_unit = .year }));
}

test "until/since: exact half-day tie, all 5 asymmetric rounding modes" {
    const a = try PlainDateTime.create(2024, 1, 1, 0, 0, 0, 0, 0, 0, .reject);
    const b = try PlainDateTime.create(2024, 1, 1, 12, 0, 0, 0, 0, 0, .reject);
    const cases = [_]struct { mode: ztemporal.RoundingMode, until_s: []const u8, since_s: []const u8 }{
        .{ .mode = .ceil, .until_s = "P1D", .since_s = "PT0S" },
        .{ .mode = .floor, .until_s = "PT0S", .since_s = "-P1D" },
        .{ .mode = .half_ceil, .until_s = "P1D", .since_s = "PT0S" },
        .{ .mode = .half_floor, .until_s = "PT0S", .since_s = "-P1D" },
        .{ .mode = .half_expand, .until_s = "P1D", .since_s = "-P1D" },
    };
    for (cases) |c| {
        const opts = RoundingOptions{ .smallest_unit = .day, .rounding_mode = c.mode };
        try expectIso(c.until_s, try a.until(b, opts));
        try expectIso(c.since_s, try a.since(b, opts));
    }
}

test "until: smallestUnit=month/year (date-only rounding path) matches real Node" {
    const a = try PlainDateTime.create(2024, 1, 15, 10, 0, 0, 0, 0, 0, .reject);
    const b = try PlainDateTime.create(2025, 6, 20, 14, 0, 0, 0, 0, 0, .reject);
    try expectIso("P1Y5M", try a.until(b, .{ .largest_unit = .year, .smallest_unit = .month }));
    try expectIso("-P1Y5M", try a.since(b, .{ .largest_unit = .year, .smallest_unit = .month }));

    const c = try PlainDateTime.create(2020, 3, 1, 0, 0, 0, 0, 0, 0, .reject);
    const d = try PlainDateTime.create(2024, 8, 1, 0, 0, 0, 0, 0, 0, .reject);
    try expectIso("P4Y", try c.until(d, .{ .largest_unit = .year, .smallest_unit = .year }));
}

test "until: backward direction, date and flat-time largestUnit" {
    const a = try PlainDateTime.create(2025, 3, 15, 5, 30, 0, 0, 0, 0, .reject);
    const b = try PlainDateTime.create(2024, 1, 1, 0, 0, 0, 0, 0, 0, .reject);
    try expectIso("-P439DT5H30M", try a.until(b, .{}));
    try expectIso("-PT10541H30M", try a.until(b, .{ .largest_unit = .hour }));
}

test "until/since: random-batch differential against real Node" {
    const Case = struct { a: [6]i32, b: [6]i32, largest: ztemporal.Unit, smallest: ztemporal.Unit, mode: ztemporal.RoundingMode, until_s: []const u8, since_s: []const u8 };
    const cases = [_]Case{
        .{ .a = .{ 1954, 11, 9, 3, 35, 17 }, .b = .{ 2073, 6, 9, 13, 1, 49 }, .largest = .year, .smallest = .year, .mode = .half_even, .until_s = "P119Y", .since_s = "-P119Y" },
        .{ .a = .{ 1985, 1, 28, 23, 56, 37 }, .b = .{ 1992, 12, 23, 10, 46, 35 }, .largest = .second, .smallest = .second, .mode = .ceil, .until_s = "PT249302998S", .since_s = "-PT249302998S" },
        .{ .a = .{ 2048, 12, 10, 22, 50, 43 }, .b = .{ 1986, 1, 15, 3, 51, 42 }, .largest = .month, .smallest = .day, .mode = .ceil, .until_s = "-P754M26D", .since_s = "P754M27D" },
        .{ .a = .{ 1963, 4, 11, 16, 43, 53 }, .b = .{ 2073, 1, 17, 6, 45, 39 }, .largest = .day, .smallest = .minute, .mode = .ceil, .until_s = "P40093DT14H2M", .since_s = "-P40093DT14H1M" },
        .{ .a = .{ 2035, 1, 26, 1, 40, 32 }, .b = .{ 2069, 4, 19, 10, 23, 46 }, .largest = .second, .smallest = .second, .mode = .half_ceil, .until_s = "PT1080204194S", .since_s = "-PT1080204194S" },
        .{ .a = .{ 2027, 1, 19, 9, 51, 40 }, .b = .{ 2012, 11, 21, 3, 18, 20 }, .largest = .second, .smallest = .second, .mode = .trunc, .until_s = "-PT446884400S", .since_s = "PT446884400S" },
        .{ .a = .{ 2080, 2, 12, 2, 14, 54 }, .b = .{ 1966, 11, 20, 17, 0, 11 }, .largest = .month, .smallest = .month, .mode = .floor, .until_s = "-P1359M", .since_s = "P1358M" },
        .{ .a = .{ 2037, 5, 28, 11, 51, 34 }, .b = .{ 2056, 6, 29, 21, 36, 34 }, .largest = .day, .smallest = .hour, .mode = .expand, .until_s = "P6972DT10H", .since_s = "-P6972DT10H" },
        .{ .a = .{ 1951, 12, 15, 6, 46, 1 }, .b = .{ 2003, 10, 9, 22, 25, 13 }, .largest = .minute, .smallest = .minute, .mode = .ceil, .until_s = "PT27254380M", .since_s = "-PT27254379M" },
        .{ .a = .{ 2078, 3, 30, 16, 7, 2 }, .b = .{ 1976, 5, 28, 1, 39, 9 }, .largest = .year, .smallest = .year, .mode = .half_expand, .until_s = "-P102Y", .since_s = "P102Y" },
        .{ .a = .{ 2076, 8, 28, 20, 16, 57 }, .b = .{ 2018, 5, 15, 1, 8, 30 }, .largest = .second, .smallest = .second, .mode = .half_even, .until_s = "-PT1839524907S", .since_s = "PT1839524907S" },
        .{ .a = .{ 2055, 4, 10, 22, 45, 3 }, .b = .{ 2089, 5, 8, 10, 56, 30 }, .largest = .day, .smallest = .day, .mode = .half_trunc, .until_s = "P12447D", .since_s = "-P12447D" },
        .{ .a = .{ 2000, 6, 28, 19, 51, 14 }, .b = .{ 2057, 6, 26, 22, 22, 45 }, .largest = .week, .smallest = .hour, .mode = .half_floor, .until_s = "P2973W6DT3H", .since_s = "-P2973W6DT3H" },
        .{ .a = .{ 1982, 12, 14, 21, 9, 13 }, .b = .{ 1971, 6, 29, 15, 2, 11 }, .largest = .week, .smallest = .minute, .mode = .half_expand, .until_s = "-P598WT6H7M", .since_s = "P598WT6H7M" },
        .{ .a = .{ 2022, 8, 15, 5, 58, 34 }, .b = .{ 1964, 2, 25, 17, 19, 9 }, .largest = .second, .smallest = .second, .mode = .half_trunc, .until_s = "-PT1845117565S", .since_s = "PT1845117565S" },
        .{ .a = .{ 2088, 1, 31, 17, 46, 33 }, .b = .{ 1998, 9, 5, 13, 47, 28 }, .largest = .year, .smallest = .week, .mode = .half_trunc, .until_s = "-P89Y4M4W", .since_s = "P89Y4M4W" },
        .{ .a = .{ 1950, 1, 2, 13, 38, 20 }, .b = .{ 2013, 11, 12, 15, 12, 17 }, .largest = .hour, .smallest = .minute, .mode = .half_trunc, .until_s = "PT559801H34M", .since_s = "-PT559801H34M" },
        .{ .a = .{ 2060, 9, 11, 7, 2, 51 }, .b = .{ 2046, 4, 22, 5, 14, 5 }, .largest = .second, .smallest = .second, .mode = .half_trunc, .until_s = "-PT454124926S", .since_s = "PT454124926S" },
        .{ .a = .{ 2001, 7, 17, 20, 19, 8 }, .b = .{ 2061, 9, 21, 9, 53, 58 }, .largest = .day, .smallest = .minute, .mode = .trunc, .until_s = "P21980DT13H34M", .since_s = "-P21980DT13H34M" },
        .{ .a = .{ 1963, 7, 6, 17, 26, 10 }, .b = .{ 1981, 2, 4, 8, 37, 4 }, .largest = .day, .smallest = .second, .mode = .half_even, .until_s = "P6422DT15H10M54S", .since_s = "-P6422DT15H10M54S" },
    };
    for (cases) |c| {
        const a = try PlainDateTime.create(c.a[0], c.a[1], c.a[2], c.a[3], c.a[4], c.a[5], 0, 0, 0, .reject);
        const b = try PlainDateTime.create(c.b[0], c.b[1], c.b[2], c.b[3], c.b[4], c.b[5], 0, 0, 0, .reject);
        const opts = RoundingOptions{ .largest_unit = c.largest, .smallest_unit = c.smallest, .rounding_mode = c.mode };
        try expectIso(c.until_s, try a.until(b, opts));
        try expectIso(c.since_s, try a.since(b, opts));
    }
}

test "until: rejects smallestUnit finer than largestUnit" {
    const a = try PlainDateTime.create(2024, 1, 1, 0, 0, 0, 0, 0, 0, .reject);
    const b = try PlainDateTime.create(2024, 1, 2, 0, 0, 0, 0, 0, 0, .reject);
    try std.testing.expectError(error.InvalidRange, a.until(b, .{ .largest_unit = .month, .smallest_unit = .year }));
}
