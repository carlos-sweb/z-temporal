const std = @import("std");
const ztemporal = @import("ztemporal");
const iso_calendar = ztemporal.iso_calendar;

test "public API: leap years, days-in-month, epoch-day round-trip" {
    try std.testing.expect(iso_calendar.isLeapYear(2024));
    try std.testing.expect(!iso_calendar.isLeapYear(1900));
    try std.testing.expectEqual(@as(u8, 29), iso_calendar.daysInMonth(2024, 2));
    try std.testing.expectEqual(@as(u8, 28), iso_calendar.daysInMonth(2023, 2));

    const ed = iso_calendar.toEpochDay(2024, 2, 29);
    const back = iso_calendar.fromEpochDay(ed);
    try std.testing.expectEqual(@as(i32, 2024), back.year);
    try std.testing.expectEqual(@as(u8, 2), back.month);
    try std.testing.expectEqual(@as(u8, 29), back.day);
}

test "public API: dayOfWeek is Temporal's 1=Monday..7=Sunday numbering" {
    try std.testing.expectEqual(@as(u8, 4), iso_calendar.dayOfWeek(1970, 1, 1));
}

test "public API: weekOfYear year-boundary redirect" {
    const w = iso_calendar.weekOfYear(2024, 12, 31);
    try std.testing.expectEqual(@as(u8, 1), w.week);
    try std.testing.expectEqual(@as(i32, 2025), w.year);
}
