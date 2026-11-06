//! UN Comtrade+ API (v1). Free key (env COMTRADE_API_KEY), sent in the
//! `Ocp-Apim-Subscription-Key` header. Free tier: 500 calls/day, 100k rows/call.
//! Verified against live responses on 2026-11-06.
//!
//! Two quirks seen in real data that the model must respect:
//!  * `period` is a string in /data/v1/get but an integer in /data/v1/getDA.
//!  * Rows are split by mode of transport (`motCode`) and customs regime
//!    (`customsCode`); `motCode == 0` / `customsCode == "C00"` are totals.
//!    Mode is recorded at the reporter's own border, so e.g. Swiss imports
//!    from China show up as Road/Rail/Air even though they crossed the
//!    ocean: the sea leg is invisible for landlocked or transit-dependent
//!    reporters. The route model has to infer it.

const std = @import("std");

pub const host = "https://comtradeapi.un.org";
pub const key_header = "Ocp-Apim-Subscription-Key";

pub const Row = struct {
    period: []const u8,
    reporterCode: i64,
    reporterISO: ?[]const u8 = null,
    partnerCode: i64,
    partnerISO: ?[]const u8 = null,
    /// "M" imports, "X" exports (plus re-import/re-export codes)
    flowCode: []const u8,
    /// HS code or "TOTAL"
    cmdCode: []const u8,
    customsCode: ?[]const u8 = null,
    /// UN mode-of-transport code. Seen in real rows: 0 total, 1000 air, 2200 inland
    /// waterway, 3100 rail, 3200 road, 9300 self-propelled. 2100 = sea per the
    /// Comtrade MOT list (to be confirmed in a sample with sea freight).
    motCode: i64 = 0,
    motDesc: ?[]const u8 = null,
    /// USD; CIF for imports, FOB for exports
    primaryValue: ?f64 = null,
    cifvalue: ?f64 = null,
    fobvalue: ?f64 = null,
    /// kg; often 0 with isNetWgtEstimated = true for aggregates
    netWgt: ?f64 = null,
    isNetWgtEstimated: ?bool = null,
    isReported: ?bool = null,
    isAggregate: ?bool = null,
};

pub const DataResponse = struct {
    count: ?i64 = null,
    data: []Row,
    @"error": ?[]const u8 = null,
};

pub const Availability = struct {
    data: []struct {
        reporterCode: i64,
        reporterISO: ?[]const u8 = null,
        /// YYYYMM as integer (sic)
        period: i64,
        lastReleased: ?[]const u8 = null,
        totalRecords: ?i64 = null,
    },
};

pub fn parseData(gpa: std.mem.Allocator, body: []const u8) !std.json.Parsed(DataResponse) {
    return std.json.parseFromSlice(DataResponse, gpa, body, .{ .ignore_unknown_fields = true });
}

pub fn parseAvailability(gpa: std.mem.Allocator, body: []const u8) !std.json.Parsed(Availability) {
    return std.json.parseFromSlice(Availability, gpa, body, .{ .ignore_unknown_fields = true });
}

/// Latest monthly period available for a reporter (YYYYMM), from getDA.
pub fn latestPeriod(a: Availability, reporter: i64) ?i64 {
    var best: ?i64 = null;
    for (a.data) |r| if (r.reporterCode == reporter) {
        best = @max(best orelse r.period, r.period);
    };
    return best;
}

pub const Mode = enum { total, sea, air, inland_waterway, rail, road, other };

pub fn mode(mot: i64) Mode {
    return switch (mot) {
        0 => .total,
        2000...2199 => .sea,
        2200...2299 => .inland_waterway,
        1000...1999 => .air,
        3100...3199 => .rail,
        3200...3299 => .road,
        else => .other,
    };
}

test "parse data rows and modes" {
    const gpa = std.testing.allocator;
    const p = try parseData(gpa,
        \\{"elapsedTime":"0.1 secs","count":2,"data":[
        \\{"period":"202606","reporterCode":757,"reporterISO":"CHE","partnerCode":156,"partnerISO":"CHN","flowCode":"M","cmdCode":"TOTAL","customsCode":"C00","motCode":0,"primaryValue":2572965758.0},
        \\{"period":"202606","reporterCode":757,"reporterISO":"CHE","partnerCode":156,"partnerISO":"CHN","flowCode":"M","cmdCode":"TOTAL","customsCode":"C00","motCode":3200,"primaryValue":1539507646.0}],"error":""}
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 2), p.value.data.len);
    try std.testing.expectEqual(Mode.road, mode(p.value.data[1].motCode));
    try std.testing.expectEqual(Mode.sea, mode(2100));
}

test "availability period is an integer" {
    const gpa = std.testing.allocator;
    const p = try parseAvailability(gpa,
        \\{"data":[{"reporterCode":757,"period":202607},{"reporterCode":757,"period":202608},{"reporterCode":156,"period":202412}]}
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(?i64, 202608), latestPeriod(p.value, 757));
    try std.testing.expectEqual(@as(?i64, 202412), latestPeriod(p.value, 156));
}
