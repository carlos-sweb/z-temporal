//! `Temporal.Now`. Phase 6 shipped only `instant()` -- every other `Now`
//! function needed a real local/named timezone offset, deferred to
//! `ZonedDateTime` (Phase 7a, now done). This file closes those out:
//! `zonedDateTimeISO`/`plainDateISO`/`plainTimeISO`/`plainDateTimeISO`
//! take an explicit `time_zone_id` (this repo's existing pattern of
//! preferring an explicit parameter over a JS-style "optional, defaults
//! to system zone" argument); `timeZoneId()` is the one function that
//! actually detects the system's configured zone.
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

/// Current wall-clock time. Ground-truthed Zig 0.16 has no portable
/// timestamp API (`std.time.nanoTimestamp` etc. were removed -- the
/// replacement needs an `std.Io` instance); uses the same raw Linux
/// `clock_gettime` syscall `z-interpreter`/`z-value`'s Date wiring
/// already established as this ecosystem's answer to that gap
/// (documented there as Linux-only "for now, like the dev setup").
pub fn instant() Instant {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    const ns: i128 = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
    // Always in Instant's representable range for any real wall-clock
    // time -- `fromEpochNanoseconds` only rejects far outside it -- so
    // `catch unreachable` here, matching how this repo's other
    // always-succeeds paths are written, rather than threading a
    // TemporalError a real clock read can't actually produce.
    return Instant.fromEpochNanoseconds(ns) catch unreachable;
}

pub fn zonedDateTimeISO(allocator: std.mem.Allocator, io: std.Io, time_zone_id: []const u8) TemporalError!ZonedDateTime {
    return instant().toZonedDateTimeISO(allocator, io, time_zone_id);
}

pub fn plainDateISO(allocator: std.mem.Allocator, io: std.Io, time_zone_id: []const u8) TemporalError!plain_date_mod.PlainDate {
    return (try zonedDateTimeISO(allocator, io, time_zone_id)).toPlainDate(allocator, io);
}

pub fn plainTimeISO(allocator: std.mem.Allocator, io: std.Io, time_zone_id: []const u8) TemporalError!plain_time_mod.PlainTime {
    return (try zonedDateTimeISO(allocator, io, time_zone_id)).toPlainTime(allocator, io);
}

pub fn plainDateTimeISO(allocator: std.mem.Allocator, io: std.Io, time_zone_id: []const u8) TemporalError!plain_date_time_mod.PlainDateTime {
    return (try zonedDateTimeISO(allocator, io, time_zone_id)).toPlainDateTime(allocator, io);
}

/// The system's configured IANA zone name -- same POSIX detection order
/// `zdate.Timezone.loadSystem` documents (1. `TZ` env var, when `environ`
/// is given and names an IANA zone; 2. `/etc/localtime`, resolved as a
/// symlink into the zoneinfo directory, e.g. `../usr/share/zoneinfo/
/// America/Santiago` -> `America/Santiago`; ground-truthed present and
/// symlinked this way in this sandbox). Returns an allocator-owned slice
/// (caller frees), matching this repo's `toIsoString`-family convention.
/// `error.InvalidTimeZone` if neither source resolves to a name (e.g. a
/// non-symlink `/etc/localtime`, or a raw POSIX rule string in `TZ`).
pub fn timeZoneId(allocator: std.mem.Allocator, io: std.Io, environ: ?std.process.Environ) TemporalError![]u8 {
    if (environ) |env| {
        if (env.getPosix("TZ")) |raw| {
            const name = if (raw.len > 0 and raw[0] == ':') raw[1..] else raw;
            if (name.len > 0 and name[0] != '/' and std.mem.indexOf(u8, name, "..") == null) {
                return try allocator.dupe(u8, name);
            }
        }
    }

    var buf: [512]u8 = undefined;
    const len = std.Io.Dir.readLinkAbsolute(io, "/etc/localtime", &buf) catch return error.InvalidTimeZone;
    const target = buf[0..len];
    const marker = "zoneinfo/";
    const idx = std.mem.indexOf(u8, target, marker) orelse return error.InvalidTimeZone;
    const name = target[idx + marker.len ..];
    if (name.len == 0) return error.InvalidTimeZone;
    return try allocator.dupe(u8, name);
}
