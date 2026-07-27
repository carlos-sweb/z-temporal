# Z-TEMPORAL

[![Zig Version](https://img.shields.io/badge/zig-0.16-orange.svg)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

The TC39 [Temporal](https://tc39.es/proposal-temporal/) API (calendar dates, wall-clock times, and their combinations) implemented from scratch in pure Zig — part of the [z-*](https://github.com/carlos-sweb) micro-library ecosystem, and the natural successor to [`z-date`](https://github.com/carlos-sweb/z-date) (same domain: calendar/datetime math). Nothing JS-specific lives here (no `JSValue`, no engine coupling): a plain sibling library, reusable anywhere ISO calendar math is useful. Every result in this repo has been cross-checked against real Node.js's native `Temporal` implementation (Node 26+ ships it without a flag).

## Scope

This is a large API, built in phases. **Phase 1** covers `PlainDate`/`PlainTime`/`PlainDateTime` construction, parsing/formatting, and field access — the ISO calendar only, no arithmetic yet. **Phase 2** adds `Duration`. **Phase 3a (current)** adds `.add()`/`.subtract()` on the 3 Phase 1 types.

**Supported (Phase 3a):**
- `PlainDate`/`PlainTime`/`PlainDateTime.add()`/`.subtract()` (consuming a `Duration`): years/months applied first (with `overflow` clamp/reject on the resulting day-of-month, default `"constrain"`), then weeks/days/time folded into a single epoch-day step. `PlainDate.add`'s duration-time-to-days conversion **truncates toward zero** (no existing time-of-day to combine with); `PlainDateTime.add` instead **floors** (must land in a canonical `[0,24h)` time-of-day) — both ground-truthed, not assumed, via targeted A/B cases against real Node. `PlainTime.add`/`.subtract` are pure mod-24h wraparound: no `overflow` parameter (nothing can overflow) and silently ignores any years/months/weeks/days on the duration (no date component to apply them to).
- `.until()`/`.since()`/`.round()` on the Plain types, and `Duration.round()`/`.total()`, are still **not** included — see below.

**Supported (Phase 2):**
- `Duration` (`years`/`months`/`weeks`/`days`/`hours`/`minutes`/`seconds`/`milliseconds`/`microseconds`/`nanoseconds`, all `i64`): `.create()`/`.parseIso()`/`.withFields()`, `.sign()`/`.blank()`/`.negated()`/`.abs()`, `.add()`/`.subtract()` (full integer balancing — ground-truthed that these never accept a years/months/weeks operand, regardless of `relativeTo`, so no calendar dependency at all here), `.compare()` (a fields-equal fast path, plus non-calendar-unit comparison by total nanoseconds — the calendar-ambiguous case needs `relativeTo`/`PlainDate` arithmetic and is `error.NeedsRelativeTo` until a future phase), `.toIsoString()`/`.parseIso()` (full ISO 8601 duration grammar, including the fractional-designator cascade — `"PT1.5H"` → `{hours:1, minutes:30}` — and the display-time seconds/ms/µs/ns merge).

**Supported (Phase 1):**
- `PlainDate` (`iso_year`/`iso_month`/`iso_day`): `.create()`/`.parseIso()`/`.withFields()`, `.compare()`/`.equals()`, getters (`.year()`/`.month()`/`.day()`/`.monthCode()`/`.dayOfWeek()`/`.dayOfYear()`/`.daysInMonth()`/`.daysInYear()`/`.monthsInYear()`/`.inLeapYear()`/`.weekOfYear()`), `.toIsoString()`.
- `PlainTime` (`hour`/`minute`/`second`/`millisecond`/`microsecond`/`nanosecond`, nanosecond precision): `.create()`/`.parseIso()`/`.withFields()`, `.compare()`/`.equals()`, `.toIsoString()`.
- `PlainDateTime` (a `PlainDate` + `PlainTime` pair): `.create()`/`.parseIso()`/`.withFields()`, `.toPlainDate()`/`.toPlainTime()`, `.compare()`/`.equals()`, `.toIsoString()`.
- ISO 8601 calendar math (`iso_calendar.zig`, all independently usable): leap years, days-in-month/year, day-of-week (Temporal's 1=Monday..7=Sunday numbering), day-of-year, **ISO 8601 week numbering** (`weekOfYear`/`yearOfWeek`, including the year-boundary redirect — a date's ISO week-year can differ from its calendar year), epoch-day conversion.
- ISO 8601 string grammar (`iso_string.zig`): the "extended" (separator-containing) format only — `YYYY-MM-DD`, `HH:MM[:SS[.fraction]]`, signed 6-digit extended years outside `[0,9999]`, calendar annotations (`[u-ca=iso8601]`, validated), timezone-name/offset annotations (parsed and discarded, a later phase's concern).
- `.from()`/`.with()`-style `overflow` handling matches real Temporal exactly (ground-truthed against Node, not assumed): `PlainDate`'s month/day **lower bound always rejects** regardless of overflow mode (only the upper bound — month>12, day>daysInMonth — respects `constrain` vs `reject`); `PlainTime`'s fields clamp **symmetrically** on both bounds under `constrain`. Plain constructors always behave as `reject` (there is no `overflow` option on `new Temporal.PlainDate(...)` itself).

**Explicitly NOT included yet** (later phases, tracked in the wider z-* engine project's roadmap, not oversights):
- `.until()`/`.since()` on `PlainDate`/`PlainTime`/`PlainDateTime` — needs a calendar-aware date-diff-and-balance algorithm plus a full rounding-mode framework (`roundingIncrement`/`roundingMode`/`smallestUnit`/`largestUnit`), test262's single largest cluster in this API (Phase 3b).
- `.round()` on `PlainTime`/`PlainDateTime`, and `Duration.round()`/`.total()` and `.toString()`'s rounding options (`smallestUnit`/`roundingMode`/`fractionalSecondDigits`) — need that same rounding-mode framework (Phase 3c).
- `Duration`'s JS-object-protocol members (`toLocaleString`/`valueOf`/`Symbol.toStringTag`) and a property-bag `.from()` dispatcher — same JS-decoupling stance as `PlainDate` below.
- `PlainYearMonth`/`PlainMonthDay`.
- `Instant` (epoch nanoseconds) and `Temporal.Now`.
- `ZonedDateTime` and real IANA timezone integration (`z-date`'s `tzdata.zig`/`PosixTz` parsing logic is the intended reuse target, but needs its process-global timezone model changed to a per-value one first).
- Non-ISO calendars (hebrew/chinese/islamic/japanese-eras/...) — `Temporal.Calendar`/`Temporal.TimeZone` as separate customizable objects don't exist in the current spec/test262 at all anymore (post-2024 simplification); only string identifiers do. A calendar annotation naming anything other than `"iso8601"` is a documented `error.InvalidFormat` for now, not silently wrong.
- The separator-less ISO "basic" format (`20240229`) — genuinely ambiguous with `PlainMonthDay` per real spec (confirmed: `Temporal.PlainTime.from('0102')` throws in real Node too), out of scope until a real disambiguation pass is designed.
- No JS/engine wiring at all (`z-value`/`z-interpreter`) — this repo only produces/consumes plain Zig values; a property bag / JS options object is a JS-level concept that belongs in the eventual wiring phase, the same way `z-buffer`/`z-bigint` stayed JS-decoupled until their own wiring phases.

## Design

- `iso_calendar.zig`: `isLeapYear(year) bool`, `daysInMonth(year, month: 1-12) u8`, `daysInYear(year) u16`, `dayOfWeek(year,month,day) u8` (1=Mon..7=Sun), `dayOfYear(year,month,day) u16`, `weekOfYear(year,month,day) WeekOfYear{week,year}`, `toEpochDay`/`fromEpochDay`, `MIN_ISO_YEAR`/`MAX_ISO_YEAR`, `isInRange`.
- `iso_string.zig`: `parsePlainDate`/`parsePlainTime`/`parsePlainDateTime(text) TemporalError!...`, `formatYear`/`formatFractionalSeconds` (shared formatting helpers).
- `plain_date.zig` / `plain_time.zig` / `plain_date_time.zig`: the 3 Phase 1 types.
- `duration.zig`: the `Duration` type — 10 `i64` fields, `IsValidDuration`-style validation (sign consistency, `2^32-1` per-calendar-field bound, `2^53*10^9-1` combined-time-part-nanoseconds bound — all 3 bounds reverse-engineered by bisection against real Node, not derived from spec text), `add`/`subtract`'s largest-unit-preserving balancing.
- `duration_string.zig`: `Duration`'s own ISO 8601 grammar (materially different from `iso_string.zig`'s — sign only once at the front, integer-only date-part designators, a fraction only on the single last-present time designator, cascaded down into smaller units at parse time).
- `errors.zig`: `TemporalError{InvalidRange, InvalidFormat, InvalidField, MixedCalendarUnits, NeedsRelativeTo, OutOfMemory}` — plain Zig errors, no JS coupling.

## A real Zig 0.16 `std.fmt` bug this library works around

Same one `z-date`'s `formatting.zig` documents: `std.fmt`'s zero-width-padded placeholder (`{d:0>N}`) prepends a spurious `+` to a *signed* integer even when its value is non-negative. `formatYear`'s 4-digit branch casts to `u32` before formatting instead of formatting the `i32` year directly — caught immediately by this repo's own Node cross-check tests (`"2024"` vs the wrongly-produced `"+2024"`).

## Usage

```zig
const ztemporal = @import("ztemporal");
const PlainDate = ztemporal.PlainDate;

const d = try PlainDate.create(2024, 2, 29, .reject);
std.debug.print("{d}\n", .{d.dayOfWeek()}); // 4 (Thursday)

const allocator = ...;
const s = try d.toIsoString(allocator, false); // "2024-02-29"
defer allocator.free(s);

const parsed = try PlainDate.parseIso("2024-02-29[u-ca=iso8601]");
```
