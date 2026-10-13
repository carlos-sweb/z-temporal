//! Temporal.Instant: exact epoch nanoseconds and time-unit arithmetic.
const std = @import("std");
const iso_calendar = @import("iso_calendar.zig");
const iso_string = @import("iso_string.zig");
const errors = @import("errors.zig");
const TemporalError = errors.TemporalError;
const duration_mod = @import("duration.zig");
const Duration = duration_mod.Duration;
const plain_time = @import("plain_time.zig");
const rounding = @import("rounding.zig");
const RoundingOptions = rounding.RoundingOptions;
const zoned_date_time = @import("zoned_date_time.zig");

const NS_PER_DAY: i128 = 86_400_000_000_000;

/// `±8_640_000_000_000_000_000_000` ns -- ground-truthed against real
/// Node's exact `Instant` boundaries (`+275760-09-13T00:00:00Z` /
/// `-271821-04-20T00:00:00Z`), one ns past either end throws "Nanoseconds
/// out of range".
pub const MIN_EPOCH_NS: i128 = -8_640_000_000_000_000_000_000;
pub const MAX_EPOCH_NS: i128 = 8_640_000_000_000_000_000_000;

pub const Instant = struct {
    epochNs: i128,

    pub fn fromEpochNanoseconds(ns: i128) TemporalError!Instant {
        if (ns < MIN_EPOCH_NS or ns > MAX_EPOCH_NS) return error.RangeError;
        return .{ .epochNs = ns };
    }

    pub fn fromEpochMilliseconds(ms: i64) TemporalError!Instant {
        return fromEpochNanoseconds(@as(i128, ms) * 1_000_000);
    }

    /// Ground-truthed: requires an offset (`Z` or signed
    /// `HH:MM[:SS[.fraction]]`, applied to compute the correct UTC value)
    /// and never validates a calendar annotation, unlike every other
    /// `fromString` in this repo -- see `iso_string.parseInstant`'s doc
    /// comment for the full derivation.
    pub const FromInput = union(enum) { string: []const u8, value: Instant };
    pub fn from(input: FromInput) TemporalError!Instant {
        return switch (input) {
            .string => |text| fromString(text),
            .value => |value| fromEpochNanoseconds(value.epochNs),
        };
    }
    pub fn init(ns: i128) TemporalError!Instant {
        return fromEpochNanoseconds(ns);
    }

    fn fromString(text: []const u8) TemporalError!Instant {
        const parsed = try iso_string.parseInstant(text);
        if (parsed.date.month < 1 or parsed.date.month > 12) return error.RangeError;
        if (parsed.date.day < 1 or parsed.date.day > iso_calendar.daysInMonth(parsed.date.year, parsed.date.month)) return error.RangeError;
        const epoch_day = iso_calendar.toEpochDay(parsed.date.year, parsed.date.month, parsed.date.day);
        const time_ns: i128 = @as(i128, parsed.time.hour) * 3_600_000_000_000 +
            @as(i128, parsed.time.minute) * 60_000_000_000 +
            @as(i128, parsed.time.second) * 1_000_000_000 +
            @as(i128, parsed.time.millisecond) * 1_000_000 +
            @as(i128, parsed.time.microsecond) * 1_000 +
            parsed.time.nanosecond;
        const total_ns = @as(i128, epoch_day) * NS_PER_DAY + time_ns - parsed.offset_nanoseconds;
        return fromEpochNanoseconds(total_ns);
    }

    pub fn epochNanoseconds(self: Instant) i128 {
        return self.epochNs;
    }

    /// Floors, not truncates -- ground-truthed:
    /// `fromEpochNanoseconds(-1_500_000).epochMilliseconds` -> `-2`.
    pub fn epochMilliseconds(self: Instant) i64 {
        return @intCast(@divFloor(self.epochNs, 1_000_000));
    }

    pub fn compare(a: Instant, b: Instant) std.math.Order {
        return std.math.order(a.epochNs, b.epochNs);
    }

    pub fn equals(a: Instant, b: Instant) bool {
        return a.epochNs == b.epochNs;
    }

    /// Ground-truthed to reject ANY nonzero `years`/`months`/`weeks`/
    /// `days` (not just calendar units like `Duration.add` already does
    /// -- `{days:1}` alone throws "Largest unit cannot be a date unit").
    pub fn add(self: Instant, d: Duration) TemporalError!Instant {
        try @import("duration.zig").validate(d);
        if (d.years != 0 or d.months != 0 or d.weeks != 0 or d.days != 0) return error.RangeError;
        const delta: i128 = @import("duration.zig").integer(d.hours) * 3_600_000_000_000 +
            @import("duration.zig").integer(d.minutes) * 60_000_000_000 +
            @import("duration.zig").integer(d.seconds) * 1_000_000_000 +
            @import("duration.zig").integer(d.milliseconds) * 1_000_000 +
            @import("duration.zig").integer(d.microseconds) * 1_000 +
            @import("duration.zig").integer(d.nanoseconds);
        return fromEpochNanoseconds(self.epochNs + delta);
    }

    pub fn subtract(self: Instant, d: Duration) TemporalError!Instant {
        return self.add(d.negated());
    }

    /// `largestUnit`/`smallestUnit` restricted to hour..nanosecond (day
    /// throws here too, unlike `PlainDateTime` -- ground-truthed "Unit
    /// was not part of the time unit group"). Reuses
    /// `plain_time.decomposeTimeDiff` directly -- no calendar complexity
    /// at all, same shape as `PlainTime.until`.
    pub fn until(self: Instant, other: Instant, options: RoundingOptions) TemporalError!Duration {
        const resolved = try rounding.resolveInstantUnits(options);
        const diff_ns: i128 = other.epochNs - self.epochNs;
        return plain_time.decomposeTimeDiff(diff_ns, resolved, options.roundingIncrement, options.roundingMode);
    }

    pub fn since(self: Instant, other: Instant, options: RoundingOptions) TemporalError!Duration {
        const resolved = try rounding.resolveInstantUnits(options);
        const diff_ns: i128 = self.epochNs - other.epochNs;
        return plain_time.decomposeTimeDiff(diff_ns, resolved, options.roundingIncrement, options.roundingMode);
    }

    /// `smallestUnit` required (no default), hour..nanosecond only.
    /// `roundingIncrement`'s cap is INCLUSIVE of the full cycle length
    /// here (`validateIncrementInclusive`) -- the headline difference
    /// from `PlainTime`/`PlainDateTime.round`, ground-truthed:
    /// `Instant` never wraps, so `hour:24` ("round to the nearest whole
    /// day-equivalent") is meaningful, unlike a wrapping clock value
    /// where the full cycle is degenerate.
    pub fn round(self: Instant, options: rounding.RoundOptions) TemporalError!Instant {
        const smallest = options.smallestUnit orelse return error.RangeError;
        if (!rounding.isTimeUnit(smallest)) return error.RangeError;
        try rounding.validateIncrementInclusive(smallest, options.roundingIncrement);
        const unit_ns = plain_time.nsPerUnit(smallest);
        // Ground-truthed: the rounding mode is applied to the
        // NON-NEGATIVE time-of-day remainder after a floor-based
        // day split, not to the raw (possibly negative) epoch value
        // directly -- for a negative `epochNs`, applying
        // `trunc`/`expand` straight to it would round toward/away from
        // the 1970-01-01 epoch origin (an arbitrary reference point),
        // but real Temporal's `trunc` there actually matches `floor` and
        // `expand` matches `ceil` (confirmed: e.g. -1553797930615116916
        // rounded to the hour gives the SAME result for trunc and floor,
        // and the same result for expand and ceil) -- consistent with
        // rounding the always-non-negative time-of-day component, where
        // trunc/floor (and ceil/expand) trivially coincide.
        const day_boundary = @divFloor(self.epochNs, NS_PER_DAY) * NS_PER_DAY;
        const time_of_day = self.epochNs - day_boundary;
        const rounded_units = rounding.roundRatioToIncrement(time_of_day, unit_ns, options.roundingIncrement, options.roundingMode);
        return fromEpochNanoseconds(day_boundary + rounded_units * unit_ns);
    }

    /// Locale formatting requires the optional ICU backend.
    pub fn toLocaleString(self: Instant, allocator: std.mem.Allocator, io: std.Io, locales: ?[]const u8, options: @import("locale.zig").LocaleOptions) TemporalError![]u8 {
        return @import("locale.zig").format(allocator, io, .instant, @as(f64, @floatFromInt(self.epochMilliseconds())), .iso8601, null, locales, options);
    }
    pub fn toString(self: Instant, allocator: std.mem.Allocator, options: StringOptions) TemporalError![]u8 {
        if (options.timeZone) |zone| {
            const io = options.io orelse return error.TypeError;
            const fmt = @import("format_options.zig");
            const p = try fmt.precision(options);
            const rounded = try self.round(.{ .smallestUnit = p.unit, .roundingIncrement = p.increment, .roundingMode = options.roundingMode });
            const value = try rounded.toZonedDateTimeISO(allocator, io, zone);
            const raw = try value.toString(allocator, io, .{ .timeZoneName = .never });
            defer allocator.free(raw);
            return fmt.time(allocator, raw, p);
        }
        const fmt = @import("format_options.zig");
        const p = try fmt.precision(options);
        const value = try self.round(.{ .smallestUnit = p.unit, .roundingIncrement = p.increment, .roundingMode = options.roundingMode });
        const raw = try value.formatDefault(allocator);
        defer allocator.free(raw);
        const timed = try fmt.time(allocator, raw, p);
        defer allocator.free(timed);
        return fmt.calendar(allocator, timed, options.calendarName == .critical);
    }
    pub fn toJSON(self: Instant, allocator: std.mem.Allocator) TemporalError![]u8 {
        return self.toString(allocator, .{});
    }
    pub const StringOptions = @import("format_options.zig").StringOptions;
    fn formatDefault(self: Instant, allocator: std.mem.Allocator) ![]u8 {
        const epoch_day: i64 = @intCast(@divFloor(self.epochNs, NS_PER_DAY));
        const ns_of_day: u64 = @intCast(@mod(self.epochNs, NS_PER_DAY));
        const ymd = iso_calendar.fromEpochDay(epoch_day);
        const time = plain_time.PlainTime.fromNanosecondsOfDay(ns_of_day);

        var year_buf: [8]u8 = undefined;
        const year_str = iso_string.formatYear(&year_buf, ymd.year);
        var frac_buf: [10]u8 = undefined;
        const frac = iso_string.formatFractionalSeconds(&frac_buf, time.millisecond, time.microsecond, time.nanosecond);
        return allocator.print("{s}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{s}Z", .{
            year_str, ymd.month, ymd.day, time.hour, time.minute, time.second, frac,
        });
    }

    /// Closes out the deferred item noted in this file's Phase 5 doc
    /// comment: pairs this exact instant with a time zone -- trivial, no
    /// disambiguation needed (an `Instant` is already exact).
    pub fn toZonedDateTimeISO(self: Instant, allocator: std.mem.Allocator, io: std.Io, time_zone_id: []const u8) TemporalError!zoned_date_time.ZonedDateTime {
        return zoned_date_time.ZonedDateTime.init(allocator, io, self.epochNs, time_zone_id, null);
    }
};

test "fromEpochMilliseconds/fromEpochNanoseconds: range boundaries" {
    _ = try Instant.fromEpochNanoseconds(MAX_EPOCH_NS);
    try std.testing.expectError(error.RangeError, Instant.fromEpochNanoseconds(MAX_EPOCH_NS + 1));
    _ = try Instant.fromEpochNanoseconds(MIN_EPOCH_NS);
    try std.testing.expectError(error.RangeError, Instant.fromEpochNanoseconds(MIN_EPOCH_NS - 1));
}

test "epochMilliseconds floors a sub-millisecond negative value" {
    const i = try Instant.fromEpochNanoseconds(-1_500_000);
    try std.testing.expectEqual(@as(i64, -2), i.epochMilliseconds());
}

test "add/subtract: rejects any nonzero years/months/weeks/days" {
    const i = try Instant.fromEpochMilliseconds(0);
    try std.testing.expectError(error.RangeError, i.add(try Duration.init(0, 0, 0, 1, 0, 0, 0, 0, 0, 0)));
    try std.testing.expectError(error.RangeError, i.add(try Duration.init(0, 0, 0, 1, 5, 0, 0, 0, 0, 0)));
    const r = try i.add(try Duration.init(0, 0, 0, 0, 5, 0, 0, 0, 0, 0));
    try std.testing.expectEqual(@as(i128, 5 * 3_600_000_000_000), r.epochNs);
}

test "until/since: default largestUnit is second, restricted to time units" {
    const a = try Instant.fromEpochMilliseconds(0);
    const b = try Instant.fromEpochMilliseconds(90_061_000);
    const allocator = std.testing.allocator;
    const d = try a.until(b, .{});
    const s = try d.toString(allocator, .{});
    defer allocator.free(s);
    try std.testing.expectEqualStrings("PT90061S", s);
    try std.testing.expectError(error.RangeError, a.until(b, .{ .largestUnit = .day }));
}

test "round: inclusive increment cap (24 ok, 25 rejected) unlike PlainTime" {
    const i = try Instant.fromEpochMilliseconds(0);
    _ = try i.round(.{ .smallestUnit = .hour, .roundingIncrement = 24 });
    try std.testing.expectError(error.RangeError, i.round(.{ .smallestUnit = .hour, .roundingIncrement = 25 }));
}

test "round: default mode is halfExpand" {
    const i = try Instant.fromEpochMilliseconds(30 * 60 * 1000);
    const r = try i.round(.{ .smallestUnit = .hour });
    try std.testing.expectEqual(@as(i128, 3_600_000_000_000), r.epochNs);
}

test "fromString: requires an offset, applies it, ignores calendar annotation validation" {
    const a = try Instant.from(.{ .string = "2024-01-01T00:00:15+00:00:15" });
    const b = try Instant.from(.{ .string = "2024-01-01T00:00:00Z" });
    try std.testing.expect(Instant.equals(a, b));
    try std.testing.expectError(error.RangeError, Instant.from(.{ .string = "2024-01-01T00:00:00" }));
    _ = try Instant.from(.{ .string = "2024-01-01T00:00:00Z[u-ca=hebrew]" });
    try std.testing.expectError(error.RangeError, Instant.from(.{ .string = "2024-02-30T00:00:00Z" }));
}

test "toString round-trips through fromString" {
    const allocator = std.testing.allocator;
    const i = try Instant.fromEpochNanoseconds(1_704_067_200_123_456_789);
    const s = try i.toString(allocator, .{});
    defer allocator.free(s);
    try std.testing.expectEqualStrings("2024-01-01T00:00:00.123456789Z", s);
    const parsed = try Instant.from(.{ .string = s });
    try std.testing.expect(Instant.equals(i, parsed));
}
