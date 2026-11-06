//! Minimal HTTPS/1.1 GET client.
//!
//! Why not `std.http.Client`? As of Zig 0.17.1 its HTTP-CONNECT proxy path
//! hands back the raw tunnel without running a TLS handshake over it, so
//! `https://` requests through a proxy stall. Cloud dev environments (and many
//! university networks) force a CONNECT proxy, so we need our own transport.
//! This one is deliberately small:
//!   * one request per connection (`Connection: close`), no pooling
//!   * optional CONNECT proxy taken from HTTPS_PROXY / https_proxy
//!   * system CA bundle, plus SSL_CERT_FILE if set
//!   * Content-Length, chunked and close-delimited bodies; gzip bodies
//!   * up to 5 redirects
//! Everything that parses bytes is a pure function with unit tests below.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const tls = std.crypto.tls;
const Certificate = std.crypto.Certificate;

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Response = struct {
    status: u16,
    /// Raw header block (without status line), owned.
    head: []u8,
    /// Decoded body (de-chunked, decompressed), owned.
    body: []u8,

    pub fn header(r: *const Response, name: []const u8) ?[]const u8 {
        return findHeader(r.head, name);
    }

    pub fn deinit(r: *Response, gpa: Allocator) void {
        gpa.free(r.head);
        gpa.free(r.body);
        r.* = undefined;
    }
};

pub const Url = struct {
    host: []const u8,
    port: u16,
    /// Path plus query, always starting with '/'.
    target: []const u8,
};

pub const Proxy = struct { host: []const u8, port: u16 };

pub const Error = error{
    UnsupportedScheme,
    InvalidUrl,
    ProxyRefused,
    MalformedResponse,
    TooManyRedirects,
    BodyTruncated,
    UnsupportedEncoding,
};

pub fn parseUrl(url: []const u8) Error!Url {
    const prefix = "https://";
    if (!std.ascii.startsWithIgnoreCase(url, prefix)) return error.UnsupportedScheme;
    const rest = url[prefix.len..];
    const slash = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
    const authority = rest[0..slash];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return error.InvalidUrl;
    var host = authority;
    var port: u16 = 443;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |c| {
        host = authority[0..c];
        port = std.fmt.parseInt(u16, authority[c + 1 ..], 10) catch return error.InvalidUrl;
    }
    if (host.len == 0) return error.InvalidUrl;
    const target = if (slash == rest.len) "/" else rest[slash..];
    return .{ .host = host, .port = port, .target = target };
}

/// Accepts `http://host:port`, `http://host:port/`, or bare `host:port`.
pub fn parseProxy(value: []const u8) ?Proxy {
    var v = std.mem.trim(u8, value, " \t\r\n");
    if (std.ascii.startsWithIgnoreCase(v, "http://")) v = v["http://".len..];
    if (std.mem.indexOfScalar(u8, v, '/')) |s| v = v[0..s];
    if (std.mem.indexOfScalar(u8, v, '@') != null) return null; // proxy auth unsupported
    const c = std.mem.lastIndexOfScalar(u8, v, ':') orelse return null;
    const port = std.fmt.parseInt(u16, v[c + 1 ..], 10) catch return null;
    if (c == 0) return null;
    return .{ .host = v[0..c], .port = port };
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return true;
    }
    return false;
}

/// Case-insensitive lookup in a CRLF-separated header block.
pub fn findHeader(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name))
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

pub const Split = struct { status: u16, head: []const u8, body: []const u8 };

/// Split a raw response into status code, header block and raw body.
pub fn splitResponse(raw: []const u8) Error!Split {
    const end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.MalformedResponse;
    const first_nl = std.mem.indexOf(u8, raw, "\r\n").?;
    const status_line = raw[0..first_nl];
    // "HTTP/1.1 200 OK"
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.")) return error.MalformedResponse;
    var parts = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = parts.next();
    const code_s = parts.next() orelse return error.MalformedResponse;
    const status = std.fmt.parseInt(u16, code_s, 10) catch return error.MalformedResponse;
    const head_start = @min(first_nl + 2, end);
    return .{ .status = status, .head = raw[head_start..end], .body = raw[end + 4 ..] };
}

/// Decode a chunked transfer-encoded body. Trailers are ignored.
pub fn dechunk(gpa: Allocator, raw: []const u8) (Error || Allocator.Error)![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (true) {
        const nl = std.mem.indexOfPos(u8, raw, i, "\r\n") orelse return error.BodyTruncated;
        var size_s = raw[i..nl];
        if (std.mem.indexOfScalar(u8, size_s, ';')) |semi| size_s = size_s[0..semi];
        const size = std.fmt.parseInt(usize, std.mem.trim(u8, size_s, " "), 16) catch return error.MalformedResponse;
        i = nl + 2;
        if (size == 0) break;
        if (i + size + 2 > raw.len) return error.BodyTruncated;
        try out.appendSlice(gpa, raw[i .. i + size]);
        i += size + 2;
    }
    return out.toOwnedSlice(gpa);
}

pub fn gunzip(gpa: Allocator, data: []const u8) ![]u8 {
    var in: Io.Reader = .fixed(data);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var d: std.compress.flate.Decompress = .init(&in, .gzip, &window);
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    _ = try d.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

/// Turn a raw response (head + body as received) into a decoded Response.
pub fn decode(gpa: Allocator, raw: []const u8) !Response {
    const s = try splitResponse(raw);
    var body: []u8 = undefined;
    const te = findHeader(s.head, "transfer-encoding");
    if (te != null and containsIgnoreCase(te.?, "chunked")) {
        body = try dechunk(gpa, s.body);
    } else if (findHeader(s.head, "content-length")) |cl_s| {
        const cl = std.fmt.parseInt(usize, cl_s, 10) catch return error.MalformedResponse;
        if (s.body.len < cl) return error.BodyTruncated;
        body = try gpa.dupe(u8, s.body[0..cl]);
    } else {
        body = try gpa.dupe(u8, s.body);
    }
    errdefer gpa.free(body);
    if (findHeader(s.head, "content-encoding")) |ce| {
        if (std.ascii.eqlIgnoreCase(ce, "gzip")) {
            const plain = try gunzip(gpa, body);
            gpa.free(body);
            body = plain;
        } else if (!std.ascii.eqlIgnoreCase(ce, "identity")) return error.UnsupportedEncoding;
    }
    return .{ .status = s.status, .head = try gpa.dupe(u8, s.head), .body = body };
}

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    bundle: Certificate.Bundle = .empty,
    bundle_lock: Io.RwLock = .init,
    proxy: ?Proxy = null,
    /// Owned copy of the proxy host string.
    proxy_host_buf: ?[]u8 = null,
    user_agent: []const u8 = "trade-atlas/0.1 (research prototype)",
    /// Hard cap on response size to protect memory.
    max_bytes: usize = 512 * 1024 * 1024,

    pub fn init(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) !Client {
        var c: Client = .{ .gpa = gpa, .io = io };
        errdefer c.deinit();
        const now = Io.Clock.real.now(io);
        try c.bundle.rescan(gpa, io, now);
        if (env.get("SSL_CERT_FILE")) |p| {
            if (std.fs.path.isAbsolute(p))
                c.bundle.addCertsFromFilePathAbsolute(gpa, io, now, p) catch {};
        }
        const pv = env.get("HTTPS_PROXY") orelse env.get("https_proxy");
        if (pv) |v| if (parseProxy(v)) |p| {
            c.proxy_host_buf = try gpa.dupe(u8, p.host);
            c.proxy = .{ .host = c.proxy_host_buf.?, .port = p.port };
        };
        return c;
    }

    pub fn deinit(c: *Client) void {
        c.bundle.deinit(c.gpa);
        if (c.proxy_host_buf) |b| c.gpa.free(b);
    }

    /// GET with redirect following. Caller owns the response.
    pub fn get(c: *Client, url: []const u8, headers: []const Header) !Response {
        var current = try c.gpa.dupe(u8, url);
        defer c.gpa.free(current);
        var hops: usize = 0;
        while (true) : (hops += 1) {
            var resp = try c.getOnce(current, headers);
            switch (resp.status) {
                301, 302, 303, 307, 308 => {
                    if (hops >= 5) {
                        resp.deinit(c.gpa);
                        return error.TooManyRedirects;
                    }
                    const loc = resp.header("location") orelse return resp;
                    const next = try resolveLocation(c.gpa, current, loc);
                    resp.deinit(c.gpa);
                    c.gpa.free(current);
                    current = next;
                },
                else => return resp,
            }
        }
    }

    /// Single request, no redirect handling. Caller owns the response.
    pub fn getOnce(c: *Client, url: []const u8, headers: []const Header) !Response {
        const u = try parseUrl(url);
        const conn = try Conn.open(c, u.host, u.port);
        defer conn.close();
        const w = conn.writer();
        try w.print("GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: {s}\r\nAccept-Encoding: gzip\r\nConnection: close\r\n", .{ u.target, u.host, c.user_agent });
        for (headers) |h| try w.print("{s}: {s}\r\n", .{ h.name, h.value });
        try w.writeAll("\r\n");
        try conn.flush();

        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(c.gpa);
        conn.reader().appendRemaining(c.gpa, &raw, .limited(c.max_bytes)) catch |err| switch (err) {
            // Servers that close without close_notify surface as ReadFailed
            // after delivering everything; `decode` verifies framing.
            error.ReadFailed => if (raw.items.len == 0) return err,
            else => |e| return e,
        };
        return decode(c.gpa, raw.items);
    }
};

/// A TLS connection to `host:port`, tunnelled through the client's proxy if
/// one is configured. Heap-allocated because the TLS state holds pointers
/// into the socket reader/writer. Shared by HTTPS requests and WebSockets.
pub const Conn = struct {
    gpa: Allocator,
    io: Io,
    stream: Io.net.Stream,
    sr: Io.net.Stream.Reader,
    sw: Io.net.Stream.Writer,
    tc: tls.Client,
    sock_read_buf: []u8,
    sock_write_buf: []u8,
    tls_read_buf: []u8,
    tls_write_buf: []u8,

    pub fn open(c: *Client, host: []const u8, port: u16) !*Conn {
        const gpa = c.gpa;
        const io = c.io;
        const self = try gpa.create(Conn);
        errdefer gpa.destroy(self);
        self.gpa = gpa;
        self.io = io;
        self.sock_read_buf = try gpa.alloc(u8, tls.Client.min_buffer_len);
        errdefer gpa.free(self.sock_read_buf);
        self.sock_write_buf = try gpa.alloc(u8, tls.Client.min_buffer_len);
        errdefer gpa.free(self.sock_write_buf);
        self.tls_read_buf = try gpa.alloc(u8, tls.Client.min_buffer_len + 16 * 1024);
        errdefer gpa.free(self.tls_read_buf);
        self.tls_write_buf = try gpa.alloc(u8, tls.Client.min_buffer_len);
        errdefer gpa.free(self.tls_write_buf);

        const dial_host = if (c.proxy) |p| p.host else host;
        const dial_port = if (c.proxy) |p| p.port else port;
        const hn = try Io.net.HostName.init(dial_host);
        // NOTE: Zig 0.17.1's threaded Io panics on connect timeouts
        // ("TODO implement netConnectIpPosix with timeout"), so deadlines are
        // enforced one level up, by cancelling the fetch task.
        self.stream = try hn.connect(io, dial_port, .{ .mode = .stream });
        errdefer self.stream.close(io);
        self.sr = self.stream.reader(io, self.sock_read_buf);
        self.sw = self.stream.writer(io, self.sock_write_buf);

        if (c.proxy != null) {
            try self.sw.interface.print("CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\n\r\n", .{ host, port, host, port });
            try self.sw.interface.flush();
            const status_line = try self.sr.interface.takeDelimiterInclusive('\n');
            if (!isStatus200(status_line)) return error.ProxyRefused;
            while (true) {
                const line = try self.sr.interface.takeDelimiterInclusive('\n');
                if (std.mem.trimEnd(u8, line, "\r\n").len == 0) break;
            }
        }

        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&entropy);
        self.tc = try tls.Client.init(&self.sr.interface, &self.sw.interface, .{
            .host = .{ .explicit = host },
            .ca = .{ .bundle = .{ .gpa = gpa, .io = io, .lock = &c.bundle_lock, .bundle = &c.bundle } },
            .read_buffer = self.tls_read_buf,
            .write_buffer = self.tls_write_buf,
            .entropy = &entropy,
            .realtime_now = Io.Clock.real.now(io),
            // Framing (Content-Length / chunked / WebSocket frames) is checked above TLS.
            .allow_truncation_attacks = true,
        });
        return self;
    }

    pub fn writer(self: *Conn) *Io.Writer {
        return &self.tc.writer;
    }

    pub fn reader(self: *Conn) *Io.Reader {
        return &self.tc.reader;
    }

    /// Push buffered plaintext through TLS and onto the socket.
    pub fn flush(self: *Conn) !void {
        try self.tc.writer.flush();
        try self.sw.interface.flush();
    }

    pub fn close(self: *Conn) void {
        const gpa = self.gpa;
        self.stream.close(self.io);
        gpa.free(self.sock_read_buf);
        gpa.free(self.sock_write_buf);
        gpa.free(self.tls_read_buf);
        gpa.free(self.tls_write_buf);
        gpa.destroy(self);
    }
};

fn isStatus200(status_line: []const u8) bool {
    return std.mem.startsWith(u8, status_line, "HTTP/1.") and status_line.len >= 12 and
        std.mem.eql(u8, status_line[9..12], "200");
}

/// Resolve a Location header against the current URL (absolute or path-only).
pub fn resolveLocation(gpa: Allocator, current: []const u8, loc: []const u8) ![]u8 {
    if (std.ascii.startsWithIgnoreCase(loc, "https://")) return gpa.dupe(u8, loc);
    if (std.ascii.startsWithIgnoreCase(loc, "http://")) {
        // Upgrade: we only speak TLS.
        return std.mem.concat(gpa, u8, &.{ "https://", loc["http://".len..] });
    }
    const u = try parseUrl(current);
    if (std.mem.startsWith(u8, loc, "/"))
        return std.fmt.allocPrint(gpa, "https://{s}:{d}{s}", .{ u.host, u.port, loc });
    return error.InvalidUrl;
}

const testing = std.testing;

test "parseUrl" {
    const u = try parseUrl("https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_hour.geojson");
    try testing.expectEqualStrings("earthquake.usgs.gov", u.host);
    try testing.expectEqual(@as(u16, 443), u.port);
    try testing.expectEqualStrings("/earthquakes/feed/v1.0/summary/all_hour.geojson", u.target);
    const q = try parseUrl("https://a.b:8443?x=1");
    try testing.expectEqualStrings("a.b", q.host);
    try testing.expectEqual(@as(u16, 8443), q.port);
    try testing.expectEqualStrings("?x=1", q.target);
    try testing.expectError(error.UnsupportedScheme, parseUrl("http://a.b/"));
    try testing.expectError(error.InvalidUrl, parseUrl("https://user@a.b/"));
}

test "parseProxy" {
    const p = parseProxy("http://127.0.0.1:40507").?;
    try testing.expectEqualStrings("127.0.0.1", p.host);
    try testing.expectEqual(@as(u16, 40507), p.port);
    try testing.expect(parseProxy("http://u:p@host:1") == null);
    try testing.expect(parseProxy("nonsense") == null);
}

test "decode content-length and headers" {
    const raw = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello";
    var r = try decode(testing.allocator, raw);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), r.status);
    try testing.expectEqualStrings("hello", r.body);
    try testing.expectEqualStrings("text/plain", r.header("CONTENT-TYPE").?);
}

test "decode chunked" {
    const raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5;ext=1\r\npedia\r\n0\r\n\r\n";
    var r = try decode(testing.allocator, raw);
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("Wikipedia", r.body);
}

test "decode truncated body is an error" {
    const raw = "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort";
    try testing.expectError(error.BodyTruncated, decode(testing.allocator, raw));
}

test "isStatus200" {
    try testing.expect(isStatus200("HTTP/1.1 200 Connection Established\r\n"));
    try testing.expect(!isStatus200("HTTP/1.1 403 Forbidden\r\n"));
    try testing.expect(!isStatus200("garbage"));
}

test "resolveLocation" {
    const a = try resolveLocation(testing.allocator, "https://x.org/a", "/b?c");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("https://x.org:443/b?c", a);
    const b = try resolveLocation(testing.allocator, "https://x.org/a", "http://y.org/z");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("https://y.org/z", b);
}
