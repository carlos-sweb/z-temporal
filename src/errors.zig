//! ECMAScript exception names for semantic failures; host failures remain distinct.
pub const TemporalError = error{ RangeError, TypeError, OutOfMemory, IoError };
