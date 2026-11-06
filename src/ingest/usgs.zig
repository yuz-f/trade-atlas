//! USGS real-time earthquake GeoJSON feed.
//! Field names verified against a live response on 2026-11-06
//! (fixtures/usgs/sample.json).

const std = @import("std");

pub const Feature = struct {
    id: []const u8,
    properties: struct {
        mag: ?f64 = null,
        place: ?[]const u8 = null,
        /// Event origin time, Unix milliseconds.
        time: i64,
        /// Last revision, Unix milliseconds.
        updated: i64,
        url: ?[]const u8 = null,
        /// PAGER alert level: green/yellow/orange/red, often null.
        alert: ?[]const u8 = null,
        tsunami: i64 = 0,
        sig: i64 = 0,
        title: ?[]const u8 = null,
    },
    geometry: struct {
        /// [longitude, latitude, depth_km]
        coordinates: [3]f64,
    },
};

pub const Collection = struct {
    metadata: struct {
        /// When USGS generated this file, Unix milliseconds.
        generated: i64,
        count: i64,
        title: ?[]const u8 = null,
    },
    features: []Feature,
};

pub fn parse(gpa: std.mem.Allocator, body: []const u8) !std.json.Parsed(Collection) {
    return std.json.parseFromSlice(Collection, gpa, body, .{ .ignore_unknown_fields = true });
}

/// Newest event origin time in the feed (Unix seconds), or null if empty.
pub fn newestEventTime(c: Collection) ?i64 {
    var best: ?i64 = null;
    for (c.features) |f| best = @max(best orelse f.properties.time, f.properties.time);
    return if (best) |b| @divFloor(b, 1000) else null;
}

test "parse inline feed" {
    const gpa = std.testing.allocator;
    const p = try parse(gpa,
        \\{"type":"FeatureCollection","metadata":{"generated":1793948301000,"count":1},
        \\"features":[{"type":"Feature","id":"us7000x","properties":{"mag":4.7,"place":"139 km SSE of False Pass, Alaska",
        \\"time":1793932525631,"updated":1793940049673,"alert":null,"tsunami":0,"sig":340},
        \\"geometry":{"type":"Point","coordinates":[-162.95,53.63,27.9]}}]}
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.value.features.len);
    try std.testing.expectEqual(@as(f64, 4.7), p.value.features[0].properties.mag.?);
    try std.testing.expectEqual(@as(?i64, 1793932525), newestEventTime(p.value));
}
