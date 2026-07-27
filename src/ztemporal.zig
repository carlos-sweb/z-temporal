//! `z-temporal` -- the TC39 Temporal API implemented from scratch in pure
//! Zig. Phase 1: PlainDate/PlainTime/PlainDateTime, ISO calendar only, no
//! arithmetic. Phase 2: Duration (construction/validation, add/subtract,
//! non-calendar compare, ISO string parse/format). Phase 3a: add/subtract
//! on the 3 Phase 1 types. Phase 3b: until/since on the 3 Phase 1 types,
//! with the full rounding-mode framework (rounding.zig). Phase 3c
//! (current, closes out "Phase 3: arithmetic"): round() on PlainTime/
//! PlainDateTime, Duration.round()/.total(). See README.md's Scope
//! section for the full phased roadmap and what's deliberately not here
//! yet (including two narrow, documented Phase 3c gaps).
const std = @import("std");

pub const iso_calendar = @import("iso_calendar.zig");
pub const iso_string = @import("iso_string.zig");
pub const errors = @import("errors.zig");
pub const TemporalError = errors.TemporalError;

const plain_date = @import("plain_date.zig");
const plain_time = @import("plain_time.zig");
const plain_date_time = @import("plain_date_time.zig");
const duration = @import("duration.zig");
pub const duration_string = @import("duration_string.zig");
const rounding = @import("rounding.zig");

pub const Overflow = plain_date.Overflow;
pub const PlainDate = plain_date.PlainDate;
pub const PlainTime = plain_time.PlainTime;
pub const PlainDateTime = plain_date_time.PlainDateTime;
pub const Duration = duration.Duration;
pub const Unit = rounding.Unit;
pub const RoundingMode = rounding.RoundingMode;
pub const RoundingOptions = rounding.RoundingOptions;
pub const RoundOptions = rounding.RoundOptions;

test {
    std.testing.refAllDecls(@This());
}
