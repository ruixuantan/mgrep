const std = @import("std");
const Token = @import("token.zig").Token;
const RepeatToken = @import("token.zig").RepeatToken;
const AltToken = @import("token.zig").AltToken;
const Range = @import("token.zig").Range;
const INF = @import("token.zig").INF;
const MAX_U8 = @import("token.zig").MAX_U8;

const NodeList = std.ArrayList(*Node);
const Edges = std.AutoHashMap(u8, *Node);

const Node = struct {
    transition: Edges,
    e_transition: NodeList,

    fn init(allocator: std.mem.Allocator) *Node {
        const node = allocator.create(Node) catch @panic("Error creating node");
        const transition = Edges.init(allocator);
        const e_transition = NodeList.init(allocator);
        node.transition = transition;
        node.e_transition = e_transition;
        return node;
    }

    fn insertEpsilonTransition(self: *Node, node: *Node) void {
        self.e_transition.append(node) catch @panic("Error appending node to transition");
    }

    fn insertTransition(self: *Node, edge: u8, node: *Node) void {
        const v = self.transition.getOrPut(edge) catch @panic("Error retrieving node transitions");
        if (!v.found_existing) {
            v.value_ptr.* = node;
        } else {
            unreachable;
        }
    }

    fn neighborNodes(self: Node, allocator: std.mem.Allocator) []const *Node {
        var neighbors = NodeList.init(allocator);
        neighbors.appendSlice(self.e_transition.items) catch @panic("Error appending epsilon transitions");
        var it = self.transition.valueIterator();
        while (it.next()) |value_ptr| {
            neighbors.append(value_ptr.*) catch @panic("Error appending transition node");
        }
        return neighbors.toOwnedSlice() catch @panic("Error creating slice from neighbor nodes");
    }

    fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        self.transition.deinit();
        self.e_transition.deinit();
        allocator.destroy(self);
    }
};

const Matcher = struct {
    allocator: std.mem.Allocator,
    string: []const u8,
    start: *Node,
    end: *Node,

    fn dfsPartialMatch(self: Matcher, node: *Node, pos: usize) bool {
        if (node == self.end) {
            return true;
        }
        if (pos >= self.string.len) {
            return false;
        }

        const next_node = node.transition.get(self.string[pos]);
        if (next_node != null) {
            if (self.dfsPartialMatch(next_node.?, pos + 1)) {
                return true;
            }
        }

        for (node.e_transition.items) |e_node| {
            if (self.dfsPartialMatch(e_node, pos)) {
                return true;
            }
        }

        return self.dfsPartialMatch(self.start, pos + 1);
    }
};

pub const Nfa = struct {
    allocator: std.mem.Allocator,
    start: *Node,
    end: *Node,

    pub fn fromTokens(allocator: std.mem.Allocator, tokens: []const *Token) Nfa {
        var nfa = fromToken(allocator, tokens[0]);
        for (tokens[1..]) |token| {
            const nextNfa = fromToken(allocator, token);
            nfa.end.insertEpsilonTransition(nextNfa.start);
            nfa.end = nextNfa.end;
        }
        return nfa;
    }

    fn fromToken(allocator: std.mem.Allocator, token: *Token) Nfa {
        switch (token.*) {
            .literal => |l| {
                var start = Node.init(allocator);
                const end = Node.init(allocator);
                start.insertTransition(l, end);
                return .{ .allocator = allocator, .start = start, .end = end };
            },
            .group => |group| {
                return fromTokens(allocator, group);
            },
            .repeat => |r| {
                var nfa = fromToken(allocator, token.repeat.token);
                var count = r.max;
                if (r.max == INF) {
                    count = if (r.min == 0) 1 else r.min;
                }

                var terminal_nodes = NodeList.init(allocator);
                defer terminal_nodes.deinit();
                for (1..count) |j| {
                    const other = fromToken(allocator, token.repeat.token);
                    nfa.end.insertEpsilonTransition(other.start);
                    // Add epsilon transition to end for nodes greater than min count
                    if (j >= r.min) terminal_nodes.append(nfa.end) catch @panic("Error appending terminal node");
                    nfa.end = other.end;
                }

                for (terminal_nodes.items) |node| {
                    node.insertEpsilonTransition(nfa.end);
                }

                if (r.min == 0) nfa.start.insertEpsilonTransition(nfa.end);
                if (r.max == INF) nfa.end.insertEpsilonTransition(nfa.start);

                return nfa;
            },
            .alt => |a| {
                var start = Node.init(allocator);
                const end = Node.init(allocator);
                var left = fromToken(allocator, a.left);
                var right = fromToken(allocator, a.right);
                start.insertEpsilonTransition(left.start);
                start.insertEpsilonTransition(right.start);
                left.end.insertEpsilonTransition(end);
                right.end.insertEpsilonTransition(end);
                return .{ .allocator = allocator, .start = start, .end = end };
            },
            .range => |r| {
                var start = Node.init(allocator);
                const end = Node.init(allocator);
                for (0..MAX_U8) |c| {
                    if (r.isSet(c)) {
                        start.insertTransition(@intCast(c), end);
                    }
                }
                return .{ .allocator = allocator, .start = start, .end = end };
            },
        }
        unreachable;
    }

    pub fn partialMatch(self: Nfa, string: []const u8) bool {
        const matcher = Matcher{ .allocator = self.allocator, .string = string, .start = self.start, .end = self.end };
        return matcher.dfsPartialMatch(self.start, 0);
    }

    pub fn deinit(self: *Nfa) void {
        // dfs and deinit
        var stack = NodeList.init(self.allocator);
        defer stack.deinit();
        stack.append(self.start) catch @panic("Error appending to deinit dfs stack");

        var visited = std.AutoHashMap(usize, *Node).init(self.allocator);
        defer visited.deinit();

        while (stack.items.len != 0) {
            var curr = stack.pop();
            if (visited.get(@intFromPtr(curr)) != null) continue;
            visited.put(@intFromPtr(curr), curr) catch @panic("Error inserting into deinit dfs hashmap");

            const curr_neighbors = curr.neighborNodes(self.allocator);
            defer self.allocator.free(curr_neighbors);
            stack.appendSlice(curr_neighbors) catch @panic("Error appending to deinit dfs stack");
        }

        var it = visited.valueIterator();
        while (it.next()) |value_ptr| {
            value_ptr.*.deinit(self.allocator);
        }
    }
};

test "create Nfa from literal tokens" {
    const allocator = std.testing.allocator;
    const lit_a = Token.init(allocator);
    lit_a.* = .{ .literal = 'a' };
    const lit_s = Token.init(allocator);
    lit_s.* = .{ .literal = 's' };
    defer allocator.destroy(lit_a);
    defer allocator.destroy(lit_s);
    const tokens = [_]*Token{ lit_a, lit_s };

    var nfa = Nfa.fromTokens(allocator, &tokens);
    defer nfa.deinit();

    const a_end_node = nfa.start.transition.get('a').?;
    const s_node = a_end_node.e_transition.items[0];
    try std.testing.expect(s_node.transition.contains('s'));
}

test "match Nfa with literal regex" {
    const allocator = std.testing.allocator;
    const lit_a = Token.init(allocator);
    lit_a.* = .{ .literal = 'a' };
    const lit_s = Token.init(allocator);
    lit_s.* = .{ .literal = 's' };
    defer allocator.destroy(lit_a);
    defer allocator.destroy(lit_s);
    const tokens = [_]*Token{ lit_a, lit_s };

    var nfa = Nfa.fromTokens(allocator, &tokens);
    defer nfa.deinit();

    const mid = "pos_as_pos";
    try std.testing.expect(nfa.partialMatch(mid));

    const end = "pos_as";
    try std.testing.expect(nfa.partialMatch(end));

    const none = "none";
    try std.testing.expect(!nfa.partialMatch(none));

    const disjunct = "abs";
    try std.testing.expect(!nfa.partialMatch(disjunct));
}

test "match Nfa with repeating regex" {
    const allocator = std.testing.allocator;
    const lit_a = Token.init(allocator);
    lit_a.* = .{ .literal = 'a' };
    const repeat_a = Token.init(allocator);
    repeat_a.* = .{ .repeat = RepeatToken{ .min = 2, .max = 4, .token = lit_a } };
    defer allocator.destroy(lit_a);
    defer allocator.destroy(repeat_a);
    const tokens = [_]*Token{repeat_a};

    var nfa = Nfa.fromTokens(allocator, &tokens);
    defer nfa.deinit();

    const min = "baac";
    try std.testing.expect(nfa.partialMatch(min));

    const max = "baaaac";
    try std.testing.expect(nfa.partialMatch(max));

    const none = "bc";
    try std.testing.expect(!nfa.partialMatch(none));

    const less = "bac";
    try std.testing.expect(!nfa.partialMatch(less));
}

test "match Nfa with fixed repeating regex" {
    const allocator = std.testing.allocator;
    const lit_a = Token.init(allocator);
    lit_a.* = .{ .literal = 'a' };
    const repeat_a = Token.init(allocator);
    repeat_a.* = .{ .repeat = RepeatToken{ .min = 2, .max = 2, .token = lit_a } };
    defer allocator.destroy(lit_a);
    defer allocator.destroy(repeat_a);
    const tokens = [_]*Token{repeat_a};

    var nfa = Nfa.fromTokens(allocator, &tokens);
    defer nfa.deinit();

    const lt = "bac";
    try std.testing.expect(!nfa.partialMatch(lt));

    const eq = "baac";
    try std.testing.expect(nfa.partialMatch(eq));
}

test "match Nfa with * regex" {
    const allocator = std.testing.allocator;
    const lit_a = Token.init(allocator);
    lit_a.* = .{ .literal = 'a' };
    const repeat_a = Token.init(allocator);
    repeat_a.* = .{ .repeat = RepeatToken{ .min = 0, .max = INF, .token = lit_a } };
    defer allocator.destroy(lit_a);
    defer allocator.destroy(repeat_a);
    const tokens = [_]*Token{repeat_a};

    var nfa = Nfa.fromTokens(allocator, &tokens);
    defer nfa.deinit();

    const none = "bc";
    try std.testing.expect(nfa.partialMatch(none));

    const some = "baac";
    try std.testing.expect(nfa.partialMatch(some));
}

test "match Nfa with + regex" {
    const allocator = std.testing.allocator;
    const lit_a = Token.init(allocator);
    lit_a.* = .{ .literal = 'a' };
    const repeat_a = Token.init(allocator);
    repeat_a.* = .{ .repeat = RepeatToken{ .min = 1, .max = INF, .token = lit_a } };
    defer allocator.destroy(lit_a);
    defer allocator.destroy(repeat_a);
    const tokens = [_]*Token{repeat_a};

    var nfa = Nfa.fromTokens(allocator, &tokens);
    defer nfa.deinit();

    const none = "bc";
    try std.testing.expect(!nfa.partialMatch(none));

    const some = "baac";
    try std.testing.expect(nfa.partialMatch(some));
}

test "match Nfa with ? regex" {
    const allocator = std.testing.allocator;
    const lit_a = Token.init(allocator);
    lit_a.* = .{ .literal = 'a' };
    const repeat_a = Token.init(allocator);
    repeat_a.* = .{ .repeat = RepeatToken{ .min = 0, .max = 1, .token = lit_a } };
    defer allocator.destroy(lit_a);
    defer allocator.destroy(repeat_a);
    const tokens = [_]*Token{repeat_a};

    var nfa = Nfa.fromTokens(allocator, &tokens);
    defer nfa.deinit();

    const none = "bc";
    try std.testing.expect(nfa.partialMatch(none));

    const some = "bac";
    try std.testing.expect(nfa.partialMatch(some));
}

test "match Nfa with alt regex" {
    const allocator = std.testing.allocator;
    const lit_left = Token.init(allocator);
    lit_left.* = .{ .literal = 'a' };
    const lit_right = Token.init(allocator);
    lit_right.* = .{ .literal = 'b' };
    const alt = Token.init(allocator);
    alt.* = .{ .alt = AltToken{ .left = lit_left, .right = lit_right } };
    defer allocator.destroy(lit_left);
    defer allocator.destroy(lit_right);
    defer allocator.destroy(alt);
    const tokens = [_]*Token{alt};

    var nfa = Nfa.fromTokens(allocator, &tokens);
    defer nfa.deinit();

    const a = "ac";
    try std.testing.expect(nfa.partialMatch(a));

    const b = "bc";
    try std.testing.expect(nfa.partialMatch(b));
}

test "match Nfa with repeat regex" {
    const allocator = std.testing.allocator;
    var range = Range.initEmpty();
    for ('A'..'Z' + 1) |c| {
        range.toggle(@intCast(c));
    }
    const t = Token.init(allocator);
    t.* = .{ .range = range };
    defer allocator.destroy(t);
    const tokens = [_]*Token{t};

    var nfa = Nfa.fromTokens(allocator, &tokens);
    defer nfa.deinit();

    const lowercase = "abcdef";
    try std.testing.expect(!nfa.partialMatch(lowercase));

    const oneuppercase = "abcdefZwxyz";
    try std.testing.expect(nfa.partialMatch(oneuppercase));
}
