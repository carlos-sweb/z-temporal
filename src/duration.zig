//! `Temporal.Duration`. No calendar dependency at all in this phase --
//! ground-truthed against real Node that `.add()`/`.subtract()` never
//! allow a years/months/weeks operand, regardless of `relativeTo`
//! (contrary to the original roadmap sketch, which assumed they would
//! need calendar support), so they're fully implemented here. `.compare()`
//! is implemented only for the non-calendar-unit case (plus an
//! always-available fields-equal fast path); the calendar-ambiguous case
//! needs `PlainDate` arithmetic (Phase 3). `.round()`/`.total()` need the
//! same and are not here at all yet.
const std = @import("std");
const iso_string = @import("iso_string.zig");
const duration_string = @import("duration_string.zig");
const errors = @import("errors.zig");
const TemporalError = errors.TemporalError;

/// Each field's magnitude bound (`2^32 - 1`) and the combined time-part's
/// total-nanoseconds bound (`2^53 * 10^9 - 1`) were reverse-engineered by
/// bisection against real Node (not derived from spec text) and confirmed
/// exact against 3 independent single-field boundary cases -- see the
/// Phase 2 plan for the bisection results.
const CALENDAR_UNIT_MAX: u64 = 4_294_967_295; // 2^32 - 1
const MAX_TIME_NS: i128 = (1 << 53) * 1_000_000_000 - 1;

pub const Duration = struct {
    years: i64 = 0,
    months: i64 = 0,
    weeks: i64 = 0,
    days: i64 = 0,
    hours: i64 = 0,
    minutes: i64 = 0,
    seconds: i64 = 0,
    milliseconds: i64 = 0,
    microseconds: i64 = 0,
    nanoseconds: i64 = 0,

    /// Full `IsValidDuration`: all nonzero fields must share one sign,
    /// `|years|`/`|months|`/`|weeks|` individually bounded, and the
    /// combined time part bounded as a single total-nanoseconds value.
    pub fn create(
        years: i64,
        months: i64,
        weeks: i64,
        days: i64,
        hours: i64,
        minutes: i64,
        seconds: i64,
        milliseconds: i64,
        microseconds: i64,
        nanoseconds: i64,
    ) TemporalError!Duration {
        const fields = [_]i64{ years, months, weeks, days, hours, minutes, seconds, milliseconds, microseconds, nanoseconds };
        var has_pos = false;
        var has_neg = false;
        for (fields) |v| {
            if (v > 0) has_pos = true;
            if (v < 0) has_neg = true;
        }
        if (has_pos and has_neg) return error.InvalidRange;

        if (@abs(years) > CALENDAR_UNIT_MAX) return error.InvalidRange;
        if (@abs(months) > CALENDAR_UNIT_MAX) return error.InvalidRange;
        if (@abs(weeks) > CALENDAR_UNIT_MAX) return error.InvalidRange;

        const total_ns = timePartNanoseconds(days, hours, minutes, seconds, milliseconds, microseconds, nanoseconds);
        if (total_ns > MAX_TIME_NS or total_ns < -MAX_TIME_NS) return error.InvalidRange;

        return .{
            .years = years,
            .months = months,
            .weeks = weeks,
            .days = days,
            .hours = hours,
            .minutes = minutes,
            .seconds = seconds,
            .milliseconds = milliseconds,
            .microseconds = microseconds,
            .nanoseconds = nanoseconds,
        };
    }

    pub fn parseIso(text: []const u8) TemporalError!Duration {
        const raw = try duration_string.parseDuration(text);
        return create(raw.years, raw.months, raw.weeks, raw.days, raw.hours, raw.minutes, raw.seconds, raw.milliseconds, raw.microseconds, raw.nanoseconds);
    }

    /// Field overrides, re-validated the same way `create` does. A
    /// struct-of-optionals (not `PlainDate`/`PlainTime`'s positional
    /// `?i32` params) because 10 positional optionals would be unreadable
    /// and error-prone at call sites.
    pub fn withFields(self: Duration, overrides: struct {
        years: ?i64 = null,
        months: ?i64 = null,
        weeks: ?i64 = null,
        days: ?i64 = null,
        hours: ?i64 = null,
        minutes: ?i64 = null,
        seconds: ?i64 = null,
        milliseconds: ?i64 = null,
        microseconds: ?i64 = null,
        nanoseconds: ?i64 = null,
    }) TemporalError!Duration {
        return create(
            overrides.years orelse self.years,
            overrides.months orelse self.months,
            overrides.weeks orelse self.weeks,
            overrides.days orelse self.days,
            overrides.hours orelse self.hours,
            overrides.minutes orelse self.minutes,
            overrides.seconds orelse self.seconds,
            overrides.milliseconds orelse self.milliseconds,
            overrides.microseconds orelse self.microseconds,
            overrides.nanoseconds orelse self.nanoseconds,
        );
    }

    pub fn sign(self: Duration) i8 {
        const fields = [_]i64{ self.years, self.months, self.weeks, self.days, self.hours, self.minutes, self.seconds, self.milliseconds, self.microseconds, self.nanoseconds };
        for (fields) |v| {
            if (v > 0) return 1;
            if (v < 0) return -1;
        }
        return 0;
    }

    pub fn blank(self: Duration) bool {
        return self.sign() == 0;
    }

    pub fn negated(self: Duration) Duration {
        return .{
            .years = -self.years,
            .months = -self.months,
            .weeks = -self.weeks,
            .days = -self.days,
            .hours = -self.hours,
            .minutes = -self.minutes,
            .seconds = -self.seconds,
            .milliseconds = -self.milliseconds,
            .microseconds = -self.microseconds,
            .nanoseconds = -self.nanoseconds,
        };
    }

    pub fn abs(self: Duration) Duration {
        return if (self.sign() < 0) self.negated() else self;
    }

    /// `days`/`hours`/.../`nanoseconds` summed as nanoseconds (no calendar
    /// units -- those have no fixed length). Used by `PlainDate`/
    /// `PlainTime`/`PlainDateTime.add`/`.subtract` (Phase 3a) to fold the
    /// duration's time part into a day-count-plus-time-of-day step.
    pub fn totalTimeNanoseconds(self: Duration) i128 {
        return timePartNanoseconds(self.days, self.hours, self.minutes, self.seconds, self.milliseconds, self.microseconds, self.nanoseconds);
    }

    fn hasCalendarUnits(self: Duration) bool {
        return self.years != 0 or self.months != 0 or self.weeks != 0;
    }

    fn fieldsEqual(a: Duration, b: Duration) bool {
        return a.years == b.years and a.months == b.months and a.weeks == b.weeks and a.days == b.days and
            a.hours == b.hours and a.minutes == b.minutes and a.seconds == b.seconds and
            a.milliseconds == b.milliseconds and a.microseconds == b.microseconds and a.nanoseconds == b.nanoseconds;
    }

    /// Fields-equal is a fast path that returns `.eq` even with calendar
    /// units present (ground-truthed: real Temporal short-circuits this
    /// case without needing `relativeTo`). Otherwise, if either side has
    /// a nonzero year/month/week, `error.NeedsRelativeTo` (needs
    /// calendar-aware balancing -- Phase 3). Otherwise compares via the
    /// combined total-nanoseconds value.
    pub fn compare(a: Duration, b: Duration) TemporalError!std.math.Order {
        if (fieldsEqual(a, b)) return .eq;
        if (a.hasCalendarUnits() or b.hasCalendarUnits()) return error.NeedsRelativeTo;
        const na = timePartNanoseconds(a.days, a.hours, a.minutes, a.seconds, a.milliseconds, a.microseconds, a.nanoseconds);
        const nb = timePartNanoseconds(b.days, b.hours, b.minutes, b.seconds, b.milliseconds, b.microseconds, b.nanoseconds);
        return std.math.order(na, nb);
    }

    /// `error.MixedCalendarUnits` if `self` or `other` has a nonzero year/
    /// month/week (real Temporal's unconditional restriction -- not
    /// resolvable with any `relativeTo`). Otherwise balances the time-part
    /// fields up through `min(largestUnitRank(self), largestUnitRank(other))`
    /// (i.e. the more-significant of the two operands' largest present
    /// unit) -- ground-truthed: `25h+3h="PT28H"` (no promotion to days,
    /// neither operand had a days field) vs. `1d+30h="P2DT6H"` (promoted,
    /// since one operand did).
    pub fn add(self: Duration, other: Duration) TemporalError!Duration {
        if (self.hasCalendarUnits() or other.hasCalendarUnits()) return error.MixedCalendarUnits;
        const na = timePartNanoseconds(self.days, self.hours, self.minutes, self.seconds, self.milliseconds, self.microseconds, self.nanoseconds);
        const nb = timePartNanoseconds(other.days, other.hours, other.minutes, other.seconds, other.milliseconds, other.microseconds, other.nanoseconds);
        const target_rank = @min(self.largestUnitRank(), other.largestUnitRank());
        return fromNanosecondsAtRank(na + nb, target_rank);
    }

    pub fn subtract(self: Duration, other: Duration) TemporalError!Duration {
        return self.add(other.negated());
    }

    /// 0=days .. 6=nanoseconds; the most-significant nonzero time-part
    /// field, or 6 (nanoseconds) if the time part is entirely zero.
    fn largestUnitRank(self: Duration) u8 {
        if (self.days != 0) return 0;
        if (self.hours != 0) return 1;
        if (self.minutes != 0) return 2;
        if (self.seconds != 0) return 3;
        if (self.milliseconds != 0) return 4;
        if (self.microseconds != 0) return 5;
        return 6;
    }

    /// `YYYY.../PnYnMnWnDTnHnMn[.fraction]S` per real Temporal's default
    /// `toString()`: single leading `-` (never per-component), zero
    /// fields omitted, `T` section present only if any of hours/minutes/
    /// (seconds-or-fraction) is nonzero, wholly-blank prints `"PT0S"`.
    /// `milliseconds`/`microseconds`/`nanoseconds` are merged into the
    /// displayed seconds value for formatting purposes only (ground-
    /// truthed: `Duration(0,0,0,0,0,0,0,5000)` -- 5000ms -- stringifies as
    /// `"PT5S"`, without mutating the stored `.milliseconds` field).
    pub fn toIsoString(self: Duration, allocator: std.mem.Allocator) ![]u8 {
        const combined_ns: i128 = @as(i128, self.milliseconds) * 1_000_000 + @as(i128, self.microseconds) * 1_000 + @as(i128, self.nanoseconds);
        const whole_seconds_carry: i64 = @intCast(@divTrunc(combined_ns, 1_000_000_000));
        const remainder_ns: i128 = @rem(combined_ns, 1_000_000_000);
        const display_seconds: i64 = self.seconds + whole_seconds_carry;

        const remainder_abs: u32 = @intCast(@abs(remainder_ns));
        const disp_ms: u16 = @intCast(remainder_abs / 1_000_000);
        const disp_us: u16 = @intCast((remainder_abs / 1_000) % 1_000);
        const disp_ns: u16 = @intCast(remainder_abs % 1_000);

        var frac_buf: [10]u8 = undefined;
        const frac = iso_string.formatFractionalSeconds(&frac_buf, disp_ms, disp_us, disp_ns);

        var buf: [192]u8 = undefined;
        var len: usize = 0;
        if (self.sign() < 0) {
            buf[0] = '-';
            len = 1;
        }
        buf[len] = 'P';
        len += 1;
        const start_after_p = len;

        if (self.years != 0) len += (std.fmt.bufPrint(buf[len..], "{d}Y", .{@abs(self.years)}) catch unreachable).len;
        if (self.months != 0) len += (std.fmt.bufPrint(buf[len..], "{d}M", .{@abs(self.months)}) catch unreachable).len;
        if (self.weeks != 0) len += (std.fmt.bufPrint(buf[len..], "{d}W", .{@abs(self.weeks)}) catch unreachable).len;
        if (self.days != 0) len += (std.fmt.bufPrint(buf[len..], "{d}D", .{@abs(self.days)}) catch unreachable).len;

        const has_time = self.hours != 0 or self.minutes != 0 or display_seconds != 0 or frac.len != 0;
        if (has_time) {
            buf[len] = 'T';
            len += 1;
            if (self.hours != 0) len += (std.fmt.bufPrint(buf[len..], "{d}H", .{@abs(self.hours)}) catch unreachable).len;
            if (self.minutes != 0) len += (std.fmt.bufPrint(buf[len..], "{d}M", .{@abs(self.minutes)}) catch unreachable).len;
            if (display_seconds != 0 or frac.len != 0) {
                len += (std.fmt.bufPrint(buf[len..], "{d}{s}S", .{ @abs(display_seconds), frac }) catch unreachable).len;
            }
        }

        if (len == start_after_p) {
            return allocator.dupe(u8, "PT0S");
        }
        return allocator.dupe(u8, buf[0..len]);
    }
};

/// `days`/`hours`/`minutes`/`seconds`/`milliseconds`/`microseconds`/
/// `nanoseconds`, all converted to and summed as nanoseconds. Shared by
/// `create`'s validation, `compare`, and `add`.
fn timePartNanoseconds(days: i64, hours: i64, minutes: i64, seconds: i64, milliseconds: i64, microseconds: i64, nanoseconds: i64) i128 {
    return @as(i128, days) * 86_400_000_000_000 +
        @as(i128, hours) * 3_600_000_000_000 +
        @as(i128, minutes) * 60_000_000_000 +
        @as(i128, seconds) * 1_000_000_000 +
        @as(i128, milliseconds) * 1_000_000 +
        @as(i128, microseconds) * 1_000 +
        @as(i128, nanoseconds);
}

/// Inverse of `timePartNanoseconds`, but stopping the "days/hours/.../ns"
/// decomposition early at `target_rank` (0=days..6=nanoseconds): every
/// unit at or below `target_rank` is extracted at its natural size: the
/// field AT `target_rank` absorbs everything larger than it instead of
/// being further carried up (this is `add`/`subtract`'s balancing rule).
fn fromNanosecondsAtRank(total_ns: i128, target_rank: u8) TemporalError!Duration {
    var remaining = total_ns;
    var days: i64 = 0;
    var hours: i64 = 0;
    var minutes: i64 = 0;
    var seconds: i64 = 0;
    var milliseconds: i64 = 0;
    var microseconds: i64 = 0;

    if (target_rank <= 0) {
        days = @intCast(@divTrunc(remaining, 86_400_000_000_000));
        remaining = @rem(remaining, 86_400_000_000_000);
    }
    if (target_rank <= 1) {
        hours = @intCast(@divTrunc(remaining, 3_600_000_000_000));
        remaining = @rem(remaining, 3_600_000_000_000);
    }
    if (target_rank <= 2) {
        minutes = @intCast(@divTrunc(remaining, 60_000_000_000));
        remaining = @rem(remaining, 60_000_000_000);
    }
    if (target_rank <= 3) {
        seconds = @intCast(@divTrunc(remaining, 1_000_000_000));
        remaining = @rem(remaining, 1_000_000_000);
    }
    if (target_rank <= 4) {
        milliseconds = @intCast(@divTrunc(remaining, 1_000_000));
        remaining = @rem(remaining, 1_000_000);
    }
    if (target_rank <= 5) {
        microseconds = @intCast(@divTrunc(remaining, 1_000));
        remaining = @rem(remaining, 1_000);
    }
    const nanoseconds: i64 = @intCast(remaining);

    return Duration.create(0, 0, 0, days, hours, minutes, seconds, milliseconds, microseconds, nanoseconds);
}

test "create: sign consistency" {
    try std.testing.expectError(error.InvalidRange, Duration.create(-1, 1, 0, 0, 0, 0, 0, 0, 0, 0));
    _ = try Duration.create(-1, -2, 0, 0, -3, 0, 0, 0, 0, 0);
}

test "create: calendar-unit bound is exactly 2^32-1" {
    _ = try Duration.create(4_294_967_295, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    try std.testing.expectError(error.InvalidRange, Duration.create(4_294_967_296, 0, 0, 0, 0, 0, 0, 0, 0, 0));
}

test "create: time-part total-nanoseconds bound matches bisected Node boundaries" {
    _ = try Duration.create(0, 0, 0, 104_249_991_374, 0, 0, 0, 0, 0, 0);
    try std.testing.expectError(error.InvalidRange, Duration.create(0, 0, 0, 104_249_991_375, 0, 0, 0, 0, 0, 0));
    _ = try Duration.create(0, 0, 0, 0, 2_501_999_792_983, 0, 0, 0, 0, 0);
    try std.testing.expectError(error.InvalidRange, Duration.create(0, 0, 0, 0, 2_501_999_792_984, 0, 0, 0, 0, 0));
    _ = try Duration.create(0, 0, 0, 0, 0, 0, 9_007_199_254_740_991, 0, 0, 0);
    try std.testing.expectError(error.InvalidRange, Duration.create(0, 0, 0, 0, 0, 0, 9_007_199_254_740_992, 0, 0, 0));
}

test "sign / blank" {
    const blank_d = try Duration.create(0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    try std.testing.expect(blank_d.blank());
    try std.testing.expectEqual(@as(i8, 0), blank_d.sign());
    const pos = try Duration.create(1, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(i8, 1), pos.sign());
    const neg = try Duration.create(-1, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(i8, -1), neg.sign());
}

test "negated / abs" {
    const d = try Duration.create(1, 2, 0, 3, 0, 0, 0, 0, 0, 0);
    const n = d.negated();
    try std.testing.expectEqual(@as(i64, -1), n.years);
    try std.testing.expectEqual(@as(i64, -2), n.months);
    const a = (try Duration.create(-1, -2, 0, -3, 0, 0, 0, 0, 0, 0)).abs();
    try std.testing.expectEqual(@as(i64, 1), a.years);
}

test "compare: equal fields is a fast path even with calendar units" {
    const a = try Duration.create(1, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(std.math.Order.eq, try Duration.compare(a, a));
}

test "compare: calendar units on either side (not equal) needs relativeTo" {
    const a = try Duration.create(2, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    const b = try Duration.create(1, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    try std.testing.expectError(error.NeedsRelativeTo, Duration.compare(a, b));
}

test "compare: non-calendar durations compare by total nanoseconds" {
    const a = try Duration.create(0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    const b = try Duration.create(0, 0, 0, 1, 0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(std.math.Order.lt, try Duration.compare(a, b));
}

test "add/subtract: throws on any calendar-unit operand, no exception for relativeTo" {
    const y = try Duration.create(1, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    const d = try Duration.create(0, 0, 0, 1, 0, 0, 0, 0, 0, 0);
    try std.testing.expectError(error.MixedCalendarUnits, Duration.add(y, d));
    try std.testing.expectError(error.MixedCalendarUnits, Duration.subtract(y, d));
}

test "add: no promotion when neither operand has the larger unit" {
    const a = try Duration.create(0, 0, 0, 0, 25, 0, 0, 0, 0, 0);
    const b = try Duration.create(0, 0, 0, 0, 3, 0, 0, 0, 0, 0);
    const r = try Duration.add(a, b);
    try std.testing.expectEqual(@as(i64, 0), r.days);
    try std.testing.expectEqual(@as(i64, 28), r.hours);
}

test "add: promotion when one operand has the larger unit" {
    const a = try Duration.create(0, 0, 0, 1, 0, 0, 0, 0, 0, 0);
    const b = try Duration.create(0, 0, 0, 0, 30, 0, 0, 0, 0, 0);
    const r = try Duration.add(a, b);
    try std.testing.expectEqual(@as(i64, 2), r.days);
    try std.testing.expectEqual(@as(i64, 6), r.hours);
}

test "subtract: can produce a negative result" {
    const a = try Duration.create(0, 0, 0, 0, 1, 0, 0, 0, 0, 0);
    const b = try Duration.create(0, 0, 0, 0, 5, 0, 0, 0, 0, 0);
    const r = try Duration.subtract(a, b);
    try std.testing.expectEqual(@as(i64, -4), r.hours);
}

test "toIsoString matches real Node byte-for-byte" {
    const allocator = std.testing.allocator;
    {
        const d = try Duration.create(1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
        const s = try d.toIsoString(allocator);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("P1Y2M3W4DT5H6M7.00800901S", s);
    }
    {
        const d = try Duration.create(0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        const s = try d.toIsoString(allocator);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("PT0S", s);
    }
    {
        const d = try Duration.create(-1, -2, 0, 0, -3, 0, 0, 0, 0, 0);
        const s = try d.toIsoString(allocator);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("-P1Y2MT3H", s);
    }
    {
        const d = try Duration.create(0, 0, 0, 0, 0, 0, 0, 0, 0, -5);
        const s = try d.toIsoString(allocator);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("-PT0.000000005S", s);
    }
    {
        const d = try Duration.create(1, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        const s = try d.toIsoString(allocator);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("P1Y", s);
    }
    {
        const d = try Duration.create(0, 0, 0, 0, 1, 0, 5, 0, 0, 0);
        const s = try d.toIsoString(allocator);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("PT1H5S", s);
    }
    {
        const d = try Duration.create(0, 0, 0, 0, 0, 5, 0, 0, 0, 0);
        const s = try d.toIsoString(allocator);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("PT5M", s);
    }
    {
        // ms=5000 displays as "PT5S" without mutating the stored field.
        const d = try Duration.create(0, 0, 0, 0, 0, 0, 0, 5000, 0, 0);
        const s = try d.toIsoString(allocator);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("PT5S", s);
        try std.testing.expectEqual(@as(i64, 5000), d.milliseconds);
    }
}

test "parseIso round-trips" {
    const d = try Duration.parseIso("P1Y2M3W4DT5H6M7.5S");
    try std.testing.expectEqual(@as(i64, 1), d.years);
    try std.testing.expectEqual(@as(i64, 500), d.milliseconds);
}
