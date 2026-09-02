pub const ProcessResult = enum {
    success,
    failure,
    timeout,

    pub fn isSuccess(self: ProcessResult) bool {
        return self == .success;
    }

    pub fn isFailure(self: ProcessResult) bool {
        return self == .failure;
    }
};

pub const FlushResult = enum {
    success,
    failure,
    timeout,

    pub fn isSuccess(self: FlushResult) bool {
        return self == .success;
    }

    pub fn isFailure(self: FlushResult) bool {
        return self == .failure;
    }

    pub fn isTimeout(self: FlushResult) bool {
        return self == .timeout;
    }

    /// Convert ExportResult to ProcessResult
    pub inline fn asProcessResult(self: FlushResult) ProcessResult {
        return switch (self) {
            .success => .success,
            .failure => .failure,
            .timeout => .timeout,
        };
    }
};

/// Result of an export operation
pub const ExportResult = enum {
    success,
    failure,
    timeout,

    pub fn isSuccess(self: ExportResult) bool {
        return self == .success;
    }

    pub fn isFailure(self: ExportResult) bool {
        return self == .failure;
    }

    /// Convert ExportResult to ProcessResult
    pub fn asFlushResult(self: ExportResult) FlushResult {
        return switch (self) {
            .success => .success,
            .failure => .failure,
            .timeout => .timeout,
        };
    }
};
