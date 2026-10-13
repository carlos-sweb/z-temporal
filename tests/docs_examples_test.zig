//! Compiled README examples.
const std = @import("std");
const Temporal = @import("ztemporal");

test "date construction and arithmetic" {
    const date = try Temporal.PlainDate.from(.{ .fields = .{
        .year = 2024,
        .monthCode = "M02",
        .day = 29,
    } }, .{});
    const changed = try date.with(.{ .month = 3 }, .{});
    const next = try changed.add(.{ .days = 1 }, .constrain);
    const text = try next.toString(std.testing.allocator, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("2024-03-30", text);
}

test "one calendar day differs from 24 hours" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const start = try Temporal.ZonedDateTime.from(allocator, io, .{ .string = "2024-03-09T12:00[America/New_York]" }, .{});
    const next = try start.add(allocator, io, .{ .days = 1 }, .constrain);
    const elapsed = try start.until(allocator, io, next, .{ .largestUnit = .hour });
    try std.testing.expectEqual(@as(f64, 23), elapsed.hours);
}
