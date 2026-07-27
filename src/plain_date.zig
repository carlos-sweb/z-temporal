//! `Temporal.PlainDate`, ISO calendar only (Phase 1 -- non-ISO calendars are
//! a later phase, see the README's Scope section). No arithmetic
//! (`.add`/`.subtract`/`.until`/`.since`) -- that needs `Duration`, a later
//! phase.
const std = @import("std");
const iso_calendar = @import("iso_calendar.zig");
const iso_string = @import("iso_string.zig");
const errors = @import("errors.zig");
const TemporalError = errors.TemporalError;
const duration_mod = @import("duration.zig");
const Duration = duration_mod.Duration;

/// `.from()`/`.with()`'s `overflow` option. Constructors always behave as
/// `.reject` (there is no `overflow` option on `new Temporal.PlainDate`
/// itself, ground-truthed against real Node) -- callers wanting
/// constructor semantics should pass `.reject` to `create`.
pub const Overflow = enum { constrain, reject };

/// The calendar step shared by `PlainDate.add`/`.subtract` and
/// `PlainDateTime.add`/`.subtract` (`pub` so both can call the exact same
/// logic, no duplication): add `add_years`/`add_months` to `year`/`month`
/// (1-12 normalized, with year carry via floored division), then clamp/
/// reject the day-of-month against the new month's length per `overflow`.
/// Ground-truthed order: months are applied before any weeks/days step
/// the caller does afterwards (`2024-01-30 + {months:1,days:1}` ==
/// `2024-03-01`, i.e. Jan30 -constrain-> Feb29 -> +1 day -> Mar1, not the
/// other order, which would give Feb29).
pub fn addISODate(year: i32, month: u8, day: u8, add_years: i64, add_months: i64, overflow: Overflow) TemporalError!iso_calendar.YearMonthDay {
    const total_months: i64 = @as(i64, month) - 1 + add_months;
    const year_carry = @divFloor(total_months, 12);
    const new_month: u8 = @intCast(@mod(total_months, 12) + 1);
    const new_year_i64: i64 = @as(i64, year) + add_years + year_carry;
    if (new_year_i64 < iso_calendar.MIN_ISO_YEAR - 1 or new_year_i64 > iso_calendar.MAX_ISO_YEAR + 1) return error.InvalidRange;
    const new_year: i32 = @intCast(new_year_i64);

    const max_day = iso_calendar.daysInMonth(new_year, new_month);
    var d = day;
    if (day > max_day) {
        if (overflow == .reject) return error.InvalidRange;
        d = max_day;
    }
    return .{ .year = new_year, .month = new_month, .day = d };
}

pub const PlainDate = struct {
    iso_year: i32,
    iso_month: u8, // 1-12
    iso_day: u8, // 1-31

    /// Real spec: month/day must be positive integers UNCONDITIONALLY
    /// (ground-truthed: `month: 0` or `day: -1` throws even under
    /// `overflow: "constrain"`) -- only the UPPER bound (month > 12,
    /// day > daysInMonth) respects `overflow`.
    pub fn create(in_year: i32, in_month: i32, in_day: i32, overflow: Overflow) TemporalError!PlainDate {
        if (in_month < 1 or in_day < 1) return error.InvalidRange;
        var m: u8 = undefined;
        if (in_month > 12) {
            if (overflow == .reject) return error.InvalidRange;
            m = 12;
        } else {
            m = @intCast(in_month);
        }
        const max_day = iso_calendar.daysInMonth(in_year, m);
        var d: u8 = undefined;
        if (in_day > max_day) {
            if (overflow == .reject) return error.InvalidRange;
            d = max_day;
        } else {
            d = @intCast(in_day);
        }
        if (!iso_calendar.isInRange(in_year, m, d)) return error.InvalidRange;
        return .{ .iso_year = in_year, .iso_month = m, .iso_day = d };
    }

    pub fn parseIso(text: []const u8) TemporalError!PlainDate {
        const parsed = try iso_string.parsePlainDate(text);
        // A parsed ISO string is always exact -- reject if (somehow) out
        // of the representable range, never clamp silently.
        return create(parsed.year, parsed.month, parsed.day, .reject);
    }

    /// Field overrides (`in_year`/`in_month`/`in_day`, each optional --
    /// `null` keeps the current value), re-validated the same way
    /// `create` does.
    pub fn withFields(self: PlainDate, in_year: ?i32, in_month: ?i32, in_day: ?i32, overflow: Overflow) TemporalError!PlainDate {
        return create(in_year orelse self.iso_year, in_month orelse self.iso_month, in_day orelse self.iso_day, overflow);
    }

    /// Years/months applied first (`addISODate`, with `overflow` clamp/
    /// reject), then weeks/days/time-part folded into a single epoch-day
    /// step. The duration's time part **truncates toward zero** when
    /// converted to whole days (there's no existing time-of-day to
    /// combine with, unlike `PlainDateTime.add`, which floors) --
    /// ground-truthed: `.add({hours:-1})` on day 1 stays day 1
    /// (trunc(-1/24)=0), `.add({hours:-25})` from day 2 goes to day 1
    /// (trunc(-25/24)=-1), not further.
    pub fn add(self: PlainDate, d: Duration, overflow: Overflow) TemporalError!PlainDate {
        const stepped = try addISODate(self.iso_year, self.iso_month, self.iso_day, d.years, d.months, overflow);
        const days_from_time: i64 = @intCast(@divTrunc(d.totalTimeNanoseconds(), 86_400_000_000_000));
        const extra_days: i64 = d.weeks * 7 + days_from_time;
        const epoch_day = iso_calendar.toEpochDay(stepped.year, stepped.month, stepped.day) + extra_days;
        const ymd = iso_calendar.fromEpochDay(epoch_day);
        if (!iso_calendar.isInRange(ymd.year, ymd.month, ymd.day)) return error.InvalidRange;
        return .{ .iso_year = ymd.year, .iso_month = ymd.month, .iso_day = ymd.day };
    }

    pub fn subtract(self: PlainDate, d: Duration, overflow: Overflow) TemporalError!PlainDate {
        return self.add(d.negated(), overflow);
    }

    pub fn compare(a: PlainDate, b: PlainDate) std.math.Order {
        const ea = iso_calendar.toEpochDay(a.iso_year, a.iso_month, a.iso_day);
        const eb = iso_calendar.toEpochDay(b.iso_year, b.iso_month, b.iso_day);
        return std.math.order(ea, eb);
    }

    pub fn equals(a: PlainDate, b: PlainDate) bool {
        return a.iso_year == b.iso_year and a.iso_month == b.iso_month and a.iso_day == b.iso_day;
    }

    pub fn year(self: PlainDate) i32 {
        return self.iso_year;
    }
    pub fn month(self: PlainDate) u8 {
        return self.iso_month;
    }
    pub fn day(self: PlainDate) u8 {
        return self.iso_day;
    }
    pub fn monthCode(self: PlainDate, buf: *[3]u8) []const u8 {
        return iso_calendar.monthCodeBuf(buf, self.iso_month);
    }
    pub fn calendarId(self: PlainDate) []const u8 {
        _ = self;
        return "iso8601";
    }
    pub fn dayOfWeek(self: PlainDate) u8 {
        return iso_calendar.dayOfWeek(self.iso_year, self.iso_month, self.iso_day);
    }
    pub fn dayOfYear(self: PlainDate) u16 {
        return iso_calendar.dayOfYear(self.iso_year, self.iso_month, self.iso_day);
    }
    pub fn daysInMonth(self: PlainDate) u8 {
        return iso_calendar.daysInMonth(self.iso_year, self.iso_month);
    }
    pub fn daysInYear(self: PlainDate) u16 {
        return iso_calendar.daysInYear(self.iso_year);
    }
    pub fn monthsInYear(self: PlainDate) u8 {
        _ = self;
        return 12;
    }
    pub fn inLeapYear(self: PlainDate) bool {
        return iso_calendar.isLeapYear(self.iso_year);
    }
    pub fn weekOfYear(self: PlainDate) iso_calendar.WeekOfYear {
        return iso_calendar.weekOfYear(self.iso_year, self.iso_month, self.iso_day);
    }

    /// `YYYY-MM-DD` (or the extended `±YYYYYY-MM-DD` form outside
    /// [0,9999]), optionally suffixed with `[u-ca=iso8601]`.
    pub fn toIsoString(self: PlainDate, allocator: std.mem.Allocator, show_calendar: bool) ![]u8 {
        var year_buf: [8]u8 = undefined;
        const year_str = iso_string.formatYear(&year_buf, self.iso_year);
        if (show_calendar) {
            return std.fmt.allocPrint(allocator, "{s}-{d:0>2}-{d:0>2}[u-ca=iso8601]", .{ year_str, self.iso_month, self.iso_day });
        }
        return std.fmt.allocPrint(allocator, "{s}-{d:0>2}-{d:0>2}", .{ year_str, self.iso_month, self.iso_day });
    }
};

test "create: constrain clamps upper bound, reject throws" {
    const constrained = try PlainDate.create(2024, 13, 1, .constrain);
    try std.testing.expectEqual(@as(u8, 12), constrained.iso_month);
    try std.testing.expectError(error.InvalidRange, PlainDate.create(2024, 13, 1, .reject));

    const day_constrained = try PlainDate.create(2024, 2, 30, .constrain);
    try std.testing.expectEqual(@as(u8, 29), day_constrained.iso_day);
    try std.testing.expectError(error.InvalidRange, PlainDate.create(2024, 2, 30, .reject));
}

test "create: month/day below 1 always rejects, regardless of overflow" {
    try std.testing.expectError(error.InvalidRange, PlainDate.create(2024, 0, 1, .constrain));
    try std.testing.expectError(error.InvalidRange, PlainDate.create(2024, 1, -1, .constrain));
}

test "create: out-of-range year is InvalidRange" {
    try std.testing.expectError(error.InvalidRange, PlainDate.create(275760, 9, 14, .reject));
    try std.testing.expectError(error.InvalidRange, PlainDate.create(-271821, 4, 18, .reject));
    _ = try PlainDate.create(275760, 9, 13, .reject);
    _ = try PlainDate.create(-271821, 4, 19, .reject);
}

test "compare/equals" {
    const a = try PlainDate.create(2024, 2, 29, .reject);
    const b = try PlainDate.create(2024, 3, 1, .reject);
    try std.testing.expectEqual(std.math.Order.lt, PlainDate.compare(a, b));
    try std.testing.expect(!PlainDate.equals(a, b));
    try std.testing.expect(PlainDate.equals(a, a));
}

test "toIsoString matches real Node byte-for-byte" {
    const allocator = std.testing.allocator;
    {
        const d = try PlainDate.create(2024, 2, 29, .reject);
        const s = try d.toIsoString(allocator, false);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("2024-02-29", s);
    }
    {
        const d = try PlainDate.create(999, 1, 1, .reject);
        const s = try d.toIsoString(allocator, false);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("0999-01-01", s);
    }
    {
        const d = try PlainDate.create(-1, 1, 1, .reject);
        const s = try d.toIsoString(allocator, false);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("-000001-01-01", s);
    }
    {
        const d = try PlainDate.create(2024, 2, 29, .reject);
        const s = try d.toIsoString(allocator, true);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("2024-02-29[u-ca=iso8601]", s);
    }
}

test "parseIso round-trips and rejects non-iso8601 calendar" {
    const d = try PlainDate.parseIso("2024-02-29[u-ca=iso8601]");
    try std.testing.expectEqual(@as(i32, 2024), d.iso_year);
    try std.testing.expectError(error.InvalidFormat, PlainDate.parseIso("2024-02-29[u-ca=hebrew]"));
}

test "add: months applied before days (order matters), default constrain" {
    const d = try PlainDate.create(2024, 1, 30, .reject);
    const r = try d.add(try Duration.create(0, 1, 0, 1, 0, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(i32, 2024), r.iso_year);
    try std.testing.expectEqual(@as(u8, 3), r.iso_month);
    try std.testing.expectEqual(@as(u8, 1), r.iso_day);
}

test "add: reject overflow throws on invalid resulting day" {
    const d = try PlainDate.create(2023, 1, 31, .reject);
    try std.testing.expectError(error.InvalidRange, d.add(try Duration.create(0, 1, 0, 0, 0, 0, 0, 0, 0, 0), .reject));
}

test "add: duration time part truncates toward zero into days (no existing time-of-day)" {
    const day1 = try PlainDate.create(2024, 1, 1, .reject);
    const stayed = try day1.add(try Duration.create(0, 0, 0, 0, -1, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(u8, 1), stayed.iso_day);

    const day2 = try PlainDate.create(2024, 1, 2, .reject);
    const back = try day2.add(try Duration.create(0, 0, 0, 0, -25, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(u8, 1), back.iso_day);
}

test "subtract: mirrors add(negated)" {
    const d = try PlainDate.create(2024, 3, 31, .reject);
    const r = try d.subtract(try Duration.create(0, 1, 0, 0, 0, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(u8, 2), r.iso_month);
    try std.testing.expectEqual(@as(u8, 29), r.iso_day);
}
