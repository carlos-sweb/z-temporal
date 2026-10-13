const std = @import("std");
const r = @import("rounding.zig");
const E = @import("errors.zig").TemporalError;
pub const CalendarName = enum { auto, always, never, critical };
pub const TimeZoneName = enum { auto, never, critical };
pub const Offset = enum { auto, never };
pub const StringOptions = struct {
    fractionalSecondDigits: ?u8 = null,
    smallestUnit: ?r.Unit = null,
    roundingMode: r.RoundingMode = .trunc,
    calendarName: CalendarName = .auto,
    timeZoneName: TimeZoneName = .auto,
    offset: Offset = .auto,
    timeZone: ?[]const u8 = null,
    io: ?std.Io = null,
};
pub const Precision = struct { unit: r.Unit = .nanosecond, increment: u32 = 1, digits: ?u8 = null, minute: bool = false };
pub fn precision(options: StringOptions) E!Precision {
    if (options.fractionalSecondDigits) |digits| if (digits > 9) return error.RangeError;
    if (options.smallestUnit) |unit| return switch (unit) {
        .minute => .{ .unit = .minute, .minute = true },
        .second => .{ .unit = .second, .digits = 0 },
        .millisecond => .{ .unit = .millisecond, .digits = 3 },
        .microsecond => .{ .unit = .microsecond, .digits = 6 },
        .nanosecond => .{ .digits = 9 },
        else => error.RangeError,
    };
    const d = options.fractionalSecondDigits orelse return .{};
    const unit: r.Unit = if (d == 0) .second else if (d <= 3) .millisecond else if (d <= 6) .microsecond else .nanosecond;
    const power: u8 = if (d == 0) 0 else if (d <= 3) 3 - d else if (d <= 6) 6 - d else 9 - d;
    var increment: u32 = 1;
    for (0..power) |_| {
        increment *= 10;
    }
    return .{ .unit = unit, .increment = increment, .digits = d };
}
pub fn calendar(allocator: std.mem.Allocator, text: []const u8, critical: bool) E![]u8 {
    if (!critical) return allocator.dupe(u8, text);
    const index = std.mem.indexOf(u8, text, "[u-ca=") orelse return allocator.dupe(u8, text);
    return allocator.print("{s}[!{s}", .{ text[0..index], text[index + 1 ..] });
}
pub fn time(allocator: std.mem.Allocator, text: []const u8, p: Precision) E![]u8 {
    const start = if (std.mem.indexOfScalar(u8, text, 'T')) |index| index + 1 else 0;
    const seconds = start + 8;
    if (text.len < seconds) return error.RangeError;
    var suffix = seconds;
    if (suffix < text.len and text[suffix] == '.') {
        suffix += 1;
        while (suffix < text.len and std.ascii.isDigit(text[suffix])) suffix += 1;
    }
    if (p.minute) return allocator.print("{s}{s}", .{ text[0 .. start + 5], text[suffix..] });
    const digits = p.digits orelse return allocator.dupe(u8, text);
    if (digits == 0) return allocator.print("{s}{s}", .{ text[0..seconds], text[suffix..] });
    var fraction: [9]u8 = @splat('0');
    if (seconds < text.len and text[seconds] == '.') {
        const count = @min(suffix - seconds - 1, 9);
        @memcpy(fraction[0..count], text[seconds + 1 .. seconds + 1 + count]);
    }
    return allocator.print("{s}.{s}{s}", .{ text[0..seconds], fraction[0..digits], text[suffix..] });
}
