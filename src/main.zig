const std = @import("std");
const FileLine = @import("fileline.zig").FileLine;
const Parser = @import("regex/parser.zig").Parser;
const ParseError = @import("regex/parser.zig").ParseError;
const Nfa = @import("regex/nfa.zig").Nfa;

pub fn mgrep(allocator: std.mem.Allocator, outw: anytype, pattern: []const u8, filename: []const u8) !void {
    var file = std.fs.cwd().openFile(filename, .{}) catch |err| {
        std.log.err("{}", .{err});
        std.process.exit(1);
    };
    defer file.close();

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var buffered = std.io.bufferedReader(file.reader());
    var reader = buffered.reader();
    var line_count: usize = 0;

    const parser = Parser.init(allocator);
    defer parser.deinit();
    const ls = parser.parse(pattern) catch |err| {
        std.log.err("{}", .{err});
        std.process.exit(1);
    };
    var nfa = Nfa.fromTokens(allocator, ls.items);
    defer nfa.deinit();

    while (true) {
        reader.streamUntilDelimiter(buf.writer(), '\n', null) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        line_count += 1;
        const line = try buf.toOwnedSlice();
        defer allocator.free(line);
        const fileline = FileLine.init(line_count, filename, line);
        if (nfa.partialMatch(fileline.line)) {
            try fileline.print(outw);
        }
        buf.clearRetainingCapacity();
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const outw = std.io.getStdOut().writer();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 3) {
        try outw.print("usage: mgrep [pattern] [file]\n", .{});
        return;
    }
    try mgrep(allocator, outw, args[1], args[2]);
}
