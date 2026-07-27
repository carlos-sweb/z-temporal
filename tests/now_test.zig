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
