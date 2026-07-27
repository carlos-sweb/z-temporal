const std = @import("std");
const ztemporal = @import("ztemporal");
const PlainTime = ztemporal.PlainTime;

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
