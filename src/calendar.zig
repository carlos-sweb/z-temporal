//! Optional ICU calendar data; Temporal arithmetic and validation stay in Zig.
const std = @import("std");
const cal = @import("iso_calendar.zig");
const E = @import("errors.zig").TemporalError;
const enabled = @import("build_options").intl;
pub const Id = enum { iso8601, buddhist, chinese, coptic, dangi, ethioaa, ethiopic, gregory, hebrew, indian, @"islamic-civil", @"islamic-tbla", @"islamic-umalqura", japanese, persian, roc };
pub const Info = extern struct { year: i32, month: i32, month_code: i32, leap_month: i32, day: i32, era: i32, era_year: i32, day_of_year: i32, days_in_month: i32, days_in_year: i32, months_in_year: i32, leap_year: i32 };
extern fn z_calendar_info([*:0]const u8, i64, *Info) c_int;
extern fn z_calendar_from_fields([*:0]const u8, c_int, c_int, c_int, c_int, c_int, c_int, *i64) c_int;
extern fn z_calendar_add([*:0]const u8, i64, c_int, c_int, c_int, *i64) c_int;
pub fn parse(name: []const u8) E!Id {
    inline for (@typeInfo(Id).@"enum".field_names, @typeInfo(Id).@"enum".field_values) |field_name, field_value| {
        if (std.ascii.eqlIgnoreCase(field_name, name)) {
            const id: Id = @fromBackingInt(field_value);
            if (id != .iso8601 and !enabled) return error.RangeError;
            return id;
        }
    }
    return error.RangeError;
}
fn calendarName(id: Id) [:0]const u8 {
    return switch (id) {
        inline else => |value| @tagName(value),
    };
}
fn check(status: c_int) E!void {
    if (status == 2) return error.OutOfMemory;
    if (status != 0) return error.RangeError;
}
pub fn info(ymd: cal.YearMonthDay, id: Id) E!?Info {
    if (id == .iso8601) return null;
    if (!enabled) return error.RangeError;
    var result: Info = undefined;
    try check(z_calendar_info(calendarName(id), cal.toEpochDay(ymd.year, ymd.month, ymd.day), &result));
    return result;
}
pub fn fromFields(id: Id, year: i32, month: i32, day: i32, code: ?[]const u8, constrain: bool) E!cal.YearMonthDay {
    if (!enabled or id == .iso8601) return error.RangeError;
    var c: i32 = 0;
    var leap: i32 = 0;
    if (code) |text| {
        if (text.len != 3 and text.len != 4) return error.RangeError;
        if (text[0] != 'M' or (text.len == 4 and text[3] != 'L')) return error.RangeError;
        c = std.fmt.parseInt(i32, text[1..3], 10) catch return error.RangeError;
        if (c < 1 or c > 13) return error.RangeError;
        leap = @intFromBool(text.len == 4);
    }
    var epoch_day: i64 = 0;
    try check(z_calendar_from_fields(calendarName(id), year, month, day, c, leap, @intFromBool(constrain), &epoch_day));
    const result = cal.fromEpochDay(epoch_day);
    if (!cal.isInRange(result.year, result.month, result.day)) return error.RangeError;
    return result;
}
pub fn add(id: Id, ymd: cal.YearMonthDay, years: i64, months: i64, constrain: bool) E!cal.YearMonthDay {
    if (!enabled or years < std.math.minInt(c_int) or years > std.math.maxInt(c_int) or months < std.math.minInt(c_int) or months > std.math.maxInt(c_int)) return error.RangeError;
    var epoch_day: i64 = 0;
    try check(z_calendar_add(calendarName(id), cal.toEpochDay(ymd.year, ymd.month, ymd.day), @intCast(years), @intCast(months), @intFromBool(constrain), &epoch_day));
    return cal.fromEpochDay(epoch_day);
}
pub fn era(id: Id, data: Info, ymd: cal.YearMonthDay) ?[]const u8 {
    return switch (id) {
        .iso8601, .chinese, .dangi => null,
        .buddhist => "be",
        .coptic => if (data.year > 0) "am" else "before-am",
        .ethioaa => "aa",
        .ethiopic => if (data.era == 1) "am" else "aa",
        .gregory => if (data.year > 0) "ce" else "bce",
        .hebrew => "am",
        .indian => "shaka",
        .@"islamic-civil", .@"islamic-tbla", .@"islamic-umalqura" => "ah",
        .persian => "ap",
        .roc => if (data.year > 0) "roc" else "broc",
        .japanese => blk: {
            const epoch = cal.toEpochDay(ymd.year, ymd.month, ymd.day);
            const starts = .{ .{ 2019, 5, 1, "reiwa" }, .{ 1989, 1, 8, "heisei" }, .{ 1926, 12, 25, "showa" }, .{ 1912, 7, 30, "taisho" }, .{ 1868, 9, 8, "meiji" } };
            inline for (starts) |entry| if (epoch >= cal.toEpochDay(entry[0], entry[1], entry[2])) break :blk entry[3];
            break :blk if (ymd.year > 0) "ce" else "bce";
        },
    };
}
pub fn fromString(text: []const u8) E!Id {
    const index = std.mem.indexOf(u8, text, "u-ca=") orelse return .iso8601;
    const value = text[index + 5 ..];
    const end = std.mem.indexOfScalar(u8, value, ']') orelse return error.RangeError;
    return parse(value[0..end]);
}
extern fn z_calendar_diff([*:0]const u8, i64, i64, c_int, *i64, *i64, *i64) c_int;
pub fn difference(id: Id, start: cal.YearMonthDay, end: cal.YearMonthDay, largest: @import("rounding.zig").Unit) E!@import("plain_date.zig").DateDiff {
    if (!enabled) return error.RangeError;
    var years: i64 = 0;
    var months: i64 = 0;
    var days: i64 = 0;
    try check(z_calendar_diff(calendarName(id), cal.toEpochDay(start.year, start.month, start.day), cal.toEpochDay(end.year, end.month, end.day), @intCast(@backingInt(largest)), &years, &months, &days));
    const weeks = if (largest == .week) @divTrunc(days, 7) else 0;
    return .{ .years = years, .months = months, .weeks = weeks, .days = days - weeks * 7, .intermediate = start };
}
pub fn isoMonth(code: ?[]const u8, month: ?i32) E!i32 {
    if (code) |text| {
        if (text.len != 3 or text[0] != 'M' or !std.ascii.isDigit(text[1]) or !std.ascii.isDigit(text[2])) return error.RangeError;
        const value = std.fmt.parseInt(i32, text[1..], 10) catch return error.RangeError;
        if (value < 1 or value > 12 or (month != null and month.? != value)) return error.RangeError;
        return value;
    }
    return month orelse error.TypeError;
}

pub fn displayName(id: Id) []const u8 {
    return if (id == .ethioaa) "ethiopic" else @tagName(id);
}
pub fn resolveYear(id: Id, year: ?i32, era_name: ?[]const u8, era_year: ?i32) E!i32 {
    if (id == .iso8601) return year orelse error.TypeError;
    if (era_name == null and era_year == null) return year orelse error.TypeError;
    const era_value = era_name orelse return error.TypeError;
    const value = era_year orelse return error.TypeError;
    var result: i64 = value;
    switch (id) {
        .gregory => {
            if (std.ascii.eqlIgnoreCase(era_value, "bce") or std.ascii.eqlIgnoreCase(era_value, "bc")) result = 1 - @as(i64, value) else if (!std.ascii.eqlIgnoreCase(era_value, "ce") and !std.ascii.eqlIgnoreCase(era_value, "ad")) return error.RangeError;
        },
        .japanese => {
            const names = .{ "meiji", "taisho", "showa", "heisei", "reiwa" };
            const bases = .{ 1867, 1911, 1925, 1988, 2018 };
            var matched = false;
            inline for (names, bases) |n, b| if (std.ascii.eqlIgnoreCase(n, era_value)) {
                result = @as(i64, value) + b;
                matched = true;
            };
            if (!matched) {
                if (std.ascii.eqlIgnoreCase(era_value, "bce")) result = 1 - @as(i64, value) else if (!std.ascii.eqlIgnoreCase(era_value, "ce")) return error.RangeError;
            }
        },
        .roc => {
            if (std.ascii.eqlIgnoreCase(era_value, "broc")) result = 1 - @as(i64, value) else if (!std.ascii.eqlIgnoreCase(era_value, "roc")) return error.RangeError;
        },
        .ethiopic => {
            if (std.ascii.eqlIgnoreCase(era_value, "aa")) result = @as(i64, value) - 5500 else if (!std.ascii.eqlIgnoreCase(era_value, "am")) return error.RangeError;
        },
        .ethioaa => {
            if (!std.ascii.eqlIgnoreCase(era_value, "aa")) return error.RangeError;
        },
        .coptic => {
            if (std.ascii.eqlIgnoreCase(era_value, "before-am")) result = 1 - @as(i64, value) else if (!std.ascii.eqlIgnoreCase(era_value, "am")) return error.RangeError;
        },
        .chinese, .dangi => return error.TypeError,
        else => {},
    }
    if (result < std.math.minInt(i32) or result > std.math.maxInt(i32)) return error.RangeError;
    const resolved: i32 = @intCast(result);
    if (year) |y| if (y != resolved) return error.RangeError;
    return resolved;
}
pub fn eraYear(id: Id, data: Info, ymd: cal.YearMonthDay) ?i32 {
    const era_name = era(id, data, ymd) orelse return null;
    if (id == .japanese and (std.mem.eql(u8, era_name, "ce") or std.mem.eql(u8, era_name, "bce"))) return if (ymd.year > 0) ymd.year else 1 - ymd.year;
    return data.era_year;
}

pub fn equal(a: Id, b: Id) bool {
    return std.mem.eql(u8, displayName(a), displayName(b));
}
