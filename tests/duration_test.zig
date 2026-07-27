const std = @import("std");
const ztemporal = @import("ztemporal");
const Duration = ztemporal.Duration;

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
