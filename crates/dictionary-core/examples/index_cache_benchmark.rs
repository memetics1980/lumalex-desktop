//! Local isolated benchmark; stdout is TSV, diagnostics go to stderr.
use dictionary_core::{DictionaryId, DictionarySource, MdictDictionary};
use mdictlib::{KeyIndexOptions, KeyOrdinal, MdxFile};
use std::{
    env, fs,
    hint::black_box,
    path::{Path, PathBuf},
    time::Instant,
};
type R<T> = Result<T, Box<dyn std::error::Error>>;

fn dist(id: &str, mode: &str, samples: &mut [f64], hits: usize, sums: u64) {
    samples.sort_by(f64::total_cmp);
    let n = samples.len();
    let p = profile::snapshot();
    let quantile = |q: f64| samples[((n - 1) as f64 * q).ceil() as usize];
    println!("{id}\t{mode}\t{n}\t{hits}\t{:.3}\t{:.3}\t{:.3}\t{:.3}\t{}\t{}\t{:.3}\t{}\t{}\t{:.3}\t{}\t{:.3}\t{}\t{:.3}\t{}\t{}\t{sums}",
        samples.iter().sum::<f64>() / n as f64, quantile(0.5), quantile(0.95), quantile(1.),
        p[0],p[1],p[2] as f64/1e6,p[3],p[4],p[5] as f64/1e6,p[6],p[7] as f64/1e6,p[8],p[9] as f64/1e6,p[10],p[11]);
}
fn measured<F>(id: &str, mode: &str, n: usize, mut f: F) -> R<()>
where
    F: FnMut(usize) -> R<(bool, u64)>,
{
    profile::reset();
    let mut samples = Vec::with_capacity(n);
    let mut hits = 0;
    let mut sums = 0;
    for i in 0..n {
        let t = Instant::now();
        let (hit, sum) = f(i)?;
        samples.push(t.elapsed().as_secs_f64() * 1e6);
        hits += usize::from(hit);
        sums += sum;
    }
    dist(id, mode, &mut samples, hits, sums);
    Ok(())
}
fn source(path: &Path) -> R<DictionarySource> {
    Ok(DictionarySource::new(
        DictionaryId::new("benchmark")?,
        path.to_path_buf(),
        None,
    )?)
}
fn run_one(id: &str, path: &Path, index_path: &Path, queries_path: &Path, build: bool) -> R<()> {
    eprintln!("start {id} cache_chunks={}", profile::capacity());
    profile::reset();
    let t = Instant::now();
    let mdx = MdxFile::open(path)?;
    let open_us = t.elapsed().as_secs_f64() * 1e6;
    dist(id, "mdx_open", &mut [open_us], 1, mdx.len());
    let options = key_index_options();
    let identity = mdx.key_index_source_identity()?;
    if build {
        measured(id, "index_build", 1, |_| {
            let report = mdx.build_key_index_to_path(index_path, &options, || false)?;
            Ok((true, report.bytes_written()))
        })?;
    }
    let mut pairs: Vec<(u64, String)> = Vec::new();
    if queries_path.exists() {
        for line in fs::read_to_string(queries_path)?.lines() {
            let (o, q) = line.split_once('\t').ok_or("invalid query file")?;
            pairs.push((o.parse()?, q.to_owned()));
        }
    } else {
        let mut seed = 20261014u64;
        for _ in 0..300 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
            let ordinal = (seed >> 16) % mdx.len();
            if let Some(key) = mdx.key_at(KeyOrdinal::new(ordinal))? {
                if !key.key().contains(['\t', '\n', '\r']) && !key.key().trim().is_empty() {
                    pairs.push((ordinal, key.key().to_owned()));
                }
            }
        }
        fs::write(
            queries_path,
            pairs
                .iter()
                .map(|(o, q)| format!("{o}\t{q}\n"))
                .collect::<String>(),
        )?;
    }
    if pairs.is_empty() {
        return Err("no queries".into());
    }
    drop(mdx);
    let mdx = MdxFile::open(path)?;
    let mut idx = None;
    measured(id, "index_open", 1, |_| {
        idx = Some(mdx.open_key_index(index_path, &identity, &options)?);
        Ok((true, mdx.len()))
    })?;
    let idx = idx.unwrap();
    let query = &pairs[0].1;
    measured(id, "reader_first_full", 1, |_| {
        let m = mdx.locate_with_key_index(&idx, query)?;
        if let Some(m) = m {
            let e = mdx.entry_at(m.first())?.ok_or("missing entry")?;
            Ok((true, black_box(e.text().len() as u64)))
        } else {
            Ok((false, 0))
        }
    })?;
    measured(id, "random_locate", pairs.len(), |i| {
        let m = mdx.locate_with_key_index(&idx, &pairs[i].1)?;
        Ok((m.is_some(), m.map_or(0, |m| m.first().get() + 1)))
    })?;
    // Fresh reader isolates source-block decompression/materialization from index search.
    let payload = MdxFile::open(path)?;
    measured(id, "random_payload", pairs.len(), |i| {
        let e = payload.entry_at(KeyOrdinal::new(pairs[i].0))?;
        Ok((
            e.is_some(),
            e.map_or(0, |e| black_box(e.text().len() as u64)),
        ))
    })?;
    measured(id, "random_full", pairs.len(), |i| {
        let m = mdx.locate_with_key_index(&idx, &pairs[i].1)?;
        if let Some(m) = m {
            let e = mdx.entry_at(m.first())?.ok_or("missing entry")?;
            Ok((true, black_box(e.text().len() as u64)))
        } else {
            Ok((false, 0))
        }
    })?;
    measured(id, "repeat_full", 200, |_| {
        let m = mdx
            .locate_with_key_index(&idx, query)?
            .ok_or("missing repeat")?;
        let e = mdx.entry_at(m.first())?.ok_or("missing entry")?;
        Ok((true, black_box(e.text().len() as u64)))
    })?;
    measured(id, "miss_locate", 100, |i| {
        let m = mdx.locate_with_key_index(&idx, &format!("zzzz__lumalex_absent_{i}_20261014"))?;
        Ok((m.is_some(), 0))
    })?;
    measured(id, "prefix20", 100, |i| {
        let prefix: String = pairs[i % pairs.len()].1.chars().take(3).collect();
        let keys = mdx.prefix_keys_with_index(&idx, &prefix, 20)?;
        Ok((!keys.is_empty(), black_box(keys.len() as u64)))
    })?;
    let u = mdx.memory_usage()?;
    eprintln!(
        "memory {id} current={} peak={} locator={} key={} record={}",
        u.current_bytes(),
        u.peak_bytes(),
        u.locator_bytes(),
        u.key_cache_bytes(),
        u.record_cache_bytes()
    );
    let core = MdictDictionary::open_with_key_index_options(
        source(path)?,
        index_path.to_path_buf(),
        key_index_options(),
    )?;
    measured(id, "app_lookup_first", pairs.len(), |i| {
        let e = core.lookup_first(&pairs[i].1)?;
        Ok((e.is_some(), e.map_or(0, |e| black_box(e.html.len() as u64))))
    })?;
    let fallback = MdictDictionary::open(source(path)?)?;
    measured(id, "no_index_first_hit", 1, |_| {
        let e = fallback.lookup_first(query)?;
        Ok((e.is_some(), e.map_or(0, |e| black_box(e.html.len() as u64))))
    })?;
    let fallback = MdictDictionary::open(source(path)?)?;
    measured(id, "no_index_first_miss", 1, |_| {
        let e = fallback.lookup_first("zzzz__lumalex_absent_20261014")?;
        Ok((e.is_some(), 0))
    })?;
    measured(id, "no_index_warm_miss", 100, |_| {
        let e = fallback.lookup_first("zzzz__lumalex_absent_20261014")?;
        Ok((e.is_some(), 0))
    })?;
    Ok(())
}
fn memory(id: &str, path: &Path, queries: &Path) -> R<()> {
    let pairs: Vec<(u64, String)> = fs::read_to_string(queries)?
        .lines()
        .map(|line| {
            let (o, q) = line.split_once('\t').unwrap();
            (o.parse().unwrap(), q.to_owned())
        })
        .collect();
    let d = MdxFile::open(path)?;
    measured(id, "memory_locator_build", 1, |_| {
        let m = d.locate("zzzz__lumalex_absent_20261014")?;
        Ok((m.is_some(), 0))
    })?;
    measured(id, "memory_random_locate", pairs.len(), |i| {
        let m = d.locate(&pairs[i].1)?;
        Ok((m.is_some(), m.map_or(0, |m| m.first().get() + 1)))
    })?;
    measured(id, "memory_random_full", pairs.len(), |i| {
        let m = d.locate(&pairs[i].1)?;
        if let Some(m) = m {
            let e = d.entry_at(m.first())?.ok_or("missing")?;
            Ok((true, e.text().len() as u64))
        } else {
            Ok((false, 0))
        }
    })?;
    let u = d.memory_usage()?;
    eprintln!(
        "memory {id} current={} peak={} locator={} key={} record={}",
        u.current_bytes(),
        u.peak_bytes(),
        u.locator_bytes(),
        u.key_cache_bytes(),
        u.record_cache_bytes()
    );
    Ok(())
}
fn hash(h: &mut u64, bytes: &[u8]) {
    for b in bytes {
        *h = (*h ^ u64::from(*b)).wrapping_mul(0x100000001b3);
    }
    *h = (*h ^ 255).wrapping_mul(0x100000001b3);
}
fn verify(id: &str, path: &Path, index_path: &Path, queries: &Path) -> R<()> {
    let d = MdxFile::open(path)?;
    let identity = d.key_index_source_identity()?;
    let idx = d.open_key_index(index_path, &identity, &key_index_options())?;
    let core = MdictDictionary::open_with_key_index_options(
        source(path)?,
        index_path.to_path_buf(),
        key_index_options(),
    )?;
    let mut h = 0xcbf29ce484222325u64;
    let mut n = 0;
    for line in fs::read_to_string(queries)?.lines() {
        let (_, q) = line.split_once('\t').ok_or("query")?;
        if let Some(m) = d.locate_with_key_index(&idx, q)? {
            for o in m.iter() {
                hash(&mut h, &o.get().to_le_bytes());
            }
            let e = d.entry_at(m.first())?.ok_or("missing")?;
            hash(&mut h, e.key().as_bytes());
            hash(&mut h, e.text().as_bytes());
        }
        let prefix: String = q.chars().take(3).collect();
        for k in d.prefix_keys_with_index(&idx, &prefix, 20)? {
            hash(&mut h, k.key().as_bytes());
            hash(&mut h, &k.ordinal().get().to_le_bytes());
        }
        if let Some(e) = core.lookup_first(q)? {
            hash(&mut h, e.headword.as_bytes());
            hash(&mut h, e.html.as_bytes());
        }
        n += 1;
    }
    println!("verify\t{id}\t{}\t{n}\t{h:016x}", profile::capacity());
    Ok(())
}
fn main() -> R<()> {
    let a: Vec<String> = env::args().collect();
    println!("dictionary\tworkload\tn\thits\tmean_us\tp50_us\tp95_us\tmax_us\tindex_reads\tindex_bytes\tindex_read_ms\tsource_reads\tsource_bytes\tsource_read_ms\tkey_decodes\tkey_decode_ms\trecord_decodes\trecord_decode_ms\tchunk_hits\tchunk_misses\tchecksum");
    if a[1] == "one" {
        run_one(
            &a[2],
            Path::new(&a[3]),
            Path::new(&a[4]),
            Path::new(&a[5]),
            a.get(6).is_some_and(|s| s == "build"),
        )?;
    } else if a[1] == "memory" {
        memory(&a[2], Path::new(&a[3]), Path::new(&a[4]))?;
    } else if a[1] == "verify" {
        verify(&a[2], Path::new(&a[3]), Path::new(&a[4]), Path::new(&a[5]))?;
    } else if a[1] == "group" {
        let manifest = fs::read_to_string(&a[2])?;
        let mut readers = Vec::new();
        for line in manifest.lines() {
            let p: Vec<_> = line.split('\t').collect();
            readers.push(MdictDictionary::open_with_key_index_options(
                source(Path::new(p[1]))?,
                PathBuf::from(p[2]),
                key_index_options(),
            )?);
        }
        let queries: Vec<String> = fs::read_to_string(&a[3])?
            .lines()
            .map(str::to_owned)
            .collect();
        measured("english_group", "group_first", 1, |_| {
            let mut hits = 0;
            let mut bytes = 0;
            for d in &readers {
                if let Some(e) = d.lookup_first(&queries[0])? {
                    hits += 1;
                    bytes += e.html.len() as u64;
                }
            }
            Ok((hits > 0, bytes))
        })?;
        measured("english_group", "group_queries", queries.len(), |i| {
            let mut hits = 0;
            let mut bytes = 0;
            for d in &readers {
                if let Some(e) = d.lookup_first(&queries[i])? {
                    hits += 1;
                    bytes += e.html.len() as u64;
                }
            }
            Ok((hits > 0, bytes))
        })?;
        measured("english_group", "group_repeat", 100, |_| {
            let mut bytes = 0;
            for d in &readers {
                if let Some(e) = d.lookup_first(&queries[0])? {
                    bytes += e.html.len() as u64;
                }
            }
            Ok((bytes > 0, bytes))
        })?;
    } else {
        return Err("use one/group".into());
    }
    if let Some(cache) = shared_pool() {
        eprintln!("shared_cache_usage {:?}", cache.usage()?);
    }
    Ok(())
}

fn shared_pool() -> Option<std::sync::Arc<mdictlib::IndexChunkCache>> {
    static POOL: std::sync::OnceLock<Option<std::sync::Arc<mdictlib::IndexChunkCache>>> =
        std::sync::OnceLock::new();
    POOL.get_or_init(|| {
        let bytes = std::env::var("LUMALEX_INDEX_CACHE_BYTES")
            .ok()
            .and_then(|s| s.parse::<usize>().ok())
            .unwrap_or(64 * 1024 * 1024);
        (bytes != 0).then(|| std::sync::Arc::new(mdictlib::IndexChunkCache::new(bytes)))
    })
    .clone()
}
fn key_index_options() -> KeyIndexOptions {
    match shared_pool() {
        Some(pool) => KeyIndexOptions::new().with_chunk_cache(pool),
        None => KeyIndexOptions::new(),
    }
}
mod profile {
    pub fn reset() {}
    pub fn snapshot() -> [u64; 12] {
        [0; 12]
    }
    pub fn capacity() -> usize {
        if super::shared_pool().is_some() {
            16
        } else {
            1
        }
    }
}
