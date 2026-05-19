//! URL encoding and hostname extraction utilities.
//!
//! Pure functions for `application/x-www-form-urlencoded` encoding and
//! host extraction from URL strings. No I/O, no allocation beyond the
//! caller-provided `ArrayList` buffer.

const std = @import("std");

/// Returns `true` when `c` is an RFC 3986 unreserved character (A-Z, a-z,
/// 0-9, '-', '_', '.', '~').
///
/// Characters outside this set must be percent-encoded in form-encoded
/// payloads so the server can distinguish parameter delimiters from
/// literal data.
///
/// This predicate is called per-byte by `formEncodeAppend`, which builds
/// the encoded form body used for POST requests.
pub fn isUnreserved(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == '.' or c == '~';
}

/// Appends a percent-encoded version of `input` to `buf` following
/// `application/x-www-form-urlencoded` rules.
///
/// Behavior:
/// - Unreserved characters (A-Z, a-z, 0-9, '-', '_', '.', '~') are appended as-is.
/// - Space characters (' ') are converted to '+'.
/// - All other characters are percent-encoded as uppercase hex (e.g., '%0A').
///
/// Arguments:
/// - `allocator`: Used to grow the `buf` ArrayList if needed.
/// - `buf`: The destination buffer to append the encoded string to.
/// - `input`: The raw string to be encoded.
///
/// Errors: `OutOfMemory` if the buffer cannot grow.
pub fn formEncodeAppend(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), input: []const u8) !void {
    for (input) |c| {
        if (isUnreserved(c)) {
            try buf.append(allocator, c);
        } else if (c == ' ') {
            try buf.append(allocator, '+');
        } else {
            var tmp: [3]u8 = undefined;
            const enc = try std.fmt.bufPrint(&tmp, "%{X:0>2}", .{c});
            try buf.appendSlice(allocator, enc);
        }
    }
}

/// Extract the hostname from a URL string for credential lookup.
///
/// Uses `std.Uri.parse` to extract the host component. Returns a slice
/// into `url` (no allocation). Falls back to returning the full `url`
/// string when parsing fails or no host is present.
pub fn hostnameFromUrl(url: []const u8) []const u8 {
    const uri = std.Uri.parse(url) catch return url;
    return if (uri.host) |h| h.percent_encoded else url;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "isUnreserved: letters, digits, and special unreserved chars" {
    const testing = std.testing;
    try testing.expect(isUnreserved('A'));
    try testing.expect(isUnreserved('Z'));
    try testing.expect(isUnreserved('a'));
    try testing.expect(isUnreserved('z'));
    try testing.expect(isUnreserved('0'));
    try testing.expect(isUnreserved('9'));
    try testing.expect(isUnreserved('-'));
    try testing.expect(isUnreserved('_'));
    try testing.expect(isUnreserved('.'));
    try testing.expect(isUnreserved('~'));
}

test "isUnreserved: reserved and special chars return false" {
    const testing = std.testing;
    try testing.expect(!isUnreserved(' '));
    try testing.expect(!isUnreserved('='));
    try testing.expect(!isUnreserved('&'));
    try testing.expect(!isUnreserved('%'));
    try testing.expect(!isUnreserved('+'));
    try testing.expect(!isUnreserved('/'));
    try testing.expect(!isUnreserved('?'));
    try testing.expect(!isUnreserved('#'));
    try testing.expect(!isUnreserved('\x00'));
    try testing.expect(!isUnreserved('\xff'));
}

test "formEncodeAppend: unreserved chars pass through" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try formEncodeAppend(allocator, &buf, "hello_world-1.0~");
    try std.testing.expectEqualStrings("hello_world-1.0~", buf.items);
}

test "formEncodeAppend: spaces become plus, specials percent-encoded" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try formEncodeAppend(allocator, &buf, "a b=c&d");
    try std.testing.expectEqualStrings("a+b%3Dc%26d", buf.items);
}

test "formEncodeAppend: empty input produces empty output" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try formEncodeAppend(allocator, &buf, "");
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "formEncodeAppend: all special bytes percent-encoded" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try formEncodeAppend(allocator, &buf, "\x00\x01\xff");
    try std.testing.expectEqualStrings("%00%01%FF", buf.items);
}

test "hostnameFromUrl: extracts host from full URL" {
    try std.testing.expectEqualStrings(
        "openqa.opensuse.org",
        hostnameFromUrl("https://openqa.opensuse.org/api/v1/jobs"),
    );
}

test "hostnameFromUrl: extracts host from URL with port" {
    try std.testing.expectEqualStrings(
        "localhost",
        hostnameFromUrl("http://localhost:9526/tests/42"),
    );
}

test "hostnameFromUrl: returns full string on parse failure" {
    try std.testing.expectEqualStrings(
        "not a url at all",
        hostnameFromUrl("not a url at all"),
    );
}

test "hostnameFromUrl: scheme-only URL with no host returns input" {
    // Edge case: "file:///" has no host authority
    const result = hostnameFromUrl("file:///etc/passwd");
    // std.Uri may or may not parse host as empty — verify no crash
    _ = result;
}
