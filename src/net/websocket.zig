//! Minimal RFC 6455 WebSocket client over `https.Conn` (wss:// only).
//! Client frames are masked as the RFC requires; server frames must not be.
//! Supports text/binary messages, fragmentation, ping/pong and close.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const https = @import("https.zig");

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,
};

pub const Error = error{
    HandshakeFailed,
    BadAccept,
    MaskedServerFrame,
    ProtocolError,
    MessageTooLarge,
    ConnectionClosed,
};

const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Sec-WebSocket-Accept for a given Sec-WebSocket-Key.
pub fn acceptKey(key: []const u8) [28]u8 {
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(key);
    h.update(guid);
    var digest: [20]u8 = undefined;
    h.final(&digest);
    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &digest);
    return out;
}

/// Write one complete (FIN) client frame: header, mask key, masked payload.
pub fn writeFrame(w: *Io.Writer, opcode: Opcode, payload: []const u8, mask: [4]u8) Io.Writer.Error!void {
    try w.writeByte(0x80 | @as(u8, @backingInt(opcode)));
    if (payload.len < 126) {
        try w.writeByte(0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 0xffff) {
        try w.writeByte(0x80 | 126);
        try w.writeInt(u16, @intCast(payload.len), .big);
    } else {
        try w.writeByte(0x80 | 127);
        try w.writeInt(u64, payload.len, .big);
    }
    try w.writeAll(&mask);
    for (payload, 0..) |b, i| try w.writeByte(b ^ mask[i % 4]);
}

pub const FrameHeader = struct {
    fin: bool,
    opcode: Opcode,
    masked: bool,
    len: u64,
};

/// Read a frame header from the stream.
pub fn readHeader(r: *Io.Reader) !FrameHeader {
    const b0 = try r.takeByte();
    const b1 = try r.takeByte();
    if (b0 & 0x70 != 0) return error.ProtocolError; // RSV bits: no extensions negotiated
    var len: u64 = b1 & 0x7f;
    if (len == 126) len = try r.takeInt(u16, .big) else if (len == 127) len = try r.takeInt(u64, .big);
    return .{ .fin = b0 & 0x80 != 0, .opcode = @fromBackingInt(@intCast(@as(u4, @truncate(b0)))), .masked = b1 & 0x80 != 0, .len = len };
}

pub const Message = struct {
    opcode: Opcode,
    data: []u8,
};

pub const Client = struct {
    conn: *https.Conn,
    io: Io,
    gpa: Allocator,
    max_message: usize = 16 * 1024 * 1024,
    closed: bool = false,

    /// Open `wss://host[:port]/path` and perform the upgrade handshake.
    pub fn connect(http: *https.Client, url: []const u8) !Client {
        const wss = "wss://";
        if (!std.ascii.startsWithIgnoreCase(url, wss)) return error.UnsupportedScheme;
        var buf: [2048]u8 = undefined;
        const as_https = try std.fmt.bufPrint(&buf, "https://{s}", .{url[wss.len..]});
        const u = try https.parseUrl(as_https);
        const conn = try https.Conn.open(http, u.host, u.port);
        errdefer conn.close();

        var nonce: [16]u8 = undefined;
        http.io.random(&nonce);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &nonce);

        const w = conn.writer();
        try w.print("GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{ u.target, u.host, http.user_agent, &key });
        try conn.flush();

        // Read the response head line by line; frames may follow immediately.
        const r = conn.reader();
        const status = try r.takeDelimiterInclusive('\n');
        if (!std.mem.startsWith(u8, status, "HTTP/1.1 101")) return error.HandshakeFailed;
        var accept_ok = false;
        const expected = acceptKey(&key);
        while (true) {
            const line = std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], "sec-websocket-accept"))
                accept_ok = std.mem.eql(u8, std.mem.trim(u8, line[colon + 1 ..], " "), &expected);
        }
        if (!accept_ok) return error.BadAccept;
        return .{ .conn = conn, .io = http.io, .gpa = http.gpa };
    }

    pub fn send(c: *Client, opcode: Opcode, payload: []const u8) !void {
        var mask: [4]u8 = undefined;
        c.io.random(&mask);
        try writeFrame(c.conn.writer(), opcode, payload, mask);
        try c.conn.flush();
    }

    pub fn sendText(c: *Client, text: []const u8) !void {
        return c.send(.text, text);
    }

    /// Block until a complete text/binary message arrives. Answers pings.
    /// Caller owns `data`.
    pub fn receive(c: *Client) !Message {
        const r = c.conn.reader();
        var acc: std.ArrayList(u8) = .empty;
        errdefer acc.deinit(c.gpa);
        var msg_opcode: ?Opcode = null;
        while (true) {
            const h = try readHeader(r);
            if (h.masked) return error.MaskedServerFrame;
            if (h.len > c.max_message or acc.items.len + h.len > c.max_message) return error.MessageTooLarge;
            const len: usize = @intCast(h.len);
            switch (h.opcode) {
                .ping => {
                    const p = try r.take(len);
                    var tmp: [125]u8 = undefined;
                    const n = @min(p.len, tmp.len);
                    @memcpy(tmp[0..n], p[0..n]);
                    try c.send(.pong, tmp[0..n]);
                },
                .pong => _ = try r.discard(.limited(len)),
                .close => {
                    _ = try r.discard(.limited(len));
                    c.closed = true;
                    return error.ConnectionClosed;
                },
                .text, .binary, .continuation => {
                    if (h.opcode != .continuation) {
                        if (msg_opcode != null) return error.ProtocolError;
                        msg_opcode = h.opcode;
                    } else if (msg_opcode == null) return error.ProtocolError;
                    try r.appendExact(c.gpa, &acc, len);
                    if (h.fin) return .{ .opcode = msg_opcode.?, .data = try acc.toOwnedSlice(c.gpa) };
                },
                _ => return error.ProtocolError,
            }
        }
    }

    pub fn close(c: *Client) void {
        if (!c.closed) c.send(.close, &.{ 0x03, 0xe8 }) catch {}; // 1000 normal closure
        c.conn.close();
    }
};

const testing = std.testing;

test "acceptKey matches RFC 6455 example" {
    const a = acceptKey("dGhlIHNhbXBsZSBub25jZQ==");
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &a);
}

test "writeFrame matches RFC 6455 masked 'Hello' example" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeFrame(&w, .text, "Hello", .{ 0x37, 0xfa, 0x21, 0x3d });
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 }, w.buffered());
}

test "writeFrame uses 16-bit length for 126..65535" {
    var buf: [300]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const payload: [200]u8 = @splat('a');
    try writeFrame(&w, .binary, &payload, .{ 0, 0, 0, 0 });
    try testing.expectEqual(@as(u8, 0x82), buf[0]);
    try testing.expectEqual(@as(u8, 0x80 | 126), buf[1]);
    try testing.expectEqual(@as(u16, 200), std.mem.readInt(u16, buf[2..4], .big));
}

test "readHeader parses unmasked server frame" {
    var r: Io.Reader = .fixed(&.{ 0x81, 0x05, 'H', 'e', 'l', 'l', 'o' });
    const h = try readHeader(&r);
    try testing.expect(h.fin);
    try testing.expectEqual(Opcode.text, h.opcode);
    try testing.expect(!h.masked);
    try testing.expectEqual(@as(u64, 5), h.len);
}

test "readHeader 64-bit length and RSV rejection" {
    var r: Io.Reader = .fixed(&.{ 0x82, 127, 0, 0, 0, 0, 0, 1, 0, 0 });
    const h = try readHeader(&r);
    try testing.expectEqual(@as(u64, 65536), h.len);
    var bad: Io.Reader = .fixed(&.{ 0xC1, 0x00 });
    try testing.expectError(error.ProtocolError, readHeader(&bad));
}
