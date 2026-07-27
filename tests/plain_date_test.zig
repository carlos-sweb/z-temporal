const std = @import("std");
const ztemporal = @import("ztemporal");
const PlainDate = ztemporal.PlainDate;
const Duration = ztemporal.Duration;

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
