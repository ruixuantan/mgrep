const std = @import("std");
const RegexParser = @import("regex/parser.zig").Parser;
const Nfa = @import("regex/nfa.zig").Nfa;
const MgrepParser = @import("parser.zig").Parser;
const MgrepConfig = @import("parser.zig").MgrepConfig;
const FileType = @import("parser.zig").FileType;
const MgrepFilelinebuf = @import("filelinebuffer.zig").Filelinebuffer(1024);

fn mgrep(allocator: std.mem.Allocator, config: MgrepConfig) !void {
    std.debug.assert(config.pattern != null);

    const parser = RegexParser.init(allocator);
    defer parser.deinit();
    const ls = parser.parse(config.pattern.?) catch |err| {
        std.log.err("{}", .{err});
        std.process.exit(1);
    };
    var nfa = Nfa.fromTokens(allocator, ls.items);
    defer nfa.deinit();
    const outw = std.io.getStdOut().writer();
    var inputbuf = std.ArrayList(u8).init(allocator);
    defer inputbuf.deinit();

    for (config.filetypes.items) |filetype| {
        const filename = switch (filetype) {
            .stdin => "(standard input)",
            .file => |f| f,
        };
        var filelinebuf = MgrepFilelinebuf.init(allocator, filename);
        defer filelinebuf.deinit();

        var input: std.io.AnyReader = undefined;
        var file: std.fs.File = undefined;
        switch (filetype) {
            .stdin => input = std.io.getStdIn().reader().any(),
            .file => |f| {
                file = std.fs.cwd().openFile(f, .{}) catch |err| {
                    std.log.err("{}", .{err});
                    std.process.exit(1);
                };
                input = file.reader().any();
            },
        }
        defer if (@TypeOf(filetype) == @TypeOf(FileType.file)) file.close();

        var buffered = std.io.bufferedReader(input);
        const reader = buffered.reader();

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

    var mgrep_parser = try MgrepParser.init(allocator, args);
    defer mgrep_parser.deinit();
    mgrep_parser.parse() catch |err| {
        std.log.err("{}", .{err});
        std.process.exit(1);
    };
    try mgrep(allocator, mgrep_parser.config);
}
