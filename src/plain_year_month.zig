//! `Temporal.PlainYearMonth`, ISO calendar only (Phase 4). Ground-truthed
//! against real Node: internally always uses day = 1 as the reference day
//! for every operation, regardless of what day (if any) was supplied to
//! `.from()` -- so `add`/`subtract`/`until`/`since`/`toPlainDate` are all
//! thin delegations to `PlainDate{year,month,1}`'s own already-built
//! machinery (Phase 3a/3b), not new algorithms.
const std = @import("std");
const iso_calendar = @import("iso_calendar.zig");
const iso_string = @import("iso_string.zig");
const errors = @import("errors.zig");
const TemporalError = errors.TemporalError;
const plain_date_mod = @import("plain_date.zig");
const PlainDate = plain_date_mod.PlainDate;
const Overflow = plain_date_mod.Overflow;
const duration_mod = @import("duration.zig");
const Duration = duration_mod.Duration;
const rounding = @import("rounding.zig");
const Unit = rounding.Unit;
const RoundingOptions = rounding.RoundingOptions;

fn isYearOrMonthUnit(unit: Unit) bool {
    return unit == .year or unit == .month;
}

pub const PlainYearMonth = struct {
    iso_year: i32,
    iso_month: u8, // 1-12

    /// Real spec: month must be a positive integer unconditionally (lower
    /// bound always rejects, matching `PlainDate.create`'s own month
    /// rule); only the upper bound (month > 12) respects `overflow`.
    /// Range validity is NOT simply "day 1 of this year-month is in
    /// range" -- ground-truthed at both boundaries (`-271821-04` is valid
    /// even though its day 1 precedes the real min date `-271821-04-19`,
    /// because the month's LAST day doesn't; `-271821-03` is invalid
    /// since neither day 1 nor its last day reaches the min) -- so the
    /// check is "day 1 OR the month's last day falls in range".
    pub fn create(in_year: i32, in_month: i32, overflow: Overflow) TemporalError!PlainYearMonth {
        if (in_month < 1) return error.InvalidRange;
        var m: u8 = undefined;
        if (in_month > 12) {
            if (overflow == .reject) return error.InvalidRange;
            m = 12;
        } else {
            m = @intCast(in_month);
        }
        const last_day = iso_calendar.daysInMonth(in_year, m);
        if (!iso_calendar.isInRange(in_year, m, 1) and !iso_calendar.isInRange(in_year, m, last_day)) return error.InvalidRange;
        return .{ .iso_year = in_year, .iso_month = m };
    }

    pub fn parseIso(text: []const u8) TemporalError!PlainYearMonth {
        const parsed = try iso_string.parsePlainYearMonth(text);
        return create(parsed.year, parsed.month, .reject);
    }

    pub fn withFields(self: PlainYearMonth, in_year: ?i32, in_month: ?i32, overflow: Overflow) TemporalError!PlainYearMonth {
        return create(in_year orelse self.iso_year, in_month orelse self.iso_month, overflow);
    }

    fn asPlainDate(self: PlainYearMonth) PlainDate {
        return .{ .iso_year = self.iso_year, .iso_month = self.iso_month, .iso_day = 1 };
    }

    /// Always constrains the day regardless of `overflow` -- ground-truthed
    /// against real Node (`day:35` on a 29-day February clamps to 29 even
    /// with `overflow:"reject"` explicitly passed).
    pub fn toPlainDate(self: PlainYearMonth, day: i32) TemporalError!PlainDate {
        return PlainDate.create(self.iso_year, self.iso_month, day, .constrain);
    }

    pub fn add(self: PlainYearMonth, d: Duration, overflow: Overflow) TemporalError!PlainYearMonth {
        const result = try self.asPlainDate().add(d, overflow);
        return .{ .iso_year = result.iso_year, .iso_month = result.iso_month };
    }

    pub fn subtract(self: PlainYearMonth, d: Duration, overflow: Overflow) TemporalError!PlainYearMonth {
        return self.add(d.negated(), overflow);
    }

    /// Delegates to `PlainDate.until`/`.since`, restricted to
    /// `largestUnit`/`smallestUnit` of `.year`/`.month` only --
    /// ground-truthed that real Temporal rejects week/day here
    /// ("Weeks and days are not allowed in this operation").
    pub fn until(self: PlainYearMonth, other: PlainYearMonth, options: RoundingOptions) TemporalError!Duration {
        const largest = options.largest_unit orelse .year;
        const smallest = options.smallest_unit orelse .month;
        if (!isYearOrMonthUnit(largest) or !isYearOrMonthUnit(smallest)) return error.InvalidRange;
        return self.asPlainDate().until(other.asPlainDate(), .{
            .largest_unit = largest,
            .smallest_unit = smallest,
            .rounding_increment = options.rounding_increment,
            .rounding_mode = options.rounding_mode,
        });
    }

    pub fn since(self: PlainYearMonth, other: PlainYearMonth, options: RoundingOptions) TemporalError!Duration {
        const largest = options.largest_unit orelse .year;
        const smallest = options.smallest_unit orelse .month;
        if (!isYearOrMonthUnit(largest) or !isYearOrMonthUnit(smallest)) return error.InvalidRange;
        return self.asPlainDate().since(other.asPlainDate(), .{
            .largest_unit = largest,
            .smallest_unit = smallest,
            .rounding_increment = options.rounding_increment,
            .rounding_mode = options.rounding_mode,
        });
    }

    pub fn compare(a: PlainYearMonth, b: PlainYearMonth) std.math.Order {
        return PlainDate.compare(a.asPlainDate(), b.asPlainDate());
    }

    pub fn equals(a: PlainYearMonth, b: PlainYearMonth) bool {
        return a.iso_year == b.iso_year and a.iso_month == b.iso_month;
    }

    pub fn year(self: PlainYearMonth) i32 {
        return self.iso_year;
    }
    pub fn month(self: PlainYearMonth) u8 {
        return self.iso_month;
    }
    pub fn monthCode(self: PlainYearMonth, buf: *[3]u8) []const u8 {
        return iso_calendar.monthCodeBuf(buf, self.iso_month);
    }
    pub fn calendarId(self: PlainYearMonth) []const u8 {
        _ = self;
        return "iso8601";
    }
    pub fn daysInMonth(self: PlainYearMonth) u8 {
        return iso_calendar.daysInMonth(self.iso_year, self.iso_month);
    }
    pub fn daysInYear(self: PlainYearMonth) u16 {
        return iso_calendar.daysInYear(self.iso_year);
    }
    pub fn monthsInYear(self: PlainYearMonth) u8 {
        _ = self;
        return 12;
    }
    pub fn inLeapYear(self: PlainYearMonth) bool {
        return iso_calendar.isLeapYear(self.iso_year);
    }

    /// `YYYY-MM` (or the extended `±YYYYYY-MM` form outside [0,9999]),
    /// optionally suffixed with `[u-ca=iso8601]`.
    pub fn toIsoString(self: PlainYearMonth, allocator: std.mem.Allocator, show_calendar: bool) ![]u8 {
        var year_buf: [8]u8 = undefined;
        const year_str = iso_string.formatYear(&year_buf, self.iso_year);
        if (show_calendar) {
            return std.fmt.allocPrint(allocator, "{s}-{d:0>2}[u-ca=iso8601]", .{ year_str, self.iso_month });
        }
        return std.fmt.allocPrint(allocator, "{s}-{d:0>2}", .{ year_str, self.iso_month });
    }
};

test "create: constrain clamps upper bound, reject throws" {
    const constrained = try PlainYearMonth.create(2024, 13, .constrain);
    try std.testing.expectEqual(@as(u8, 12), constrained.iso_month);
    try std.testing.expectError(error.InvalidRange, PlainYearMonth.create(2024, 13, .reject));
}

test "create: month below 1 always rejects, regardless of overflow" {
    try std.testing.expectError(error.InvalidRange, PlainYearMonth.create(2024, 0, .constrain));
}

test "create: asymmetric range boundary (day1-or-last-day rule)" {
    _ = try PlainYearMonth.create(275760, 9, .reject);
    try std.testing.expectError(error.InvalidRange, PlainYearMonth.create(275760, 10, .reject));
    _ = try PlainYearMonth.create(-271821, 4, .reject);
    try std.testing.expectError(error.InvalidRange, PlainYearMonth.create(-271821, 3, .reject));
}

test "toPlainDate always constrains regardless of day validity" {
    const ym = try PlainYearMonth.create(2024, 2, .reject);
    const d = try ym.toPlainDate(35);
    try std.testing.expectEqual(@as(u8, 29), d.iso_day);
}

test "add: delegates to PlainDate{year,month,1}, day-31 vs day-1 construction identical" {
    const ym = try PlainYearMonth.create(2024, 1, .reject);
    const r1 = try ym.add(try Duration.create(0, 0, 0, 35, 0, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(u8, 2), r1.iso_month);
    const r2 = try ym.add(try Duration.create(0, 0, 0, 400, 0, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(i32, 2025), r2.iso_year);
    try std.testing.expectEqual(@as(u8, 2), r2.iso_month);
}

test "until/since: rejects week/day units, default largestUnit is year" {
    const a = try PlainYearMonth.create(2024, 1, .reject);
    const b = try PlainYearMonth.create(2025, 6, .reject);
    const allocator = std.testing.allocator;
    const d = try a.until(b, .{});
    const s = try d.toIsoString(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("P1Y5M", s);
    try std.testing.expectError(error.InvalidRange, a.until(b, .{ .smallest_unit = .day }));
    try std.testing.expectError(error.InvalidRange, a.until(b, .{ .smallest_unit = .week }));
}

test "toIsoString matches real Node byte-for-byte" {
    const allocator = std.testing.allocator;
    {
        const ym = try PlainYearMonth.create(2024, 2, .reject);
        const s = try ym.toIsoString(allocator, false);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("2024-02", s);
    }
    {
        const ym = try PlainYearMonth.create(-1, 1, .reject);
        const s = try ym.toIsoString(allocator, false);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("-000001-01", s);
    }
}

test "parseIso: bare YYYY-MM and full date string both parse, calendar validated" {
    const ym = try PlainYearMonth.parseIso("2024-02");
    try std.testing.expectEqual(@as(u8, 2), ym.iso_month);
    const ym2 = try PlainYearMonth.parseIso("2024-02-15T10:00:00");
    try std.testing.expectEqual(@as(i32, 2024), ym2.iso_year);
    try std.testing.expectEqual(@as(u8, 2), ym2.iso_month);
    try std.testing.expectError(error.InvalidFormat, PlainYearMonth.parseIso("2024-02[u-ca=hebrew]"));
}
