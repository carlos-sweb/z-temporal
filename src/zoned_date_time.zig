//! Temporal.ZonedDateTime: exact instants with named or fixed-offset zones and calendars.
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

const TIME_ZONE_ID_MAX = 255;
const timezone = @import("timezone.zig");

/// Loads `time_zone_id` as a real IANA zone. Transient -- callers
/// `deinit()` it immediately after use, never stored on a `ZonedDateTime`
/// value (kept a plain, deinit-free struct like every other type here).
fn loadTimeZone(allocator: Allocator, io: std.Io, time_zone_id: []const u8) TemporalError!timezone.Zone {
    return timezone.load(allocator, io, time_zone_id);
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
fn resolveWallClock(tz: *const timezone.Zone, local_ms: i64, disambiguation: Disambiguation) TemporalError!i64 {
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
        .reject => error.RangeError,
        .compatible => unreachable,
    };
}

pub fn resolveFields(
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
    const dt = try @import("plain_date_time.zig").regulate(in_year, in_month, in_day, in_hour, in_minute, in_second, in_millisecond, in_microsecond, in_nanosecond, overflow);
    const local_ns = @as(i128, iso_calendar.toEpochDay(dt.date.iso_year, dt.date.iso_month, dt.date.iso_day)) * NS_PER_DAY + dt.time.totalNanoseconds();
    var tz = try loadTimeZone(allocator, io, time_zone_id);
    defer tz.deinit();
    const local_ms: i64 = @intCast(@divFloor(local_ns, NS_PER_MS));
    const utc_ms = try resolveWallClock(&tz, local_ms, disambiguation);
    const offset_ns: i128 = (@as(i128, local_ms) - @as(i128, utc_ms)) * NS_PER_MS;
    return ZonedDateTime.init(allocator, io, local_ns - offset_ns, time_zone_id, null);
}

pub const ZonedDateTime = struct {
    calendar: @import("calendar.zig").Id = .iso8601,
    epochNs: i128,
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
        return @import("calendar.zig").displayName(self.calendar);
    }

    fn make(epochNs: i128, raw_time_zone_id: []const u8) TemporalError!ZonedDateTime {
        var zone_buf: [255]u8 = undefined;
        const time_zone_id = try timezone.normalize(&zone_buf, raw_time_zone_id);
        if (epochNs < instant_mod.MIN_EPOCH_NS or epochNs > instant_mod.MAX_EPOCH_NS) return error.RangeError;
        if (time_zone_id.len == 0 or time_zone_id.len > TIME_ZONE_ID_MAX) return error.RangeError;
        var result: ZonedDateTime = .{ .epochNs = epochNs, .time_zone_buf = undefined, .time_zone_len = @intCast(time_zone_id.len) };
        @memcpy(result.time_zone_buf[0..time_zone_id.len], time_zone_id);
        return result;
    }

    /// Exact-instant construction -- nothing to disambiguate.
    pub fn init(allocator: Allocator, io: std.Io, epochNs: i128, time_zone_id: []const u8, calendarIdValue: ?[]const u8) TemporalError!ZonedDateTime {
        var tz = try loadTimeZone(allocator, io, time_zone_id);
        defer tz.deinit();
        const name = try timezone.canonical(allocator, io, time_zone_id);
        defer allocator.free(name);
        return (try make(epochNs, name)).withCalendar(calendarIdValue orelse "iso8601");
    }

    /// Wall-clock-field construction (needs `disambiguation`, default
    /// `.compatible`).
    /// String parse -- date+time+optional-offset+[TimeZoneName][calendar].
    /// Needs both `disambiguation` (used when the offset is absent, or
    /// with `offset_option: .ignore`/`.prefer`-fallback) and
    /// `offset_option` (default `.reject`, used when the string carries
    /// an explicit offset). Non-iso8601 calendar annotation ->
    /// `error.RangeError`.
    pub const Fields = struct {
        era: ?[]const u8 = null,
        eraYear: ?i32 = null,
        year: ?i32 = null,
        month: ?i32 = null,
        day: ?i32 = null,
        hour: ?i32 = null,
        minute: ?i32 = null,
        second: ?i32 = null,
        millisecond: ?i32 = null,
        microsecond: ?i32 = null,
        nanosecond: ?i32 = null,
        calendar: ?[]const u8 = null,
        monthCode: ?[]const u8 = null,
        timeZone: ?[]const u8 = null,
        offset: ?[]const u8 = null,
    };
    pub const FromInput = union(enum) { string: []const u8, value: ZonedDateTime, fields: Fields };
    pub const FromOptions = struct { overflow: Overflow = .constrain, offset: OffsetOption = .reject, disambiguation: Disambiguation = .compatible };
    pub fn from(allocator: Allocator, io: std.Io, input: FromInput, options: FromOptions) TemporalError!ZonedDateTime {
        return switch (input) {
            .string => |text| blk: {
                const value = try fromString(allocator, io, text, options.offset, options.disambiguation, true);
                break :blk (try value.withTimeZone(allocator, io, value.timeZoneId())).withCalendar(@tagName(try @import("calendar.zig").fromString(text)));
            },
            .value => |value| value,
            .fields => |f| blk: {
                const y = f.year;
                const m = f.month;
                const d = f.day orelse return error.TypeError;
                const zone = f.timeZone orelse return error.TypeError;
                const dt = try PlainDateTime.from(.{ .fields = .{ .year = y, .era = f.era, .eraYear = f.eraYear, .month = m, .monthCode = f.monthCode, .day = d, .hour = f.hour, .minute = f.minute, .second = f.second, .millisecond = f.millisecond, .microsecond = f.microsecond, .nanosecond = f.nanosecond, .calendar = f.calendar } }, .{ .overflow = options.overflow });
                if (f.offset) |offset_value| {
                    if (offset_value.len == 0 or offset_value[0] == 'Z' or offset_value[0] == 'z') return error.RangeError;
                    const text = try dt.toString(allocator, .{});
                    defer allocator.free(text);
                    const source = try allocator.print("{s}{s}[{s}]", .{ text, offset_value, zone });
                    defer allocator.free(source);
                    break :blk fromString(allocator, io, source, options.offset, options.disambiguation, false);
                }
                break :blk (try resolveFields(allocator, io, dt.date.iso_year, dt.date.iso_month, dt.date.iso_day, dt.time.hour, dt.time.minute, dt.time.second, dt.time.millisecond, dt.time.microsecond, dt.time.nanosecond, zone, .reject, options.disambiguation)).withCalendar(dt.calendarId());
            },
        };
    }
    pub const WithOptions = struct { overflow: Overflow = .constrain, offset: OffsetOption = .prefer, disambiguation: Disambiguation = .compatible };
    pub fn with(self: ZonedDateTime, allocator: Allocator, io: std.Io, fields: Fields, options: WithOptions) TemporalError!ZonedDateTime {
        if (fields.timeZone != null or fields.calendar != null or (self.calendar != .iso8601 and (fields.era == null) != (fields.eraYear == null))) return error.TypeError;
        if ((self.calendar == .iso8601 or (fields.era == null and fields.eraYear == null)) and fields.year == null and fields.month == null and fields.day == null and fields.hour == null and fields.minute == null and fields.second == null and fields.millisecond == null and fields.microsecond == null and fields.nanosecond == null and fields.offset == null) return error.TypeError;
        const dt = try self.toPlainDateTime(allocator, io);
        const old_offset = try self.offset(allocator, io);
        defer allocator.free(old_offset);
        return from(allocator, io, .{ .fields = .{ .year = if (fields.era != null or fields.eraYear != null) fields.year else fields.year orelse dt.year(), .era = fields.era, .eraYear = fields.eraYear, .month = if (fields.monthCode != null) fields.month else fields.month orelse dt.month(), .monthCode = fields.monthCode, .day = fields.day orelse dt.day(), .calendar = @tagName(self.calendar), .hour = fields.hour orelse dt.time.hour, .minute = fields.minute orelse dt.time.minute, .second = fields.second orelse dt.time.second, .millisecond = fields.millisecond orelse dt.time.millisecond, .microsecond = fields.microsecond orelse dt.time.microsecond, .nanosecond = fields.nanosecond orelse dt.time.nanosecond, .timeZone = self.timeZoneId(), .offset = fields.offset orelse old_offset } }, .{ .overflow = options.overflow, .offset = options.offset, .disambiguation = options.disambiguation });
    }
    pub fn withPlainTime(self: ZonedDateTime, allocator: Allocator, io: std.Io, time: ?PlainTime) TemporalError!ZonedDateTime {
        const dt = try self.toPlainDateTime(allocator, io);
        const t = time orelse PlainTime{};
        return (try resolveFields(allocator, io, dt.date.iso_year, dt.date.iso_month, dt.date.iso_day, t.hour, t.minute, t.second, t.millisecond, t.microsecond, t.nanosecond, self.timeZoneId(), .reject, .compatible)).withCalendar(@tagName(self.calendar));
    }
    pub fn withTimeZone(self: ZonedDateTime, allocator: Allocator, io: std.Io, zone: []const u8) TemporalError!ZonedDateTime {
        return (try init(allocator, io, self.epochNs, zone, null)).withCalendar(@tagName(self.calendar));
    }
    pub fn withCalendar(self: ZonedDateTime, id: []const u8) TemporalError!ZonedDateTime {
        var result = self;
        result.calendar = try @import("calendar.zig").parse(id);
        return result;
    }
    pub fn add(self: ZonedDateTime, allocator: Allocator, io: std.Io, d: Duration, overflow: Overflow) TemporalError!ZonedDateTime {
        try @import("duration.zig").validate(d);
        const has_date = d.years != 0 or d.months != 0 or d.weeks != 0 or d.days != 0;
        var base = self;
        if (has_date) {
            const local = try self.toPlainDateTime(allocator, io);
            const shifted = try local.date.add(.{ .years = d.years, .months = d.months, .weeks = d.weeks, .days = d.days }, overflow);
            base = try resolveFields(allocator, io, shifted.iso_year, shifted.iso_month, shifted.iso_day, local.time.hour, local.time.minute, local.time.second, local.time.millisecond, local.time.microsecond, local.time.nanosecond, self.timeZoneId(), .reject, .compatible);
        }
        const delta = try Duration.init(0, 0, 0, 0, d.hours, d.minutes, d.seconds, d.milliseconds, d.microseconds, d.nanoseconds);
        return (try make(base.epochNs + delta.totalTimeNanoseconds(), self.timeZoneId())).withCalendar(@tagName(self.calendar));
    }
    pub fn subtract(self: ZonedDateTime, allocator: Allocator, io: std.Io, d: Duration, overflow: Overflow) TemporalError!ZonedDateTime {
        return self.add(allocator, io, d.negated(), overflow);
    }
    pub fn until(self: ZonedDateTime, allocator: Allocator, io: std.Io, other: ZonedDateTime, options: @import("rounding.zig").RoundingOptions) TemporalError!Duration {
        if (!@import("calendar.zig").equal(self.calendar, other.calendar)) return error.RangeError;
        const r = @import("rounding.zig");
        const units = try r.resolveTimeUnitsForZoned(options);
        if (r.isTimeUnit(units.largest)) return self.toInstant().until(other.toInstant(), options);
        if (!@import("calendar.zig").equal(self.calendar, other.calendar)) return error.RangeError;
        if (!std.ascii.eqlIgnoreCase(timezone.primary(self.timeZoneId()), timezone.primary(other.timeZoneId()))) return error.RangeError;
        const rel = @import("relative.zig");
        return rel.difference(try self.toPlainDateTime(allocator, io), try other.toPlainDateTime(allocator, io), self.epochNs, other.epochNs, .{ .largestUnit = units.largest, .smallestUnit = units.smallest, .roundingIncrement = options.roundingIncrement, .roundingMode = options.roundingMode }, .{ .allocator = allocator, .io = io, .zone = self.timeZoneId() });
    }
    pub fn since(self: ZonedDateTime, allocator: Allocator, io: std.Io, other: ZonedDateTime, options: @import("rounding.zig").RoundingOptions) TemporalError!Duration {
        var opts = options;
        opts.roundingMode = @import("relative.zig").negateMode(opts.roundingMode);
        return (try self.until(allocator, io, other, opts)).negated();
    }
    pub fn round(self: ZonedDateTime, allocator: Allocator, io: std.Io, options: @import("rounding.zig").RoundOptions) TemporalError!ZonedDateTime {
        const r = @import("rounding.zig");
        const unit = options.smallestUnit orelse return error.RangeError;
        if (!r.isTimeUnitOrDay(unit)) return error.RangeError;
        if (unit == .day) {
            if (options.roundingIncrement != 1) return error.RangeError;
            const start = try self.startOfDay(allocator, io);
            const next = try start.add(allocator, io, .{ .days = 1 }, .constrain);
            const rounded = r.roundRatioToIncrement(self.epochNs - start.epochNs, next.epochNs - start.epochNs, 1, options.roundingMode);
            return if (rounded == 0) start else next;
        }
        const local = try self.toPlainDateTime(allocator, io);
        const rounded = try local.round(options);
        const offset_value = try self.offset(allocator, io);
        defer allocator.free(offset_value);
        return (try from(allocator, io, .{ .fields = .{ .year = rounded.date.iso_year, .month = rounded.date.iso_month, .day = rounded.date.iso_day, .hour = rounded.time.hour, .minute = rounded.time.minute, .second = rounded.time.second, .millisecond = rounded.time.millisecond, .microsecond = rounded.time.microsecond, .nanosecond = rounded.time.nanosecond, .timeZone = self.timeZoneId(), .offset = offset_value } }, .{ .offset = .prefer })).withCalendar(@tagName(self.calendar));
    }
    pub fn era(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!?[]const u8 {
        return (try self.toPlainDate(allocator, io)).era();
    }
    pub fn eraYear(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!?i32 {
        return (try self.toPlainDate(allocator, io)).eraYear();
    }
    pub fn epochNanoseconds(self: ZonedDateTime) i128 {
        return self.epochNs;
    }
    pub fn epochMilliseconds(self: ZonedDateTime) i64 {
        return self.toInstant().epochMilliseconds();
    }
    pub fn offset(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError![]u8 {
        const ns = try self.offsetNanoseconds(allocator, io);
        const magnitude: u64 = @intCast(@abs(ns));
        const h = magnitude / 3_600_000_000_000;
        const m = magnitude / 60_000_000_000 % 60;
        const sec = magnitude / 1_000_000_000 % 60;
        const sign: u8 = if (ns < 0) '-' else '+';
        if (sec != 0) return allocator.print("{c}{d:0>2}:{d:0>2}:{d:0>2}", .{ sign, h, m, sec });
        return allocator.print("{c}{d:0>2}:{d:0>2}", .{ sign, h, m });
    }
    pub fn dayOfYear(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!u16 {
        return (try self.toPlainDate(allocator, io)).dayOfYear();
    }
    pub fn daysInMonth(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!u8 {
        return (try self.toPlainDate(allocator, io)).daysInMonth();
    }
    pub fn daysInYear(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!u16 {
        return (try self.toPlainDate(allocator, io)).daysInYear();
    }
    pub fn monthsInYear(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!u8 {
        return (try self.toPlainDate(allocator, io)).monthsInYear();
    }
    pub fn inLeapYear(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!bool {
        return (try self.toPlainDate(allocator, io)).inLeapYear();
    }
    pub fn daysInWeek(_: ZonedDateTime) u8 {
        return 7;
    }
    pub fn weekOfYear(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!?u8 {
        return (try self.toPlainDate(allocator, io)).weekOfYear();
    }
    pub fn yearOfWeek(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!?i32 {
        return (try self.toPlainDate(allocator, io)).yearOfWeek();
    }
    pub fn monthCode(self: ZonedDateTime, allocator: Allocator, io: std.Io, buf: *[4]u8) TemporalError![]const u8 {
        return (try self.toPlainDate(allocator, io)).monthCode(buf);
    }
    fn fromString(allocator: Allocator, io: std.Io, text: []const u8, offset_option: OffsetOption, disambiguation: Disambiguation, allowMinuteMatch: bool) TemporalError!ZonedDateTime {
        const parsed = try iso_string.parseZonedDateTime(text);
        if (parsed.date.month < 1 or parsed.date.month > 12) return error.RangeError;
        if (parsed.date.day < 1 or parsed.date.day > iso_calendar.daysInMonth(parsed.date.year, parsed.date.month)) return error.RangeError;
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

        if (parsed.isUtc) return make(local_ns, parsed.time_zone_id);
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
                const actual = tz.offsetAtUtc(candidate_utc_ms);
                const rounded_actual = @import("rounding.zig").roundRatioToIncrement(actual, 60_000, 1, .halfExpand) * 60_000;
                if (actual == given_offset_ms) return make(local_ns - given_offset_ns, parsed.time_zone_id);
                if (allowMinuteMatch and parsed.minutePrecision and rounded_actual == given_offset_ms) {
                    const candidate = local_ms - actual;
                    if (tz.offsetAtUtc(candidate) == actual) return make(local_ns - @as(i128, actual) * NS_PER_MS, parsed.time_zone_id);
                }
                if (offset_option == .reject) return error.RangeError;
                const utc_ms = try resolveWallClock(&tz, local_ms, disambiguation);
                const offset_ns: i128 = (@as(i128, local_ms) - @as(i128, utc_ms)) * NS_PER_MS;
                return make(local_ns - offset_ns, parsed.time_zone_id);
            },
        }
    }

    /// Pure field projection -- `epochNanoseconds` is already exact, no
    /// timezone lookup needed.
    pub fn toInstant(self: ZonedDateTime) Instant {
        return Instant.fromEpochNanoseconds(self.epochNs) catch unreachable;
    }

    fn offsetNanosecondsAt(allocator: Allocator, io: std.Io, epochNs: i128, time_zone_id: []const u8) TemporalError!i128 {
        var tz = try loadTimeZone(allocator, io, time_zone_id);
        defer tz.deinit();
        const epoch_ms: i64 = @intCast(@divFloor(epochNs, NS_PER_MS));
        return @as(i128, tz.offsetAtUtc(epoch_ms)) * NS_PER_MS;
    }

    pub fn offsetNanoseconds(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!i128 {
        return offsetNanosecondsAt(allocator, io, self.epochNs, self.timeZoneId());
    }

    /// The local wall-clock date+time -- reused by every field getter and
    /// the Plain-type conversions below.
    pub fn toPlainDateTime(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!PlainDateTime {
        const offset_ns = try self.offsetNanoseconds(allocator, io);
        const local_ns = self.epochNs + offset_ns;
        const epoch_day: i64 = @intCast(@divFloor(local_ns, NS_PER_DAY));
        const ns_of_day: u64 = @intCast(@mod(local_ns, NS_PER_DAY));
        const ymd = iso_calendar.fromEpochDay(epoch_day);
        return .{
            .date = try (try PlainDate.init(ymd.year, ymd.month, ymd.day, null)).withCalendar(@tagName(self.calendar)),
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
        return std.math.order(a.epochNs, b.epochNs);
    }

    /// Requires the same instant AND the same `timeZoneId` -- ground-truthed
    /// (same instant, `America/New_York` vs `UTC` -> NOT equal, even
    /// though `compare` is `0`). `calendarId` is always `iso8601` for
    /// every value this library can construct, so it's not compared
    /// explicitly (would always agree).
    pub fn equals(a: ZonedDateTime, b: ZonedDateTime) bool {
        return a.epochNs == b.epochNs and std.mem.eql(u8, timezone.primary(a.timeZoneId()), timezone.primary(b.timeZoneId())) and @import("calendar.zig").equal(a.calendar, b.calendar);
    }

    /// Hours between this local day's start and the next's -- DST-aware
    /// (ground-truthed `24` on a normal day, `23` on the `America/New_York`
    /// spring-forward day).
    fn startOfDayNs(allocator: Allocator, io: std.Io, target_day: i64, zone: []const u8) TemporalError!i128 {
        var tz = try loadTimeZone(allocator, io, zone);
        defer tz.deinit();
        var low: i64 = target_day * 86_400_000 - 2 * 86_400_000;
        var high: i64 = target_day * 86_400_000 + 2 * 86_400_000;
        while (low < high) {
            const middle = low + @divTrunc(high - low, 2);
            const local_day = @divFloor(middle + tz.offsetAtUtc(middle), 86_400_000);
            if (local_day < target_day) low = middle + 1 else high = middle;
        }
        return @as(i128, low) * NS_PER_MS;
    }
    pub fn hoursInDay(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!f64 {
        const date = try self.toPlainDate(allocator, io);
        const epoch_day = iso_calendar.toEpochDay(date.iso_year, date.iso_month, date.iso_day);
        const start = try startOfDayNs(allocator, io, epoch_day, self.timeZoneId());
        const end = try startOfDayNs(allocator, io, epoch_day + 1, self.timeZoneId());
        return @as(f64, @floatFromInt(end - start)) / 3_600_000_000_000;
    }

    /// Midnight of this value's local day, resolved the same way any
    /// other wall-clock construction is (`.compatible`, since a real
    /// midnight can itself fall in a DST gap in rare zones).
    pub fn startOfDay(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError!ZonedDateTime {
        const date = try self.toPlainDate(allocator, io);
        const epoch_day = iso_calendar.toEpochDay(date.iso_year, date.iso_month, date.iso_day);
        return (try make(try startOfDayNs(allocator, io, epoch_day, self.timeZoneId()), self.timeZoneId())).withCalendar(@tagName(self.calendar));
    }

    pub const TransitionDirection = enum { next, previous };

    /// The next/previous DST (or other offset) transition relative to
    /// this instant in this time zone, or `null` if the zone has none in
    /// that direction (e.g. a fixed-offset zone like `UTC`).
    pub fn getTimeZoneTransition(self: ZonedDateTime, allocator: Allocator, io: std.Io, direction: TransitionDirection) TemporalError!?ZonedDateTime {
        var tz = try loadTimeZone(allocator, io, self.timeZoneId());
        defer tz.deinit();
        const epoch_s: i64 = @intCast(@divFloor(self.epochNs, 1_000_000_000));
        var found: ?i64 = null;
        if (tz.fixed != null) return null;
        for (tz.named.?.tz.transitions) |t| {
            if (tz.offsetAtUtc(t.ts * 1000) == tz.offsetAtUtc(t.ts * 1000 - 1)) continue;
            switch (direction) {
                .next => {
                    if (t.ts > epoch_s and (found == null or t.ts < found.?)) found = t.ts;
                },
                .previous => {
                    if (@as(i128, t.ts) * 1_000_000_000 < self.epochNs and (found == null or t.ts > found.?)) found = t.ts;
                },
            }
        }
        if (tz.named.?.posix) |posix| if (posix.dst) |dst| {
            const year_value = iso_calendar.fromEpochDay(@intCast(@divFloor(self.epochNs, NS_PER_DAY))).year;
            const transitions = tz.named.?.tz.transitions;
            const last = if (transitions.len > 0) transitions[transitions.len - 1].ts else std.math.minInt(i64);
            for (0..4) |index| {
                const y = year_value + @as(i32, @intCast(index)) - 1;
                const candidates = [2]i64{ timezone.posixTransition(dst.start, y, posix.std_offset_ms), timezone.posixTransition(dst.end, y, dst.offset_ms) };
                for (candidates) |candidate| {
                    if (candidate <= last) continue;
                    const candidate_ns = @as(i128, candidate) * 1_000_000_000;
                    const eligible = if (direction == .next) candidate_ns > self.epochNs else candidate_ns < self.epochNs;
                    if (eligible and (found == null or (if (direction == .next) candidate < found.? else candidate > found.?))) found = candidate;
                }
            }
        };
        const ts = found orelse return null;
        return try (try make(@as(i128, ts) * 1_000_000_000, self.timeZoneId())).withCalendar(@tagName(self.calendar));
    }

    /// `YYYY-MM-DDTHH:MM:SS[.fraction]±HH:MM[TimeZoneId][u-ca=iso8601]`.
    pub fn toLocaleString(self: ZonedDateTime, allocator: std.mem.Allocator, io: std.Io, locales: ?[]const u8, options: @import("locale.zig").LocaleOptions) TemporalError![]u8 {
        return @import("locale.zig").format(allocator, io, .zoned, @as(f64, @floatFromInt(self.epochMilliseconds())), self.calendar, self.timeZoneId(), locales, options);
    }
    pub fn toString(self: ZonedDateTime, allocator: Allocator, io: std.Io, options: StringOptions) TemporalError![]u8 {
        const fmt = @import("format_options.zig");
        const p = try fmt.precision(options);
        const value = try self.round(allocator, io, .{ .smallestUnit = p.unit, .roundingIncrement = p.increment, .roundingMode = options.roundingMode });
        const raw = try value.formatDefault(allocator, io, options.offset != .never, options.timeZoneName != .never, options.calendarName == .always or options.calendarName == .critical or (options.calendarName == .auto and self.calendar != .iso8601));
        defer allocator.free(raw);
        const timed = try fmt.time(allocator, raw, p);
        defer allocator.free(timed);
        const calendared = try fmt.calendar(allocator, timed, options.calendarName == .critical);
        if (options.timeZoneName != .critical) return calendared;
        defer allocator.free(calendared);
        const index = std.mem.indexOfScalar(u8, calendared, '[') orelse return allocator.dupe(u8, calendared);
        return allocator.print("{s}[!{s}", .{ calendared[0..index], calendared[index + 1 ..] });
    }
    pub fn toJSON(self: ZonedDateTime, allocator: Allocator, io: std.Io) TemporalError![]u8 {
        return self.toString(allocator, io, .{});
    }
    pub const StringOptions = @import("format_options.zig").StringOptions;
    fn formatDefault(self: ZonedDateTime, allocator: Allocator, io: std.Io, show_offset: bool, show_time_zone: bool, show_calendar: bool) ![]u8 {
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
            const mag_min: u32 = @intCast(@divTrunc(mag_ns + 30_000_000_000, 60_000_000_000));
            offset_str = std.fmt.bufPrint(&offset_buf, "{c}{d:0>2}:{d:0>2}", .{ sign, mag_min / 60, mag_min % 60 }) catch unreachable;
        }

        return allocator.print("{s}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{s}{s}{s}{s}{s}{s}{s}{s}", .{
            year_str,                                      dt.date.iso_month,               dt.date.iso_day,
            dt.time.hour,                                  dt.time.minute,                  dt.time.second,
            frac,                                          offset_str,                      if (show_time_zone) "[" else "",
            if (show_time_zone) self.timeZoneId() else "", if (show_time_zone) "]" else "", if (show_calendar) "[u-ca=" else "",
            if (show_calendar) self.calendarId() else "",  if (show_calendar) "]" else "",
        });
    }
};
