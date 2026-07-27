//! ISO 8601 calendar math (leap years, days-in-month, day-of-week,
//! day-of-year, ISO week numbering, epoch-day conversion). Ported from
//! `z-date`'s `calendar.zig` (day-of-week via an epoch-day closed form,
//! NOT Zeller's congruence -- Zeller's truncated-division split silently
//! produced wrong weekdays for negative/BCE years) but reindexed to
//! Temporal's 1-12 month convention (z-date uses 0-11) and extended with
//! ISO week numbering and day-of-year, which z-date has no equivalent of.
const std = @import("std");

/// True if `year` cannot be represented by any ISO date (Temporal's own
/// range: -271821-04-19 .. +275760-09-13, ground-truthed against real
/// Node's `Temporal.PlainDate` constructor boundaries).
pub const MIN_ISO_YEAR: i32 = -271821;
pub const MAX_ISO_YEAR: i32 = 275760;

pub fn isLeapYear(year: i32) bool {
    if (@mod(year, 4) != 0) return false;
    if (@mod(year, 100) == 0 and @mod(year, 400) != 0) return false;
    return true;
}

const DAYS_IN_MONTH = [12]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

/// `month` is 1-12 (Temporal convention, unlike z-date's 0-11).
pub fn daysInMonth(year: i32, month: u8) u8 {
    if (month == 2 and isLeapYear(year)) return 29;
    return DAYS_IN_MONTH[month - 1];
}

pub fn daysInYear(year: i32) u16 {
    return if (isLeapYear(year)) 366 else 365;
}

/// Days since the epoch (1970-01-01 = day 0) for a given year's January 1.
/// `year` as i64 so `year - 1970` never overflows even at `minInt(i32)`.
fn yearToEpochDay(year: i64) i64 {
    const y = year - 1970;
    var leap_years: i64 = 0;
    if (y >= 0) {
        leap_years = @divFloor(y + 1, 4) - @divFloor(y + 69, 100) + @divFloor(y + 369, 400);
    } else {
        const yb = -y;
        leap_years = -(@divFloor(yb + 2, 4) - @divFloor(yb + 30, 100) + @divFloor(yb + 30, 400));
    }
    return y * 365 + leap_years;
}

/// Days since the epoch (1970-01-01 = day 0) for `year-month-day`.
pub fn toEpochDay(year: i32, month: u8, day: u8) i64 {
    var days: i64 = yearToEpochDay(year);
    var m: u8 = 1;
    while (m < month) : (m += 1) days += daysInMonth(year, m);
    days += day - 1;
    return days;
}

pub const YearMonthDay = struct { year: i32, month: u8, day: u8 };

/// Inverse of `toEpochDay`. Same O(1)-amortized year approximation z-date's
/// `timestampToComponents` uses (ratio 146097 days == 400 Gregorian years,
/// then adjust by a small bounded number of steps), followed by a month
/// scan (at most 12 iterations).
pub fn fromEpochDay(epoch_day: i64) YearMonthDay {
    var year: i64 = 1970 + @divTrunc(epoch_day * 400, 146097);
    while (true) {
        const year_start = yearToEpochDay(year);
        const next_year_start = yearToEpochDay(year + 1);
        if (epoch_day >= year_start and epoch_day < next_year_start) break;
        if (epoch_day < year_start) year -= 1 else year += 1;
    }
    const year_i32: i32 = @intCast(year);
    const day_of_year_0based = epoch_day - yearToEpochDay(year);

    var month: u8 = 1;
    var day_in_month: i64 = day_of_year_0based + 1;
    while (month < 12) : (month += 1) {
        const dim = daysInMonth(year_i32, month);
        if (day_in_month <= dim) break;
        day_in_month -= dim;
    }
    return .{ .year = year_i32, .month = month, .day = @intCast(day_in_month) };
}

/// Day of week, 1 (Monday) .. 7 (Sunday) -- Temporal/ISO 8601 numbering
/// (NOT classic `Date`'s 0-6 Sunday=0). 1970-01-01 was a Thursday (ISO 4).
pub fn dayOfWeek(year: i32, month: u8, day: u8) u8 {
    const days = toEpochDay(year, month, day);
    // @mod is floored, so negative epoch days resolve correctly.
    return @intCast(@mod(days + 3, 7) + 1);
}

/// Day of year, 1-based (Jan 1 == 1).
pub fn dayOfYear(year: i32, month: u8, day: u8) u16 {
    var doy: u16 = day;
    var m: u8 = 1;
    while (m < month) : (m += 1) doy += daysInMonth(year, m);
    return doy;
}

/// True iff `year` has 53 ISO weeks (a "long" ISO year): years whose
/// January 1 falls on a Thursday, or leap years whose January 1 falls on
/// a Wednesday. Standard ISO 8601 week-numbering rule.
fn isLongIsoYear(year: i32) bool {
    const dow_jan1 = dayOfWeek(year, 1, 1);
    if (dow_jan1 == 4) return true; // Thursday
    if (dow_jan1 == 3 and isLeapYear(year)) return true; // Wednesday + leap
    return false;
}

pub const WeekOfYear = struct { week: u8, year: i32 };

/// ISO 8601 week number + week-numbering year (which can differ from the
/// calendar year at year boundaries -- e.g. 2024-12-31 is ISO week 1 of
/// 2025; 2023-01-01 is ISO week 52 of 2022). Standard algorithm: week =
/// floor((dayOfYear - dayOfWeek + 10) / 7), then redirect into the
/// adjacent year if the result falls outside [1, weeksInYear(year)].
pub fn weekOfYear(year: i32, month: u8, day: u8) WeekOfYear {
    const doy: i32 = dayOfYear(year, month, day);
    const dow: i32 = dayOfWeek(year, month, day);
    const week = @divFloor(doy - dow + 10, 7);
    if (week < 1) {
        return .{ .week = if (isLongIsoYear(year - 1)) 53 else 52, .year = year - 1 };
    }
    if (week > 52 and !isLongIsoYear(year)) {
        return .{ .week = 1, .year = year + 1 };
    }
    return .{ .week = @intCast(week), .year = year };
}

/// `MnnCode` per Temporal's `monthCode` getter -- ISO calendar never has a
/// leap month, so this is always `"M" ++ 2-digit month`, no `"L"` suffix.
pub fn monthCodeBuf(buf: *[3]u8, month: u8) []const u8 {
    buf[0] = 'M';
    buf[1] = '0' + @divTrunc(month, 10);
    buf[2] = '0' + @mod(month, 10);
    return buf[0..3];
}

const MIN_EPOCH_DAY: i64 = toEpochDay(MIN_ISO_YEAR, 4, 19);
const MAX_EPOCH_DAY: i64 = toEpochDay(MAX_ISO_YEAR, 9, 13);

/// Whether `year-month-day` (already field-range-validated) falls inside
/// Temporal's representable ISO date range.
pub fn isInRange(year: i32, month: u8, day: u8) bool {
    const ed = toEpochDay(year, month, day);
    return ed >= MIN_EPOCH_DAY and ed <= MAX_EPOCH_DAY;
}

test "isLeapYear matches Gregorian rule" {
    try std.testing.expect(isLeapYear(2024));
    try std.testing.expect(!isLeapYear(2023));
    try std.testing.expect(!isLeapYear(1900));
    try std.testing.expect(isLeapYear(2000));
    try std.testing.expect(isLeapYear(0));
    try std.testing.expect(isLeapYear(-4));
}

test "toEpochDay / fromEpochDay round-trip" {
    const cases = [_]YearMonthDay{
        .{ .year = 1970, .month = 1, .day = 1 },
        .{ .year = 2024, .month = 2, .day = 29 },
        .{ .year = 1969, .month = 12, .day = 31 },
        .{ .year = 0, .month = 1, .day = 1 },
        .{ .year = -1, .month = 12, .day = 31 },
        .{ .year = 275760, .month = 9, .day = 13 },
        .{ .year = -271821, .month = 4, .day = 19 },
    };
    for (cases) |c| {
        const ed = toEpochDay(c.year, c.month, c.day);
        const back = fromEpochDay(ed);
        try std.testing.expectEqual(c.year, back.year);
        try std.testing.expectEqual(c.month, back.month);
        try std.testing.expectEqual(c.day, back.day);
    }
    try std.testing.expectEqual(@as(i64, 0), toEpochDay(1970, 1, 1));
}

test "dayOfWeek matches real Node (Temporal 1=Monday..7=Sunday)" {
    try std.testing.expectEqual(@as(u8, 1), dayOfWeek(2024, 1, 1)); // Monday
    try std.testing.expectEqual(@as(u8, 2), dayOfWeek(2024, 12, 31)); // Tuesday
    try std.testing.expectEqual(@as(u8, 7), dayOfWeek(2023, 1, 1)); // Sunday
    try std.testing.expectEqual(@as(u8, 5), dayOfWeek(2021, 1, 1)); // Friday
    try std.testing.expectEqual(@as(u8, 4), dayOfWeek(1970, 1, 1)); // Thursday
}

test "weekOfYear/yearOfWeek matches real Node boundary cases" {
    const c1 = weekOfYear(2024, 1, 1);
    try std.testing.expectEqual(WeekOfYear{ .week = 1, .year = 2024 }, c1);
    const c2 = weekOfYear(2024, 12, 31);
    try std.testing.expectEqual(WeekOfYear{ .week = 1, .year = 2025 }, c2);
    const c3 = weekOfYear(2023, 1, 1);
    try std.testing.expectEqual(WeekOfYear{ .week = 52, .year = 2022 }, c3);
    const c4 = weekOfYear(2021, 1, 1);
    try std.testing.expectEqual(WeekOfYear{ .week = 53, .year = 2020 }, c4);
}

test "dayOfYear" {
    try std.testing.expectEqual(@as(u16, 1), dayOfYear(2024, 1, 1));
    try std.testing.expectEqual(@as(u16, 366), dayOfYear(2024, 12, 31));
    try std.testing.expectEqual(@as(u16, 365), dayOfYear(2023, 12, 31));
}

test "isInRange matches real Node's exact ISO date boundaries" {
    try std.testing.expect(isInRange(275760, 9, 13));
    try std.testing.expect(!isInRange(275760, 9, 14));
    try std.testing.expect(isInRange(-271821, 4, 19));
    try std.testing.expect(!isInRange(-271821, 4, 18));
}
