//! Parser tests against real captured responses (see fixtures/).
//! If a source changes its schema, re-run `atlas probe <id>` and these
//! tests show exactly which assumption broke.

const std = @import("std");
const fx = @import("fixtures");
const atlas = @import("atlas");
const testing = std.testing;
const gpa = testing.allocator;

test "usgs fixture" {
    const p = try atlas.usgs.parse(gpa, fx.usgs);
    defer p.deinit();
    try testing.expectEqual(@as(usize, @intCast(p.value.metadata.count)), p.value.features.len);
    try testing.expect(atlas.usgs.newestEventTime(p.value) != null);
    for (p.value.features) |f| {
        try testing.expect(f.geometry.coordinates[1] >= -90 and f.geometry.coordinates[1] <= 90);
        try testing.expect(f.properties.mag.? >= 4.5);
    }
}

test "gdacs fixture" {
    const p = try atlas.gdacs.parse(gpa, fx.gdacs);
    defer p.deinit();
    try testing.expect(p.value.features.len > 0);
    for (p.value.features) |f| {
        try testing.expect(atlas.gdacs.eventType(f) != .unknown);
        _ = try atlas.time.parseIso(f.properties.fromdate);
    }
}

test "portwatch daily ports fixture" {
    const pw = atlas.portwatch;
    const p = try pw.parse(pw.QueryResult(pw.DailyPort), gpa, fx.portwatch_ports_daily);
    defer p.deinit();
    try testing.expect(p.value.features.len > 0);
    for (p.value.features) |f| {
        try testing.expectEqualStrings("port1114", f.attributes.portid);
        _ = try atlas.time.parseIso(f.attributes.date);
        try testing.expect(f.attributes.portcalls.? >= 0);
    }
}

test "portwatch daily chokepoints fixture (Hormuz)" {
    const pw = atlas.portwatch;
    const p = try pw.parse(pw.QueryResult(pw.DailyChokepoint), gpa, fx.portwatch_chokepoints_daily);
    defer p.deinit();
    try testing.expect(p.value.features.len > 0);
    for (p.value.features) |f| {
        try testing.expectEqualStrings("chokepoint6", f.attributes.portid);
        try testing.expect(f.attributes.n_total != null);
    }
}

test "portwatch chokepoints reference fixture has 28 chokepoints" {
    const pw = atlas.portwatch;
    const p = try pw.parse(pw.QueryResult(pw.PortRef), gpa, fx.portwatch_chokepoints_db);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 28), p.value.features.len);
    var found_hormuz = false;
    for (p.value.features) |f| {
        if (std.mem.eql(u8, f.attributes.portname, "Strait of Hormuz")) found_hormuz = true;
    }
    try testing.expect(found_hormuz);
}

test "portwatch disruptions and tradenow fixtures" {
    const pw = atlas.portwatch;
    const d = try pw.parse(pw.QueryResult(pw.Disruption), gpa, fx.portwatch_disruptions);
    defer d.deinit();
    try testing.expect(d.value.features.len > 0);
    const t = try pw.parse(pw.QueryResult(pw.TradeNow), gpa, fx.portwatch_tradenow);
    defer t.deinit();
    try testing.expect(t.value.features.len > 0);
}

test "fred fixture" {
    const p = try atlas.fred.parse(gpa, fx.fred);
    defer p.deinit();
    try testing.expect(p.value.observations.len > 0);
    try testing.expect(atlas.fred.value(p.value.observations[0].value) != null);
}

test "comtrade fixture" {
    const p = try atlas.comtrade.parseData(gpa, fx.comtrade);
    defer p.deinit();
    try testing.expect(p.value.data.len > 0);
    for (p.value.data) |r| {
        try testing.expectEqual(@as(i64, 842), r.reporterCode);
        _ = try atlas.time.parsePeriod(r.period);
    }
}

test "gdelt fixtures" {
    _ = try atlas.gdelt.parseLastUpdate(fx.gdelt_lastupdate);
    var lines = std.mem.tokenizeScalar(u8, fx.gdelt_export, '\n');
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        const e = try atlas.gdelt.parseEvent(std.mem.trimEnd(u8, line, "\r"));
        try testing.expect(e.quad_class >= 1 and e.quad_class <= 4);
        try testing.expect(e.date_added > 0);
    }
    try testing.expect(n > 0);
}

test "aisstream fixture" {
    var lines = std.mem.tokenizeScalar(u8, fx.aisstream, '\n');
    var with_meta: usize = 0;
    while (lines.next()) |line| {
        const p = try atlas.aisstream.parse(gpa, line);
        defer p.deinit();
        if (p.value.MetaData) |md| {
            with_meta += 1;
            _ = try atlas.time.parseIso(md.time_utc);
        }
    }
    try testing.expect(with_meta > 0);
}

test "opensanctions fixtures" {
    const p = try atlas.opensanctions.parseIndex(gpa, fx.opensanctions_index);
    defer p.deinit();
    _ = try atlas.time.parseIso(p.value.updated_at);
    const first = std.mem.sliceTo(fx.opensanctions_head, '\n');
    try testing.expectEqualStrings(atlas.opensanctions.csv_header, std.mem.trimEnd(u8, first, "\r"));
}
