const std = @import("std");

const err: std.fs.File = std.fs.File.stderr();
const out: std.fs.File = std.fs.File.stdout();

pub fn initStream(use_stderr: bool, buffer: []u8) std.fs.File.Writer {
    const fh = if (use_stderr) err else out;
    return fh.writer(buffer);
}
