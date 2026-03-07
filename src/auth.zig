const std = @import("std");
const HmacSha1 = std.crypto.auth.hmac.HmacSha1;

/// Writes 40-char lowercase hex HMAC-SHA1 digest into `out[0..40]`.
pub fn hmacSha1Hex(
    key: []const u8,
    message: []const u8,
    out: *[40]u8,
) void {
    var hmac_out: [HmacSha1.mac_length]u8 = undefined;
    HmacSha1.create(&hmac_out, message, key);
    out.* = std.fmt.bytesToHex(hmac_out, .lower);
}

/// Returns a stack-allocated array of the three auth headers.
/// `timestamp` must outlive the returned headers (they borrow from it).
/// `api_key` and `hash_buf` must outlive the returned headers.
pub fn buildAuthHeaders(
    api_key: []const u8,
    api_secret: []const u8,
    path_and_query: []const u8,
    timestamp: []const u8,
    hash_buf: *[40]u8,
) [3]std.http.Header {
    var hmac = HmacSha1.init(api_secret);
    hmac.update(path_and_query);
    hmac.update(timestamp);
    var hmac_out: [HmacSha1.mac_length]u8 = undefined;
    hmac.final(&hmac_out);
    hash_buf.* = std.fmt.bytesToHex(hmac_out, .lower);

    return [3]std.http.Header{
        .{ .name = "X-API-Microtime", .value = timestamp },
        .{ .name = "X-API-Key", .value = api_key },
        .{ .name = "X-API-Hash", .value = hash_buf },
    };
}

test "hmacSha1Hex" {
    const testing = std.testing;

    var out: [40]u8 = undefined;
    hmacSha1Hex("key", "The quick brown fox jumps over the lazy dog", &out);

    // Expected value from standard HMAC-SHA1 tests
    try testing.expectEqualStrings("de7c9b85b8b78aa6bc8a7a36f70a90701c9db4d9", &out);
}

test "buildAuthHeaders" {
    const testing = std.testing;

    const api_key = "MYKEY";
    const api_secret = "MYSECRET";
    const path_and_query = "/api/v1/jobs/1?foo=bar";
    const timestamp = "1234567890";

    var hash_buf: [40]u8 = undefined;
    const headers = buildAuthHeaders(api_key, api_secret, path_and_query, timestamp, &hash_buf);

    try testing.expectEqualStrings("X-API-Microtime", headers[0].name);
    try testing.expectEqualStrings("1234567890", headers[0].value);

    try testing.expectEqualStrings("X-API-Key", headers[1].name);
    try testing.expectEqualStrings("MYKEY", headers[1].value);

    try testing.expectEqualStrings("X-API-Hash", headers[2].name);

    // Compute expected hash manually
    var expected_hash: [40]u8 = undefined;
    hmacSha1Hex(api_secret, "/api/v1/jobs/1?foo=bar1234567890", &expected_hash);

    try testing.expectEqualStrings(&expected_hash, headers[2].value);
    try testing.expectEqualStrings(&expected_hash, &hash_buf);
}

test "buildAuthHeaders: openQA reference values" {
    const testing = std.testing;

    // Values from real failed E2E run against reference Perl implementation
    const api_key = "47A19E5C33D8382C";
    const api_secret = "A42C3826ECEAD136";
    const path_and_query = "/api/v1/isos";
    const timestamp = "1772841033";
    const expected_hash = "fb0924abfd5c774240b2f54123d3ffda3ec265a3";

    var hash_buf: [40]u8 = undefined;
    const headers = buildAuthHeaders(api_key, api_secret, path_and_query, timestamp, &hash_buf);

    try testing.expectEqualStrings(expected_hash, headers[2].value);
    try testing.expectEqualStrings(expected_hash, &hash_buf);
}

test "buildAuthHeaders: dummy values" {
    const testing = std.testing;

    // Completely invented dummy values
    const api_key = "DUMMY_KEY_123";
    const api_secret = "DUMMY_SECRET_456";
    const path_and_query = "/api/v1/dummy/path?foo=bar";
    const timestamp = "1122334455";
    
    // Manual calculation verify:
    // StringToSign: "/api/v1/dummy/path?foo=bar1122334455"
    // Key: "DUMMY_SECRET_456"
    // Expected Hash (HMAC-SHA1): "8635bb555e82de08b0a8ce7804df8fa9d3796f42"
    const expected_hash = "8635bb555e82de08b0a8ce7804df8fa9d3796f42";

    var hash_buf: [40]u8 = undefined;
    const headers = buildAuthHeaders(api_key, api_secret, path_and_query, timestamp, &hash_buf);

    try testing.expectEqualStrings(expected_hash, headers[2].value);
}

test "buildAuthHeaders: Turn 21 failed run values" {
    const testing = std.testing;

    const api_key = "DD91EFCBDB293F3B";
    const api_secret = "A22BFECB924B4237";
    const path_and_query = "/api/v1/isos";
    const timestamp = "1772870327";
    // Python says this should be: 1d926cbc771b814d1f36a234fd966d62db6cd03c
    const expected_hash = "1d926cbc771b814d1f36a234fd966d62db6cd03c";

    var hash_buf: [40]u8 = undefined;
    const headers = buildAuthHeaders(api_key, api_secret, path_and_query, timestamp, &hash_buf);

    try testing.expectEqualStrings(expected_hash, headers[2].value);
}
