# TODO - OpenTelemetry Zig Implementation

# Tracer

- [X] Switch the OTLP exporter to use Protobuf instead of JSON.
- [ ] Update the trace ID ratio sampling.
  - Make the descriptions align with the spec requirements
  - Validate the ratio algo
  - support more from the trace state.
- [ ] Update the parent sampling decorator.
  - Add support for overriding the parent set decisions.
  - Make the descriptions align with the spec reqs.
  - Validate the logic.
- [ ] create an iterator/parser for loading tracestate; Eliminate the need for allocation to read the tracestate
  - Make it use the builder; this will require making the builder support pre-pending changes rather than preserving order.
  - Make it slice instead of a struct, as it should be immutable.
  - Make it avoid allocators as much as possbile; the builder should be used for where the mutation/allocation happens.
- [ ] ID generators should return typed IDs, rather than the underlying array length.
- [ ] Should Spans be allocated by an arena to make it easier to clean up for the tracer?
- [ ] Who should be the owner of the attributes attached to the span start options?
  - Validation can be moved out of the `startSpan()` if a builder does it and the options object owns them.
  - But that will require some helpers for simple cases.
- [ ] The Span.Context objects aren't really dealing with the ownership aspects yet.
- [ ] Is there a way to reduce the logic in the start span method?
  - Preload timestamp/span context in the options creation maybe?
  - Allow the option to influence the sampling decision through the options?
  - Compute trace/span id in the option creation as well?
- [ ] Logger sytle interface for span events?
- [ ] Thread local context and stack storage?
- [ ] Trace doesn't match the new naming and import syntaxes.
- [X] Fix missing span status bug.

# Metrics

- [ ] Histogram configurations need to be supported. Instruments need support for configurations generally.
- [ ] Can the SDK reduce the duplication by making more things templated?
- [ ] Stop ignoring the advisory parameter on the meter methods.
- [ ] Audit the orders of the mutex(es) on the meter.
  - Observables are triggered (iterated over) by the reader,
  - While the non-observables are modified by the meter when creating new meters.

## Logs

- [ ] Maybe an option for default attributes.
- [X] Convience methods in the API for when one isn't using metrics or tracing.
- [X] Extract trace id and span id from the context if provided null.
