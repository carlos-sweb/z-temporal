const std = @import("std");
const ztemporal = @import("ztemporal");
const Now = ztemporal.Now;
const Instant = ztemporal.Instant;

test "public API: instant() returns a plausible, forward-moving current time" {
    const a = Now.instant();
    // A generous sanity window: strictly after 2020-01-01 and strictly
    // before 2100-01-01, so this test only fails if the clock (or this
    // library's epoch math) is genuinely broken, not due to test-runner
    // clock skew.
    const min = try Instant.parseIso("2020-01-01T00:00:00Z");
    const max = try Instant.parseIso("2100-01-01T00:00:00Z");
    try std.testing.expectEqual(std.math.Order.gt, Instant.compare(a, min));
    try std.testing.expectEqual(std.math.Order.lt, Instant.compare(a, max));

    const b = Now.instant();
    try std.testing.expect(Instant.compare(b, a) != .lt);
}

test "public API: zonedDateTimeISO/plainDateISO/plainTimeISO/plainDateTimeISO with an explicit zone" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const z = try Now.zonedDateTimeISO(allocator, io, "America/New_York");
    try std.testing.expect(try z.year(allocator, io) >= 2026);

    const d = try Now.plainDateISO(allocator, io, "America/New_York");
    try std.testing.expect(d.iso_year >= 2026);

    const t = try Now.plainTimeISO(allocator, io, "America/New_York");
    try std.testing.expect(t.hour < 24);

    const dt = try Now.plainDateTimeISO(allocator, io, "America/New_York");
    try std.testing.expect(dt.date.iso_year >= 2026);
}

test "public API: timeZoneId resolves /etc/localtime when no TZ env is given" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const id = try Now.timeZoneId(allocator, io, null);
    defer allocator.free(id);
    try std.testing.expect(id.len > 0);
}
