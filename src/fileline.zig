const std = @import("std");

pub const FileLine = struct {
    line_number: usize,
    filename: []const u8,
    line: []const u8,

    pub fn init(line_number: usize, filename: []const u8, line: []const u8) FileLine {
        return .{ .line_number = line_number, .filename = filename, .line = line };
    }

    pub fn print(self: FileLine, outw: anytype) !void {
        try outw.print("{s}:{d}:{s}\n", .{ self.filename, self.line_number, self.line });
    }
};
