//! Temporal's ISO 8601 string grammar for PlainDate/PlainTime/PlainDateTime
//! -- materially different from z-date's own parser (calendar annotations
//! `[u-ca=...]`, nanosecond-precision fractions, no legacy/loose formats at
//! all). Only the "extended" (separator-containing) format is supported --
//! the separator-less "basic" format is genuinely ambiguous with MonthDay
//! per real spec (confirmed via Node: `PlainTime.from('0102')` itself
//! throws in real Temporal) and is out of scope for this phase.
const std = @import("std");
const errors = @import("errors.zig");
const TemporalError = errors.TemporalError;

pub const ParsedDate = struct { year: i32, month: u8, day: u8 };
pub const ParsedTime = struct {
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    millisecond: u16 = 0,
    microsecond: u16 = 0,
    nanosecond: u16 = 0,
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn readNDigits(s: []const u8, pos: *usize, n: usize) TemporalError!u32 {
    if (pos.* + n > s.len) return error.InvalidFormat;
    var value: u32 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = s[pos.* + i];
        if (!isDigit(c)) return error.InvalidFormat;
        value = value * 10 + (c - '0');
    }
    pos.* += n;
    return value;
}

fn expect(s: []const u8, pos: *usize, c: u8) TemporalError!void {
    if (pos.* >= s.len or s[pos.*] != c) return error.InvalidFormat;
    pos.* += 1;
}

fn parseSignedYear(s: []const u8, pos: *usize) TemporalError!i32 {
    if (pos.* < s.len and (s[pos.*] == '+' or s[pos.*] == '-')) {
        const negative = s[pos.*] == '-';
        pos.* += 1;
        const mag = try readNDigits(s, pos, 6);
        const v: i32 = @intCast(mag);
        return if (negative) -v else v;
    }
    const v = try readNDigits(s, pos, 4);
    return @intCast(v);
}

fn parseDatePart(s: []const u8, pos: *usize) TemporalError!ParsedDate {
    const year = try parseSignedYear(s, pos);
    try expect(s, pos, '-');
    const month = try readNDigits(s, pos, 2);
    try expect(s, pos, '-');
    const day = try readNDigits(s, pos, 2);
    if (month < 1 or month > 12) return error.InvalidFormat;
    if (day < 1 or day > 31) return error.InvalidFormat;
    return .{ .year = year, .month = @intCast(month), .day = @intCast(day) };
}

/// `HH:MM[:SS[.fraction]]` -- minute is mandatory (matches real Temporal:
/// bare-hour forms are rejected/ambiguous, not supported this phase).
fn parseTimePart(s: []const u8, pos: *usize) TemporalError!ParsedTime {
    const hour = try readNDigits(s, pos, 2);
    try expect(s, pos, ':');
    const minute = try readNDigits(s, pos, 2);
    if (hour > 23 or minute > 59) return error.InvalidFormat;
    var result = ParsedTime{ .hour = @intCast(hour), .minute = @intCast(minute) };
    if (pos.* < s.len and s[pos.*] == ':') {
        pos.* += 1;
        const second = try readNDigits(s, pos, 2);
        if (second > 59) return error.InvalidFormat;
        result.second = @intCast(second);
        if (pos.* < s.len and (s[pos.*] == '.' or s[pos.*] == ',')) {
            pos.* += 1;
            const start = pos.*;
            var digits: [9]u8 = .{ '0', '0', '0', '0', '0', '0', '0', '0', '0' };
            var i: usize = 0;
            while (pos.* < s.len and isDigit(s[pos.*]) and i < 9) : (i += 1) {
                digits[i] = s[pos.*];
                pos.* += 1;
            }
            if (pos.* == start) return error.InvalidFormat; // '.' with no digits
            // extra digits beyond 9 are allowed by the grammar but dropped
            // (sub-nanosecond precision isn't representable here).
            while (pos.* < s.len and isDigit(s[pos.*])) pos.* += 1;
            const ns_total = std.fmt.parseInt(u32, &digits, 10) catch return error.InvalidFormat;
            result.millisecond = @intCast(ns_total / 1_000_000);
            result.microsecond = @intCast((ns_total / 1_000) % 1_000);
            result.nanosecond = @intCast(ns_total % 1_000);
        }
    }
    return result;
}

/// Optional `Z` or `±HH:MM[:SS[.fraction]]` UTC-offset designator --
/// consumed and discarded (PlainDate/PlainTime/PlainDateTime.from ignores
/// any offset in the source string; only ZonedDateTime/Instant, a later
/// phase, cares about it).
fn skipOffset(s: []const u8, pos: *usize) TemporalError!void {
    if (pos.* >= s.len) return;
    if (s[pos.*] == 'Z' or s[pos.*] == 'z') {
        pos.* += 1;
        return;
    }
    if (s[pos.*] == '+' or s[pos.*] == '-') {
        pos.* += 1;
        _ = try readNDigits(s, pos, 2);
        try expect(s, pos, ':');
        _ = try readNDigits(s, pos, 2);
        if (pos.* < s.len and s[pos.*] == ':') {
            pos.* += 1;
            _ = try readNDigits(s, pos, 2);
            if (pos.* < s.len and (s[pos.*] == '.' or s[pos.*] == ',')) {
                pos.* += 1;
                const start = pos.*;
                while (pos.* < s.len and isDigit(s[pos.*])) pos.* += 1;
                if (pos.* == start) return error.InvalidFormat;
            }
        }
    }
}

/// Zero or more `[...]` bracket annotations. Each is either a timezone
/// name (no `=`, e.g. `[America/New_York]`, discarded -- a later phase's
/// concern) or `[u-ca=CalendarId]` (optionally critical-flagged with a
/// leading `!`). Phase 1 is ISO-only: any calendar id other than
/// `"iso8601"` is `error.InvalidFormat` (non-ISO calendars are Phase 8).
fn skipAnnotations(s: []const u8, pos: *usize) TemporalError!void {
    while (pos.* < s.len and s[pos.*] == '[') {
        pos.* += 1;
        const start = pos.*;
        while (pos.* < s.len and s[pos.*] != ']') pos.* += 1;
        if (pos.* >= s.len) return error.InvalidFormat;
        var inner = s[start..pos.*];
        pos.* += 1; // consume ']'
        if (inner.len > 0 and inner[0] == '!') inner = inner[1..];
        if (std.mem.indexOfScalar(u8, inner, '=')) |eq| {
            const key = inner[0..eq];
            const value = inner[eq + 1 ..];
            if (std.mem.eql(u8, key, "u-ca")) {
                if (!std.mem.eql(u8, value, "iso8601")) return error.InvalidFormat;
            }
            // Other `key=value` annotations (e.g. future extensions):
            // ignored, matching real spec's "unknown non-critical
            // annotations are ignored" rule (critical-flag enforcement
            // is a documented narrowing, not implemented this phase).
        }
        // else: bare timezone-name annotation, discarded.
    }
}

/// A PlainDate string: date part, then an optional (ignored) time+offset,
/// then optional annotations. Trailing content after the date part is
/// tolerated only in these well-formed shapes -- anything else is
/// `error.InvalidFormat`.
pub fn parsePlainDate(s: []const u8) TemporalError!ParsedDate {
    var pos: usize = 0;
    const date = try parseDatePart(s, &pos);
    if (pos < s.len and (s[pos] == 'T' or s[pos] == 't' or s[pos] == ' ')) {
        pos += 1;
        _ = try parseTimePart(s, &pos);
        try skipOffset(s, &pos);
    }
    try skipAnnotations(s, &pos);
    if (pos != s.len) return error.InvalidFormat;
    return date;
}

/// A PlainTime string: either time-only (`HH:MM[:SS[.f]]`) or a full
/// date-time string (date part + `T`/space + time), from which only the
/// time is kept -- matches real Temporal's dual-form `PlainTime.from`.
/// Disambiguated the simple way: a leading 4-or-6-digit year followed by
/// `-` means "this is a date-time string", anything else is "time-only".
pub fn parsePlainTime(s: []const u8) TemporalError!ParsedTime {
    var pos: usize = 0;
    const looks_like_date = s.len >= 5 and (isDigit(s[0]) and s[1] == '0' or true) and blk: {
        // A date part starts with a sign, or 4 digits followed by '-'.
        if (s[0] == '+' or s[0] == '-') break :blk true;
        break :blk s.len > 4 and isDigit(s[0]) and isDigit(s[1]) and isDigit(s[2]) and isDigit(s[3]) and s[4] == '-';
    };
    if (looks_like_date) {
        _ = try parseDatePart(s, &pos);
        if (pos >= s.len or (s[pos] != 'T' and s[pos] != 't' and s[pos] != ' ')) return error.InvalidFormat;
        pos += 1;
    }
    const time = try parseTimePart(s, &pos);
    try skipOffset(s, &pos);
    try skipAnnotations(s, &pos);
    if (pos != s.len) return error.InvalidFormat;
    return time;
}

pub const ParsedYearMonth = struct { year: i32, month: u8 };

/// A PlainYearMonth string: `YYYY-MM`, or a full `YYYY-MM-DD[...]` string
/// (the day, if present, is parsed and dropped -- ground-truthed:
/// `PlainYearMonth.from("2024-02-15T10:00:00")` -> `2024-02`).
pub fn parsePlainYearMonth(s: []const u8) TemporalError!ParsedYearMonth {
    var pos: usize = 0;
    const year = try parseSignedYear(s, &pos);
    try expect(s, &pos, '-');
    const month = try readNDigits(s, &pos, 2);
    if (month < 1 or month > 12) return error.InvalidFormat;
    if (pos < s.len and s[pos] == '-') {
        pos += 1;
        const day = try readNDigits(s, &pos, 2);
        if (day < 1 or day > 31) return error.InvalidFormat;
    }
    if (pos < s.len and (s[pos] == 'T' or s[pos] == 't' or s[pos] == ' ')) {
        pos += 1;
        _ = try parseTimePart(s, &pos);
        try skipOffset(s, &pos);
    }
    try skipAnnotations(s, &pos);
    if (pos != s.len) return error.InvalidFormat;
    return .{ .year = year, .month = @intCast(month) };
}

pub const ParsedMonthDay = struct { month: u8, day: u8 };

/// A PlainMonthDay string: bare `MM-DD`, or a full `YYYY-MM-DD[...]`
/// string (the year is parsed and dropped). Disambiguated the same way
/// `parsePlainTime` disambiguates time-only vs date-time: a leading sign,
/// or 4 digits followed by `-`, means "this is a full date string".
pub fn parsePlainMonthDay(s: []const u8) TemporalError!ParsedMonthDay {
    var pos: usize = 0;
    const looks_like_full_date = (s.len > 0 and (s[0] == '+' or s[0] == '-')) or
        (s.len >= 5 and isDigit(s[0]) and isDigit(s[1]) and isDigit(s[2]) and isDigit(s[3]) and s[4] == '-');
    if (looks_like_full_date) {
        const date = try parseDatePart(s, &pos);
        if (pos < s.len and (s[pos] == 'T' or s[pos] == 't' or s[pos] == ' ')) {
            pos += 1;
            _ = try parseTimePart(s, &pos);
            try skipOffset(s, &pos);
        }
        try skipAnnotations(s, &pos);
        if (pos != s.len) return error.InvalidFormat;
        return .{ .month = date.month, .day = date.day };
    }
    const month = try readNDigits(s, &pos, 2);
    try expect(s, &pos, '-');
    const day = try readNDigits(s, &pos, 2);
    if (month < 1 or month > 12) return error.InvalidFormat;
    if (day < 1 or day > 31) return error.InvalidFormat;
    if (pos < s.len and (s[pos] == 'T' or s[pos] == 't' or s[pos] == ' ')) {
        pos += 1;
        _ = try parseTimePart(s, &pos);
        try skipOffset(s, &pos);
    }
    try skipAnnotations(s, &pos);
    if (pos != s.len) return error.InvalidFormat;
    return .{ .month = @intCast(month), .day = @intCast(day) };
}

pub const ParsedDateTime = struct { date: ParsedDate, time: ParsedTime };

/// A PlainDateTime string: date part, then an optional time part
/// (defaults to midnight when absent, matching real Temporal:
/// `PlainDateTime.from('2024-02-29')` -> `2024-02-29T00:00:00`).
pub fn parsePlainDateTime(s: []const u8) TemporalError!ParsedDateTime {
    var pos: usize = 0;
    const date = try parseDatePart(s, &pos);
    var time = ParsedTime{};
    if (pos < s.len and (s[pos] == 'T' or s[pos] == 't' or s[pos] == ' ')) {
        pos += 1;
        time = try parseTimePart(s, &pos);
        try skipOffset(s, &pos);
    }
    try skipAnnotations(s, &pos);
    if (pos != s.len) return error.InvalidFormat;
    return .{ .date = date, .time = time };
}

/// Formats `year` per real Temporal's exact rule (ground-truthed against
/// Node): 4-digit zero-padded, no sign, when `0 <= year <= 9999`;
/// otherwise 6-digit zero-padded magnitude with an explicit `+`/`-` sign.
/// Same convention z-date's `formatYear` already uses.
pub fn formatYear(buf: []u8, year: i32) []const u8 {
    if (year >= 0 and year <= 9999) {
        const y: u32 = @intCast(year);
        return std.fmt.bufPrint(buf, "{d:0>4}", .{y}) catch unreachable;
    }
    const sign: u8 = if (year < 0) '-' else '+';
    const mag: u32 = @intCast(@abs(year));
    return std.fmt.bufPrint(buf, "{c}{d:0>6}", .{ sign, mag }) catch unreachable;
}

/// The fractional-second suffix (`.` + trimmed digits), or "" when the
/// sub-second value is exactly zero -- matches real Temporal's default
/// `toString()` behavior (ground-truthed: trailing zeros trimmed, whole
/// field omitted when zero, never rounds).
pub fn formatFractionalSeconds(buf: []u8, millisecond: u16, microsecond: u16, nanosecond: u16) []const u8 {
    const total: u32 = @as(u32, millisecond) * 1_000_000 + @as(u32, microsecond) * 1_000 + nanosecond;
    if (total == 0) return "";
    var digits: [9]u8 = undefined;
    _ = std.fmt.bufPrint(&digits, "{d:0>9}", .{total}) catch unreachable;
    var len: usize = 9;
    while (len > 0 and digits[len - 1] == '0') len -= 1;
    buf[0] = '.';
    @memcpy(buf[1 .. 1 + len], digits[0..len]);
    return buf[0 .. 1 + len];
}

test "parsePlainDate: extended form, signed years, trailing time/annotations" {
    try std.testing.expectEqual(ParsedDate{ .year = 2024, .month = 2, .day = 29 }, try parsePlainDate("2024-02-29"));
    try std.testing.expectEqual(ParsedDate{ .year = 2024, .month = 2, .day = 29 }, try parsePlainDate("2024-02-29T01:02:03.5"));
    try std.testing.expectEqual(ParsedDate{ .year = 2024, .month = 2, .day = 29 }, try parsePlainDate("2024-02-29[u-ca=iso8601]"));
    try std.testing.expectEqual(ParsedDate{ .year = 12345, .month = 1, .day = 1 }, try parsePlainDate("+012345-01-01"));
    try std.testing.expectEqual(ParsedDate{ .year = -1, .month = 1, .day = 1 }, try parsePlainDate("-000001-01-01"));
    try std.testing.expectError(error.InvalidFormat, parsePlainDate("2024-02-29[u-ca=hebrew]"));
    try std.testing.expectError(error.InvalidFormat, parsePlainDate("2024-2-29"));
    try std.testing.expectError(error.InvalidFormat, parsePlainDate(""));
}

test "parsePlainTime: time-only and date-time forms" {
    const t = try parsePlainTime("01:02");
    try std.testing.expectEqual(@as(u8, 1), t.hour);
    try std.testing.expectEqual(@as(u8, 2), t.minute);
    try std.testing.expectEqual(@as(u8, 0), t.second);
    const t2 = try parsePlainTime("2024-02-29T01:02:03.005");
    try std.testing.expectEqual(@as(u8, 1), t2.hour);
    try std.testing.expectEqual(@as(u16, 5), t2.millisecond);
}

test "parsePlainDateTime: time defaults to midnight when absent" {
    const dt = try parsePlainDateTime("2024-02-29");
    try std.testing.expectEqual(@as(u8, 0), dt.time.hour);
    const dt2 = try parsePlainDateTime("2024-02-29T01:02:03.004005006");
    try std.testing.expectEqual(@as(u16, 4), dt2.time.millisecond);
    try std.testing.expectEqual(@as(u16, 5), dt2.time.microsecond);
    try std.testing.expectEqual(@as(u16, 6), dt2.time.nanosecond);
}

test "formatYear matches real Node's exact 4-vs-6-digit rule" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("2024", formatYear(&buf, 2024));
    try std.testing.expectEqualStrings("0000", formatYear(&buf, 0));
    try std.testing.expectEqualStrings("0999", formatYear(&buf, 999));
    try std.testing.expectEqualStrings("9999", formatYear(&buf, 9999));
    try std.testing.expectEqualStrings("-000001", formatYear(&buf, -1));
    try std.testing.expectEqualStrings("+012345", formatYear(&buf, 12345));
    try std.testing.expectEqualStrings("+010000", formatYear(&buf, 10000));
    try std.testing.expectEqualStrings("+275760", formatYear(&buf, 275760));
    try std.testing.expectEqualStrings("-271821", formatYear(&buf, -271821));
}

test "formatFractionalSeconds trims trailing zeros, omits when zero" {
    var buf: [10]u8 = undefined;
    try std.testing.expectEqualStrings("", formatFractionalSeconds(&buf, 0, 0, 0));
    try std.testing.expectEqualStrings(".1", formatFractionalSeconds(&buf, 100, 0, 0));
    try std.testing.expectEqualStrings(".10002", formatFractionalSeconds(&buf, 100, 20, 0));
    try std.testing.expectEqualStrings(".000000005", formatFractionalSeconds(&buf, 0, 0, 5));
    try std.testing.expectEqualStrings(".004005006", formatFractionalSeconds(&buf, 4, 5, 6));
}
