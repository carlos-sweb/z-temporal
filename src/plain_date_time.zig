//! Temporal.PlainDateTime: calendar-aware local dates and times.
const std = @import("std");
const iso_string = @import("iso_string.zig");
const iso_calendar = @import("iso_calendar.zig");
const errors = @import("errors.zig");
const TemporalError = errors.TemporalError;
const plain_date = @import("plain_date.zig");
const plain_time = @import("plain_time.zig");
const Duration = @import("duration.zig").Duration;
const rounding = @import("rounding.zig");
const RoundingOptions = rounding.RoundingOptions;

pub const PlainDate = plain_date.PlainDate;
pub const PlainTime = plain_time.PlainTime;
pub const Overflow = plain_date.Overflow;

const NS_PER_DAY: i128 = 86_400_000_000_000;

/// `until`/`since`'s shared engine. Two fundamentally different shapes
/// depending on `resolved.largest`, both ground-truthed against real Node:
/// a *time* `largestUnit` flattens the whole interval into one signed
/// nanosecond total (date part folded in via epoch days) and decomposes
/// from there -- no date-balance step at all. A *date* `largestUnit`
/// instead borrows the sub-day time-of-day difference into a whole-day
/// carry (floor, matching Phase 3a's `add`'s convention) to get a
/// date-only adjusted endpoint, then reuses `PlainDate`'s
/// `diffISODate`/`roundDateDiff` on that pair, attaching the canonical
/// `[0,24h)` time remainder.
fn diffDateTime(self: PlainDateTime, other: PlainDateTime, resolved: rounding.ResolvedUnits, increment: u32, mode: rounding.RoundingMode, negate: bool) TemporalError!Duration {
    const rel = @import("relative.zig");
    const origin = try rel.epoch(self, .{});
    const target = try rel.epoch(other, .{});
    const d = try rel.difference(self, other, origin, target, .{ .largestUnit = resolved.largest, .smallestUnit = resolved.smallest, .roundingIncrement = increment, .roundingMode = if (negate) rel.negateMode(mode) else mode }, .{});
    return if (negate) d.negated() else d;
}

pub fn regulate(year_value: i32, month_value: i32, day_value: i32, hour_value: i32, minute_value: i32, second_value: i32, millisecond_value: i32, microsecond_value: i32, nanosecond_value: i32, overflow: Overflow) TemporalError!PlainDateTime {
    const d = try @import("plain_date.zig").regulate(year_value, month_value, day_value, overflow);
    const t = try @import("plain_time.zig").regulate(hour_value, minute_value, second_value, millisecond_value, microsecond_value, nanosecond_value, overflow);
    const result: PlainDateTime = .{ .date = d, .time = t };
    try result.validate();
    return result;
}

pub const PlainDateTime = struct {
    date: PlainDate,
    time: PlainTime = .{},

    pub fn validate(self: PlainDateTime) TemporalError!void {
        const epoch = @as(i128, iso_calendar.toEpochDay(self.date.iso_year, self.date.iso_month, self.date.iso_day)) * NS_PER_DAY + self.time.totalNanoseconds();
        const bound: @TypeOf(epoch) = 100_000_001 * NS_PER_DAY;
        if (epoch <= -bound or epoch >= bound) return error.RangeError;
    }
    fn finish(value: PlainDateTime) TemporalError!PlainDateTime {
        try value.validate();
        return value;
    }
    pub fn init(in_year: i32, in_month: i32, in_day: i32, in_hour: i32, in_minute: i32, in_second: i32, in_millisecond: i32, in_microsecond: i32, in_nanosecond: i32, calendarIdValue: ?[]const u8) TemporalError!PlainDateTime {
        return (try regulate(in_year, in_month, in_day, in_hour, in_minute, in_second, in_millisecond, in_microsecond, in_nanosecond, .reject)).withCalendar(calendarIdValue orelse "iso8601");
    }

    pub const Fields = struct {
        era: ?[]const u8 = null,
        eraYear: ?i32 = null,
        calendar: ?[]const u8 = null,
        monthCode: ?[]const u8 = null,
        year: ?i32 = null,
        month: ?i32 = null,
        day: ?i32 = null,
        hour: ?i32 = null,
        minute: ?i32 = null,
        second: ?i32 = null,
        millisecond: ?i32 = null,
        microsecond: ?i32 = null,
        nanosecond: ?i32 = null,
    };
    pub const FromInput = union(enum) { string: []const u8, value: PlainDateTime, fields: Fields };
    pub const FromOptions = struct { overflow: Overflow = .constrain };
    pub fn from(input: FromInput, options: FromOptions) TemporalError!PlainDateTime {
        return switch (input) {
            .string => |text| fromString(text),
            .value => |value| value,
            .fields => |f| finish(.{
                .date = try PlainDate.from(.{ .fields = .{ .year = f.year, .era = f.era, .eraYear = f.eraYear, .month = f.month, .monthCode = f.monthCode, .day = f.day, .calendar = f.calendar } }, .{ .overflow = options.overflow }),
                .time = try @import("plain_time.zig").regulate(f.hour orelse 0, f.minute orelse 0, f.second orelse 0, f.millisecond orelse 0, f.microsecond orelse 0, f.nanosecond orelse 0, options.overflow),
            }),
        };
    }

    fn fromString(text: []const u8) TemporalError!PlainDateTime {
        const parsed = try iso_string.parsePlainDateTime(text);
        const d = try (try PlainDate.init(parsed.date.year, parsed.date.month, parsed.date.day, null)).withCalendar(@tagName(try @import("calendar.zig").fromString(text)));
        return finish(.{ .date = d, .time = .{
            .hour = parsed.time.hour,
            .minute = parsed.time.minute,
            .second = parsed.time.second,
            .millisecond = parsed.time.millisecond,
            .microsecond = parsed.time.microsecond,
            .nanosecond = parsed.time.nanosecond,
        } });
    }

    pub fn with(self: PlainDateTime, fields: Fields, options: FromOptions) TemporalError!PlainDateTime {
        if (fields.calendar != null) return error.TypeError;
        const date_fields = (self.date.calendar != .iso8601 and (fields.era != null or fields.eraYear != null)) or fields.year != null or fields.month != null or fields.monthCode != null or fields.day != null;
        const time_fields = fields.hour != null or fields.minute != null or fields.second != null or fields.millisecond != null or fields.microsecond != null or fields.nanosecond != null;
        if (!date_fields and !time_fields) return error.TypeError;
        return finish(.{ .date = if (date_fields) try self.date.with(.{ .year = fields.year, .era = fields.era, .eraYear = fields.eraYear, .month = fields.month, .monthCode = fields.monthCode, .day = fields.day }, .{ .overflow = options.overflow }) else self.date, .time = if (time_fields) try self.time.with(.{ .hour = fields.hour, .minute = fields.minute, .second = fields.second, .millisecond = fields.millisecond, .microsecond = fields.microsecond, .nanosecond = fields.nanosecond }, .{ .overflow = options.overflow }) else self.time });
    }

    /// Combines `PlainDate.addISODate` (years/months, `overflow` clamp/
    /// reject) with a floored time-of-day wraparound (unlike
    /// `PlainDate.add`'s truncation -- there's an existing time-of-day
    /// here that must land in canonical `[0,24h)`, ground-truthed:
    /// `PlainDateTime(...,0,0).add({hours:-23})` carries the date back
    /// one day and leaves `01:00:00`, which only floored division
    /// produces). `d.weeks`/`.days`/time-part all fold into one epoch-day
    /// step alongside the day-carry from the wraparound.
    pub fn add(self: PlainDateTime, d: Duration, overflow: Overflow) TemporalError!PlainDateTime {
        try @import("duration.zig").validate(d);
        const combined: i128 = @as(i128, self.time.totalNanoseconds()) + d.totalTimeNanoseconds();
        const day_carry: i64 = @intCast(@divFloor(combined, NS_PER_DAY));
        const ns_of_day: u64 = @intCast(@mod(combined, NS_PER_DAY));

        const stepped_date = try self.date.add(.{ .years = d.years, .months = d.months }, overflow);
        const stepped = stepped_date.asYMD();
        const epoch_day = iso_calendar.toEpochDay(stepped.year, stepped.month, stepped.day) + @as(i64, @intCast(@import("duration.zig").integer(d.weeks))) * 7 + day_carry;
        const ymd = iso_calendar.fromEpochDay(epoch_day);
        if (!iso_calendar.isInRange(ymd.year, ymd.month, ymd.day)) return error.RangeError;
        return finish(.{
            .date = try (try PlainDate.init(ymd.year, ymd.month, ymd.day, null)).withCalendar(@tagName(self.date.calendar)),
            .time = PlainTime.fromNanosecondsOfDay(ns_of_day),
        });
    }

    pub fn subtract(self: PlainDateTime, d: Duration, overflow: Overflow) TemporalError!PlainDateTime {
        return self.add(d.negated(), overflow);
    }

    pub fn until(self: PlainDateTime, other: PlainDateTime, options: RoundingOptions) TemporalError!Duration {
        if (!@import("calendar.zig").equal(self.date.calendar, other.date.calendar)) return error.RangeError;
        const resolved = try rounding.resolveDateTimeUnits(options);
        return diffDateTime(self, other, resolved, options.roundingIncrement, options.roundingMode, false);
    }

    pub fn since(self: PlainDateTime, other: PlainDateTime, options: RoundingOptions) TemporalError!Duration {
        if (!@import("calendar.zig").equal(self.date.calendar, other.date.calendar)) return error.RangeError;
        const resolved = try rounding.resolveDateTimeUnits(options);
        return diffDateTime(self, other, resolved, options.roundingIncrement, options.roundingMode, true);
    }

    /// Rounds to `options.smallestUnit` (required; restricted to time
    /// units plus `.day` -- ground-truthed that real Temporal rejects
    /// week/month/year here, unlike `until`/`since`). `.day` uses noon as
    /// the tie point (fixed `NS_PER_DAY` denominator); any unit carries
    /// the date forward one day on overflow, reusing the same epoch-day
    /// shift `diffDateTime`'s date/time borrow already establishes.
    pub fn round(self: PlainDateTime, options: rounding.RoundOptions) TemporalError!PlainDateTime {
        const smallest = options.smallestUnit orelse return error.RangeError;
        if (!rounding.isTimeUnitOrDay(smallest) or (smallest == .day and options.roundingIncrement != 1)) return error.RangeError;
        try rounding.validateIncrement(smallest, options.roundingIncrement);

        const smallest_ns: i128 = if (smallest == .day) NS_PER_DAY else plain_time.nsPerUnit(smallest);
        const rounded_units = rounding.roundRatioToIncrement(self.time.totalNanoseconds(), smallest_ns, options.roundingIncrement, options.roundingMode);
        var rounded_ns: i128 = rounded_units * smallest_ns;

        var day_carry: i64 = 0;
        if (rounded_ns >= NS_PER_DAY) {
            day_carry = 1;
            rounded_ns -= NS_PER_DAY;
        }
        const ns_of_day: u64 = @intCast(rounded_ns);

        const epoch_day = iso_calendar.toEpochDay(self.date.iso_year, self.date.iso_month, self.date.iso_day) + day_carry;
        const ymd = iso_calendar.fromEpochDay(epoch_day);
        if (!iso_calendar.isInRange(ymd.year, ymd.month, ymd.day)) return error.RangeError;
        return finish(.{
            .date = try (try PlainDate.init(ymd.year, ymd.month, ymd.day, null)).withCalendar(@tagName(self.date.calendar)),
            .time = PlainTime.fromNanosecondsOfDay(ns_of_day),
        });
    }

    pub fn withPlainTime(self: PlainDateTime, plainTime: ?PlainTime) TemporalError!PlainDateTime {
        return finish(.{ .date = self.date, .time = plainTime orelse .{} });
    }
    pub fn withCalendar(self: PlainDateTime, id: []const u8) TemporalError!PlainDateTime {
        return .{ .date = try self.date.withCalendar(id), .time = self.time };
    }
    pub fn toPlainYearMonth(self: PlainDateTime) TemporalError!@import("plain_year_month.zig").PlainYearMonth {
        return self.date.toPlainYearMonth();
    }
    pub fn toPlainMonthDay(self: PlainDateTime) TemporalError!@import("plain_month_day.zig").PlainMonthDay {
        return self.date.toPlainMonthDay();
    }
    pub fn toZonedDateTime(self: PlainDateTime, allocator: std.mem.Allocator, io: std.Io, timeZone: []const u8, disambiguation: @import("zoned_date_time.zig").Disambiguation) TemporalError!@import("zoned_date_time.zig").ZonedDateTime {
        return (try @import("zoned_date_time.zig").resolveFields(allocator, io, self.date.iso_year, self.date.iso_month, self.date.iso_day, self.time.hour, self.time.minute, self.time.second, self.time.millisecond, self.time.microsecond, self.time.nanosecond, timeZone, .reject, disambiguation)).withCalendar(@tagName(self.date.calendar));
    }
    pub fn year(self: PlainDateTime) i32 {
        return self.date.year();
    }
    pub fn month(self: PlainDateTime) u8 {
        return self.date.month();
    }
    pub fn day(self: PlainDateTime) u8 {
        return self.date.day();
    }
    pub fn dayOfWeek(self: PlainDateTime) u8 {
        return self.date.dayOfWeek();
    }
    pub fn dayOfYear(self: PlainDateTime) u16 {
        return self.date.dayOfYear();
    }
    pub fn daysInMonth(self: PlainDateTime) u8 {
        return self.date.daysInMonth();
    }
    pub fn daysInYear(self: PlainDateTime) u16 {
        return self.date.daysInYear();
    }
    pub fn monthsInYear(self: PlainDateTime) u8 {
        return self.date.monthsInYear();
    }
    pub fn inLeapYear(self: PlainDateTime) bool {
        return self.date.inLeapYear();
    }
    pub fn weekOfYear(self: PlainDateTime) ?u8 {
        return self.date.weekOfYear();
    }
    pub fn yearOfWeek(self: PlainDateTime) ?i32 {
        return self.date.yearOfWeek();
    }
    pub fn daysInWeek(self: PlainDateTime) u8 {
        return self.date.daysInWeek();
    }
    pub fn era(self: PlainDateTime) ?[]const u8 {
        return self.date.era();
    }
    pub fn eraYear(self: PlainDateTime) ?i32 {
        return self.date.eraYear();
    }
    pub fn hour(self: PlainDateTime) u8 {
        return self.time.hour;
    }
    pub fn minute(self: PlainDateTime) u8 {
        return self.time.minute;
    }
    pub fn second(self: PlainDateTime) u8 {
        return self.time.second;
    }
    pub fn millisecond(self: PlainDateTime) u16 {
        return self.time.millisecond;
    }
    pub fn microsecond(self: PlainDateTime) u16 {
        return self.time.microsecond;
    }
    pub fn nanosecond(self: PlainDateTime) u16 {
        return self.time.nanosecond;
    }
    pub fn monthCode(self: PlainDateTime, buf: *[4]u8) []const u8 {
        return self.date.monthCode(buf);
    }
    pub fn toPlainDate(self: PlainDateTime) PlainDate {
        return self.date;
    }
    pub fn toPlainTime(self: PlainDateTime) PlainTime {
        return self.time;
    }
    pub fn calendarId(self: PlainDateTime) []const u8 {
        return self.date.calendarId();
    }

    pub fn compare(a: PlainDateTime, b: PlainDateTime) std.math.Order {
        const date_order = PlainDate.compare(a.date, b.date);
        if (date_order != .eq) return date_order;
        return PlainTime.compare(a.time, b.time);
    }

    pub fn equals(a: PlainDateTime, b: PlainDateTime) bool {
        return PlainDate.equals(a.date, b.date) and PlainTime.equals(a.time, b.time);
    }

    /// `YYYY-MM-DDTHH:MM:SS[.fraction]`, time part always shown (even at
    /// exact midnight -- matches real Node: `2024-01-01T00:00:00`, not a
    /// bare date).
    pub fn toLocaleString(self: PlainDateTime, allocator: std.mem.Allocator, io: std.Io, locales: ?[]const u8, options: @import("locale.zig").LocaleOptions) TemporalError![]u8 {
        return @import("locale.zig").format(allocator, io, .dateTime, @as(f64, @floatFromInt(@divFloor(try @import("relative.zig").epoch(self, .{}), 1_000_000))), self.date.calendar, null, locales, options);
    }
    pub fn toString(self: PlainDateTime, allocator: std.mem.Allocator, options: StringOptions) TemporalError![]u8 {
        const fmt = @import("format_options.zig");
        const p = try fmt.precision(options);
        const value = try self.round(.{ .smallestUnit = p.unit, .roundingIncrement = p.increment, .roundingMode = options.roundingMode });
        const raw = try value.formatDefault(allocator, options.calendarName == .always or options.calendarName == .critical or (options.calendarName == .auto and self.date.calendar != .iso8601));
        defer allocator.free(raw);
        const timed = try fmt.time(allocator, raw, p);
        defer allocator.free(timed);
        return fmt.calendar(allocator, timed, options.calendarName == .critical);
    }
    pub fn toJSON(self: PlainDateTime, allocator: std.mem.Allocator) TemporalError![]u8 {
        return self.toString(allocator, .{});
    }
    pub const StringOptions = @import("format_options.zig").StringOptions;
    fn formatDefault(self: PlainDateTime, allocator: std.mem.Allocator, show_calendar: bool) ![]u8 {
        var year_buf: [8]u8 = undefined;
        const year_str = iso_string.formatYear(&year_buf, self.date.iso_year);
        var frac_buf: [10]u8 = undefined;
        const frac = iso_string.formatFractionalSeconds(&frac_buf, self.time.millisecond, self.time.microsecond, self.time.nanosecond);
        if (show_calendar) {
            return allocator.print("{s}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{s}[u-ca={s}]", .{
                year_str, self.date.iso_month, self.date.iso_day, self.time.hour, self.time.minute, self.time.second, frac, self.calendarId(),
            });
        }
        return allocator.print("{s}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{s}", .{
            year_str, self.date.iso_month, self.date.iso_day, self.time.hour, self.time.minute, self.time.second, frac,
        });
    }
};

test "init combines PlainDate + PlainTime overflow rules" {
    const c = try @import("plain_date_time.zig").regulate(2024, 2, 30, 25, 0, 0, 0, 0, 0, .constrain);
    try std.testing.expectEqual(@as(u8, 29), c.date.iso_day);
    try std.testing.expectEqual(@as(u8, 23), c.time.hour);
    try std.testing.expectError(error.RangeError, @import("plain_date_time.zig").regulate(2024, 0, 1, 0, 0, 0, 0, 0, 0, .constrain));
}

test "toPlainDate/toPlainTime" {
    const dt = try PlainDateTime.init(2024, 2, 29, 1, 2, 3, 4, 5, 6, null);
    try std.testing.expect(PlainDate.equals(dt.toPlainDate(), try PlainDate.init(2024, 2, 29, null)));
    try std.testing.expect(PlainTime.equals(dt.toPlainTime(), try PlainTime.init(1, 2, 3, 4, 5, 6)));
}

test "compare" {
    const a = try PlainDateTime.init(2024, 1, 1, 0, 0, 0, 0, 0, 0, null);
    const b = try PlainDateTime.init(2024, 1, 2, 0, 0, 0, 0, 0, 0, null);
    try std.testing.expectEqual(std.math.Order.lt, PlainDateTime.compare(a, b));
}

test "toString matches real Node byte-for-byte" {
    const allocator = std.testing.allocator;
    {
        const dt = try PlainDateTime.init(2024, 2, 29, 1, 2, 3, 4, 5, 6, null);
        const s = try dt.toString(allocator, .{});
        defer allocator.free(s);
        try std.testing.expectEqualStrings("2024-02-29T01:02:03.004005006", s);
    }
    {
        const dt = try PlainDateTime.init(2024, 1, 1, 0, 0, 0, 0, 0, 0, null);
        const s = try dt.toString(allocator, .{});
        defer allocator.free(s);
        try std.testing.expectEqualStrings("2024-01-01T00:00:00", s);
    }
}

test "fromString: date-only defaults time to midnight" {
    const dt = try PlainDateTime.from(.{ .string = "2024-02-29" }, .{});
    try std.testing.expectEqual(@as(u8, 0), dt.time.hour);
    try std.testing.expectEqual(@as(u8, 29), dt.date.iso_day);
}

test "add: floors time-of-day carry (unlike PlainDate.add's truncation)" {
    const dt = try PlainDateTime.init(2024, 1, 2, 0, 0, 0, 0, 0, 0, null);
    const r = try dt.add(try Duration.init(0, 0, 0, 0, -23, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(u8, 1), r.date.iso_day);
    try std.testing.expectEqual(@as(u8, 1), r.time.hour);
}

test "add: date+time+overflow combined in one call" {
    const dt = try PlainDateTime.init(2023, 2, 28, 23, 30, 0, 0, 0, 0, null);
    const r = try dt.add(try Duration.init(1, 0, 0, 1, 1, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(i32, 2024), r.date.iso_year);
    try std.testing.expectEqual(@as(u8, 3), r.date.iso_month);
    try std.testing.expectEqual(@as(u8, 1), r.date.iso_day);
    try std.testing.expectEqual(@as(u8, 0), r.time.hour);
    try std.testing.expectEqual(@as(u8, 30), r.time.minute);
}

test "subtract: crosses year boundary backward" {
    const dt = try PlainDateTime.init(2024, 1, 1, 0, 0, 0, 0, 0, 0, null);
    const r = try dt.subtract(try Duration.init(0, 0, 0, 0, 1, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(i32, 2023), r.date.iso_year);
    try std.testing.expectEqual(@as(u8, 12), r.date.iso_month);
    try std.testing.expectEqual(@as(u8, 31), r.date.iso_day);
    try std.testing.expectEqual(@as(u8, 23), r.time.hour);
}
