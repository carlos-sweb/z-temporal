//! TC39 relative-duration rounding on exact epoch nanoseconds.
const std = @import("std");
const E = @import("errors.zig").TemporalError;
const cal = @import("iso_calendar.zig");
const date = @import("plain_date.zig");
const PDT = @import("plain_date_time.zig").PlainDateTime;
const PT = @import("plain_time.zig");
const D = @import("duration.zig").Duration;
const num = @import("duration.zig").integer;
const r = @import("rounding.zig");
const day_ns = 86_400_000_000_000;
pub const Context = struct { allocator: std.mem.Allocator = std.heap.page_allocator, io: ?std.Io = null, zone: ?[]const u8 = null };
pub fn epoch(dt: PDT, ctx: Context) E!i128 {
    if (ctx.zone) |zone| {
        const z = try @import("zoned_date_time.zig").resolveFields(ctx.allocator, ctx.io.?, dt.date.iso_year, dt.date.iso_month, dt.date.iso_day, dt.time.hour, dt.time.minute, dt.time.second, dt.time.millisecond, dt.time.microsecond, dt.time.nanosecond, zone, .constrain, .compatible);
        return z.epochNs;
    }
    return @as(i128, cal.toEpochDay(dt.date.iso_year, dt.date.iso_month, dt.date.iso_day)) * day_ns + dt.time.totalNanoseconds();
}
fn at(start: PDT, d: D, ctx: Context) E!i128 {
    return epoch(.{ .date = try start.date.add(d, .constrain), .time = start.time }, ctx);
}
fn dateOnly(d: D) D {
    return .{ .years = d.years, .months = d.months, .weeks = d.weeks, .days = d.days };
}
pub fn rawDifference(start: PDT, end: PDT, origin: i128, target: i128, largest: r.Unit, ctx: Context) E!D {
    if (r.isTimeUnit(largest)) return PT.decomposeTimeDiff(target - origin, .{ .largest = largest, .smallest = .nanosecond }, 1, .trunc);
    if (ctx.zone != null and date.PlainDate.compare(start.date, end.date) == .eq) return PT.decomposeTimeDiff(target - origin, .{ .largest = .hour, .smallest = .nanosecond }, 1, .trunc);
    const sign: i64 = if (target < origin) -1 else 1;
    var end_day = cal.toEpochDay(end.date.iso_year, end.date.iso_month, end.date.iso_day);
    var remaining: i128 = 0;
    var adjustment: usize = 0;
    while (true) : (adjustment += 1) {
        const ymd = cal.fromEpochDay(end_day);
        const intermediate: PDT = .{ .date = .{ .iso_year = ymd.year, .iso_month = ymd.month, .iso_day = ymd.day, .calendar = start.date.calendar }, .time = start.time };
        remaining = target - try epoch(intermediate, ctx);
        if (remaining == 0 or (remaining > 0) == (sign > 0)) break;
        if (adjustment >= 2) return error.RangeError;
        end_day -= sign;
    }
    const end_date = cal.fromEpochDay(end_day);
    const raw = if (start.date.calendar == .iso8601) try date.diffISODate(start.date.asYMD(), end_date, largest) else try @import("calendar.zig").difference(start.date.calendar, start.date.asYMD(), end_date, largest);
    const time = try PT.decomposeTimeDiff(remaining, .{ .largest = .hour, .smallest = .nanosecond }, 1, .trunc);
    return D.init(raw.years, raw.months, raw.weeks, raw.days, time.hours, time.minutes, time.seconds, time.milliseconds, time.microseconds, time.nanoseconds);
}
const Window = struct { low: D, high: D, lowEpoch: i128, highEpoch: i128, rank: i128 };
fn window(start: PDT, origin: i128, raw: D, sign: i128, unit: r.Unit, increment: u32, shift: bool, ctx: Context) E!Window {
    var low: D = .{};
    var value: i128 = 0;
    switch (unit) {
        .year => value = num(raw.years),
        .month => {
            low.years = raw.years;
            value = num(raw.months);
        },
        .week => {
            low.years = raw.years;
            low.months = raw.months;
            value = num(raw.weeks) + @divTrunc(num(raw.days), 7);
        },
        .day => {
            low = dateOnly(raw);
            value = num(raw.days);
            low.days = 0;
        },
        else => unreachable,
    }
    value = @divTrunc(value, increment) * increment;
    if (shift) value += sign * increment;
    var high = low;
    switch (unit) {
        .year => {
            low.years = @floatFromInt(value);
            high.years = @floatFromInt(value + sign * increment);
        },
        .month => {
            low.months = @floatFromInt(value);
            high.months = @floatFromInt(value + sign * increment);
        },
        .week => {
            low.weeks = @floatFromInt(value);
            high.weeks = @floatFromInt(value + sign * increment);
        },
        .day => {
            low.days = @floatFromInt(value);
            high.days = @floatFromInt(value + sign * increment);
        },
        else => unreachable,
    }
    return .{ .low = low, .high = high, .lowEpoch = if (value == 0) origin else try at(start, low, ctx), .highEpoch = try at(start, high, ctx), .rank = value };
}
pub fn total(start: PDT, end: PDT, origin: i128, target: i128, unit: r.Unit, ctx: Context) E!f64 {
    if (origin == target) return 0;
    if (r.isTimeUnit(unit)) return @floatCast(@as(f128, @floatFromInt(target - origin)) / @as(f128, @floatFromInt(PT.nsPerUnit(unit))));
    if (ctx.zone == null and (unit == .day or unit == .week)) return @floatCast(@as(f128, @floatFromInt(target - origin)) / @as(f128, @floatFromInt(if (unit == .week) 7 * @as(i128, day_ns) else @as(i128, day_ns))));
    const raw = try rawDifference(start, end, origin, target, unit, ctx);
    const sign: i128 = if (target < origin) -1 else 1;
    var w = try window(start, origin, raw, sign, unit, 1, false, ctx);
    if (target < @min(w.lowEpoch, w.highEpoch) or target > @max(w.lowEpoch, w.highEpoch)) w = try window(start, origin, raw, sign, unit, 1, true, ctx);
    const denominator = w.highEpoch - w.lowEpoch;
    const numerator = w.rank * denominator + (target - w.lowEpoch) * sign;
    return @floatCast(@as(f128, @floatFromInt(numerator)) / @as(f128, @floatFromInt(denominator)));
}
pub fn difference(start: PDT, end: PDT, origin: i128, target: i128, options: r.RoundingOptions, ctx: Context) E!D {
    const units = try r.resolveDateTimeUnits(options);
    if (origin == target) return .{};
    var raw = try rawDifference(start, end, origin, target, units.largest, ctx);
    const sign: i128 = if (target < origin) -1 else 1;
    const smallest = units.smallest;
    var nudged = target;
    var expanded = false;
    if (smallest == .year or smallest == .month or smallest == .week or (smallest == .day and ctx.zone != null)) {
        var w = try window(start, origin, raw, sign, smallest, options.roundingIncrement, false, ctx);
        if (target < @min(w.lowEpoch, w.highEpoch) or target > @max(w.lowEpoch, w.highEpoch)) w = try window(start, origin, raw, sign, smallest, options.roundingIncrement, true, ctx);
        const width: i128 = @intCast(@abs(w.highEpoch - w.lowEpoch));
        const progress = @as(i128, @intCast(@abs(target - w.lowEpoch)));
        const candidate = w.rank * width + sign * progress * options.roundingIncrement;
        const rounded = r.roundRatioToIncrement(candidate, width, options.roundingIncrement, options.roundingMode);
        expanded = rounded != w.rank;
        raw = if (expanded) w.high else w.low;
        nudged = if (expanded) w.highEpoch else w.lowEpoch;
    } else {
        var base = dateOnly(raw);
        base.days = 0;
        const baseEpoch = if (base.blank()) origin else try at(start, base, ctx);
        var remainder = target - baseEpoch;
        const quantum = if (smallest == .day) day_ns else PT.nsPerUnit(smallest);
        remainder = r.roundRatioToIncrement(remainder, quantum, options.roundingIncrement, options.roundingMode) * quantum;
        nudged = baseEpoch + remainder;
        expanded = (nudged - target) * sign > 0;
        if (r.isTimeUnit(units.largest)) return PT.decomposeTimeDiff(remainder, .{ .largest = units.largest, .smallest = .nanosecond }, 1, .trunc);
        if (ctx.zone != null) {
            var days = num(raw.days);
            var mid = base;
            mid.days = @floatFromInt(days);
            var midEpoch = if (mid.blank()) origin else try at(start, mid, ctx);
            while ((nudged - midEpoch) * sign < 0) {
                days -= sign;
                mid.days = @floatFromInt(days);
                midEpoch = try at(start, mid, ctx);
            }
            var next = mid;
            next.days = @floatFromInt(days + sign);
            var nextEpoch = try at(start, next, ctx);
            while ((nudged - nextEpoch) * sign >= 0) {
                days += sign;
                midEpoch = nextEpoch;
                next.days = @floatFromInt(days + sign);
                nextEpoch = try at(start, next, ctx);
            }
            base.days = @floatFromInt(days);
            remainder = nudged - midEpoch;
        } else {
            base.days = @floatFromInt(@divTrunc(remainder, day_ns));
            remainder = @rem(remainder, day_ns);
        }
        const time = try PT.decomposeTimeDiff(remainder, .{ .largest = .hour, .smallest = .nanosecond }, 1, .trunc);
        raw = try D.init(base.years, base.months, base.weeks, base.days, time.hours, time.minutes, time.seconds, time.milliseconds, time.microseconds, time.nanoseconds);
    }
    if (expanded and smallest != .week) {
        var rank: i32 = @intCast(@backingInt(if (r.isTimeUnit(smallest)) r.Unit.day else smallest));
        while (rank > @backingInt(units.largest)) {
            rank -= 1;
            const unit: r.Unit = @fromBackingInt(@as(u4, @intCast(rank)));
            if (unit == .week and units.largest != .week) continue;
            var next = dateOnly(raw);
            switch (unit) {
                .year => {
                    next.years += @as(f64, @floatFromInt(sign));
                    next.months = 0;
                    next.weeks = 0;
                    next.days = 0;
                },
                .month => {
                    next.months += @as(f64, @floatFromInt(sign));
                    next.weeks = 0;
                    next.days = 0;
                },
                .week => {
                    next.weeks += @as(f64, @floatFromInt(sign));
                    next.days = 0;
                },
                else => continue,
            }
            if ((nudged - try at(start, next, ctx)) * sign >= 0) raw = next else break;
        }
    }
    return raw;
}
pub fn negateMode(mode: r.RoundingMode) r.RoundingMode {
    return switch (mode) {
        .ceil => .floor,
        .floor => .ceil,
        .halfCeil => .halfFloor,
        .halfFloor => .halfCeil,
        else => mode,
    };
}
