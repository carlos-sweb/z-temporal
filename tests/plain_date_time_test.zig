const std = @import("std");
const ztemporal = @import("ztemporal");
const PlainDateTime = ztemporal.PlainDateTime;
const PlainDate = ztemporal.PlainDate;
const PlainTime = ztemporal.PlainTime;
const Duration = ztemporal.Duration;

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
