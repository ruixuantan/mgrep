const std = @import("std");
const Token = @import("token.zig").Token;
const TokenList = @import("token.zig").TokenList;
const RepeatToken = @import("token.zig").RepeatToken;
const AltToken = @import("token.zig").AltToken;
const Range = @import("token.zig").Range;
const INF = @import("token.zig").INF;
const MAX_U8 = @import("token.zig").MAX_U8;

pub const ParseError = error{
    MissingClosingGroupBracket,
    MissingClosingRangeBracket,
    RepeatTokenAtStart,
    MissingClosingRepeatBracket,
    NoNumbersInRange,
    InvalidRangeNumber,
    RangeMinGreaterThanMax,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    pos: usize,
    tokens: TokenList,

    fn initWithPos(allocator: std.mem.Allocator, pos: usize) *Parser {
        const parser = allocator.create(Parser) catch @panic("Error allocating parser");
        const ls = TokenList.init(allocator);
        parser.allocator = allocator;
        parser.pos = pos;
        parser.tokens = ls;
        return parser;
    }

    pub fn init(allocator: std.mem.Allocator) *Parser {
        return initWithPos(allocator, 0);
    }

    pub fn deinit(self: *Parser) void {
        for (self.tokens.items) |t| {
            t.deinit(self.allocator);
        }
        self.tokens.deinit();
        self.allocator.destroy(self);
    }

    fn process(self: *Parser, regex: []const u8) ParseError!void {
        const char = regex[self.pos];
        switch (char) {
            '\\' => self.parseSpecial(regex),
            '[' => try self.parseRange(regex),
            '|' => try self.parseAlt(regex),
            '(' => try self.parseGroup(regex),
            '{' => try self.parseRepeatSpecified(regex),
            '*', '+', '?' => self.parseRepeat(regex),
            '.' => {
                const range = Range.initFull();
                const t = Token.init(self.allocator);
                t.* = .{ .range = range };
                self.tokens.append(t) catch @panic("Error appending token");
            },
            else => {
                const t = Token.init(self.allocator);
                t.* = .{ .literal = char };
                self.tokens.append(t) catch @panic("Error appending token");
            },
        }
        self.pos += 1;
    }

    fn parseSpecial(self: *Parser, regex: []const u8) void {
        self.pos += 1;
        var range = Range.initEmpty();
        if (regex[self.pos] == 'S' or regex[self.pos] == 'W' or regex[self.pos] == 'D') {
            range = Range.initFull();
        }
        switch (regex[self.pos]) {
            'r' => range.toggle('\r'),
            'n' => range.toggle('\n'),
            't' => range.toggle('\t'),
            '\\' => range.toggle('\\'),
            's', 'S' => {
                range.toggle(' ');
                range.toggle('\r');
                range.toggle('\t');
                range.toggle('\n');
            },
            'd', 'D' => {
                for ('0'..'9' + 1) |c| {
                    range.toggle(@intCast(c));
                }
            },
            'w', 'W' => {
                for ('a'..'z' + 1) |c| {
                    range.toggle(@intCast(c));
                }
                for ('A'..'Z' + 1) |c| {
                    range.toggle(@intCast(c));
                }
                for ('0'..'9' + 1) |c| {
                    range.toggle(@intCast(c));
                }
                range.toggle('_');
            },
            else => range.toggle(regex[self.pos]),
        }

        const t = Token.init(self.allocator);
        t.* = .{ .range = range };
        self.tokens.append(t) catch @panic("Error appending token");
    }

    fn parseRange(self: *Parser, regex: []const u8) ParseError!void {
        self.pos += 1;
        var min: u8 = 0;
        var range = Range.initEmpty();
        if (regex[self.pos] == '^') {
            range = Range.initFull();
            self.pos += 1;
        }
        while (self.pos < regex.len and regex[self.pos] != ']') : (self.pos += 1) {
            if (min == 0) {
                min = regex[self.pos];
            } else {
                if (regex[self.pos] == '-') continue;

                if (regex[self.pos - 1] == '-') { // handle [a-z] cases
                    const max = regex[self.pos];
                    for (min..max + 1) |c| {
                        range.toggle(c);
                    }
                } else { // handle [ab] cases
                    range.toggle(min);
                    range.toggle(regex[self.pos]);
                }
                min = 0;
            }
        }
        if (self.pos >= regex.len) return ParseError.MissingClosingRangeBracket;

        const t = Token.init(self.allocator);
        t.* = .{ .range = range };
        self.tokens.append(t) catch @panic("Error appending token");
    }

    fn parseAlt(self: *Parser, regex: []const u8) ParseError!void {
        const left = self.tokens.pop();

        const right_parser = Parser.initWithPos(self.allocator, self.pos + 1);
        defer self.allocator.destroy(right_parser);

        while (right_parser.pos < regex.len and regex[right_parser.pos] != ')') {
            try right_parser.process(regex);
        }
        self.pos = right_parser.pos;
        const right_tokens = right_parser.tokens.toOwnedSlice() catch @panic("Error converting right token to slice");
        const right = Token.init(self.allocator);
        right.* = .{ .group = right_tokens };

        const t = Token.init(self.allocator);
        t.* = .{ .alt = AltToken{ .left = left, .right = right } };
        self.tokens.append(t) catch @panic("Error appending token");
    }

    fn parseRepeat(self: *Parser, regex: []const u8) void {
        const prev = self.tokens.pop();
        var rt = RepeatToken{ .min = 0, .max = INF, .token = prev };
        switch (regex[self.pos]) {
            '*' => {},
            '+' => rt.min = 1,
            '?' => rt.max = 1,
            else => unreachable,
        }
        const t = Token.init(self.allocator);
        t.* = .{ .repeat = rt };
        self.tokens.append(t) catch @panic("Error appending token");
    }

    fn parseRepeatSpecified(self: *Parser, regex: []const u8) ParseError!void {
        if (self.pos == 0) return ParseError.RepeatTokenAtStart;

        const start = self.pos + 1;
        while (self.pos < regex.len and regex[self.pos] != '}') : (self.pos += 1) {}

        if (self.pos >= regex.len) return ParseError.MissingClosingRepeatBracket;

        const end = self.pos;
        var it = std.mem.split(u8, regex[start..end], ",");
        const str_min = it.next() orelse return ParseError.NoNumbersInRange;
        var min: usize = undefined;
        if (std.mem.eql(u8, str_min, "")) {
            min = 0;
        } else {
            min = std.fmt.parseUnsigned(usize, str_min, 10) catch return ParseError.InvalidRangeNumber;
        }
        std.debug.assert(min != undefined);

        var max = min;
        const str_max = it.next();
        if (str_max != null) {
            if (std.mem.eql(u8, str_max.?, "")) {
                max = INF;
            } else {
                max = std.fmt.parseUnsigned(usize, str_max.?, 10) catch return ParseError.InvalidRangeNumber;
            }
        }
        if (min > max) return ParseError.RangeMinGreaterThanMax;

        const t = Token.init(self.allocator);
        const prev = self.tokens.pop();
        t.* = .{ .repeat = RepeatToken{ .min = min, .max = max, .token = prev } };
        self.tokens.append(t) catch @panic("Error appending token");
    }

    fn parseGroup(self: *Parser, regex: []const u8) ParseError!void {
        const grp_parser = Parser.initWithPos(self.allocator, self.pos + 1);
        defer self.allocator.destroy(grp_parser);

        while (regex[grp_parser.pos] != ')') {
            try grp_parser.process(regex);
            if (grp_parser.pos >= regex.len) return ParseError.MissingClosingGroupBracket;
        }
        self.pos = grp_parser.pos;
        const grp_tokens = grp_parser.tokens.toOwnedSlice() catch @panic("Error converting group token to slice");
        const t = Token.init(self.allocator);
        t.* = .{ .group = grp_tokens };
        self.tokens.append(t) catch @panic("Error appending group token");
    }

    pub fn parse(self: *Parser, regex: []const u8) ParseError!TokenList {
        while (self.pos < regex.len) {
            try self.process(regex);
        }
        return self.tokens;
    }
};

test "parse literal string" {
    const allocator = std.testing.allocator;
    const parser = Parser.init(allocator);
    defer parser.deinit();

    const regex = "as";
    const ls = try parser.parse(regex);
    try std.testing.expectEqual(2, ls.items.len);
    try std.testing.expectEqual('a', ls.items[0].literal);
    try std.testing.expectEqual('s', ls.items[1].literal);
}

test "parse group" {
    const allocator = std.testing.allocator;
    const parser = Parser.init(allocator);
    defer parser.deinit();

    const ls = try parser.parse("a(s)");
    try std.testing.expectEqual(2, ls.items.len);
    try std.testing.expectEqual('a', ls.items[0].literal);
    try std.testing.expectEqual(1, ls.items[1].group.len);
    try std.testing.expectEqual('s', ls.items[1].group[0].literal);
}

test "parse repeats" {
    const allocator = std.testing.allocator;
    const parser = Parser.init(allocator);
    defer parser.deinit();

    const star_ls = try parser.parse("as*");
    try std.testing.expectEqual(2, star_ls.items.len);
    try std.testing.expectEqual(0, star_ls.items[1].repeat.min);
    try std.testing.expectEqual(INF, star_ls.items[1].repeat.max);
    try std.testing.expectEqual('s', star_ls.items[1].repeat.token.literal);

    const plus_parser = Parser.init(allocator);
    defer plus_parser.deinit();
    const plus_ls = try plus_parser.parse("as+");
    try std.testing.expectEqual(1, plus_ls.items[1].repeat.min);
    try std.testing.expectEqual(INF, plus_ls.items[1].repeat.max);
    try std.testing.expectEqual('s', plus_ls.items[1].repeat.token.literal);

    const qn_parser = Parser.init(allocator);
    defer qn_parser.deinit();
    const qn_ls = try qn_parser.parse("as?");
    try std.testing.expectEqual(0, qn_ls.items[1].repeat.min);
    try std.testing.expectEqual(1, qn_ls.items[1].repeat.max);
    try std.testing.expectEqual('s', qn_ls.items[1].repeat.token.literal);
}

test "parse specified repeat" {
    const allocator = std.testing.allocator;
    const parser = Parser.init(allocator);
    defer parser.deinit();

    const ls = try parser.parse("as{1,100}");
    try std.testing.expectEqual(2, ls.items.len);
    try std.testing.expectEqual(1, ls.items[1].repeat.min);
    try std.testing.expectEqual(100, ls.items[1].repeat.max);
    try std.testing.expectEqual('s', ls.items[1].repeat.token.literal);

    const single_parser = Parser.init(allocator);
    defer single_parser.deinit();
    const single_ls = try single_parser.parse("a{423}s");
    try std.testing.expectEqual(423, single_ls.items[0].repeat.min);
    try std.testing.expectEqual(423, single_ls.items[0].repeat.max);
    try std.testing.expectEqual('a', single_ls.items[0].repeat.token.literal);

    const min_parser = Parser.init(allocator);
    defer min_parser.deinit();
    const min_ls = try min_parser.parse("a{2,}s");
    try std.testing.expectEqual(2, min_ls.items[0].repeat.min);
    try std.testing.expectEqual(INF, min_ls.items[0].repeat.max);
    try std.testing.expectEqual('a', min_ls.items[0].repeat.token.literal);

    const max_parser = Parser.init(allocator);
    defer max_parser.deinit();
    const max_ls = try max_parser.parse("a{,3}s");
    try std.testing.expectEqual(0, max_ls.items[0].repeat.min);
    try std.testing.expectEqual(3, max_ls.items[0].repeat.max);
    try std.testing.expectEqual('a', max_ls.items[0].repeat.token.literal);
}

test "parse alt" {
    const allocator = std.testing.allocator;
    const parser = Parser.init(allocator);
    defer parser.deinit();

    const ls = try parser.parse("a|bb");
    try std.testing.expectEqual(1, ls.items.len);
    const left = ls.items[0].alt.left;
    const right = ls.items[0].alt.right;
    try std.testing.expectEqual('a', left.literal);
    try std.testing.expectEqual('b', right.group[0].literal);
    try std.testing.expectEqual('b', right.group[1].literal);
}

test "parse range" {
    const allocator = std.testing.allocator;
    const parser = Parser.init(allocator);
    defer parser.deinit();

    const ls = try parser.parse("[3-5b-c]");
    try std.testing.expectEqual(1, ls.items.len);
    try std.testing.expect(!ls.items[0].range.isSet('2'));
    try std.testing.expect(ls.items[0].range.isSet('3'));
    try std.testing.expect(ls.items[0].range.isSet('4'));
    try std.testing.expect(ls.items[0].range.isSet('5'));
    try std.testing.expect(!ls.items[0].range.isSet('6'));
    try std.testing.expect(!ls.items[0].range.isSet('1'));
    try std.testing.expect(ls.items[0].range.isSet('b'));
    try std.testing.expect(ls.items[0].range.isSet('c'));
    try std.testing.expect(!ls.items[0].range.isSet('d'));

    const nodash_parser = Parser.init(allocator);
    defer nodash_parser.deinit();
    const nodash_ls = try nodash_parser.parse("[ac]");
    try std.testing.expect(nodash_ls.items[0].range.isSet('a'));
    try std.testing.expect(!nodash_ls.items[0].range.isSet('b'));
    try std.testing.expect(nodash_ls.items[0].range.isSet('c'));

    const neg_parser = Parser.init(allocator);
    defer neg_parser.deinit();
    const neg_ls = try neg_parser.parse("[^a-z]");
    try std.testing.expect(neg_ls.items[0].range.isSet('a' - 1));
    try std.testing.expect(!neg_ls.items[0].range.isSet('a'));
    try std.testing.expect(!neg_ls.items[0].range.isSet('z'));
    try std.testing.expect(neg_ls.items[0].range.isSet('z' + 1));
}

test "parse special" {
    const allocator = std.testing.allocator;
    const parser = Parser.init(allocator);
    defer parser.deinit();

    const ls = try parser.parse("\\d");
    try std.testing.expectEqual(1, ls.items.len);
    try std.testing.expect(!ls.items[0].range.isSet('0' - 1));
    try std.testing.expect(ls.items[0].range.isSet('0'));
    try std.testing.expect(ls.items[0].range.isSet('4'));
    try std.testing.expect(ls.items[0].range.isSet('9'));
    try std.testing.expect(!ls.items[0].range.isSet('9' + 1));

    const neg_parser = Parser.init(allocator);
    defer neg_parser.deinit();

    const neg_ls = try neg_parser.parse("\\D");
    try std.testing.expectEqual(1, neg_ls.items.len);
    try std.testing.expect(neg_ls.items[0].range.isSet('0' - 1));
    try std.testing.expect(!neg_ls.items[0].range.isSet('0'));
    try std.testing.expect(!neg_ls.items[0].range.isSet('4'));
    try std.testing.expect(!neg_ls.items[0].range.isSet('9'));
    try std.testing.expect(neg_ls.items[0].range.isSet('9' + 1));
}
