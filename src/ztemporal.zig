//! Typed TC39 Temporal values, algorithms, and optional ICU calendar/localization support.
const std = @import("std");

pub const iso_calendar = @import("iso_calendar.zig");
pub const iso_string = @import("iso_string.zig");
pub const errors = @import("errors.zig");
pub const TemporalError = errors.TemporalError;

const plain_date = @import("plain_date.zig");
const plain_time = @import("plain_time.zig");
const plain_date_time = @import("plain_date_time.zig");
const plain_year_month = @import("plain_year_month.zig");
const plain_month_day = @import("plain_month_day.zig");
const instant_mod = @import("instant.zig");
const zoned_date_time_mod = @import("zoned_date_time.zig");
const duration = @import("duration.zig");
pub const duration_string = @import("duration_string.zig");
const rounding = @import("rounding.zig");

pub const Overflow = plain_date.Overflow;
pub const PlainDate = plain_date.PlainDate;
pub const PlainTime = plain_time.PlainTime;
pub const PlainDateTime = plain_date_time.PlainDateTime;
pub const PlainYearMonth = plain_year_month.PlainYearMonth;
pub const PlainMonthDay = plain_month_day.PlainMonthDay;
pub const Instant = instant_mod.Instant;
pub const ZonedDateTime = zoned_date_time_mod.ZonedDateTime;
pub const OffsetOption = zoned_date_time_mod.OffsetOption;
pub const Disambiguation = zoned_date_time_mod.Disambiguation;
pub const Now = @import("now.zig");
pub const Duration = duration.Duration;
pub const Unit = rounding.Unit;
pub const RoundingMode = rounding.RoundingMode;
pub const RoundingOptions = rounding.RoundingOptions;
pub const RoundOptions = rounding.RoundOptions;

test {
    std.testing.refAllDecls(@This());
}

pub const StringOptions = @import("format_options.zig").StringOptions;
pub const CalendarName = @import("format_options.zig").CalendarName;
pub const TimeZoneName = @import("format_options.zig").TimeZoneName;

pub const LocaleOptions = @import("locale.zig").LocaleOptions;
pub const intlEnabled = @import("build_options").intl;

pub const DurationLocaleOptions = @import("locale.zig").DurationLocaleOptions;

pub const intlDataVersion = @import("locale.zig").dataVersion;
