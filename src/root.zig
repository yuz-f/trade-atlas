//! Library root: every module, so `zig build test` covers all of them.

pub const https = @import("net/https.zig");
pub const websocket = @import("net/websocket.zig");
pub const time = @import("util/time.zig");
pub const zip = @import("util/zip.zig");
pub const registry = @import("ingest/registry.zig");
pub const schema = @import("ingest/schema.zig");
pub const usgs = @import("ingest/usgs.zig");
pub const gdacs = @import("ingest/gdacs.zig");
pub const portwatch = @import("ingest/portwatch.zig");
pub const fred = @import("ingest/fred.zig");
pub const comtrade = @import("ingest/comtrade.zig");
pub const gdelt = @import("ingest/gdelt.zig");
pub const aisstream = @import("ingest/aisstream.zig");
pub const opensanctions = @import("ingest/opensanctions.zig");
pub const probe = @import("probe.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
