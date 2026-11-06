//! Date/time parsing for the formats our sources actually use. All results
//! are Unix seconds, UTC. Sources that publish local time are not used.

const std = @import("std");

pub const Error = error{InvalidDate};

/// Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's algorithm).
pub fn daysFromCivil(y_in: i64, m: u8, d: u8) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = @as(i64, (m + 9) % 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const Civil = struct { year: i64, month: u8, day: u8 };

pub fn civilFromDays(z_in: i64) Civil {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    return .{ .year = y, .month = m, .day = d };
}

fn num(s: []const u8) Error!i64 {
    return std.fmt.parseInt(i64, s, 10) catch error.InvalidDate;
}

fn validated(y: i64, m: i64, d: i64, hh: i64, mm: i64, ss: i64) Error!i64 {
    if (m < 1 or m > 12 or d < 1 or d > 31 or hh > 23 or mm > 59 or ss > 60 or hh < 0 or mm < 0 or ss < 0) return error.InvalidDate;
    return daysFromCivil(y, @intCast(m), @intCast(d)) * 86400 + hh * 3600 + mm * 60 + ss;
}

/// "YYYY-MM-DD", "YYYY-MM-DDTHH:MM:SS[.fff][Z]" or "YYYY-MM-DD HH:MM:SS[.fff...]"
/// (trailing zone text such as " +0000 UTC" is accepted only if it is +0000/Z/UTC).
pub fn parseIso(s: []const u8) Error!i64 {
    if (s.len < 10 or s[4] != '-' or s[7] != '-') return error.InvalidDate;
    const y = try num(s[0..4]);
    const m = try num(s[5..7]);
    const d = try num(s[8..10]);
    if (s.len == 10) return validated(y, m, d, 0, 0, 0);
    if ((s[10] != 'T' and s[10] != ' ') or s.len < 19 or s[13] != ':' or s[16] != ':') return error.InvalidDate;
    const t = try validated(y, m, d, try num(s[11..13]), try num(s[14..16]), try num(s[17..19]));
    var rest = s[19..];
    if (rest.len > 0 and rest[0] == '.') {
        var i: usize = 1;
        while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
        rest = rest[i..];
    }
    rest = std.mem.trim(u8, rest, " ");
    if (rest.len == 0 or std.mem.eql(u8, rest, "Z") or std.mem.eql(u8, rest, "+0000 UTC") or
        std.mem.eql(u8, rest, "+00:00") or std.mem.eql(u8, rest, "UTC")) return t;
    return error.InvalidDate;
}

/// GDELT "YYYYMMDDHHMMSS".
pub fn parseCompact(s: []const u8) Error!i64 {
    if (s.len != 14) return error.InvalidDate;
    return validated(try num(s[0..4]), try num(s[4..6]), try num(s[6..8]), try num(s[8..10]), try num(s[10..12]), try num(s[12..14]));
}

/// Comtrade monthly period "YYYYMM" (or annual "YYYY") -> first day of period.
pub fn parsePeriod(s: []const u8) Error!i64 {
    if (s.len == 4) return validated(try num(s), 1, 1, 0, 0, 0);
    if (s.len == 6) return validated(try num(s[0..4]), try num(s[4..6]), 1, 0, 0, 0);
    return error.InvalidDate;
}

/// Format Unix seconds as "YYYY-MM-DDTHH:MM:SSZ".
pub fn formatIso(buf: *[20]u8, t: i64) []const u8 {
    const days = @divFloor(t, 86400);
    const sod: u64 = @intCast(t - days * 86400);
    const c = civilFromDays(days);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u64, @intCast(c.year)), c.month, c.day, sod / 3600, (sod / 60) % 60, sod % 60,
    }) catch unreachable;
}

const testing = std.testing;

test "civil round trip" {
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, 19723), daysFromCivil(2024, 1, 1));
    const c = civilFromDays(daysFromCivil(2000, 2, 29));
    try testing.expectEqual(@as(i64, 2000), c.year);
    try testing.expectEqual(@as(u8, 2), c.month);
    try testing.expectEqual(@as(u8, 29), c.day);
}

test "source formats" {
    // 2026-11-06T07:11:17Z = 1793949077
    try testing.expectEqual(@as(i64, 1793949077), try parseIso("2026-11-06T07:11:17"));
    try testing.expectEqual(@as(i64, 1793949077), try parseIso("2026-11-06 07:11:17.05898103 +0000 UTC")); // AISStream
    try testing.expectEqual(@as(i64, 1793923200), try parseIso("2026-11-06")); // PortWatch / FRED
    try testing.expectEqual(@as(i64, 1793948400), try parseCompact("20261106070000")); // GDELT
    try testing.expectEqual(@as(i64, try parseIso("2026-06-01")), try parsePeriod("202606")); // Comtrade
    try testing.expectError(error.InvalidDate, parseIso("2026-13-01"));
    try testing.expectError(error.InvalidDate, parseIso("2026-11-06T07:11:17+02:00"));
}

test "formatIso" {
    var b: [20]u8 = undefined;
    try testing.expectEqualStrings("2026-11-06T07:11:17Z", formatIso(&b, 1793949077));
}
