const std = @import("std");
const t = @import("ztemporal");
const Kind = enum { PlainDate, PlainTime, PlainDateTime, PlainYearMonth, PlainMonthDay, Instant, Duration, ZonedDateTime };
const Options = struct {
    largestUnit: ?t.Unit = null,
    smallestUnit: ?t.Unit = null,
    roundingIncrement: u32 = 1,
    roundingMode: ?t.RoundingMode = null,
    fractionalSecondDigits: ?u8 = null,
    calendarName: t.CalendarName = .auto,
    timeZoneName: t.TimeZoneName = .auto,
    offset: ?[]const u8 = null,
    disambiguation: t.Disambiguation = .compatible,
    overflow: @TypeOf(t.Overflow.constrain) = .constrain,
    localeOptions: t.LocaleOptions = .{},
    durationLocaleOptions: @import("ztemporal").DurationLocaleOptions = .{},
    locales: ?[]const u8 = null,
    relativeTo: ?[]const u8 = null,
    unit: t.Unit = .nanosecond,
};
const Request = struct { kind: Kind, op: []const u8, a: []const u8, b: ?[]const u8 = null, options: Options = .{} };
const Properties = struct { year: ?i32 = null, month: ?u8 = null, monthCode: []const u8, day: ?u8 = null, era: ?[]const u8 = null, eraYear: ?i32 = null, daysInYear: ?u16 = null, daysInMonth: ?u8 = null, monthsInYear: ?u8 = null, inLeapYear: ?bool = null };
fn properties(comptime T: type, value: T, allocator: std.mem.Allocator) !Properties {
    var buf: [4]u8 = undefined;
    return .{ .year = if (@hasDecl(T, "year")) value.year() else null, .month = if (@hasDecl(T, "month")) value.month() else null, .day = if (@hasDecl(T, "day")) value.day() else null, .monthCode = try allocator.dupe(u8, value.monthCode(&buf)), .era = if (@hasDecl(T, "era")) value.era() else null, .eraYear = if (@hasDecl(T, "eraYear")) value.eraYear() else null, .daysInYear = if (@hasDecl(T, "daysInYear")) value.daysInYear() else null, .daysInMonth = if (@hasDecl(T, "daysInMonth")) value.daysInMonth() else null, .monthsInYear = if (@hasDecl(T, "monthsInYear")) value.monthsInYear() else null, .inLeapYear = if (@hasDecl(T, "inLeapYear")) value.inLeapYear() else null };
}
const Response = struct { properties: ?Properties = null, result: ?[]const u8 = null, number: ?f64 = null, errorName: ?[]const u8 = null, components: ?t.Duration = null };
fn is(req: Request, op: []const u8) bool {
    return std.mem.eql(u8, req.op, op);
}
fn opts(req: Request) t.RoundingOptions {
    return .{ .largestUnit = req.options.largestUnit, .smallestUnit = req.options.smallestUnit, .roundingIncrement = req.options.roundingIncrement, .roundingMode = req.options.roundingMode orelse .trunc };
}
fn rounding(req: Request) t.RoundOptions {
    return .{ .largestUnit = req.options.largestUnit, .smallestUnit = req.options.smallestUnit, .roundingIncrement = req.options.roundingIncrement, .roundingMode = req.options.roundingMode orelse .halfExpand };
}
fn format(req: Request) t.StringOptions {
    return .{ .fractionalSecondDigits = req.options.fractionalSecondDigits, .smallestUnit = req.options.smallestUnit, .roundingMode = req.options.roundingMode orelse .trunc, .calendarName = req.options.calendarName, .timeZoneName = req.options.timeZoneName, .offset = if (req.options.offset) |v| (if (std.mem.eql(u8, v, "never")) .never else .auto) else .auto };
}
fn durationResponse(allocator: std.mem.Allocator, d: t.Duration) !Response {
    return .{ .result = try d.toString(allocator, .{}), .components = d };
}
fn plain(comptime T: type, req: Request, allocator: std.mem.Allocator, io: std.Io) !Response {
    const a = try T.from(.{ .string = req.a }, .{});
    if (is(req, "toLocaleString")) return .{ .result = try a.toLocaleString(allocator, io, req.options.locales, req.options.localeOptions) };
    if (comptime @hasDecl(T, "monthCode")) if (is(req, "properties")) return .{ .properties = try properties(T, a, allocator) };
    if (is(req, "from") or is(req, "toString")) return .{ .result = try a.toString(allocator, format(req)) };
    if (is(req, "toJSON")) return .{ .result = try a.toJSON(allocator) };
    if (comptime @hasDecl(T, "until")) {
        if (is(req, "until") or is(req, "since")) {
            const b = try T.from(.{ .string = req.b.? }, .{});
            return durationResponse(allocator, if (is(req, "until")) try a.until(b, opts(req)) else try a.since(b, opts(req)));
        }
    }
    if (comptime @hasDecl(T, "add")) {
        if (is(req, "add") or is(req, "subtract")) {
            const d = try t.Duration.from(.{ .string = req.b.? });
            const result = if (T == t.PlainTime) (if (is(req, "add")) a.add(d) else a.subtract(d)) else (if (is(req, "add")) try a.add(d, req.options.overflow) else try a.subtract(d, req.options.overflow));
            return .{ .result = try result.toString(allocator, .{}) };
        }
    }
    if (comptime @hasDecl(T, "round")) if (is(req, "round")) return .{ .result = try (try a.round(rounding(req))).toString(allocator, .{}) };
    return error.TypeError;
}
fn execute(req: Request, allocator: std.mem.Allocator, io: std.Io) !Response {
    switch (req.kind) {
        .PlainDate => return plain(t.PlainDate, req, allocator, io),
        .PlainTime => return plain(t.PlainTime, req, allocator, io),
        .PlainDateTime => return plain(t.PlainDateTime, req, allocator, io),
        .PlainYearMonth => return plain(t.PlainYearMonth, req, allocator, io),
        .PlainMonthDay => return plain(t.PlainMonthDay, req, allocator, io),
        .Instant => {
            const a = try t.Instant.from(.{ .string = req.a });
            if (is(req, "from") or is(req, "toString")) return .{ .result = try a.toString(allocator, format(req)) };
            if (is(req, "toLocaleString")) return .{ .result = try a.toLocaleString(allocator, io, req.options.locales, req.options.localeOptions) };
            if (is(req, "toJSON")) return .{ .result = try a.toJSON(allocator) };
            if (is(req, "round")) return .{ .result = try (try a.round(rounding(req))).toString(allocator, .{}) };
            if (is(req, "until") or is(req, "since")) {
                const b = try t.Instant.from(.{ .string = req.b.? });
                return durationResponse(allocator, if (is(req, "until")) try a.until(b, opts(req)) else try a.since(b, opts(req)));
            }
            const d = try t.Duration.from(.{ .string = req.b.? });
            return .{ .result = try (if (is(req, "add")) try a.add(d) else try a.subtract(d)).toString(allocator, .{}) };
        },
        .Duration => {
            const a = try t.Duration.from(.{ .string = req.a });
            if (is(req, "toLocaleString")) return .{ .result = try a.toLocaleString(allocator, req.options.locales, req.options.durationLocaleOptions) };
            var rt: ?t.Duration.RelativeTo = null;
            if (req.options.relativeTo) |text| {
                rt = if (std.mem.indexOfScalar(u8, text, '[') != null) .{ .zonedDateTime = try t.ZonedDateTime.from(allocator, io, .{ .string = text }, .{}) } else .{ .plainDate = try t.PlainDate.from(.{ .string = text }, .{}) };
            }
            if (is(req, "total")) return .{ .number = try a.total(.{ .relativeTo = rt, .unit = req.options.unit, .allocator = allocator, .io = io }) };
            if (is(req, "round")) return durationResponse(allocator, try a.round(.{ .relativeTo = rt, .largestUnit = req.options.largestUnit, .smallestUnit = req.options.smallestUnit, .roundingIncrement = req.options.roundingIncrement, .roundingMode = req.options.roundingMode orelse .halfExpand, .allocator = allocator, .io = io }));
            if (is(req, "compare")) return .{ .number = switch (try t.Duration.compare(a, try t.Duration.from(.{ .string = req.b.? }), .{ .relativeTo = rt, .allocator = allocator, .io = io })) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            } };
            if (is(req, "add") or is(req, "subtract")) {
                const b = try t.Duration.from(.{ .string = req.b.? });
                return durationResponse(allocator, if (is(req, "add")) try a.add(b) else try a.subtract(b));
            }
            return .{ .result = try a.toString(allocator, format(req)), .components = a };
        },
        .ZonedDateTime => {
            const offset_option: t.OffsetOption = if (req.options.offset) |name| std.meta.stringToEnum(t.OffsetOption, name) orelse .reject else .reject;
            const a = try t.ZonedDateTime.from(allocator, io, .{ .string = req.a }, .{ .offset = offset_option, .disambiguation = req.options.disambiguation });
            if (is(req, "from") or is(req, "toString")) return .{ .result = try a.toString(allocator, io, format(req)) };
            if (is(req, "toLocaleString")) return .{ .result = try a.toLocaleString(allocator, io, req.options.locales, req.options.localeOptions) };
            if (is(req, "toJSON")) return .{ .result = try a.toJSON(allocator, io) };
            if (is(req, "round")) return .{ .result = try (try a.round(allocator, io, rounding(req))).toString(allocator, io, .{}) };
            if (is(req, "until") or is(req, "since")) {
                const b = try t.ZonedDateTime.from(allocator, io, .{ .string = req.b.? }, .{});
                return durationResponse(allocator, if (is(req, "until")) try a.until(allocator, io, b, opts(req)) else try a.since(allocator, io, b, opts(req)));
            }
            const d = try t.Duration.from(.{ .string = req.b.? });
            return .{ .result = try (if (is(req, "add")) try a.add(allocator, io, d, req.options.overflow) else try a.subtract(allocator, io, d, req.options.overflow)).toString(allocator, io, .{}) };
        },
    }
}
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const parsed = try std.json.parseFromSlice(Request, allocator, args[1], .{ .ignore_unknown_fields = true });
    const response = execute(parsed.value, allocator, init.io) catch |err| Response{ .errorName = @errorName(err) };
    const json = try std.json.Stringify.valueAlloc(allocator, response, .{ .emit_null_optional_fields = false });
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.writeAll(json);
    try stdout.interface.flush();
}
