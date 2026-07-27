//! Shared rounding-mode framework for `until`/`since` (Phase 3b) and, later,
//! `.round()`/`Duration.round()`/`.total()` (Phase 3c). `Unit` covers all 10
//! Temporal units; `RoundingMode` covers all 9 real Temporal rounding modes.
//! `roundRatioToIncrement` is the one generic integer-only (no floats)
//! rational-rounding primitive every caller in this phase funnels through,
//! for both fixed-radix time units and variable-length calendar units alike
//! (calendar callers just pass a different denominator per case).
const std = @import("std");
const errors = @import("errors.zig");
const TemporalError = errors.TemporalError;

/// Declaration order doubles as rank (coarsest first) for `@intFromEnum`
/// comparisons -- `year` is rank 0, `nanosecond` is rank 9.
pub const Unit = enum { year, month, week, day, hour, minute, second, millisecond, microsecond, nanosecond };

pub const RoundingMode = enum { ceil, floor, trunc, expand, half_ceil, half_floor, half_trunc, half_expand, half_even };

pub const RoundingOptions = struct {
    largest_unit: ?Unit = null,
    smallest_unit: ?Unit = null,
    rounding_increment: u32 = 1,
    rounding_mode: RoundingMode = .trunc,
};

pub fn isDateUnit(unit: Unit) bool {
    return @intFromEnum(unit) <= @intFromEnum(Unit.day);
}

pub fn isTimeUnit(unit: Unit) bool {
    return @intFromEnum(unit) >= @intFromEnum(Unit.hour);
}

/// `null` for year/month/week/day -- ground-truthed against real Node to
/// have no divisibility/maximum cap on `roundingIncrement` at all (unlike
/// every time unit below `day`, which requires the increment to evenly
/// divide the cycle length below and be strictly less than it: hour's
/// cycle is 24, minute/second's is 60, ms/us/ns's is 1000).
fn cycleLength(unit: Unit) ?u32 {
    return switch (unit) {
        .hour => 24,
        .minute, .second => 60,
        .millisecond, .microsecond, .nanosecond => 1000,
        .year, .month, .week, .day => null,
    };
}

pub fn validateIncrement(unit: Unit, increment: u32) TemporalError!void {
    if (increment < 1) return error.InvalidRange;
    if (cycleLength(unit)) |cycle| {
        if (increment >= cycle) return error.InvalidRange;
        if (cycle % increment != 0) return error.InvalidRange;
    }
}

pub const ResolvedUnits = struct { largest: Unit, smallest: Unit };

fn resolveUnits(options: RoundingOptions, default_largest: Unit, default_smallest: Unit, comptime allowed: fn (Unit) bool) TemporalError!ResolvedUnits {
    const largest = options.largest_unit orelse default_largest;
    const smallest = options.smallest_unit orelse default_smallest;
    if (!allowed(largest) or !allowed(smallest)) return error.InvalidRange;
    if (@intFromEnum(largest) > @intFromEnum(smallest)) return error.InvalidRange;
    try validateIncrement(smallest, options.rounding_increment);
    return .{ .largest = largest, .smallest = smallest };
}

/// `PlainDate`: date units only (year..day), default largestUnit "day",
/// default smallestUnit "day" (finest available -- no rounding unless
/// asked).
pub fn resolveDateUnits(options: RoundingOptions) TemporalError!ResolvedUnits {
    return resolveUnits(options, .day, .day, isDateUnit);
}

/// `PlainTime`: time units only (hour..nanosecond), default largestUnit
/// "hour", default smallestUnit "nanosecond".
pub fn resolveTimeUnits(options: RoundingOptions) TemporalError!ResolvedUnits {
    return resolveUnits(options, .hour, .nanosecond, isTimeUnit);
}

/// `PlainDateTime`: any of the 10 units, default largestUnit "day",
/// default smallestUnit "nanosecond".
pub fn resolveDateTimeUnits(options: RoundingOptions) TemporalError!ResolvedUnits {
    return resolveUnits(options, .day, .nanosecond, struct {
        fn f(_: Unit) bool {
            return true;
        }
    }.f);
}

/// Rounds `numerator/denominator` (`denominator > 0`) to the nearest
/// multiple of `increment`, per `mode`, returning that multiple (same
/// scale as `numerator/denominator`, e.g. hours or months -- NOT divided
/// by `increment`). Integer-only: `q`/`r` come from a floor-division of
/// `numerator` by `denominator*increment`, so `r` is always in
/// `[0, denominator*increment)` regardless of `numerator`'s sign; every
/// mode is then a small adjustment to `q` based on `r`'s position (or, for
/// the half-* modes, `2*r` against the halfway point) -- ground-truthed
/// against real Node's `Temporal` at an exact tie (12h of a 24h day) in
/// both directions for all 9 modes before trusting this derivation.
pub fn roundRatioToIncrement(numerator: i128, denominator: i128, increment: i128, mode: RoundingMode) i128 {
    const combined_denom = denominator * increment;
    var q = @divFloor(numerator, combined_denom);
    const r = numerator - q * combined_denom;
    const is_negative = numerator < 0;
    const twice_r = r * 2;

    switch (mode) {
        .floor => {},
        .ceil => {
            if (r > 0) q += 1;
        },
        .trunc => {
            if (is_negative and r > 0) q += 1;
        },
        .expand => {
            if (!is_negative and r > 0) q += 1;
        },
        .half_floor => {
            if (twice_r > combined_denom) q += 1;
        },
        .half_ceil => {
            if (twice_r >= combined_denom and r > 0) q += 1;
        },
        .half_trunc => {
            if (is_negative) {
                if (twice_r >= combined_denom and r > 0) q += 1;
            } else {
                if (twice_r > combined_denom) q += 1;
            }
        },
        .half_expand => {
            if (!is_negative) {
                if (twice_r >= combined_denom and r > 0) q += 1;
            } else {
                if (twice_r > combined_denom) q += 1;
            }
        },
        .half_even => {
            if (twice_r > combined_denom) {
                q += 1;
            } else if (twice_r == combined_denom and @mod(q, 2) != 0) {
                q += 1;
            }
        },
    }
    return q * increment;
}

test "roundRatioToIncrement: exact 12h/24h tie, all 9 modes, both directions" {
    // Mirrors the ground-truthed Node table: `until` sees +12h (raw
    // numerator positive), `since` sees -12h (negated).
    const denom: i128 = 24;
    const cases = [_]struct { mode: RoundingMode, until_q: i128, since_q: i128 }{
        .{ .mode = .ceil, .until_q = 1, .since_q = 0 },
        .{ .mode = .floor, .until_q = 0, .since_q = -1 },
        .{ .mode = .trunc, .until_q = 0, .since_q = 0 },
        .{ .mode = .expand, .until_q = 1, .since_q = -1 },
        .{ .mode = .half_ceil, .until_q = 1, .since_q = 0 },
        .{ .mode = .half_floor, .until_q = 0, .since_q = -1 },
        .{ .mode = .half_trunc, .until_q = 0, .since_q = 0 },
        .{ .mode = .half_expand, .until_q = 1, .since_q = -1 },
        .{ .mode = .half_even, .until_q = 0, .since_q = 0 },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.until_q, roundRatioToIncrement(12, denom, 1, c.mode));
        try std.testing.expectEqual(c.since_q, roundRatioToIncrement(-12, denom, 1, c.mode));
    }
}

test "roundRatioToIncrement: non-tie values round to nearest regardless of mode" {
    // 15/24 ~ 0.625, unambiguously nearer to 1 than 0.
    inline for (.{ RoundingMode.half_ceil, .half_floor, .half_trunc, .half_expand, .half_even }) |mode| {
        try std.testing.expectEqual(@as(i128, 1), roundRatioToIncrement(15, 24, 1, mode));
    }
}

test "roundRatioToIncrement: increment grouping" {
    // 44/29 with increment 1 in months ~ 1.517 -> halfExpand rounds to 2;
    // ground-truthed against the `since halfExpand -> P2M` Node case.
    try std.testing.expectEqual(@as(i128, 2), roundRatioToIncrement(44, 29, 1, .half_expand));
    try std.testing.expectEqual(@as(i128, -2), roundRatioToIncrement(-44, 29, 1, .half_expand));
}

test "validateIncrement: time units capped+divisible, calendar units uncapped" {
    try validateIncrement(.hour, 12);
    try std.testing.expectError(error.InvalidRange, validateIncrement(.hour, 24));
    try std.testing.expectError(error.InvalidRange, validateIncrement(.hour, 23));
    try validateIncrement(.month, 5);
    try validateIncrement(.week, 3);
    try validateIncrement(.day, 999_999_999);
}

test "resolveDateUnits: defaults, unit-group rejection, largest<smallest rejection" {
    const r = try resolveDateUnits(.{});
    try std.testing.expectEqual(Unit.day, r.largest);
    try std.testing.expectEqual(Unit.day, r.smallest);
    try std.testing.expectError(error.InvalidRange, resolveDateUnits(.{ .largest_unit = .hour }));
    try std.testing.expectError(error.InvalidRange, resolveDateUnits(.{ .largest_unit = .month, .smallest_unit = .year }));
}
