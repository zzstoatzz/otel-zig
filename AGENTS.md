# otel-zig

Use the Zig version pinned in `build.zig.zon`. The OpenTelemetry specification
and protobuf definitions are available in `spec/` and `opentelemetry-proto/`.
Read [examples](examples/README.md) for API usage rather than copying cached paths.

## build and checks

- `zig build` builds libraries and examples; `zig build test` runs unit tests.
- `zig build test-api`, `test-sdk` and `test-exporters` select layers.
- `zig build --verbose example-multithreaded-http -- console 20 1.0` exercises
  all signals; the `otlp` mode requires a configured collector.
- Use `zig build -l` to discover targets. Prefer build targets over standalone
  `zig run`/`zig test`, which require explicit module dependency wiring.

## ownership

API values are non-owning by default. Document lifetimes and use owned clones
when data must outlive its caller. Buffering exporters and processors own copies.
A builder's `finish` releases the builder; `build` does not. Both return owned data.

Providers own processors; processors own exporters. Preserve both `deinit` and
`destroy` in the cleanup chain established through `flowTo`. A span's `end`
finishes recording; `deinit` releases memory. Do not conflate them.

Tests use the SDK's collecting exporters and `MockErrorHandler` to assert errors
and emitted records. Keep API interfaces independent of SDK implementation.
Preserve the `CLAUDE.md` link to this shared instruction source.
