//! Temporal.PlainTime: wall-clock time with nanosecond precision.
const std = @import("std");
const iso_string = @import("iso_string.zig");
const errors = @import("errors.zig");
const TemporalError = errors.TemporalError;
const Overflow = @import("plain_date.zig").Overflow;
const Duration = @import("duration.zig").Duration;
const rounding = @import("rounding.zig");
const RoundingOptions = rounding.RoundingOptions;

const NS_PER_DAY: u64 = 86_400_000_000_000;

fn clampField(value: i32, max: u16, overflow: Overflow) TemporalError!u16 {
    if (value < 0 or value > max) {
        if (overflow == .reject) return error.RangeError;
        return @intCast(std.math.clamp(value, 0, @as(i32, max)));
    }
    return @intCast(value);
}

pub fn nsPerUnit(unit: rounding.Unit) i128 {
    return switch (unit) {
        .hour => 3_600_000_000_000,
        .minute => 60_000_000_000,
        .second => 1_000_000_000,
        .millisecond => 1_000_000,
        .microsecond => 1_000,
        .nanosecond => 1,
        else => unreachable,
    };
}

/// Rounds `diff_ns` to `resolved.smallest` precision, then decomposes the
/// result from `resolved.largest` down to nanosecond -- the field AT
/// `resolved.largest` absorbs everything larger than it (never carries
/// into a coarser unit), matching `duration.zig`'s `fromNanosecondsAtRank`
/// shape. `pub` so `PlainDateTime.until`/`.since` (Phase 3b) can reuse it
/// directly for the flat, time-unit-`largestUnit` case.
pub fn decomposeTimeDiff(diff_ns: i128, resolved: rounding.ResolvedUnits, increment: u32, mode: rounding.RoundingMode) TemporalError!Duration {
    const smallest_ns = nsPerUnit(resolved.smallest);
    const rounded_units = rounding.roundRatioToIncrement(diff_ns, smallest_ns, increment, mode);
    var remaining: i128 = rounded_units * smallest_ns;

    var hours: i128 = 0;
    var minutes: i128 = 0;
    var seconds: i128 = 0;
    var milliseconds: i128 = 0;
    var microseconds: i128 = 0;

    const largest_rank = @backingInt(resolved.largest);
    if (largest_rank <= @backingInt(rounding.Unit.hour)) {
        hours = @intCast(@divTrunc(remaining, 3_600_000_000_000));
        remaining = @rem(remaining, 3_600_000_000_000);
    }
    if (largest_rank <= @backingInt(rounding.Unit.minute)) {
        minutes = @intCast(@divTrunc(remaining, 60_000_000_000));
        remaining = @rem(remaining, 60_000_000_000);
    }
    if (largest_rank <= @backingInt(rounding.Unit.second)) {
        seconds = @intCast(@divTrunc(remaining, 1_000_000_000));
        remaining = @rem(remaining, 1_000_000_000);
    }
    if (largest_rank <= @backingInt(rounding.Unit.millisecond)) {
        milliseconds = @intCast(@divTrunc(remaining, 1_000_000));
        remaining = @rem(remaining, 1_000_000);
    }
    if (largest_rank <= @backingInt(rounding.Unit.microsecond)) {
        microseconds = @intCast(@divTrunc(remaining, 1_000));
        remaining = @rem(remaining, 1_000);
    }
    const nanoseconds: i128 = @intCast(remaining);

    return Duration.init(0, 0, 0, 0, hours, minutes, seconds, milliseconds, microseconds, nanoseconds);
}

pub fn regulate(hour: i32, minute: i32, second: i32, millisecond: i32, microsecond: i32, nanosecond: i32, overflow: Overflow) TemporalError!PlainTime {
    return .{
        .hour = @intCast(try clampField(hour, 23, overflow)),
        .minute = @intCast(try clampField(minute, 59, overflow)),
        .second = @intCast(try clampField(second, 59, overflow)),
        .millisecond = try clampField(millisecond, 999, overflow),
        .microsecond = try clampField(microsecond, 999, overflow),
        .nanosecond = try clampField(nanosecond, 999, overflow),
    };
}

pub const PlainTime = struct {
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    millisecond: u16 = 0,
    microsecond: u16 = 0,
    nanosecond: u16 = 0,

    pub fn init(in_hour: i32, in_minute: i32, in_second: i32, in_millisecond: i32, in_microsecond: i32, in_nanosecond: i32) TemporalError!PlainTime {
        return regulate(in_hour, in_minute, in_second, in_millisecond, in_microsecond, in_nanosecond, .reject);
    }

    pub const Fields = struct {
        hour: ?i32 = null,
        minute: ?i32 = null,
        second: ?i32 = null,
        millisecond: ?i32 = null,
        microsecond: ?i32 = null,
        nanosecond: ?i32 = null,
    };
    pub const FromInput = union(enum) { string: []const u8, value: PlainTime, fields: Fields };
    pub const FromOptions = struct { overflow: Overflow = .constrain };
    pub fn from(input: FromInput, options: FromOptions) TemporalError!PlainTime {
        return switch (input) {
            .string => |text| fromString(text),
            .value => |value| value,
            .fields => |f| blk: {
                if (f.hour == null and f.minute == null and f.second == null and f.millisecond == null and f.microsecond == null and f.nanosecond == null) return error.TypeError;
                break :blk regulate(f.hour orelse 0, f.minute orelse 0, f.second orelse 0, f.millisecond orelse 0, f.microsecond orelse 0, f.nanosecond orelse 0, options.overflow);
            },
        };
    }

    fn fromString(text: []const u8) TemporalError!PlainTime {
        const parsed = try iso_string.parsePlainTime(text);
        return .{
            .hour = parsed.hour,
            .minute = parsed.minute,
            .second = parsed.second,
            .millisecond = parsed.millisecond,
            .microsecond = parsed.microsecond,
            .nanosecond = parsed.nanosecond,
        };
    }

    pub fn with(self: PlainTime, fields: Fields, options: FromOptions) TemporalError!PlainTime {
        return self.withInternal(fields.hour, fields.minute, fields.second, fields.millisecond, fields.microsecond, fields.nanosecond, options.overflow);
    }
    fn withInternal(self: PlainTime, hour: ?i32, minute: ?i32, second: ?i32, millisecond: ?i32, microsecond: ?i32, nanosecond: ?i32, overflow: Overflow) TemporalError!PlainTime {
        if (hour == null and minute == null and second == null and millisecond == null and microsecond == null and nanosecond == null) return error.TypeError;
        return regulate(
            hour orelse self.hour,
            minute orelse self.minute,
            second orelse self.second,
            millisecond orelse self.millisecond,
            microsecond orelse self.microsecond,
            nanosecond orelse self.nanosecond,
            overflow,
        );
    }

    pub fn totalNanoseconds(self: PlainTime) u64 {
        var t: u64 = self.hour;
        t = t * 60 + self.minute;
        t = t * 60 + self.second;
        t = t * 1000 + self.millisecond;
        t = t * 1000 + self.microsecond;
        t = t * 1000 + self.nanosecond;
        return t;
    }

    /// Inverse of `totalNanoseconds`. `ns` must already be a canonical
    /// `[0, 86_400_000_000_000)` time-of-day (callers -- `add`/`subtract`
    /// here and on `PlainDateTime` -- get there via `@mod`, never pass a
    /// raw signed/out-of-range value).
    pub fn fromNanosecondsOfDay(ns: u64) PlainTime {
        var remaining = ns;
        const nanosecond: u16 = @intCast(remaining % 1000);
        remaining /= 1000;
        const microsecond: u16 = @intCast(remaining % 1000);
        remaining /= 1000;
        const millisecond: u16 = @intCast(remaining % 1000);
        remaining /= 1000;
        const second: u8 = @intCast(remaining % 60);
        remaining /= 60;
        const minute: u8 = @intCast(remaining % 60);
        remaining /= 60;
        const hour: u8 = @intCast(remaining);
        return .{ .hour = hour, .minute = minute, .second = second, .millisecond = millisecond, .microsecond = microsecond, .nanosecond = nanosecond };
    }

    /// Pure modular arithmetic (mod 24h) -- silently ignores
    /// `d.years`/`.months`/`.weeks`/`.days` (no date component exists to
    /// apply them to, ground-truthed: `PlainTime.add({days:1})` behaves
    /// identically to not passing `days` at all) and takes no `overflow`
    /// parameter (wraparound can never produce an invalid state, so
    /// there's nothing to constrain/reject -- ground-truthed: passing
    /// `overflow: "reject"` in real Temporal never has any observable
    /// effect here).
    pub fn add(self: PlainTime, d: Duration) PlainTime {
        const combined: i128 = @as(i128, self.totalNanoseconds()) + d.totalTimeNanoseconds();
        const ns_of_day: u64 = @intCast(@mod(combined, @as(i128, NS_PER_DAY)));
        return fromNanosecondsOfDay(ns_of_day);
    }

    pub fn subtract(self: PlainTime, d: Duration) PlainTime {
        return self.add(d.negated());
    }

    /// Rounds to `options.smallestUnit` (required -- there's no natural
    /// finest-default for a single-value rounding, unlike `until`/`since`),
    /// wrapping mod-24h with no day-carry concept (`23:59:30` rounded to
    /// the nearest minute -> `00:00:00`), ground-truthed against real
    /// Node's default `roundingMode: "halfExpand"`.
    pub fn round(self: PlainTime, options: rounding.RoundOptions) TemporalError!PlainTime {
        const smallest = options.smallestUnit orelse return error.RangeError;
        if (!rounding.isTimeUnit(smallest)) return error.RangeError;
        try rounding.validateIncrement(smallest, options.roundingIncrement);
        const smallest_ns = nsPerUnit(smallest);
        const rounded_units = rounding.roundRatioToIncrement(self.totalNanoseconds(), smallest_ns, options.roundingIncrement, options.roundingMode);
        const ns_of_day: u64 = @intCast(@mod(rounded_units * smallest_ns, @as(i128, NS_PER_DAY)));
        return fromNanosecondsOfDay(ns_of_day);
    }

    /// No calendar complexity at all (unlike `PlainDate`/`PlainDateTime`) --
    /// every unit involved has a fixed length, so this is ordinary
    /// fixed-radix rounding via `decomposeTimeDiff`.
    pub fn until(self: PlainTime, other: PlainTime, options: RoundingOptions) TemporalError!Duration {
        const resolved = try rounding.resolveTimeUnits(options);
        const diff_ns: i128 = @as(i128, other.totalNanoseconds()) - @as(i128, self.totalNanoseconds());
        return decomposeTimeDiff(diff_ns, resolved, options.roundingIncrement, options.roundingMode);
    }

    pub fn since(self: PlainTime, other: PlainTime, options: RoundingOptions) TemporalError!Duration {
        const resolved = try rounding.resolveTimeUnits(options);
        const diff_ns: i128 = @as(i128, self.totalNanoseconds()) - @as(i128, other.totalNanoseconds());
        return decomposeTimeDiff(diff_ns, resolved, options.roundingIncrement, options.roundingMode);
    }

    pub fn compare(a: PlainTime, b: PlainTime) std.math.Order {
        return std.math.order(a.totalNanoseconds(), b.totalNanoseconds());
    }

    pub fn equals(a: PlainTime, b: PlainTime) bool {
        return a.totalNanoseconds() == b.totalNanoseconds();
    }

    /// `HH:MM:SS[.fraction]` -- fraction auto-trimmed/omitted (real
    /// Temporal's default `toString()` behavior, never rounds).
    pub fn toLocaleString(self: PlainTime, allocator: std.mem.Allocator, io: std.Io, locales: ?[]const u8, options: @import("locale.zig").LocaleOptions) TemporalError![]u8 {
        return @import("locale.zig").format(allocator, io, .time, @as(f64, @floatFromInt(self.totalNanoseconds() / 1_000_000)), .iso8601, null, locales, options);
    }
    pub fn toString(self: PlainTime, allocator: std.mem.Allocator, options: StringOptions) TemporalError![]u8 {
        const fmt = @import("format_options.zig");
        const p = try fmt.precision(options);
        const value = try self.round(.{ .smallestUnit = p.unit, .roundingIncrement = p.increment, .roundingMode = options.roundingMode });
        const raw = try value.formatDefault(allocator);
        defer allocator.free(raw);
        const timed = try fmt.time(allocator, raw, p);
        defer allocator.free(timed);
        return fmt.calendar(allocator, timed, options.calendarName == .critical);
    }
    pub fn toJSON(self: PlainTime, allocator: std.mem.Allocator) TemporalError![]u8 {
        return self.toString(allocator, .{});
    }
    pub const StringOptions = @import("format_options.zig").StringOptions;
    fn formatDefault(self: PlainTime, allocator: std.mem.Allocator) ![]u8 {
        var frac_buf: [10]u8 = undefined;
        const frac = iso_string.formatFractionalSeconds(&frac_buf, self.millisecond, self.microsecond, self.nanosecond);
        return allocator.print("{d:0>2}:{d:0>2}:{d:0>2}{s}", .{ self.hour, self.minute, self.second, frac });
    }
};

test "init: symmetric clamp under constrain, reject on either bound" {
    const c = try @import("plain_time.zig").regulate(25, 70, 70, 1200, -1, 0, .constrain);
    try std.testing.expectEqual(@as(u8, 23), c.hour);
    try std.testing.expectEqual(@as(u8, 59), c.minute);
    try std.testing.expectEqual(@as(u8, 59), c.second);
    try std.testing.expectEqual(@as(u16, 999), c.millisecond);
    try std.testing.expectEqual(@as(u16, 0), c.microsecond);
    try std.testing.expectError(error.RangeError, PlainTime.init(25, 0, 0, 0, 0, 0));
    try std.testing.expectError(error.RangeError, PlainTime.init(-1, 0, 0, 0, 0, 0));

    const neg = try @import("plain_time.zig").regulate(-1, 0, 0, 0, 0, 0, .constrain);
    try std.testing.expectEqual(@as(u8, 0), neg.hour);
}

test "toString matches real Node byte-for-byte" {
    const allocator = std.testing.allocator;
    {
        const t = try PlainTime.init(23, 59, 59, 999, 999, 999);
        const s = try t.toString(allocator, .{});
        defer allocator.free(s);
        try std.testing.expectEqualStrings("23:59:59.999999999", s);
    }
    {
        const t = try PlainTime.init(1, 2, 0, 0, 0, 0);
        const s = try t.toString(allocator, .{});
        defer allocator.free(s);
        try std.testing.expectEqualStrings("01:02:00", s);
    }
    {
        const t = try PlainTime.init(1, 2, 3, 100, 20, 0);
        const s = try t.toString(allocator, .{});
        defer allocator.free(s);
        try std.testing.expectEqualStrings("01:02:03.10002", s);
    }
}

test "fromString: time-only" {
    const t = try PlainTime.from(.{ .string = "01:02" }, .{});
    try std.testing.expectEqual(@as(u8, 1), t.hour);
    try std.testing.expectEqual(@as(u8, 2), t.minute);
    try std.testing.expectEqual(@as(u8, 0), t.second);
}

test "add: wraps mod 24h regardless of magnitude" {
    const t = try PlainTime.init(12, 0, 0, 0, 0, 0);
    const r = t.add(try Duration.init(0, 0, 0, 0, 50, 0, 0, 0, 0, 0));
    try std.testing.expectEqual(@as(u8, 14), r.hour);
}

test "add: silently ignores calendar-unit and days duration fields" {
    const t = try PlainTime.init(1, 0, 0, 0, 0, 0);
    const with_days = t.add(try Duration.init(0, 0, 0, 1, 0, 0, 0, 0, 0, 0));
    const without_days = t.add(try Duration.init(0, 0, 0, 0, 0, 0, 0, 0, 0, 0));
    try std.testing.expect(PlainTime.equals(with_days, without_days));
}

test "subtract: wraps backward past midnight" {
    const t = try PlainTime.init(0, 0, 0, 0, 0, 0);
    const r = t.subtract(try Duration.init(0, 0, 0, 0, 0, 0, 0, 0, 0, 1));
    try std.testing.expectEqual(@as(u8, 23), r.hour);
    try std.testing.expectEqual(@as(u8, 59), r.minute);
    try std.testing.expectEqual(@as(u16, 999), r.nanosecond);
}
