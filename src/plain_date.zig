//! Temporal.PlainDate: calendar-aware date values with ISO storage.
const calendars = @import("calendar.zig");
const std = @import("std");
const iso_calendar = @import("iso_calendar.zig");
const iso_string = @import("iso_string.zig");
const errors = @import("errors.zig");
const TemporalError = errors.TemporalError;
const duration_mod = @import("duration.zig");
const Duration = duration_mod.Duration;
const rounding = @import("rounding.zig");
const Unit = rounding.Unit;
const RoundingOptions = rounding.RoundingOptions;
const plain_year_month = @import("plain_year_month.zig");
const plain_month_day = @import("plain_month_day.zig");

/// `.from()`/`.with()`'s `overflow` option. Constructors always behave as
/// `.reject` (there is no `overflow` option on `new Temporal.PlainDate`
/// itself, ground-truthed against real Node) -- callers wanting
/// constructor semantics should pass `.reject` to `init`.
pub const Overflow = enum { constrain, reject };

/// The calendar step shared by `PlainDate.add`/`.subtract` and
/// `PlainDateTime.add`/`.subtract` (`pub` so both can call the exact same
/// logic, no duplication): add `add_years`/`add_months` to `year`/`month`
/// (1-12 normalized, with year carry via floored division), then clamp/
/// reject the day-of-month against the new month's length per `overflow`.
/// Ground-truthed order: months are applied before any weeks/days step
/// the caller does afterwards (`2024-01-30 + {months:1,days:1}` ==
/// `2024-03-01`, i.e. Jan30 -constrain-> Feb29 -> +1 day -> Mar1, not the
/// other order, which would give Feb29).
pub fn addISODate(year: i32, month: u8, day: u8, add_years: i64, add_months: i64, overflow: Overflow) TemporalError!iso_calendar.YearMonthDay {
    const total_months: i64 = @as(i64, month) - 1 + add_months;
    const year_carry = @divFloor(total_months, 12);
    const new_month: u8 = @intCast(@mod(total_months, 12) + 1);
    const new_year_i64: i64 = @as(i64, year) + add_years + year_carry;
    if (new_year_i64 < iso_calendar.MIN_ISO_YEAR - 1 or new_year_i64 > iso_calendar.MAX_ISO_YEAR + 1) return error.RangeError;
    const new_year: i32 = @intCast(new_year_i64);

    const max_day = iso_calendar.daysInMonth(new_year, new_month);
    var d = day;
    if (day > max_day) {
        if (overflow == .reject) return error.RangeError;
        d = max_day;
    }
    return .{ .year = new_year, .month = new_month, .day = d };
}

/// One step of `add_years`/`add_months` (whichever `use_years` selects)
/// from `s`, via `addISODate` (`.constrain`, matching the rest of this
/// balance algorithm).
fn stepCalendar(s: iso_calendar.YearMonthDay, candidate: i64, comptime use_years: bool) TemporalError!iso_calendar.YearMonthDay {
    return if (use_years)
        addISODate(s.year, s.month, s.day, candidate, 0, .constrain)
    else
        addISODate(s.year, s.month, s.day, 0, candidate, .constrain);
}

/// `start` stepped by `candidate` years/months (whichever `use_years`
/// selects), WITHOUT clamping the day-of-month -- i.e. `start.day` applied
/// literally to `year`/`month`'s length, letting it overflow into
/// subsequent months via plain arithmetic (`iso_calendar.toEpochDay`
/// doesn't bounds-check `day` against the month, so this is just a direct
/// call). Used only for `calendarCandidate`'s overshoot comparison, never
/// as an actual returned date.
fn targetYearMonth(start: iso_calendar.YearMonthDay, candidate: i64, comptime use_years: bool) struct { year: i32, month: u8 } {
    if (use_years) {
        return .{ .year = @intCast(@as(i64, start.year) + candidate), .month = start.month };
    }
    const total_months: i64 = @as(i64, start.month) - 1 + candidate;
    const year_carry = @divFloor(total_months, 12);
    const new_month: u8 = @intCast(@mod(total_months, 12) + 1);
    return .{ .year = @intCast(@as(i64, start.year) + year_carry), .month = new_month };
}

/// The candidate/overshoot-adjust step shared by `diffISODate` (always
/// `use_years=false` -- it always steps in months even when displaying
/// years, since that's what makes leap-day/month-end borrow cases land
/// correctly) and the `smallestUnit:"year"` rounding case in
/// `roundDateDiff` (`use_years=true`). Ground-truthed: at most one
/// adjustment is ever needed, since a whole calendar-unit step overshoots
/// by less than one further unit.
///
/// The overshoot/undershoot comparison MUST use the **unclamped** target
/// position (`targetYearMonth` + `start.day` applied literally, letting it
/// roll into the next month when the target month is shorter), not the
/// day-clamped `addISODate` result -- ground-truthed with paired cases
/// where a day-of-month clamp lands the clamped position exactly ON `end`
/// (e.g. `2023-01-31 -> 2024-02-29`, a leap-day case): comparing the
/// *clamped* position to `end` says "not overshooting" (they're equal) and
/// wrongly keeps the larger candidate (`P1Y1M` instead of the real
/// `P1Y29D`), while comparing the *unclamped* position (`2024-02-31`,
/// i.e. `2024-03-02`) correctly detects the overshoot. A same-shaped
/// backward case (`2024-08-31 -> 2024-06-30`) confirms this isn't just
/// "clamping always forces an adjustment": there the unclamped comparison
/// correctly finds NO overshoot and keeps the larger candidate, matching
/// real Node's `-P2M` (not `-P1M31D`) -- only the unclamped-vs-clamped
/// switch, not a clamping-triggered special case, explains both.
fn calendarCandidate(start: iso_calendar.YearMonthDay, end: iso_calendar.YearMonthDay, comptime use_years: bool) TemporalError!struct { candidate: i64, intermediate: iso_calendar.YearMonthDay } {
    const start_epoch = iso_calendar.toEpochDay(start.year, start.month, start.day);
    const end_epoch = iso_calendar.toEpochDay(end.year, end.month, end.day);
    const initial: i64 = if (use_years)
        @as(i64, end.year) - @as(i64, start.year)
    else
        (@as(i64, end.year) - @as(i64, start.year)) * 12 + (@as(i64, end.month) - @as(i64, start.month));

    const target = targetYearMonth(start, initial, use_years);
    const unclamped_epoch = iso_calendar.toEpochDay(target.year, target.month, start.day);
    var candidate = initial;
    if (end_epoch > start_epoch and unclamped_epoch > end_epoch) {
        candidate -= 1;
    } else if (end_epoch < start_epoch and unclamped_epoch < end_epoch) {
        candidate += 1;
    }
    const intermediate = try stepCalendar(start, candidate, use_years);
    return .{ .candidate = candidate, .intermediate = intermediate };
}

pub const DateDiff = struct {
    years: i64 = 0,
    months: i64 = 0,
    weeks: i64 = 0,
    days: i64 = 0,
    intermediate: iso_calendar.YearMonthDay,
};

/// The unrounded, full-precision balance of `start` to `end` at
/// `largestUnit` granularity. Ground-truthed candidate/overshoot-adjust
/// algorithm (see the Phase 3b plan for the full derivation): for the
/// year/month family, always steps in MONTHS internally (never years
/// directly) and splits into years+months only for display -- this is
/// what makes leap-day/month-end borrow cases land correctly (e.g.
/// `2023-01-31 -> 2024-02-29` gives `P1Y29D`, no month term, rather than
/// what a naive Y/M/D-subtraction-with-borrow algorithm would produce).
/// `intermediate` (the position after applying the largestUnit-level
/// candidate) is returned so `roundDateDiff` can take "one more step" for
/// the rounding fraction's denominator without recomputing the balance.
pub fn diffISODate(start: iso_calendar.YearMonthDay, end: iso_calendar.YearMonthDay, largestUnit: Unit) TemporalError!DateDiff {
    const start_epoch = iso_calendar.toEpochDay(start.year, start.month, start.day);
    const end_epoch = iso_calendar.toEpochDay(end.year, end.month, end.day);

    if (largestUnit == .year or largestUnit == .month) {
        const c = try calendarCandidate(start, end, false);
        const intermediate_epoch = iso_calendar.toEpochDay(c.intermediate.year, c.intermediate.month, c.intermediate.day);
        const remaining_days = end_epoch - intermediate_epoch;
        if (largestUnit == .year) {
            return .{ .years = @divTrunc(c.candidate, 12), .months = @rem(c.candidate, 12), .days = remaining_days, .intermediate = c.intermediate };
        }
        return .{ .months = c.candidate, .days = remaining_days, .intermediate = c.intermediate };
    }

    const total_days = end_epoch - start_epoch;
    if (largestUnit == .week) {
        const weeks = @divTrunc(total_days, 7);
        const days = @rem(total_days, 7);
        return .{ .weeks = weeks, .days = days, .intermediate = iso_calendar.fromEpochDay(start_epoch + weeks * 7) };
    }
    return .{ .days = total_days, .intermediate = end };
}

fn negateDateDiff(d: DateDiff) DateDiff {
    return .{ .years = -d.years, .months = -d.months, .weeks = -d.weeks, .days = -d.days, .intermediate = d.intermediate };
}

/// Rounds `raw` (already balanced at `resolved.largest` by `diffISODate`)
/// down to `resolved.smallest`, per `increment`/`mode`. `negate` implements
/// `since`: ground-truthed that `since` is NOT "negate `until`'s rounded
/// result" (the two disagree exactly at rounding ties) but rather "negate
/// the unrounded raw diff, then round the negated value with the same
/// mode" -- so this always computes using `start`/`end` in the forward
/// (`self`, `other`) order regardless of `negate`, and only flips signs
/// going into the rounding step itself.
///
/// The variable-length calendar-unit denominator (month/year) comes from
/// stepping **one more** `smallest`-unit in the direction of travel from
/// `raw.intermediate` -- ground-truthed with a case where "the unit at
/// `intermediate`" and "one step further" have different lengths, and only
/// the latter matched real Node (see the Phase 3b plan).
pub fn roundDateDiff(start: iso_calendar.YearMonthDay, end: iso_calendar.YearMonthDay, raw: DateDiff, resolved: rounding.ResolvedUnits, increment: u32, mode: rounding.RoundingMode, negate: bool) TemporalError!DateDiff {
    _ = raw;
    const PDT = @import("plain_date_time.zig").PlainDateTime;
    const rel = @import("relative.zig");
    const a: PDT = .{ .date = .{ .iso_year = start.year, .iso_month = start.month, .iso_day = start.day } };
    const b: PDT = .{ .date = .{ .iso_year = end.year, .iso_month = end.month, .iso_day = end.day } };
    var d = try rel.difference(a, b, try rel.epoch(a, .{}), try rel.epoch(b, .{}), .{ .largestUnit = resolved.largest, .smallestUnit = resolved.smallest, .roundingIncrement = increment, .roundingMode = if (negate) rel.negateMode(mode) else mode }, .{});
    if (negate) d = d.negated();
    return .{ .years = @intCast(@import("duration.zig").integer(d.years)), .months = @intCast(@import("duration.zig").integer(d.months)), .weeks = @intCast(@import("duration.zig").integer(d.weeks)), .days = @intCast(@import("duration.zig").integer(d.days)), .intermediate = start };
}

/// `Duration.total`'s date-only fractional balance -- the float-returning
/// counterpart to `roundDateDiff`'s per-unit numerator/denominator
/// computation (same candidate/intermediate/denominator derivation, see
/// its doc comment), but divides instead of rounding to an integer. Used
/// only via `Duration.total(relativeTo, unit)`, where `start`/`end` are
/// always a plain `relativeTo`/`relativeTo.add(duration)` pair (no time
/// component -- `PlainDate` has none).
pub fn totalUnitsBetween(start: iso_calendar.YearMonthDay, end: iso_calendar.YearMonthDay, unit: Unit) TemporalError!f64 {
    const start_epoch = iso_calendar.toEpochDay(start.year, start.month, start.day);
    const end_epoch = iso_calendar.toEpochDay(end.year, end.month, end.day);
    const total_days_f: f64 = @floatFromInt(end_epoch - start_epoch);

    switch (unit) {
        .day => return total_days_f,
        .week => return total_days_f / 7.0,
        .month => {
            const sign: i8 = if (end_epoch > start_epoch) 1 else if (end_epoch < start_epoch) -1 else 0;
            if (sign == 0) return 0;
            const raw = try diffISODate(start, end, .month);
            const next = try stepCalendar(raw.intermediate, sign, false);
            const denom: i128 = @abs(iso_calendar.toEpochDay(next.year, next.month, next.day) - iso_calendar.toEpochDay(raw.intermediate.year, raw.intermediate.month, raw.intermediate.day));
            const months_f: f64 = @floatFromInt(raw.months);
            const days_f: f64 = @floatFromInt(raw.days);
            const denom_f: f64 = @floatFromInt(denom);
            return months_f + days_f / denom_f;
        },
        .year => {
            const sign: i8 = if (end_epoch > start_epoch) 1 else if (end_epoch < start_epoch) -1 else 0;
            if (sign == 0) return 0;
            const c = try calendarCandidate(start, end, true);
            const c_intermediate_epoch = iso_calendar.toEpochDay(c.intermediate.year, c.intermediate.month, c.intermediate.day);
            const next = try stepCalendar(c.intermediate, sign, true);
            const denom: i128 = @abs(iso_calendar.toEpochDay(next.year, next.month, next.day) - c_intermediate_epoch);
            const years_f: f64 = @floatFromInt(c.candidate);
            const remaining_f: f64 = @floatFromInt(end_epoch - c_intermediate_epoch);
            const denom_f: f64 = @floatFromInt(denom);
            return years_f + remaining_f / denom_f;
        },
        else => return error.RangeError,
    }
}

pub fn regulate(in_year: i32, in_month: i32, in_day: i32, overflow: Overflow) TemporalError!PlainDate {
    if (in_month < 1 or in_day < 1) return error.RangeError;
    var m: u8 = undefined;
    if (in_month > 12) {
        if (overflow == .reject) return error.RangeError;
        m = 12;
    } else {
        m = @intCast(in_month);
    }
    const max_day = iso_calendar.daysInMonth(in_year, m);
    var d: u8 = undefined;
    if (in_day > max_day) {
        if (overflow == .reject) return error.RangeError;
        d = max_day;
    } else {
        d = @intCast(in_day);
    }
    if (!iso_calendar.isInRange(in_year, m, d)) return error.RangeError;
    return .{ .iso_year = in_year, .iso_month = m, .iso_day = d };
}

pub const PlainDate = struct {
    calendar: calendars.Id = .iso8601,
    calendarData: ?calendars.Info = null,
    iso_year: i32,
    iso_month: u8, // 1-12
    iso_day: u8, // 1-31

    /// Real spec: month/day must be positive integers UNCONDITIONALLY
    /// (ground-truthed: `month: 0` or `day: -1` throws even under
    /// `overflow: "constrain"`) -- only the UPPER bound (month > 12,
    /// day > daysInMonth) respects `overflow`.
    pub fn init(in_year: i32, in_month: i32, in_day: i32, calendarIdValue: ?[]const u8) TemporalError!PlainDate {
        return (try regulate(in_year, in_month, in_day, .reject)).withCalendar(calendarIdValue orelse "iso8601");
    }

    pub const Fields = struct {
        era: ?[]const u8 = null,
        eraYear: ?i32 = null,
        calendar: ?[]const u8 = null,
        monthCode: ?[]const u8 = null,
        year: ?i32 = null,
        month: ?i32 = null,
        day: ?i32 = null,
    };
    pub const FromInput = union(enum) { string: []const u8, value: PlainDate, fields: Fields };
    pub const FromOptions = struct { overflow: Overflow = .constrain };
    pub fn from(input: FromInput, options: FromOptions) TemporalError!PlainDate {
        return switch (input) {
            .string => |text| fromString(text),
            .value => |value| value,
            .fields => |f| blk: {
                var id = try calendars.parse(f.calendar orelse "iso8601");
                if (id == .ethiopic and f.era != null and std.ascii.eqlIgnoreCase(f.era.?, "aa")) id = .ethioaa;
                const y = try calendars.resolveYear(id, f.year, f.era, f.eraYear);
                const d = f.day orelse return error.TypeError;
                if (id == .iso8601) break :blk regulate(y, try calendars.isoMonth(f.monthCode, f.month), d, options.overflow);
                if (f.month == null and f.monthCode == null) return error.TypeError;
                const ymd = try calendars.fromFields(id, y, f.month orelse 0, d, f.monthCode, options.overflow == .constrain);
                const result = try (try regulate(ymd.year, ymd.month, ymd.day, .reject)).withCalendar(@tagName(id));
                if (f.month != null and f.monthCode != null and result.month() != f.month.?) return error.RangeError;
                if (f.era) |era_value| {
                    const actual = result.era() orelse return error.RangeError;
                    if (!std.ascii.eqlIgnoreCase(actual, era_value) and !(std.mem.eql(u8, actual, "ce") and std.ascii.eqlIgnoreCase(era_value, "ad")) and !(std.mem.eql(u8, actual, "bce") and std.ascii.eqlIgnoreCase(era_value, "bc"))) return error.RangeError;
                    if (result.eraYear() != f.eraYear) return error.RangeError;
                }
                break :blk result;
            },
        };
    }

    fn fromString(text: []const u8) TemporalError!PlainDate {
        const parsed = try iso_string.parsePlainDate(text);
        // A parsed ISO string is always exact -- reject if (somehow) out
        // of the representable range, never clamp silently.
        return (try regulate(parsed.year, parsed.month, parsed.day, .reject)).withCalendar(@tagName(try calendars.fromString(text)));
    }

    /// Field overrides (`in_year`/`in_month`/`in_day`, each optional --
    /// `null` keeps the current value), re-validated the same way
    /// `init` does.
    pub fn with(self: PlainDate, fields: Fields, options: FromOptions) TemporalError!PlainDate {
        if (fields.calendar != null or (self.calendar != .iso8601 and (fields.era == null) != (fields.eraYear == null))) return error.TypeError;
        if ((self.calendar == .iso8601 or (fields.era == null and fields.eraYear == null)) and fields.year == null and fields.month == null and fields.monthCode == null and fields.day == null) return error.TypeError;
        var buf: [4]u8 = undefined;
        const code = if (fields.monthCode) |value| value else if (fields.month == null) self.monthCode(&buf) else null;
        return from(.{ .fields = .{ .year = if (fields.era != null or fields.eraYear != null) fields.year else fields.year orelse self.year(), .era = fields.era, .eraYear = fields.eraYear, .month = fields.month, .monthCode = code, .day = fields.day orelse self.day(), .calendar = @tagName(self.calendar) } }, options);
    }

    /// Years/months applied first (`addISODate`, with `overflow` clamp/
    /// reject), then weeks/days/time-part folded into a single epoch-day
    /// step. The duration's time part **truncates toward zero** when
    /// converted to whole days (there's no existing time-of-day to
    /// combine with, unlike `PlainDateTime.add`, which floors) --
    /// ground-truthed: `.add({hours:-1})` on day 1 stays day 1
    /// (trunc(-1/24)=0), `.add({hours:-25})` from day 2 goes to day 1
    /// (trunc(-25/24)=-1), not further.
    pub fn add(self: PlainDate, d: Duration, overflow: Overflow) TemporalError!PlainDate {
        try @import("duration.zig").validate(d);
        const stepped = if (self.calendar == .iso8601) try addISODate(self.iso_year, self.iso_month, self.iso_day, @intCast(@import("duration.zig").integer(d.years)), @intCast(@import("duration.zig").integer(d.months)), overflow) else try calendars.add(self.calendar, self.asYMD(), @intCast(@import("duration.zig").integer(d.years)), @intCast(@import("duration.zig").integer(d.months)), overflow == .constrain);
        const days_from_time: i64 = @intCast(@divTrunc(d.totalTimeNanoseconds(), 86_400_000_000_000));
        const extra_days: i64 = @as(i64, @intCast(@import("duration.zig").integer(d.weeks))) * 7 + days_from_time;
        const epoch_day = iso_calendar.toEpochDay(stepped.year, stepped.month, stepped.day) + extra_days;
        const ymd = iso_calendar.fromEpochDay(epoch_day);
        if (!iso_calendar.isInRange(ymd.year, ymd.month, ymd.day)) return error.RangeError;
        return (try regulate(ymd.year, ymd.month, ymd.day, .reject)).withCalendar(@tagName(self.calendar));
    }

    pub fn subtract(self: PlainDate, d: Duration, overflow: Overflow) TemporalError!PlainDate {
        return self.add(d.negated(), overflow);
    }

    pub fn asYMD(self: PlainDate) iso_calendar.YearMonthDay {
        return .{ .year = self.iso_year, .month = self.iso_month, .day = self.iso_day };
    }

    pub fn until(self: PlainDate, other: PlainDate, options: RoundingOptions) TemporalError!Duration {
        if (!calendars.equal(self.calendar, other.calendar)) return error.RangeError;
        _ = try rounding.resolveDateUnits(options);
        const a: @import("plain_date_time.zig").PlainDateTime = .{ .date = self };
        const b: @import("plain_date_time.zig").PlainDateTime = .{ .date = other };
        const rel = @import("relative.zig");
        var opts = options;
        opts.largestUnit = (try rounding.resolveDateUnits(options)).largest;
        opts.smallestUnit = options.smallestUnit orelse .day;

        const result = try rel.difference(a, b, try rel.epoch(a, .{}), try rel.epoch(b, .{}), opts, .{});
        return result;
    }

    pub fn since(self: PlainDate, other: PlainDate, options: RoundingOptions) TemporalError!Duration {
        if (!calendars.equal(self.calendar, other.calendar)) return error.RangeError;
        _ = try rounding.resolveDateUnits(options);
        const a: @import("plain_date_time.zig").PlainDateTime = .{ .date = self };
        const b: @import("plain_date_time.zig").PlainDateTime = .{ .date = other };
        const rel = @import("relative.zig");
        var opts = options;
        opts.largestUnit = (try rounding.resolveDateUnits(options)).largest;
        opts.smallestUnit = options.smallestUnit orelse .day;
        opts.roundingMode = rel.negateMode(opts.roundingMode);
        const result = try rel.difference(a, b, try rel.epoch(a, .{}), try rel.epoch(b, .{}), opts, .{});
        return result.negated();
    }

    pub fn compare(a: PlainDate, b: PlainDate) std.math.Order {
        const ea = iso_calendar.toEpochDay(a.iso_year, a.iso_month, a.iso_day);
        const eb = iso_calendar.toEpochDay(b.iso_year, b.iso_month, b.iso_day);
        return std.math.order(ea, eb);
    }

    pub fn equals(a: PlainDate, b: PlainDate) bool {
        return a.iso_year == b.iso_year and a.iso_month == b.iso_month and a.iso_day == b.iso_day and calendars.equal(a.calendar, b.calendar);
    }

    pub fn year(self: PlainDate) i32 {
        return if (self.calendarData) |info| info.year else self.iso_year;
    }
    pub fn month(self: PlainDate) u8 {
        return if (self.calendarData) |info| @intCast(info.month) else self.iso_month;
    }
    pub fn day(self: PlainDate) u8 {
        return if (self.calendarData) |info| @intCast(info.day) else self.iso_day;
    }
    pub fn monthCode(self: PlainDate, buf: *[4]u8) []const u8 {
        if (self.calendarData) |info| return std.fmt.bufPrint(buf, "M{d:0>2}{s}", .{ @as(u32, @intCast(info.month_code)), if (info.leap_month != 0) "L" else "" }) catch unreachable;
        const small: *[3]u8 = @ptrCast(buf);
        return iso_calendar.monthCodeBuf(small, self.iso_month);
    }
    pub fn calendarId(self: PlainDate) []const u8 {
        return @import("calendar.zig").displayName(self.calendar);
    }
    pub fn toPlainDateTime(self: PlainDate, time: ?@import("plain_time.zig").PlainTime) TemporalError!@import("plain_date_time.zig").PlainDateTime {
        const value: @import("plain_date_time.zig").PlainDateTime = .{ .date = self, .time = time orelse .{} };
        try value.validate();
        return value;
    }
    pub fn toZonedDateTime(self: PlainDate, allocator: std.mem.Allocator, io: std.Io, timeZone: []const u8, plainTime: ?@import("plain_time.zig").PlainTime) TemporalError!@import("zoned_date_time.zig").ZonedDateTime {
        const value = try (try self.toPlainDateTime(plainTime)).toZonedDateTime(allocator, io, timeZone, .compatible);
        return if (plainTime == null) value.startOfDay(allocator, io) else value;
    }
    pub fn withCalendar(self: PlainDate, id: []const u8) TemporalError!PlainDate {
        var result = self;
        result.calendar = try calendars.parse(id);
        result.calendarData = try calendars.info(self.asYMD(), result.calendar);
        return result;
    }
    pub fn era(self: PlainDate) ?[]const u8 {
        return if (self.calendarData) |info| calendars.era(self.calendar, info, self.asYMD()) else null;
    }
    pub fn eraYear(self: PlainDate) ?i32 {
        if (self.era() == null) return null;
        return calendars.eraYear(self.calendar, self.calendarData.?, self.asYMD());
    }
    pub fn daysInWeek(_: PlainDate) u8 {
        return 7;
    }
    pub fn yearOfWeek(self: PlainDate) ?i32 {
        if (self.calendar != .iso8601) return null;
        return iso_calendar.weekOfYear(self.iso_year, self.iso_month, self.iso_day).year;
    }
    pub fn toPlainYearMonth(self: PlainDate) TemporalError!plain_year_month.PlainYearMonth {
        var buf: [4]u8 = undefined;
        return plain_year_month.PlainYearMonth.from(.{ .fields = .{ .year = self.year(), .monthCode = self.monthCode(&buf), .calendar = @tagName(self.calendar) } }, .{});
    }
    pub fn toPlainMonthDay(self: PlainDate) TemporalError!plain_month_day.PlainMonthDay {
        var buf: [4]u8 = undefined;
        return plain_month_day.PlainMonthDay.from(.{ .fields = .{ .monthCode = self.monthCode(&buf), .day = self.day(), .calendar = @tagName(self.calendar) } }, .{});
    }
    pub fn dayOfWeek(self: PlainDate) u8 {
        return iso_calendar.dayOfWeek(self.iso_year, self.iso_month, self.iso_day);
    }
    pub fn dayOfYear(self: PlainDate) u16 {
        if (self.calendarData) |info| return @intCast(info.day_of_year);
        return iso_calendar.dayOfYear(self.iso_year, self.iso_month, self.iso_day);
    }
    pub fn daysInMonth(self: PlainDate) u8 {
        if (self.calendarData) |info| return @intCast(info.days_in_month);
        return iso_calendar.daysInMonth(self.iso_year, self.iso_month);
    }
    pub fn daysInYear(self: PlainDate) u16 {
        if (self.calendarData) |info| return @intCast(info.days_in_year);
        return iso_calendar.daysInYear(self.iso_year);
    }
    pub fn monthsInYear(self: PlainDate) u8 {
        return if (self.calendarData) |info| @intCast(info.months_in_year) else 12;
    }
    pub fn inLeapYear(self: PlainDate) bool {
        return if (self.calendarData) |info| info.leap_year != 0 else iso_calendar.isLeapYear(self.iso_year);
    }
    pub fn weekOfYear(self: PlainDate) ?u8 {
        if (self.calendar != .iso8601) return null;
        return iso_calendar.weekOfYear(self.iso_year, self.iso_month, self.iso_day).week;
    }

    /// `YYYY-MM-DD` (or the extended `±YYYYYY-MM-DD` form outside
    /// [0,9999]), optionally suffixed with `[u-ca=iso8601]`.
    pub fn toLocaleString(self: PlainDate, allocator: std.mem.Allocator, io: std.Io, locales: ?[]const u8, options: @import("locale.zig").LocaleOptions) TemporalError![]u8 {
        const d = self.asYMD();
        return @import("locale.zig").format(allocator, io, .date, @as(f64, @floatFromInt(iso_calendar.toEpochDay(d.year, d.month, d.day))) * 86_400_000, self.calendar, null, locales, options);
    }
    pub fn toString(self: PlainDate, allocator: std.mem.Allocator, options: StringOptions) TemporalError![]u8 {
        const raw = try self.formatDefault(allocator, options.calendarName == .always or options.calendarName == .critical or (options.calendarName == .auto and self.calendar != .iso8601));
        defer allocator.free(raw);
        return @import("format_options.zig").calendar(allocator, raw, options.calendarName == .critical);
    }
    pub fn toJSON(self: PlainDate, allocator: std.mem.Allocator) TemporalError![]u8 {
        return self.toString(allocator, .{});
    }
    pub const StringOptions = @import("format_options.zig").StringOptions;
    fn formatDefault(self: PlainDate, allocator: std.mem.Allocator, show_calendar: bool) ![]u8 {
        var year_buf: [8]u8 = undefined;
        const year_str = iso_string.formatYear(&year_buf, self.iso_year);
        if (show_calendar) {
            return allocator.print("{s}-{d:0>2}-{d:0>2}[u-ca={s}]", .{ year_str, self.iso_month, self.iso_day, self.calendarId() });
        }
        return allocator.print("{s}-{d:0>2}-{d:0>2}", .{ year_str, self.iso_month, self.iso_day });
    }
};

test "init: constrain clamps upper bound, reject throws" {
    const constrained = try @import("plain_date.zig").regulate(2024, 13, 1, .constrain);
    try std.testing.expectEqual(@as(u8, 12), constrained.iso_month);
    try std.testing.expectError(error.RangeError, PlainDate.init(2024, 13, 1, null));

    const day_constrained = try @import("plain_date.zig").regulate(2024, 2, 30, .constrain);
    try std.testing.expectEqual(@as(u8, 29), day_constrained.iso_day);
    try std.testing.expectError(error.RangeError, PlainDate.init(2024, 2, 30, null));
}

test "init: month/day below 1 always rejects, regardless of overflow" {
    try std.testing.expectError(error.RangeError, @import("plain_date.zig").regulate(2024, 0, 1, .constrain));
    try std.testing.expectError(error.RangeError, @import("plain_date.zig").regulate(2024, 1, -1, .constrain));
}

test "init: out-of-range year is RangeError" {
    try std.testing.expectError(error.RangeError, PlainDate.init(275760, 9, 14, null));
    try std.testing.expectError(error.RangeError, PlainDate.init(-271821, 4, 18, null));
    _ = try PlainDate.init(275760, 9, 13, null);
    _ = try PlainDate.init(-271821, 4, 19, null);
}

test "compare/equals" {
    const a = try PlainDate.init(2024, 2, 29, null);
    const b = try PlainDate.init(2024, 3, 1, null);
    try std.testing.expectEqual(std.math.Order.lt, PlainDate.compare(a, b));
    try std.testing.expect(!PlainDate.equals(a, b));
    try std.testing.expect(PlainDate.equals(a, a));
}

test "toString matches real Node byte-for-byte" {
    const allocator = std.testing.allocator;
    {
        const d = try PlainDate.init(2024, 2, 29, null);
        const s = try d.toString(allocator, .{});
        defer allocator.free(s);
        try std.testing.expectEqualStrings("2024-02-29", s);
    }
    {
        const d = try PlainDate.init(999, 1, 1, null);
        const s = try d.toString(allocator, .{});
        defer allocator.free(s);
        try std.testing.expectEqualStrings("0999-01-01", s);
    }
    {
        const d = try PlainDate.init(-1, 1, 1, null);
        const s = try d.toString(allocator, .{});
        defer allocator.free(s);
        try std.testing.expectEqualStrings("-000001-01-01", s);
    }
    {
        const d = try PlainDate.init(2024, 2, 29, null);
        const s = try d.toString(allocator, .{ .calendarName = .always });
        defer allocator.free(s);
        try std.testing.expectEqualStrings("2024-02-29[u-ca=iso8601]", s);
    }
}

test "fromString round-trips and rejects non-iso8601 calendar" {
    const d = try PlainDate.from(.{ .string = "2024-02-29[u-ca=iso8601]" }, .{});
    try std.testing.expectEqual(@as(i32, 2024), d.iso_year);
    try std.testing.expectError(error.RangeError, PlainDate.from(.{ .string = "2024-02-29[u-ca=unknown]" }, .{}));
}

test "add: months applied before days (order matters), default constrain" {
    const d = try PlainDate.init(2024, 1, 30, null);
    const r = try d.add(try Duration.init(0, 1, 0, 1, 0, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(i32, 2024), r.iso_year);
    try std.testing.expectEqual(@as(u8, 3), r.iso_month);
    try std.testing.expectEqual(@as(u8, 1), r.iso_day);
}

test "add: reject overflow throws on invalid resulting day" {
    const d = try PlainDate.init(2023, 1, 31, null);
    try std.testing.expectError(error.RangeError, d.add(try Duration.init(0, 1, 0, 0, 0, 0, 0, 0, 0, 0), .reject));
}

test "add: duration time part truncates toward zero into days (no existing time-of-day)" {
    const day1 = try PlainDate.init(2024, 1, 1, null);
    const stayed = try day1.add(try Duration.init(0, 0, 0, 0, -1, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(u8, 1), stayed.iso_day);

    const day2 = try PlainDate.init(2024, 1, 2, null);
    const back = try day2.add(try Duration.init(0, 0, 0, 0, -25, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(u8, 1), back.iso_day);
}

test "subtract: mirrors add(negated)" {
    const d = try PlainDate.init(2024, 3, 31, null);
    const r = try d.subtract(try Duration.init(0, 1, 0, 0, 0, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(u8, 2), r.iso_month);
    try std.testing.expectEqual(@as(u8, 29), r.iso_day);
}
