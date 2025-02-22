const std = @import("std");
const RegexParser = @import("regex/parser.zig").Parser;
const Nfa = @import("regex/nfa.zig").Nfa;
const MgrepParser = @import("parser.zig").Parser;
const MgrepConfig = @import("parser.zig").MgrepConfig;

const MgrepFilelinebufSize: usize = 1024;
const MgrepFilelinebuf = @import("filelinebuffer.zig").Filelinebuffer(MgrepFilelinebufSize);

pub fn mgrep(allocator: std.mem.Allocator, outw: anytype, config: MgrepConfig) !void {
    std.debug.assert(config.pattern != null);
    std.debug.assert(config.text != null or config.filenames != null);

    var inputbuf = std.ArrayList(u8).init(allocator);
    defer inputbuf.deinit();

    for (config.filenames.?) |filename| {
        var filelinebuf = MgrepFilelinebuf.init(allocator, filename);
        defer filelinebuf.deinit();

        var file = std.fs.cwd().openFile(filename, .{}) catch |err| {
            std.log.err("{}", .{err});
            std.process.exit(1);
        };
        defer file.close();
        var buffered = std.io.bufferedReader(file.reader());
        var reader = buffered.reader();

        const parser = RegexParser.init(allocator);
        defer parser.deinit();
        const ls = parser.parse(config.pattern.?) catch |err| {
            std.log.err("{}", .{err});
            std.process.exit(1);
        };
        var nfa = Nfa.fromTokens(allocator, ls.items);
        defer nfa.deinit();

        while (true) {
            reader.streamUntilDelimiter(inputbuf.writer(), '\n', null) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            const line = try inputbuf.toOwnedSlice();
            try filelinebuf.add(line, nfa.matchAll(line));
            if (filelinebuf.isFull()) {
                try filelinebuf.print(outw, config);
                filelinebuf.reset();
            }
            inputbuf.clearRetainingCapacity();
        }

        try filelinebuf.print(outw, config);
        try filelinebuf.aggregatePrint(outw, config);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const outw = std.io.getStdOut().writer();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len == 1) {
        try outw.print("usage: mgrep [-chlnv] [pattern] [file ...]\n", .{});
        return;
    }

    var mgrep_parser = MgrepParser.init(args);
    mgrep_parser.parse() catch |err| {
        std.log.err("{}", .{err});
        std.process.exit(1);
    };
    try mgrep(allocator, outw, mgrep_parser.config);
}
