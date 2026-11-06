//! In-memory reader for small ZIP archives (GDELT ships each 15-minute
//! update as a one-entry .zip). Reads the central directory, so entries that
//! use data descriptors (sizes after the data) are handled too.
//! Supports "stored" (0) and "deflate" (8) entries; no ZIP64, no encryption.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ NotZip, Truncated, UnsupportedMethod, Encrypted, EntryNotFound, Zip64Unsupported };

pub const Entry = struct {
    name: []const u8,
    method: u16,
    compressed_size: u32,
    uncompressed_size: u32,
    local_header_offset: u32,
    flags: u16,
};

fn rd16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}
fn rd32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

/// Locate the End Of Central Directory record (it sits within the last 64 KiB + 22 bytes).
fn findEocd(data: []const u8) Error!usize {
    if (data.len < 22) return error.NotZip;
    var i: usize = data.len - 22;
    const stop = if (data.len > 22 + 0xffff) data.len - 22 - 0xffff else 0;
    while (true) : (i -= 1) {
        if (rd32(data, i) == 0x06054b50) return i;
        if (i == stop) return error.NotZip;
    }
}

/// List entries. Caller owns the returned slice (names point into `data`).
pub fn entries(gpa: Allocator, data: []const u8) (Error || Allocator.Error)![]Entry {
    const eocd = try findEocd(data);
    const count = rd16(data, eocd + 10);
    const cd_off = rd32(data, eocd + 16);
    if (cd_off == 0xffffffff) return error.Zip64Unsupported;
    var list: std.ArrayList(Entry) = .empty;
    errdefer list.deinit(gpa);
    var p: usize = cd_off;
    var n: usize = 0;
    while (n < count) : (n += 1) {
        if (p + 46 > data.len or rd32(data, p) != 0x02014b50) return error.Truncated;
        const name_len = rd16(data, p + 28);
        const extra_len = rd16(data, p + 30);
        const comment_len = rd16(data, p + 32);
        if (p + 46 + name_len > data.len) return error.Truncated;
        try list.append(gpa, .{
            .flags = rd16(data, p + 8),
            .method = rd16(data, p + 10),
            .compressed_size = rd32(data, p + 20),
            .uncompressed_size = rd32(data, p + 24),
            .local_header_offset = rd32(data, p + 42),
            .name = data[p + 46 ..][0..name_len],
        });
        p += 46 + name_len + extra_len + comment_len;
    }
    return list.toOwnedSlice(gpa);
}

/// Decompress one entry. Caller owns the result.
pub fn extract(gpa: Allocator, data: []const u8, e: Entry) ![]u8 {
    if (e.flags & 1 != 0) return error.Encrypted;
    const lh = e.local_header_offset;
    if (lh + 30 > data.len or rd32(data, lh) != 0x04034b50) return error.Truncated;
    const start = lh + 30 + rd16(data, lh + 26) + rd16(data, lh + 28);
    if (start + e.compressed_size > data.len) return error.Truncated;
    const comp = data[start..][0..e.compressed_size];
    switch (e.method) {
        0 => return gpa.dupe(u8, comp),
        8 => {
            var in: std.Io.Reader = .fixed(comp);
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var d: std.compress.flate.Decompress = .init(&in, .raw, &window);
            var out: std.Io.Writer.Allocating = try .initCapacity(gpa, e.uncompressed_size);
            errdefer out.deinit();
            _ = try d.reader.streamRemaining(&out.writer);
            if (out.written().len != e.uncompressed_size) return error.Truncated;
            return out.toOwnedSlice();
        },
        else => return error.UnsupportedMethod,
    }
}

/// Convenience: decompress the first entry.
pub fn extractFirst(gpa: Allocator, data: []const u8) ![]u8 {
    const es = try entries(gpa, data);
    defer gpa.free(es);
    if (es.len == 0) return error.EntryNotFound;
    return extract(gpa, data, es[0]);
}

test "extract stored entry from hand-built zip" {
    // Built per APPNOTE.TXT: local header + data + central dir + EOCD; "hi" stored.
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const name = "a.txt";
    const body = "hi";
    const crc = std.hash.Crc32.hash(body);
    // local file header
    try buf.appendSlice(gpa, &.{ 0x50, 0x4b, 0x03, 0x04, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    try appendInt(gpa, &buf, u32, crc);
    try appendInt(gpa, &buf, u32, body.len);
    try appendInt(gpa, &buf, u32, body.len);
    try appendInt(gpa, &buf, u16, name.len);
    try appendInt(gpa, &buf, u16, 0);
    try buf.appendSlice(gpa, name);
    try buf.appendSlice(gpa, body);
    const cd = buf.items.len;
    try buf.appendSlice(gpa, &.{ 0x50, 0x4b, 0x01, 0x02, 20, 0, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    try appendInt(gpa, &buf, u32, crc);
    try appendInt(gpa, &buf, u32, body.len);
    try appendInt(gpa, &buf, u32, body.len);
    try appendInt(gpa, &buf, u16, name.len);
    try buf.appendSlice(gpa, &(@as([12]u8, @splat(0)))); // extra, comment, disk, attrs
    try appendInt(gpa, &buf, u32, 0); // local header offset
    try buf.appendSlice(gpa, name);
    const cd_size = buf.items.len - cd;
    try buf.appendSlice(gpa, &.{ 0x50, 0x4b, 0x05, 0x06, 0, 0, 0, 0, 1, 0, 1, 0 });
    try appendInt(gpa, &buf, u32, @intCast(cd_size));
    try appendInt(gpa, &buf, u32, @intCast(cd));
    try appendInt(gpa, &buf, u16, 0);

    const es = try entries(gpa, buf.items);
    defer gpa.free(es);
    try std.testing.expectEqual(@as(usize, 1), es.len);
    try std.testing.expectEqualStrings("a.txt", es[0].name);
    const out = try extractFirst(gpa, buf.items);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("hi", out);
}

fn appendInt(gpa: Allocator, buf: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try buf.appendSlice(gpa, &b);
}

test "not a zip" {
    try std.testing.expectError(error.NotZip, entries(std.testing.allocator, "hello world, definitely not a zip file"));
}
