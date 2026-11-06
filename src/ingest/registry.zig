//! Every external input the system uses, in one place. The UI's freshness
//! badges, the probe command and docs/SOURCES.md all read from this table.

const std = @import("std");

/// How close to "now" the data is, as shown in the UI.
pub const Freshness = enum {
    /// seconds to minutes
    live,
    /// hours to ~a week
    near_live,
    /// weeks to years
    lagged,
    /// reference data that changes rarely
    static,

    pub fn label(f: Freshness) []const u8 {
        return switch (f) {
            .live => "LIVE",
            .near_live => "NEAR-LIVE",
            .lagged => "LAGGED",
            .static => "STATIC",
        };
    }
};

/// The model keeps these input families separate so each one's contribution
/// can be measured (requirement 5).
pub const Family = enum {
    financial,
    political,
    media,
    physical,
    /// trade structure: who trades what with whom (the graph itself)
    structure,
    /// geography and identifiers
    reference,
};

pub const Auth = union(enum) {
    none,
    /// key appended as a query parameter
    query: struct { param: []const u8, env: []const u8 },
    /// key sent as a request header
    header: struct { name: []const u8, env: []const u8 },
    /// key sent inside the WebSocket subscription message
    in_message: struct { env: []const u8 },

    pub fn env(a: Auth) ?[]const u8 {
        return switch (a) {
            .none => null,
            .query => |q| q.env,
            .header => |h| h.env,
            .in_message => |m| m.env,
        };
    }
};

pub const Format = enum { json, text, zip_tsv, csv, websocket_json, binary };

pub const Source = struct {
    id: []const u8,
    name: []const u8,
    measures: []const u8,
    family: Family,
    freshness: Freshness,
    /// How often we poll (seconds). 0 = streamed.
    poll_s: u32,
    /// Typical delay between the real-world event and the data, as observed.
    lag: []const u8,
    licence: []const u8,
    homepage: []const u8,
    auth: Auth,
    format: Format,
    /// Requirements from the brief this source supports.
    supports: []const u8,
};

pub const sources = [_]Source{
    .{
        .id = "aisstream",
        .name = "AISStream.io",
        .measures = "Live vessel positions (PositionReport) and identity/type/destination (ShipStaticData)",
        .family = .physical,
        .freshness = .live,
        .poll_s = 0,
        .lag = "seconds; terrestrial receivers only (no coverage seen at Hormuz, Bab-el-Mandeb, Suez, Taiwan Strait, Bosporus)",
        .licence = "Free beta, no SLA; terms at aisstream.io",
        .homepage = "https://aisstream.io",
        .auth = .{ .in_message = .{ .env = "AISSTREAM_API_KEY" } },
        .format = .websocket_json,
        .supports = "2 live data, 3 globe, 5d physical",
    },
    .{
        .id = "portwatch_ports_daily",
        .name = "IMF PortWatch - Daily Ports Data",
        .measures = "Daily port calls by vessel type and estimated import/export tonnes per port (satellite AIS)",
        .family = .physical,
        .freshness = .near_live,
        .poll_s = 6 * 3600,
        .lag = "~7 days (rows to 2026-10-30 on 2026-11-06); layer edited weekly",
        .licence = "IMF terms of use (imf.org/external/terms.htm)",
        .homepage = "https://portwatch.imf.org",
        .auth = .none,
        .format = .json,
        .supports = "4 time series, 5d, Phase 1/2 target",
    },
    .{
        .id = "portwatch_chokepoints_daily",
        .name = "IMF PortWatch - Daily Chokepoints Data",
        .measures = "Daily transit calls and capacity by vessel type for 28 chokepoints",
        .family = .physical,
        .freshness = .near_live,
        .poll_s = 6 * 3600,
        .lag = "~7 days expected; endpoint returned HTTP 400 on 2026-11-06 (IMF-side outage)",
        .licence = "IMF terms of use",
        .homepage = "https://portwatch.imf.org",
        .auth = .none,
        .format = .json,
        .supports = "3 chokepoints, 4, 5d, Phase 2 target",
    },
    .{
        .id = "portwatch_ports_db",
        .name = "IMF PortWatch - Ports database",
        .measures = "Port list: id, name, country, lat/lon, vessel counts, share of country's maritime trade",
        .family = .reference,
        .freshness = .static,
        .poll_s = 7 * 86400,
        .lag = "reference",
        .licence = "IMF terms of use",
        .homepage = "https://portwatch.imf.org",
        .auth = .none,
        .format = .json,
        .supports = "3 ports on globe, 4 dependencies",
    },
    .{
        .id = "portwatch_chokepoints_db",
        .name = "IMF PortWatch - Chokepoints database",
        .measures = "28 chokepoints with coordinates and traffic composition",
        .family = .reference,
        .freshness = .static,
        .poll_s = 7 * 86400,
        .lag = "reference",
        .licence = "IMF terms of use",
        .homepage = "https://portwatch.imf.org",
        .auth = .none,
        .format = .json,
        .supports = "3 chokepoint symbols, route tagging",
    },
    .{
        .id = "portwatch_disruptions",
        .name = "IMF PortWatch - Disruptions database",
        .measures = "Disruption events (cyclones, quakes, floods...) with affected ports",
        .family = .physical,
        .freshness = .near_live,
        .poll_s = 6 * 3600,
        .lag = "days",
        .licence = "IMF terms of use",
        .homepage = "https://portwatch.imf.org",
        .auth = .none,
        .format = .json,
        .supports = "3 disruption markers, Phase 2 labels",
    },
    .{
        .id = "portwatch_tradenow",
        .name = "IMF PortWatch - Monthly TradeNow",
        .measures = "Monthly AIS-based nowcast of trade value and volume per economy/region",
        .family = .structure,
        .freshness = .near_live,
        .poll_s = 86400,
        .lag = "~1 month (2026-09 on 2026-11-06)",
        .licence = "IMF terms of use",
        .homepage = "https://portwatch.imf.org",
        .auth = .none,
        .format = .json,
        .supports = "4 market value (benchmark for our nowcast)",
    },
    .{
        .id = "comtrade",
        .name = "UN Comtrade+",
        .measures = "Bilateral trade value (USD) and weight by HS code, reporter, partner, mode of transport",
        .family = .structure,
        .freshness = .lagged,
        .poll_s = 86400,
        .lag = "monthly data ~2-3 months for USA/DEU/CHE (2026-08 on 2026-11-06); China monthly only to 2024-12",
        .licence = "UN Comtrade terms; free tier 500 calls/day, 100k rows/call",
        .homepage = "https://comtradeplus.un.org",
        .auth = .{ .header = .{ .name = "Ocp-Apim-Subscription-Key", .env = "COMTRADE_API_KEY" } },
        .format = .json,
        .supports = "4 goods categories, value, dependencies; 6 trade graph",
    },
    .{
        .id = "census_porths",
        .name = "US Census international trade (port x HS)",
        .measures = "US imports by port of entry, HS code, partner, vessel value and weight",
        .family = .structure,
        .freshness = .lagged,
        .poll_s = 86400,
        .lag = "~5-6 weeks",
        .licence = "US Government work (public domain)",
        .homepage = "https://www.census.gov/foreign-trade/reference/guides/Guide_to_International_Trade_Datasets.pdf",
        .auth = .{ .query = .{ .param = "key", .env = "CENSUS_API_KEY" } },
        .format = .json,
        .supports = "validation of route allocation at real ports",
    },
    .{
        .id = "fred",
        .name = "FRED (St. Louis Fed)",
        .measures = "Brent/WTI daily, deep-sea freight PPI (monthly), FX rates",
        .family = .financial,
        .freshness = .near_live,
        .poll_s = 6 * 3600,
        .lag = "1-3 days (daily series); ~6 weeks (PPI)",
        .licence = "Free API key; series-specific copyright notes in FRED",
        .homepage = "https://fred.stlouisfed.org",
        .auth = .{ .query = .{ .param = "api_key", .env = "FRED_API_KEY" } },
        .format = .json,
        .supports = "5a financial; 4 market value (FX)",
    },
    .{
        .id = "gdelt_events",
        .name = "GDELT 2.0 Events",
        .measures = "Machine-coded news events (CAMEO), actors' countries, Goldstein scale, tone, mentions",
        .family = .media,
        .freshness = .live,
        .poll_s = 15 * 60,
        .lag = "15 minutes",
        .licence = "Free and open; cite GDELT",
        .homepage = "https://www.gdeltproject.org",
        .auth = .none,
        .format = .zip_tsv,
        .supports = "5b political, 5c media, 6 clustering signal",
    },
    .{
        .id = "gdacs",
        .name = "GDACS (EC JRC / UN OCHA)",
        .measures = "Global alerts: earthquakes, tropical cyclones, floods, volcanoes, droughts, wildfires",
        .family = .physical,
        .freshness = .near_live,
        .poll_s = 15 * 60,
        .lag = "minutes to hours",
        .licence = "Free; attribution to GDACS",
        .homepage = "https://www.gdacs.org",
        .auth = .none,
        .format = .json,
        .supports = "5d hazards, 3 markers",
    },
    .{
        .id = "usgs",
        .name = "USGS Earthquake Hazards",
        .measures = "Earthquakes M4.5+ (past week), location, depth, PAGER alert, tsunami flag",
        .family = .physical,
        .freshness = .live,
        .poll_s = 5 * 60,
        .lag = "minutes",
        .licence = "US Government work (public domain)",
        .homepage = "https://earthquake.usgs.gov",
        .auth = .none,
        .format = .json,
        .supports = "5d hazards",
    },
    .{
        .id = "opensanctions_maritime",
        .name = "OpenSanctions - maritime",
        .measures = "Sanctioned/flagged vessels (IMO, MMSI), operators, owners, risk tags",
        .family = .political,
        .freshness = .near_live,
        .poll_s = 86400,
        .lag = "~1 day",
        .licence = "CC BY-NC 4.0 (non-commercial use with attribution)",
        .homepage = "https://www.opensanctions.org",
        .auth = .none,
        .format = .json,
        .supports = "5b sanctions; join to AIS by IMO",
    },
    .{
        .id = "unga_votes",
        .name = "UN General Assembly voting (Bailey, Strezhnev & Voeten)",
        .measures = "Dyadic voting agreement and ideal points, 1946-2025",
        .family = .political,
        .freshness = .lagged,
        .poll_s = 30 * 86400,
        .lag = "annual",
        .licence = "CC0 1.0",
        .homepage = "https://dataverse.harvard.edu/dataset.xhtml?persistentId=doi:10.7910/DVN/LEJUQZ",
        .auth = .none,
        .format = .json,
        .supports = "5b alignment, 6 clustering",
    },
    .{
        .id = "marnet",
        .name = "Eurostat SeaRoute MARNET (20 km)",
        .measures = "Global maritime lane network (29,581 segments), tagged Suez/Panama/Malacca/Bab-el-Mandeb/...",
        .family = .reference,
        .freshness = .static,
        .poll_s = 0,
        .lag = "reference",
        .licence = "EUPL 1.2",
        .homepage = "https://github.com/eurostat/searoute",
        .auth = .none,
        .format = .binary,
        .supports = "3 routes along real sea lanes, rerouting",
    },
    .{
        .id = "natural_earth",
        .name = "Natural Earth",
        .measures = "Land polygons and coastlines (1:110m, 1:50m)",
        .family = .reference,
        .freshness = .static,
        .poll_s = 0,
        .lag = "reference",
        .licence = "Public domain",
        .homepage = "https://www.naturalearthdata.com",
        .auth = .none,
        .format = .binary,
        .supports = "3 globe",
    },
    .{
        .id = "nga_msi",
        .name = "NGA Maritime Safety Information",
        .measures = "Navigational warnings (NAVAREA) and anti-shipping activity messages (ASAM)",
        .family = .political,
        .freshness = .near_live,
        .poll_s = 3600,
        .lag = "hours; portal under maintenance (HTTP 503) on 2026-11-06",
        .licence = "US Government work (public domain)",
        .homepage = "https://msi.nga.mil",
        .auth = .none,
        .format = .json,
        .supports = "5b/5d official disruption evidence",
    },
};

pub fn find(id: []const u8) ?*const Source {
    for (&sources) |*s| if (std.mem.eql(u8, s.id, id)) return s;
    return null;
}

test "ids are unique" {
    for (sources, 0..) |a, i| for (sources[i + 1 ..]) |b| {
        try std.testing.expect(!std.mem.eql(u8, a.id, b.id));
    };
    try std.testing.expect(find("usgs") != null);
    try std.testing.expect(find("nope") == null);
}
