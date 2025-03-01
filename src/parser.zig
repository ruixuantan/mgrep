const std = @import("std");

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

    fn deinit(self: *MgrepConfig, allocator: std.mem.Allocator) void {
        for (self.filetypes.items) |ft| {
            switch (ft) {
                FileType.file => |f| allocator.free(f),
                else => {},
            }
        }
        self.filetypes.deinit();
    }
};

pub const ParseError = error{
    MissingPattern,
    MissingFiles,
    UnrecognizedConfig,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    args: [][]const u8,
    pos: usize,
    config: MgrepConfig,

    pub fn init(allocator: std.mem.Allocator, args: [][]const u8) !Parser {
        return .{ .allocator = allocator, .args = args, .pos = 1, .config = try MgrepConfig.init(allocator) };
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
            const stat = try std.fs.cwd().statFile(self.args[i]);
            switch (stat.kind) {
                .directory => try self.getFiles(self.args[i]),
                .file => try self.config.filetypes.append(FileType{ .file = try self.allocator.dupe(u8, self.args[i]) }),
                else => std.log.err("{s} detected is of kind: {s}\n", .{ self.args[i], @tagName(stat.kind) }),
            }
        }
        if (self.config.filetypes.items.len == 1) {
            self.config.filename_display = false;
        }

        std.debug.assert(self.config.pattern != null);
    }

    fn parseConfig(self: *Parser) ParseError!void {
        for (1..self.args[self.pos].len) |i| {
            switch (self.args[self.pos][i]) {
                'c' => self.config.count = true,
                'h' => self.config.filename_display = false,
                'l' => self.config.filename_list = true,
                'n' => self.config.line_number_display = true,
                'v' => self.config.negation = true,
                else => return ParseError.UnrecognizedConfig,
            }
        }
    }

    fn getFiles(self: *Parser, str_dir: []const u8) !void {
        var dir = try std.fs.cwd().openDir(str_dir, .{});
        defer dir.close();
        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            var path = try self.allocator.alloc(u8, str_dir.len + entry.path.len);
            @memcpy(path[0..str_dir.len], str_dir);
            @memcpy(path[str_dir.len..], entry.path);
            const stat = try std.fs.cwd().statFile(path);
            switch (stat.kind) {
                .file => try self.config.filetypes.append(FileType{ .file = path }),
                else => {
                    self.allocator.free(path);
                },
            }
        }
    }

    pub fn deinit(self: *Parser) void {
        self.config.deinit(self.allocator);
    }
};

test "test parse single file" {
    var input = [_][]const u8{ "mgrep", "asdf", "src/main.zig" };
    var parser = try Parser.init(std.testing.allocator, &input);
    defer parser.deinit();
    try parser.parse();
    try std.testing.expectEqual(false, parser.config.filename_display);
    try std.testing.expectEqualStrings("asdf", parser.config.pattern.?);
    try std.testing.expectEqual(1, parser.config.filetypes.items.len);
    try std.testing.expectEqualStrings("src/main.zig", parser.config.filetypes.items[0].file);
}

test "test parse single file with config" {
    var input = [_][]const u8{ "mgrep", "-c", "asdf", "src/main.zig" };
    var parser = try Parser.init(std.testing.allocator, &input);
    defer parser.deinit();
    try parser.parse();
    try std.testing.expectEqual(true, parser.config.count);
    try std.testing.expectEqual(false, parser.config.filename_display);
    try std.testing.expectEqualStrings("asdf", parser.config.pattern.?);
    try std.testing.expectEqual(1, parser.config.filetypes.items.len);
    try std.testing.expectEqualStrings("src/main.zig", parser.config.filetypes.items[0].file);
}

test "test parse single file with multiple config" {
    var input = [_][]const u8{ "mgrep", "-v", "-n", "asdf", "src/main.zig" };
    var parser = try Parser.init(std.testing.allocator, &input);
    defer parser.deinit();
    try parser.parse();
    try std.testing.expectEqual(true, parser.config.line_number_display);
    try std.testing.expectEqual(true, parser.config.negation);
    try std.testing.expectEqualStrings("asdf", parser.config.pattern.?);
    try std.testing.expectEqual(1, parser.config.filetypes.items.len);
    try std.testing.expectEqualStrings("src/main.zig", parser.config.filetypes.items[0].file);
}

test "test parse single file with multiple concatenated config" {
    var input = [_][]const u8{ "mgrep", "-vn", "asdf", "src/main.zig" };
    var parser = try Parser.init(std.testing.allocator, &input);
    defer parser.deinit();
    try parser.parse();
    try std.testing.expectEqual(true, parser.config.line_number_display);
    try std.testing.expectEqual(true, parser.config.negation);
    try std.testing.expectEqualStrings("asdf", parser.config.pattern.?);
    try std.testing.expectEqual(1, parser.config.filetypes.items.len);
    try std.testing.expectEqualStrings("src/main.zig", parser.config.filetypes.items[0].file);
}

test "test parse multiple files" {
    var input = [_][]const u8{ "mgrep", "asdf", "src/main.zig", "build.zig" };
    var parser = try Parser.init(std.testing.allocator, &input);
    defer parser.deinit();
    try parser.parse();
    try std.testing.expectEqual(true, parser.config.filename_display);
    try std.testing.expectEqualStrings("asdf", parser.config.pattern.?);
    try std.testing.expectEqual(2, parser.config.filetypes.items.len);
    try std.testing.expectEqualStrings("src/main.zig", parser.config.filetypes.items[0].file);
    try std.testing.expectEqualStrings("build.zig", parser.config.filetypes.items[1].file);
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

test "test parse directory" {
    var input = [_][]const u8{ "mgrep", "asdf", "src/" };
    var parser = try Parser.init(std.testing.allocator, &input);
    defer parser.deinit();
    try parser.parse();
    try std.testing.expectEqualStrings("asdf", parser.config.pattern.?);
    try std.testing.expect(parser.config.filetypes.items.len > 0);
}
