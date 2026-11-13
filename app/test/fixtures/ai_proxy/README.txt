Public test-only TLS material for ai-proxy-test.invalid.

These files were generated locally for the HTTP CONNECT regression test.
The private key is intentionally public and has no use outside this test.
No fixture is included in Flutter assets or application packages.

The CA expires in November 2036. The leaf expires in November 2027.
Keep leaf validity within 398 days for macOS trust evaluation. To renew,
generate a new local test CA and server key, sign a leaf with SAN
DNS:ai-proxy-test.invalid, CA:FALSE, digitalSignature/keyEncipherment and
serverAuth, then replace the three .pem.txt files. Never use real credentials.
