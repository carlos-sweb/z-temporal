//! Temporal.Now: explicit std.Io clock access and system or specified time zones.
const std = @import("std");
const instant_mod = @import("instant.zig");
const Instant = instant_mod.Instant;
const zoned_date_time = @import("zoned_date_time.zig");
const ZonedDateTime = zoned_date_time.ZonedDateTime;
const plain_date_mod = @import("plain_date.zig");
const plain_time_mod = @import("plain_time.zig");
const plain_date_time_mod = @import("plain_date_time.zig");
const errors = @import("errors.zig");
const TemporalError = errors.TemporalError;

/// Current wall-clock instant, using Zig's portable real clock.
pub fn instant(io: std.Io) Instant {
    return Instant.fromEpochNanoseconds(std.Io.Clock.real.now(io).nanoseconds) catch unreachable;
}

pub fn zonedDateTimeISO(allocator: std.mem.Allocator, io: std.Io, time_zone_id: ?[]const u8) TemporalError!ZonedDateTime {
    const detected = if (time_zone_id == null) try timeZoneId(allocator, io, null) else null;
    defer if (detected) |name| allocator.free(name);
    return instant(io).toZonedDateTimeISO(allocator, io, time_zone_id orelse detected.?);
}

pub fn plainDateISO(allocator: std.mem.Allocator, io: std.Io, time_zone_id: ?[]const u8) TemporalError!plain_date_mod.PlainDate {
    return (try zonedDateTimeISO(allocator, io, time_zone_id)).toPlainDate(allocator, io);
}

pub fn plainTimeISO(allocator: std.mem.Allocator, io: std.Io, time_zone_id: ?[]const u8) TemporalError!plain_time_mod.PlainTime {
    return (try zonedDateTimeISO(allocator, io, time_zone_id)).toPlainTime(allocator, io);
}

pub fn plainDateTimeISO(allocator: std.mem.Allocator, io: std.Io, time_zone_id: ?[]const u8) TemporalError!plain_date_time_mod.PlainDateTime {
    return (try zonedDateTimeISO(allocator, io, time_zone_id)).toPlainDateTime(allocator, io);
}

/// Detect a named system zone. Supply Environ to honor TZ explicitly.
/// Uses /etc/localtime names or copied TZif data, then ICU when enabled,
/// and the specification's UTC fallback when no host name is available.
pub fn timeZoneId(allocator: std.mem.Allocator, io: std.Io, environ: ?std.process.Environ) TemporalError![]u8 {
    const timezone = @import("timezone.zig");
    if (environ) |env| if (env.getPosix("TZ")) |raw| {
        const name = if (raw.len > 0 and raw[0] == ':') raw[1..] else raw;
        return timezone.canonical(allocator, io, name) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.IoError => return err,
            else => return allocator.dupe(u8, "UTC"),
        };
    };
    var buf: [512]u8 = undefined;
    const len = std.Io.Dir.readLinkAbsolute(io, "/etc/localtime", &buf) catch 0;
    if (len > 0) {
        const target = buf[0..len];
        if (std.mem.indexOf(u8, target, "zoneinfo/")) |idx| return timezone.canonical(allocator, io, target[idx + 9 ..]);
    }
    const local = std.Io.Dir.cwd().readFileAlloc(io, "/etc/localtime", allocator, .limited(1_048_576)) catch null;
    if (local) |bytes| {
        defer allocator.free(bytes);
        var root = std.Io.Dir.openDirAbsolute(io, timezone.directory, .{ .iterate = true }) catch return error.IoError;
        defer root.close(io);
        var walker = try root.walk(allocator);
        defer walker.deinit();
        while (walker.next(io) catch return error.IoError) |entry| {
            if (entry.kind == .directory) continue;
            const candidate = root.readFileAlloc(io, entry.path, allocator, .limited(1_048_576)) catch continue;
            const same = std.mem.eql(u8, bytes, candidate);
            allocator.free(candidate);
            if (same) return allocator.dupe(u8, timezone.primary(entry.path));
        }
    }
    if (try @import("locale.zig").systemTimeZone(allocator)) |name| return name;
    return allocator.dupe(u8, "UTC");
}
