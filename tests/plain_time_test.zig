const std = @import("std");
const ztemporal = @import("ztemporal");
const PlainTime = ztemporal.PlainTime;
const Duration = ztemporal.Duration;
const RoundingOptions = ztemporal.RoundingOptions;

fn expectIso(expected: []const u8, d: Duration) !void {
    const allocator = std.testing.allocator;
    const s = try d.toString(allocator, .{});
    defer allocator.free(s);
    try std.testing.expectEqualStrings(expected, s);
}

test "public API: init, compare, toString round-trip" {
    const t = try PlainTime.init(1, 2, 3, 4, 5, 6);
    const allocator = std.testing.allocator;
    const s = try t.toString(allocator, .{});
    defer allocator.free(s);
    try std.testing.expectEqualStrings("01:02:03.004005006", s);

    const parsed = try PlainTime.from(.{ .string = s }, .{});
    try std.testing.expect(PlainTime.equals(t, parsed));
}

test "public API: symmetric overflow clamp" {
    const c = try PlainTime.from(.{ .fields = .{ .hour = 25, .minute = 0, .second = 0, .millisecond = 0, .microsecond = 0, .nanosecond = 0 } }, .{ .overflow = .constrain });
    try std.testing.expectEqual(@as(u8, 23), c.hour);
    try std.testing.expectError(ztemporal.TemporalError.RangeError, PlainTime.init(25, 0, 0, 0, 0, 0));
}

test "public API: compare orders by total nanoseconds" {
    const a = try PlainTime.init(1, 0, 0, 0, 0, 0);
    const b = try PlainTime.init(2, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(std.math.Order.lt, PlainTime.compare(a, b));
}

test "public API: add/subtract via Duration wraps mod 24h" {
    const t = try PlainTime.init(23, 30, 0, 0, 0, 0);
    const r = t.add(try Duration.init(0, 0, 0, 0, 1, 0, 0, 0, 0, 0));
    try std.testing.expectEqual(@as(u8, 0), r.hour);
    try std.testing.expectEqual(@as(u8, 30), r.minute);

    const back = r.subtract(try Duration.init(0, 0, 0, 0, 1, 0, 0, 0, 0, 0));
    try std.testing.expect(PlainTime.equals(t, back));
}

test "until: default (largestUnit=hour) matches real Node" {
    const a = try PlainTime.init(1, 0, 0, 0, 0, 0);
    const b = try PlainTime.init(5, 30, 0, 0, 0, 0);
    try expectIso("PT4H30M", try a.until(b, .{}));
    try expectIso("-PT4H30M", try a.since(b, .{}));
}

test "until: largestUnit=minute flattens (no separate hour field)" {
    const a = try PlainTime.init(1, 0, 0, 0, 0, 0);
    const b = try PlainTime.init(5, 30, 0, 0, 0, 0);
    try expectIso("PT270M", try a.until(b, .{ .largestUnit = .minute }));
}

test "until: roundingIncrement groups minutes" {
    const a = try PlainTime.init(0, 0, 0, 0, 0, 0);
    const b = try PlainTime.init(0, 47, 0, 0, 0, 0);
    try expectIso("PT45M", try a.until(b, .{ .smallestUnit = .minute, .roundingIncrement = 15 }));
    try expectIso("PT30M", try a.until(b, .{ .smallestUnit = .minute, .roundingIncrement = 30 }));
}

test "roundingIncrement: hour must divide 24 and be strictly less" {
    const a = try PlainTime.init(0, 0, 0, 0, 0, 0);
    const b = try PlainTime.init(12, 0, 0, 0, 0, 0);
    try std.testing.expectError(error.RangeError, a.until(b, .{ .smallestUnit = .hour, .roundingIncrement = 24 }));
    try std.testing.expectError(error.RangeError, a.until(b, .{ .smallestUnit = .hour, .roundingIncrement = 23 }));
}

test "until: backward direction, flattened at minute/second largestUnit" {
    const a = try PlainTime.init(5, 30, 0, 0, 0, 0);
    const b = try PlainTime.init(1, 0, 0, 0, 0, 0);
    try expectIso("-PT270M", try a.until(b, .{ .largestUnit = .minute }));
    try expectIso("-PT16200S", try a.until(b, .{ .largestUnit = .second }));
}

test "round: default mode is halfExpand (opposite of until/since's trunc)" {
    const t = try PlainTime.init(12, 34, 56, 789, 123, 456);
    const r1 = try t.round(.{ .smallestUnit = .minute });
    try std.testing.expectEqual(@as(u8, 12), r1.hour);
    try std.testing.expectEqual(@as(u8, 35), r1.minute);
    const r2 = try t.round(.{ .smallestUnit = .hour });
    try std.testing.expectEqual(@as(u8, 13), r2.hour);
}

test "round: exact tie rounds via halfExpand, floor/ceil override" {
    const t = try PlainTime.init(12, 30, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(u8, 13), (try t.round(.{ .smallestUnit = .hour })).hour);
    try std.testing.expectEqual(@as(u8, 12), (try t.round(.{ .smallestUnit = .hour, .roundingMode = .floor })).hour);
    try std.testing.expectEqual(@as(u8, 13), (try t.round(.{ .smallestUnit = .hour, .roundingMode = .ceil })).hour);
}

test "round: roundingIncrement groups, wraps mod-24h" {
    const t = try PlainTime.init(12, 34, 0, 0, 0, 0);
    const r = try t.round(.{ .smallestUnit = .minute, .roundingIncrement = 15 });
    try std.testing.expectEqual(@as(u8, 12), r.hour);
    try std.testing.expectEqual(@as(u8, 30), r.minute);

    const midnight_wrap = try PlainTime.init(23, 59, 30, 0, 0, 0);
    const wrapped = try midnight_wrap.round(.{ .smallestUnit = .minute });
    try std.testing.expectEqual(@as(u8, 0), wrapped.hour);
    try std.testing.expectEqual(@as(u8, 0), wrapped.minute);
}

test "round: rejects missing smallestUnit and a date unit" {
    const t = try PlainTime.init(1, 0, 0, 0, 0, 0);
    try std.testing.expectError(error.RangeError, t.round(.{}));
    try std.testing.expectError(error.RangeError, t.round(.{ .smallestUnit = .day }));
}

test "until: rejects a date unit (PlainTime has no date component)" {
    const a = try PlainTime.init(1, 0, 0, 0, 0, 0);
    const b = try PlainTime.init(5, 0, 0, 0, 0, 0);
    try std.testing.expectError(error.RangeError, a.until(b, .{ .largestUnit = .day }));
}
