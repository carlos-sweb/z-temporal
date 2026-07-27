const std = @import("std");
const ztemporal = @import("ztemporal");
const PlainYearMonth = ztemporal.PlainYearMonth;
const PlainDate = ztemporal.PlainDate;
const Duration = ztemporal.Duration;

test "public API: create, compare, toIsoString round-trip" {
    const ym = try PlainYearMonth.create(2024, 2, .reject);
    try std.testing.expectEqual(@as(i32, 2024), ym.year());
    try std.testing.expectEqual(@as(u8, 2), ym.month());
    try std.testing.expectEqual(@as(u8, 29), ym.daysInMonth());
    try std.testing.expectEqual(@as(u16, 366), ym.daysInYear());
    try std.testing.expect(ym.inLeapYear());

    const allocator = std.testing.allocator;
    const s = try ym.toIsoString(allocator, false);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("2024-02", s);

    const parsed = try PlainYearMonth.parseIso(s);
    try std.testing.expect(PlainYearMonth.equals(ym, parsed));
}

test "public API: withFields" {
    const ym = try PlainYearMonth.create(2024, 2, .reject);
    const ym2 = try ym.withFields(null, 6, .reject);
    try std.testing.expectEqual(@as(i32, 2024), ym2.year());
    try std.testing.expectEqual(@as(u8, 6), ym2.month());
}

test "public API: add/subtract via Duration, delegates to day=1 PlainDate" {
    const ym = try PlainYearMonth.create(2024, 1, .reject);
    const added = try ym.add(try Duration.create(0, 13, 0, 0, 0, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(i32, 2025), added.year());
    try std.testing.expectEqual(@as(u8, 2), added.month());

    const back = try added.subtract(try Duration.create(0, 13, 0, 0, 0, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expect(PlainYearMonth.equals(ym, back));
}

test "public API: until/since" {
    const a = try PlainYearMonth.create(2024, 1, .reject);
    const b = try PlainYearMonth.create(2025, 6, .reject);
    const allocator = std.testing.allocator;

    const d = try a.until(b, .{});
    const s = try d.toIsoString(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("P1Y5M", s);

    const d2 = try b.since(a, .{});
    const s2 = try d2.toIsoString(allocator);
    defer allocator.free(s2);
    try std.testing.expectEqualStrings("P1Y5M", s2);
}

test "public API: toPlainDate always constrains" {
    const ym = try PlainYearMonth.create(2024, 2, .reject);
    const d = try ym.toPlainDate(35);
    try std.testing.expect(PlainDate.equals(d, try PlainDate.create(2024, 2, 29, .reject)));
}

test "public API: random-batch differential against real Node" {
    const Case = struct { a: [2]i32, b: [2]i32, until_s: []const u8, since_s: []const u8, cmp: i8 };
    const cases = [_]Case{
        .{ .a = .{ 2194, 11 }, .b = .{ 2104, 10 }, .until_s = "-P90Y1M", .since_s = "P90Y1M", .cmp = 1 },
        .{ .a = .{ 2144, 10 }, .b = .{ 2049, 4 }, .until_s = "-P95Y6M", .since_s = "P95Y6M", .cmp = 1 },
        .{ .a = .{ 2104, 10 }, .b = .{ 2033, 5 }, .until_s = "-P71Y5M", .since_s = "P71Y5M", .cmp = 1 },
        .{ .a = .{ 1963, 6 }, .b = .{ 2019, 2 }, .until_s = "P55Y8M", .since_s = "-P55Y8M", .cmp = -1 },
        .{ .a = .{ 1924, 5 }, .b = .{ 1988, 4 }, .until_s = "P63Y11M", .since_s = "-P63Y11M", .cmp = -1 },
        .{ .a = .{ 2010, 11 }, .b = .{ 1977, 2 }, .until_s = "-P33Y9M", .since_s = "P33Y9M", .cmp = 1 },
        .{ .a = .{ 2167, 2 }, .b = .{ 2122, 1 }, .until_s = "-P45Y1M", .since_s = "P45Y1M", .cmp = 1 },
        .{ .a = .{ 2101, 8 }, .b = .{ 1939, 6 }, .until_s = "-P162Y2M", .since_s = "P162Y2M", .cmp = 1 },
        .{ .a = .{ 1974, 6 }, .b = .{ 2062, 10 }, .until_s = "P88Y4M", .since_s = "-P88Y4M", .cmp = -1 },
        .{ .a = .{ 2149, 1 }, .b = .{ 2037, 10 }, .until_s = "-P111Y3M", .since_s = "P111Y3M", .cmp = 1 },
        .{ .a = .{ 2194, 8 }, .b = .{ 1921, 8 }, .until_s = "-P273Y", .since_s = "P273Y", .cmp = 1 },
        .{ .a = .{ 1912, 8 }, .b = .{ 1968, 12 }, .until_s = "P56Y4M", .since_s = "-P56Y4M", .cmp = -1 },
        .{ .a = .{ 2069, 7 }, .b = .{ 1993, 10 }, .until_s = "-P75Y9M", .since_s = "P75Y9M", .cmp = 1 },
        .{ .a = .{ 1967, 11 }, .b = .{ 2131, 5 }, .until_s = "P163Y6M", .since_s = "-P163Y6M", .cmp = -1 },
        .{ .a = .{ 1967, 3 }, .b = .{ 2045, 3 }, .until_s = "P78Y", .since_s = "-P78Y", .cmp = -1 },
    };
    const allocator = std.testing.allocator;
    for (cases) |c| {
        const a = try PlainYearMonth.create(c.a[0], c.a[1], .reject);
        const b = try PlainYearMonth.create(c.b[0], c.b[1], .reject);
        const until_dur = try a.until(b, .{});
        const until_s = try until_dur.toIsoString(allocator);
        defer allocator.free(until_s);
        try std.testing.expectEqualStrings(c.until_s, until_s);

        const since_dur = try a.since(b, .{});
        const since_s = try since_dur.toIsoString(allocator);
        defer allocator.free(since_s);
        try std.testing.expectEqualStrings(c.since_s, since_s);

        const expected_cmp: std.math.Order = if (c.cmp > 0) .gt else if (c.cmp < 0) .lt else .eq;
        try std.testing.expectEqual(expected_cmp, PlainYearMonth.compare(a, b));
    }
}

test "public API: PlainDate.toPlainYearMonth round-trips" {
    const d = try PlainDate.create(2024, 2, 29, .reject);
    const ym = d.toPlainYearMonth();
    try std.testing.expect(PlainYearMonth.equals(ym, try PlainYearMonth.create(2024, 2, .reject)));
}
