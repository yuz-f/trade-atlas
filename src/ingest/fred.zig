//! FRED (Federal Reserve Bank of St. Louis) series observations.
//! Endpoint: https://api.stlouisfed.org/fred/series/observations?series_id=..&api_key=..&file_type=json
//! Free key (env FRED_API_KEY). Verified against live responses on 2026-11-06.

const std = @import("std");

/// Series used by the model (family a: financial/commercial). Codes verified to exist.
pub const Series = struct { id: []const u8, label: []const u8, freq: []const u8 };
pub const series = [_]Series{
    .{ .id = "DCOILBRENTEU", .label = "Brent crude, USD/bbl", .freq = "daily" },
    .{ .id = "DCOILWTICO", .label = "WTI crude, USD/bbl", .freq = "daily" },
    .{ .id = "PCU483111483111", .label = "PPI: deep sea freight transportation", .freq = "monthly" },
    .{ .id = "DEXCHUS", .label = "CNY per USD", .freq = "daily" },
};

pub const Observations = struct {
    observations: []struct {
        /// "YYYY-MM-DD"
        date: []const u8,
        /// Decimal string, or "." when missing (e.g. market holiday).
        value: []const u8,
    },
};

pub fn parse(gpa: std.mem.Allocator, body: []const u8) !std.json.Parsed(Observations) {
    return std.json.parseFromSlice(Observations, gpa, body, .{ .ignore_unknown_fields = true });
}

pub fn value(s: []const u8) ?f64 {
    if (std.mem.eql(u8, s, ".")) return null;
    return std.fmt.parseFloat(f64, s) catch null;
}

pub fn observationsUrl(buf: []u8, series_id: []const u8, key: []const u8, limit: u32) ![]u8 {
    return std.fmt.bufPrint(buf, "https://api.stlouisfed.org/fred/series/observations?series_id={s}&api_key={s}&file_type=json&sort_order=desc&limit={d}", .{ series_id, key, limit });
}

test "parse observations with a missing value" {
    const gpa = std.testing.allocator;
    const p = try parse(gpa,
        \\{"realtime_start":"2026-11-04","count":10295,"observations":[
        \\{"realtime_start":"2026-11-04","realtime_end":"2026-11-04","date":"2026-11-03","value":"107.03"},
        \\{"realtime_start":"2026-11-04","realtime_end":"2026-11-04","date":"2026-11-02","value":"."}]}
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(?f64, 107.03), value(p.value.observations[0].value));
    try std.testing.expectEqual(@as(?f64, null), value(p.value.observations[1].value));
}
