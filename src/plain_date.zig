//! `Temporal.PlainDate`, ISO calendar only (Phase 1 -- non-ISO calendars are
//! a later phase, see the README's Scope section). No arithmetic
//! (`.add`/`.subtract`/`.until`/`.since`) -- that needs `Duration`, a later
//! phase.
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
/// constructor semantics should pass `.reject` to `create`.
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
    if (new_year_i64 < iso_calendar.MIN_ISO_YEAR - 1 or new_year_i64 > iso_calendar.MAX_ISO_YEAR + 1) return error.InvalidRange;
    const new_year: i32 = @intCast(new_year_i64);

    const max_day = iso_calendar.daysInMonth(new_year, new_month);
    var d = day;
    if (day > max_day) {
        if (overflow == .reject) return error.InvalidRange;
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
/// `largest_unit` granularity. Ground-truthed candidate/overshoot-adjust
/// algorithm (see the Phase 3b plan for the full derivation): for the
/// year/month family, always steps in MONTHS internally (never years
/// directly) and splits into years+months only for display -- this is
/// what makes leap-day/month-end borrow cases land correctly (e.g.
/// `2023-01-31 -> 2024-02-29` gives `P1Y29D`, no month term, rather than
/// what a naive Y/M/D-subtraction-with-borrow algorithm would produce).
/// `intermediate` (the position after applying the largest_unit-level
/// candidate) is returned so `roundDateDiff` can take "one more step" for
/// the rounding fraction's denominator without recomputing the balance.
pub fn diffISODate(start: iso_calendar.YearMonthDay, end: iso_calendar.YearMonthDay, largest_unit: Unit) TemporalError!DateDiff {
    const start_epoch = iso_calendar.toEpochDay(start.year, start.month, start.day);
    const end_epoch = iso_calendar.toEpochDay(end.year, end.month, end.day);

    if (largest_unit == .year or largest_unit == .month) {
        const c = try calendarCandidate(start, end, false);
        const intermediate_epoch = iso_calendar.toEpochDay(c.intermediate.year, c.intermediate.month, c.intermediate.day);
        const remaining_days = end_epoch - intermediate_epoch;
        if (largest_unit == .year) {
            return .{ .years = @divTrunc(c.candidate, 12), .months = @rem(c.candidate, 12), .days = remaining_days, .intermediate = c.intermediate };
        }
        return .{ .months = c.candidate, .days = remaining_days, .intermediate = c.intermediate };
    }

    const total_days = end_epoch - start_epoch;
    if (largest_unit == .week) {
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
    if (resolved.smallest == .day and increment == 1) {
        return if (negate) negateDateDiff(raw) else raw;
    }

    const start_epoch = iso_calendar.toEpochDay(start.year, start.month, start.day);
    const end_epoch = iso_calendar.toEpochDay(end.year, end.month, end.day);
    const sign: i8 = if (end_epoch > start_epoch) 1 else if (end_epoch < start_epoch) -1 else 0;
    if (sign == 0) return .{ .intermediate = start };

    switch (resolved.smallest) {
        .day => {
            var candidate: i128 = raw.days;
            if (negate) candidate = -candidate;
            const rounded_days: i64 = @intCast(rounding.roundRatioToIncrement(candidate, 1, increment, mode));
            return .{
                .years = if (negate) -raw.years else raw.years,
                .months = if (negate) -raw.months else raw.months,
                .weeks = if (negate) -raw.weeks else raw.weeks,
                .days = rounded_days,
                .intermediate = raw.intermediate,
            };
        },
        // KNOWN LIMITATION (Phase 3c ground-truthing): when `raw` came
        // from the year/month family (`resolved.largest` is `.year` or
        // `.month`, so `raw.weeks == 0` and this branch is only adjusting
        // the trailing day-remainder into weeks) AND the direction is
        // backward (`end` before `start`), the 5 half-* rounding modes
        // (`half_ceil`/`half_floor`/`half_trunc`/`half_expand`/
        // `half_even`) do not always match real Temporal -- confirmed
        // `ceil`/`floor`/`trunc`/`expand` (non-tie-breaking modes) DO
        // match exactly in this same combination, and ALL 9 modes match
        // correctly in the forward direction and whenever `raw` is
        // itself from the week/day family (`resolved.largest == .week`).
        // Extensive differential probing against real Node did not
        // converge on the exact backward+half-mode algorithm in
        // reasonable time; this is accepted, narrow, documented debt
        // (see README's Scope section) rather than a silent gap.
        .week => {
            var total_days: i128 = @as(i128, raw.weeks) * 7 + raw.days;
            if (negate) total_days = -total_days;
            const rounded_weeks: i64 = @intCast(rounding.roundRatioToIncrement(total_days, 7, increment, mode));
            return .{
                .years = if (negate) -raw.years else raw.years,
                .months = if (negate) -raw.months else raw.months,
                .weeks = rounded_weeks,
                .intermediate = raw.intermediate,
            };
        },
        .month => {
            const total_months = raw.years * 12 + raw.months;
            const next = try stepCalendar(raw.intermediate, sign, false);
            const denom: i128 = @abs(iso_calendar.toEpochDay(next.year, next.month, next.day) - iso_calendar.toEpochDay(raw.intermediate.year, raw.intermediate.month, raw.intermediate.day));
            var numerator: i128 = @as(i128, total_months) * denom + raw.days;
            if (negate) numerator = -numerator;
            const rounded_total = rounding.roundRatioToIncrement(numerator, denom, increment, mode);
            if (resolved.largest == .year) {
                return .{ .years = @intCast(@divTrunc(rounded_total, 12)), .months = @intCast(@rem(rounded_total, 12)), .intermediate = raw.intermediate };
            }
            return .{ .months = @intCast(rounded_total), .intermediate = raw.intermediate };
        },
        .year => {
            const c = try calendarCandidate(start, end, true);
            const c_intermediate_epoch = iso_calendar.toEpochDay(c.intermediate.year, c.intermediate.month, c.intermediate.day);
            const next = try stepCalendar(c.intermediate, sign, true);
            const denom: i128 = @abs(iso_calendar.toEpochDay(next.year, next.month, next.day) - c_intermediate_epoch);
            var numerator: i128 = @as(i128, c.candidate) * denom + (end_epoch - c_intermediate_epoch);
            if (negate) numerator = -numerator;
            const rounded_total = rounding.roundRatioToIncrement(numerator, denom, increment, mode);
            return .{ .years = @intCast(rounded_total), .intermediate = c.intermediate };
        },
        else => unreachable,
    }
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
        else => return error.InvalidRange,
    }
}

pub const PlainDate = struct {
    iso_year: i32,
    iso_month: u8, // 1-12
    iso_day: u8, // 1-31

    /// Real spec: month/day must be positive integers UNCONDITIONALLY
    /// (ground-truthed: `month: 0` or `day: -1` throws even under
    /// `overflow: "constrain"`) -- only the UPPER bound (month > 12,
    /// day > daysInMonth) respects `overflow`.
    pub fn create(in_year: i32, in_month: i32, in_day: i32, overflow: Overflow) TemporalError!PlainDate {
        if (in_month < 1 or in_day < 1) return error.InvalidRange;
        var m: u8 = undefined;
        if (in_month > 12) {
            if (overflow == .reject) return error.InvalidRange;
            m = 12;
        } else {
            m = @intCast(in_month);
        }
        const max_day = iso_calendar.daysInMonth(in_year, m);
        var d: u8 = undefined;
        if (in_day > max_day) {
            if (overflow == .reject) return error.InvalidRange;
            d = max_day;
        } else {
            d = @intCast(in_day);
        }
        if (!iso_calendar.isInRange(in_year, m, d)) return error.InvalidRange;
        return .{ .iso_year = in_year, .iso_month = m, .iso_day = d };
    }

    pub fn parseIso(text: []const u8) TemporalError!PlainDate {
        const parsed = try iso_string.parsePlainDate(text);
        // A parsed ISO string is always exact -- reject if (somehow) out
        // of the representable range, never clamp silently.
        return create(parsed.year, parsed.month, parsed.day, .reject);
    }

    /// Field overrides (`in_year`/`in_month`/`in_day`, each optional --
    /// `null` keeps the current value), re-validated the same way
    /// `create` does.
    pub fn withFields(self: PlainDate, in_year: ?i32, in_month: ?i32, in_day: ?i32, overflow: Overflow) TemporalError!PlainDate {
        return create(in_year orelse self.iso_year, in_month orelse self.iso_month, in_day orelse self.iso_day, overflow);
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
        const stepped = try addISODate(self.iso_year, self.iso_month, self.iso_day, d.years, d.months, overflow);
        const days_from_time: i64 = @intCast(@divTrunc(d.totalTimeNanoseconds(), 86_400_000_000_000));
        const extra_days: i64 = d.weeks * 7 + days_from_time;
        const epoch_day = iso_calendar.toEpochDay(stepped.year, stepped.month, stepped.day) + extra_days;
        const ymd = iso_calendar.fromEpochDay(epoch_day);
        if (!iso_calendar.isInRange(ymd.year, ymd.month, ymd.day)) return error.InvalidRange;
        return .{ .iso_year = ymd.year, .iso_month = ymd.month, .iso_day = ymd.day };
    }

    pub fn subtract(self: PlainDate, d: Duration, overflow: Overflow) TemporalError!PlainDate {
        return self.add(d.negated(), overflow);
    }

    pub fn asYMD(self: PlainDate) iso_calendar.YearMonthDay {
        return .{ .year = self.iso_year, .month = self.iso_month, .day = self.iso_day };
    }

    pub fn until(self: PlainDate, other: PlainDate, options: RoundingOptions) TemporalError!Duration {
        const resolved = try rounding.resolveDateUnits(options);
        const start = self.asYMD();
        const end = other.asYMD();
        const raw = try diffISODate(start, end, resolved.largest);
        const d = try roundDateDiff(start, end, raw, resolved, options.rounding_increment, options.rounding_mode, false);
        return Duration.create(d.years, d.months, d.weeks, d.days, 0, 0, 0, 0, 0, 0);
    }

    pub fn since(self: PlainDate, other: PlainDate, options: RoundingOptions) TemporalError!Duration {
        const resolved = try rounding.resolveDateUnits(options);
        const start = self.asYMD();
        const end = other.asYMD();
        const raw = try diffISODate(start, end, resolved.largest);
        const d = try roundDateDiff(start, end, raw, resolved, options.rounding_increment, options.rounding_mode, true);
        return Duration.create(d.years, d.months, d.weeks, d.days, 0, 0, 0, 0, 0, 0);
    }

    pub fn compare(a: PlainDate, b: PlainDate) std.math.Order {
        const ea = iso_calendar.toEpochDay(a.iso_year, a.iso_month, a.iso_day);
        const eb = iso_calendar.toEpochDay(b.iso_year, b.iso_month, b.iso_day);
        return std.math.order(ea, eb);
    }

    pub fn equals(a: PlainDate, b: PlainDate) bool {
        return a.iso_year == b.iso_year and a.iso_month == b.iso_month and a.iso_day == b.iso_day;
    }

    pub fn year(self: PlainDate) i32 {
        return self.iso_year;
    }
    pub fn month(self: PlainDate) u8 {
        return self.iso_month;
    }
    pub fn day(self: PlainDate) u8 {
        return self.iso_day;
    }
    pub fn monthCode(self: PlainDate, buf: *[3]u8) []const u8 {
        return iso_calendar.monthCodeBuf(buf, self.iso_month);
    }
    pub fn calendarId(self: PlainDate) []const u8 {
        _ = self;
        return "iso8601";
    }
    pub fn toPlainYearMonth(self: PlainDate) plain_year_month.PlainYearMonth {
        return .{ .iso_year = self.iso_year, .iso_month = self.iso_month };
    }
    /// Reference year is always 1972, regardless of `self`'s own year --
    /// ground-truthed against real Node (`plain_month_day.zig`'s doc
    /// comment has the full derivation).
    pub fn toPlainMonthDay(self: PlainDate) plain_month_day.PlainMonthDay {
        return .{ .iso_month = self.iso_month, .iso_day = self.iso_day, .reference_year = plain_month_day.REFERENCE_YEAR };
    }
    pub fn dayOfWeek(self: PlainDate) u8 {
        return iso_calendar.dayOfWeek(self.iso_year, self.iso_month, self.iso_day);
    }
    pub fn dayOfYear(self: PlainDate) u16 {
        return iso_calendar.dayOfYear(self.iso_year, self.iso_month, self.iso_day);
    }
    pub fn daysInMonth(self: PlainDate) u8 {
        return iso_calendar.daysInMonth(self.iso_year, self.iso_month);
    }
    pub fn daysInYear(self: PlainDate) u16 {
        return iso_calendar.daysInYear(self.iso_year);
    }
    pub fn monthsInYear(self: PlainDate) u8 {
        _ = self;
        return 12;
    }
    pub fn inLeapYear(self: PlainDate) bool {
        return iso_calendar.isLeapYear(self.iso_year);
    }
    pub fn weekOfYear(self: PlainDate) iso_calendar.WeekOfYear {
        return iso_calendar.weekOfYear(self.iso_year, self.iso_month, self.iso_day);
    }

    /// `YYYY-MM-DD` (or the extended `±YYYYYY-MM-DD` form outside
    /// [0,9999]), optionally suffixed with `[u-ca=iso8601]`.
    pub fn toIsoString(self: PlainDate, allocator: std.mem.Allocator, show_calendar: bool) ![]u8 {
        var year_buf: [8]u8 = undefined;
        const year_str = iso_string.formatYear(&year_buf, self.iso_year);
        if (show_calendar) {
            return std.fmt.allocPrint(allocator, "{s}-{d:0>2}-{d:0>2}[u-ca=iso8601]", .{ year_str, self.iso_month, self.iso_day });
        }
        return std.fmt.allocPrint(allocator, "{s}-{d:0>2}-{d:0>2}", .{ year_str, self.iso_month, self.iso_day });
    }
};

test "create: constrain clamps upper bound, reject throws" {
    const constrained = try PlainDate.create(2024, 13, 1, .constrain);
    try std.testing.expectEqual(@as(u8, 12), constrained.iso_month);
    try std.testing.expectError(error.InvalidRange, PlainDate.create(2024, 13, 1, .reject));

    const day_constrained = try PlainDate.create(2024, 2, 30, .constrain);
    try std.testing.expectEqual(@as(u8, 29), day_constrained.iso_day);
    try std.testing.expectError(error.InvalidRange, PlainDate.create(2024, 2, 30, .reject));
}

test "create: month/day below 1 always rejects, regardless of overflow" {
    try std.testing.expectError(error.InvalidRange, PlainDate.create(2024, 0, 1, .constrain));
    try std.testing.expectError(error.InvalidRange, PlainDate.create(2024, 1, -1, .constrain));
}

test "create: out-of-range year is InvalidRange" {
    try std.testing.expectError(error.InvalidRange, PlainDate.create(275760, 9, 14, .reject));
    try std.testing.expectError(error.InvalidRange, PlainDate.create(-271821, 4, 18, .reject));
    _ = try PlainDate.create(275760, 9, 13, .reject);
    _ = try PlainDate.create(-271821, 4, 19, .reject);
}

test "compare/equals" {
    const a = try PlainDate.create(2024, 2, 29, .reject);
    const b = try PlainDate.create(2024, 3, 1, .reject);
    try std.testing.expectEqual(std.math.Order.lt, PlainDate.compare(a, b));
    try std.testing.expect(!PlainDate.equals(a, b));
    try std.testing.expect(PlainDate.equals(a, a));
}

test "toIsoString matches real Node byte-for-byte" {
    const allocator = std.testing.allocator;
    {
        const d = try PlainDate.create(2024, 2, 29, .reject);
        const s = try d.toIsoString(allocator, false);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("2024-02-29", s);
    }
    {
        const d = try PlainDate.create(999, 1, 1, .reject);
        const s = try d.toIsoString(allocator, false);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("0999-01-01", s);
    }
    {
        const d = try PlainDate.create(-1, 1, 1, .reject);
        const s = try d.toIsoString(allocator, false);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("-000001-01-01", s);
    }
    {
        const d = try PlainDate.create(2024, 2, 29, .reject);
        const s = try d.toIsoString(allocator, true);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("2024-02-29[u-ca=iso8601]", s);
    }
}

test "parseIso round-trips and rejects non-iso8601 calendar" {
    const d = try PlainDate.parseIso("2024-02-29[u-ca=iso8601]");
    try std.testing.expectEqual(@as(i32, 2024), d.iso_year);
    try std.testing.expectError(error.InvalidFormat, PlainDate.parseIso("2024-02-29[u-ca=hebrew]"));
}

test "add: months applied before days (order matters), default constrain" {
    const d = try PlainDate.create(2024, 1, 30, .reject);
    const r = try d.add(try Duration.create(0, 1, 0, 1, 0, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(i32, 2024), r.iso_year);
    try std.testing.expectEqual(@as(u8, 3), r.iso_month);
    try std.testing.expectEqual(@as(u8, 1), r.iso_day);
}

test "add: reject overflow throws on invalid resulting day" {
    const d = try PlainDate.create(2023, 1, 31, .reject);
    try std.testing.expectError(error.InvalidRange, d.add(try Duration.create(0, 1, 0, 0, 0, 0, 0, 0, 0, 0), .reject));
}

test "add: duration time part truncates toward zero into days (no existing time-of-day)" {
    const day1 = try PlainDate.create(2024, 1, 1, .reject);
    const stayed = try day1.add(try Duration.create(0, 0, 0, 0, -1, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(u8, 1), stayed.iso_day);

    const day2 = try PlainDate.create(2024, 1, 2, .reject);
    const back = try day2.add(try Duration.create(0, 0, 0, 0, -25, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(u8, 1), back.iso_day);
}

test "subtract: mirrors add(negated)" {
    const d = try PlainDate.create(2024, 3, 31, .reject);
    const r = try d.subtract(try Duration.create(0, 1, 0, 0, 0, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(u8, 2), r.iso_month);
    try std.testing.expectEqual(@as(u8, 29), r.iso_day);
}
