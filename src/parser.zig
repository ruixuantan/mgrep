const std = @import("std");

pub const MgrepConfig = struct {
    count: bool,
    filename_display: bool,
    filename_list: bool,
    line_number_display: bool,
    negation: bool,
    pattern: ?[]const u8,
    text: ?[]const u8,
    filenames: ?[][]const u8,

    fn init() MgrepConfig {
        return .{
            .count = false,
            .filename_display = true,
            .filename_list = false,
            .line_number_display = false,
            .negation = false,
            .pattern = null,
            .text = null,
            .filenames = null,
        };
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

    pub fn init(args: [][]const u8) Parser {
        return .{ .args = args, .pos = 1, .config = MgrepConfig.init() };
    }

    pub fn parse(self: *Parser) ParseError!void {
        while (self.pos < self.args.len and self.args[self.pos][0] == '-') : (self.pos += 1) {
            try self.parseConfig();
        }

        if (self.pos == self.args.len) {
            return ParseError.MissingPattern;
        }
        self.config.pattern = self.args[self.pos];
        self.pos += 1;

        if (self.pos == self.args.len) {
            return ParseError.MissingFiles;
        }
        self.config.filenames = self.args[self.pos..];
        if (self.config.filenames.?.len == 1) {
            self.config.filename_display = false;
        }

        std.debug.assert(self.config.pattern != null);
        std.debug.assert(self.config.text != null or self.config.filenames != null);
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
};

test "test parse single file" {
    var input = [_][]const u8{ "mgrep", "asdf", "asdf.txt" };
    var parser = Parser.init(&input);
    try parser.parse();
    try std.testing.expectEqual(false, parser.config.filename_display);
    try std.testing.expectEqualStrings("asdf", parser.config.pattern.?);
    try std.testing.expectEqual(1, parser.config.filenames.?.len);
    try std.testing.expectEqualStrings("asdf.txt", parser.config.filenames.?[0]);
}

test "test parse single file with config" {
    var input = [_][]const u8{ "mgrep", "-c", "asdf", "asdf.txt" };
    var parser = Parser.init(&input);
    try parser.parse();
    try std.testing.expectEqual(true, parser.config.count);
    try std.testing.expectEqual(false, parser.config.filename_display);
    try std.testing.expectEqualStrings("asdf", parser.config.pattern.?);
    try std.testing.expectEqual(1, parser.config.filenames.?.len);
    try std.testing.expectEqualStrings("asdf.txt", parser.config.filenames.?[0]);
}

test "test parse single file with multiple config" {
    var input = [_][]const u8{ "mgrep", "-v", "-n", "asdf", "asdf.txt" };
    var parser = Parser.init(&input);
    try parser.parse();
    try std.testing.expectEqual(true, parser.config.line_number_display);
    try std.testing.expectEqual(true, parser.config.negation);
    try std.testing.expectEqualStrings("asdf", parser.config.pattern.?);
    try std.testing.expectEqual(1, parser.config.filenames.?.len);
    try std.testing.expectEqualStrings("asdf.txt", parser.config.filenames.?[0]);
}

test "test parse multiple files" {
    var input = [_][]const u8{ "mgrep", "asdf", "asdf.txt", "fdsa.txt" };
    var parser = Parser.init(&input);
    try parser.parse();
    try std.testing.expectEqual(true, parser.config.filename_display);
    try std.testing.expectEqualStrings("asdf", parser.config.pattern.?);
    try std.testing.expectEqual(2, parser.config.filenames.?.len);
    try std.testing.expectEqualStrings("asdf.txt", parser.config.filenames.?[0]);
    try std.testing.expectEqualStrings("fdsa.txt", parser.config.filenames.?[1]);
}
