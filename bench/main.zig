//! Single-process file benchmark driver. Timings are collected externally.
const std = @import("std");
const Bao = @import("bao");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return error.ExpectedModeAndInputPath;
    const root = if (std.mem.eql(u8, args[1], "hash"))
        try Bao.hashFile(init.io, .cwd(), args[2])
    else if (std.mem.eql(u8, args[1], "parallel")) blk: {
        if (args.len != 5) return error.ExpectedOutputPathAndWorkers;
        if (std.mem.eql(u8, args[2], args[3])) return error.InputIsOutput;
        const workers = try std.fmt.parseInt(usize, args[4], 10);
        const input = try std.Io.Dir.cwd().openFile(init.io, args[2], .{});
        defer input.close(init.io);
        const stat = try input.stat(init.io);
        const output = try std.Io.Dir.cwd().createFile(init.io, args[3], .{});
        defer output.close(init.io);
        break :blk try Bao.Parallel.encodeFile(init.io, init.gpa, input, stat.size, output, workers);
    } else if (std.mem.eql(u8, args[1], "outboard")) blk: {
        if (args.len != 4) return error.ExpectedOutputPath;
        if (std.mem.eql(u8, args[2], args[3])) return error.InputIsOutput;
        const file = try std.Io.Dir.cwd().createFile(init.io, args[3], .{});
        defer file.close(init.io);
        var buffer: [1024 * 1024]u8 = undefined;
        var writer = file.writerStreaming(init.io, &buffer);
        const encoded = try Bao.encodeFile(init.io, .cwd(), args[2], &writer.interface);
        try writer.interface.flush();
        break :blk encoded.root;
    } else return error.UnknownMode;
    std.debug.print("{x}\n", .{root});
}
