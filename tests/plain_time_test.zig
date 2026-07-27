const std = @import("std");
const ztemporal = @import("ztemporal");
const PlainTime = ztemporal.PlainTime;
const Duration = ztemporal.Duration;
const RoundingOptions = ztemporal.RoundingOptions;

fn expectIso(expected: []const u8, d: Duration) !void {
    const allocator = std.testing.allocator;
    const s = try d.toIsoString(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings(expected, s);
}

test "public API: create, compare, toIsoString round-trip" {
    const t = try PlainTime.create(1, 2, 3, 4, 5, 6, .reject);
    const allocator = std.testing.allocator;
    const s = try t.toIsoString(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("01:02:03.004005006", s);

    const parsed = try PlainTime.parseIso(s);
    try std.testing.expect(PlainTime.equals(t, parsed));
}

test "public API: symmetric overflow clamp" {
    const c = try PlainTime.create(25, 0, 0, 0, 0, 0, .constrain);
    try std.testing.expectEqual(@as(u8, 23), c.hour);
    try std.testing.expectError(ztemporal.TemporalError.InvalidRange, PlainTime.create(25, 0, 0, 0, 0, 0, .reject));
}

test "public API: compare orders by total nanoseconds" {
    const a = try PlainTime.create(1, 0, 0, 0, 0, 0, .reject);
    const b = try PlainTime.create(2, 0, 0, 0, 0, 0, .reject);
    try std.testing.expectEqual(std.math.Order.lt, PlainTime.compare(a, b));
}

test "public API: add/subtract via Duration wraps mod 24h" {
    const t = try PlainTime.create(23, 30, 0, 0, 0, 0, .reject);
    const r = t.add(try Duration.create(0, 0, 0, 0, 1, 0, 0, 0, 0, 0));
    try std.testing.expectEqual(@as(u8, 0), r.hour);
    try std.testing.expectEqual(@as(u8, 30), r.minute);

    const back = r.subtract(try Duration.create(0, 0, 0, 0, 1, 0, 0, 0, 0, 0));
    try std.testing.expect(PlainTime.equals(t, back));
}

test "until: default (largestUnit=hour) matches real Node" {
    const a = try PlainTime.create(1, 0, 0, 0, 0, 0, .reject);
    const b = try PlainTime.create(5, 30, 0, 0, 0, 0, .reject);
    try expectIso("PT4H30M", try a.until(b, .{}));
    try expectIso("-PT4H30M", try a.since(b, .{}));
}

test "until: largestUnit=minute flattens (no separate hour field)" {
    const a = try PlainTime.create(1, 0, 0, 0, 0, 0, .reject);
    const b = try PlainTime.create(5, 30, 0, 0, 0, 0, .reject);
    try expectIso("PT270M", try a.until(b, .{ .largest_unit = .minute }));
}

test "until: roundingIncrement groups minutes" {
    const a = try PlainTime.create(0, 0, 0, 0, 0, 0, .reject);
    const b = try PlainTime.create(0, 47, 0, 0, 0, 0, .reject);
    try expectIso("PT45M", try a.until(b, .{ .smallest_unit = .minute, .rounding_increment = 15 }));
    try expectIso("PT30M", try a.until(b, .{ .smallest_unit = .minute, .rounding_increment = 30 }));
}

test "roundingIncrement: hour must divide 24 and be strictly less" {
    const a = try PlainTime.create(0, 0, 0, 0, 0, 0, .reject);
    const b = try PlainTime.create(12, 0, 0, 0, 0, 0, .reject);
    try std.testing.expectError(error.InvalidRange, a.until(b, .{ .smallest_unit = .hour, .rounding_increment = 24 }));
    try std.testing.expectError(error.InvalidRange, a.until(b, .{ .smallest_unit = .hour, .rounding_increment = 23 }));
}

test "until: backward direction, flattened at minute/second largestUnit" {
    const a = try PlainTime.create(5, 30, 0, 0, 0, 0, .reject);
    const b = try PlainTime.create(1, 0, 0, 0, 0, 0, .reject);
    try expectIso("-PT270M", try a.until(b, .{ .largest_unit = .minute }));
    try expectIso("-PT16200S", try a.until(b, .{ .largest_unit = .second }));
}

test "until: rejects a date unit (PlainTime has no date component)" {
    const a = try PlainTime.create(1, 0, 0, 0, 0, 0, .reject);
    const b = try PlainTime.create(5, 0, 0, 0, 0, 0, .reject);
    try std.testing.expectError(error.InvalidRange, a.until(b, .{ .largest_unit = .day }));
}
