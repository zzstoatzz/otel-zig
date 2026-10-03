> adopted from the notes repo during the 2026-08-23 curation pass; project design/retro content lives with its project.

# otel-zig span-processor performance & threading

hard-won lessons from the `BatchSpanProcessor` in `otel-zig` (our zig OTLP
SDK), found while chasing a downstream latency regression: the `/wrapped`
endpoint of [leaflet](https://leaflet.pub) (an atproto publishing platform)
was 13.5s under a 24-way concurrent burst while every individual query was
sub-millisecond.

## the lock-convoy bug (fixed 2026-06-26, otel-zig zig-0.16 `3dd08a8`)

`onEnd` held the processor mutex across `SpanData.initOwned` — a **deep heap
copy** of the span name and every attribute. For DB/HTTP instrumentation those
attributes are large strings (full SQL statements, URLs). Cloning under the lock
serializes every concurrent `onEnd`, and on a box with few cores a thread
**preempted mid-copy stalls every other span-ending thread**. The result is a
classic lock convoy: a flood of sub-ms spans collapses into multi-second tail
latency. Downstream symptom: 14 spans/request × 24 concurrent requests → seconds
of *inter-span* gaps in the trace, even though each span's own duration was ~0.

**Fix:** clone *before* taking the lock; hold the lock only for the
shutdown/capacity re-check + the pointer append. Free the clone on every drop
path (shutdown raced, queue full, append failure). The expensive work is now
fully parallel; the critical section is O(1).

General rule: **never hold a shared lock across an allocation / deep copy / any
unbounded work.** Do the heavy work on stack/local state, take the lock only to
splice the finished result into shared structure.

## diagnosing "slow endpoint, fast queries" — isolate every layer

The trap is to blame the obvious thing (the queries, then the machine). Prove
each layer instead. What actually localized it:

- **machine:** burst a trivial endpoint (`/health`, no DB, no spans) at the same
  concurrency. 24× `/health` = 150ms ⇒ the box handles concurrency fine.
- **the pool / the allocator:** micro-benchmark each in isolation with 1 vs N
  threads. Read pool = 3µs/query @ 24 threads; arena-on-page_allocator =
  0.01ms/req @ 24 threads ⇒ neither convoys.
- **the queries:** sum the per-query span durations (logfire `db.local.query`):
  280ms total ⇒ not the SQL.
- **scaling shape is the tell:** 8 concurrent = 5.9s, 24 = 13.5s — **superlinear**.
  Pure CPU saturation is ~linear (work-conserving); worse-than-linear means
  **lock contention**, threads actively blocking each other.
- what remained after eliminating machine/pool/alloc/queries was the one thing
  the benches didn't exercise (logfire is inert in unit tests): the per-query
  span lifecycle. By elimination → the processor lock.

## mutex choice: span processors own a real OS thread → `std.Thread.Mutex` is wrong on 0.16

`std.Thread.Mutex` **does not exist in zig 0.16** (removed; `std.Io.Mutex`
replaces it — see [io/synchronization](../io/synchronization.md)). A processor
spawns its *own* plain `std.Thread` for the export loop, so its mutex is touched
by both that plain thread and whatever ends spans. The synchronization note's
SIGSEGV rule applies: an **Evented** `Io.Mutex` touched by a plain `std.Thread`
segfaults (`Thread.current()` is null off Uring-managed threads). So:

- on **0.16**, use `Io.Mutex`; it is safe from a plain export thread **as long as
  the app's Io is Threaded** (a Threaded futex works from any plain thread). This
  is what the `zig-0.16` line does.
- a fully Io-agnostic processor would run its export loop via `io.async` instead
  of `std.Thread.spawn`, so all mutex users share one Io. Not done yet — current
  design assumes Threaded.

## otel-zig branch topology (don't fix the wrong line)

The repo carries two parallel lines off base `1ba5a15`:

| branch | zig | mutex | protobuf dep | who uses it |
|---|---|---|---|---|
| `trunk` | 0.15 | `std.Thread.Mutex` | `Arwalk/zig-protobuf` master | the 0.15 maintenance line; **does not build on 0.16** (`std.process.getEnvVarOwned` gone + no `std.Thread.Mutex`) |
| `zig-0.16` | 0.16 | `std.Io.Mutex` | `zzstoatzz/zig-protobuf` `zig-0.16` fork (protobuf 4.0.0) | `logfire-zig` 0.2.3 pins `d369ad2` here; leaflet/typeahead compile this |
| `main` from `v0.1.0-alpha.1` | 0.17 | `std.Io.Mutex` | `Arwalk/zig-protobuf` `zig-master` (protobuf 5.0.0) | the last 0.16 commit on `main` is tagged `v0.0.2` |

The "pinned-protobuf-breaks-on-0.16" smell is a **trunk-only** artifact — the
0.16 line already uses the fork. Always confirm which branch a dependency pins
(`grep otel build.zig.zon` → commit → `git branch --contains`) before "fixing"
build breakage. Downstream consumers (logfire-zig → leaflet) bump at their
leisure via the normal dep-hash chain; the library is the thing to keep correct.
