# std.crypto - Cryptography Library

Comprehensive cryptographic primitives: hashing, encryption, signatures, key exchange, password hashing, and secure utilities.

## Quick Reference

| Category | Types/Functions |
|----------|-----------------|
| **Hash** | `hash.sha2.Sha256`, `hash.sha2.Sha512`, `hash.sha3.*`, `hash.Blake3`, `hash.blake2.*`, `hash.Md5`, `hash.Sha1` |
| **AEAD** | `aead.aes_gcm.Aes256Gcm`, `aead.chacha_poly.ChaCha20Poly1305`, `aead.aegis.*` |
| **MAC** | `auth.hmac.*`, `auth.siphash.*`, `auth.cmac.*` |
| **Signatures** | `sign.Ed25519`, `sign.ecdsa.*` |
| **Key Exchange** | `dh.X25519` |
| **KEM** | `kem.ml_kem.*` (post-quantum) |
| **Password** | `pwhash.argon2`, `pwhash.scrypt`, `pwhash.bcrypt`, `pwhash.pbkdf2` |
| **KDF** | `kdf.hkdf.HkdfSha256`, `kdf.hkdf.HkdfSha512` |
| **Random** | `random` (thread-local CSPRNG) |
| **Utilities** | `secureZero`, `timing_safe.*`, `codecs.*` |

## Choosing Algorithms

```
Need encryption?
├─ With authentication → AEAD (Aes256Gcm, ChaCha20Poly1305)
└─ Stream only → stream.chacha.* (usually want AEAD instead)

Need hashing?
├─ General purpose → Sha256, Sha512, Blake3
├─ Password storage → argon2, scrypt, bcrypt
└─ Legacy compatibility → Md5, Sha1 (NOT secure for new designs)

Need signatures?
├─ Standard choice → Ed25519
└─ ECDSA compatibility → ecdsa.EcdsaP256Sha256

Need key exchange?
├─ Standard choice → X25519
└─ Post-quantum → ml_kem.* (Kyber)

Need MAC?
├─ With key → HmacSha256, HmacSha512
└─ Hash table keying → siphash
```

## Hashing

### SHA-2 Family

```zig
const std = @import("std");
const sha2 = std.crypto.hash.sha2;

// One-shot hashing
var digest: [sha2.Sha256.digest_length]u8 = undefined;
sha2.Sha256.hash("hello world", &digest, .{});

// Streaming (incremental)
var hasher = sha2.Sha256.init(.{});
hasher.update("hello ");
hasher.update("world");
hasher.final(&digest);

// Peek at intermediate digest without consuming state
const intermediate = hasher.peek();
```

Available: `Sha224`, `Sha256`, `Sha384`, `Sha512`, `Sha512_224`, `Sha512_256`

### SHA-3 Family

```zig
const sha3 = std.crypto.hash.sha3;

var digest: [sha3.Sha3_256.digest_length]u8 = undefined;
sha3.Sha3_256.hash("data", &digest, .{});

// SHAKE (extendable output)
var shake = sha3.Shake128.init(.{});
shake.update("data");
var output: [64]u8 = undefined;
shake.squeeze(&output);
```

Available: `Sha3_224`, `Sha3_256`, `Sha3_384`, `Sha3_512`, `Shake128`, `Shake256`, `Keccak256`, `Keccak512`

### Blake3

```zig
const Blake3 = std.crypto.hash.Blake3;

// Standard hashing
var digest: [Blake3.digest_length]u8 = undefined;
Blake3.hash("data", &digest, .{});

// Keyed hashing (MAC)
var keyed: [Blake3.digest_length]u8 = undefined;
Blake3.hash("data", &keyed, .{ .key = key });

// Key derivation
var derived: [32]u8 = undefined;
Blake3.hash("material", &derived, .{ .context = "my app v1 key derivation" });
```

### Blake2

```zig
const blake2 = std.crypto.hash.blake2;

// Blake2b (64-byte output)
var digest: [blake2.Blake2b256.digest_length]u8 = undefined;
blake2.Blake2b256.hash("data", &digest, .{});

// With key
blake2.Blake2b256.hash("data", &digest, .{ .key = key });
```

Available: `Blake2b128`, `Blake2b256`, `Blake2b384`, `Blake2b512`, `Blake2s128`, `Blake2s224`, `Blake2s256`

## AEAD (Authenticated Encryption)

### AES-GCM

```zig
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

// Encryption
var ciphertext: [plaintext.len]u8 = undefined;
var tag: [Aes256Gcm.tag_length]u8 = undefined;
Aes256Gcm.encrypt(&ciphertext, &tag, plaintext, associated_data, nonce, key);

// Decryption
var decrypted: [ciphertext.len]u8 = undefined;
try Aes256Gcm.decrypt(&decrypted, &ciphertext, tag, associated_data, nonce, key);
// Returns error.AuthenticationFailed if tag doesn't verify
```

Key constants:
- `key_length`: 32 bytes (256 bits)
- `nonce_length`: 12 bytes
- `tag_length`: 16 bytes

### ChaCha20-Poly1305

```zig
const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

var ciphertext: [msg.len]u8 = undefined;
var tag: [ChaCha20Poly1305.tag_length]u8 = undefined;

ChaCha20Poly1305.encrypt(&ciphertext, &tag, msg, ad, nonce, key);
try ChaCha20Poly1305.decrypt(&decrypted, &ciphertext, tag, ad, nonce, key);
```

Key constants:
- `key_length`: 32 bytes
- `nonce_length`: 12 bytes (IETF) or 24 bytes (XChaCha)
- `tag_length`: 16 bytes

Available variants:
- `ChaCha20Poly1305` - Standard IETF
- `XChaCha20Poly1305` - Extended nonce (24 bytes, better for random nonces)
- `ChaCha12Poly1305`, `ChaCha8Poly1305` - Reduced rounds (faster, lower security margin)

### AEGIS

High-performance AEAD designed for modern CPUs with AES-NI:

```zig
const Aegis256 = std.crypto.aead.aegis.Aegis256;

var ciphertext: [msg.len]u8 = undefined;
var tag: [Aegis256.tag_length]u8 = undefined;

Aegis256.encrypt(&ciphertext, &tag, msg, ad, nonce, key);
try Aegis256.decrypt(&decrypted, &ciphertext, tag, ad, nonce, key);
```

## Message Authentication (MAC)

### HMAC

```zig
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

// One-shot
var mac: [HmacSha256.mac_length]u8 = undefined;
HmacSha256.create(&mac, message, key);

// Streaming
var hmac = HmacSha256.init(key);
hmac.update(data1);
hmac.update(data2);
hmac.final(&mac);
```

Available: `HmacMd5`, `HmacSha1`, `HmacSha224`, `HmacSha256`, `HmacSha384`, `HmacSha512`

### SipHash

Fast MAC for hash table keying (not for general authentication):

```zig
const SipHash = std.crypto.auth.siphash.SipHash64(2, 4);

const hash = SipHash.hash(key, data);
```

## Digital Signatures

### Ed25519

```zig
const Ed25519 = std.crypto.sign.Ed25519;

// Generate key pair
const kp = Ed25519.KeyPair.generate();

// Sign message
const sig = kp.sign(message, null);

// Verify signature
try kp.public_key.verify(sig, message);
// Returns error.SignatureVerificationFailed on failure

// Incremental signing (large messages)
var signer = try kp.signer(null);
signer.update(chunk1);
signer.update(chunk2);
const sig2 = signer.finalize();
```

Key lengths:
- Secret key: 64 bytes
- Public key: 32 bytes
- Signature: 64 bytes

### ECDSA

```zig
const EcdsaP256Sha256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

// Generate key pair
const kp = EcdsaP256Sha256.KeyPair.generate();

// Sign
const sig = try kp.sign(message, null);

// Verify
try sig.verify(message, kp.public_key);
```

Available: `EcdsaP256Sha256`, `EcdsaP256Sha3_256`, `EcdsaP384Sha384`, `EcdsaP384Sha3_384`, `EcdsaSecp256k1Sha256`

## Key Exchange

### X25519 (Diffie-Hellman)

```zig
const X25519 = std.crypto.dh.X25519;

// Generate key pairs for Alice and Bob
const alice = X25519.KeyPair.generate();
const bob = X25519.KeyPair.generate();

// Compute shared secret
const alice_shared = try X25519.scalarmult(alice.secret_key, bob.public_key);
const bob_shared = try X25519.scalarmult(bob.secret_key, alice.public_key);
// alice_shared == bob_shared

// IMPORTANT: Hash the shared secret before use
var key: [32]u8 = undefined;
std.crypto.hash.sha2.Sha256.hash(&alice_shared, &key, .{});
```

### ML-KEM (Post-Quantum)

```zig
const MlKem768 = std.crypto.kem.ml_kem.MlKem768;

// Key generation
const kp = MlKem768.KeyPair.generate();

// Encapsulation (sender)
const encaps = kp.public_key.encaps(null);
const shared_secret = encaps.shared_secret;
const ciphertext = encaps.ciphertext;

// Decapsulation (receiver)
const decaps_secret = try kp.secret_key.decaps(ciphertext);
// shared_secret == decaps_secret
```

Available: `MlKem512`, `MlKem768`, `MlKem1024`

## Key Derivation

### HKDF

```zig
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;

// Extract: derive pseudorandom key from input keying material
const prk = HkdfSha256.extract(salt, input_key_material);

// Expand: derive output key from PRK
var output_key: [32]u8 = undefined;
HkdfSha256.expand(&output_key, context_info, prk);

// Streaming extract (large IKM)
var hkdf = HkdfSha256.extractInit(salt);
hkdf.update(ikm_part1);
hkdf.update(ikm_part2);
var prk2: [HkdfSha256.prk_length]u8 = undefined;
hkdf.final(&prk2);
```

## Password Hashing

### Argon2

Memory-hard password hashing (recommended for new applications):

```zig
const argon2 = std.crypto.pwhash.argon2;

// Hash password
var hash: [32]u8 = undefined;
try argon2.kdf(
    allocator,
    &hash,
    password,
    salt,
    .{
        .t = 3,      // time cost (iterations)
        .m = 65536,  // memory cost (KiB)
        .p = 4,      // parallelism
    },
    .argon2id,  // mode: argon2i, argon2d, or argon2id
);

// Use preset parameters
try argon2.kdf(allocator, &hash, password, salt, argon2.Params.interactive_2id, .argon2id);

// PHC string format (for storage)
var buf: [128]u8 = undefined;
const encoded = try argon2.strHash(password, salt, .interactive_2id, .argon2id, &buf);
// Returns: "$argon2id$v=19$m=65536,t=3,p=4$..."

// Verify PHC-encoded hash
try argon2.strVerify(encoded, password, null);
```

Parameter presets:
- `interactive_2id`: Fast verification (login forms)
- `moderate_2id`: Balanced
- `sensitive_2id`: High security (key derivation)
- `owasp_2id`: OWASP recommended

### Scrypt

Memory-hard KDF:

```zig
const scrypt = std.crypto.pwhash.scrypt;

var hash: [32]u8 = undefined;
try scrypt.kdf(
    allocator,
    &hash,
    password,
    salt,
    .{ .ln = 17, .r = 8, .p = 1 },  // N=2^17, r=8, p=1
);

// Presets
try scrypt.kdf(allocator, &hash, password, salt, scrypt.Params.interactive);
```

### bcrypt

```zig
const bcrypt = std.crypto.pwhash.bcrypt;

// Hash password
var hash: [bcrypt.hash_length]u8 = undefined;
try bcrypt.strHash(password, .{ .rounds = 10 }, &hash);

// Verify
try bcrypt.strVerify(hash_str, password);
```

### PBKDF2

```zig
const pbkdf2 = std.crypto.pwhash.pbkdf2;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

var key: [32]u8 = undefined;
pbkdf2(HmacSha256, &key, password, salt, 100000);  // 100k iterations
```

## Secure Random

Thread-local cryptographically secure PRNG:

```zig
const random = std.crypto.random;

// Random bytes
var key: [32]u8 = undefined;
random.bytes(&key);

// Random integers
const n = random.int(u64);
const bounded = random.intRangeLessThan(u32, 0, 100);  // [0, 100)

// Random float [0, 1)
const f = random.float(f64);

// Shuffle
random.shuffle(u32, &items);
```

## Secure Utilities

### secureZero

Securely erase sensitive data (prevents optimizer from removing):

```zig
var secret: [32]u8 = undefined;
// ... use secret ...
std.crypto.secureZero(u8, &secret);  // guaranteed to zero
```

### Timing-Safe Operations

```zig
const timing_safe = std.crypto.timing_safe;

// Constant-time equality (for MACs, signatures)
const equal = timing_safe.eql([32]u8, mac1, mac2);

// Constant-time comparison
const order = timing_safe.compare(u8, &a, &b, .big);  // .lt, .eq, .gt

// Constant-time arithmetic
const overflow = timing_safe.add(u8, &a, &b, &result, .big);
const underflow = timing_safe.sub(u8, &a, &b, &result, .big);
```

### Codecs (Constant-Time)

```zig
const codecs = std.crypto.codecs;

// Hex encoding (constant-time)
var hex: [64]u8 = undefined;
try codecs.hex.encode(&hex, &binary, .lower);

// Hex decoding
var decoded: [32]u8 = undefined;
try codecs.hex.decode(&decoded, &hex);

// Base64
const base64 = codecs.base64;
// Similar API to hex
```

## Elliptic Curve Primitives

Low-level curve operations (usually use higher-level APIs):

```zig
const ecc = std.crypto.ecc;

// Edwards25519
const point = ecc.Edwards25519.basePoint;
const result = try point.mul(scalar);

// P-256 (NIST)
const p256_point = ecc.P256.basePoint;

// Ristretto255 (prime-order group)
const ristretto = ecc.Ristretto255.basePoint;
```

Available: `Curve25519`, `Edwards25519`, `Ristretto255`, `P256`, `P384`, `Secp256k1`

## Error Handling

```zig
const errors = std.crypto.errors;

// Common errors
error.AuthenticationFailed    // MAC/tag verification failed
error.SignatureVerificationFailed
error.IdentityElement         // Degenerate point in ECC
error.NonCanonical           // Input not in canonical form
error.InvalidEncoding        // Malformed input
error.WeakPublicKey          // Unsafe public key
error.PasswordVerificationFailed
```

## Common Patterns

### Encrypt-then-MAC

```zig
// Use AEAD instead - it handles this correctly
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
Aes256Gcm.encrypt(&ct, &tag, pt, ad, nonce, key);
```

### Key Generation

```zig
// For symmetric keys
var key: [32]u8 = undefined;
std.crypto.random.bytes(&key);

// For asymmetric keys
const kp = std.crypto.sign.Ed25519.KeyPair.generate();
```

### Nonce Management

```zig
// Option 1: Counter (deterministic, never reuse)
var nonce: [12]u8 = undefined;
std.mem.writeInt(u64, nonce[0..8], counter, .big);
@memset(nonce[8..], 0);
counter += 1;

// Option 2: Random (safe with XChaCha's 24-byte nonce)
const XChaCha = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
var nonce: [XChaCha.nonce_length]u8 = undefined;
std.crypto.random.bytes(&nonce);
```

### Secure Password Storage

```zig
const argon2 = std.crypto.pwhash.argon2;

// Registration: hash and store
var buf: [128]u8 = undefined;
const hash_str = try argon2.strHash(password, null, .interactive_2id, .argon2id, &buf);
// Store hash_str in database

// Login: verify
argon2.strVerify(stored_hash, password, null) catch |err| {
    if (err == error.PasswordVerificationFailed) {
        // Invalid password
    }
};
```

## Side-Channel Protection

Configure side-channel mitigations:

```zig
const SideChannelsMitigations = std.crypto.SideChannelsMitigations;

// Available levels:
// .none    - Fastest, no mitigations
// .basic   - Protects against most practical attacks
// .medium  - Default, good balance (increased resistance)
// .full    - Highest protection, significant performance impact

// Default is .medium
const default = std.crypto.default_side_channels_mitigations;
```

## Notes

- **Never use MD5 or SHA1 for security** - only for legacy compatibility
- **AEAD over separate encrypt+MAC** - AES-GCM or ChaCha20-Poly1305 handle this correctly
- **Hash shared secrets** - X25519 output should be passed through a KDF before use
- **Use argon2id for passwords** - it's the current best practice
- **XChaCha for random nonces** - 24-byte nonce has negligible collision probability
- **Timing attacks** - use `timing_safe.eql` for comparing secrets, not `==` or `std.mem.eql`
- **Zero secrets** - always `secureZero` sensitive data when done
