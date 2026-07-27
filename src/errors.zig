//! Zig error set for this repo -- no JS coupling. The z-interpreter wiring
//! phase (not part of this repo) maps these to real JS `RangeError`s the
//! same way `bufferErr`/`bigintErr` already do for z-buffer/z-bigint.
pub const TemporalError = error{
    /// A field is outside its valid range (month 13, day 32, hour 24, ...)
    /// and `overflow: "reject"` was requested (or the caller is a
    /// constructor, which always rejects -- no `overflow` option there).
    InvalidRange,
    /// A calendar id other than "iso8601" was requested (non-ISO calendars
    /// are a later phase) or an ISO string failed to parse.
    InvalidFormat,
    /// A property bag is missing a required field, or has a field of the
    /// wrong type/shape (e.g. a non-integer where an integer is required).
    InvalidField,
    /// `Duration.add`/`.subtract` with a calendar-unit (year/month/week)
    /// operand -- unconditionally unsupported by real Temporal, regardless
    /// of any `relativeTo`, not merely deferred.
    MixedCalendarUnits,
    /// `Duration.compare` between two durations that both carry calendar
    /// units and aren't field-for-field equal -- resolvable only with a
    /// `relativeTo` and calendar-aware balancing (`PlainDate` arithmetic,
    /// a later phase), unlike `MixedCalendarUnits`.
    NeedsRelativeTo,
    OutOfMemory,
};
