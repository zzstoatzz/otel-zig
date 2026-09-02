const std = @import("std");
const io = std.Options.debug_io;

const err: std.Io.File = std.Io.File.stderr();
const out: std.Io.File = std.Io.File.stdout();

pub fn initStream(use_stderr: bool, buffer: []u8) std.Io.File.Writer {
    const fh = if (use_stderr) err else out;
    return fh.writer(io, buffer);
}
