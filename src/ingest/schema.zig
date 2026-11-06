//! Summarise the shape of a JSON document as a list of key paths and types.
//! Used by `atlas probe` so that every field name we rely on is taken from a
//! real response, never typed from memory. Arrays are summarised by their
//! first element (`[]`), objects by their keys.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub fn typeName(v: Value) []const u8 {
    return switch (v) {
        .null => "null",
        .bool => "bool",
        .integer => "int",
        .float => "float",
        .number_string => "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

/// Append one line per leaf path, e.g. `features[].properties.mag: float`.
pub fn summarise(gpa: Allocator, out: *std.ArrayList(u8), v: Value, path: []const u8, max_depth: usize) !void {
    switch (v) {
        .object => |o| {
            if (max_depth == 0 or o.count() == 0) return line(gpa, out, path, "object");
            var it = o.iterator();
            while (it.next()) |e| {
                const p = if (path.len == 0)
                    try gpa.dupe(u8, e.key_ptr.*)
                else
                    try std.fmt.allocPrint(gpa, "{s}.{s}", .{ path, e.key_ptr.* });
                defer gpa.free(p);
                try summarise(gpa, out, e.value_ptr.*, p, max_depth - 1);
            }
        },
        .array => |a| {
            const p = try std.fmt.allocPrint(gpa, "{s}[]", .{path});
            defer gpa.free(p);
            if (a.items.len == 0 or max_depth == 0) return line(gpa, out, p, "array(empty)");
            try summarise(gpa, out, a.items[0], p, max_depth - 1);
        },
        else => try line(gpa, out, path, typeName(v)),
    }
}

fn line(gpa: Allocator, out: *std.ArrayList(u8), path: []const u8, t: []const u8) !void {
    try out.print(gpa, "{s}: {s}\n", .{ if (path.len == 0) "$" else path, t });
}

pub fn summariseSlice(gpa: Allocator, json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(Value, gpa, json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try summarise(gpa, &out, parsed.value, "", 8);
    return out.toOwnedSlice(gpa);
}

test "summarise nested json" {
    const gpa = std.testing.allocator;
    const s = try summariseSlice(gpa,
        \\{"type":"FeatureCollection","features":[{"properties":{"mag":4.5,"place":"x"},"id":"a"}],"n":3}
    );
    defer gpa.free(s);
    try std.testing.expectEqualStrings(
        \\type: string
        \\features[].properties.mag: float
        \\features[].properties.place: string
        \\features[].id: string
        \\n: int
        \\
    , s);
}
