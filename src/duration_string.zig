//! ISO 8601 duration string grammar: `[+-]?P(nY)?(nM)?(nW)?(nD)?(T(nH)?(nM)?(nS)?)?`.
//! Ground-truthed against real Node's `Temporal.Duration.from`: sign only
//! once at the front (never per-component), date-part designators (Y/M/W/D)
//! are integer-only (a fraction there is a parse error, unlike the time
//! part), and a fraction is allowed only on the single LAST-present time
//! designator (H, M, or S) -- it is not stored as a fractional field
//! (`Duration` has none) but cascaded down into the smaller units
//! immediately, e.g. `"PT1.5H"` -> `{hours:1, minutes:30}`. Designator
//! order is strictly enforced in both parts; an empty `"P"` or a `"T"`
//! with nothing after it is a parse error.
const std = @import("std");
const errors = @import("errors.zig");
const TemporalError = errors.TemporalError;

pub const RawDuration = struct {
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
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn readInt(s: []const u8, pos: *usize) TemporalError!i64 {
    const start = pos.*;
    while (pos.* < s.len and isDigit(s[pos.*])) pos.* += 1;
    if (pos.* == start) return error.InvalidFormat;
    return std.fmt.parseInt(i64, s[start..pos.*], 10) catch return error.InvalidFormat;
}

/// Reads `.`/`,` + 1-9 digits, returned as a numerator over 10^9 (i.e. the
/// fractional value is `numerator / 1_000_000_000`). More than 9 digits is
/// a parse error (ground-truthed: real Temporal rejects a 10th fractional
/// digit outright, unlike the Plain*/`iso_string.zig` parser, which
/// silently truncates extra digits beyond nanosecond precision).
fn readFractionNumerator(s: []const u8, pos: *usize) TemporalError!u64 {
    const start = pos.*;
    var count: usize = 0;
    while (pos.* < s.len and isDigit(s[pos.*])) : (count += 1) pos.* += 1;
    if (count == 0 or count > 9) return error.InvalidFormat;
    var num = std.fmt.parseInt(u64, s[start..pos.*], 10) catch return error.InvalidFormat;
    var i: usize = count;
    while (i < 9) : (i += 1) num *= 10;
    return num;
}

const ValueAndFrac = struct { whole: i64, frac_num: u64 = 0, has_frac: bool = false };

fn readValueAndOptionalFrac(s: []const u8, pos: *usize) TemporalError!ValueAndFrac {
    const whole = try readInt(s, pos);
    if (pos.* < s.len and (s[pos.*] == '.' or s[pos.*] == ',')) {
        pos.* += 1;
        const num = try readFractionNumerator(s, pos);
        return .{ .whole = whole, .frac_num = num, .has_frac = true };
    }
    return .{ .whole = whole };
}

fn applySign(value: i64, negative: bool) i64 {
    return if (negative) -value else value;
}

pub fn parseDuration(s: []const u8) TemporalError!RawDuration {
    var pos: usize = 0;
    var negative = false;
    if (pos < s.len and (s[pos] == '+' or s[pos] == '-')) {
        negative = s[pos] == '-';
        pos += 1;
    }
    if (pos >= s.len or (s[pos] != 'P' and s[pos] != 'p')) return error.InvalidFormat;
    pos += 1;

    var result = RawDuration{};
    var any_component = false;

    // Date part: Y, M, W, D, strict order, integer-only (a fraction here
    // is a parse error, not a Duration concept).
    const DATE_RANK = std.StaticStringMap(u8).initComptime(.{
        .{ "Y", 1 }, .{ "y", 1 }, .{ "M", 2 }, .{ "m", 2 },
        .{ "W", 3 }, .{ "w", 3 }, .{ "D", 4 }, .{ "d", 4 },
    });
    var last_date_rank: u8 = 0;
    while (pos < s.len and s[pos] != 'T' and s[pos] != 't') {
        const value = try readInt(s, &pos);
        if (pos >= s.len) return error.InvalidFormat;
        const c = s[pos .. pos + 1];
        const rank = DATE_RANK.get(c) orelse return error.InvalidFormat;
        if (rank <= last_date_rank) return error.InvalidFormat;
        last_date_rank = rank;
        pos += 1;
        any_component = true;
        switch (rank) {
            1 => result.years = applySign(value, negative),
            2 => result.months = applySign(value, negative),
            3 => result.weeks = applySign(value, negative),
            4 => result.days = applySign(value, negative),
            else => unreachable,
        }
    }

    if (pos < s.len and (s[pos] == 'T' or s[pos] == 't')) {
        pos += 1;
        const TIME_RANK = std.StaticStringMap(u8).initComptime(.{
            .{ "H", 1 }, .{ "h", 1 }, .{ "M", 2 }, .{ "m", 2 }, .{ "S", 3 }, .{ "s", 3 },
        });
        var last_time_rank: u8 = 0;
        var saw_time_component = false;
        while (pos < s.len) {
            const vf = try readValueAndOptionalFrac(s, &pos);
            if (pos >= s.len) return error.InvalidFormat;
            const c = s[pos .. pos + 1];
            const rank = TIME_RANK.get(c) orelse return error.InvalidFormat;
            if (rank <= last_time_rank) return error.InvalidFormat;
            last_time_rank = rank;
            pos += 1;
            any_component = true;
            saw_time_component = true;

            switch (rank) {
                1 => { // H
                    result.hours = applySign(vf.whole, negative);
                    if (vf.has_frac) {
                        const extra_ns: i64 = @intCast(vf.frac_num * 3600);
                        const extra_minutes = @divTrunc(extra_ns, 60_000_000_000);
                        const rem1 = @rem(extra_ns, 60_000_000_000);
                        const extra_seconds = @divTrunc(rem1, 1_000_000_000);
                        const rem2 = @rem(rem1, 1_000_000_000);
                        result.minutes = applySign(extra_minutes, negative);
                        result.seconds = applySign(extra_seconds, negative);
                        result.milliseconds = applySign(@divTrunc(rem2, 1_000_000), negative);
                        result.microseconds = applySign(@mod(@divTrunc(rem2, 1_000), 1000), negative);
                        result.nanoseconds = applySign(@mod(rem2, 1000), negative);
                        if (pos != s.len) return error.InvalidFormat;
                    }
                },
                2 => { // M
                    result.minutes = applySign(vf.whole, negative);
                    if (vf.has_frac) {
                        const extra_ns: i64 = @intCast(vf.frac_num * 60);
                        const extra_seconds = @divTrunc(extra_ns, 1_000_000_000);
                        const rem2 = @rem(extra_ns, 1_000_000_000);
                        result.seconds = applySign(extra_seconds, negative);
                        result.milliseconds = applySign(@divTrunc(rem2, 1_000_000), negative);
                        result.microseconds = applySign(@mod(@divTrunc(rem2, 1_000), 1000), negative);
                        result.nanoseconds = applySign(@mod(rem2, 1000), negative);
                        if (pos != s.len) return error.InvalidFormat;
                    }
                },
                3 => { // S
                    result.seconds = applySign(vf.whole, negative);
                    if (vf.has_frac) {
                        const rem2: i64 = @intCast(vf.frac_num);
                        result.milliseconds = applySign(@divTrunc(rem2, 1_000_000), negative);
                        result.microseconds = applySign(@mod(@divTrunc(rem2, 1_000), 1000), negative);
                        result.nanoseconds = applySign(@mod(rem2, 1000), negative);
                    }
                },
                else => unreachable,
            }
        }
        if (!saw_time_component) return error.InvalidFormat; // bare "T"
    }

    if (!any_component) return error.InvalidFormat; // bare "P"
    if (pos != s.len) return error.InvalidFormat;
    return result;
}

test "parseDuration: full component set, sign, case-insensitivity" {
    const d = try parseDuration("P1Y2M3W4DT5H6M7S");
    try std.testing.expectEqual(@as(i64, 1), d.years);
    try std.testing.expectEqual(@as(i64, 2), d.months);
    try std.testing.expectEqual(@as(i64, 3), d.weeks);
    try std.testing.expectEqual(@as(i64, 4), d.days);
    try std.testing.expectEqual(@as(i64, 5), d.hours);
    try std.testing.expectEqual(@as(i64, 6), d.minutes);
    try std.testing.expectEqual(@as(i64, 7), d.seconds);

    const lower = try parseDuration("p1d");
    try std.testing.expectEqual(@as(i64, 1), lower.days);

    const neg = try parseDuration("-P1D");
    try std.testing.expectEqual(@as(i64, -1), neg.days);

    const explicit_plus = try parseDuration("+P1D");
    try std.testing.expectEqual(@as(i64, 1), explicit_plus.days);
}

test "parseDuration: fractional H cascades to M/S/ms/us/ns" {
    const d = try parseDuration("PT1.5H");
    try std.testing.expectEqual(@as(i64, 1), d.hours);
    try std.testing.expectEqual(@as(i64, 30), d.minutes);
    try std.testing.expectEqual(@as(i64, 0), d.seconds);
}

test "parseDuration: fractional S cascades to ms/us/ns, comma accepted" {
    const d = try parseDuration("PT1.123456789S");
    try std.testing.expectEqual(@as(i64, 1), d.seconds);
    try std.testing.expectEqual(@as(i64, 123), d.milliseconds);
    try std.testing.expectEqual(@as(i64, 456), d.microseconds);
    try std.testing.expectEqual(@as(i64, 789), d.nanoseconds);

    const comma = try parseDuration("PT1,5S");
    try std.testing.expectEqual(@as(i64, 500), comma.milliseconds);
}

test "parseDuration: rejects bad grammar" {
    try std.testing.expectError(error.InvalidFormat, parseDuration("P"));
    try std.testing.expectError(error.InvalidFormat, parseDuration("PT"));
    try std.testing.expectError(error.InvalidFormat, parseDuration("P3D1Y"));
    try std.testing.expectError(error.InvalidFormat, parseDuration("P1.5D"));
    try std.testing.expectError(error.InvalidFormat, parseDuration("PT1.12345678901S"));
    try std.testing.expectError(error.InvalidFormat, parseDuration("P1D1H"));
    try std.testing.expectError(error.InvalidFormat, parseDuration(""));
}
