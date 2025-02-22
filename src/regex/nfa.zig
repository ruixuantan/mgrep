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

    // e_transition is ordered
    // so we can control where transitions to terminal node are located.
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

pub const SubstrIndex = struct { start: usize, end: usize };
const SubstrIndexList = std.ArrayList(SubstrIndex);

const Matcher = struct {
    string: []const u8,
    start: *Node,
    end: *Node,

    fn init(string: []const u8, start: *Node, end: *Node) Matcher {
        return .{ .string = string, .start = start, .end = end };
    }

    fn match(self: Matcher, node: *Node, i: usize) ?usize {
        if (node == self.end) {
            return i;
        }
        if (i >= self.string.len) {
            return null;
        }

        const next_node = node.transition.get(self.string[i]);
        if (next_node != null) {
            const res = self.match(next_node.?, i + 1);
            if (res != null) {
                return res.?;
            }
        }

        for (node.e_transition.items) |e_node| {
            const res = self.match(e_node, i);
            if (res != null) {
                return res.?;
            }
        }
        return null;
    }

    fn matchAll(self: *Matcher, allocator: std.mem.Allocator) []const SubstrIndex {
        var ls = SubstrIndexList.init(allocator);
        var i: usize = 0;
        while (i < self.string.len) {
            const j = self.match(self.start, i);
            if (j == null) {
                i += 1;
            } else {
                // condition happens when there is an epsilon transition to the terminal node
                const end = if (j.? == i) j.? + 1 else j.?;
                ls.append(.{ .start = i, .end = end }) catch @panic("Error appending to list of substring indexes");
                i = end;
            }
        }
        return ls.toOwnedSlice() catch @panic("Error converting list of substring indexes to slice");
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
                var start = Node.init(allocator);
                const end = Node.init(allocator);
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
                    if (j >= r.min) {
                        terminal_nodes.append(nfa.end) catch @panic("Error appending terminal node");
                    }
                    nfa.end = other.end;
                }

                // adding terminal epsilon transitions at the end results in greedy match
                for (terminal_nodes.items) |node| {
                    node.insertEpsilonTransition(end);
                }

                start.insertEpsilonTransition(nfa.start);
                if (r.min == 0) {
                    start.insertEpsilonTransition(end);
                }
                if (r.max == INF) {
                    nfa.end.insertEpsilonTransition(nfa.start);
                }
                nfa.end.insertEpsilonTransition(end);

                return .{ .allocator = allocator, .start = start, .end = end };
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

    pub fn matchAll(self: Nfa, string: []const u8) []const SubstrIndex {
        var matcher = Matcher.init(string, self.start, self.end);
        return matcher.matchAll(self.allocator);
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
            if (visited.get(@intFromPtr(curr)) != null) {
                continue;
            }
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

    const mid = nfa.matchAll("pos_as_pos_as");
    defer nfa.allocator.free(mid);
    const mid_res = [_]SubstrIndex{ SubstrIndex{ .start = 4, .end = 6 }, SubstrIndex{ .start = 11, .end = 13 } };
    try std.testing.expectEqualSlices(SubstrIndex, &mid_res, mid);

    try std.testing.expectEqual(0, nfa.matchAll("none").len);
    try std.testing.expectEqual(0, nfa.matchAll("abs").len);
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

    const min = nfa.matchAll("baac");
    defer nfa.allocator.free(min);
    const min_res = [_]SubstrIndex{SubstrIndex{ .start = 1, .end = 3 }};
    try std.testing.expectEqualSlices(SubstrIndex, &min_res, min);

    const max = nfa.matchAll("baaaac");
    defer nfa.allocator.free(max);
    const max_res = [_]SubstrIndex{SubstrIndex{ .start = 1, .end = 5 }};
    try std.testing.expectEqualSlices(SubstrIndex, &max_res, max);

    try std.testing.expectEqual(0, nfa.matchAll("bc").len);
    try std.testing.expectEqual(0, nfa.matchAll("bac").len);
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

    try std.testing.expectEqual(0, nfa.matchAll("bac").len);

    const eq = nfa.matchAll("baac");
    defer nfa.allocator.free(eq);
    const eq_res = [_]SubstrIndex{SubstrIndex{ .start = 1, .end = 3 }};
    try std.testing.expectEqualSlices(SubstrIndex, &eq_res, eq);
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

    const none = nfa.matchAll("bc");
    defer nfa.allocator.free(none);
    const none_res = [_]SubstrIndex{ SubstrIndex{ .start = 0, .end = 1 }, SubstrIndex{ .start = 1, .end = 2 } };
    try std.testing.expectEqualSlices(SubstrIndex, &none_res, none);

    const some = nfa.matchAll("baac");
    defer nfa.allocator.free(some);
    const some_res = [_]SubstrIndex{ SubstrIndex{ .start = 0, .end = 1 }, SubstrIndex{ .start = 1, .end = 3 }, SubstrIndex{ .start = 3, .end = 4 } };
    try std.testing.expectEqualSlices(SubstrIndex, &some_res, some);
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

    try std.testing.expectEqual(0, nfa.matchAll("bc").len);

    const some = nfa.matchAll("baac");
    defer nfa.allocator.free(some);
    const some_res = [_]SubstrIndex{SubstrIndex{ .start = 1, .end = 3 }};
    try std.testing.expectEqualSlices(SubstrIndex, &some_res, some);
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

    const none = nfa.matchAll("bc");
    defer nfa.allocator.free(none);
    const none_res = [_]SubstrIndex{ SubstrIndex{ .start = 0, .end = 1 }, SubstrIndex{ .start = 1, .end = 2 } };
    try std.testing.expectEqualSlices(SubstrIndex, &none_res, none);

    const some = nfa.matchAll("bac");
    defer nfa.allocator.free(some);
    const some_res = [_]SubstrIndex{ SubstrIndex{ .start = 0, .end = 1 }, SubstrIndex{ .start = 1, .end = 2 }, SubstrIndex{ .start = 2, .end = 3 } };
    try std.testing.expectEqualSlices(SubstrIndex, &some_res, some);
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

    const a = nfa.matchAll("ac");
    defer nfa.allocator.free(a);
    const a_res = [_]SubstrIndex{SubstrIndex{ .start = 0, .end = 1 }};
    try std.testing.expectEqualSlices(SubstrIndex, &a_res, a);

    const b = nfa.matchAll("bc");
    defer nfa.allocator.free(b);
    const b_res = [_]SubstrIndex{SubstrIndex{ .start = 0, .end = 1 }};
    try std.testing.expectEqualSlices(SubstrIndex, &b_res, b);
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

    try std.testing.expectEqual(0, nfa.matchAll("abcdef").len);

    const oneuppercase = nfa.matchAll("abcdefZwxyz");
    defer nfa.allocator.free(oneuppercase);
    const oneuppercase_res = [_]SubstrIndex{SubstrIndex{ .start = 6, .end = 7 }};
    try std.testing.expectEqualSlices(SubstrIndex, &oneuppercase_res, oneuppercase);
}
