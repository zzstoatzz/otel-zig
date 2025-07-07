const otel_api = @import("otel-api");

/// Provides hash and equality functions for `InstrumentationScope` to be used
/// as the context for `std.HashMapUnmanaged`.
///
/// This allows `InstrumentationScope` to be used as a key in hash maps
/// for caching loggers, meters, and tracers across different providers.
pub const InstrumentationScopeMapContext = struct {
    pub fn hash(_: @This(), key: otel_api.InstrumentationScope) u64 {
        return key.hashCode();
    }

    pub fn eql(_: @This(), a: otel_api.InstrumentationScope, b: otel_api.InstrumentationScope) bool {
        return otel_api.InstrumentationScope.eql(a, b);
    }
};
