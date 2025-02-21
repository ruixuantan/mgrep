const std = @import("std");
const MgrepConfig = @import("parser.zig").MgrepConfig;

const Result = enum {
    Match,
    NoMatch,
};

const Fileline = struct {
    line: []const u8,
    result: Result,
};

pub fn Linebuffer(comptime size: usize) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        buffer: [size]Fileline,
        curr_size: usize,
        reset_count: usize,
        filename: []const u8,
        matches: usize,

        pub fn init(allocator: std.mem.Allocator, filename: []const u8) Self {
            return .{ .allocator = allocator, .buffer = undefined, .curr_size = 0, .reset_count = 0, .filename = filename, .matches = 0 };
        }

        pub fn add(self: *Self, line: []const u8, match: bool) void {
            std.debug.assert(self.curr_size < size);

            const result = if (match) Result.Match else Result.NoMatch;
            self.buffer[self.curr_size] = .{ .line = line, .result = result };
            self.curr_size += 1;
            if (match) {
                self.matches += 1;
            }
        }

        pub fn isFull(self: Self) bool {
            return self.curr_size == size;
        }

        pub fn reset(self: *Self) void {
            self.curr_size = 0;
            self.reset_count += 1;
            for (self.buffer) |fileline| {
                self.allocator.free(fileline.line);
            }
        }

        pub fn print(self: Self, outw: anytype, config: MgrepConfig) !void {
            const match_target = if (config.negation) Result.NoMatch else Result.Match;
            if (config.count or config.filename_list) {
                return;
            }

            for (0..self.curr_size) |i| {
                if (self.buffer[i].result == match_target) {
                    if (config.filename_display) {
                        try outw.print("{s}", .{self.filename});
                    }

                    if (config.line_number_display) {
                        if (config.filename_display) {
                            try outw.print(" ", .{});
                        }
                        try outw.print("{d}", .{self.reset_count * size + i + 1});
                    }

                    if (config.filename_display or config.line_number_display) {
                        try outw.print(":", .{});
                    }

                    try outw.print("{s}\n", .{self.buffer[i].line});
                }
            }
        }

        pub fn aggregatePrint(self: Self, outw: anytype, config: MgrepConfig) !void {
            if (config.count) {
                if (config.filename_display) {
                    try outw.print("{s}:", .{self.filename});
                }
                var count = self.matches;
                if (config.negation) {
                    count = (self.reset_count * size + self.curr_size) - self.matches;
                }
                try outw.print("{d}\n", .{count});
            } else if (config.filename_list) {
                try outw.print("{s}\n", .{self.filename});
            }
        }

        pub fn deinit(self: *Self) void {
            for (0..self.curr_size) |i| {
                self.allocator.free(self.buffer[i].line);
            }
        }
    };
}

test "test Linebuffer add and reset" {
    const allocator = std.testing.allocator;
    const TestLinebuffer = Linebuffer(2);
    var linebuf = TestLinebuffer.init(allocator, "test.txt");
    defer linebuf.deinit();

    linebuf.add(try allocator.dupe(u8, "line 1"), true);
    linebuf.add(try allocator.dupe(u8, "line 2"), false);
    try std.testing.expectEqual(2, linebuf.buffer.len);
    try std.testing.expectEqual(2, linebuf.curr_size);
    try std.testing.expectEqual(0, linebuf.reset_count);
    try std.testing.expectEqual(1, linebuf.matches);
    try std.testing.expectEqual(Result.Match, linebuf.buffer[0].result);
    try std.testing.expectEqual(Result.NoMatch, linebuf.buffer[1].result);
    try std.testing.expect(linebuf.isFull());

    linebuf.reset();
    linebuf.add(try allocator.dupe(u8, "line 3"), true);
    try std.testing.expectEqual(2, linebuf.buffer.len);
    try std.testing.expectEqual(1, linebuf.curr_size);
    try std.testing.expectEqual(1, linebuf.reset_count);
    try std.testing.expectEqual(2, linebuf.matches);
    try std.testing.expectEqual(Result.Match, linebuf.buffer[0].result);
    try std.testing.expect(!linebuf.isFull());
}
