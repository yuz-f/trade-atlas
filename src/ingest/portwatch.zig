//! IMF PortWatch, served as ArcGIS FeatureServer layers.
//! Base: https://services9.arcgis.com/weJ1QsnbMYJlCHdG/arcgis/rest/services/<Layer>/FeatureServer/0
//! Field names below were read from each layer's live `?f=json` metadata and
//! from real query results on 2026-11-06. PortWatch derives these counts and
//! tonnages from satellite AIS; they are IMF estimates, not customs data.
//! Licence: IMF terms of use (https://www.imf.org/external/terms.htm).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const base = "https://services9.arcgis.com/weJ1QsnbMYJlCHdG/arcgis/rest/services";

pub const Layer = enum {
    /// Daily port calls and import/export tonnage per port (~2000 ports).
    Daily_Ports_Data,
    /// Daily transit calls and capacity per chokepoint (28 chokepoints).
    Daily_Chokepoints_Data,
    /// Port reference list: id, name, country, lat/lon, traffic shares.
    PortWatch_ports_database,
    /// Chokepoint reference list (same schema as ports database).
    PortWatch_chokepoints_database,
    /// Disruption events (GDACS-derived) with affected ports.
    portwatch_disruptions_database,
    /// Monthly AIS-based nowcast of trade value/volume per economy.
    Monthly_TradeNow,
};

/// ArcGIS query response envelope (only what we use).
pub fn QueryResult(comptime Attr: type) type {
    return struct {
        features: []struct { attributes: Attr },
        exceededTransferLimit: ?bool = null,
    };
}

pub const DailyPort = struct {
    /// "YYYY-MM-DD" (esriFieldTypeDateOnly)
    date: []const u8,
    portid: []const u8,
    portname: ?[]const u8 = null,
    ISO3: ?[]const u8 = null,
    portcalls: ?f64 = null,
    portcalls_container: ?f64 = null,
    portcalls_dry_bulk: ?f64 = null,
    portcalls_general_cargo: ?f64 = null,
    portcalls_roro: ?f64 = null,
    portcalls_tanker: ?f64 = null,
    /// Metric tonnes (estimated)
    import: ?f64 = null,
    @"export": ?f64 = null,
};

/// Verified against real rows (fixtures/portwatch_chokepoints_daily). The
/// endpoint returned HTTP 400 for ~15 minutes on 2026-11-06 (IMF-side), then
/// recovered: callers must treat failures as "stale", not "zero traffic".
pub const DailyChokepoint = struct {
    date: []const u8,
    portid: []const u8,
    portname: ?[]const u8 = null,
    n_total: ?f64 = null,
    n_container: ?f64 = null,
    n_dry_bulk: ?f64 = null,
    n_general_cargo: ?f64 = null,
    n_roro: ?f64 = null,
    n_tanker: ?f64 = null,
    capacity: ?f64 = null,
    capacity_tanker: ?f64 = null,
    capacity_container: ?f64 = null,
    capacity_dry_bulk: ?f64 = null,
};

pub const PortRef = struct {
    portid: []const u8,
    portname: []const u8,
    country: ?[]const u8 = null,
    ISO3: ?[]const u8 = null,
    lat: f64,
    lon: f64,
    vessel_count_total: ?f64 = null,
    share_country_maritime_import: ?f64 = null,
    share_country_maritime_export: ?f64 = null,
    LOCODE: ?[]const u8 = null,
};

pub const Disruption = struct {
    eventid: i64,
    eventtype: ?[]const u8 = null,
    eventname: ?[]const u8 = null,
    alertlevel: ?[]const u8 = null,
    country: ?[]const u8 = null,
    /// Unix milliseconds (esriFieldTypeDate)
    fromdate: ?i64 = null,
    todate: ?i64 = null,
    lat: ?f64 = null,
    long: ?f64 = null,
    n_affectedports: ?i64 = null,
    affectedports: ?[]const u8 = null,
};

pub const TradeNow = struct {
    region: ?[]const u8 = null,
    ISO3: ?[]const u8 = null,
    date: []const u8,
    trade_value: ?f64 = null,
    trade_volume: ?f64 = null,
    value_import_total: ?f64 = null,
    value_export_total: ?f64 = null,
};

/// Layer metadata: we only need the last data edit, which is a cheap
/// freshness check before pulling rows.
pub const LayerInfo = struct {
    name: ?[]const u8 = null,
    maxRecordCount: ?i64 = null,
    editingInfo: ?struct { dataLastEditDate: ?i64 = null } = null,
};

pub fn parse(comptime T: type, gpa: Allocator, body: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, gpa, body, .{ .ignore_unknown_fields = true });
}

/// Build a query URL. `where` is raw SQL and gets percent-encoded here.
pub fn queryUrl(gpa: Allocator, layer: Layer, where: []const u8, out_fields: []const u8, extra: []const u8) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    errdefer w.deinit();
    try w.writer.print("{s}/{s}/FeatureServer/0/query?where=", .{ base, @tagName(layer) });
    try percentEncode(&w.writer, where);
    try w.writer.writeAll("&outFields=");
    try percentEncode(&w.writer, out_fields);
    try w.writer.print("&returnGeometry=false&f=json{s}", .{extra});
    return w.toOwnedSlice();
}

pub fn layerInfoUrl(gpa: Allocator, layer: Layer) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/{s}/FeatureServer/0?f=json", .{ base, @tagName(layer) });
}

pub fn percentEncode(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~')
            try w.writeByte(c)
        else
            try w.print("%{X:0>2}", .{c});
    }
}

/// Latest `date` string among rows ("YYYY-MM-DD" sorts lexicographically).
pub fn latestDate(comptime Attr: type, r: QueryResult(Attr)) ?[]const u8 {
    var best: ?[]const u8 = null;
    for (r.features) |f| {
        if (best == null or std.mem.order(u8, f.attributes.date, best.?) == .gt) best = f.attributes.date;
    }
    return best;
}

test "queryUrl encodes where clause" {
    const gpa = std.testing.allocator;
    const u = try queryUrl(gpa, .Daily_Ports_Data, "portid='port1114' AND date>=DATE '2026-10-20'", "date,portid", "");
    defer gpa.free(u);
    try std.testing.expectEqualStrings(base ++ "/Daily_Ports_Data/FeatureServer/0/query?where=portid%3D%27port1114%27%20AND%20date%3E%3DDATE%20%272026-10-20%27&outFields=date%2Cportid&returnGeometry=false&f=json", u);
}

test "parse daily ports rows (shape of a real response)" {
    const gpa = std.testing.allocator;
    const p = try parse(QueryResult(DailyPort), gpa,
        \\{"objectIdFieldName":"ObjectId","features":[
        \\{"attributes":{"date":"2026-10-29","portid":"port1114","portname":"Rotterdam","portcalls":84,"import":512685,"export":268892}},
        \\{"attributes":{"date":"2026-10-30","portid":"port1114","portname":"Rotterdam","portcalls":80,"import":635873,"export":218255}}]}
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(f64, 218255), p.value.features[1].attributes.@"export".?);
    try std.testing.expectEqualStrings("2026-10-30", latestDate(DailyPort, p.value).?);
}
