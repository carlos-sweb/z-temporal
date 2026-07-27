const std = @import("std");
const ztemporal = @import("ztemporal");
const ZonedDateTime = ztemporal.ZonedDateTime;
const Disambiguation = ztemporal.Disambiguation;
const OffsetOption = ztemporal.OffsetOption;

const NY = "America/New_York";

test "public API: create, toIsoString round-trip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const z = try ZonedDateTime.create(allocator, io, 1_710_055_800_000_000_000, NY);
    const s = try z.toIsoString(allocator, io, true, true, false);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("2024-03-10T03:30:00-04:00[America/New_York]", s);
}

test "public API: create, toIsoString with calendar annotation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const z = try ZonedDateTime.create(allocator, io, 1_718_452_800_000_000_000, "UTC");
    const s = try z.toIsoString(allocator, io, true, true, true);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("2024-06-15T12:00:00+00:00[UTC][u-ca=iso8601]", s);
}

// DST gap: 2024-03-10T02:30 in America/New_York doesn't exist (spring
// forward 02:00 -> 03:00). Ground-truthed against real Node.
test "fromFields: DST gap x 4 disambiguation modes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const compatible = try ZonedDateTime.fromFields(allocator, io, 2024, 3, 10, 2, 30, 0, 0, 0, 0, NY, .constrain, .compatible);
    try std.testing.expectEqual(@as(i128, 1_710_055_800_000_000_000), compatible.epoch_nanoseconds);

    const later = try ZonedDateTime.fromFields(allocator, io, 2024, 3, 10, 2, 30, 0, 0, 0, 0, NY, .constrain, .later);
    try std.testing.expectEqual(@as(i128, 1_710_055_800_000_000_000), later.epoch_nanoseconds);

    const earlier = try ZonedDateTime.fromFields(allocator, io, 2024, 3, 10, 2, 30, 0, 0, 0, 0, NY, .constrain, .earlier);
    try std.testing.expectEqual(@as(i128, 1_710_052_200_000_000_000), earlier.epoch_nanoseconds);

    try std.testing.expectError(error.AmbiguousTime, ZonedDateTime.fromFields(allocator, io, 2024, 3, 10, 2, 30, 0, 0, 0, 0, NY, .constrain, .reject));
}

// DST fold: 2024-11-03T01:30 in America/New_York happens twice (fall back
// 02:00 -> 01:00). Ground-truthed against real Node.
test "fromFields: DST fold x 4 disambiguation modes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const compatible = try ZonedDateTime.fromFields(allocator, io, 2024, 11, 3, 1, 30, 0, 0, 0, 0, NY, .constrain, .compatible);
    try std.testing.expectEqual(@as(i128, 1_730_611_800_000_000_000), compatible.epoch_nanoseconds);

    const earlier = try ZonedDateTime.fromFields(allocator, io, 2024, 11, 3, 1, 30, 0, 0, 0, 0, NY, .constrain, .earlier);
    try std.testing.expectEqual(@as(i128, 1_730_611_800_000_000_000), earlier.epoch_nanoseconds);

    const later = try ZonedDateTime.fromFields(allocator, io, 2024, 11, 3, 1, 30, 0, 0, 0, 0, NY, .constrain, .later);
    try std.testing.expectEqual(@as(i128, 1_730_615_400_000_000_000), later.epoch_nanoseconds);

    try std.testing.expectError(error.AmbiguousTime, ZonedDateTime.fromFields(allocator, io, 2024, 11, 3, 1, 30, 0, 0, 0, 0, NY, .constrain, .reject));
}

// A normal time that merely falls within a day of a DST transition must
// NOT be treated as ambiguous -- ground-truthed all 4 modes agree.
test "fromFields: normal time near a transition is unambiguous under every mode" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    inline for (.{ .compatible, .earlier, .later, .reject }) |mode| {
        const z = try ZonedDateTime.fromFields(allocator, io, 2024, 3, 10, 5, 0, 0, 0, 0, 0, NY, .constrain, mode);
        try std.testing.expectEqual(@as(i128, 1_710_061_200_000_000_000), z.epoch_nanoseconds);
    }
}

// Offset option matrix: string carries a deliberately wrong offset
// (America/New_York is -04:00 in June, string says -03:00).
test "parseIso: offset option matrix with a wrong offset" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const text = "2024-06-15T12:00:00-03:00[America/New_York]";

    const used = try ZonedDateTime.parseIso(allocator, io, text, .use, .compatible);
    try std.testing.expectEqual(@as(i128, 1_718_463_600_000_000_000), used.epoch_nanoseconds);

    const preferred = try ZonedDateTime.parseIso(allocator, io, text, .prefer, .compatible);
    try std.testing.expectEqual(@as(i128, 1_718_467_200_000_000_000), preferred.epoch_nanoseconds);

    const ignored = try ZonedDateTime.parseIso(allocator, io, text, .ignore, .compatible);
    try std.testing.expectEqual(@as(i128, 1_718_467_200_000_000_000), ignored.epoch_nanoseconds);

    try std.testing.expectError(error.AmbiguousTime, ZonedDateTime.parseIso(allocator, io, text, .reject, .compatible));
}

test "parseIso: offset option with a correct offset always uses it" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const z = try ZonedDateTime.parseIso(allocator, io, "2024-06-15T12:00:00-04:00[America/New_York]", .use, .compatible);
    try std.testing.expectEqual(@as(i128, 1_718_467_200_000_000_000), z.epoch_nanoseconds);
}

// `prefer` picks whichever fold candidate the given offset actually
// matches, rather than falling back to `.compatible`'s first-occurrence
// rule -- ground-truthed both fold offsets round-trip through `prefer`.
test "parseIso: offset option .prefer picks the matching fold candidate" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const first = try ZonedDateTime.parseIso(allocator, io, "2024-11-03T01:30:00-04:00[America/New_York]", .prefer, .compatible);
    try std.testing.expectEqual(@as(i128, 1_730_611_800_000_000_000), first.epoch_nanoseconds);

    const second = try ZonedDateTime.parseIso(allocator, io, "2024-11-03T01:30:00-05:00[America/New_York]", .prefer, .compatible);
    try std.testing.expectEqual(@as(i128, 1_730_615_400_000_000_000), second.epoch_nanoseconds);
}

// `equals` additionally requires the same `timeZoneId` (and `calendarId`,
// always "iso8601" here); `compare` orders by instant only.
test "equals vs compare: same instant, different time zone" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const a = try ZonedDateTime.parseIso(allocator, io, "2024-06-15T12:00:00-04:00[America/New_York]", .reject, .compatible);
    const b = try ZonedDateTime.create(allocator, io, a.epoch_nanoseconds, "UTC");

    try std.testing.expectEqual(std.math.Order.eq, ZonedDateTime.compare(a, b));
    try std.testing.expect(!ZonedDateTime.equals(a, b));
    try std.testing.expect(ZonedDateTime.equals(a, a));
}

test "hoursInDay: normal day is 24, DST transition days are 23/25" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const normal = try ZonedDateTime.parseIso(allocator, io, "2024-06-15T00:00:00-04:00[America/New_York]", .reject, .compatible);
    try std.testing.expectApproxEqAbs(@as(f64, 24), try normal.hoursInDay(allocator, io), 1e-9);

    const spring = try ZonedDateTime.parseIso(allocator, io, "2024-03-10T00:00:00-05:00[America/New_York]", .reject, .compatible);
    try std.testing.expectApproxEqAbs(@as(f64, 23), try spring.hoursInDay(allocator, io), 1e-9);

    const fall = try ZonedDateTime.parseIso(allocator, io, "2024-11-03T00:00:00-04:00[America/New_York]", .reject, .compatible);
    try std.testing.expectApproxEqAbs(@as(f64, 25), try fall.hoursInDay(allocator, io), 1e-9);
}

test "startOfDay" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const mid = try ZonedDateTime.parseIso(allocator, io, "2024-06-15T15:30:00-04:00[America/New_York]", .reject, .compatible);
    const start = try mid.startOfDay(allocator, io);
    try std.testing.expectEqual(@as(i128, 1_718_424_000_000_000_000), start.epoch_nanoseconds);
    const s = try start.toIsoString(allocator, io, true, true, false);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("2024-06-15T00:00:00-04:00[America/New_York]", s);
}

test "getTimeZoneTransition: next and previous" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const mid = try ZonedDateTime.parseIso(allocator, io, "2024-06-15T15:30:00-04:00[America/New_York]", .reject, .compatible);

    const next = (try mid.getTimeZoneTransition(allocator, io, .next)).?;
    try std.testing.expectEqual(@as(i128, 1_730_613_600_000_000_000), next.epoch_nanoseconds);

    const previous = (try mid.getTimeZoneTransition(allocator, io, .previous)).?;
    try std.testing.expectEqual(@as(i128, 1_710_054_000_000_000_000), previous.epoch_nanoseconds);
}

// Real Temporal's ZonedDateTime genuinely supports non-ISO calendars (the
// getters would change meaning), so this repo rejects them explicitly
// instead of silently ignoring them like `Instant` does.
test "parseIso: non-iso8601 calendar annotation is rejected" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expectError(error.InvalidFormat, ZonedDateTime.parseIso(allocator, io, "2024-06-15T12:00:00-04:00[America/New_York][u-ca=hebrew]", .reject, .compatible));

    const ok = try ZonedDateTime.parseIso(allocator, io, "2024-06-15T12:00:00-04:00[America/New_York][u-ca=iso8601]", .reject, .compatible);
    try std.testing.expectEqual(@as(i128, 1_718_467_200_000_000_000), ok.epoch_nanoseconds);
}

test "parseIso: missing time zone bracket is a format error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expectError(error.InvalidFormat, ZonedDateTime.parseIso(allocator, io, "2024-06-15T12:00:00-04:00", .reject, .compatible));
}

test "create: invalid time zone id" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expectError(error.InvalidTimeZone, ZonedDateTime.create(allocator, io, 0, "Not/A_Real_Zone"));
}

test "toPlainDate/toPlainTime/toPlainDateTime getters" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const z = try ZonedDateTime.parseIso(allocator, io, "2024-06-15T15:30:45.123456789-04:00[America/New_York]", .reject, .compatible);

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
    const z = try ZonedDateTime.create(allocator, io, 1_718_467_200_000_000_000, NY);
    const instant = z.toInstant();
    try std.testing.expectEqual(@as(i128, 1_718_467_200_000_000_000), instant.epoch_nanoseconds);
}
