//! `Temporal.Instant`, an exact-time scalar (epoch nanoseconds) -- no
//! calendar involvement at all (Phase 5). Ground-truthed to reject ANY
//! nonzero `years`/`months`/`weeks`/`days` on `add`/`subtract` (not just
//! calendar units like `Duration.add` already does) and to restrict
//! `until`/`since`/`round` to hour..nanosecond units, so this reuses
//! `plain_time.zig`'s `decomposeTimeDiff`/`nsPerUnit` (Phase 3b) directly
//! -- no new balance algorithm needed anywhere in this file.
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
    epoch_nanoseconds: i128,

    pub fn fromEpochNanoseconds(ns: i128) TemporalError!Instant {
        if (ns < MIN_EPOCH_NS or ns > MAX_EPOCH_NS) return error.InvalidRange;
        return .{ .epoch_nanoseconds = ns };
    }

    pub fn fromEpochMilliseconds(ms: i64) TemporalError!Instant {
        return fromEpochNanoseconds(@as(i128, ms) * 1_000_000);
    }

    /// Ground-truthed: requires an offset (`Z` or signed
    /// `HH:MM[:SS[.fraction]]`, applied to compute the correct UTC value)
    /// and never validates a calendar annotation, unlike every other
    /// `parseIso` in this repo -- see `iso_string.parseInstant`'s doc
    /// comment for the full derivation.
    pub fn parseIso(text: []const u8) TemporalError!Instant {
        const parsed = try iso_string.parseInstant(text);
        if (parsed.date.month < 1 or parsed.date.month > 12) return error.InvalidFormat;
        if (parsed.date.day < 1 or parsed.date.day > iso_calendar.daysInMonth(parsed.date.year, parsed.date.month)) return error.InvalidFormat;
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
        return self.epoch_nanoseconds;
    }

    /// Floors, not truncates -- ground-truthed:
    /// `fromEpochNanoseconds(-1_500_000).epochMilliseconds` -> `-2`.
    pub fn epochMilliseconds(self: Instant) i64 {
        return @intCast(@divFloor(self.epoch_nanoseconds, 1_000_000));
    }

    pub fn compare(a: Instant, b: Instant) std.math.Order {
        return std.math.order(a.epoch_nanoseconds, b.epoch_nanoseconds);
    }

    pub fn equals(a: Instant, b: Instant) bool {
        return a.epoch_nanoseconds == b.epoch_nanoseconds;
    }

    /// Ground-truthed to reject ANY nonzero `years`/`months`/`weeks`/
    /// `days` (not just calendar units like `Duration.add` already does
    /// -- `{days:1}` alone throws "Largest unit cannot be a date unit").
    pub fn add(self: Instant, d: Duration) TemporalError!Instant {
        if (d.years != 0 or d.months != 0 or d.weeks != 0 or d.days != 0) return error.InvalidRange;
        const delta: i128 = @as(i128, d.hours) * 3_600_000_000_000 +
            @as(i128, d.minutes) * 60_000_000_000 +
            @as(i128, d.seconds) * 1_000_000_000 +
            @as(i128, d.milliseconds) * 1_000_000 +
            @as(i128, d.microseconds) * 1_000 +
            d.nanoseconds;
        return fromEpochNanoseconds(self.epoch_nanoseconds + delta);
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
        const diff_ns: i128 = other.epoch_nanoseconds - self.epoch_nanoseconds;
        return plain_time.decomposeTimeDiff(diff_ns, resolved, options.rounding_increment, options.rounding_mode);
    }

    pub fn since(self: Instant, other: Instant, options: RoundingOptions) TemporalError!Duration {
        const resolved = try rounding.resolveInstantUnits(options);
        const diff_ns: i128 = self.epoch_nanoseconds - other.epoch_nanoseconds;
        return plain_time.decomposeTimeDiff(diff_ns, resolved, options.rounding_increment, options.rounding_mode);
    }

    /// `smallestUnit` required (no default), hour..nanosecond only.
    /// `roundingIncrement`'s cap is INCLUSIVE of the full cycle length
    /// here (`validateIncrementInclusive`) -- the headline difference
    /// from `PlainTime`/`PlainDateTime.round`, ground-truthed:
    /// `Instant` never wraps, so `hour:24` ("round to the nearest whole
    /// day-equivalent") is meaningful, unlike a wrapping clock value
    /// where the full cycle is degenerate.
    pub fn round(self: Instant, options: rounding.RoundOptions) TemporalError!Instant {
        const smallest = options.smallest_unit orelse return error.InvalidRange;
        if (!rounding.isTimeUnit(smallest)) return error.InvalidRange;
        try rounding.validateIncrementInclusive(smallest, options.rounding_increment);
        const unit_ns = plain_time.nsPerUnit(smallest);
        // Ground-truthed: the rounding mode is applied to the
        // NON-NEGATIVE time-of-day remainder after a floor-based
        // day split, not to the raw (possibly negative) epoch value
        // directly -- for a negative `epoch_nanoseconds`, applying
        // `trunc`/`expand` straight to it would round toward/away from
        // the 1970-01-01 epoch origin (an arbitrary reference point),
        // but real Temporal's `trunc` there actually matches `floor` and
        // `expand` matches `ceil` (confirmed: e.g. -1553797930615116916
        // rounded to the hour gives the SAME result for trunc and floor,
        // and the same result for expand and ceil) -- consistent with
        // rounding the always-non-negative time-of-day component, where
        // trunc/floor (and ceil/expand) trivially coincide.
        const day_boundary = @divFloor(self.epoch_nanoseconds, NS_PER_DAY) * NS_PER_DAY;
        const time_of_day = self.epoch_nanoseconds - day_boundary;
        const rounded_units = rounding.roundRatioToIncrement(time_of_day, unit_ns, options.rounding_increment, options.rounding_mode);
        return fromEpochNanoseconds(day_boundary + rounded_units * unit_ns);
    }

    /// `YYYY-MM-DDTHH:MM:SS[.fraction]Z` -- always UTC (`Z`); this repo
    /// doesn't implement arbitrary-offset output (no `ZonedDateTime`
    /// yet, matches the project's existing no-JS-options-object stance).
    pub fn toIsoString(self: Instant, allocator: std.mem.Allocator) ![]u8 {
        const epoch_day: i64 = @intCast(@divFloor(self.epoch_nanoseconds, NS_PER_DAY));
        const ns_of_day: u64 = @intCast(@mod(self.epoch_nanoseconds, NS_PER_DAY));
        const ymd = iso_calendar.fromEpochDay(epoch_day);
        const time = plain_time.PlainTime.fromNanosecondsOfDay(ns_of_day);

        var year_buf: [8]u8 = undefined;
        const year_str = iso_string.formatYear(&year_buf, ymd.year);
        var frac_buf: [10]u8 = undefined;
        const frac = iso_string.formatFractionalSeconds(&frac_buf, time.millisecond, time.microsecond, time.nanosecond);
        return std.fmt.allocPrint(allocator, "{s}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{s}Z", .{
            year_str, ymd.month, ymd.day, time.hour, time.minute, time.second, frac,
        });
    }

    /// Closes out the deferred item noted in this file's Phase 5 doc
    /// comment: pairs this exact instant with a time zone -- trivial, no
    /// disambiguation needed (an `Instant` is already exact).
    pub fn toZonedDateTimeISO(self: Instant, allocator: std.mem.Allocator, io: std.Io, time_zone_id: []const u8) TemporalError!zoned_date_time.ZonedDateTime {
        return zoned_date_time.ZonedDateTime.create(allocator, io, self.epoch_nanoseconds, time_zone_id);
    }
};

test "fromEpochMilliseconds/fromEpochNanoseconds: range boundaries" {
    _ = try Instant.fromEpochNanoseconds(MAX_EPOCH_NS);
    try std.testing.expectError(error.InvalidRange, Instant.fromEpochNanoseconds(MAX_EPOCH_NS + 1));
    _ = try Instant.fromEpochNanoseconds(MIN_EPOCH_NS);
    try std.testing.expectError(error.InvalidRange, Instant.fromEpochNanoseconds(MIN_EPOCH_NS - 1));
}

test "epochMilliseconds floors a sub-millisecond negative value" {
    const i = try Instant.fromEpochNanoseconds(-1_500_000);
    try std.testing.expectEqual(@as(i64, -2), i.epochMilliseconds());
}

test "add/subtract: rejects any nonzero years/months/weeks/days" {
    const i = try Instant.fromEpochMilliseconds(0);
    try std.testing.expectError(error.InvalidRange, i.add(try Duration.create(0, 0, 0, 1, 0, 0, 0, 0, 0, 0)));
    try std.testing.expectError(error.InvalidRange, i.add(try Duration.create(0, 0, 0, 1, 5, 0, 0, 0, 0, 0)));
    const r = try i.add(try Duration.create(0, 0, 0, 0, 5, 0, 0, 0, 0, 0));
    try std.testing.expectEqual(@as(i128, 5 * 3_600_000_000_000), r.epoch_nanoseconds);
}

test "until/since: default largestUnit is second, restricted to time units" {
    const a = try Instant.fromEpochMilliseconds(0);
    const b = try Instant.fromEpochMilliseconds(90_061_000);
    const allocator = std.testing.allocator;
    const d = try a.until(b, .{});
    const s = try d.toIsoString(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("PT90061S", s);
    try std.testing.expectError(error.InvalidRange, a.until(b, .{ .largest_unit = .day }));
}

test "round: inclusive increment cap (24 ok, 25 rejected) unlike PlainTime" {
    const i = try Instant.fromEpochMilliseconds(0);
    _ = try i.round(.{ .smallest_unit = .hour, .rounding_increment = 24 });
    try std.testing.expectError(error.InvalidRange, i.round(.{ .smallest_unit = .hour, .rounding_increment = 25 }));
}

test "round: default mode is halfExpand" {
    const i = try Instant.fromEpochMilliseconds(30 * 60 * 1000);
    const r = try i.round(.{ .smallest_unit = .hour });
    try std.testing.expectEqual(@as(i128, 3_600_000_000_000), r.epoch_nanoseconds);
}

test "parseIso: requires an offset, applies it, ignores calendar annotation validation" {
    const a = try Instant.parseIso("2024-01-01T00:00:15+00:00:15");
    const b = try Instant.parseIso("2024-01-01T00:00:00Z");
    try std.testing.expect(Instant.equals(a, b));
    try std.testing.expectError(error.InvalidFormat, Instant.parseIso("2024-01-01T00:00:00"));
    _ = try Instant.parseIso("2024-01-01T00:00:00Z[u-ca=hebrew]");
    try std.testing.expectError(error.InvalidFormat, Instant.parseIso("2024-02-30T00:00:00Z"));
}

test "toIsoString round-trips through parseIso" {
    const allocator = std.testing.allocator;
    const i = try Instant.fromEpochNanoseconds(1_704_067_200_123_456_789);
    const s = try i.toIsoString(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("2024-01-01T00:00:00.123456789Z", s);
    const parsed = try Instant.parseIso(s);
    try std.testing.expect(Instant.equals(i, parsed));
}
