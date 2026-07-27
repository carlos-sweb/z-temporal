const std = @import("std");
const ztemporal = @import("ztemporal");
const PlainMonthDay = ztemporal.PlainMonthDay;
const PlainDate = ztemporal.PlainDate;

test "public API: create, equals, toIsoString round-trip" {
    const md = try PlainMonthDay.create(2, 29, .reject);
    try std.testing.expectEqual(@as(u8, 29), md.day());

    const allocator = std.testing.allocator;
    const s = try md.toIsoString(allocator, false);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("02-29", s);

    const parsed = try PlainMonthDay.parseIso(s);
    try std.testing.expect(PlainMonthDay.equals(md, parsed));
}

test "public API: withFields" {
    const md = try PlainMonthDay.create(2, 29, .reject);
    const md2 = try md.withFields(4, null, .reject);
    try std.testing.expectEqual(@as(u8, 4), md2.iso_month);
    try std.testing.expectEqual(@as(u8, 29), md2.iso_day);
}

test "public API: toPlainDate always constrains" {
    const md = try PlainMonthDay.create(2, 29, .reject);
    const d = try md.toPlainDate(2023);
    try std.testing.expect(PlainDate.equals(d, try PlainDate.create(2023, 2, 28, .reject)));
}

test "public API: constrain clamps to the 1972 (leap) calendar for every month" {
    const expected = [12]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    for (1..13) |m| {
        const md = try PlainMonthDay.create(@intCast(m), 32, .constrain);
        try std.testing.expectEqual(expected[m - 1], md.iso_day);
    }
}

test "public API: PlainDate.toPlainMonthDay always uses reference year 1972" {
    const d = try PlainDate.create(2024, 2, 29, .reject);
    const md = d.toPlainMonthDay();
    const allocator = std.testing.allocator;
    const s = try md.toIsoString(allocator, true);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("1972-02-29[u-ca=iso8601]", s);
}
