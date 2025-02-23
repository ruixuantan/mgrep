const std = @import("std");

pub const STD_INPUT = "(standard input)";

pub const FileType = union(enum) {
    stdin,
    file: []const u8,
};

pub const FileTypeList = std.ArrayList(FileType);

pub const MgrepConfig = struct {
    count: bool,
    filename_display: bool,
    filename_list: bool,
    line_number_display: bool,
    negation: bool,
    pattern: ?[]const u8,
    filetypes: FileTypeList,

    fn init(allocator: std.mem.Allocator) !MgrepConfig {
        const ls = FileTypeList.init(allocator);
        return .{
            .count = false,
            .filename_display = true,
            .filename_list = false,
            .line_number_display = false,
            .negation = false,
            .pattern = null,
            .filetypes = ls,
        };
    }

    fn deinit(self: *MgrepConfig) void {
        self.filetypes.deinit();
    }
};

pub const ParseError = error{
    MissingPattern,
    MissingFiles,
    UnrecognizedConfig,
};

pub const Parser = struct {
    args: [][]const u8,
    pos: usize,
    config: MgrepConfig,

    pub fn init(allocator: std.mem.Allocator, args: [][]const u8) !Parser {
        return .{ .args = args, .pos = 1, .config = try MgrepConfig.init(allocator) };
    }

    pub fn parse(self: *Parser) !void {
        while (self.pos < self.args.len and self.args[self.pos][0] == '-') : (self.pos += 1) {
            try self.parseConfig();
        }

        if (self.pos == self.args.len) {
            return ParseError.MissingPattern;
        }
        self.config.pattern = self.args[self.pos];
        self.pos += 1;
        if (self.pos == self.args.len) { // take std.in input
            self.config.filename_display = false;
            try self.config.filetypes.append(FileType.stdin);
            std.debug.assert(self.config.pattern != null);
            return;
        }

        for (self.pos..self.args.len) |i| {
            try self.config.filetypes.append(FileType{ .file = self.args[i] });
        }
        if (self.config.filetypes.items.len == 1) {
            self.config.filename_display = false;
        }

        std.debug.assert(self.config.pattern != null);
    }

    fn parseConfig(self: *Parser) ParseError!void {
        switch (self.args[self.pos][1]) {
            'c' => self.config.count = true,
            'h' => self.config.filename_display = false,
            'l' => self.config.filename_list = true,
            'n' => self.config.line_number_display = true,
            'v' => self.config.negation = true,
            else => return ParseError.UnrecognizedConfig,
        }
    }

    pub fn deinit(self: *Parser) void {
        self.config.deinit();
    }
};

test "test parse single file" {
    var input = [_][]const u8{ "mgrep", "asdf", "asdf.txt" };
    var parser = try Parser.init(std.testing.allocator, &input);
    defer parser.deinit();
    try parser.parse();
    try std.testing.expectEqual(false, parser.config.filename_display);
    try std.testing.expectEqualStrings("asdf", parser.config.pattern.?);
    try std.testing.expectEqual(1, parser.config.filetypes.items.len);
    try std.testing.expectEqualStrings("asdf.txt", parser.config.filetypes.items[0].file);
}

test "test parse single file with config" {
    var input = [_][]const u8{ "mgrep", "-c", "asdf", "asdf.txt" };
    var parser = try Parser.init(std.testing.allocator, &input);
    defer parser.deinit();
    try parser.parse();
    try std.testing.expectEqual(true, parser.config.count);
    try std.testing.expectEqual(false, parser.config.filename_display);
    try std.testing.expectEqualStrings("asdf", parser.config.pattern.?);
    try std.testing.expectEqual(1, parser.config.filetypes.items.len);
    try std.testing.expectEqualStrings("asdf.txt", parser.config.filetypes.items[0].file);
}

test "test parse single file with multiple config" {
    var input = [_][]const u8{ "mgrep", "-v", "-n", "asdf", "asdf.txt" };
    var parser = try Parser.init(std.testing.allocator, &input);
    defer parser.deinit();
    try parser.parse();
    try std.testing.expectEqual(true, parser.config.line_number_display);
    try std.testing.expectEqual(true, parser.config.negation);
    try std.testing.expectEqualStrings("asdf", parser.config.pattern.?);
    try std.testing.expectEqual(1, parser.config.filetypes.items.len);
    try std.testing.expectEqualStrings("asdf.txt", parser.config.filetypes.items[0].file);
}

test "test parse multiple files" {
    var input = [_][]const u8{ "mgrep", "asdf", "asdf.txt", "fdsa.txt" };
    var parser = try Parser.init(std.testing.allocator, &input);
    defer parser.deinit();
    try parser.parse();
    try std.testing.expectEqual(true, parser.config.filename_display);
    try std.testing.expectEqualStrings("asdf", parser.config.pattern.?);
    try std.testing.expectEqual(2, parser.config.filetypes.items.len);
    try std.testing.expectEqualStrings("asdf.txt", parser.config.filetypes.items[0].file);
    try std.testing.expectEqualStrings("fdsa.txt", parser.config.filetypes.items[1].file);
}

test "test parse no files, from std in" {
    var input = [_][]const u8{ "mgrep", "asdf" };
    var parser = try Parser.init(std.testing.allocator, &input);
    defer parser.deinit();
    try parser.parse();
    try std.testing.expectEqual(false, parser.config.filename_display);
    try std.testing.expectEqualStrings("asdf", parser.config.pattern.?);
    try std.testing.expectEqual(1, parser.config.filetypes.items.len);
    try std.testing.expectEqual(FileType.stdin, parser.config.filetypes.items[0]);
}
