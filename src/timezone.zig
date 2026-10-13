const std = @import("std");
const zdate = @import("zdate");
pub const directory = @import("build_options").tzdataDirectory;
const E = @import("errors.zig").TemporalError;
pub const Zone = struct {
    fixed: ?i64 = null,
    named: ?zdate.Timezone = null,
    pub fn deinit(self: *Zone) void {
        if (self.named) |*tz| tz.deinit();
    }
    pub fn offsetAtUtc(self: *const Zone, ms: i64) i64 {
        return if (self.fixed) |offset| offset else self.named.?.offsetAtUtc(ms);
    }
    pub fn utcFromLocal(self: *const Zone, ms: i64) i64 {
        return if (self.fixed) |offset| ms - offset else self.named.?.utcFromLocal(ms);
    }
};
pub fn fixedOffset(name: []const u8) E!?i64 {
    if (name.len == 0 or (name[0] != '+' and name[0] != '-')) return null;
    if (name.len != 3 and name.len != 5 and name.len != 6) return error.RangeError;
    const h = std.fmt.parseInt(u8, name[1..3], 10) catch return error.RangeError;
    var m: u8 = 0;
    if (name.len == 5) m = std.fmt.parseInt(u8, name[3..5], 10) catch return error.RangeError;
    if (name.len == 6) {
        if (name[3] != ':') return error.RangeError;
        m = std.fmt.parseInt(u8, name[4..6], 10) catch return error.RangeError;
    }
    if (h > 23 or m > 59) return error.RangeError;
    const ms = (@as(i64, h) * 60 + m) * 60_000;
    return if (name[0] == '-') -ms else ms;
}
pub fn load(allocator: std.mem.Allocator, io: std.Io, name: []const u8) E!Zone {
    if (std.ascii.eqlIgnoreCase(name, "UTC")) return .{ .fixed = 0 };
    if (try fixedOffset(name)) |ms| return .{ .fixed = ms };
    const canonical_name = try canonical(allocator, io, name);
    defer allocator.free(canonical_name);
    return (try loadExact(allocator, io, canonical_name)) orelse error.RangeError;
}
pub fn normalize(buf: []u8, name: []const u8) E![]const u8 {
    if (try fixedOffset(name)) |ms| {
        const magnitude: u64 = @abs(@divTrunc(ms, 60_000));
        return std.fmt.bufPrint(buf, "{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (ms < 0) '-' else '+'), magnitude / 60, magnitude % 60 }) catch error.RangeError;
    }
    if (std.ascii.eqlIgnoreCase(name, "UTC")) return "UTC";
    return name;
}

pub fn posixTransition(rule: anytype, year: i32, offset_ms: i64) i64 {
    const cal = @import("iso_calendar.zig");
    var epoch_day = cal.toEpochDay(year, 1, 1);
    switch (rule.kind) {
        .julian_leap => epoch_day += rule.day,
        .julian_no_leap => epoch_day += rule.day - 1 + @as(i64, if (cal.isLeapYear(year) and rule.day >= 60) 1 else 0),
        .month_week_day => {
            const month: u8 = @intCast(rule.month);
            const first_dow = @mod(@as(i32, cal.dayOfWeek(year, month, 1)), 7);
            var day = 1 + @mod(rule.day - first_dow, 7) + (rule.week - 1) * 7;
            if (day > cal.daysInMonth(year, month)) day -= 7;
            epoch_day = cal.toEpochDay(year, month, @intCast(day));
        },
    }
    return @divFloor(epoch_day * 86_400_000 + rule.time_ms - offset_ms, 1000);
}
pub fn canonical(allocator: std.mem.Allocator, io: std.Io, raw: []const u8) E![]u8 {
    if (std.ascii.eqlIgnoreCase(raw, "UTC")) return allocator.dupe(u8, "UTC");
    var buf: [255]u8 = undefined;
    const normalized = try normalize(&buf, raw);
    if (try fixedOffset(normalized) != null) return allocator.dupe(u8, normalized);
    var direct = loadExact(allocator, io, normalized) catch |err| blk: {
        if (err != error.RangeError) return err;
        var root = std.Io.Dir.openDirAbsolute(io, directory, .{ .iterate = true }) catch return error.IoError;
        defer root.close(io);
        var walker = try root.walk(allocator);
        defer walker.deinit();
        while (walker.next(io) catch return error.IoError) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.path, normalized)) return allocator.dupe(u8, entry.path);
        }
        break :blk null;
    };
    if (direct) |*zone| {
        zone.deinit();
        return allocator.dupe(u8, normalized);
    }
    return error.RangeError;
}
fn loadExact(allocator: std.mem.Allocator, io: std.Io, name: []const u8) E!?Zone {
    if (name.len == 0 or name[0] == '/' or std.mem.indexOf(u8, name, "..") != null) return error.RangeError;
    const path = try allocator.print("{s}/{s}", .{ directory, name });
    defer allocator.free(path);
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.RangeError,
        else => return error.IoError,
    };
    if (stat.kind != .file) return error.RangeError;
    const tz = zdate.Timezone.loadFromFile(allocator, io, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound, error.NotDir => return error.RangeError,
        else => return error.IoError,
    };
    return .{ .named = tz };
}
pub fn primary(name: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(name, "UTC") or std.ascii.eqlIgnoreCase(name, "Etc/UTC") or std.ascii.eqlIgnoreCase(name, "Etc/GMT") or std.ascii.eqlIgnoreCase(name, "GMT")) return "UTC";
    var value = name;
    for (0..32) |_| {
        if (@import("timezone_links.zig").links.get(value)) |target| value = target else return value;
    }
    return value;
}
