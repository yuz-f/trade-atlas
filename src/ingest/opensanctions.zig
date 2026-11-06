//! OpenSanctions "maritime" collection: sanctioned/flagged vessels,
//! operators and owners. Index: https://data.opensanctions.org/datasets/latest/maritime/index.json
//! (redirects to a versioned artifact). Licence: CC BY-NC 4.0 (non-commercial,
//! attribution). Updated daily. Verified 2026-11-06.

const std = @import("std");

pub const index_url = "https://data.opensanctions.org/datasets/latest/maritime/index.json";

pub const Index = struct {
    updated_at: []const u8,
    entity_count: ?i64 = null,
    target_count: ?i64 = null,
    resources: []struct {
        name: []const u8,
        url: []const u8,
        size: ?i64 = null,
        checksum: ?[]const u8 = null,
    },
};

pub fn parseIndex(gpa: std.mem.Allocator, body: []const u8) !std.json.Parsed(Index) {
    return std.json.parseFromSlice(Index, gpa, body, .{ .ignore_unknown_fields = true });
}

/// Header of maritime.csv as served on 2026-11-06.
pub const csv_header = "\"type\",\"caption\",\"imo\",\"risk\",\"countries\",\"flag\",\"mmsi\",\"id\",\"url\",\"datasets\",\"aliases\"";

/// "IMO9427366" -> 9427366
pub fn imoNumber(s: []const u8) ?u64 {
    const digits = if (std.mem.startsWith(u8, s, "IMO")) s[3..] else s;
    if (digits.len != 7) return null;
    return std.fmt.parseInt(u64, digits, 10) catch null;
}

test "imoNumber" {
    try std.testing.expectEqual(@as(?u64, 9427366), imoNumber("IMO9427366"));
    try std.testing.expectEqual(@as(?u64, null), imoNumber(""));
    try std.testing.expectEqual(@as(?u64, null), imoNumber("IMO12"));
}
