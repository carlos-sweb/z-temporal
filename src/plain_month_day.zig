//! `Temporal.PlainMonthDay`, ISO calendar only (Phase 4). Ground-truthed
//! against real Node to have NO arithmetic at all (`.add`/`.subtract`/
//! `.until`/`.since`/`.compare`/`.round` are all `undefined` on the real
//! prototype) -- just construction/parsing/equality/`toPlainDate`.
//! Carries a hidden reference ISO year, always 1972 (a leap year, so
//! `M02`/day 29 is always constructible) -- ground-truthed via
//! `toString({calendarName:"always"})` showing `1972-...` regardless of
//! input, and that `PlainDate.prototype.toPlainMonthDay()` also always
//! uses 1972, not the source date's own year.
const std = @import("std");
const iso_calendar = @import("iso_calendar.zig");
const iso_string = @import("iso_string.zig");
const errors = @import("errors.zig");
const TemporalError = errors.TemporalError;
const plain_date_mod = @import("plain_date.zig");
const PlainDate = plain_date_mod.PlainDate;
const Overflow = plain_date_mod.Overflow;

pub const REFERENCE_YEAR: i32 = 1972;

pub const PlainMonthDay = struct {
    iso_month: u8, // 1-12
    iso_day: u8, // 1-31
    reference_year: i32 = REFERENCE_YEAR,

    /// Real spec: month/day must be positive integers unconditionally
    /// (lower bound always rejects); only the upper bound respects
    /// `overflow`. Day validity uses `REFERENCE_YEAR`'s calendar (1972 is
    /// a leap year, so `day:29` for February is always constructible,
    /// `day:30` never is).
    pub fn create(in_month: i32, in_day: i32, overflow: Overflow) TemporalError!PlainMonthDay {
        if (in_month < 1 or in_day < 1) return error.InvalidRange;
        var m: u8 = undefined;
        if (in_month > 12) {
            if (overflow == .reject) return error.InvalidRange;
            m = 12;
        } else {
            m = @intCast(in_month);
        }
        const max_day = iso_calendar.daysInMonth(REFERENCE_YEAR, m);
        var d: u8 = undefined;
        if (in_day > max_day) {
            if (overflow == .reject) return error.InvalidRange;
            d = max_day;
        } else {
            d = @intCast(in_day);
        }
        return .{ .iso_month = m, .iso_day = d, .reference_year = REFERENCE_YEAR };
    }

    pub fn parseIso(text: []const u8) TemporalError!PlainMonthDay {
        const parsed = try iso_string.parsePlainMonthDay(text);
        return create(parsed.month, parsed.day, .reject);
    }

    pub fn withFields(self: PlainMonthDay, in_month: ?i32, in_day: ?i32, overflow: Overflow) TemporalError!PlainMonthDay {
        return create(in_month orelse self.iso_month, in_day orelse self.iso_day, overflow);
    }

    /// Always constrains, same as `PlainYearMonth.toPlainDate` --
    /// ground-truthed against real Node.
    pub fn toPlainDate(self: PlainMonthDay, year: i32) TemporalError!PlainDate {
        return PlainDate.create(year, self.iso_month, self.iso_day, .constrain);
    }

    /// Compares month, day, AND `reference_year` -- ground-truthed (two
    /// `PlainMonthDay`s with the same month/day but a different explicit
    /// reference year, via real Temporal's 4-arg constructor, are not
    /// equal). Every construction path this library exposes uses
    /// `REFERENCE_YEAR` unconditionally, so this only matters for
    /// documented correctness, not a reachable divergence here.
    pub fn equals(a: PlainMonthDay, b: PlainMonthDay) bool {
        return a.iso_month == b.iso_month and a.iso_day == b.iso_day and a.reference_year == b.reference_year;
    }

    pub fn day(self: PlainMonthDay) u8 {
        return self.iso_day;
    }
    pub fn monthCode(self: PlainMonthDay, buf: *[3]u8) []const u8 {
        return iso_calendar.monthCodeBuf(buf, self.iso_month);
    }
    pub fn calendarId(self: PlainMonthDay) []const u8 {
        _ = self;
        return "iso8601";
    }

    /// `MM-DD` -- the reference year is never shown by default (matches
    /// real Temporal: it only appears with an explicit calendar-name
    /// request, which this repo doesn't implement as a JS-level option;
    /// `show_calendar` reuses `reference_year` for that annotated form,
    /// same shape as the other Plain types' `[u-ca=iso8601]` suffix).
    pub fn toIsoString(self: PlainMonthDay, allocator: std.mem.Allocator, show_calendar: bool) ![]u8 {
        if (show_calendar) {
            var year_buf: [8]u8 = undefined;
            const year_str = iso_string.formatYear(&year_buf, self.reference_year);
            return std.fmt.allocPrint(allocator, "{s}-{d:0>2}-{d:0>2}[u-ca=iso8601]", .{ year_str, self.iso_month, self.iso_day });
        }
        return std.fmt.allocPrint(allocator, "{d:0>2}-{d:0>2}", .{ self.iso_month, self.iso_day });
    }
};

test "create: constrain clamps upper bound, reject throws" {
    const constrained = try PlainMonthDay.create(2, 30, .constrain);
    try std.testing.expectEqual(@as(u8, 29), constrained.iso_day);
    try std.testing.expectError(error.InvalidRange, PlainMonthDay.create(2, 30, .reject));
    _ = try PlainMonthDay.create(2, 29, .reject);
}

test "create: month/day below 1 always rejects, regardless of overflow" {
    try std.testing.expectError(error.InvalidRange, PlainMonthDay.create(0, 1, .constrain));
    try std.testing.expectError(error.InvalidRange, PlainMonthDay.create(1, 0, .constrain));
}

test "toPlainDate always constrains" {
    const md = try PlainMonthDay.create(2, 29, .reject);
    const d = try md.toPlainDate(2023);
    try std.testing.expectEqual(@as(u8, 28), d.iso_day);
}

test "equals compares month, day, and reference_year" {
    const a = try PlainMonthDay.create(2, 29, .reject);
    const b = try PlainMonthDay.create(2, 29, .reject);
    try std.testing.expect(PlainMonthDay.equals(a, b));
    const c = PlainMonthDay{ .iso_month = 2, .iso_day = 29, .reference_year = 2000 };
    try std.testing.expect(!PlainMonthDay.equals(a, c));
}

test "toIsoString matches real Node byte-for-byte" {
    const allocator = std.testing.allocator;
    {
        const md = try PlainMonthDay.create(2, 29, .reject);
        const s = try md.toIsoString(allocator, false);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("02-29", s);
    }
    {
        const md = try PlainMonthDay.create(2, 29, .reject);
        const s = try md.toIsoString(allocator, true);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("1972-02-29[u-ca=iso8601]", s);
    }
}

test "parseIso: bare MM-DD and full date string both parse" {
    const md = try PlainMonthDay.parseIso("02-29");
    try std.testing.expectEqual(@as(u8, 2), md.iso_month);
    try std.testing.expectEqual(@as(u8, 29), md.iso_day);
    const md2 = try PlainMonthDay.parseIso("2024-02-15T10:00:00");
    try std.testing.expectEqual(@as(u8, 2), md2.iso_month);
    try std.testing.expectEqual(@as(u8, 15), md2.iso_day);
    try std.testing.expectError(error.InvalidFormat, PlainMonthDay.parseIso("02-29[u-ca=hebrew]"));
}
