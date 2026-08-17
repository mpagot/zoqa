// Fuzz harness for the INI config parser and host resolver
// (src/config.zig: findCredentialsWith → parseIni, resolveHost).
//
// ---------------------------------------------------------------------------
// Corpus format
// ---------------------------------------------------------------------------
//
// Two sections separated by the literal line "---":
//
//   <flags_byte><hostname>
//   ---
//   <ini_content>
//
// Section 1: first byte encodes boolean flags as a bitmask:
//   bit 0 (0x01): flag_osd  → resolves to "http://openqa.suse.de"
//   bit 1 (0x02): flag_o3   → resolves to "https://openqa.opensuse.org"
//   bit 2 (0x04): flag_odn  → resolves to "https://openqa.debian.net"
//   remaining bytes: hostname string passed to resolveHost as host_arg
//
// Section 2: INI content exercised through the full findCredentials path.
//   A custom in-memory ReadFileFn returns the INI content directly,
//   avoiding filesystem I/O in the AFL++ persistent-mode hot loop.
//
// If no "---" separator is found, the entire input is used as INI content
// with an empty hostname (exercises the null host_arg / localhost-default branch).
//
// If section 1 has only the flags byte (no hostname bytes), host_arg is null
// (exercises the localhost-default branch when no flags match).
//
// ---------------------------------------------------------------------------
// resolveHost branches covered
// ---------------------------------------------------------------------------
//
//   1. flag_osd=true         → "http://openqa.suse.de"
//   2. flag_o3=true          → "https://openqa.opensuse.org"
//   3. flag_odn=true         → "https://openqa.debian.net"
//   4. host contains "://"   → passthrough (no allocation)
//   5. host starts with "/"  → passthrough (no allocation)
//   6. host is bare hostname → allocates "https://{hostname}"
//   7. host_arg = null       → "http://localhost"
//
const std = @import("std");
const config = @import("zoqa").config;

// ---------------------------------------------------------------------------
// In-memory ReadFileFn for findCredentialsWith
// ---------------------------------------------------------------------------
//
// The fuzz input's INI content is stored in a global slice (set per
// iteration in zig_fuzz_test). The readFile function returns a copy
// of it for any path, simulating a filesystem where every config file
// has the same fuzzed content. This exercises the parseIni code path
// at full speed without disk I/O.

var fuzz_ini_content: []const u8 = "";

fn readFileFromFuzzInput(allocator: std.mem.Allocator, _: []const u8) anyerror![]u8 {
    const copy = try allocator.alloc(u8, fuzz_ini_content.len);
    @memcpy(copy, fuzz_ini_content);
    return copy;
}

pub export fn zig_fuzz_init() void {}

pub export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    const input = buf[0..@intCast(len)];

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Split on first occurrence of "\n---\n" separator.
    const sep = "\n---\n";
    const split_pos = std.mem.indexOf(u8, input, sep);

    const header_section: []const u8 = if (split_pos) |p| input[0..p] else "";
    const ini_content: []const u8 = if (split_pos) |p| input[p + sep.len ..] else input;

    // Decode header_section: first byte = flags bitmask, rest = hostname.
    const flag_osd = header_section.len > 0 and (header_section[0] & 0x01) != 0;
    const flag_o3 = header_section.len > 0 and (header_section[0] & 0x02) != 0;
    const flag_odn = header_section.len > 0 and (header_section[0] & 0x04) != 0;
    const hostname_bytes: []const u8 = if (header_section.len > 1) header_section[1..] else "";
    const host_arg: ?[]const u8 = if (hostname_bytes.len > 0) hostname_bytes else null;

    // ---------------------------------------------------------------------------
    // Target 1: resolveHost — exercises all 7 branches
    // ---------------------------------------------------------------------------
    if (config.resolveHost(allocator, flag_osd, flag_o3, flag_odn, host_arg)) |host_res| {
        if (host_res.allocated) allocator.free(host_res.url);
    } else |_| {}

    // ---------------------------------------------------------------------------
    // Target 2: findCredentialsWith — exercises the full credential lookup
    //           pipeline: path construction → file reading (mocked) → parseIni
    //           → section matching → key/value extraction → Credentials.
    //
    // Uses an in-memory ReadFileFn that returns the fuzz INI content for any
    // path, keeping the persistent-mode loop free of filesystem I/O.
    //
    // When host_arg is null, use "localhost" as the lookup hostname so the
    // section-matching logic is still exercised.
    // ---------------------------------------------------------------------------
    const lookup_host = host_arg orelse "localhost";
    fuzz_ini_content = ini_content;

    if (config.findCredentialsWith(
        allocator,
        lookup_host,
        "/fuzz/config", // non-null so the OPENQA_CONFIG search path is exercised
        "/fuzz/home", // non-null so the HOME search path is exercised
        readFileFromFuzzInput,
    )) |creds_opt| {
        if (creds_opt) |creds| {
            creds.deinit();
        }
    } else |_| {}
}
