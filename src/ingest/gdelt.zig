//! GDELT 2.0 Event database, raw 15-minute files.
//! https://data.gdeltproject.org/gdeltv2/lastupdate.txt lists the newest
//! export/mentions/gkg zips. Each export zip holds one tab-separated file
//! with 61 columns (GDELT 2.0 Event Codebook). We use the raw files rather
//! than the DOC API because the DOC API rate-limits to one request per 5 s
//! and reset our connections during probing (2026-11-06).
//! Column count and positions verified on a real file (20261106070000).

const std = @import("std");
const time = @import("../util/time.zig");

pub const LastUpdate = struct {
    export_url: []const u8,
    mentions_url: []const u8,
    gkg_url: []const u8,
    /// Unix seconds, from the filename stamp.
    stamp: i64,
};

/// Parse lastupdate.txt: three lines "<size> <md5> <url>".
pub fn parseLastUpdate(text: []const u8) !LastUpdate {
    var urls: [3][]const u8 = undefined;
    var n: usize = 0;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        _ = f.next() orelse continue;
        _ = f.next() orelse continue;
        const url = f.next() orelse continue;
        if (n < 3) urls[n] = url;
        n += 1;
    }
    if (n < 3) return error.MalformedLastUpdate;
    const name = urls[0][(std.mem.lastIndexOfScalar(u8, urls[0], '/') orelse return error.MalformedLastUpdate) + 1 ..];
    if (name.len < 14) return error.MalformedLastUpdate;
    return .{ .export_url = urls[0], .mentions_url = urls[1], .gkg_url = urls[2], .stamp = try time.parseCompact(name[0..14]) };
}

/// GDELT publishes http:// URLs; the same host serves https.
pub fn httpsUrl(buf: []u8, url: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, url, "http://")) return std.fmt.bufPrint(buf, "https://{s}", .{url[7..]});
    return std.fmt.bufPrint(buf, "{s}", .{url});
}

pub const columns = 61;

/// The subset of event columns the model uses (0-based codebook positions).
pub const Event = struct {
    id: []const u8, // 0 GlobalEventID
    day: []const u8, // 1 SQLDATE (YYYYMMDD, event date)
    actor1_country: []const u8, // 7 Actor1CountryCode (CAMEO, ISO3-like)
    actor2_country: []const u8, // 17 Actor2CountryCode
    event_code: []const u8, // 26 EventCode (CAMEO)
    root_code: []const u8, // 28 EventRootCode
    quad_class: u8, // 29 QuadClass 1..4 (verbal/material cooperation/conflict)
    goldstein: f32, // 30 GoldsteinScale -10..10
    num_mentions: u32, // 31 NumMentions
    avg_tone: f32, // 34 AvgTone
    lat: ?f32, // 56 ActionGeo_Lat
    lon: ?f32, // 57 ActionGeo_Long
    date_added: i64, // 59 DATEADDED (YYYYMMDDHHMMSS) -> Unix s
    source_url: []const u8, // 60 SOURCEURL
};

pub fn parseEvent(line: []const u8) !Event {
    var cols: [columns][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, line, '\t');
    var i: usize = 0;
    while (it.next()) |c| : (i += 1) {
        if (i >= columns) return error.TooManyColumns;
        cols[i] = c;
    }
    if (i != columns) return error.WrongColumnCount;
    return .{
        .id = cols[0],
        .day = cols[1],
        .actor1_country = cols[7],
        .actor2_country = cols[17],
        .event_code = cols[26],
        .root_code = cols[28],
        .quad_class = std.fmt.parseInt(u8, cols[29], 10) catch 0,
        .goldstein = std.fmt.parseFloat(f32, cols[30]) catch 0,
        .num_mentions = std.fmt.parseInt(u32, cols[31], 10) catch 0,
        .avg_tone = std.fmt.parseFloat(f32, cols[34]) catch 0,
        .lat = std.fmt.parseFloat(f32, cols[56]) catch null,
        .lon = std.fmt.parseFloat(f32, cols[57]) catch null,
        .date_added = time.parseCompact(cols[59]) catch 0,
        .source_url = cols[60],
    };
}

test "parseLastUpdate" {
    const lu = try parseLastUpdate(
        \\62082 0d8d1f9cfc732b0ab820fc552b383823 http://data.gdeltproject.org/gdeltv2/20261106070000.export.CSV.zip
        \\68971 6e41935c006d0a566f72a70b4977f42c http://data.gdeltproject.org/gdeltv2/20261106070000.mentions.CSV.zip
        \\3415125 91605ba68288e0954fbca463b912b675 http://data.gdeltproject.org/gdeltv2/20261106070000.gkg.csv.zip
        \\
    );
    try std.testing.expectEqual(try time.parseCompact("20261106070000"), lu.stamp);
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://data.gdeltproject.org/gdeltv2/20261106070000.export.CSV.zip", try httpsUrl(&b, lu.export_url));
}

test "parseEvent rejects wrong column count" {
    try std.testing.expectError(error.WrongColumnCount, parseEvent("a\tb\tc"));
}
