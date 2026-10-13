const std = @import("std");
const E = @import("errors.zig").TemporalError;
const calendar = @import("calendar.zig");
const enabled = @import("build_options").intl;
pub const Width = enum { numeric, @"2-digit", narrow, short, long };
pub const Style = enum { full, long, medium, short };
pub const HourCycle = enum { h11, h12, h23, h24 };
pub const LocaleOptions = struct {
    calendar: ?[]const u8 = null,
    timeZone: ?[]const u8 = null,
    dateStyle: ?Style = null,
    timeStyle: ?Style = null,
    year: ?Width = null,
    month: ?Width = null,
    day: ?Width = null,
    weekday: ?Width = null,
    era: ?Width = null,
    hour: ?Width = null,
    minute: ?Width = null,
    second: ?Width = null,
    timeZoneName: ?Width = null,
    fractionalSecondDigits: ?u8 = null,
    hour12: ?bool = null,
    hourCycle: ?HourCycle = null,
};
pub const Kind = enum { date, time, dateTime, yearMonth, monthDay, instant, zoned };
extern fn z_locale_date([*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, c_int, c_int, f64, [*]u8, c_int) c_int;
fn numeric(writer: *std.Io.Writer, width: ?Width, char: u8) !void {
    if (width) |value| {
        if (value != .numeric and value != .@"2-digit") return error.RangeError;
        try writer.writeByte(char);
        if (value == .@"2-digit") try writer.writeByte(char);
    }
}
fn text(writer: *std.Io.Writer, width: ?Width, char: u8) !void {
    if (width) |value| {
        const count: usize = switch (value) {
            .short => 3,
            .long => 4,
            .narrow => 5,
            else => return error.RangeError,
        };
        for (0..count) |_| try writer.writeByte(char);
    }
}
pub fn format(allocator: std.mem.Allocator, io: std.Io, kind: Kind, millis: f64, own_calendar: calendar.Id, own_zone: ?[]const u8, locales: ?[]const u8, options: LocaleOptions) E![]u8 {
    if (!enabled) return error.TypeError;
    const locale = locales orelse "en-US";
    var locale_calendar: []const u8 = "gregory";
    if (std.mem.indexOf(u8, locale, "-u-ca-")) |index| {
        const tail = locale[index + 6 ..];
        var end = tail.len;
        var cursor: usize = 0;
        while (cursor < tail.len) {
            const next = std.mem.indexOfScalarPos(u8, tail, cursor, '-') orelse break;
            const after = std.mem.indexOfScalarPos(u8, tail, next + 1, '-') orelse tail.len;
            if (after - next - 1 == 2) {
                end = next;
                break;
            }
            cursor = next + 1;
        }
        locale_calendar = tail[0..end];
    }
    const id = try calendar.parse(options.calendar orelse locale_calendar);
    if (own_calendar != .iso8601 and id != own_calendar) return error.RangeError;
    if ((kind == .yearMonth or kind == .monthDay) and id != own_calendar) return error.RangeError;
    if (kind == .zoned and options.timeZone != null) return error.TypeError;
    const has_styles = options.dateStyle != null or options.timeStyle != null;
    const explicit_date = options.year != null or options.month != null or options.day != null or options.weekday != null or options.era != null;
    const explicit_time = options.hour != null or options.minute != null or options.second != null or options.timeZoneName != null or options.fractionalSecondDigits != null;
    if (has_styles and (explicit_date or explicit_time)) return error.TypeError;
    if (options.timeStyle != null and (kind == .date or kind == .yearMonth or kind == .monthDay)) return error.TypeError;
    if (options.dateStyle != null and (kind == .time or kind == .yearMonth or kind == .monthDay)) return error.TypeError;
    const default_date = !explicit_date and !explicit_time and !has_styles and kind != .time;
    const default_time = !explicit_date and !explicit_time and !has_styles and (kind == .time or kind == .dateTime or kind == .instant or kind == .zoned);
    var buf: [128]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buf);
    const w = &fixed;
    numeric(w, options.year orelse if (default_date and kind != .monthDay) Width.numeric else null, 'y') catch |e| return map(e);
    if (options.month orelse if (default_date) Width.numeric else null) |month| {
        const count: usize = switch (month) {
            .numeric => 1,
            .@"2-digit" => 2,
            .short => 3,
            .long => 4,
            .narrow => 5,
        };
        for (0..count) |_| w.writeByte('M') catch return error.RangeError;
    }
    numeric(w, options.day orelse if (default_date and kind != .yearMonth) Width.numeric else null, 'd') catch |e| return map(e);
    text(w, options.weekday, 'E') catch |e| return map(e);
    text(w, options.era, 'G') catch |e| return map(e);
    const hc: u8 = if (options.hour12) |h| (if (h) 'h' else 'H') else if (options.hourCycle) |cycle| switch (cycle) {
        .h11 => 'K',
        .h12 => 'h',
        .h23 => 'H',
        .h24 => 'k',
    } else 'j';
    numeric(w, options.hour orelse if (default_time) Width.numeric else null, hc) catch |e| return map(e);
    numeric(w, options.minute orelse if (default_time) Width.numeric else null, 'm') catch |e| return map(e);
    numeric(w, options.second orelse if (default_time) Width.numeric else null, 's') catch |e| return map(e);
    text(w, options.timeZoneName orelse if (default_time and kind == .zoned) Width.short else null, 'z') catch |e| return map(e);
    if (options.fractionalSecondDigits) |digits| {
        if (digits < 1 or digits > 3) return error.RangeError;
        for (0..digits) |_| w.writeByte('S') catch return error.RangeError;
    }
    var detected: ?[]u8 = null;
    defer if (detected) |name| allocator.free(name);
    if ((kind == .instant) and options.timeZone == null and own_zone == null) detected = try @import("now.zig").timeZoneId(allocator, io, null);
    const zone = options.timeZone orelse own_zone orelse detected orelse "UTC";
    if (options.timeZone != null) {
        var loaded = try @import("timezone.zig").load(allocator, io, zone);
        loaded.deinit();
    }
    const loc = try allocator.dupeSentinel(u8, locale, 0);
    defer allocator.free(loc);
    const cal = try allocator.dupeSentinel(u8, @tagName(id), 0);
    defer allocator.free(cal);
    const tz = if (zone.len > 0 and (zone[0] == '+' or zone[0] == '-')) blk: {
        const combined = try allocator.print("GMT{s}", .{zone});
        defer allocator.free(combined);
        break :blk try allocator.dupeSentinel(u8, combined, 0);
    } else try allocator.dupeSentinel(u8, zone, 0);
    defer allocator.free(tz);
    const pattern = try allocator.dupeSentinel(u8, buf[0..fixed.end], 0);
    defer allocator.free(pattern);
    var output: [4096]u8 = undefined;
    const length = z_locale_date(loc, cal, tz, pattern, if (options.dateStyle) |style| @intCast(@backingInt(style)) else -1, if (options.timeStyle) |style| @intCast(@backingInt(style)) else -1, millis, &output, output.len);
    if (length == -2) return error.OutOfMemory;
    if (length < 0) return error.RangeError;
    // ECMA Intl's date-time patterns use regular spaces before day periods.
    const raw = output[0..@intCast(length)];
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        if (std.mem.startsWith(u8, raw[i..], "\xe2\x80\xaf")) {
            try list.append(allocator, ' ');
            i += 3;
        } else if (std.mem.startsWith(u8, raw[i..], "\xc2\xa0")) {
            try list.append(allocator, ' ');
            i += 2;
        } else {
            try list.append(allocator, raw[i]);
            i += 1;
        }
    }
    return list.toOwnedSlice(allocator);
}
fn map(err: anyerror) E {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.RangeError;
}
pub const DurationStyle = enum { long, short, narrow, digital };
pub const DurationLocaleOptions = struct { style: DurationStyle = .short, fractionalSecondDigits: ?u8 = null };
extern fn z_locale_duration([*:0]const u8, [*]const f64, c_int, c_int, [*]u8, c_int) c_int;
pub fn duration(allocator: std.mem.Allocator, locales: ?[]const u8, values: [10]f64, options: DurationLocaleOptions) E![]u8 {
    if (!enabled) return error.TypeError;
    if (options.fractionalSecondDigits) |digits| if (digits > 9) return error.RangeError;
    const locale = try allocator.dupeSentinel(u8, locales orelse "en-US", 0);
    defer allocator.free(locale);
    var buf: [4096]u8 = undefined;
    const count = z_locale_duration(locale, &values, @intCast(@backingInt(options.style)), if (options.fractionalSecondDigits) |d| d else -1, &buf, buf.len);
    if (count == -2) return error.OutOfMemory;
    if (count < 0) return error.RangeError;
    return allocator.dupe(u8, buf[0..@intCast(count)]);
}

extern fn z_icu_version() [*:0]const u8;
pub fn dataVersion() ?[]const u8 {
    return if (enabled) std.mem.span(z_icu_version()) else null;
}
extern fn z_system_zone([*]u8, c_int) c_int;
pub fn systemTimeZone(allocator: std.mem.Allocator) E!?[]u8 {
    if (!enabled) return null;
    var buf: [1024]u8 = undefined;
    const count = z_system_zone(&buf, buf.len);
    if (count == -2) return error.OutOfMemory;
    if (count < 0) return error.IoError;
    return try allocator.dupe(u8, buf[0..@intCast(count)]);
}
