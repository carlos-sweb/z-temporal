const std = @import("std");
const t = @import("ztemporal");
const allocator = std.testing.allocator;
const io = std.testing.io;
fn expectString(comptime T: type, value: T, expected: []const u8) !void {
    const text = try value.toString(allocator, .{});
    defer allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}
test "canonical from, constructor, with and missing-field error names" {
    const date = try t.PlainDate.from(.{ .fields = .{ .year = 2024, .monthCode = "M02", .day = 29 } }, .{});
    try expectString(t.PlainDate, date, "2024-02-29");
    try std.testing.expectError(error.RangeError, t.PlainDate.init(2023, 2, 29, null));
    try std.testing.expectError(error.TypeError, t.PlainDate.from(.{ .fields = .{ .month = 2, .day = 1 } }, .{}));
    try std.testing.expectError(error.TypeError, date.with(.{}, .{}));
    try std.testing.expectError(error.RangeError, date.with(.{ .month = 3, .monthCode = "M02" }, .{}));
    const dt = try date.toPlainDateTime(try t.PlainTime.init(12, 34, 56, 0, 0, 0));
    try std.testing.expectEqual(@as(u8, 12), dt.hour());
    try std.testing.expectEqual(@as(?i32, 2024), dt.yearOfWeek());
    const changed = try dt.with(.{ .hour = 9 }, .{});
    try std.testing.expectEqual(@as(u8, 9), changed.hour());
    try expectString(t.PlainDateTime, try dt.withPlainTime(null), "2024-02-29T00:00:00");
    const ym = try dt.toPlainYearMonth();
    try expectString(t.PlainYearMonth, ym, "2024-02");
    const md = try dt.toPlainMonthDay();
    try expectString(t.PlainMonthDay, md, "02-29");
}
test "constructor reference dates differ from from normalization" {
    const a = try t.PlainYearMonth.init(2024, 2, null, 15);
    const b = try t.PlainYearMonth.from(.{ .string = "2024-02-15" }, .{});
    try std.testing.expect(!t.PlainYearMonth.equals(a, b));
    const text = try a.toString(allocator, .{ .calendarName = .always });
    defer allocator.free(text);
    try std.testing.expectEqualStrings("2024-02-15[u-ca=iso8601]", text);
    const c = try t.PlainMonthDay.init(2, 29, null, 2000);
    const d = try t.PlainMonthDay.from(.{ .string = "2000-02-29" }, .{});
    try std.testing.expect(!t.PlainMonthDay.equals(c, d));
    const ym = try t.PlainYearMonth.from(.{ .string = "2024-01" }, .{});
    try std.testing.expectError(error.RangeError, ym.add(.{ .days = -1 }, .constrain));
    try std.testing.expectError(error.RangeError, ym.add(.{ .days = -35 }, .constrain));
}
test "grammar: basic forms, leap seconds, critical annotations and fractional precision" {
    try expectString(t.PlainTime, try t.PlainTime.from(.{ .string = "12" }, .{}), "12:00:00");
    try expectString(t.PlainTime, try t.PlainTime.from(.{ .string = "T0102" }, .{}), "01:02:00");
    try expectString(t.PlainTime, try t.PlainTime.from(.{ .string = "12:00:60" }, .{}), "12:00:59");
    try std.testing.expectError(error.RangeError, t.PlainTime.from(.{ .string = "0102" }, .{}));
    try std.testing.expectError(error.RangeError, t.PlainTime.from(.{ .string = "12:00:00.1234567890" }, .{}));
    try std.testing.expectError(error.RangeError, t.Instant.from(.{ .string = "2024-01-01T00:00Z[!foo=bar]" }));
    try std.testing.expectError(error.RangeError, t.PlainYearMonth.from(.{ .string = "2024-02-30" }, .{}));
    try std.testing.expectError(error.RangeError, t.PlainMonthDay.from(.{ .string = "02-29T12:00" }, .{}));
}
test "Number rounding, negative zero and invalid numeric fields" {
    const large = try t.Duration.init(0, 0, 0, 0, 0, 0, 0, 0, 0, @as(i128, 9_007_199_254_740_993));
    try std.testing.expectEqual(@as(f64, 9_007_199_254_740_992), large.nanoseconds);
    try expectString(t.Duration, large, "PT9007199.254740992S");
    try std.testing.expect(!std.math.signbit(large.negated().years));
    try std.testing.expectError(error.RangeError, t.Duration.from(.{ .fields = .{ .hours = 1.5 } }));
    try std.testing.expectError(error.RangeError, t.Duration.from(.{ .fields = .{ .seconds = std.math.nan(f64) } }));
    try std.testing.expectError(error.TypeError, t.Duration.from(.{ .fields = .{} }));
    try std.testing.expectError(error.TypeError, large.with(.{}));
    const corrupt = t.Duration{ .hours = std.math.inf(f64) };
    try std.testing.expectError(error.RangeError, corrupt.total(.{ .unit = .hour }));
    const text = try (t.Duration{ .hours = 2 }).toString(allocator, .{ .fractionalSecondDigits = 3 });
    defer allocator.free(text);
    try std.testing.expectEqualStrings("PT2H0.000S", text);
}
test "DST calendar days, fixed zones, aliases, with and relativeTo" {
    const a = try t.ZonedDateTime.from(allocator, io, .{ .string = "2024-03-09T12:00[America/New_York]" }, .{});
    const day = try a.add(allocator, io, .{ .days = 1 }, .constrain);
    const hours = try a.add(allocator, io, .{ .hours = 24 }, .constrain);
    try std.testing.expectEqual(@as(u8, 12), try day.hour(allocator, io));
    try std.testing.expectEqual(@as(u8, 13), try hours.hour(allocator, io));
    try std.testing.expectEqual(@as(f64, 23), try (t.Duration{ .days = 1 }).total(.{ .relativeTo = .{ .zonedDateTime = a }, .unit = .hour, .allocator = allocator, .io = io }));
    try std.testing.expectEqual(std.math.Order.lt, try t.Duration.compare(.{ .days = 1 }, .{ .hours = 24 }, .{ .relativeTo = .{ .zonedDateTime = a }, .allocator = allocator, .io = io }));
    const r = try (t.Duration{ .days = 1 }).round(.{ .relativeTo = .{ .zonedDateTime = a }, .largestUnit = .hour, .allocator = allocator, .io = io });
    try std.testing.expectEqual(@as(f64, 23), r.hours);
    const utc = try t.ZonedDateTime.init(allocator, io, 0, "utc", null);
    const alias = try t.ZonedDateTime.init(allocator, io, 0, "Etc/UTC", null);
    try std.testing.expect(t.ZonedDateTime.equals(utc, alias));
    try std.testing.expectEqualStrings("Etc/UTC", alias.timeZoneId());
    const fixed = try t.ZonedDateTime.init(allocator, io, 0, "+0530", null);
    try std.testing.expectEqualStrings("+05:30", fixed.timeZoneId());
    const named = try t.ZonedDateTime.init(allocator, io, 0, "america/new_york", null);
    try std.testing.expectEqualStrings("America/New_York", named.timeZoneId());
    try std.testing.expectError(error.TypeError, a.with(allocator, io, .{}, .{}));
    const updated = try a.with(allocator, io, .{ .hour = 9 }, .{});
    try std.testing.expectEqual(@as(u8, 9), try updated.hour(allocator, io));
    _ = try a.withPlainTime(allocator, io, null);
    _ = try a.withTimeZone(allocator, io, "UTC");
    _ = try a.withCalendar("iso8601");
    const offset = try a.offset(allocator, io);
    defer allocator.free(offset);
    try std.testing.expectEqualStrings("-05:00", offset);
    _ = try a.dayOfYear(allocator, io);
    var month_code_buf: [4]u8 = undefined;
    _ = try a.monthCode(allocator, io, &month_code_buf);
    _ = try a.era(allocator, io);
}
test "format rounding options and JSON defaults" {
    const value = try t.PlainDateTime.from(.{ .string = "2024-12-31T23:59:59.999999999" }, .{});
    const text = try value.toString(allocator, .{ .fractionalSecondDigits = 0, .roundingMode = .ceil });
    defer allocator.free(text);
    try std.testing.expectEqualStrings("2025-01-01T00:00:00", text);
    try std.testing.expectError(error.RangeError, value.round(.{ .smallestUnit = .day, .roundingIncrement = 2 }));
    const json = try value.toJSON(allocator);
    defer allocator.free(json);
    try std.testing.expectEqualStrings("2024-12-31T23:59:59.999999999", json);
    const i = try t.Instant.init(0);
    const local = try i.toString(allocator, .{ .timeZone = "+05:30", .io = io, .smallestUnit = .minute });
    defer allocator.free(local);
    try std.testing.expectEqualStrings("1970-01-01T05:30+05:30", local);
}
test "future transitions and exact previous-transition boundary" {
    const value = try t.ZonedDateTime.from(allocator, io, .{ .string = "2100-01-01T00:00[America/New_York]" }, .{});
    const next = (try value.getTimeZoneTransition(allocator, io, .next)).?;
    try std.testing.expectEqual(@as(i32, 2100), try next.year(allocator, io));
    try std.testing.expectEqual(@as(u8, 3), try next.month(allocator, io));
    const previous = try next.getTimeZoneTransition(allocator, io, .previous);
    try std.testing.expect(previous == null or previous.?.epochNs < next.epochNs);
    const after = try next.add(allocator, io, .{ .nanoseconds = 1 }, .constrain);
    const back = (try after.getTimeZoneTransition(allocator, io, .previous)).?;
    try std.testing.expectEqual(next.epochNs, back.epochNs);
}
test "optional ICU calendars, eras, leap months and localization" {
    if (!t.intlEnabled) {
        try std.testing.expectError(error.RangeError, t.PlainDate.from(.{ .string = "2024-02-29[u-ca=hebrew]" }, .{}));
        return;
    }
    const constructor = try t.PlainDate.init(2024, 2, 29, "hebrew");
    try std.testing.expectEqual(@as(i32, 5784), constructor.year());
    const constructorYM = try t.PlainYearMonth.init(2024, 2, "hebrew", 15);
    try std.testing.expectEqual(@as(i32, 5784), constructorYM.year());
    const constructorMD = try t.PlainMonthDay.init(2, 29, "hebrew", 2024);
    try std.testing.expectEqual(@as(u8, 20), constructorMD.day());
    const value = try t.PlainDate.from(.{ .string = "2024-02-29[u-ca=hebrew]" }, .{});
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(i32, 5784), value.year());
    try std.testing.expectEqualStrings("M05L", value.monthCode(&buf));
    const era = try t.PlainDate.from(.{ .fields = .{ .calendar = "japanese", .era = "reiwa", .eraYear = 6, .month = 2, .day = 29 } }, .{});
    try std.testing.expectEqual(@as(i32, 2024), era.iso_year);
    const aa = try t.PlainDate.from(.{ .fields = .{ .calendar = "ethiopic", .era = "aa", .eraYear = 7516, .month = 6, .day = 21 } }, .{});
    const am = try t.PlainDate.from(.{ .string = "2024-02-29[u-ca=ethiopic]" }, .{});
    try std.testing.expect(t.PlainDate.equals(aa, am));
    const next = try value.add(.{ .years = 1 }, .constrain);
    try std.testing.expectEqual(@as(i32, 5785), next.year());
    const md = try t.PlainMonthDay.from(.{ .fields = .{ .calendar = "hebrew", .monthCode = "M05L", .day = 20 } }, .{});
    try expectString(t.PlainMonthDay, md, "1970-02-26[u-ca=hebrew]");
    const translated = try value.toLocaleString(allocator, io, "en-US", .{ .calendar = "hebrew" });
    defer allocator.free(translated);
    try std.testing.expect(translated.len > 0);
    try std.testing.expectError(error.RangeError, value.toLocaleString(allocator, io, "en-US", .{}));
    const d = try t.Duration.from(.{ .string = "P1DT2H30M" });
    const label = try d.toLocaleString(allocator, "es-CL", .{ .style = .long });
    defer allocator.free(label);
    try std.testing.expectEqualStrings("1 día, 2 horas y 30 minutos", label);
}

test "Now uses a controllable std.Io clock" {
    const Fake = struct {
        fn now(_: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
            std.debug.assert(clock == .real);
            return .{ .nanoseconds = 1_704_067_200_123_456_789 };
        }
    };
    var vtable = io.vtable.*;
    vtable.now = Fake.now;
    const controlled: std.Io = .{ .userdata = null, .vtable = &vtable };
    try std.testing.expectEqual(@as(i128, 1_704_067_200_123_456_789), t.Now.instant(controlled).epochNanoseconds());
}
