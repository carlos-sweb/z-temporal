//! `Temporal.PlainTime`. Unlike `PlainDate`'s month/day (lower bound
//! always rejects), every `PlainTime` field clamps SYMMETRICALLY under
//! `overflow: "constrain"` (negative -> 0, too-large -> max) -- confirmed
//! against real Node (`PlainTime.from({hour:-1})` -> `00:00:00`, not a
//! throw).
const std = @import("std");
const iso_string = @import("iso_string.zig");
const errors = @import("errors.zig");
const TemporalError = errors.TemporalError;
const Overflow = @import("plain_date.zig").Overflow;
const Duration = @import("duration.zig").Duration;

const NS_PER_DAY: u64 = 86_400_000_000_000;

fn clampField(value: i32, max: u16, overflow: Overflow) TemporalError!u16 {
    if (value < 0 or value > max) {
        if (overflow == .reject) return error.InvalidRange;
        return @intCast(std.math.clamp(value, 0, @as(i32, max)));
    }
    return @intCast(value);
}

pub const PlainTime = struct {
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    millisecond: u16 = 0,
    microsecond: u16 = 0,
    nanosecond: u16 = 0,

    pub fn create(hour: i32, minute: i32, second: i32, millisecond: i32, microsecond: i32, nanosecond: i32, overflow: Overflow) TemporalError!PlainTime {
        return .{
            .hour = @intCast(try clampField(hour, 23, overflow)),
            .minute = @intCast(try clampField(minute, 59, overflow)),
            .second = @intCast(try clampField(second, 59, overflow)),
            .millisecond = try clampField(millisecond, 999, overflow),
            .microsecond = try clampField(microsecond, 999, overflow),
            .nanosecond = try clampField(nanosecond, 999, overflow),
        };
    }

    pub fn parseIso(text: []const u8) TemporalError!PlainTime {
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

    pub fn withFields(self: PlainTime, hour: ?i32, minute: ?i32, second: ?i32, millisecond: ?i32, microsecond: ?i32, nanosecond: ?i32, overflow: Overflow) TemporalError!PlainTime {
        return create(
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

    pub fn compare(a: PlainTime, b: PlainTime) std.math.Order {
        return std.math.order(a.totalNanoseconds(), b.totalNanoseconds());
    }

    pub fn equals(a: PlainTime, b: PlainTime) bool {
        return a.totalNanoseconds() == b.totalNanoseconds();
    }

    /// `HH:MM:SS[.fraction]` -- fraction auto-trimmed/omitted (real
    /// Temporal's default `toString()` behavior, never rounds).
    pub fn toIsoString(self: PlainTime, allocator: std.mem.Allocator) ![]u8 {
        var frac_buf: [10]u8 = undefined;
        const frac = iso_string.formatFractionalSeconds(&frac_buf, self.millisecond, self.microsecond, self.nanosecond);
        return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}{s}", .{ self.hour, self.minute, self.second, frac });
    }
};

test "create: symmetric clamp under constrain, reject on either bound" {
    const c = try PlainTime.create(25, 70, 70, 1200, -1, 0, .constrain);
    try std.testing.expectEqual(@as(u8, 23), c.hour);
    try std.testing.expectEqual(@as(u8, 59), c.minute);
    try std.testing.expectEqual(@as(u8, 59), c.second);
    try std.testing.expectEqual(@as(u16, 999), c.millisecond);
    try std.testing.expectEqual(@as(u16, 0), c.microsecond);
    try std.testing.expectError(error.InvalidRange, PlainTime.create(25, 0, 0, 0, 0, 0, .reject));
    try std.testing.expectError(error.InvalidRange, PlainTime.create(-1, 0, 0, 0, 0, 0, .reject));

    const neg = try PlainTime.create(-1, 0, 0, 0, 0, 0, .constrain);
    try std.testing.expectEqual(@as(u8, 0), neg.hour);
}

test "toIsoString matches real Node byte-for-byte" {
    const allocator = std.testing.allocator;
    {
        const t = try PlainTime.create(23, 59, 59, 999, 999, 999, .reject);
        const s = try t.toIsoString(allocator);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("23:59:59.999999999", s);
    }
    {
        const t = try PlainTime.create(1, 2, 0, 0, 0, 0, .reject);
        const s = try t.toIsoString(allocator);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("01:02:00", s);
    }
    {
        const t = try PlainTime.create(1, 2, 3, 100, 20, 0, .reject);
        const s = try t.toIsoString(allocator);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("01:02:03.10002", s);
    }
}

test "parseIso: time-only" {
    const t = try PlainTime.parseIso("01:02");
    try std.testing.expectEqual(@as(u8, 1), t.hour);
    try std.testing.expectEqual(@as(u8, 2), t.minute);
    try std.testing.expectEqual(@as(u8, 0), t.second);
}

test "add: wraps mod 24h regardless of magnitude" {
    const t = try PlainTime.create(12, 0, 0, 0, 0, 0, .reject);
    const r = t.add(try Duration.create(0, 0, 0, 0, 50, 0, 0, 0, 0, 0));
    try std.testing.expectEqual(@as(u8, 14), r.hour);
}

test "add: silently ignores calendar-unit and days duration fields" {
    const t = try PlainTime.create(1, 0, 0, 0, 0, 0, .reject);
    const with_days = t.add(try Duration.create(0, 0, 0, 1, 0, 0, 0, 0, 0, 0));
    const without_days = t.add(try Duration.create(0, 0, 0, 0, 0, 0, 0, 0, 0, 0));
    try std.testing.expect(PlainTime.equals(with_days, without_days));
}

test "subtract: wraps backward past midnight" {
    const t = try PlainTime.create(0, 0, 0, 0, 0, 0, .reject);
    const r = t.subtract(try Duration.create(0, 0, 0, 0, 0, 0, 0, 0, 0, 1));
    try std.testing.expectEqual(@as(u8, 23), r.hour);
    try std.testing.expectEqual(@as(u8, 59), r.minute);
    try std.testing.expectEqual(@as(u16, 999), r.nanosecond);
}
