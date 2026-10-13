const std = @import("std");
const ztemporal = @import("ztemporal");
const ZonedDateTime = ztemporal.ZonedDateTime;
const Disambiguation = ztemporal.Disambiguation;
const OffsetOption = ztemporal.OffsetOption;

const NY = "America/New_York";

test "public API: init, toString round-trip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const z = try ZonedDateTime.init(allocator, io, 1_710_055_800_000_000_000, NY, null);
    const s = try z.toString(allocator, io, .{ .offset = .auto, .timeZoneName = .auto, .calendarName = .never });
    defer allocator.free(s);
    try std.testing.expectEqualStrings("2024-03-10T03:30:00-04:00[America/New_York]", s);
}

test "public API: init, toString with calendar annotation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const z = try ZonedDateTime.init(allocator, io, 1_718_452_800_000_000_000, "UTC", null);
    const s = try z.toString(allocator, io, .{ .offset = .auto, .timeZoneName = .auto, .calendarName = .always });
    defer allocator.free(s);
    try std.testing.expectEqualStrings("2024-06-15T12:00:00+00:00[UTC][u-ca=iso8601]", s);
}

// DST gap: 2024-03-10T02:30 in America/New_York doesn't exist (spring
// forward 02:00 -> 03:00). Ground-truthed against real Node.
test "fromFields: DST gap x 4 disambiguation modes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const compatible = try ZonedDateTime.from(allocator, io, .{ .fields = .{ .year = 2024, .month = 3, .day = 10, .hour = 2, .minute = 30, .second = 0, .millisecond = 0, .microsecond = 0, .nanosecond = 0, .timeZone = NY } }, .{ .overflow = .constrain, .disambiguation = .compatible });
    try std.testing.expectEqual(@as(i128, 1_710_055_800_000_000_000), compatible.epochNs);

    const later = try ZonedDateTime.from(allocator, io, .{ .fields = .{ .year = 2024, .month = 3, .day = 10, .hour = 2, .minute = 30, .second = 0, .millisecond = 0, .microsecond = 0, .nanosecond = 0, .timeZone = NY } }, .{ .overflow = .constrain, .disambiguation = .later });
    try std.testing.expectEqual(@as(i128, 1_710_055_800_000_000_000), later.epochNs);

    const earlier = try ZonedDateTime.from(allocator, io, .{ .fields = .{ .year = 2024, .month = 3, .day = 10, .hour = 2, .minute = 30, .second = 0, .millisecond = 0, .microsecond = 0, .nanosecond = 0, .timeZone = NY } }, .{ .overflow = .constrain, .disambiguation = .earlier });
    try std.testing.expectEqual(@as(i128, 1_710_052_200_000_000_000), earlier.epochNs);

    try std.testing.expectError(error.RangeError, ZonedDateTime.from(allocator, io, .{ .fields = .{ .year = 2024, .month = 3, .day = 10, .hour = 2, .minute = 30, .second = 0, .millisecond = 0, .microsecond = 0, .nanosecond = 0, .timeZone = NY } }, .{ .overflow = .constrain, .disambiguation = .reject }));
}

// DST fold: 2024-11-03T01:30 in America/New_York happens twice (fall back
// 02:00 -> 01:00). Ground-truthed against real Node.
test "fromFields: DST fold x 4 disambiguation modes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const compatible = try ZonedDateTime.from(allocator, io, .{ .fields = .{ .year = 2024, .month = 11, .day = 3, .hour = 1, .minute = 30, .second = 0, .millisecond = 0, .microsecond = 0, .nanosecond = 0, .timeZone = NY } }, .{ .overflow = .constrain, .disambiguation = .compatible });
    try std.testing.expectEqual(@as(i128, 1_730_611_800_000_000_000), compatible.epochNs);

    const earlier = try ZonedDateTime.from(allocator, io, .{ .fields = .{ .year = 2024, .month = 11, .day = 3, .hour = 1, .minute = 30, .second = 0, .millisecond = 0, .microsecond = 0, .nanosecond = 0, .timeZone = NY } }, .{ .overflow = .constrain, .disambiguation = .earlier });
    try std.testing.expectEqual(@as(i128, 1_730_611_800_000_000_000), earlier.epochNs);

    const later = try ZonedDateTime.from(allocator, io, .{ .fields = .{ .year = 2024, .month = 11, .day = 3, .hour = 1, .minute = 30, .second = 0, .millisecond = 0, .microsecond = 0, .nanosecond = 0, .timeZone = NY } }, .{ .overflow = .constrain, .disambiguation = .later });
    try std.testing.expectEqual(@as(i128, 1_730_615_400_000_000_000), later.epochNs);

    try std.testing.expectError(error.RangeError, ZonedDateTime.from(allocator, io, .{ .fields = .{ .year = 2024, .month = 11, .day = 3, .hour = 1, .minute = 30, .second = 0, .millisecond = 0, .microsecond = 0, .nanosecond = 0, .timeZone = NY } }, .{ .overflow = .constrain, .disambiguation = .reject }));
}

// A normal time that merely falls within a day of a DST transition must
// NOT be treated as ambiguous -- ground-truthed all 4 modes agree.
test "fromFields: normal time near a transition is unambiguous under every mode" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    inline for (.{ .compatible, .earlier, .later, .reject }) |mode| {
        const z = try ZonedDateTime.from(allocator, io, .{ .fields = .{ .year = 2024, .month = 3, .day = 10, .hour = 5, .minute = 0, .second = 0, .millisecond = 0, .microsecond = 0, .nanosecond = 0, .timeZone = NY } }, .{ .overflow = .constrain, .disambiguation = mode });
        try std.testing.expectEqual(@as(i128, 1_710_061_200_000_000_000), z.epochNs);
    }
}

// Offset option matrix: string carries a deliberately wrong offset
// (America/New_York is -04:00 in June, string says -03:00).
test "fromString: offset option matrix with a wrong offset" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const text = "2024-06-15T12:00:00-03:00[America/New_York]";

    const used = try ZonedDateTime.from(allocator, io, .{ .string = text }, .{ .offset = .use, .disambiguation = .compatible });
    try std.testing.expectEqual(@as(i128, 1_718_463_600_000_000_000), used.epochNs);

    const preferred = try ZonedDateTime.from(allocator, io, .{ .string = text }, .{ .offset = .prefer, .disambiguation = .compatible });
    try std.testing.expectEqual(@as(i128, 1_718_467_200_000_000_000), preferred.epochNs);

    const ignored = try ZonedDateTime.from(allocator, io, .{ .string = text }, .{ .offset = .ignore, .disambiguation = .compatible });
    try std.testing.expectEqual(@as(i128, 1_718_467_200_000_000_000), ignored.epochNs);

    try std.testing.expectError(error.RangeError, ZonedDateTime.from(allocator, io, .{ .string = text }, .{ .offset = .reject, .disambiguation = .compatible }));
}

test "fromString: offset option with a correct offset always uses it" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const z = try ZonedDateTime.from(allocator, io, .{ .string = "2024-06-15T12:00:00-04:00[America/New_York]" }, .{ .offset = .use, .disambiguation = .compatible });
    try std.testing.expectEqual(@as(i128, 1_718_467_200_000_000_000), z.epochNs);
}

// `prefer` picks whichever fold candidate the given offset actually
// matches, rather than falling back to `.compatible`'s first-occurrence
// rule -- ground-truthed both fold offsets round-trip through `prefer`.
test "fromString: offset option .prefer picks the matching fold candidate" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const first = try ZonedDateTime.from(allocator, io, .{ .string = "2024-11-03T01:30:00-04:00[America/New_York]" }, .{ .offset = .prefer, .disambiguation = .compatible });
    try std.testing.expectEqual(@as(i128, 1_730_611_800_000_000_000), first.epochNs);

    const second = try ZonedDateTime.from(allocator, io, .{ .string = "2024-11-03T01:30:00-05:00[America/New_York]" }, .{ .offset = .prefer, .disambiguation = .compatible });
    try std.testing.expectEqual(@as(i128, 1_730_615_400_000_000_000), second.epochNs);
}

// `equals` additionally requires the same `timeZoneId` (and `calendarId`,
// always "iso8601" here); `compare` orders by instant only.
test "equals vs compare: same instant, different time zone" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const a = try ZonedDateTime.from(allocator, io, .{ .string = "2024-06-15T12:00:00-04:00[America/New_York]" }, .{ .offset = .reject, .disambiguation = .compatible });
    const b = try ZonedDateTime.init(allocator, io, a.epochNs, "UTC", null);

    try std.testing.expectEqual(std.math.Order.eq, ZonedDateTime.compare(a, b));
    try std.testing.expect(!ZonedDateTime.equals(a, b));
    try std.testing.expect(ZonedDateTime.equals(a, a));
}

test "hoursInDay: normal day is 24, DST transition days are 23/25" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const normal = try ZonedDateTime.from(allocator, io, .{ .string = "2024-06-15T00:00:00-04:00[America/New_York]" }, .{ .offset = .reject, .disambiguation = .compatible });
    try std.testing.expectApproxEqAbs(@as(f64, 24), try normal.hoursInDay(allocator, io), 1e-9);

    const spring = try ZonedDateTime.from(allocator, io, .{ .string = "2024-03-10T00:00:00-05:00[America/New_York]" }, .{ .offset = .reject, .disambiguation = .compatible });
    try std.testing.expectApproxEqAbs(@as(f64, 23), try spring.hoursInDay(allocator, io), 1e-9);

    const fall = try ZonedDateTime.from(allocator, io, .{ .string = "2024-11-03T00:00:00-04:00[America/New_York]" }, .{ .offset = .reject, .disambiguation = .compatible });
    try std.testing.expectApproxEqAbs(@as(f64, 25), try fall.hoursInDay(allocator, io), 1e-9);
}

test "startOfDay" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const mid = try ZonedDateTime.from(allocator, io, .{ .string = "2024-06-15T15:30:00-04:00[America/New_York]" }, .{ .offset = .reject, .disambiguation = .compatible });
    const start = try mid.startOfDay(allocator, io);
    try std.testing.expectEqual(@as(i128, 1_718_424_000_000_000_000), start.epochNs);
    const s = try start.toString(allocator, io, .{ .offset = .auto, .timeZoneName = .auto, .calendarName = .never });
    defer allocator.free(s);
    try std.testing.expectEqualStrings("2024-06-15T00:00:00-04:00[America/New_York]", s);
}

test "getTimeZoneTransition: next and previous" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const mid = try ZonedDateTime.from(allocator, io, .{ .string = "2024-06-15T15:30:00-04:00[America/New_York]" }, .{ .offset = .reject, .disambiguation = .compatible });

    const next = (try mid.getTimeZoneTransition(allocator, io, .next)).?;
    try std.testing.expectEqual(@as(i128, 1_730_613_600_000_000_000), next.epochNs);

    const previous = (try mid.getTimeZoneTransition(allocator, io, .previous)).?;
    try std.testing.expectEqual(@as(i128, 1_710_054_000_000_000_000), previous.epochNs);
}

// Real Temporal's ZonedDateTime genuinely supports non-ISO calendars (the
// getters would change meaning), so this repo rejects them explicitly
// instead of silently ignoring them like `Instant` does.
test "fromString: non-iso8601 calendar annotation is rejected" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expectError(error.RangeError, ZonedDateTime.from(allocator, io, .{ .string = "2024-06-15T12:00:00-04:00[America/New_York][u-ca=unknown]" }, .{ .offset = .reject, .disambiguation = .compatible }));

    const ok = try ZonedDateTime.from(allocator, io, .{ .string = "2024-06-15T12:00:00-04:00[America/New_York][u-ca=iso8601]" }, .{ .offset = .reject, .disambiguation = .compatible });
    try std.testing.expectEqual(@as(i128, 1_718_467_200_000_000_000), ok.epochNs);
}

test "fromString: missing time zone bracket is a format error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expectError(error.RangeError, ZonedDateTime.from(allocator, io, .{ .string = "2024-06-15T12:00:00-04:00" }, .{ .offset = .reject, .disambiguation = .compatible }));
}

test "init: invalid time zone id" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expectError(error.RangeError, ZonedDateTime.init(allocator, io, 0, "Not/A_Real_Zone", null));
}

test "toPlainDate/toPlainTime/toPlainDateTime getters" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const z = try ZonedDateTime.from(allocator, io, .{ .string = "2024-06-15T15:30:45.123456789-04:00[America/New_York]" }, .{ .offset = .reject, .disambiguation = .compatible });

    try std.testing.expectEqual(@as(i32, 2024), try z.year(allocator, io));
    try std.testing.expectEqual(@as(u8, 6), try z.month(allocator, io));
    try std.testing.expectEqual(@as(u8, 15), try z.day(allocator, io));
    try std.testing.expectEqual(@as(u8, 15), try z.hour(allocator, io));
    try std.testing.expectEqual(@as(u8, 30), try z.minute(allocator, io));
    try std.testing.expectEqual(@as(u8, 45), try z.second(allocator, io));
    try std.testing.expectEqual(@as(u16, 123), try z.millisecond(allocator, io));
    try std.testing.expectEqual(@as(u16, 456), try z.microsecond(allocator, io));
    try std.testing.expectEqual(@as(u16, 789), try z.nanosecond(allocator, io));

    const dt = try z.toPlainDateTime(allocator, io);
    try std.testing.expectEqual(@as(i32, 2024), dt.date.iso_year);
    try std.testing.expectEqual(@as(u8, 15), dt.time.hour);
}

test "toInstant is a pure projection" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const z = try ZonedDateTime.init(allocator, io, 1_718_467_200_000_000_000, NY, null);
    const instant = z.toInstant();
    try std.testing.expectEqual(@as(i128, 1_718_467_200_000_000_000), instant.epochNs);
}
