//! trade-atlas command line.
//!   atlas sources            list every data source and its freshness class
//!   atlas probe [id ...]     fetch a real sample from each (or the named) source(s)
//!                            into ./fixtures/<id>/ and print a summary

const std = @import("std");
const Io = std.Io;
const atlas = @import("atlas");
const registry = atlas.registry;
const probe = atlas.probe;
const time = atlas.time;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [4096]u8 = undefined;
    var out_w: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_w.interface;
    defer out.flush() catch {};

    if (args.len < 2 or std.mem.eql(u8, args[1], "help") or std.mem.eql(u8, args[1], "--help")) {
        try out.writeAll(
            \\usage:
            \\  atlas sources          list data sources
            \\  atlas probe [id ...]   fetch real samples into ./fixtures/<id>/
            \\
        );
        return;
    }

    if (std.mem.eql(u8, args[1], "sources")) {
        for (registry.sources) |s| {
            const key = s.auth.env() orelse "-";
            try out.print("{s:<28} {s:<9} {s:<10} key={s:<18} {s}\n", .{ s.id, s.freshness.label(), @tagName(s.family), key, s.name });
        }
        return;
    }

    if (std.mem.eql(u8, args[1], "probe")) {
        var http = try atlas.https.Client.init(gpa, io, init.environ_map);
        defer http.deinit();
        var dir = try Io.Dir.cwd().createDirPathOpen(io, "fixtures", .{});
        defer dir.close(io);

        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(gpa);
        if (args.len > 2) {
            for (args[2..]) |a| {
                if (registry.find(a) == null) {
                    try out.print("unknown source '{s}' (see `atlas sources`)\n", .{a});
                    return;
                }
                try ids.append(gpa, a);
            }
        } else for (registry.sources) |s| try ids.append(gpa, s.id);

        var failures: usize = 0;
        for (ids.items) |id| {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var ctx: probe.Ctx = .{
                .gpa = gpa,
                .arena = arena.allocator(),
                .io = io,
                .http = &http,
                .env = init.environ_map,
                .out_dir = dir,
                .now = Io.Clock.real.now(io).toSeconds(),
            };
            const r = probe.probeOne(&ctx, id);
            if (r.outcome == .failed) failures += 1;
            var b: [20]u8 = undefined;
            const age = if (r.data_time) |t| try std.fmt.allocPrint(ctx.arena, "{d:.1} d old", .{@as(f64, @floatFromInt(ctx.now - t)) / 86400.0}) else "no timestamp";
            try out.print("{s:<28} {s:<8} http={d:<3} data={s} ({s})\n    {s}\n", .{
                id,                                                    @tagName(r.outcome), r.http_status,
                if (r.data_time) |t| time.formatIso(&b, t) else "n/a", age,                 r.note,
            });
            try out.flush();
        }
        try out.print("\n{d}/{d} sources failed. Details in fixtures/<id>/PROBE.md\n", .{ failures, ids.items.len });
        return;
    }

    try out.print("unknown command '{s}'\n", .{args[1]});
}
