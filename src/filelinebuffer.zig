const std = @import("std");
const MgrepConfig = @import("parser.zig").MgrepConfig;
const SubstrIndex = @import("regex/nfa.zig").SubstrIndex;

const Fileline = struct {
    line: []const u8,
    matches: []const SubstrIndex,

    fn contains_match(self: Fileline) bool {
        return self.matches.len > 0;
    }

    fn deinit(self: *Fileline, allocator: std.mem.Allocator) void {
        allocator.free(self.line);
        allocator.free(self.matches);
    }
};

const Filelines = std.ArrayList(Fileline);

pub fn Filelinebuffer(comptime size: usize) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        buffer: Filelines,
        reset_count: usize,
        filename: []const u8,
        lines_matched: usize,

        pub fn init(allocator: std.mem.Allocator, filename: []const u8) Self {
            return .{ .allocator = allocator, .buffer = Filelines.init(allocator), .reset_count = 0, .filename = filename, .lines_matched = 0 };
        }

        pub fn add(self: *Self, line: []const u8, ls: []const SubstrIndex) !void {
            std.debug.assert(self.buffer.items.len < size);

            try self.buffer.append(.{ .line = line, .matches = ls });
            if (self.buffer.getLast().contains_match()) {
                self.lines_matched += 1;
            }
        }

        pub fn isFull(self: Self) bool {
            return self.buffer.items.len == size;
        }

        pub fn reset(self: *Self) void {
            self.reset_count += 1;
            for (self.buffer.items) |*fileline| {
                fileline.deinit(self.allocator);
            }
            self.buffer.clearAndFree();
        }

        pub fn print(self: Self, outw: anytype, config: MgrepConfig) !void {
            const match_target = !config.negation;
            if (config.count or config.filename_list) {
                return;
            }

            for (self.buffer.items, 0..) |fileline, i| {
                if (fileline.contains_match() == match_target) {
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

                    var line_pos: usize = 0;
                    for (fileline.matches) |index| {
                        try outw.print("{s}", .{fileline.line[line_pos..index.start]});
                        try outw.print("\x1b[31m", .{});
                        try outw.print("{s}", .{fileline.line[index.start..index.end]});
                        try outw.print("\x1b[0m", .{});
                        line_pos = index.end;
                    }
                    try outw.print("{s}\n", .{fileline.line[line_pos..]});
                }
            }
        }

        pub fn aggregatePrint(self: Self, outw: anytype, config: MgrepConfig) !void {
            if (config.count) {
                if (config.filename_display) {
                    try outw.print("{s}:", .{self.filename});
                }
                var count = self.lines_matched;
                if (config.negation) {
                    count = (self.reset_count * size + self.buffer.items.len) - self.lines_matched;
                }
                try outw.print("{d}\n", .{count});
            } else if (config.filename_list) {
                try outw.print("{s}\n", .{self.filename});
            }
        }

        pub fn deinit(self: *Self) void {
            for (self.buffer.items) |*fileline| {
                fileline.deinit(self.allocator);
            }
            self.buffer.deinit();
        }
    };
}

test "test Linebuffer add and reset" {
    const allocator = std.testing.allocator;
    const TestFilelinebuffer = Filelinebuffer(2);
    var filelinebuf = TestFilelinebuffer.init(allocator, "test.txt");
    defer filelinebuf.deinit();

    const line1_res = [_]SubstrIndex{SubstrIndex{ .start = 3, .end = 4 }};
    try filelinebuf.add(try allocator.dupe(u8, "line 1"), try allocator.dupe(SubstrIndex, &line1_res));
    const line2_res = [_]SubstrIndex{};
    try filelinebuf.add(try allocator.dupe(u8, "line 2"), try allocator.dupe(SubstrIndex, &line2_res));
    try std.testing.expectEqual(2, filelinebuf.buffer.items.len);
    try std.testing.expectEqual(0, filelinebuf.reset_count);
    try std.testing.expectEqual(1, filelinebuf.lines_matched);
    try std.testing.expect(filelinebuf.isFull());

    filelinebuf.reset();
    const line3_res = [_]SubstrIndex{SubstrIndex{ .start = 3, .end = 4 }};
    try filelinebuf.add(try allocator.dupe(u8, "line 3"), try allocator.dupe(SubstrIndex, &line3_res));
    try std.testing.expectEqual(1, filelinebuf.buffer.items.len);
    try std.testing.expectEqual(1, filelinebuf.reset_count);
    try std.testing.expectEqual(2, filelinebuf.lines_matched);
    try std.testing.expect(!filelinebuf.isFull());
}
