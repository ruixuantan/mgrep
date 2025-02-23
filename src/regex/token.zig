const std = @import("std");
const Nfa = @import("nfa.zig").Nfa;

pub const INF = std.math.maxInt(usize);
pub const MAX_U8 = std.math.maxInt(u8);

pub const Range = std.bit_set.IntegerBitSet(MAX_U8);

pub const RepeatToken = struct { min: usize, max: usize, token: *Token };
pub const AltToken = struct { left: *Token, right: *Token };

pub const Token = union(enum) {
    literal: u8,
    group: []const *Token,
    repeat: RepeatToken,
    alt: AltToken,
    range: Range,

    pub fn init(allocator: std.mem.Allocator) *Token {
        return allocator.create(Token) catch @panic("Error initialising Token");
    }

    pub fn deinit(self: *Token, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .literal, .range => {},
            .group => |g| {
                for (g) |t| {
                    t.deinit(allocator);
                }
                allocator.free(g);
            },
            .repeat => |r| r.token.deinit(allocator),
            .alt => |a| {
                a.left.deinit(allocator);
                a.right.deinit(allocator);
            },
        }
        allocator.destroy(self);
    }

    pub fn debug_print(self: Token) void {
        switch (self) {
            .literal => |l| std.debug.print("(Literal: {c})", .{l}),
            .group => |g| {
                std.debug.print("(Group: ", .{});
                for (g) |t| {
                    t.debug_print();
                }
                std.debug.print(")", .{});
            },
            .repeat => |r| {
                std.debug.print("(Repeat min: {d}, max: {d}, token: ", .{ r.min, r.max });
                r.token.debug_print();
                std.debug.print(")", .{});
            },
            .alt => |a| {
                std.debug.print("(Alt left: ", .{});
                a.left.debug_print();
                std.debug.print(" right: ", .{});
                a.right.debug_print();
                std.debug.print(")", .{});
            },
            .range => |r| {
                std.debug.print("(Range: ");
                for (1..MAX_U8) |c| {
                    if (r.isSet(c) and !r.isSet(c - 1)) {
                        std.debug.print("{c}-", .{c});
                    } else if (!r.isSet(c) and r.isSet(c - 1)) {
                        std.debug.print("{c} ", .{c - 1});
                    }
                }
                std.debug.print(")", .{});
            },
        }
    }
};

pub const TokenList = std.ArrayList(*Token);
