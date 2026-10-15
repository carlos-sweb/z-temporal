const std = @import("std");
const ztemporal = @import("ztemporal");
const Instant = ztemporal.Instant;
const Duration = ztemporal.Duration;

test "public API: fromEpochMilliseconds, toString round-trip via fromString" {
    const i = try Instant.fromEpochMilliseconds(0);
    const allocator = std.testing.allocator;
    const s = try i.toString(allocator, .{});
    defer allocator.free(s);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", s);

    const parsed = try Instant.from(.{ .string = s });
    try std.testing.expect(Instant.equals(i, parsed));
}

test "public API: compare, equals" {
    const a = try Instant.fromEpochMilliseconds(0);
    const b = try Instant.fromEpochMilliseconds(1000);
    try std.testing.expectEqual(std.math.Order.lt, Instant.compare(a, b));
    try std.testing.expect(!Instant.equals(a, b));
    try std.testing.expect(Instant.equals(a, a));
}

test "public API: add/subtract via Duration" {
    const i = try Instant.fromEpochMilliseconds(0);
    const added = try i.add(try Duration.init(0, 0, 0, 0, 5, 0, 0, 0, 0, 0));
    const allocator = std.testing.allocator;
    const s = try added.toString(allocator, .{});
    defer allocator.free(s);
    try std.testing.expectEqualStrings("1970-01-01T05:00:00Z", s);

    const back = try added.subtract(try Duration.init(0, 0, 0, 0, 5, 0, 0, 0, 0, 0));
    try std.testing.expect(Instant.equals(i, back));
}

test "public API: round" {
    const i = try Instant.fromEpochMilliseconds(30 * 60 * 1000 + 90_000);
    const r = try i.round(.{ .smallestUnit = .hour });
    const allocator = std.testing.allocator;
    const s = try r.toString(allocator, .{});
    defer allocator.free(s);
    try std.testing.expectEqualStrings("1970-01-01T01:00:00Z", s);
}

test "round: random-batch differential against real Node" {
    const Case = struct { ns: i128, su: ztemporal.Unit, mode: ztemporal.RoundingMode, result: i128 };
    const cases = [_]Case{
        .{ .ns = 470267621080796577, .su = .millisecond, .mode = .halfEven, .result = 470267621081000000 },
        .{ .ns = -281671193677107795, .su = .minute, .mode = .halfCeil, .result = -281671200000000000 },
        .{ .ns = -1553797930615116916, .su = .hour, .mode = .trunc, .result = -1553799600000000000 },
        .{ .ns = -201402446514157173, .su = .millisecond, .mode = .halfExpand, .result = -201402446514000000 },
        .{ .ns = -965672646120824795, .su = .nanosecond, .mode = .halfTrunc, .result = -965672646120824795 },
        .{ .ns = 1247037847683663456, .su = .microsecond, .mode = .ceil, .result = 1247037847683664000 },
        .{ .ns = 760559174592626546, .su = .microsecond, .mode = .halfEven, .result = 760559174592627000 },
        .{ .ns = 1513991550797295744, .su = .second, .mode = .floor, .result = 1513991550000000000 },
        .{ .ns = 1263497680942502454, .su = .nanosecond, .mode = .halfCeil, .result = 1263497680942502454 },
        .{ .ns = -1569169930654553155, .su = .minute, .mode = .halfEven, .result = -1569169920000000000 },
        .{ .ns = -801058238759037020, .su = .second, .mode = .ceil, .result = -801058238000000000 },
        .{ .ns = 999252971249074148, .su = .microsecond, .mode = .floor, .result = 999252971249074000 },
        .{ .ns = -1650808276524756885, .su = .second, .mode = .halfCeil, .result = -1650808277000000000 },
        .{ .ns = 153148477453604525, .su = .second, .mode = .floor, .result = 153148477000000000 },
        .{ .ns = 325682248598215128, .su = .hour, .mode = .halfExpand, .result = 325681200000000000 },
    };
    for (cases) |c| {
        const i = try Instant.fromEpochNanoseconds(c.ns);
        const r = try i.round(.{ .smallestUnit = c.su, .roundingMode = c.mode });
        try std.testing.expectEqual(c.result, r.epochNs);
    }
}

test "until: random-batch differential against real Node" {
    const Case = struct { a: i128, b: i128, lu: ztemporal.Unit, result: []const u8 };
    const cases = [_]Case{
        // Restore values beyond Number.MAX_SAFE_INTEGER; observable Duration
        // components and serialization now reproduce Node's Number rounding.
        .{ .a = 0, .b = 774083557755723856, .lu = .nanosecond, .result = "PT774083557.755723904S" },
        .{ .a = 0, .b = -774083557755723856, .lu = .nanosecond, .result = "-PT774083557.755723904S" },
        .{ .a = 1177473340838060079, .b = 83411864937962772, .lu = .second, .result = "-PT1094061475.900097307S" },
        .{ .a = -1442675706267141290, .b = -1445258976513472941, .lu = .nanosecond, .result = "-PT2583270.246331651S" },
        .{ .a = 818212919645620302, .b = -620676116429605263, .lu = .millisecond, .result = "-PT1438889036.075225565S" },
        .{ .a = 1124736557182746167, .b = -89415057571734390, .lu = .microsecond, .result = "-PT1214151614.754480557S" },
        .{ .a = 778759286108919695, .b = -976041075324608296, .lu = .minute, .result = "-PT29246672M41.433527991S" },
        .{ .a = 419097414408924414, .b = 205334326451164668, .lu = .second, .result = "-PT213763087.957759746S" },
        .{ .a = -164816172871512502, .b = -199597782593727206, .lu = .microsecond, .result = "-PT34781609.722214704S" },
        .{ .a = 342053189386521099, .b = 1210987861034599340, .lu = .second, .result = "PT868934671.648078241S" },
        .{ .a = -1169505960909391542, .b = -1006367591752709300, .lu = .microsecond, .result = "PT163138369.156682242S" },
        .{ .a = -1319977961723499881, .b = -1311425268562649150, .lu = .nanosecond, .result = "PT8552693.160850731S" },
    };
    const allocator = std.testing.allocator;
    for (cases) |c| {
        const a = try Instant.fromEpochNanoseconds(c.a);
        const b = try Instant.fromEpochNanoseconds(c.b);
        const d = try a.until(b, .{ .largestUnit = c.lu });
        const s = try d.toString(allocator, .{});
        defer allocator.free(s);
        try std.testing.expectEqualStrings(c.result, s);
    }
}

test "public API: until/since" {
    const a = try Instant.fromEpochMilliseconds(0);
    const b = try Instant.fromEpochMilliseconds(90_061_000);
    const allocator = std.testing.allocator;
    const d = try a.until(b, .{ .largestUnit = .hour });
    const s = try d.toString(allocator, .{});
    defer allocator.free(s);
    try std.testing.expectEqualStrings("PT25H1M1S", s);

    const d2 = try b.since(a, .{ .largestUnit = .hour });
    const s2 = try d2.toString(allocator, .{});
    defer allocator.free(s2);
    try std.testing.expectEqualStrings("PT25H1M1S", s2);
}

test "public API: toZonedDateTimeISO" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const i = try Instant.fromEpochNanoseconds(1_718_467_200_000_000_000);
    const z = try i.toZonedDateTimeISO(allocator, io, "America/New_York");
    const s = try z.toString(allocator, io, .{ .offset = .auto, .timeZoneName = .auto, .calendarName = .never });
    defer allocator.free(s);
    try std.testing.expectEqualStrings("2024-06-15T12:00:00-04:00[America/New_York]", s);
}

test "test262: Instant.round increments divide a full day" {
    const instant = try Instant.from(.{ .string = "1976-11-18T14:23:30.123456789Z" });
    const next_day = try Instant.from(.{ .string = "1976-11-19T00:00:00Z" });
    const Case = struct { unit: ztemporal.Unit, increments: []const u32 };
    const cases = [_]Case{
        .{ .unit = .hour, .increments = &.{ 1, 2, 4, 6, 8, 12, 24 } },
        .{ .unit = .minute, .increments = &.{ 1, 5, 10, 20, 30, 40, 80, 120, 720, 1440 } },
        .{ .unit = .second, .increments = &.{ 1, 5, 10, 20, 25, 30, 50, 100, 400, 864, 86400 } },
        .{ .unit = .millisecond, .increments = &.{ 1, 5, 10, 20, 25, 30, 50, 100, 86_400_000 } },
        .{ .unit = .microsecond, .increments = &.{ 1, 5, 10, 20, 25, 30, 50, 100 } },
        .{ .unit = .nanosecond, .increments = &.{ 1, 5, 10, 20, 25, 30, 50, 100, 1_000_000_000 } },
    };
    for (cases) |case| for (case.increments) |increment| {
        _ = try instant.round(.{ .smallestUnit = case.unit, .roundingIncrement = increment });
    };
    for ([_]Case{
        .{ .unit = .hour, .increments = &.{24} },
        .{ .unit = .minute, .increments = &.{1440} },
        .{ .unit = .second, .increments = &.{86400} },
        .{ .unit = .millisecond, .increments = &.{86_400_000} },
    }) |case| {
        const actual = try instant.round(.{ .smallestUnit = case.unit, .roundingIncrement = case.increments[0] });
        try std.testing.expect(Instant.equals(next_day, actual));
    }
    for ([_]Case{
        .{ .unit = .hour, .increments = &.{ 0, 7, 25 } },
        .{ .unit = .minute, .increments = &.{ 7, 1441 } },
        .{ .unit = .second, .increments = &.{ 7, 86401 } },
        .{ .unit = .nanosecond, .increments = &.{1_000_000_001} },
    }) |case| for (case.increments) |increment| {
        try std.testing.expectError(error.RangeError, instant.round(.{ .smallestUnit = case.unit, .roundingIncrement = increment }));
    };
    try std.testing.expectError(error.RangeError, (try ztemporal.PlainTime.init(12, 0, 0, 0, 0, 0)).round(.{ .smallestUnit = .minute, .roundingIncrement = 1440 }));
}
