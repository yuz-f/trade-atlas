//! AISStream.io live AIS over WebSocket (wss://stream.aisstream.io/v0/stream).
//! Free, beta, no SLA, message schema may change. Key: env AISSTREAM_API_KEY.
//! The subscription must be sent within 3 s of connecting. Messages arrive as
//! binary frames containing JSON. Field names verified on live messages
//! (2026-11-06).
//!
//! Coverage is terrestrial-receiver based. In a 90 s global sample on
//! 2026-11-06 (4,555 position reports) there were ZERO reports in boxes
//! around Hormuz, Bab-el-Mandeb, Suez, the Taiwan Strait and the Bosporus,
//! while Malacca, Gibraltar, Dover and the Cape were covered. Absence of
//! ships in AISStream is therefore NOT evidence of absence of traffic.

const std = @import("std");
const time = @import("../util/time.zig");

pub const url = "wss://stream.aisstream.io/v0/stream";

pub const Box = struct { lat_min: f64, lon_min: f64, lat_max: f64, lon_max: f64 };

/// Build the subscription message. Caller owns the result.
/// NOTE: contains the API key — never log or persist it.
pub fn subscription(gpa: std.mem.Allocator, key: []const u8, boxes: []const Box, message_types: []const []const u8) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    errdefer w.deinit();
    try w.writer.writeAll("{\"APIKey\":");
    try std.json.Stringify.encodeJsonString(key, .{}, &w.writer);
    try w.writer.writeAll(",\"BoundingBoxes\":[");
    for (boxes, 0..) |b, i| {
        if (i > 0) try w.writer.writeByte(',');
        try w.writer.print("[[{d},{d}],[{d},{d}]]", .{ b.lat_min, b.lon_min, b.lat_max, b.lon_max });
    }
    try w.writer.writeByte(']');
    if (message_types.len > 0) {
        try w.writer.writeAll(",\"FilterMessageTypes\":[");
        for (message_types, 0..) |t, i| {
            if (i > 0) try w.writer.writeByte(',');
            try std.json.Stringify.encodeJsonString(t, .{}, &w.writer);
        }
        try w.writer.writeByte(']');
    }
    try w.writer.writeByte('}');
    return w.toOwnedSlice();
}

pub const Envelope = struct {
    MessageType: []const u8,
    MetaData: ?struct {
        MMSI: u64,
        ShipName: ?[]const u8 = null,
        latitude: f64,
        longitude: f64,
        /// "2026-11-06 07:11:17.05898103 +0000 UTC"
        time_utc: []const u8,
    } = null,
    Message: ?struct {
        PositionReport: ?struct {
            Sog: ?f64 = null,
            Cog: ?f64 = null,
            TrueHeading: ?f64 = null,
            NavigationalStatus: ?i64 = null,
            Valid: ?bool = null,
        } = null,
        ShipStaticData: ?struct {
            ImoNumber: ?u64 = null,
            /// AIS ship type code (70-79 cargo, 80-89 tanker, ...)
            Type: ?i64 = null,
            Destination: ?[]const u8 = null,
            MaximumStaticDraught: ?f64 = null,
            Dimension: ?struct { A: i64 = 0, B: i64 = 0, C: i64 = 0, D: i64 = 0 } = null,
        } = null,
    } = null,
};

pub fn parse(gpa: std.mem.Allocator, msg: []const u8) !std.json.Parsed(Envelope) {
    return std.json.parseFromSlice(Envelope, gpa, msg, .{ .ignore_unknown_fields = true });
}

pub const ShipClass = enum { cargo, tanker, passenger, other };

pub fn shipClass(ais_type: i64) ShipClass {
    return switch (ais_type) {
        70...79 => .cargo,
        80...89 => .tanker,
        60...69 => .passenger,
        else => .other,
    };
}

test "subscription json" {
    const gpa = std.testing.allocator;
    const s = try subscription(gpa, "KEY", &.{.{ .lat_min = 24, .lon_min = 54, .lat_max = 28, .lon_max = 60 }}, &.{"PositionReport"});
    defer gpa.free(s);
    try std.testing.expectEqualStrings("{\"APIKey\":\"KEY\",\"BoundingBoxes\":[[[24,54],[28,60]]],\"FilterMessageTypes\":[\"PositionReport\"]}", s);
}

test "parse real position report" {
    const gpa = std.testing.allocator;
    const p = try parse(gpa,
        \\{"MetaData":{"MMSI":244815000,"MMSI_String":244815000,"ShipName":"TX1 KLASINA J   ","latitude":52.45907,"longitude":4.59398,"time_utc":"2026-11-06 07:11:17.05898103 +0000 UTC"},"MessageType":"PositionReport","Message":{"PositionReport":{"MessageID":1,"RepeatIndicator":0,"UserID":244815000,"Valid":true,"NavigationalStatus":7,"RateOfTurn":-128,"Sog":0,"PositionAccuracy":false,"Longitude":4.59398,"Latitude":52.459073333333336,"Cog":57.7,"TrueHeading":511,"Timestamp":17,"SpecialManoeuvreIndicator":0,"Spare":0,"Raim":false,"CommunicationState":151084}}}
    );
    defer p.deinit();
    const md = p.value.MetaData.?;
    try std.testing.expectEqual(@as(u64, 244815000), md.MMSI);
    try std.testing.expectEqual(try time.parseIso("2026-11-06T07:11:17"), try time.parseIso(md.time_utc));
    try std.testing.expectEqual(@as(?f64, 57.7), p.value.Message.?.PositionReport.?.Cog);
}

test "parse real static data" {
    const gpa = std.testing.allocator;
    const p = try parse(gpa,
        \\{"MetaData":{"MMSI":311001158,"ShipName":"STAR ASPIRATION     ","latitude":-21.11344,"longitude":149.61762,"time_utc":"2026-11-06 07:11:17.075231898 +0000 UTC"},"MessageType":"ShipStaticData","Message":{"ShipStaticData":{"AisVersion":1,"CallSign":"C6FO9  ","Destination":"AU HPT              ","Dimension":{"A":195,"B":35,"C":20,"D":18},"ImoNumber":9458767,"MaximumStaticDraught":7.7,"Type":70}}}
    );
    defer p.deinit();
    const sd = p.value.Message.?.ShipStaticData.?;
    try std.testing.expectEqual(@as(?u64, 9458767), sd.ImoNumber);
    try std.testing.expectEqual(ShipClass.cargo, shipClass(sd.Type.?));
}
