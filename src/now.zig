//! `Temporal.Now`, scoped to `instant()` only this phase -- every other
//! Now function needs a real local/named timezone offset to avoid being
//! silently wrong on a non-UTC system, and this repo defers real IANA
//! timezone integration to `ZonedDateTime` (item 20's phase 7). See the
//! Phase 6 plan for the full derivation.
const std = @import("std");
const instant_mod = @import("instant.zig");
const Instant = instant_mod.Instant;

/// Current wall-clock time. Ground-truthed Zig 0.16 has no portable
/// timestamp API (`std.time.nanoTimestamp` etc. were removed -- the
/// replacement needs an `std.Io` instance); uses the same raw Linux
/// `clock_gettime` syscall `z-interpreter`/`z-value`'s Date wiring
/// already established as this ecosystem's answer to that gap
/// (documented there as Linux-only "for now, like the dev setup").
pub fn instant() Instant {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    const ns: i128 = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
    // Always in Instant's representable range for any real wall-clock
    // time -- `fromEpochNanoseconds` only rejects far outside it -- so
    // `catch unreachable` here, matching how this repo's other
    // always-succeeds paths are written, rather than threading a
    // TemporalError a real clock read can't actually produce.
    return Instant.fromEpochNanoseconds(ns) catch unreachable;
}
