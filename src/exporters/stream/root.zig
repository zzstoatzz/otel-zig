pub const SinkConfig = @import("config.zig");
pub const LogRecordSink = @import("logs.zig");
pub const MetricDataSink = @import("metrics.zig");
pub const SpanDataSink = @import("traces.zig");

test "Stream Exporters" {
    @import("std").testing.refAllDecls(@This());
}
