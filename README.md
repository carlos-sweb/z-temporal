# Z-Temporal

[![Zig](https://img.shields.io/badge/zig-0.17-orange.svg)](https://ziglang.org/)

A typed Zig implementation of the [TC39 Temporal API](https://tc39.es/proposal-temporal/). Public methods and options use JavaScript names: `from`, `with`, `toString`, `toJSON`, `smallestUnit`, `roundingMode`, and `relativeTo`.

Version 0.1.0 changes the public API. See [MIGRATION.md](MIGRATION.md).

## Release 0.2.1

- `PlainMonthDay.toString` keeps the ISO reference year for non-ISO calendars
  when `calendarName` is `never`, while omitting the calendar annotation.
- The four `calendarName` modes have native regression coverage.

## Release 0.2.0

- PlainTime ignores calendar identifiers in ISO string annotations, including
  unknown identifiers and critical calendar annotations. Malformed annotations
  and unsupported critical non-calendar extensions still produce RangeError.
- Instant.round accepts rounding increments that divide a full 24-hour day,
  rather than limiting minutes and seconds to their clock-field cycles.
  The shared rounding-increment option limit remains 1,000,000,000.
- Regression coverage addresses four PlainTime and three Instant Test262 failures,
  with additional comparisons against native Node Temporal. All seven original
  tests pass with z-interpreter v0.2.0 in an isolated build using this release.

These fixes require consumers to update their z-temporal dependency. They do not
complete the JavaScript bindings in z-interpreter or establish full Test262 parity.

## API documentation

Browse the [Zig API docs](https://carlos-sweb.github.io/z-temporal/). GitHub Pages rebuilds them automatically on each push to `master`.

Generate the documentation locally with Zig 0.17.0:

```sh
zig build docs
python3 -m http.server 8000 --directory zig-out/docs
```

Open `http://localhost:8000/`. The docs include the public types, signatures, source, and doc comments. Optional ICU APIs use the same signatures; enable them in your application with `-Dintl=true`.

## Requirements

- Zig 0.17.0.
- IANA TZif files for named zones, normally `/usr/share/zoneinfo`.
- Node 26.5.0 for the reproducible differential suite; normal Zig tests do not need Node.
- ICU development libraries only when building with `-Dintl=true`. ISO calculations, fixed offsets, and named-zone Temporal algorithms remain in Zig.

The `z-date` dependency is pinned and fetched automatically. Returned strings belong to the supplied allocator. Temporal values themselves require no `deinit`.

## Using the API

`init` corresponds to a JavaScript constructor and rejects invalid fields. `from` accepts a tagged string, value, or fields input. Field construction defaults to `overflow: .constrain`; string parsing rejects invalid dates independently of overflow. `with` accepts a partial field struct and options.

```zig
const std = @import("std");
const Temporal = @import("ztemporal");

test "date construction and arithmetic" {
    const date = try Temporal.PlainDate.from(.{ .fields = .{
        .year = 2024, .monthCode = "M02", .day = 29,
    } }, .{});
    const changed = try date.with(.{ .month = 3 }, .{});
    const next = try changed.add(.{ .days = 1 }, .constrain);
    const text = try next.toString(std.testing.allocator, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("2024-03-30", text);
}
```

Timezone-dependent operations take an allocator and `std.Io` explicitly. Date units follow the local calendar; time units advance the exact instant.

```zig
const std = @import("std");
const Temporal = @import("ztemporal");

test "one calendar day differs from 24 hours" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const start = try Temporal.ZonedDateTime.from(allocator, io,
        .{ .string = "2024-03-09T12:00[America/New_York]" }, .{});
    const next = try start.add(allocator, io, .{ .days = 1 }, .constrain);
    const elapsed = try start.until(allocator, io, next, .{ .largestUnit = .hour });
    try std.testing.expectEqual(@as(f64, 23), elapsed.hours);
}
```

## API coverage

| Type | Operations |
| --- | --- |
| `Instant` | `init`, `from`, `fromEpochMilliseconds`, `fromEpochNanoseconds`, epoch getters, `compare`, `equals`, `add`, `subtract`, `until`, `since`, `round`, `toZonedDateTimeISO` |
| `PlainDate` | `init`, `from`, `with`, `withCalendar`, getters, `compare`, `equals`, `add`, `subtract`, `until`, `since`, conversions to date-time, zoned date-time, year-month, and month-day |
| `PlainTime` | `init`, `from`, `with`, time fields, `compare`, `equals`, `add`, `subtract`, `until`, `since`, `round` |
| `PlainDateTime` | `init`, `from`, `with`, `withPlainTime`, `withCalendar`, getters, comparisons, arithmetic, differences, `round`, Plain conversions and `toZonedDateTime` |
| `PlainYearMonth` | `init`, `from`, `with`, getters, `compare`, `equals`, arithmetic, differences and `toPlainDate` |
| `PlainMonthDay` | `init`, `from`, `with`, getters, `equals` and `toPlainDate`; Temporal defines no arithmetic or ordering for this type |
| `Duration` | `init`, `from`, `with`, fields, `sign`, `blank`, `negated`, `abs`, `compare`, `add`, `subtract`, `round`, `total` |
| `ZonedDateTime` | construction, `with`, `withPlainTime`, `withTimeZone`, `withCalendar`, getters, comparisons, arithmetic, differences, `round`, Plain conversions, `toInstant`, `startOfDay`, `hoursInDay`, `getTimeZoneTransition` |
| `Now` | `instant`, `timeZoneId`, `zonedDateTimeISO`, `plainDateTimeISO`, `plainDateISO`, `plainTimeISO` |

Every value type exposes `toString`, `toJSON`, and optional-ICU `toLocaleString`. Getters are methods where Zig allows them; `PlainTime` and `Duration` components are fields. `compare` returns `std.math.Order`, corresponding to JavaScript's -1/0/1.

`PlainYearMonth.init(year, month, calendar, referenceISODay)` and `PlainMonthDay.init(month, day, calendar, referenceISOYear)` accept `null` for their constructor defaults. PlainDate, PlainDateTime, and ZonedDateTime constructors also take an optional final calendar argument; pass `null` for ISO. Constructor date fields describe the underlying ISO date, as in JavaScript. `from` normalizes reference dates according to its own rules.

`StringOptions` provides `smallestUnit`, `fractionalSecondDigits`, `roundingMode`, `calendarName`, `timeZoneName`, `offset`, and an optional output `timeZone` for `Instant`. Supply `io` in these options when an Instant's output zone requires lookup. `null` represents the automatic precision/default largest unit; enum options are typed instead of accepting arbitrary strings.

`Duration.compare`, `round`, and `total` accept options with a tagged `relativeTo`: `.plainDate`, `.plainDateTime`, or `.zonedDateTime`. A plain date-time reference follows Temporal's date-only interpretation. For a zoned reference, include `allocator` and `io` in the options. Duration fields use `f64` to reproduce JavaScript Number conversion and precision; Instant nanoseconds remain exact `i128`.

## Calendars and localization

With `-Dintl=true`, field construction and calendar annotations support `buddhist`, `chinese`, `coptic`, `dangi`, `ethioaa`, `ethiopic`, `gregory`, `hebrew`, `indian`, `islamic-civil`, `islamic-tbla`, `islamic-umalqura`, `japanese`, `persian`, `roc`, and `iso8601`. Generic `islamic` and `islamic-rgsa` are rejected, matching the reference Node version.

Calendar-aware fields include `calendar`, `monthCode`, and paired `era`/`eraYear` where applicable. Calendar data is cached in values when constructed, so getters do not allocate. Month codes need a `[4]u8` buffer to include leap codes such as `M05L`. Week-number getters return optional values; non-ISO calendars have no ISO week number.

`toLocaleString` uses a locale string (or `null` for `en-US`) and typed `LocaleOptions`. Date/time options cover calendar, time zone, date/time styles, year/month/day/weekday/era, time components, fractional seconds, and hour cycle. Duration localization uses `DurationLocaleOptions` with `long`, `short`, `narrow`, or `digital` style. Localized output depends on ICU/CLDR versions.

Without ICU, non-ISO calendars produce `RangeError` and localized formatting produces `TypeError`; ISO serialization continues to work. This is an explicit build capability boundary.

## Errors

Semantic failures use `error.RangeError` or `error.TypeError`, selected by the corresponding Temporal operation. Parsing errors are `RangeError`, not `SyntaxError`. Missing required fields and empty `with` inputs produce `TypeError` where required by the specification. Allocation and host-data failures remain `OutOfMemory` and `IoError`.

Error messages and JavaScript stack traces are outside the typed Zig API. Construct values through public constructors and operations; direct mutation of representation fields bypasses invariants.

## Verification

```sh
zig build test
zig build test -Doptimize=safe
zig build test-parity
zig build test -Dintl=true
zig build test-parity -Dintl=true
zig fmt --check build.zig src tests
```

`test-parity` runs a deterministic catalog against native Node Temporal and compares serialized results, duration components, getters, numeric totals, and exception names. The catalog covers grammar, all nine rounding modes, backward differences, calendar fractions, Number precision, DST and fixed zones, calendar reference dates, and optional ICU calendars/localization. README examples are compiled as tests.

For the exact reference data versions:

```sh
bash scripts/setup-parity-data.sh
zig build test-parity -Dintl=true \
  -Dicu-prefix="$PWD/.zig-cache/parity-data/icu/usr/local" \
  -Dtzdata-dir="$PWD/.zig-cache/parity-data/zoneinfo"
```

`-Dicu-prefix` selects ICU headers and libraries together. `-Dtzdata-dir` selects an absolute TZif database path; keep the selected database immutable while values are in use. CI pins Node 26.5.0, ICU 78.3, and tzdata 2026b. The catalog is regression coverage, not a claim that every test262 case has been ported.

## JavaScript runtime boundary

This library supplies Temporal values and algorithms. A JavaScript engine adapter must supply prototypes, symbols, property access/getters, receiver-brand checks, coercions, arbitrary property bags, locale-list negotiation, and JavaScript exceptions. These are intentionally excluded from the typed API and from its parity catalog.
