Shared index chunk cache — isolated branch codex/index-cache-budget

Production wiring is in dictionary-bridge. Its process-owned pool is shared
across all MDX readers: 64 MiB desktop, 8 MiB Android/iOS. No Dart API or stored
index format changes. KeyIndexOptions without a pool retains the legacy policy.
The cache budget includes Vec capacities plus conservative pool bookkeeping,
and evicted blocks still leased by a reader. It does not bound total app RSS.
Buffers, queries, source key/record caches and WebView memory are separate.

Pool locks are released before file reads. Checksums run before admission.
Each opened index has a fresh cache owner; closing the index purges its blocks.
Cached bytes cannot leak between reopened indexes, different paths, or policies.
If the source parser memory limit cannot admit a chunk, its retained index
chunks are dropped before retrying the original bounded read.

Tests:
  cargo fmt --all -- --check
  cargo test --release --locked --offline -p mdictlib
  cargo test --release --locked --offline --workspace

The original persistent-index tests run with both legacy and shared policies.
Two fixed single-buffer memory expectations now account for lazy shared reads;
the exact returned-page memory assertion is preserved after warming the cache.
Three pre-existing Windows URL fixture failures were reproduced on main.
Only the test-generated URL slashes were corrected; the URL decoder is intact.

Benchmark:
  cargo build --release --locked --offline -p dictionary-core --example index_cache_benchmark
  python benchmarks/index-cache-budget/run.py --corpus <previous manifest.json> --history <previous history.txt>

The manifest reuses the previous experiment's absolute dictionary/index paths
and the fixed 300-query files per dictionary. Run three alternating trials.
Raw paths, query sequences and individual logs remain under ignored target/.
Delivered TSV files contain only dictionary labels, timings and cache counters.
No cached article contents or credentials are exported.

The benchmark uses a single Release binary with either the unchanged legacy
single-section-chunk policy or the actual shared pool, without timing probes
inside production code. It also checks the 8 MiB pool and full sampled-output
digests. Pool peak usage is checked against its hard ceiling on every run.
Windows file caching is not cleared. Core timings exclude the GUI and bridge.

Results: results-20261014/report.txt, summary.tsv, measurements.tsv,
cache-usage.tsv and verification.tsv. No merge, deployment or release publish.

Additional source guard: retained chunk payload for any index is capped at
one eighth of the source parser's available working-memory headroom at open.
This is an upper bound, not an eager reservation. Tight custom source limits
therefore leave most of their headroom for key and record decoding.

Index/read/decode probe columns in measurements.tsv are zero because internal
timing probes are disabled in this production-code benchmark. They do not
mean that no I/O occurred. Pool hit/miss/eviction/peak figures are recorded
separately in cache-usage.tsv through the public cache snapshot API.
