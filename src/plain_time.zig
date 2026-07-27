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

    fn totalNanoseconds(self: PlainTime) u64 {
        var t: u64 = self.hour;
        t = t * 60 + self.minute;
        t = t * 60 + self.second;
        t = t * 1000 + self.millisecond;
        t = t * 1000 + self.microsecond;
        t = t * 1000 + self.nanosecond;
        return t;
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
