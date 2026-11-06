//! GDACS (Global Disaster Alert and Coordination System, EC JRC + UN OCHA).
//! Endpoint: /gdacsapi/api/events/geteventlist/SEARCH?eventlist=EQ;TC;FL;VO;DR;WF&fromDate=..&toDate=..
//! Field names verified against a live response on 2026-11-06.

const std = @import("std");
const time = @import("../util/time.zig");

pub const EventType = enum { EQ, TC, FL, VO, DR, WF, unknown };

pub const Feature = struct {
    geometry: struct {
        type: []const u8,
        coordinates: std.json.Value,
    },
    properties: struct {
        eventtype: []const u8,
        eventid: i64,
        episodeid: i64 = 0,
        name: ?[]const u8 = null,
        /// "Green" | "Orange" | "Red"
        alertlevel: ?[]const u8 = null,
        alertscore: ?f64 = null,
        country: ?[]const u8 = null,
        iso3: ?[]const u8 = null,
        /// "2026-11-01T00:00:00" (UTC)
        fromdate: []const u8,
        todate: []const u8,
        datemodified: ?[]const u8 = null,
        /// "true" / "false" as strings
        iscurrent: ?[]const u8 = null,
    },
};

pub const Collection = struct { features: []Feature };

pub fn parse(gpa: std.mem.Allocator, body: []const u8) !std.json.Parsed(Collection) {
    return std.json.parseFromSlice(Collection, gpa, body, .{ .ignore_unknown_fields = true });
}

pub fn eventType(f: Feature) EventType {
    return std.meta.stringToEnum(EventType, f.properties.eventtype) orelse .unknown;
}

/// Representative point [lon, lat] of an event (GDACS returns point centroids here).
pub fn point(f: Feature) ?[2]f64 {
    if (!std.mem.eql(u8, f.geometry.type, "Point")) return null;
    const a = switch (f.geometry.coordinates) {
        .array => |a| a,
        else => return null,
    };
    if (a.items.len < 2) return null;
    return .{ asF64(a.items[0]) orelse return null, asF64(a.items[1]) orelse return null };
}

fn asF64(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => |x| x,
        .integer => |x| @floatFromInt(x),
        else => null,
    };
}

/// Latest `datemodified` across events (Unix seconds).
pub fn newestModified(c: Collection) ?i64 {
    var best: ?i64 = null;
    for (c.features) |f| {
        const s = f.properties.datemodified orelse continue;
        const t = time.parseIso(s) catch continue;
        best = @max(best orelse t, t);
    }
    return best;
}

test "parse inline gdacs" {
    const gpa = std.testing.allocator;
    const p = try parse(gpa,
        \\{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[80.2,15.8]},
        \\"properties":{"eventtype":"TC","eventid":1001346,"episodeid":10,"name":"Tropical Cyclone MURASU-26","alertlevel":"Red",
        \\"alertscore":3,"country":"India","iso3":"IND","fromdate":"2026-11-01T00:00:00","todate":"2026-11-03T06:00:00",
        \\"datemodified":"2026-11-04T06:01:20","iscurrent":"true"}}]}
    );
    defer p.deinit();
    const f = p.value.features[0];
    try std.testing.expectEqual(EventType.TC, eventType(f));
    try std.testing.expectEqual([2]f64{ 80.2, 15.8 }, point(f).?);
    try std.testing.expectEqual(try time.parseIso("2026-11-04T06:01:20"), newestModified(p.value).?);
}
