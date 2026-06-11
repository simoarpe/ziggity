# std.base64

Base64 encoding/decoding per RFC 4648.

## Quick Reference

| Codec | Use Case |
|-------|----------|
| `standard` | Standard Base64 with `=` padding (email, MIME) |
| `standard_no_pad` | Standard Base64 without padding |
| `url_safe` | URL-safe Base64 with `=` padding |
| `url_safe_no_pad` | URL-safe Base64 without padding (JWT, URLs) |

## Encoding

```zig
const std = @import("std");
const base64 = std.base64;

const data = "Hello, World!";

// Standard Base64 (with padding)
var buf: [100]u8 = undefined;
const encoded = base64.standard.Encoder.encode(&buf, data);
// "SGVsbG8sIFdvcmxkIQ=="

// URL-safe without padding (common for JWTs)
const encoded = base64.url_safe_no_pad.Encoder.encode(&buf, data);
// "SGVsbG8sIFdvcmxkIQ"

// Calculate required buffer size
const size = base64.standard.Encoder.calcSize(data.len);
```

## Decoding

```zig
const encoded = "SGVsbG8sIFdvcmxkIQ==";

// Decode to buffer
var buf: [100]u8 = undefined;
const decoded_len = try base64.standard.Decoder.calcSizeForSlice(encoded);
const decoded = buf[0..decoded_len];
try base64.standard.Decoder.decode(decoded, encoded);
// decoded = "Hello, World!"

// Calculate max decoded size (before knowing padding)
const max_size = try base64.standard.Decoder.calcSizeUpperBound(encoded.len);
```

## Decoding with Ignored Characters

Decode Base64 that contains whitespace or other characters to ignore:

```zig
const encoded = "SGVs bG8s\nIFdv cmxk IQ==";  // with spaces and newlines

// Create decoder that ignores whitespace
const decoder = base64.standard.decoderWithIgnore(" \n");

var buf: [100]u8 = undefined;
const max_size = try decoder.calcSizeUpperBound(encoded.len);
const decoded_len = try decoder.decode(buf[0..max_size], encoded);
const decoded = buf[0..decoded_len];
// "Hello, World!"
```

## Streaming Encoding

```zig
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);

try base64.standard.Encoder.encodeWriter(&writer.interface, data);
try writer.interface.flush();
```

## Codecs Detail

```zig
// Standard alphabet: A-Z, a-z, 0-9, +, /
base64.standard            // with = padding
base64.standard_no_pad     // without padding

// URL-safe alphabet: A-Z, a-z, 0-9, -, _
base64.url_safe            // with = padding
base64.url_safe_no_pad     // without padding

// Access alphabet characters directly
base64.standard_alphabet_chars  // [64]u8
base64.url_safe_alphabet_chars  // [64]u8
```

## Error Handling

```zig
base64.standard.Decoder.decode(dest, source) catch |err| switch (err) {
    error.InvalidCharacter => // character not in alphabet
    error.InvalidPadding => // incorrect padding
    error.NoSpaceLeft => // dest buffer too small (DecoderWithIgnore only)
};
```

## Common Patterns

### Encode binary data for JSON/URLs
```zig
fn encodeForUrl(data: []const u8, buf: []u8) []const u8 {
    return std.base64.url_safe_no_pad.Encoder.encode(buf, data);
}
```

### Decode JWT payload
```zig
fn decodeJwtPayload(payload: []const u8, buf: []u8) ![]u8 {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const size = try decoder.calcSizeForSlice(payload);
    try decoder.decode(buf[0..size], payload);
    return buf[0..size];
}
```

### Handle multi-line Base64 (PEM format)
```zig
fn decodePem(pem_data: []const u8, buf: []u8) ![]u8 {
    // Skip header/footer, decode with newline ignoring
    const decoder = std.base64.standard.decoderWithIgnore("\n\r");
    const max = try decoder.calcSizeUpperBound(pem_data.len);
    const len = try decoder.decode(buf[0..max], pem_data);
    return buf[0..len];
}
```

## Notes

- Standard uses `+` and `/` which need URL encoding
- URL-safe uses `-` and `_` which are safe in URLs
- Padding (`=`) makes length divisible by 4
- `calcSizeForSlice` gives exact size; `calcSizeUpperBound` gives max (ignores padding)
- All codecs use little-endian byte order internally
