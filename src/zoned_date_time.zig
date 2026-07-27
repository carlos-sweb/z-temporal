//! `Temporal.ZonedDateTime`, Phase 7a: construction, disambiguation/offset
//! resolution, getters, conversions, string parse/format. The one
//! architecture departure in this whole project so far -- every other
//! type here is a pure value needing at most an allocator for string
//! formatting; this type needs real IANA timezone data (I/O to read
//! `/usr/share/zoneinfo/...`, an allocator to parse the TZif transition
//! table), so its timezone-dependent methods take `allocator`/`io`.
//!
//! Reuses `zdate.Timezone` (`z-date`'s `tzdata.zig`) directly, per-call,
//! never stored long-term -- the "process-global timezone model" earlier
//! project notes flagged as a blocker is `z-date`'s separate,
//! Date-specific `timezone.zig` wrapper; the underlying `Timezone` type
//! itself is already a clean, per-value building block.
//!
//! Ground-truthed non-ISO calendars are NOT accepted here (unlike
//! `Instant`, which silently ignores any calendar annotation): real
//! Temporal's `ZonedDateTime` getters genuinely depend on calendar
//! semantics (e.g. a `u-ca=hebrew` annotation changes `.year`/`.month`/
//! `.day` to Hebrew-calendar values), so accepting-and-ignoring one here
//! would compute iso8601 values while claiming a different calendar --
//! this repo's established "reject non-iso8601" policy (matching every
//! Plain type) applies, not `Instant`'s exception.
const std = @import("std");
const Allocator = std.mem.Allocator;
const zdate = @import("zdate");
const iso_calendar = @import("iso_calendar.zig");
const iso_string = @import("iso_string.zig");
const errors = @import("errors.zig");
const TemporalError = errors.TemporalError;
const plain_date_mod = @import("plain_date.zig");
const PlainDate = plain_date_mod.PlainDate;
const Overflow = plain_date_mod.Overflow;
const plain_time_mod = @import("plain_time.zig");
const PlainTime = plain_time_mod.PlainTime;
const plain_date_time_mod = @import("plain_date_time.zig");
const PlainDateTime = plain_date_time_mod.PlainDateTime;
const plain_year_month = @import("plain_year_month.zig");
const plain_month_day = @import("plain_month_day.zig");
const instant_mod = @import("instant.zig");
const Instant = instant_mod.Instant;
const duration_mod = @import("duration.zig");
const Duration = duration_mod.Duration;

const NS_PER_DAY: i128 = 86_400_000_000_000;
const NS_PER_MS: i128 = 1_000_000;

/// Governs conflicts between a given numeric offset and what the time
/// zone actually says at that wall-clock time -- ground-truthed default
/// is `.reject` (different from `Disambiguation`'s default).
pub const OffsetOption = enum { use, prefer, ignore, reject };

/// Governs how a nonexistent (DST gap) or repeated (DST fold) wall-clock
/// time resolves to an instant -- ground-truthed default is `.compatible`.
pub const Disambiguation = enum { compatible, earlier, later, reject };

const TIME_ZONE_ID_MAX = 48;

/// Loads `time_zone_id` as a real IANA zone. Transient -- callers
/// `deinit()` it immediately after use, never stored on a `ZonedDateTime`
/// value (kept a plain, deinit-free struct like every other type here).
fn loadTimeZone(allocator: Allocator, io: std.Io, time_zone_id: []const u8) TemporalError!zdate.Timezone {
    return zdate.Timezone.loadNamed(allocator, io, time_zone_id) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidTimeZone,
    };
}

/// Resolves a wall-clock instant (`local_ms`, the epoch-ms value you'd
/// get by interpreting the local date+time fields literally as UTC --
/// matches `zdate.Timezone.utcFromLocal`'s own input convention) to a
/// real UTC epoch-ms value, per `disambiguation`.
///
/// `.compatible` reuses `utcFromLocal` directly -- ground-truthed
/// byte-for-byte against real Node to already implement exactly that
/// mode for both a DST gap (`2024-03-10T02:30` in `America/New_York` ->
/// `03:30-04:00`) and a DST fold (`2024-11-03T01:30` -> the earlier
/// `-04:00` occurrence).
///
/// The other 3 modes reuse the same before/after probing technique
/// `utcFromLocal` uses internally, then pick by comparing the two
/// resulting UTC candidates directly (`.earlier` = the smaller,
/// `.later` = the larger) -- ground-truthed this simple min/max rule
/// holds uniformly across BOTH a gap and a fold (only `.compatible`
/// treats the two asymmetrically: forward-skip for a gap, first-occurrence
/// for a fold -- which is exactly why it's handled separately via
/// `utcFromLocal` above, not folded into this min/max rule).
fn resolveWallClock(tz: *const zdate.Timezone, local_ms: i64, disambiguation: Disambiguation) TemporalError!i64 {
    if (disambiguation == .compatible) return tz.utcFromLocal(local_ms);

    const probe_distance: i64 = 86_400_000;
    const offset_before = tz.offsetAtUtc(local_ms -| probe_distance);
    const utc_with_before = local_ms -| offset_before;
    const before_ok = tz.offsetAtUtc(utc_with_before) == offset_before;

    const offset_after = tz.offsetAtUtc(local_ms +| probe_distance);
    const utc_with_after = local_ms -| offset_after;
    const after_ok = tz.offsetAtUtc(utc_with_after) == offset_after;

    // Unambiguous: at most one candidate is self-consistent, or both are
    // and they agree (far from any transition).
    if (before_ok and !after_ok) return utc_with_before;
    if (after_ok and !before_ok) return utc_with_after;
    if (before_ok and after_ok and utc_with_before == utc_with_after) return utc_with_before;

    // Ambiguous (fold: both self-consistent but different; gap: neither
    // self-consistent) -- ground-truthed the smaller/larger rule holds
    // for both.
    return switch (disambiguation) {
        .earlier => @min(utc_with_before, utc_with_after),
        .later => @max(utc_with_before, utc_with_after),
        .reject => error.AmbiguousTime,
        .compatible => unreachable,
    };
}

pub const ZonedDateTime = struct {
    epoch_nanoseconds: i128,
    time_zone_buf: [TIME_ZONE_ID_MAX]u8,
    time_zone_len: u8,

    // Pointer receiver, deliberately -- a value receiver here would make
    // every call site pass a fresh byval copy of `ZonedDateTime`, and the
    // returned slice would borrow from that copy's temporary storage
    // (reused by the very next call, e.g. a following `std.debug.print`
    // or `std.fmt.bufPrint`), corrupting the string it points to. A
    // pointer receiver borrows from the caller's real, addressable
    // `ZonedDateTime` value instead, which is always what every call
    // site here actually has.
    pub fn timeZoneId(self: *const ZonedDateTime) []const u8 {
        return self.time_zone_buf[0..self.time_zone_len];
    }

    pub fn calendarId(self: ZonedDateTime) []const u8 {
        _ = self;
        return "iso8601";
    }

    fn make(epoch_nanoseconds: i128, time_zone_id: []const u8) TemporalError!ZonedDateTime {
        if (epoch_nanoseconds < instant_mod.MIN_EPOCH_NS or epoch_nanoseconds > instant_mod.MAX_EPOCH_NS) return error.InvalidRange;
        if (time_zone_id.len == 0 or time_zone_id.len > TIME_ZONE_ID_MAX) return error.InvalidTimeZone;
        var result: ZonedDateTime = .{ .epoch_nanoseconds = epoch_nanoseconds, .time_zone_buf = undefined, .time_zone_len = @intCast(time_zone_id.len) };
        @memcpy(result.time_zone_buf[0..time_zone_id.len], time_zone_id);
        return result;
    }

    /// Exact-instant construction -- nothing to disambiguate.
    pub fn create(allocator: Allocator, io: std.Io, epoch_nanoseconds: i128, time_zone_id: []const u8) TemporalError!ZonedDateTime {
        var tz = try loadTimeZone(allocator, io, time_zone_id);
        defer tz.deinit();
        return make(epoch_nanoseconds, time_zone_id);
    }

    /// Wall-clock-field construction (needs `disambiguation`, default
    /// `.compatible`).
    pub fn fromFields(
        allocator: Allocator,
        io: std.Io,
        in_year: i32,
        in_month: i32,
        in_day: i32,
        in_hour: i32,
        in_minute: i32,
        in_second: i32,
        in_millisecond: i32,
        in_microsecond: i32,
        in_nanosecond: i32,
        time_zone_id: []const u8,
        overflow: Overflow,
        disambiguation: Disambiguation,
    ) TemporalError!ZonedDateTime {
        const dt = try PlainDateTime.create(in_year, in_month, in_day, in_hour, in_minute, in_second, in_millisecond, in_microsecond, in_nanosecond, overflow);
        const local_ns = @as(i128, iso_calendar.toEpochDay(dt.date.iso_year, dt.date.iso_month, dt.date.iso_day)) * NS_PER_DAY + dt.time.totalNanoseconds();
        var tz = try loadTimeZone(allocator, io, time_zone_id);
        defer tz.deinit();
        const local_ms: i64 = @intCast(@divFloor(local_ns, NS_PER_MS));
        const utc_ms = try resolveWallClock(&tz, local_ms, disambiguation);
        const offset_ns: i128 = (@as(i128, local_ms) - @as(i128, utc_ms)) * NS_PER_MS;
        return make(local_ns - offset_ns, time_zone_id);
    }

    /// String parse -- date+time+optional-offset+[TimeZoneName][calendar].
    /// Needs both `disambiguation` (used when the offset is absent, or
    /// with `offset_option: .ignore`/`.prefer`-fallback) and
    /// `offset_option` (default `.reject`, used when the string carries
    /// an explicit offset). Non-iso8601 calendar annotation ->
    /// `error.InvalidFormat`.
    pub fn parseIso(allocator: Allocator, io: std.Io, text: []const u8, offset_option: OffsetOption, disambiguation: Disambiguation) TemporalError!ZonedDateTime {
        const parsed = try iso_string.parseZonedDateTime(text);
        if (parsed.date.month < 1 or parsed.date.month > 12) return error.InvalidFormat;
        if (parsed.date.day < 1 or parsed.date.day > iso_calendar.daysInMonth(parsed.date.year, parsed.date.month)) return error.InvalidFormat;
        const local_ns: i128 = @as(i128, iso_calendar.toEpochDay(parsed.date.year, parsed.date.month, parsed.date.day)) * NS_PER_DAY +
            @as(i128, parsed.time.hour) * 3_600_000_000_000 +
            @as(i128, parsed.time.minute) * 60_000_000_000 +
            @as(i128, parsed.time.second) * 1_000_000_000 +
            @as(i128, parsed.time.millisecond) * 1_000_000 +
            @as(i128, parsed.time.microsecond) * 1_000 +
            parsed.time.nanosecond;

        var tz = try loadTimeZone(allocator, io, parsed.time_zone_id);
        defer tz.deinit();
        const local_ms: i64 = @intCast(@divFloor(local_ns, NS_PER_MS));

        const given_offset_ns = parsed.offset_nanoseconds orelse {
            const utc_ms = try resolveWallClock(&tz, local_ms, disambiguation);
            const offset_ns: i128 = (@as(i128, local_ms) - @as(i128, utc_ms)) * NS_PER_MS;
            return make(local_ns - offset_ns, parsed.time_zone_id);
        };

        switch (offset_option) {
            .use => {
                return make(local_ns - given_offset_ns, parsed.time_zone_id);
            },
            .ignore => {
                const utc_ms = try resolveWallClock(&tz, local_ms, disambiguation);
                const offset_ns: i128 = (@as(i128, local_ms) - @as(i128, utc_ms)) * NS_PER_MS;
                return make(local_ns - offset_ns, parsed.time_zone_id);
            },
            .reject, .prefer => {
                const given_offset_ms: i64 = @intCast(@divTrunc(given_offset_ns, NS_PER_MS));
                const candidate_utc_ms = local_ms -| given_offset_ms;
                if (tz.offsetAtUtc(candidate_utc_ms) == given_offset_ms) {
                    return make(local_ns - given_offset_ns, parsed.time_zone_id);
                }
                if (offset_option == .reject) return error.AmbiguousTime;
                const utc_ms = try resolveWallClock(&tz, local_ms, disambiguation);
                const offset_ns: i128 = (@as(i128, local_ms) - @as(i128, utc_ms)) * NS_PER_MS;
                return make(local_ns - offset_ns, parsed.time_zone_id);
            },
        }
    }

    /// Pure field projection -- `epochNanoseconds` is already exact, no
    /// timezone lookup needed.
    pub fn toInstant(self: ZonedDateTime) Instant {
        return Instant.fromEpochNanoseconds(self.epoch_nanoseconds) catch unreachable;
    }

    fn offsetNanosecondsAt(allocator: Allocator, io: std.Io, epoch_nanoseconds: i128, time_zone_id: []const u8) TemporalError!i128 {
        var tz = try loadTimeZone(allocator, io, time_zone_id);
        defer tz.deinit();
        const epoch_ms: i64 = @intCast(@divFloor(epoch_nanoseconds, NS_PER_MS));
        return @as(i128, tz.offsetAtUtc(epoch_ms)) * NS_PER_MS;
    }

    pub fn offsetNanoseconds(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!i128 {
        return offsetNanosecondsAt(allocator, io, self.epoch_nanoseconds, self.timeZoneId());
    }

    /// The local wall-clock date+time -- reused by every field getter and
    /// the Plain-type conversions below.
    pub fn toPlainDateTime(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!PlainDateTime {
        const offset_ns = try self.offsetNanoseconds(allocator, io);
        const local_ns = self.epoch_nanoseconds + offset_ns;
        const epoch_day: i64 = @intCast(@divFloor(local_ns, NS_PER_DAY));
        const ns_of_day: u64 = @intCast(@mod(local_ns, NS_PER_DAY));
        const ymd = iso_calendar.fromEpochDay(epoch_day);
        return .{
            .date = .{ .iso_year = ymd.year, .iso_month = ymd.month, .iso_day = ymd.day },
            .time = PlainTime.fromNanosecondsOfDay(ns_of_day),
        };
    }

    pub fn toPlainDate(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!PlainDate {
        return (try self.toPlainDateTime(allocator, io)).date;
    }

    pub fn toPlainTime(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!PlainTime {
        return (try self.toPlainDateTime(allocator, io)).time;
    }

    pub fn toPlainYearMonth(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!plain_year_month.PlainYearMonth {
        return (try self.toPlainDate(allocator, io)).toPlainYearMonth();
    }

    pub fn toPlainMonthDay(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!plain_month_day.PlainMonthDay {
        return (try self.toPlainDate(allocator, io)).toPlainMonthDay();
    }

    pub fn year(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!i32 {
        return (try self.toPlainDate(allocator, io)).iso_year;
    }
    pub fn month(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!u8 {
        return (try self.toPlainDate(allocator, io)).iso_month;
    }
    pub fn day(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!u8 {
        return (try self.toPlainDate(allocator, io)).iso_day;
    }
    pub fn hour(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!u8 {
        return (try self.toPlainTime(allocator, io)).hour;
    }
    pub fn minute(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!u8 {
        return (try self.toPlainTime(allocator, io)).minute;
    }
    pub fn second(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!u8 {
        return (try self.toPlainTime(allocator, io)).second;
    }
    pub fn millisecond(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!u16 {
        return (try self.toPlainTime(allocator, io)).millisecond;
    }
    pub fn microsecond(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!u16 {
        return (try self.toPlainTime(allocator, io)).microsecond;
    }
    pub fn nanosecond(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!u16 {
        return (try self.toPlainTime(allocator, io)).nanosecond;
    }
    pub fn dayOfWeek(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!u8 {
        return (try self.toPlainDate(allocator, io)).dayOfWeek();
    }

    /// Compares the underlying instant only -- matches `Instant.compare`.
    pub fn compare(a: ZonedDateTime, b: ZonedDateTime) std.math.Order {
        return std.math.order(a.epoch_nanoseconds, b.epoch_nanoseconds);
    }

    /// Requires the same instant AND the same `timeZoneId` -- ground-truthed
    /// (same instant, `America/New_York` vs `UTC` -> NOT equal, even
    /// though `compare` is `0`). `calendarId` is always `iso8601` for
    /// every value this library can construct, so it's not compared
    /// explicitly (would always agree).
    pub fn equals(a: ZonedDateTime, b: ZonedDateTime) bool {
        return a.epoch_nanoseconds == b.epoch_nanoseconds and std.mem.eql(u8, a.timeZoneId(), b.timeZoneId());
    }

    /// Hours between this local day's start and the next's -- DST-aware
    /// (ground-truthed `24` on a normal day, `23` on the `America/New_York`
    /// spring-forward day).
    pub fn hoursInDay(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!f64 {
        const start = try self.startOfDay(allocator, io);
        const next_date = try (try start.toPlainDate(allocator, io)).add(try Duration.create(0, 0, 0, 1, 0, 0, 0, 0, 0, 0), .constrain);
        const next_start = try fromFields(allocator, io, next_date.iso_year, next_date.iso_month, next_date.iso_day, 0, 0, 0, 0, 0, 0, self.timeZoneId(), .constrain, .compatible);
        const diff_ns: i128 = next_start.epoch_nanoseconds - start.epoch_nanoseconds;
        return @as(f64, @floatFromInt(diff_ns)) / @as(f64, @floatFromInt(3_600_000_000_000));
    }

    /// Midnight of this value's local day, resolved the same way any
    /// other wall-clock construction is (`.compatible`, since a real
    /// midnight can itself fall in a DST gap in rare zones).
    pub fn startOfDay(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!ZonedDateTime {
        const date = try self.toPlainDate(allocator, io);
        return fromFields(allocator, io, date.iso_year, date.iso_month, date.iso_day, 0, 0, 0, 0, 0, 0, self.timeZoneId(), .constrain, .compatible);
    }

    pub const TransitionDirection = enum { next, previous };

    /// The next/previous DST (or other offset) transition relative to
    /// this instant in this time zone, or `null` if the zone has none in
    /// that direction (e.g. a fixed-offset zone like `UTC`).
    pub fn getTimeZoneTransition(self: ZonedDateTime, allocator: Allocator, io: std.Io, direction: TransitionDirection) TemporalError!?ZonedDateTime {
        var tz = try loadTimeZone(allocator, io, self.timeZoneId());
        defer tz.deinit();
        const epoch_s: i64 = @intCast(@divFloor(self.epoch_nanoseconds, 1_000_000_000));
        var found: ?i64 = null;
        for (tz.tz.transitions) |t| {
            switch (direction) {
                .next => {
                    if (t.ts > epoch_s and (found == null or t.ts < found.?)) found = t.ts;
                },
                .previous => {
                    if (t.ts <= epoch_s and (found == null or t.ts > found.?)) found = t.ts;
                },
            }
        }
        const ts = found orelse return null;
        return try make(@as(i128, ts) * 1_000_000_000, self.timeZoneId());
    }

    /// `YYYY-MM-DDTHH:MM:SS[.fraction]±HH:MM[TimeZoneId][u-ca=iso8601]`.
    pub fn toIsoString(self: ZonedDateTime, allocator: Allocator, io: std.Io, show_offset: bool, show_time_zone: bool, show_calendar: bool) ![]u8 {
        const dt = try self.toPlainDateTime(allocator, io);
        const offset_ns = try self.offsetNanoseconds(allocator, io);

        var year_buf: [8]u8 = undefined;
        const year_str = iso_string.formatYear(&year_buf, dt.date.iso_year);
        var frac_buf: [10]u8 = undefined;
        const frac = iso_string.formatFractionalSeconds(&frac_buf, dt.time.millisecond, dt.time.microsecond, dt.time.nanosecond);

        var offset_buf: [7]u8 = undefined;
        var offset_str: []const u8 = "";
        if (show_offset) {
            const sign: u8 = if (offset_ns < 0) '-' else '+';
            const mag_ns = @abs(offset_ns);
            const mag_min: u32 = @intCast(@divTrunc(mag_ns, 60_000_000_000));
            offset_str = try std.fmt.bufPrint(&offset_buf, "{c}{d:0>2}:{d:0>2}", .{ sign, mag_min / 60, mag_min % 60 });
        }

        return std.fmt.allocPrint(allocator, "{s}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{s}{s}{s}{s}{s}{s}", .{
            year_str,          dt.date.iso_month, dt.date.iso_day,
            dt.time.hour,      dt.time.minute,    dt.time.second,
            frac,              offset_str,
            if (show_time_zone) "[" else "",
            if (show_time_zone) self.timeZoneId() else "",
            if (show_time_zone) "]" else "",
            if (show_calendar) "[u-ca=iso8601]" else "",
        });
    }
};
