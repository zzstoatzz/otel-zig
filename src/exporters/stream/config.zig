const std = @import("std");

writer: *std.Io.Writer,
include_timestamp: bool = true,
include_attributes: bool = true,
include_resource: bool = false,
include_unended_spans: bool = false,
flush_after_each: bool = false,
