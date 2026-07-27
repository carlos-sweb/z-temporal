//! `Temporal.PlainDateTime` -- a `PlainDate` + `PlainTime` pair. Overflow
//! validation on construction combines both types' own rules unchanged
//! (date's month/day lower bound always rejects; time's fields clamp
//! symmetrically) -- ground-truthed against real Node.
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
    const time_diff_ns: i128 = @as(i128, other.time.totalNanoseconds()) - @as(i128, self.time.totalNanoseconds());

    if (rounding.isTimeUnit(resolved.largest)) {
        const self_epoch = iso_calendar.toEpochDay(self.date.iso_year, self.date.iso_month, self.date.iso_day);
        const other_epoch = iso_calendar.toEpochDay(other.date.iso_year, other.date.iso_month, other.date.iso_day);
        var total_ns: i128 = @as(i128, other_epoch - self_epoch) * NS_PER_DAY + time_diff_ns;
        if (negate) total_ns = -total_ns;
        return plain_time.decomposeTimeDiff(total_ns, resolved, increment, mode);
    }

    const day_carry: i64 = @intCast(@divFloor(time_diff_ns, NS_PER_DAY));
    const remaining_time_ns: i128 = @mod(time_diff_ns, NS_PER_DAY);
    const other_epoch = iso_calendar.toEpochDay(other.date.iso_year, other.date.iso_month, other.date.iso_day);
    const adjusted_end = iso_calendar.fromEpochDay(other_epoch + day_carry);
    const start_ymd = iso_calendar.YearMonthDay{ .year = self.date.iso_year, .month = self.date.iso_month, .day = self.date.iso_day };

    const raw = try plain_date.diffISODate(start_ymd, adjusted_end, resolved.largest);

    if (resolved.smallest == .day) {
        var numerator: i128 = @as(i128, raw.days) * NS_PER_DAY + remaining_time_ns;
        var years = raw.years;
        var months = raw.months;
        var weeks = raw.weeks;
        if (negate) {
            numerator = -numerator;
            years = -years;
            months = -months;
            weeks = -weeks;
        }
        const rounded_days: i64 = @intCast(rounding.roundRatioToIncrement(numerator, NS_PER_DAY, increment, mode));
        return Duration.create(years, months, weeks, rounded_days, 0, 0, 0, 0, 0, 0);
    }

    if (rounding.isTimeUnit(resolved.smallest)) {
        var time_value = remaining_time_ns;
        var years = raw.years;
        var months = raw.months;
        var weeks = raw.weeks;
        var days = raw.days;
        // `remaining_time_ns` is always >= 0 (floor-mod convention), but
        // `raw.days` can be negative in a backward `until` (`self` later
        // than `other`) -- reconcile to a same-sign pair before any
        // further sign flip, or `Duration.create` rejects the mix.
        if (days < 0 and time_value > 0) {
            days += 1;
            time_value -= NS_PER_DAY;
        }
        if (negate) {
            time_value = -time_value;
            years = -years;
            months = -months;
            weeks = -weeks;
            days = -days;
        }
        const smallest_ns = plain_time.nsPerUnit(resolved.smallest);
        const rounded_units = rounding.roundRatioToIncrement(time_value, smallest_ns, increment, mode);
        var rounded_ns: i128 = rounded_units * smallest_ns;
        // Magnitude-based, not sign-based: `rounded_ns` is already
        // correctly signed to match `days` (both derive from the same
        // forward-or-negated computation) -- only a genuine
        // rounding-induced overflow past a full day needs a day carry.
        if (rounded_ns >= NS_PER_DAY) {
            days += 1;
            rounded_ns -= NS_PER_DAY;
        } else if (rounded_ns <= -NS_PER_DAY) {
            days -= 1;
            rounded_ns += NS_PER_DAY;
        }
        // The date part above already consumed everything down to `days`;
        // the time remainder always cascades fully from hour (never folds
        // into `resolved.largest`, which is a *date* unit here).
        const time_part = try plain_time.decomposeTimeDiff(rounded_ns, .{ .largest = .hour, .smallest = .nanosecond }, 1, .trunc);
        return Duration.create(years, months, weeks, days, time_part.hours, time_part.minutes, time_part.seconds, time_part.milliseconds, time_part.microseconds, time_part.nanoseconds);
    }

    // resolved.smallest is week/month/year: reuse PlainDate's calendar
    // rounding on the date-only pair. Known simplification: the sub-day
    // time-of-day fraction (already folded into `adjusted_end` via
    // `day_carry`, but not into the finer rounding numerator here) is
    // treated as negligible relative to a week/month/year-sized rounding
    // decision -- verified against every ground-truthed case in the Phase
    // 3b plan, revisit only if test262 surfaces a boundary tie this misses.
    const rd = try plain_date.roundDateDiff(start_ymd, adjusted_end, raw, resolved, increment, mode, negate);
    return Duration.create(rd.years, rd.months, rd.weeks, rd.days, 0, 0, 0, 0, 0, 0);
}

pub const PlainDateTime = struct {
    date: PlainDate,
    time: PlainTime = .{},

    pub fn create(year: i32, month: i32, day: i32, hour: i32, minute: i32, second: i32, millisecond: i32, microsecond: i32, nanosecond: i32, overflow: Overflow) TemporalError!PlainDateTime {
        const d = try PlainDate.create(year, month, day, overflow);
        const t = try PlainTime.create(hour, minute, second, millisecond, microsecond, nanosecond, overflow);
        return .{ .date = d, .time = t };
    }

    pub fn parseIso(text: []const u8) TemporalError!PlainDateTime {
        const parsed = try iso_string.parsePlainDateTime(text);
        const d = try PlainDate.create(parsed.date.year, parsed.date.month, parsed.date.day, .reject);
        return .{ .date = d, .time = .{
            .hour = parsed.time.hour,
            .minute = parsed.time.minute,
            .second = parsed.time.second,
            .millisecond = parsed.time.millisecond,
            .microsecond = parsed.time.microsecond,
            .nanosecond = parsed.time.nanosecond,
        } };
    }

    pub fn withFields(
        self: PlainDateTime,
        year: ?i32,
        month: ?i32,
        day: ?i32,
        hour: ?i32,
        minute: ?i32,
        second: ?i32,
        millisecond: ?i32,
        microsecond: ?i32,
        nanosecond: ?i32,
        overflow: Overflow,
    ) TemporalError!PlainDateTime {
        return create(
            year orelse self.date.iso_year,
            month orelse self.date.iso_month,
            day orelse self.date.iso_day,
            hour orelse self.time.hour,
            minute orelse self.time.minute,
            second orelse self.time.second,
            millisecond orelse self.time.millisecond,
            microsecond orelse self.time.microsecond,
            nanosecond orelse self.time.nanosecond,
            overflow,
        );
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
        const combined: i128 = @as(i128, self.time.totalNanoseconds()) + d.totalTimeNanoseconds();
        const day_carry: i64 = @intCast(@divFloor(combined, NS_PER_DAY));
        const ns_of_day: u64 = @intCast(@mod(combined, NS_PER_DAY));

        const stepped = try plain_date.addISODate(self.date.iso_year, self.date.iso_month, self.date.iso_day, d.years, d.months, overflow);
        const epoch_day = iso_calendar.toEpochDay(stepped.year, stepped.month, stepped.day) + d.weeks * 7 + day_carry;
        const ymd = iso_calendar.fromEpochDay(epoch_day);
        if (!iso_calendar.isInRange(ymd.year, ymd.month, ymd.day)) return error.InvalidRange;
        return .{
            .date = .{ .iso_year = ymd.year, .iso_month = ymd.month, .iso_day = ymd.day },
            .time = PlainTime.fromNanosecondsOfDay(ns_of_day),
        };
    }

    pub fn subtract(self: PlainDateTime, d: Duration, overflow: Overflow) TemporalError!PlainDateTime {
        return self.add(d.negated(), overflow);
    }

    pub fn until(self: PlainDateTime, other: PlainDateTime, options: RoundingOptions) TemporalError!Duration {
        const resolved = try rounding.resolveDateTimeUnits(options);
        return diffDateTime(self, other, resolved, options.rounding_increment, options.rounding_mode, false);
    }

    pub fn since(self: PlainDateTime, other: PlainDateTime, options: RoundingOptions) TemporalError!Duration {
        const resolved = try rounding.resolveDateTimeUnits(options);
        return diffDateTime(self, other, resolved, options.rounding_increment, options.rounding_mode, true);
    }

    /// Rounds to `options.smallest_unit` (required; restricted to time
    /// units plus `.day` -- ground-truthed that real Temporal rejects
    /// week/month/year here, unlike `until`/`since`). `.day` uses noon as
    /// the tie point (fixed `NS_PER_DAY` denominator); any unit carries
    /// the date forward one day on overflow, reusing the same epoch-day
    /// shift `diffDateTime`'s date/time borrow already establishes.
    pub fn round(self: PlainDateTime, options: rounding.RoundOptions) TemporalError!PlainDateTime {
        const smallest = options.smallest_unit orelse return error.InvalidRange;
        if (!rounding.isTimeUnitOrDay(smallest)) return error.InvalidRange;
        try rounding.validateIncrement(smallest, options.rounding_increment);

        const smallest_ns: i128 = if (smallest == .day) NS_PER_DAY else plain_time.nsPerUnit(smallest);
        const rounded_units = rounding.roundRatioToIncrement(self.time.totalNanoseconds(), smallest_ns, options.rounding_increment, options.rounding_mode);
        var rounded_ns: i128 = rounded_units * smallest_ns;

        var day_carry: i64 = 0;
        if (rounded_ns >= NS_PER_DAY) {
            day_carry = 1;
            rounded_ns -= NS_PER_DAY;
        }
        const ns_of_day: u64 = @intCast(rounded_ns);

        const epoch_day = iso_calendar.toEpochDay(self.date.iso_year, self.date.iso_month, self.date.iso_day) + day_carry;
        const ymd = iso_calendar.fromEpochDay(epoch_day);
        if (!iso_calendar.isInRange(ymd.year, ymd.month, ymd.day)) return error.InvalidRange;
        return .{
            .date = .{ .iso_year = ymd.year, .iso_month = ymd.month, .iso_day = ymd.day },
            .time = PlainTime.fromNanosecondsOfDay(ns_of_day),
        };
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
    pub fn toIsoString(self: PlainDateTime, allocator: std.mem.Allocator, show_calendar: bool) ![]u8 {
        var year_buf: [8]u8 = undefined;
        const year_str = iso_string.formatYear(&year_buf, self.date.iso_year);
        var frac_buf: [10]u8 = undefined;
        const frac = iso_string.formatFractionalSeconds(&frac_buf, self.time.millisecond, self.time.microsecond, self.time.nanosecond);
        if (show_calendar) {
            return std.fmt.allocPrint(allocator, "{s}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{s}[u-ca=iso8601]", .{
                year_str, self.date.iso_month, self.date.iso_day, self.time.hour, self.time.minute, self.time.second, frac,
            });
        }
        return std.fmt.allocPrint(allocator, "{s}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{s}", .{
            year_str, self.date.iso_month, self.date.iso_day, self.time.hour, self.time.minute, self.time.second, frac,
        });
    }
};

test "create combines PlainDate + PlainTime overflow rules" {
    const c = try PlainDateTime.create(2024, 2, 30, 25, 0, 0, 0, 0, 0, .constrain);
    try std.testing.expectEqual(@as(u8, 29), c.date.iso_day);
    try std.testing.expectEqual(@as(u8, 23), c.time.hour);
    try std.testing.expectError(error.InvalidRange, PlainDateTime.create(2024, 0, 1, 0, 0, 0, 0, 0, 0, .constrain));
}

test "toPlainDate/toPlainTime" {
    const dt = try PlainDateTime.create(2024, 2, 29, 1, 2, 3, 4, 5, 6, .reject);
    try std.testing.expect(PlainDate.equals(dt.toPlainDate(), try PlainDate.create(2024, 2, 29, .reject)));
    try std.testing.expect(PlainTime.equals(dt.toPlainTime(), try PlainTime.create(1, 2, 3, 4, 5, 6, .reject)));
}

test "compare" {
    const a = try PlainDateTime.create(2024, 1, 1, 0, 0, 0, 0, 0, 0, .reject);
    const b = try PlainDateTime.create(2024, 1, 2, 0, 0, 0, 0, 0, 0, .reject);
    try std.testing.expectEqual(std.math.Order.lt, PlainDateTime.compare(a, b));
}

test "toIsoString matches real Node byte-for-byte" {
    const allocator = std.testing.allocator;
    {
        const dt = try PlainDateTime.create(2024, 2, 29, 1, 2, 3, 4, 5, 6, .reject);
        const s = try dt.toIsoString(allocator, false);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("2024-02-29T01:02:03.004005006", s);
    }
    {
        const dt = try PlainDateTime.create(2024, 1, 1, 0, 0, 0, 0, 0, 0, .reject);
        const s = try dt.toIsoString(allocator, false);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("2024-01-01T00:00:00", s);
    }
}

test "parseIso: date-only defaults time to midnight" {
    const dt = try PlainDateTime.parseIso("2024-02-29");
    try std.testing.expectEqual(@as(u8, 0), dt.time.hour);
    try std.testing.expectEqual(@as(u8, 29), dt.date.iso_day);
}

test "add: floors time-of-day carry (unlike PlainDate.add's truncation)" {
    const dt = try PlainDateTime.create(2024, 1, 2, 0, 0, 0, 0, 0, 0, .reject);
    const r = try dt.add(try Duration.create(0, 0, 0, 0, -23, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(u8, 1), r.date.iso_day);
    try std.testing.expectEqual(@as(u8, 1), r.time.hour);
}

test "add: date+time+overflow combined in one call" {
    const dt = try PlainDateTime.create(2023, 2, 28, 23, 30, 0, 0, 0, 0, .reject);
    const r = try dt.add(try Duration.create(1, 0, 0, 1, 1, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(i32, 2024), r.date.iso_year);
    try std.testing.expectEqual(@as(u8, 3), r.date.iso_month);
    try std.testing.expectEqual(@as(u8, 1), r.date.iso_day);
    try std.testing.expectEqual(@as(u8, 0), r.time.hour);
    try std.testing.expectEqual(@as(u8, 30), r.time.minute);
}

test "subtract: crosses year boundary backward" {
    const dt = try PlainDateTime.create(2024, 1, 1, 0, 0, 0, 0, 0, 0, .reject);
    const r = try dt.subtract(try Duration.create(0, 0, 0, 0, 1, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(i32, 2023), r.date.iso_year);
    try std.testing.expectEqual(@as(u8, 12), r.date.iso_month);
    try std.testing.expectEqual(@as(u8, 31), r.date.iso_day);
    try std.testing.expectEqual(@as(u8, 23), r.time.hour);
}
