//! `atlas probe`: fetch one real sample from every source, check that the
//! fields our parsers rely on are present, and record what came back.
//! Output per source in fixtures/<id>/:
//!   sample.*   the raw response (or a trimmed excerpt), marked as a FIXTURE
//!   schema.txt key paths and types seen in the response
//!   PROBE.md   URL (keys redacted), HTTP status, size, fetch time, data time
//! API keys are read from the environment and never written to disk.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const https = @import("net/https.zig");
const ws = @import("net/websocket.zig");
const registry = @import("ingest/registry.zig");
const schema = @import("ingest/schema.zig");
const time = @import("util/time.zig");
const zip = @import("util/zip.zig");
const usgs = @import("ingest/usgs.zig");
const gdacs = @import("ingest/gdacs.zig");
const portwatch = @import("ingest/portwatch.zig");
const fred = @import("ingest/fred.zig");
const comtrade = @import("ingest/comtrade.zig");
const gdelt = @import("ingest/gdelt.zig");
const ais = @import("ingest/aisstream.zig");
const opensanctions = @import("ingest/opensanctions.zig");

pub const Outcome = enum { ok, degraded, failed, skipped };

pub const Result = struct {
    id: []const u8,
    outcome: Outcome = .failed,
    http_status: u16 = 0,
    bytes: usize = 0,
    fetched_at: i64 = 0,
    /// Newest timestamp inside the data (Unix s), if the source has one.
    data_time: ?i64 = null,
    /// One-line human summary.
    note: []const u8 = "",
    url: []const u8 = "",
};

pub const Ctx = struct {
    gpa: Allocator,
    /// Freed after each source.
    arena: Allocator,
    io: Io,
    http: *https.Client,
    env: *const std.process.Environ.Map,
    out_dir: Io.Dir,
    now: i64,

    fn key(c: *Ctx, name: []const u8) ?[]const u8 {
        const v = c.env.get(name) orelse return null;
        return if (v.len == 0) null else v;
    }

    fn get(c: *Ctx, url: []const u8, headers: []const https.Header) !https.Response {
        return c.http.get(url, headers);
    }

    fn save(c: *Ctx, id: []const u8, name: []const u8, data: []const u8) !void {
        var dir = try c.out_dir.createDirPathOpen(c.io, id, .{});
        defer dir.close(c.io);
        try dir.writeFile(c.io, .{ .sub_path = name, .data = data });
    }

    fn saveSchema(c: *Ctx, id: []const u8, json: []const u8) void {
        const s = schema.summariseSlice(c.arena, json) catch return;
        c.save(id, "schema.txt", s) catch {};
    }

    fn date(c: *Ctx, days_ago: i64) []const u8 {
        var b: [20]u8 = undefined;
        const s = time.formatIso(&b, c.now - days_ago * 86400);
        return c.arena.dupe(u8, s[0..10]) catch "1970-01-01";
    }
};

/// Replace the value of `param=` query parameters that carry secrets.
pub fn redact(gpa: Allocator, url: []const u8, params: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    outer: while (i < url.len) {
        for (params) |p| {
            if ((url[i] == '?' or url[i] == '&') and std.mem.startsWith(u8, url[i + 1 ..], p) and
                i + 1 + p.len < url.len and url[i + 1 + p.len] == '=')
            {
                try out.appendSlice(gpa, url[i .. i + 2 + p.len]);
                try out.appendSlice(gpa, "<REDACTED>");
                i += 2 + p.len;
                while (i < url.len and url[i] != '&') i += 1;
                continue :outer;
            }
        }
        try out.append(gpa, url[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn finish(r: *Result, resp: *const https.Response) void {
    r.http_status = resp.status;
    r.bytes = resp.body.len;
    r.outcome = if (resp.status == 200) .ok else .failed;
}

fn probeUsgs(c: *Ctx, r: *Result) !void {
    r.url = "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/4.5_week.geojson";
    var resp = try c.get(r.url, &.{});
    defer resp.deinit(c.gpa);
    finish(r, &resp);
    if (resp.status != 200) return;
    const p = try usgs.parse(c.gpa, resp.body);
    defer p.deinit();
    r.data_time = usgs.newestEventTime(p.value);
    r.note = try std.fmt.allocPrint(c.arena, "{d} quakes M4.5+ in past week", .{p.value.features.len});
    try c.save(r.id, "sample.json", resp.body);
    c.saveSchema(r.id, resp.body);
}

fn probeGdacs(c: *Ctx, r: *Result) !void {
    r.url = try std.fmt.allocPrint(c.arena, "https://www.gdacs.org/gdacsapi/api/events/geteventlist/SEARCH?eventlist=EQ;TC;FL;VO;DR;WF&fromDate={s}&toDate={s}", .{ c.date(14), c.date(0) });
    var resp = try c.get(r.url, &.{});
    defer resp.deinit(c.gpa);
    finish(r, &resp);
    if (resp.status != 200) return;
    const p = try gdacs.parse(c.gpa, resp.body);
    defer p.deinit();
    r.data_time = gdacs.newestModified(p.value);
    r.note = try std.fmt.allocPrint(c.arena, "{d} events in past 14 days", .{p.value.features.len});
    try c.save(r.id, "sample.json", resp.body);
    c.saveSchema(r.id, resp.body);
}

fn probePortwatchDaily(c: *Ctx, r: *Result, layer: portwatch.Layer, portid: []const u8, comptime Attr: type) !void {
    // Cheap freshness check first: when did IMF last edit the layer?
    const info_url = try portwatch.layerInfoUrl(c.arena, layer);
    var edited: ?i64 = null;
    if (c.get(info_url, &.{})) |info_resp| {
        var ir = info_resp;
        defer ir.deinit(c.gpa);
        if (portwatch.parse(portwatch.LayerInfo, c.gpa, ir.body)) |li| {
            defer li.deinit();
            if (li.value.editingInfo) |e| if (e.dataLastEditDate) |ms| {
                edited = @divFloor(ms, 1000);
            };
        } else |_| {}
    } else |_| {}

    const where = try std.fmt.allocPrint(c.arena, "portid='{s}' AND date>=DATE '{s}'", .{ portid, c.date(21) });
    r.url = try portwatch.queryUrl(c.arena, layer, where, "*", "");
    var resp = try c.get(r.url, &.{});
    defer resp.deinit(c.gpa);
    finish(r, &resp);
    try c.save(r.id, "sample.json", resp.body);
    if (resp.status != 200) return;
    if (std.mem.indexOf(u8, resp.body, "\"error\"") != null and std.mem.indexOf(u8, resp.body, "\"features\"") == null) {
        r.outcome = .failed;
        r.note = try std.fmt.allocPrint(c.arena, "ArcGIS error: {s}", .{resp.body[0..@min(160, resp.body.len)]});
        return;
    }
    c.saveSchema(r.id, resp.body);
    const p = try portwatch.parse(portwatch.QueryResult(Attr), c.gpa, resp.body);
    defer p.deinit();
    if (portwatch.latestDate(Attr, p.value)) |d| r.data_time = time.parseIso(d) catch null;
    var eb: [20]u8 = undefined;
    r.note = try std.fmt.allocPrint(c.arena, "{d} daily rows for {s}; layer last edited {s}", .{
        p.value.features.len, portid, if (edited) |e| time.formatIso(&eb, e) else "unknown",
    });
    if (p.value.features.len == 0) r.outcome = .degraded;
}

fn probePortwatchTable(c: *Ctx, r: *Result, layer: portwatch.Layer, extra: []const u8, comptime Attr: type) !void {
    r.url = try portwatch.queryUrl(c.arena, layer, "1=1", "*", extra);
    var resp = try c.get(r.url, &.{});
    defer resp.deinit(c.gpa);
    finish(r, &resp);
    if (resp.status != 200) return;
    try c.save(r.id, "sample.json", resp.body);
    c.saveSchema(r.id, resp.body);
    const p = try portwatch.parse(portwatch.QueryResult(Attr), c.gpa, resp.body);
    defer p.deinit();
    r.note = try std.fmt.allocPrint(c.arena, "{d} rows (exceededTransferLimit={?})", .{ p.value.features.len, p.value.exceededTransferLimit });
    if (Attr == portwatch.Disruption) {
        for (p.value.features) |f| if (f.attributes.fromdate) |ms| {
            r.data_time = @max(r.data_time orelse @divFloor(ms, 1000), @divFloor(ms, 1000));
        };
    } else if (Attr == portwatch.TradeNow) {
        for (p.value.features) |f| {
            const t = time.parseIso(f.attributes.date) catch continue;
            r.data_time = @max(r.data_time orelse t, t);
        }
    }
}

fn probeFred(c: *Ctx, r: *Result) !void {
    const k = c.key("FRED_API_KEY") orelse {
        r.outcome = .skipped;
        r.note = "FRED_API_KEY not set";
        return;
    };
    var buf: [512]u8 = undefined;
    var notes: std.ArrayList(u8) = .empty;
    for (fred.series) |s| {
        const url = try fred.observationsUrl(&buf, s.id, k, 5);
        r.url = try redact(c.arena, url, &.{"api_key"});
        var resp = try c.get(url, &.{});
        defer resp.deinit(c.gpa);
        finish(r, &resp);
        if (resp.status != 200) {
            try notes.print(c.arena, "{s}: HTTP {d}; ", .{ s.id, resp.status });
            continue;
        }
        const p = try fred.parse(c.gpa, resp.body);
        defer p.deinit();
        if (p.value.observations.len > 0) {
            const o = p.value.observations[0];
            try notes.print(c.arena, "{s} {s}={s}; ", .{ s.id, o.date, o.value });
            if (std.mem.eql(u8, s.id, "DCOILBRENTEU")) {
                r.data_time = time.parseIso(o.date) catch null;
                try c.save(r.id, "sample.json", resp.body);
                c.saveSchema(r.id, resp.body);
            }
        }
    }
    r.note = notes.items;
}

fn probeComtrade(c: *Ctx, r: *Result) !void {
    const k = c.key("COMTRADE_API_KEY") orelse {
        r.outcome = .skipped;
        r.note = "COMTRADE_API_KEY not set";
        return;
    };
    const hdr = [_]https.Header{.{ .name = comtrade.key_header, .value = k }};
    // 1) What is available? USA, DEU, CHE, CHN, JPN, SGP
    const da_url = comtrade.host ++ "/data/v1/getDA/C/M/HS?reporterCode=842,276,757,156,392,702";
    var da = try c.get(da_url, &hdr);
    defer da.deinit(c.gpa);
    if (da.status != 200) {
        finish(r, &da);
        r.url = da_url;
        return;
    }
    const av = try comtrade.parseAvailability(c.gpa, da.body);
    defer av.deinit();
    var notes: std.ArrayList(u8) = .empty;
    try notes.appendSlice(c.arena, "latest monthly period: ");
    const reporters = [_]struct { code: i64, iso: []const u8 }{
        .{ .code = 842, .iso = "USA" }, .{ .code = 276, .iso = "DEU" }, .{ .code = 757, .iso = "CHE" },
        .{ .code = 156, .iso = "CHN" }, .{ .code = 392, .iso = "JPN" }, .{ .code = 702, .iso = "SGP" },
    };
    for (reporters) |rep| try notes.print(c.arena, "{s} {?d}, ", .{ rep.iso, comtrade.latestPeriod(av.value, rep.code) });
    const us_latest = comtrade.latestPeriod(av.value, 842) orelse 0;

    // 2) A real data slice: US imports from China, HS 27/84/85, latest month, all modes.
    r.url = try std.fmt.allocPrint(c.arena, "{s}/data/v1/get/C/M/HS?reporterCode=842&period={d}&partnerCode=156&cmdCode=27,84,85&flowCode=M&includeDesc=true", .{ comtrade.host, us_latest });
    var resp = try c.get(r.url, &hdr);
    defer resp.deinit(c.gpa);
    finish(r, &resp);
    if (resp.status != 200) return;
    try c.save(r.id, "sample.json", resp.body);
    c.saveSchema(r.id, resp.body);
    const p = try comtrade.parseData(c.gpa, resp.body);
    defer p.deinit();
    var sea: f64 = 0;
    var total: f64 = 0;
    for (p.value.data) |row| {
        if (!std.mem.eql(u8, row.customsCode orelse "C00", "C00")) continue;
        const v = row.primaryValue orelse 0;
        switch (comtrade.mode(row.motCode)) {
            .total => total += v,
            .sea => sea += v,
            else => {},
        }
    }
    try notes.print(c.arena, "| USA<-CHN HS27/84/85 {d}: {d} rows, sea share {d:.1}%", .{ us_latest, p.value.data.len, if (total > 0) 100 * sea / total else 0 });
    r.data_time = time.parsePeriod(try std.fmt.allocPrint(c.arena, "{d}", .{us_latest})) catch null;
    r.note = notes.items;
}

fn probeCensus(c: *Ctx, r: *Result) !void {
    const k = c.key("CENSUS_API_KEY") orelse {
        r.outcome = .skipped;
        r.note = "CENSUS_API_KEY not set";
        return;
    };
    // Port 5301 = Houston-Galveston district port of Houston; HS 27 (fuels). Month two back.
    const url = try std.fmt.allocPrint(c.arena, "https://api.census.gov/data/timeseries/intltrade/imports/porths?get=PORT,PORT_NAME,CTY_NAME,GEN_VAL_MO,VES_VAL_MO,VES_WGT_MO&I_COMMODITY=27&time={s}&PORT=5301&key={s}", .{ c.date(70)[0..7], k });
    r.url = try redact(c.arena, url, &.{"key"});
    var resp = try c.http.getOnce(url, &.{});
    defer resp.deinit(c.gpa);
    finish(r, &resp);
    if (resp.status == 302) {
        const loc = resp.header("location") orelse "";
        r.note = try std.fmt.allocPrint(c.arena, "redirected to {s} (key not accepted: activate it via the link in the Census e-mail)", .{loc});
        return;
    }
    if (resp.status != 200) return;
    try c.save(r.id, "sample.json", resp.body);
    r.note = "ok";
}

fn probeGdelt(c: *Ctx, r: *Result) !void {
    r.url = "https://data.gdeltproject.org/gdeltv2/lastupdate.txt";
    var lu_resp = try c.get(r.url, &.{});
    defer lu_resp.deinit(c.gpa);
    finish(r, &lu_resp);
    if (lu_resp.status != 200) return;
    try c.save(r.id, "lastupdate.txt", lu_resp.body);
    const lu = try gdelt.parseLastUpdate(lu_resp.body);
    r.data_time = lu.stamp;
    var b: [256]u8 = undefined;
    const export_url = try gdelt.httpsUrl(&b, lu.export_url);
    var z = try c.get(export_url, &.{});
    defer z.deinit(c.gpa);
    if (z.status != 200) {
        r.outcome = .degraded;
        r.note = try std.fmt.allocPrint(c.arena, "lastupdate ok, export zip HTTP {d}", .{z.status});
        return;
    }
    const tsv = try zip.extractFirst(c.gpa, z.body);
    defer c.gpa.free(tsv);
    var lines = std.mem.tokenizeScalar(u8, tsv, '\n');
    var n: usize = 0;
    var bad: usize = 0;
    var excerpt: std.ArrayList(u8) = .empty;
    while (lines.next()) |line| : (n += 1) {
        _ = gdelt.parseEvent(std.mem.trimEnd(u8, line, "\r")) catch {
            bad += 1;
            continue;
        };
        if (n < 25) {
            try excerpt.appendSlice(c.arena, line);
            try excerpt.append(c.arena, '\n');
        }
    }
    try c.save(r.id, "export_excerpt.tsv", excerpt.items);
    r.note = try std.fmt.allocPrint(c.arena, "{d} events in latest 15-min file, {d} rows failed the 61-column check", .{ n, bad });
    r.bytes = z.body.len;
}

fn probeOpenSanctions(c: *Ctx, r: *Result) !void {
    r.url = opensanctions.index_url;
    var resp = try c.get(r.url, &.{});
    defer resp.deinit(c.gpa);
    finish(r, &resp);
    if (resp.status != 200) return;
    try c.save(r.id, "index.json", resp.body);
    c.saveSchema(r.id, resp.body);
    const p = try opensanctions.parseIndex(c.gpa, resp.body);
    defer p.deinit();
    r.data_time = time.parseIso(p.value.updated_at) catch null;
    var header_ok = false;
    for (p.value.resources) |res| if (std.mem.eql(u8, res.name, "maritime.csv")) {
        var head = c.get(res.url, &.{.{ .name = "Range", .value = "bytes=0-8191" }}) catch break;
        defer head.deinit(c.gpa);
        const first = std.mem.sliceTo(head.body, '\n');
        header_ok = std.mem.eql(u8, std.mem.trimEnd(u8, first, "\r"), opensanctions.csv_header);
        try c.save(r.id, "maritime_head.csv", head.body[0 .. std.mem.lastIndexOfScalar(u8, head.body, '\n') orelse head.body.len]);
    };
    r.note = try std.fmt.allocPrint(c.arena, "{?d} targets; maritime.csv header matches parser: {}", .{ p.value.target_count, header_ok });
    if (!header_ok) r.outcome = .degraded;
}

fn probeUnga(c: *Ctx, r: *Result) !void {
    r.url = "https://dataverse.harvard.edu/api/datasets/:persistentId/?persistentId=doi:10.7910/DVN/LEJUQZ";
    var resp = try c.get(r.url, &.{});
    defer resp.deinit(c.gpa);
    finish(r, &resp);
    if (resp.status != 200) return;
    const V = struct { data: struct { latestVersion: struct {
        releaseTime: []const u8,
        versionNumber: ?i64 = null,
        files: []struct { dataFile: struct { filename: []const u8, filesize: ?i64 = null } },
    } } };
    const p = try std.json.parseFromSlice(V, c.gpa, resp.body, .{ .ignore_unknown_fields = true });
    defer p.deinit();
    const v = p.value.data.latestVersion;
    r.data_time = time.parseIso(v.releaseTime) catch null;
    var list: std.ArrayList(u8) = .empty;
    for (v.files) |f| try list.print(c.arena, "{s} ({?d} bytes)\n", .{ f.dataFile.filename, f.dataFile.filesize });
    try c.save(r.id, "files.txt", list.items);
    r.note = try std.fmt.allocPrint(c.arena, "version {?d}, {d} files", .{ v.versionNumber, v.files.len });
}

fn probeBinary(c: *Ctx, r: *Result, url: []const u8, magic: []const u8, what: []const u8) !void {
    r.url = url;
    var resp = try c.get(url, &.{});
    defer resp.deinit(c.gpa);
    finish(r, &resp);
    if (resp.status != 200) return;
    const ok = std.mem.startsWith(u8, resp.body, magic);
    if (!ok) r.outcome = .degraded;
    r.note = try std.fmt.allocPrint(c.arena, "{s}; magic bytes ok: {}", .{ what, ok });
}

fn probeNga(c: *Ctx, r: *Result) !void {
    r.url = "https://msi.nga.mil/api/publications/broadcast-warn?output=json&status=active";
    var resp = try c.get(r.url, &.{});
    defer resp.deinit(c.gpa);
    finish(r, &resp);
    if (resp.status == 200) {
        try c.save(r.id, "sample.json", resp.body);
        c.saveSchema(r.id, resp.body);
        r.note = "ok";
    } else if (std.mem.indexOf(u8, resp.body, "MAINTENANCE") != null) {
        r.note = "portal reports 'MSI IS CURRENTLY UNDER MAINTENANCE'";
    }
}

fn probeAis(c: *Ctx, r: *Result) !void {
    const k = c.key("AISSTREAM_API_KEY") orelse {
        r.outcome = .skipped;
        r.note = "AISSTREAM_API_KEY not set";
        return;
    };
    r.url = ais.url;
    var cl = try ws.Client.connect(c.http, ais.url);
    defer cl.close();
    const sub = try ais.subscription(c.gpa, k, &.{.{ .lat_min = -90, .lon_min = -180, .lat_max = 90, .lon_max = 180 }}, &.{});
    defer c.gpa.free(sub);
    try cl.sendText(sub);
    var samples: std.ArrayList(u8) = .empty;
    var counts = std.StringHashMap(usize).init(c.arena);
    var n: usize = 0;
    while (n < 200) : (n += 1) {
        const m = try cl.receive();
        defer c.gpa.free(m.data);
        r.bytes += m.data.len;
        const p = ais.parse(c.gpa, m.data) catch continue;
        defer p.deinit();
        const t = try c.arena.dupe(u8, p.value.MessageType);
        const e = try counts.getOrPut(t);
        if (!e.found_existing) {
            e.value_ptr.* = 0;
            try samples.appendSlice(c.arena, m.data);
            try samples.append(c.arena, '\n');
        }
        e.value_ptr.* += 1;
        if (p.value.MetaData) |md| if (time.parseIso(md.time_utc)) |ts| {
            r.data_time = @max(r.data_time orelse ts, ts);
        } else |_| {};
    }
    try c.save(r.id, "messages.jsonl", samples.items);
    var notes: std.ArrayList(u8) = .empty;
    try notes.appendSlice(c.arena, "200 messages: ");
    var it = counts.iterator();
    while (it.next()) |e| try notes.print(c.arena, "{s}={d} ", .{ e.key_ptr.*, e.value_ptr.* });
    r.note = notes.items;
    r.http_status = 101;
    r.outcome = .ok;
}

const ProbeFn = *const fn (*Ctx, *Result) anyerror!void;

fn wrap(comptime f: anytype, comptime args: anytype) ProbeFn {
    return struct {
        fn call(c: *Ctx, r: *Result) anyerror!void {
            return @call(.auto, f, .{ c, r } ++ args);
        }
    }.call;
}

const marnet_url = "https://raw.githubusercontent.com/eurostat/searoute/master/modules/core/src/main/resources/marnet/marnet_plus_20km.gpkg";
const natural_earth_url = "https://naciscdn.org/naturalearth/110m/physical/ne_110m_land.zip";

const probes = [_]struct { id: []const u8, f: ProbeFn }{
    .{ .id = "usgs", .f = probeUsgs },
    .{ .id = "gdacs", .f = probeGdacs },
    .{ .id = "portwatch_ports_daily", .f = wrap(probePortwatchDaily, .{ portwatch.Layer.Daily_Ports_Data, "port1114", portwatch.DailyPort }) },
    .{ .id = "portwatch_chokepoints_daily", .f = wrap(probePortwatchDaily, .{ portwatch.Layer.Daily_Chokepoints_Data, "chokepoint6", portwatch.DailyChokepoint }) },
    .{ .id = "portwatch_ports_db", .f = wrap(probePortwatchTable, .{ portwatch.Layer.PortWatch_ports_database, "&resultRecordCount=25", portwatch.PortRef }) },
    .{ .id = "portwatch_chokepoints_db", .f = wrap(probePortwatchTable, .{ portwatch.Layer.PortWatch_chokepoints_database, "", portwatch.PortRef }) },
    .{ .id = "portwatch_disruptions", .f = wrap(probePortwatchTable, .{ portwatch.Layer.portwatch_disruptions_database, "&orderByFields=ObjectId%20DESC&resultRecordCount=25", portwatch.Disruption }) },
    .{ .id = "portwatch_tradenow", .f = wrap(probePortwatchTable, .{ portwatch.Layer.Monthly_TradeNow, "&orderByFields=date%20DESC&resultRecordCount=25", portwatch.TradeNow }) },
    .{ .id = "fred", .f = probeFred },
    .{ .id = "comtrade", .f = probeComtrade },
    .{ .id = "census_porths", .f = probeCensus },
    .{ .id = "gdelt_events", .f = probeGdelt },
    .{ .id = "opensanctions_maritime", .f = probeOpenSanctions },
    .{ .id = "unga_votes", .f = probeUnga },
    .{ .id = "marnet", .f = wrap(probeBinary, .{ marnet_url, "SQLite format 3\x00", "GeoPackage (SQLite) lane network" }) },
    .{ .id = "natural_earth", .f = wrap(probeBinary, .{ natural_earth_url, "PK\x03\x04", "zipped shapefile" }) },
    .{ .id = "nga_msi", .f = probeNga },
    .{ .id = "aisstream", .f = probeAis },
};

pub fn probeOne(c: *Ctx, id: []const u8) Result {
    var r: Result = .{ .id = id, .fetched_at = c.now };
    const f: ProbeFn = for (probes) |p| {
        if (std.mem.eql(u8, p.id, id)) break p.f;
    } else {
        r.outcome = .skipped;
        r.note = "no probe defined";
        return r;
    };
    const res = f(c, &r);
    res catch |err| {
        r.outcome = .failed;
        r.note = std.fmt.allocPrint(c.arena, "error: {s}", .{@errorName(err)}) catch "error";
    };
    writeReport(c, &r) catch {};
    return r;
}

fn writeReport(c: *Ctx, r: *const Result) !void {
    const src = registry.find(r.id);
    var b1: [20]u8 = undefined;
    var b2: [20]u8 = undefined;
    const md = try std.fmt.allocPrint(c.arena,
        \\# Probe: {s}
        \\
        \\> FIXTURE. Real response captured by `atlas probe` for tests and schema checks.
        \\> Not used as live data by the running system.
        \\
        \\| field | value |
        \\|---|---|
        \\| source | {s} |
        \\| url | `{s}` |
        \\| outcome | {s} |
        \\| http status | {d} |
        \\| bytes | {d} |
        \\| fetched at (UTC) | {s} |
        \\| newest data time (UTC) | {s} |
        \\| freshness class | {s} |
        \\| note | {s} |
        \\
    , .{
        r.id,
        if (src) |s| s.name else "?",
        r.url,
        @tagName(r.outcome),
        r.http_status,
        r.bytes,
        time.formatIso(&b1, r.fetched_at),
        if (r.data_time) |t| time.formatIso(&b2, t) else "n/a",
        if (src) |s| s.freshness.label() else "?",
        r.note,
    });
    try c.save(r.id, "PROBE.md", md);
}

test "every registered source has a probe" {
    for (registry.sources) |src| {
        const has = for (probes) |p| {
            if (std.mem.eql(u8, p.id, src.id)) break true;
        } else false;
        try std.testing.expect(has);
    }
}

test "redact" {
    const gpa = std.testing.allocator;
    const s = try redact(gpa, "https://x/y?series_id=A&api_key=SECRET&file_type=json", &.{"api_key"});
    defer gpa.free(s);
    try std.testing.expectEqualStrings("https://x/y?series_id=A&api_key=<REDACTED>&file_type=json", s);
    const t = try redact(gpa, "https://x/y?key=SECRET", &.{"key"});
    defer gpa.free(t);
    try std.testing.expectEqualStrings("https://x/y?key=<REDACTED>", t);
}
