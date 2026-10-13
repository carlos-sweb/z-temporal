# Migrating to Z-Temporal 0.1.0

Requires Zig 0.17.0. This release changes API names and signatures to follow Temporal.

## Methods and options

| Previous API | 0.1.0 |
| --- | --- |
| `create(..., overflow)` | `init(..., null)` for rejecting calendar-aware constructors; `from(.{ .fields = ... }, .{ .overflow = ... })` for field regulation |
| `parseIso(text)` | `from(.{ .string = text }, options)`; Instant and Duration do not take from-options |
| `withFields(...)` | `with(fields, options)`; Duration uses `with(fields)` |
| `toIsoString(allocator, ...)` | `toString(allocator, options)` |
| `largest_unit`, `smallest_unit` | `largestUnit`, `smallestUnit` |
| `rounding_increment`, `rounding_mode` | `roundingIncrement`, `roundingMode` |
| `.half_expand` and other half modes | `.halfExpand`, `.halfCeil`, `.halfFloor`, `.halfTrunc`, `.halfEven` |
| `Now.instant()` | `Now.instant(io)` |
| Duration `round(relativeTo, options)` | `round(.{ .relativeTo = ..., ... })` |
| Duration `total(relativeTo, unit)` | `total(.{ .relativeTo = ..., .unit = ... })` |
| Duration `compare(a, b)` | `compare(a, b, options)` |

ZonedDateTime string/field construction now uses `from(allocator, io, input, options)`. Partial ZonedDateTime updates use `with(allocator, io, fields, options)`.

`PlainYearMonth.init(year, month, calendar, referenceISODay)` and `PlainMonthDay.init(month, day, calendar, referenceISOYear)` take the same calendar/reference arguments as JavaScript; pass `null` for the defaults. PlainDate, PlainDateTime, and ZonedDateTime constructors take an optional final calendar argument. PlainTime, Instant, and Duration constructors have no calendar argument. Constructors preserve explicit references, while `from` performs Temporal normalization.

## Errors and numbers

Replace catches of `InvalidRange`, `InvalidFormat`, `InvalidTimeZone`, `AmbiguousTime`, `MixedCalendarUnits`, and `NeedsRelativeTo` with `RangeError`, as appropriate to the operation. Invalid/missing field protocol conditions use `TypeError`. Host failures remain separate. Do not mechanically classify every field failure as TypeError: out-of-range field values are RangeError.

Duration components are now `f64`, matching JavaScript Number. Integer calculations remain exact internally until conversion to a Number component. Instant and ZonedDateTime expose exact `epochNanoseconds()`; their representation field is named `epochNs`.

`PlainDate.weekOfYear()` now returns the week number rather than a `{week, year}` record. Use `yearOfWeek()` for the accompanying year. Both return optional values because non-ISO calendars have no ISO week numbering.

Month-code buffers must be `[4]u8`. Plain conversions that can validate ranges or allocate calendar metadata now return error unions; add `try` at those call sites.

## Formatting and runtime resources

Use `toJSON` for Temporal's default serialization, independent of display options. `toString` accepts precision and calendar/zone visibility options. Allocated strings must be freed by the caller.

Timezone arithmetic requires explicit allocator/I/O arguments. Zoned Duration references carry these resources in the operation options. `Now` uses Zig's portable real clock; pass `null` as the optional zone to detect the system zone.

Enable non-ISO calendars and localization with `-Dintl=true`. Consumers of the build module receive its ICU linkage; ISO-only builds have no ICU dependency. Keep ICU versions aligned with the reference Node version when comparing localized strings.
