//! Temporal.Duration: Number components, exact internal arithmetic, and relative operations.
const std = @import("std");
const iso_string = @import("iso_string.zig");
const duration_string = @import("duration_string.zig");
const errors = @import("errors.zig");
const TemporalError = errors.TemporalError;
const iso_calendar = @import("iso_calendar.zig");
const rounding = @import("rounding.zig");
const plain_date = @import("plain_date.zig");
const plain_date_time = @import("plain_date_time.zig");

const NS_PER_DAY: i128 = 86_400_000_000_000;

/// Each field's magnitude bound (`2^32 - 1`) and the combined time-part's
/// total-nanoseconds bound (`2^53 * 10^9 - 1`) were reverse-engineered by
/// bisection against real Node (not derived from spec text) and confirmed
/// exact against 3 independent single-field boundary cases -- see the
/// Phase 2 plan for the bisection results.
const CALENDAR_UNIT_MAX: u64 = 4_294_967_295; // 2^32 - 1
const MAX_TIME_NS: i128 = (1 << 53) * 1_000_000_000 - 1;

pub fn integer(value: f64) i128 {
    return @intFromFloat(value);
}
fn number(value: anytype) TemporalError!f64 {
    const result: f64 = switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => value,
        else => @compileError("Temporal duration components must be numbers"),
    };
    if (!std.math.isFinite(result) or @trunc(result) != result or @abs(result) > @as(f64, @floatFromInt(MAX_TIME_NS))) return error.RangeError;
    return if (result == 0) 0 else result;
}
pub const Duration = struct {
    years: f64 = 0,
    months: f64 = 0,
    weeks: f64 = 0,
    days: f64 = 0,
    hours: f64 = 0,
    minutes: f64 = 0,
    seconds: f64 = 0,
    milliseconds: f64 = 0,
    microseconds: f64 = 0,
    nanoseconds: f64 = 0,

    /// Full `IsValidDuration`: all nonzero fields must share one sign,
    /// `|years|`/`|months|`/`|weeks|` individually bounded, and the
    /// combined time part bounded as a single total-nanoseconds value.
    pub fn init(
        in_years: anytype,
        in_months: anytype,
        in_weeks: anytype,
        in_days: anytype,
        in_hours: anytype,
        in_minutes: anytype,
        in_seconds: anytype,
        in_milliseconds: anytype,
        in_microseconds: anytype,
        in_nanoseconds: anytype,
    ) TemporalError!Duration {
        const years = try number(in_years);
        const months = try number(in_months);
        const weeks = try number(in_weeks);
        const days = try number(in_days);
        const hours = try number(in_hours);
        const minutes = try number(in_minutes);
        const seconds = try number(in_seconds);
        const milliseconds = try number(in_milliseconds);
        const microseconds = try number(in_microseconds);
        const nanoseconds = try number(in_nanoseconds);
        const fields = [_]f64{ years, months, weeks, days, hours, minutes, seconds, milliseconds, microseconds, nanoseconds };
        var has_pos = false;
        var has_neg = false;
        for (fields) |v| {
            if (v > 0) has_pos = true;
            if (v < 0) has_neg = true;
        }
        if (has_pos and has_neg) return error.RangeError;

        if (@abs(years) > CALENDAR_UNIT_MAX) return error.RangeError;
        if (@abs(months) > CALENDAR_UNIT_MAX) return error.RangeError;
        if (@abs(weeks) > CALENDAR_UNIT_MAX) return error.RangeError;

        const total_ns = timePartNanoseconds(days, hours, minutes, seconds, milliseconds, microseconds, nanoseconds);
        if (total_ns > MAX_TIME_NS or total_ns < -MAX_TIME_NS) return error.RangeError;

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

    pub const Fields = struct {
        years: ?f64 = null,
        months: ?f64 = null,
        weeks: ?f64 = null,
        days: ?f64 = null,
        hours: ?f64 = null,
        minutes: ?f64 = null,
        seconds: ?f64 = null,
        milliseconds: ?f64 = null,
        microseconds: ?f64 = null,
        nanoseconds: ?f64 = null,
    };
    pub const FromInput = union(enum) { string: []const u8, value: Duration, fields: Fields };
    pub fn from(input: FromInput) TemporalError!Duration {
        return switch (input) {
            .string => |text| fromString(text),
            .value => |value| blk: {
                try value.validate();
                break :blk value;
            },
            .fields => |f| blk: {
                if (f.years == null and f.months == null and f.weeks == null and f.days == null and f.hours == null and f.minutes == null and f.seconds == null and f.milliseconds == null and f.microseconds == null and f.nanoseconds == null) return error.TypeError;
                break :blk init(f.years orelse 0, f.months orelse 0, f.weeks orelse 0, f.days orelse 0, f.hours orelse 0, f.minutes orelse 0, f.seconds orelse 0, f.milliseconds orelse 0, f.microseconds orelse 0, f.nanoseconds orelse 0);
            },
        };
    }
    fn fromString(text: []const u8) TemporalError!Duration {
        const raw = try duration_string.parseDuration(text);
        return init(raw.years, raw.months, raw.weeks, raw.days, raw.hours, raw.minutes, raw.seconds, raw.milliseconds, raw.microseconds, raw.nanoseconds);
    }

    /// Field overrides, re-validated the same way `init` does. A
    /// struct-of-optionals (not `PlainDate`/`PlainTime`'s positional
    /// `?i32` params) because 10 positional optionals would be unreadable
    /// and error-prone at call sites.
    pub fn with(self: Duration, overrides: struct {
        years: ?f64 = null,
        months: ?f64 = null,
        weeks: ?f64 = null,
        days: ?f64 = null,
        hours: ?f64 = null,
        minutes: ?f64 = null,
        seconds: ?f64 = null,
        milliseconds: ?f64 = null,
        microseconds: ?f64 = null,
        nanoseconds: ?f64 = null,
    }) TemporalError!Duration {
        if (overrides.years == null and overrides.months == null and overrides.weeks == null and overrides.days == null and overrides.hours == null and overrides.minutes == null and overrides.seconds == null and overrides.milliseconds == null and overrides.microseconds == null and overrides.nanoseconds == null) return error.TypeError;
        return init(
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
        const fields = [_]f64{ self.years, self.months, self.weeks, self.days, self.hours, self.minutes, self.seconds, self.milliseconds, self.microseconds, self.nanoseconds };
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
            .years = if (self.years == 0) 0 else -self.years,
            .months = if (self.months == 0) 0 else -self.months,
            .weeks = if (self.weeks == 0) 0 else -self.weeks,
            .days = if (self.days == 0) 0 else -self.days,
            .hours = if (self.hours == 0) 0 else -self.hours,
            .minutes = if (self.minutes == 0) 0 else -self.minutes,
            .seconds = if (self.seconds == 0) 0 else -self.seconds,
            .milliseconds = if (self.milliseconds == 0) 0 else -self.milliseconds,
            .microseconds = if (self.microseconds == 0) 0 else -self.microseconds,
            .nanoseconds = if (self.nanoseconds == 0) 0 else -self.nanoseconds,
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
    /// a nonzero year/month/week, `error.RangeError` (needs
    /// calendar-aware balancing -- Phase 3). Otherwise compares via the
    /// combined total-nanoseconds value.
    pub const RelativeTo = union(enum) { plainDate: plain_date.PlainDate, plainDateTime: plain_date_time.PlainDateTime, zonedDateTime: @import("zoned_date_time.zig").ZonedDateTime };
    pub const CompareOptions = struct { relativeTo: ?RelativeTo = null, allocator: std.mem.Allocator = std.heap.page_allocator, io: ?std.Io = null };
    pub const RoundOptions = struct { relativeTo: ?RelativeTo = null, largestUnit: ?rounding.Unit = null, smallestUnit: ?rounding.Unit = null, roundingIncrement: u32 = 1, roundingMode: rounding.RoundingMode = .halfExpand, allocator: std.mem.Allocator = std.heap.page_allocator, io: ?std.Io = null };
    pub const TotalOptions = struct { relativeTo: ?RelativeTo = null, unit: rounding.Unit, allocator: std.mem.Allocator = std.heap.page_allocator, io: ?std.Io = null };
    fn anchor(rt: RelativeTo, allocator: std.mem.Allocator, io: ?std.Io) TemporalError!plain_date_time.PlainDateTime {
        return switch (rt) {
            .plainDate => |value| .{ .date = value },
            .plainDateTime => |value| .{ .date = value.date },
            .zonedDateTime => |value| value.toPlainDateTime(allocator, io orelse return error.TypeError),
        };
    }
    fn endpoint(d: Duration, rt: RelativeTo, allocator: std.mem.Allocator, io: ?std.Io) TemporalError!i128 {
        const rel = @import("relative.zig");
        return switch (rt) {
            .zonedDateTime => |value| (try value.add(allocator, io orelse return error.TypeError, d, .constrain)).epochNs,
            else => rel.epoch(try (try anchor(rt, allocator, io)).add(d, .constrain), .{}),
        };
    }
    pub fn compare(a: Duration, b: Duration, options: CompareOptions) TemporalError!std.math.Order {
        try a.validate();
        try b.validate();
        if (fieldsEqual(a, b)) return .eq;
        if (options.relativeTo) |rt| return std.math.order(try endpoint(a, rt, options.allocator, options.io), try endpoint(b, rt, options.allocator, options.io));
        if (a.hasCalendarUnits() or b.hasCalendarUnits()) return error.RangeError;
        return std.math.order(a.totalTimeNanoseconds(), b.totalTimeNanoseconds());
    }

    /// `error.RangeError` if `self` or `other` has a nonzero year/
    /// month/week (real Temporal's unconditional restriction -- not
    /// resolvable with any `relativeTo`). Otherwise balances the time-part
    /// fields up through `min(largestUnitRank(self), largestUnitRank(other))`
    /// (i.e. the more-significant of the two operands' largest present
    /// unit) -- ground-truthed: `25h+3h="PT28H"` (no promotion to days,
    /// neither operand had a days field) vs. `1d+30h="P2DT6H"` (promoted,
    /// since one operand did).
    fn validate(self: Duration) TemporalError!void {
        _ = try init(self.years, self.months, self.weeks, self.days, self.hours, self.minutes, self.seconds, self.milliseconds, self.microseconds, self.nanoseconds);
    }
    pub fn add(self: Duration, other: Duration) TemporalError!Duration {
        try self.validate();
        try other.validate();
        if (self.hasCalendarUnits() or other.hasCalendarUnits()) return error.RangeError;
        const na = timePartNanoseconds(self.days, self.hours, self.minutes, self.seconds, self.milliseconds, self.microseconds, self.nanoseconds);
        const nb = timePartNanoseconds(other.days, other.hours, other.minutes, other.seconds, other.milliseconds, other.microseconds, other.nanoseconds);
        const target_rank = @min(self.largestUnitRank(), other.largestUnitRank());
        return fromNanosecondsAtRank(na + nb, target_rank);
    }

    pub fn subtract(self: Duration, other: Duration) TemporalError!Duration {
        return self.add(other.negated());
    }

    /// The largest unit (year..nanosecond) with a nonzero field, or
    /// `.nanosecond` if `self.blank()`. Used by `round`/`.total` to
    /// auto-resolve `largestUnit` when the caller only supplies
    /// `smallestUnit` -- ground-truthed that this (not a fixed per-type
    /// default, unlike `until`/`since`) is what real Temporal does.
    fn largestPresentUnit(self: Duration) rounding.Unit {
        if (self.years != 0) return .year;
        if (self.months != 0) return .month;
        if (self.weeks != 0) return .week;
        if (self.days != 0) return .day;
        if (self.hours != 0) return .hour;
        if (self.minutes != 0) return .minute;
        if (self.seconds != 0) return .second;
        if (self.milliseconds != 0) return .millisecond;
        if (self.microseconds != 0) return .microsecond;
        return .nanosecond;
    }

    /// `largestUnit` when omitted: the caller's explicit `smallestUnit` if
    /// it's COARSER than `self`'s own largest field (ground-truthed:
    /// `{hours:25,minutes:30}.round({smallestUnit:"day"})` -> `P1D`, a
    /// flat single unit, not `self`'s own `hour`); otherwise `self`'s own
    /// largest field (ground-truthed: `{years:1,months:6}.round({
    /// smallestUnit:"day",...})` -> `P1Y6M`, keeping `year`).
    fn resolvedLargestForRound(self: Duration, options: rounding.RoundOptions) rounding.Unit {
        if (options.largestUnit) |lu| return lu;
        const self_largest = self.largestPresentUnit();
        if (options.smallestUnit) |su| {
            return if (@backingInt(su) < @backingInt(self_largest)) su else self_largest;
        }
        return self_largest;
    }

    fn isCalendarOnlyUnit(u: rounding.Unit) bool {
        return u == .year or u == .month or u == .week;
    }

    /// `relativeTo` is mandatory whenever a year/month/week unit is
    /// INVOLVED, whether that's a field already present on `self` or one
    /// of the requested `largest`/`smallest` units -- ground-truthed:
    /// `{hours:100}.round({smallestUnit:"week"})` (no calendar field on
    /// `self` at all) still throws without `relativeTo`, since weeks
    /// (unlike day and finer) aren't a fixed length relative to a
    /// calendar-free instant.
    fn requiresRelativeTo(self: Duration, largest: rounding.Unit, smallest: rounding.Unit) bool {
        return self.hasCalendarUnits() or isCalendarOnlyUnit(largest) or isCalendarOnlyUnit(smallest);
    }

    fn rankFromUnit(unit: rounding.Unit) u8 {
        return switch (unit) {
            .day => 0,
            .hour => 1,
            .minute => 2,
            .second => 3,
            .millisecond => 4,
            .microsecond => 5,
            .nanosecond => 6,
            else => unreachable,
        };
    }

    fn nsPerUnitFor(unit: rounding.Unit) i128 {
        return switch (unit) {
            .week => 7 * NS_PER_DAY,
            .day => NS_PER_DAY,
            .hour => 3_600_000_000_000,
            .minute => 60_000_000_000,
            .second => 1_000_000_000,
            .millisecond => 1_000_000,
            .microsecond => 1_000,
            .nanosecond => 1,
            else => unreachable,
        };
    }

    /// `total_ns` rounded to `target_rank`'s unit, then decomposed the
    /// same way `add`/`subtract` already do via `fromNanosecondsAtRank`.
    fn fromNanosecondsAtRankRounded(total_ns: i128, target_rank: u8, increment: u32, mode: rounding.RoundingMode) TemporalError!Duration {
        const denom = rankDenom(target_rank);
        const rounded_units = rounding.roundRatioToIncrement(total_ns, denom, increment, mode);
        return fromNanosecondsAtRank(rounded_units * denom, target_rank);
    }

    fn rankDenom(rank: u8) i128 {
        return switch (rank) {
            0 => NS_PER_DAY,
            1 => 3_600_000_000_000,
            2 => 60_000_000_000,
            3 => 1_000_000_000,
            4 => 1_000_000,
            5 => 1_000,
            else => 1,
        };
    }

    /// Rounds to `options.smallestUnit`/`.largestUnit` (at least one
    /// required). Ground-truthed real Temporal's actual composition
    /// whenever a year/month/week unit is involved: `round` with
    /// `relativeTo` is exactly `relativeTo-at-midnight.until(
    /// relativeTo-at-midnight.add(self), options)` -- confirmed including
    /// the mixed calendar+time case (`{years:1,hours:30}.round({
    /// smallestUnit:"hour", relativeTo:"2024-01-01"})` -> `P1Y1DT6H`,
    /// which needs `PlainDateTime`'s balance, not a bare `PlainDate`'s --
    /// so this always anchors at midnight via `PlainDateTime`, never
    /// `PlainDate` directly, even for a calendar-only duration (degrades
    /// to the same result either way there). No `relativeTo` needed (and
    /// none used, even if supplied) when neither the duration's own
    /// fields nor the requested units involve year/month/week.
    pub fn round(self: Duration, options: RoundOptions) TemporalError!Duration {
        try self.validate();
        const ro: rounding.RoundOptions = .{ .largestUnit = options.largestUnit, .smallestUnit = options.smallestUnit, .roundingIncrement = options.roundingIncrement, .roundingMode = options.roundingMode };
        if (options.smallestUnit == null and options.largestUnit == null) return error.RangeError;
        const largest = self.resolvedLargestForRound(ro);
        const smallest = options.smallestUnit orelse .nanosecond;
        if (@backingInt(largest) > @backingInt(smallest)) return error.RangeError;
        try rounding.validateIncrement(smallest, options.roundingIncrement);
        if (options.relativeTo) |rt| {
            const start = try anchor(rt, options.allocator, options.io);
            const target = try endpoint(self, rt, options.allocator, options.io);
            const rel = @import("relative.zig");
            var ctx: rel.Context = .{ .allocator = options.allocator, .io = options.io };
            var end: plain_date_time.PlainDateTime = undefined;
            var origin: i128 = undefined;
            switch (rt) {
                .zonedDateTime => |value| {
                    ctx.zone = value.timeZoneId();
                    origin = value.epochNs;
                    end = try (try value.add(options.allocator, options.io.?, self, .constrain)).toPlainDateTime(options.allocator, options.io.?);
                },
                else => {
                    origin = try rel.epoch(start, .{});
                    end = try start.add(self, .constrain);
                },
            }
            return rel.difference(start, end, origin, target, .{ .largestUnit = largest, .smallestUnit = smallest, .roundingIncrement = options.roundingIncrement, .roundingMode = options.roundingMode }, ctx);
        }
        if (self.requiresRelativeTo(largest, smallest)) return error.RangeError;
        const quantum = nsPerUnitFor(smallest);
        const rounded = rounding.roundRatioToIncrement(self.totalTimeNanoseconds(), quantum, options.roundingIncrement, options.roundingMode) * quantum;
        return fromNanosecondsAtRank(rounded, rankFromUnit(largest));
    }
    pub fn total(self: Duration, options: TotalOptions) TemporalError!f64 {
        try self.validate();
        const rel = @import("relative.zig");
        if (options.relativeTo) |rt| {
            const start = try anchor(rt, options.allocator, options.io);
            const target = try endpoint(self, rt, options.allocator, options.io);
            var ctx: rel.Context = .{ .allocator = options.allocator, .io = options.io };
            var end: plain_date_time.PlainDateTime = undefined;
            var origin: i128 = undefined;
            switch (rt) {
                .zonedDateTime => |value| {
                    ctx.zone = value.timeZoneId();
                    origin = value.epochNs;
                    end = try (try value.add(options.allocator, options.io.?, self, .constrain)).toPlainDateTime(options.allocator, options.io.?);
                },
                else => {
                    origin = try rel.epoch(start, .{});
                    end = try start.add(self, .constrain);
                },
            }
            return rel.total(start, end, origin, target, options.unit, ctx);
        }
        if (self.hasCalendarUnits() or isCalendarOnlyUnit(options.unit)) return error.RangeError;
        return @floatCast(@as(f128, @floatFromInt(self.totalTimeNanoseconds())) / @as(f128, @floatFromInt(nsPerUnitFor(options.unit))));
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
    pub fn toLocaleString(self: Duration, allocator: std.mem.Allocator, locales: ?[]const u8, options: @import("locale.zig").DurationLocaleOptions) TemporalError![]u8 {
        return @import("locale.zig").duration(allocator, locales, .{ self.years, self.months, self.weeks, self.days, self.hours, self.minutes, self.seconds, self.milliseconds, self.microseconds, self.nanoseconds }, options);
    }
    pub fn toString(self: Duration, allocator: std.mem.Allocator, options: StringOptions) TemporalError![]u8 {
        try self.validate();
        const p = try @import("format_options.zig").precision(options);
        if (p.minute) return error.RangeError;
        var value = self;
        if (options.smallestUnit != null or options.fractionalSecondDigits != null) {
            const ns = integer(self.seconds) * 1_000_000_000 + integer(self.milliseconds) * 1_000_000 + integer(self.microseconds) * 1_000 + integer(self.nanoseconds);
            const unit = @import("plain_time.zig").nsPerUnit(p.unit);
            const rounded = rounding.roundRatioToIncrement(ns, unit, p.increment, options.roundingMode) * unit;
            value.seconds = @floatFromInt(@divTrunc(rounded, 1_000_000_000));
            value.milliseconds = 0;
            value.microseconds = 0;
            value.nanoseconds = @floatFromInt(@rem(rounded, 1_000_000_000));
        }
        const raw = try value.formatDefault(allocator);
        defer allocator.free(raw);
        const digits = p.digits orelse return allocator.dupe(u8, raw);
        const s_index = std.mem.lastIndexOfScalar(u8, raw, 'S');
        const prefix = raw;
        if (s_index) |end| {
            var first = end;
            while (first > 0 and (std.ascii.isDigit(raw[first - 1]) or raw[first - 1] == '.')) first -= 1;
            const dot = std.mem.indexOfScalar(u8, raw[first..end], '.');
            const whole_end = if (dot) |i| first + i else end;
            if (digits == 0) return allocator.print("{s}S", .{raw[0..whole_end]});
            var frac: [9]u8 = @splat('0');
            if (dot) |_| {
                const count = @min(end - whole_end - 1, 9);
                @memcpy(frac[0..count], raw[whole_end + 1 .. whole_end + 1 + count]);
            }
            return allocator.print("{s}.{s}S", .{ raw[0..whole_end], frac[0..digits] });
        }
        var zeros: [9]u8 = @splat('0');
        if (digits == 0) return allocator.print("{s}{s}0S", .{ prefix, if (std.mem.indexOfScalar(u8, prefix, 'T') == null) "T" else "" });
        return allocator.print("{s}{s}0.{s}S", .{ prefix, if (std.mem.indexOfScalar(u8, prefix, 'T') == null) "T" else "", zeros[0..digits] });
    }
    pub fn toJSON(self: Duration, allocator: std.mem.Allocator) TemporalError![]u8 {
        return self.toString(allocator, .{});
    }
    pub const StringOptions = @import("format_options.zig").StringOptions;
    fn formatDefault(self: Duration, allocator: std.mem.Allocator) ![]u8 {
        const combined_ns: i128 = integer(self.milliseconds) * 1_000_000 + integer(self.microseconds) * 1_000 + integer(self.nanoseconds);
        const whole_seconds_carry: i128 = @intCast(@divTrunc(combined_ns, 1_000_000_000));
        const remainder_ns: i128 = @rem(combined_ns, 1_000_000_000);
        const display_seconds: i128 = integer(self.seconds) + whole_seconds_carry;

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

        if (self.years != 0) len += (std.fmt.bufPrint(buf[len..], "{d}Y", .{@abs(integer(self.years))}) catch unreachable).len;
        if (self.months != 0) len += (std.fmt.bufPrint(buf[len..], "{d}M", .{@abs(integer(self.months))}) catch unreachable).len;
        if (self.weeks != 0) len += (std.fmt.bufPrint(buf[len..], "{d}W", .{@abs(integer(self.weeks))}) catch unreachable).len;
        if (self.days != 0) len += (std.fmt.bufPrint(buf[len..], "{d}D", .{@abs(integer(self.days))}) catch unreachable).len;

        const has_time = self.hours != 0 or self.minutes != 0 or display_seconds != 0 or frac.len != 0;
        if (has_time) {
            buf[len] = 'T';
            len += 1;
            if (self.hours != 0) len += (std.fmt.bufPrint(buf[len..], "{d}H", .{@abs(integer(self.hours))}) catch unreachable).len;
            if (self.minutes != 0) len += (std.fmt.bufPrint(buf[len..], "{d}M", .{@abs(integer(self.minutes))}) catch unreachable).len;
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
/// `init`'s validation, `compare`, and `add`.
fn timePartNanoseconds(days: f64, hours: f64, minutes: f64, seconds: f64, milliseconds: f64, microseconds: f64, nanoseconds: f64) i128 {
    return integer(days) * 86_400_000_000_000 +
        integer(hours) * 3_600_000_000_000 +
        integer(minutes) * 60_000_000_000 +
        integer(seconds) * 1_000_000_000 +
        integer(milliseconds) * 1_000_000 +
        integer(microseconds) * 1_000 +
        integer(nanoseconds);
}

/// Inverse of `timePartNanoseconds`, but stopping the "days/hours/.../ns"
/// decomposition early at `target_rank` (0=days..6=nanoseconds): every
/// unit at or below `target_rank` is extracted at its natural size: the
/// field AT `target_rank` absorbs everything larger than it instead of
/// being further carried up (this is `add`/`subtract`'s balancing rule).
fn fromNanosecondsAtRank(total_ns: i128, target_rank: u8) TemporalError!Duration {
    // Exact internal decomposition; init performs the observable Number conversion.
    if (total_ns < -MAX_TIME_NS or total_ns > MAX_TIME_NS) return error.RangeError;
    var remaining = total_ns;
    var days: i128 = 0;
    var hours: i128 = 0;
    var minutes: i128 = 0;
    var seconds: i128 = 0;
    var milliseconds: i128 = 0;
    var microseconds: i128 = 0;

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
    const nanoseconds: i128 = remaining;

    return Duration.init(0, 0, 0, days, hours, minutes, seconds, milliseconds, microseconds, nanoseconds);
}

test "init: sign consistency" {
    try std.testing.expectError(error.RangeError, Duration.init(-1, 1, 0, 0, 0, 0, 0, 0, 0, 0));
    _ = try Duration.init(-1, -2, 0, 0, -3, 0, 0, 0, 0, 0);
}

test "init: calendar-unit bound is exactly 2^32-1" {
    _ = try Duration.init(4_294_967_295, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    try std.testing.expectError(error.RangeError, Duration.init(4_294_967_296, 0, 0, 0, 0, 0, 0, 0, 0, 0));
}

test "init: time-part total-nanoseconds bound matches bisected Node boundaries" {
    _ = try Duration.init(0, 0, 0, 104_249_991_374, 0, 0, 0, 0, 0, 0);
    try std.testing.expectError(error.RangeError, Duration.init(0, 0, 0, 104_249_991_375, 0, 0, 0, 0, 0, 0));
    _ = try Duration.init(0, 0, 0, 0, 2_501_999_792_983, 0, 0, 0, 0, 0);
    try std.testing.expectError(error.RangeError, Duration.init(0, 0, 0, 0, 2_501_999_792_984, 0, 0, 0, 0, 0));
    _ = try Duration.init(0, 0, 0, 0, 0, 0, 9_007_199_254_740_991, 0, 0, 0);
    try std.testing.expectError(error.RangeError, Duration.init(0, 0, 0, 0, 0, 0, 9_007_199_254_740_992, 0, 0, 0));
}

test "sign / blank" {
    const blank_d = try Duration.init(0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    try std.testing.expect(blank_d.blank());
    try std.testing.expectEqual(@as(i8, 0), blank_d.sign());
    const pos = try Duration.init(1, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(i8, 1), pos.sign());
    const neg = try Duration.init(-1, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(i8, -1), neg.sign());
}

test "negated / abs" {
    const d = try Duration.init(1, 2, 0, 3, 0, 0, 0, 0, 0, 0);
    const n = d.negated();
    try std.testing.expectEqual(@as(i64, -1), n.years);
    try std.testing.expectEqual(@as(i64, -2), n.months);
    const a = (try Duration.init(-1, -2, 0, -3, 0, 0, 0, 0, 0, 0)).abs();
    try std.testing.expectEqual(@as(i64, 1), a.years);
}

test "compare: equal fields is a fast path even with calendar units" {
    const a = try Duration.init(1, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(std.math.Order.eq, try Duration.compare(a, a, .{}));
}

test "compare: calendar units on either side (not equal) needs relativeTo" {
    const a = try Duration.init(2, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    const b = try Duration.init(1, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    try std.testing.expectError(error.RangeError, Duration.compare(a, b, .{}));
}

test "compare: non-calendar durations compare by total nanoseconds" {
    const a = try Duration.init(0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    const b = try Duration.init(0, 0, 0, 1, 0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(std.math.Order.lt, try Duration.compare(a, b, .{}));
}

test "add/subtract: throws on any calendar-unit operand, no exception for relativeTo" {
    const y = try Duration.init(1, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    const d = try Duration.init(0, 0, 0, 1, 0, 0, 0, 0, 0, 0);
    try std.testing.expectError(error.RangeError, Duration.add(y, d));
    try std.testing.expectError(error.RangeError, Duration.subtract(y, d));
}

test "add: no promotion when neither operand has the larger unit" {
    const a = try Duration.init(0, 0, 0, 0, 25, 0, 0, 0, 0, 0);
    const b = try Duration.init(0, 0, 0, 0, 3, 0, 0, 0, 0, 0);
    const r = try Duration.add(a, b);
    try std.testing.expectEqual(@as(i64, 0), r.days);
    try std.testing.expectEqual(@as(i64, 28), r.hours);
}

test "add: promotion when one operand has the larger unit" {
    const a = try Duration.init(0, 0, 0, 1, 0, 0, 0, 0, 0, 0);
    const b = try Duration.init(0, 0, 0, 0, 30, 0, 0, 0, 0, 0);
    const r = try Duration.add(a, b);
    try std.testing.expectEqual(@as(i64, 2), r.days);
    try std.testing.expectEqual(@as(i64, 6), r.hours);
}

test "subtract: can produce a negative result" {
    const a = try Duration.init(0, 0, 0, 0, 1, 0, 0, 0, 0, 0);
    const b = try Duration.init(0, 0, 0, 0, 5, 0, 0, 0, 0, 0);
    const r = try Duration.subtract(a, b);
    try std.testing.expectEqual(@as(i64, -4), r.hours);
}

test "toString matches real Node byte-for-byte" {
    const allocator = std.testing.allocator;
    {
        const d = try Duration.init(1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
        const s = try d.toString(allocator, .{});
        defer allocator.free(s);
        try std.testing.expectEqualStrings("P1Y2M3W4DT5H6M7.00800901S", s);
    }
    {
        const d = try Duration.init(0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        const s = try d.toString(allocator, .{});
        defer allocator.free(s);
        try std.testing.expectEqualStrings("PT0S", s);
    }
    {
        const d = try Duration.init(-1, -2, 0, 0, -3, 0, 0, 0, 0, 0);
        const s = try d.toString(allocator, .{});
        defer allocator.free(s);
        try std.testing.expectEqualStrings("-P1Y2MT3H", s);
    }
    {
        const d = try Duration.init(0, 0, 0, 0, 0, 0, 0, 0, 0, -5);
        const s = try d.toString(allocator, .{});
        defer allocator.free(s);
        try std.testing.expectEqualStrings("-PT0.000000005S", s);
    }
    {
        const d = try Duration.init(1, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        const s = try d.toString(allocator, .{});
        defer allocator.free(s);
        try std.testing.expectEqualStrings("P1Y", s);
    }
    {
        const d = try Duration.init(0, 0, 0, 0, 1, 0, 5, 0, 0, 0);
        const s = try d.toString(allocator, .{});
        defer allocator.free(s);
        try std.testing.expectEqualStrings("PT1H5S", s);
    }
    {
        const d = try Duration.init(0, 0, 0, 0, 0, 5, 0, 0, 0, 0);
        const s = try d.toString(allocator, .{});
        defer allocator.free(s);
        try std.testing.expectEqualStrings("PT5M", s);
    }
    {
        // ms=5000 displays as "PT5S" without mutating the stored field.
        const d = try Duration.init(0, 0, 0, 0, 0, 0, 0, 5000, 0, 0);
        const s = try d.toString(allocator, .{});
        defer allocator.free(s);
        try std.testing.expectEqualStrings("PT5S", s);
        try std.testing.expectEqual(@as(i64, 5000), d.milliseconds);
    }
}

test "fromString round-trips" {
    const d = try Duration.from(.{ .string = "P1Y2M3W4DT5H6M7.5S" });
    try std.testing.expectEqual(@as(i64, 1), d.years);
    try std.testing.expectEqual(@as(i64, 500), d.milliseconds);
}

pub fn validate(value: Duration) TemporalError!void {
    try value.validate();
}
