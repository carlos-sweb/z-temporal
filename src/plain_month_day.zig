//! Temporal.PlainMonthDay: preserves constructor reference years; from normalizes them.
const calendars = @import("calendar.zig");
const std = @import("std");
const iso_calendar = @import("iso_calendar.zig");
const iso_string = @import("iso_string.zig");
const errors = @import("errors.zig");
const TemporalError = errors.TemporalError;
const plain_date_mod = @import("plain_date.zig");
const PlainDate = plain_date_mod.PlainDate;
const Overflow = plain_date_mod.Overflow;

pub const REFERENCE_YEAR: i32 = 1972;

pub fn regulate(in_month: i32, in_day: i32, overflow: Overflow) TemporalError!PlainMonthDay {
    if (in_month < 1 or in_day < 1) return error.RangeError;
    var m: u8 = undefined;
    if (in_month > 12) {
        if (overflow == .reject) return error.RangeError;
        m = 12;
    } else {
        m = @intCast(in_month);
    }
    const max_day = iso_calendar.daysInMonth(REFERENCE_YEAR, m);
    var d: u8 = undefined;
    if (in_day > max_day) {
        if (overflow == .reject) return error.RangeError;
        d = max_day;
    } else {
        d = @intCast(in_day);
    }
    return .{ .iso_month = m, .iso_day = d, .reference_year = REFERENCE_YEAR };
}

pub const PlainMonthDay = struct {
    calendar: calendars.Id = .iso8601,
    calendarData: ?calendars.Info = null,
    iso_month: u8, // 1-12
    iso_day: u8, // 1-31
    reference_year: i32 = REFERENCE_YEAR,

    /// Real spec: month/day must be positive integers unconditionally
    /// (lower bound always rejects); only the upper bound respects
    /// `overflow`. Day validity uses `REFERENCE_YEAR`'s calendar (1972 is
    /// a leap year, so `day:29` for February is always constructible,
    /// `day:30` never is).
    pub fn init(in_month: i32, in_day: i32, calendarIdValue: ?[]const u8, referenceISOYear: ?i32) TemporalError!PlainMonthDay {
        const year_value = referenceISOYear orelse REFERENCE_YEAR;
        const date = try PlainDate.init(year_value, in_month, in_day, null);
        return fromDate(try date.withCalendar(calendarIdValue orelse "iso8601"));
    }

    fn fromDate(value: PlainDate) PlainMonthDay {
        return .{ .iso_month = value.iso_month, .iso_day = value.iso_day, .reference_year = value.iso_year, .calendar = value.calendar, .calendarData = value.calendarData };
    }
    fn asCalendarDate(self: PlainMonthDay) PlainDate {
        return .{ .iso_year = self.reference_year, .iso_month = self.iso_month, .iso_day = self.iso_day, .calendar = self.calendar, .calendarData = self.calendarData };
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
    pub const FromInput = union(enum) { string: []const u8, value: PlainMonthDay, fields: Fields };
    pub const FromOptions = struct { overflow: Overflow = .constrain };
    pub fn from(input: FromInput, options: FromOptions) TemporalError!PlainMonthDay {
        return switch (input) {
            .string => |text| fromString(text),
            .value => |value| value,
            .fields => |f| blk: {
                const id = try calendars.parse(f.calendar orelse "iso8601");
                const d = f.day orelse return error.TypeError;
                if (id == .iso8601) {
                    const date = try PlainDate.from(.{ .fields = .{ .year = f.year orelse REFERENCE_YEAR, .month = f.month, .monthCode = f.monthCode, .day = d } }, .{ .overflow = options.overflow });
                    break :blk regulate(date.iso_month, date.iso_day, .reject);
                }
                if (f.monthCode == null and f.year == null and f.era == null and f.eraYear == null) return error.TypeError;
                var code_buf: [4]u8 = undefined;
                var code = f.monthCode;
                var actual_day = d;
                if (f.year != null or f.era != null or f.eraYear != null) {
                    const year_value = try calendars.resolveYear(id, f.year, f.era, f.eraYear);
                    const date = try PlainDate.from(.{ .fields = .{ .year = year_value, .month = f.month, .monthCode = f.monthCode, .day = d, .calendar = f.calendar } }, .{ .overflow = options.overflow });
                    code = date.monthCode(&code_buf);
                    actual_day = date.day();
                }
                const reference = try (try PlainDate.init(1972, 12, 31, null)).withCalendar(@tagName(id));
                var year_value = reference.year();
                var count: usize = 0;
                while (count < 100) : (count += 1) {
                    const candidate = PlainDate.from(.{ .fields = .{ .year = year_value, .monthCode = code, .day = actual_day, .calendar = f.calendar } }, .{ .overflow = .reject }) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        year_value -= 1;
                        continue;
                    };
                    if (PlainDate.compare(candidate, reference) != .gt) break :blk fromDate(candidate);
                    year_value -= 1;
                }
                return error.RangeError;
            },
        };
    }

    fn fromString(text: []const u8) TemporalError!PlainMonthDay {
        const id = try calendars.fromString(text);
        const parsed = try iso_string.parsePlainMonthDay(text);
        if (id == .iso8601) return regulate(parsed.month, parsed.day, .reject);
        const date = try PlainDate.from(.{ .string = text }, .{});
        var buf: [4]u8 = undefined;
        return from(.{ .fields = .{ .monthCode = date.monthCode(&buf), .day = date.day(), .calendar = @tagName(date.calendar) } }, .{});
    }

    pub fn with(self: PlainMonthDay, fields: Fields, options: FromOptions) TemporalError!PlainMonthDay {
        if (fields.calendar != null or (self.calendar != .iso8601 and (fields.era == null) != (fields.eraYear == null))) return error.TypeError;
        if ((self.calendar == .iso8601 or (fields.era == null and fields.eraYear == null)) and fields.year == null and fields.month == null and fields.day == null and fields.monthCode == null) return error.TypeError;
        var buf: [4]u8 = undefined;
        const code = if (fields.monthCode) |c| c else if (fields.month == null) self.monthCode(&buf) else null;
        return from(.{ .fields = .{ .day = fields.day orelse self.day(), .year = fields.year, .era = fields.era, .eraYear = fields.eraYear, .month = fields.month, .monthCode = code, .calendar = @tagName(self.calendar) } }, options);
    }

    /// Always constrains, same as `PlainYearMonth.toPlainDate` --
    /// ground-truthed against real Node.
    pub fn toPlainDate(self: PlainMonthDay, year: i32) TemporalError!PlainDate {
        var buf: [4]u8 = undefined;
        return PlainDate.from(.{ .fields = .{ .year = year, .monthCode = self.monthCode(&buf), .day = self.day(), .calendar = @tagName(self.calendar) } }, .{});
    }

    /// Compares month, day, AND `reference_year` -- ground-truthed (two
    /// `PlainMonthDay`s with the same month/day but a different explicit
    /// reference year, via real Temporal's 4-arg constructor, are not
    /// equal). Constructors preserve references; from normalizes them.
    pub fn equals(a: PlainMonthDay, b: PlainMonthDay) bool {
        return a.iso_month == b.iso_month and a.iso_day == b.iso_day and a.reference_year == b.reference_year and @import("calendar.zig").equal(a.calendar, b.calendar);
    }

    pub fn day(self: PlainMonthDay) u8 {
        return self.asCalendarDate().day();
    }
    pub fn monthCode(self: PlainMonthDay, buf: *[4]u8) []const u8 {
        return self.asCalendarDate().monthCode(buf);
    }
    pub fn calendarId(self: PlainMonthDay) []const u8 {
        return @import("calendar.zig").displayName(self.calendar);
    }

    /// `MM-DD` -- the reference year is never shown by default (matches
    /// real Temporal: it only appears with an explicit calendar-name
    /// request, which this repo doesn't implement as a JS-level option;
    /// `show_calendar` reuses `reference_year` for that annotated form,
    /// same shape as the other Plain types' `[u-ca=iso8601]` suffix).
    pub fn toLocaleString(self: PlainMonthDay, allocator: std.mem.Allocator, io: std.Io, locales: ?[]const u8, options: @import("locale.zig").LocaleOptions) TemporalError![]u8 {
        const d = self.asCalendarDate().asYMD();
        return @import("locale.zig").format(allocator, io, .monthDay, @as(f64, @floatFromInt(iso_calendar.toEpochDay(d.year, d.month, d.day))) * 86_400_000, self.calendar, null, locales, options);
    }
    pub fn toString(self: PlainMonthDay, allocator: std.mem.Allocator, options: StringOptions) TemporalError![]u8 {
        const raw = try self.formatDefault(allocator, options.calendarName == .always or options.calendarName == .critical or (options.calendarName == .auto and self.calendar != .iso8601));
        defer allocator.free(raw);
        return @import("format_options.zig").calendar(allocator, raw, options.calendarName == .critical);
    }
    pub fn toJSON(self: PlainMonthDay, allocator: std.mem.Allocator) TemporalError![]u8 {
        return self.toString(allocator, .{});
    }
    pub const StringOptions = @import("format_options.zig").StringOptions;
    fn formatDefault(self: PlainMonthDay, allocator: std.mem.Allocator, show_calendar: bool) ![]u8 {
        if (show_calendar) {
            var year_buf: [8]u8 = undefined;
            const year_str = iso_string.formatYear(&year_buf, self.reference_year);
            return allocator.print("{s}-{d:0>2}-{d:0>2}[u-ca={s}]", .{ year_str, self.iso_month, self.iso_day, self.calendarId() });
        }
        return allocator.print("{d:0>2}-{d:0>2}", .{ self.iso_month, self.iso_day });
    }
};

test "init: constrain clamps upper bound, reject throws" {
    const constrained = try @import("plain_month_day.zig").regulate(2, 30, .constrain);
    try std.testing.expectEqual(@as(u8, 29), constrained.iso_day);
    try std.testing.expectError(error.RangeError, PlainMonthDay.init(2, 30, null, null));
    _ = try PlainMonthDay.init(2, 29, null, null);
}

test "init: month/day below 1 always rejects, regardless of overflow" {
    try std.testing.expectError(error.RangeError, @import("plain_month_day.zig").regulate(0, 1, .constrain));
    try std.testing.expectError(error.RangeError, @import("plain_month_day.zig").regulate(1, 0, .constrain));
}

test "toPlainDate always constrains" {
    const md = try PlainMonthDay.init(2, 29, null, null);
    const d = try md.toPlainDate(2023);
    try std.testing.expectEqual(@as(u8, 28), d.iso_day);
}

test "equals compares month, day, and reference_year" {
    const a = try PlainMonthDay.init(2, 29, null, null);
    const b = try PlainMonthDay.init(2, 29, null, null);
    try std.testing.expect(PlainMonthDay.equals(a, b));
    const c = PlainMonthDay{ .iso_month = 2, .iso_day = 29, .reference_year = 2000 };
    try std.testing.expect(!PlainMonthDay.equals(a, c));
}

test "toString matches real Node byte-for-byte" {
    const allocator = std.testing.allocator;
    {
        const md = try PlainMonthDay.init(2, 29, null, null);
        const s = try md.toString(allocator, .{});
        defer allocator.free(s);
        try std.testing.expectEqualStrings("02-29", s);
    }
    {
        const md = try PlainMonthDay.init(2, 29, null, null);
        const s = try md.toString(allocator, .{ .calendarName = .always });
        defer allocator.free(s);
        try std.testing.expectEqualStrings("1972-02-29[u-ca=iso8601]", s);
    }
}

test "fromString: bare MM-DD and full date string both parse" {
    const md = try PlainMonthDay.from(.{ .string = "02-29" }, .{});
    try std.testing.expectEqual(@as(u8, 2), md.iso_month);
    try std.testing.expectEqual(@as(u8, 29), md.iso_day);
    const md2 = try PlainMonthDay.from(.{ .string = "2024-02-15T10:00:00" }, .{});
    try std.testing.expectEqual(@as(u8, 2), md2.iso_month);
    try std.testing.expectEqual(@as(u8, 15), md2.iso_day);
    try std.testing.expectError(error.RangeError, PlainMonthDay.from(.{ .string = "02-29[u-ca=unknown]" }, .{}));
}
