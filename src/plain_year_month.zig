//! Temporal.PlainYearMonth: preserves constructor reference dates; from normalizes them.
const calendars = @import("calendar.zig");
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

pub fn regulate(in_year: i32, in_month: i32, overflow: Overflow) TemporalError!PlainYearMonth {
    if (in_month < 1) return error.RangeError;
    var m: u8 = undefined;
    if (in_month > 12) {
        if (overflow == .reject) return error.RangeError;
        m = 12;
    } else {
        m = @intCast(in_month);
    }
    const last_day = iso_calendar.daysInMonth(in_year, m);
    if (!iso_calendar.isInRange(in_year, m, 1) and !iso_calendar.isInRange(in_year, m, last_day)) return error.RangeError;
    return .{ .iso_year = in_year, .iso_month = m };
}

pub const PlainYearMonth = struct {
    calendar: calendars.Id = .iso8601,
    calendarData: ?calendars.Info = null,
    iso_year: i32,
    iso_month: u8, // 1-12
    reference_day: u8 = 1,

    /// Real spec: month must be a positive integer unconditionally (lower
    /// bound always rejects, matching `PlainDate.init`'s own month
    /// rule); only the upper bound (month > 12) respects `overflow`.
    /// Range validity is NOT simply "day 1 of this year-month is in
    /// range" -- ground-truthed at both boundaries (`-271821-04` is valid
    /// even though its day 1 precedes the real min date `-271821-04-19`,
    /// because the month's LAST day doesn't; `-271821-03` is invalid
    /// since neither day 1 nor its last day reaches the min) -- so the
    /// check is "day 1 OR the month's last day falls in range".
    pub fn init(in_year: i32, in_month: i32, calendarIdValue: ?[]const u8, referenceISODay: ?i32) TemporalError!PlainYearMonth {
        var result = try regulate(in_year, in_month, .reject);
        const day = referenceISODay orelse 1;
        if (day < 1 or day > iso_calendar.daysInMonth(in_year, result.iso_month)) return error.RangeError;
        result.reference_day = @intCast(day);
        const id = try calendars.parse(calendarIdValue orelse "iso8601");
        if (id == .iso8601) return result;
        const date: PlainDate = .{ .iso_year = in_year, .iso_month = result.iso_month, .iso_day = @intCast(day) };
        return fromDate(try date.withCalendar(@tagName(id)));
    }

    fn fromDate(value: PlainDate) PlainYearMonth {
        return .{ .iso_month = value.iso_month, .iso_year = value.iso_year, .reference_day = value.iso_day, .calendar = value.calendar, .calendarData = value.calendarData };
    }
    fn asCalendarDate(self: PlainYearMonth) PlainDate {
        return .{ .iso_year = self.iso_year, .iso_month = self.iso_month, .iso_day = self.reference_day, .calendar = self.calendar, .calendarData = self.calendarData };
    }
    pub const Fields = struct {
        era: ?[]const u8 = null,
        eraYear: ?i32 = null,
        calendar: ?[]const u8 = null,
        monthCode: ?[]const u8 = null,
        year: ?i32 = null,
        month: ?i32 = null,
    };
    pub const FromInput = union(enum) { string: []const u8, value: PlainYearMonth, fields: Fields };
    pub const FromOptions = struct { overflow: Overflow = .constrain };
    pub fn from(input: FromInput, options: FromOptions) TemporalError!PlainYearMonth {
        return switch (input) {
            .string => |text| fromString(text),
            .value => |value| value,
            .fields => |f| blk: {
                const id = try calendars.parse(f.calendar orelse "iso8601");
                if (id == .iso8601) break :blk regulate(f.year orelse return error.TypeError, try calendars.isoMonth(f.monthCode, f.month), options.overflow);
                break :blk fromDate(try PlainDate.from(.{ .fields = .{ .year = f.year, .era = f.era, .eraYear = f.eraYear, .month = f.month, .monthCode = f.monthCode, .day = 1, .calendar = f.calendar } }, .{ .overflow = options.overflow }));
            },
        };
    }
    fn fromString(text: []const u8) TemporalError!PlainYearMonth {
        const id = try calendars.fromString(text);
        const parsed = try iso_string.parsePlainYearMonth(text);
        if (id == .iso8601) return regulate(parsed.year, parsed.month, .reject);
        const date = try PlainDate.from(.{ .string = text }, .{});
        var buf: [4]u8 = undefined;
        return from(.{ .fields = .{ .year = date.year(), .monthCode = date.monthCode(&buf), .calendar = @tagName(date.calendar) } }, .{});
    }

    pub fn with(self: PlainYearMonth, fields: Fields, options: FromOptions) TemporalError!PlainYearMonth {
        if (fields.calendar != null or (self.calendar != .iso8601 and (fields.era == null) != (fields.eraYear == null))) return error.TypeError;
        if (fields.year == null and fields.month == null and fields.monthCode == null and (self.calendar == .iso8601 or (fields.era == null and fields.eraYear == null))) return error.TypeError;
        var buf: [4]u8 = undefined;
        const code = if (fields.monthCode) |c| c else if (fields.month == null) self.monthCode(&buf) else null;
        return from(.{ .fields = .{ .year = if (fields.era != null or fields.eraYear != null) fields.year else fields.year orelse self.year(), .era = fields.era, .eraYear = fields.eraYear, .month = fields.month, .monthCode = code, .calendar = @tagName(self.calendar) } }, options);
    }

    fn asPlainDate(self: PlainYearMonth) TemporalError!PlainDate {
        if (self.calendar == .iso8601) return .{ .iso_year = self.iso_year, .iso_month = self.iso_month, .iso_day = 1 };
        var buf: [4]u8 = undefined;
        return PlainDate.from(.{ .fields = .{ .year = self.year(), .monthCode = self.monthCode(&buf), .day = 1, .calendar = @tagName(self.calendar) } }, .{});
    }

    /// Always constrains the day regardless of `overflow` -- ground-truthed
    /// against real Node (`day:35` on a 29-day February clamps to 29 even
    /// with `overflow:"reject"` explicitly passed).
    pub fn toPlainDate(self: PlainYearMonth, day: i32) TemporalError!PlainDate {
        var buf: [4]u8 = undefined;
        return PlainDate.from(.{ .fields = .{ .year = self.year(), .monthCode = self.monthCode(&buf), .day = day, .calendar = @tagName(self.calendar) } }, .{});
    }

    pub fn add(self: PlainYearMonth, d: Duration, overflow: Overflow) TemporalError!PlainYearMonth {
        var start = try self.asPlainDate();
        if (d.sign() < 0) start = try start.with(.{ .day = start.daysInMonth() }, .{});
        const result = try start.add(d, overflow);
        var buf: [4]u8 = undefined;
        return from(.{ .fields = .{ .year = result.year(), .monthCode = result.monthCode(&buf), .calendar = @tagName(result.calendar) } }, .{});
    }

    pub fn subtract(self: PlainYearMonth, d: Duration, overflow: Overflow) TemporalError!PlainYearMonth {
        return self.add(d.negated(), overflow);
    }

    /// Delegates to `PlainDate.until`/`.since`, restricted to
    /// `largestUnit`/`smallestUnit` of `.year`/`.month` only --
    /// ground-truthed that real Temporal rejects week/day here
    /// ("Weeks and days are not allowed in this operation").
    pub fn until(self: PlainYearMonth, other: PlainYearMonth, options: RoundingOptions) TemporalError!Duration {
        const largest = options.largestUnit orelse .year;
        const smallest = options.smallestUnit orelse .month;
        if (!isYearOrMonthUnit(largest) or !isYearOrMonthUnit(smallest)) return error.RangeError;
        if (!@import("calendar.zig").equal(self.calendar, other.calendar)) return error.RangeError;
        return (try self.asPlainDate()).until(try other.asPlainDate(), .{
            .largestUnit = largest,
            .smallestUnit = smallest,
            .roundingIncrement = options.roundingIncrement,
            .roundingMode = options.roundingMode,
        });
    }

    pub fn since(self: PlainYearMonth, other: PlainYearMonth, options: RoundingOptions) TemporalError!Duration {
        const largest = options.largestUnit orelse .year;
        const smallest = options.smallestUnit orelse .month;
        if (!isYearOrMonthUnit(largest) or !isYearOrMonthUnit(smallest)) return error.RangeError;
        if (!@import("calendar.zig").equal(self.calendar, other.calendar)) return error.RangeError;
        return (try self.asPlainDate()).since(try other.asPlainDate(), .{
            .largestUnit = largest,
            .smallestUnit = smallest,
            .roundingIncrement = options.roundingIncrement,
            .roundingMode = options.roundingMode,
        });
    }

    pub fn compare(a: PlainYearMonth, b: PlainYearMonth) std.math.Order {
        return PlainDate.compare(.{ .iso_year = a.iso_year, .iso_month = a.iso_month, .iso_day = a.reference_day }, .{ .iso_year = b.iso_year, .iso_month = b.iso_month, .iso_day = b.reference_day });
    }

    pub fn equals(a: PlainYearMonth, b: PlainYearMonth) bool {
        return a.iso_year == b.iso_year and a.iso_month == b.iso_month and a.reference_day == b.reference_day and @import("calendar.zig").equal(a.calendar, b.calendar);
    }

    pub fn era(self: PlainYearMonth) ?[]const u8 {
        return self.asCalendarDate().era();
    }
    pub fn eraYear(self: PlainYearMonth) ?i32 {
        return self.asCalendarDate().eraYear();
    }
    pub fn year(self: PlainYearMonth) i32 {
        return self.asCalendarDate().year();
    }
    pub fn month(self: PlainYearMonth) u8 {
        return self.asCalendarDate().month();
    }
    pub fn monthCode(self: PlainYearMonth, buf: *[4]u8) []const u8 {
        return self.asCalendarDate().monthCode(buf);
    }
    pub fn calendarId(self: PlainYearMonth) []const u8 {
        return @import("calendar.zig").displayName(self.calendar);
    }
    pub fn daysInMonth(self: PlainYearMonth) u8 {
        return self.asCalendarDate().daysInMonth();
    }
    pub fn daysInYear(self: PlainYearMonth) u16 {
        return self.asCalendarDate().daysInYear();
    }
    pub fn monthsInYear(self: PlainYearMonth) u8 {
        return self.asCalendarDate().monthsInYear();
    }
    pub fn inLeapYear(self: PlainYearMonth) bool {
        return self.asCalendarDate().inLeapYear();
    }

    /// `YYYY-MM` (or the extended `±YYYYYY-MM` form outside [0,9999]),
    /// optionally suffixed with `[u-ca=iso8601]`.
    pub fn toLocaleString(self: PlainYearMonth, allocator: std.mem.Allocator, io: std.Io, locales: ?[]const u8, options: @import("locale.zig").LocaleOptions) TemporalError![]u8 {
        const d = self.asCalendarDate().asYMD();
        return @import("locale.zig").format(allocator, io, .yearMonth, @as(f64, @floatFromInt(iso_calendar.toEpochDay(d.year, d.month, d.day))) * 86_400_000, self.calendar, null, locales, options);
    }
    pub fn toString(self: PlainYearMonth, allocator: std.mem.Allocator, options: StringOptions) TemporalError![]u8 {
        const raw = try self.formatDefault(allocator, options.calendarName == .always or options.calendarName == .critical or (options.calendarName == .auto and self.calendar != .iso8601));
        defer allocator.free(raw);
        return @import("format_options.zig").calendar(allocator, raw, options.calendarName == .critical);
    }
    pub fn toJSON(self: PlainYearMonth, allocator: std.mem.Allocator) TemporalError![]u8 {
        return self.toString(allocator, .{});
    }
    pub const StringOptions = @import("format_options.zig").StringOptions;
    fn formatDefault(self: PlainYearMonth, allocator: std.mem.Allocator, show_calendar: bool) ![]u8 {
        var year_buf: [8]u8 = undefined;
        const year_str = iso_string.formatYear(&year_buf, self.iso_year);
        if (show_calendar) {
            return allocator.print("{s}-{d:0>2}-{d:0>2}[u-ca={s}]", .{ year_str, self.iso_month, self.reference_day, self.calendarId() });
        }
        return allocator.print("{s}-{d:0>2}", .{ year_str, self.iso_month });
    }
};

test "init: constrain clamps upper bound, reject throws" {
    const constrained = try @import("plain_year_month.zig").regulate(2024, 13, .constrain);
    try std.testing.expectEqual(@as(u8, 12), constrained.iso_month);
    try std.testing.expectError(error.RangeError, PlainYearMonth.init(2024, 13, null, null));
}

test "init: month below 1 always rejects, regardless of overflow" {
    try std.testing.expectError(error.RangeError, @import("plain_year_month.zig").regulate(2024, 0, .constrain));
}

test "init: asymmetric range boundary (day1-or-last-day rule)" {
    _ = try PlainYearMonth.init(275760, 9, null, null);
    try std.testing.expectError(error.RangeError, PlainYearMonth.init(275760, 10, null, null));
    _ = try PlainYearMonth.init(-271821, 4, null, null);
    try std.testing.expectError(error.RangeError, PlainYearMonth.init(-271821, 3, null, null));
}

test "toPlainDate always constrains regardless of day validity" {
    const ym = try PlainYearMonth.init(2024, 2, null, null);
    const d = try ym.toPlainDate(35);
    try std.testing.expectEqual(@as(u8, 29), d.iso_day);
}

test "add: delegates to PlainDate{year,month,1}, day-31 vs day-1 construction identical" {
    const ym = try PlainYearMonth.init(2024, 1, null, null);
    const r1 = try ym.add(try Duration.init(0, 0, 0, 35, 0, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(u8, 2), r1.iso_month);
    const r2 = try ym.add(try Duration.init(0, 0, 0, 400, 0, 0, 0, 0, 0, 0), .constrain);
    try std.testing.expectEqual(@as(i32, 2025), r2.iso_year);
    try std.testing.expectEqual(@as(u8, 2), r2.iso_month);
}

test "until/since: rejects week/day units, default largestUnit is year" {
    const a = try PlainYearMonth.init(2024, 1, null, null);
    const b = try PlainYearMonth.init(2025, 6, null, null);
    const allocator = std.testing.allocator;
    const d = try a.until(b, .{});
    const s = try d.toString(allocator, .{});
    defer allocator.free(s);
    try std.testing.expectEqualStrings("P1Y5M", s);
    try std.testing.expectError(error.RangeError, a.until(b, .{ .smallestUnit = .day }));
    try std.testing.expectError(error.RangeError, a.until(b, .{ .smallestUnit = .week }));
}

test "toString matches real Node byte-for-byte" {
    const allocator = std.testing.allocator;
    {
        const ym = try PlainYearMonth.init(2024, 2, null, null);
        const s = try ym.toString(allocator, .{});
        defer allocator.free(s);
        try std.testing.expectEqualStrings("2024-02", s);
    }
    {
        const ym = try PlainYearMonth.init(-1, 1, null, null);
        const s = try ym.toString(allocator, .{});
        defer allocator.free(s);
        try std.testing.expectEqualStrings("-000001-01", s);
    }
}

test "fromString: bare YYYY-MM and full date string both parse, calendar validated" {
    const ym = try PlainYearMonth.from(.{ .string = "2024-02" }, .{});
    try std.testing.expectEqual(@as(u8, 2), ym.iso_month);
    const ym2 = try PlainYearMonth.from(.{ .string = "2024-02-15T10:00:00" }, .{});
    try std.testing.expectEqual(@as(i32, 2024), ym2.iso_year);
    try std.testing.expectEqual(@as(u8, 2), ym2.iso_month);
    try std.testing.expectError(error.RangeError, PlainYearMonth.from(.{ .string = "2024-02[u-ca=unknown]" }, .{}));
}
