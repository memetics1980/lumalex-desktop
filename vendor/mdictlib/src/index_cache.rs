//! Optional, application-owned cache shared by independently opened indexes.
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use crate::error::{Error, Result};
use crate::limits::MemoryReservation;

const MAX_ENTRIES: usize = 1024;
const ENTRY_OVERHEAD_BYTES: usize = 1024;
const MAX_SECTION_CHUNKS: usize = 16;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) struct CacheKey {
    pub(crate) owner: u64,
    pub(crate) section: usize,
    pub(crate) chunk: u64,
}

#[derive(Debug)]
struct Accounting {
    maximum: usize,
    resident: AtomicUsize,
    peak: AtomicUsize,
}

impl Accounting {
    fn claim(self: &Arc<Self>, bytes: usize) -> Option<CacheReservation> {
        let mut current = self.resident.load(Ordering::Acquire);
        loop {
            let next = current.checked_add(bytes)?;
            if next > self.maximum {
                return None;
            }
            match self.resident.compare_exchange_weak(
                current,
                next,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => {
                    self.peak.fetch_max(next, Ordering::Relaxed);
                    return Some(CacheReservation {
                        accounting: Arc::clone(self),
                        bytes,
                    });
                }
                Err(observed) => current = observed,
            }
        }
    }
}

#[derive(Debug)]
struct CacheReservation {
    accounting: Arc<Accounting>,
    bytes: usize,
}
impl Drop for CacheReservation {
    fn drop(&mut self) {
        self.accounting
            .resident
            .fetch_sub(self.bytes, Ordering::AcqRel);
    }
}

#[derive(Debug)]
pub(crate) struct CachedChunk {
    pub(crate) bytes: Vec<u8>,
    // Keeps source-dictionary accounting alive until the last in-flight reader
    // releases its lease, even after the pool evicts this chunk.
    _source_memory: MemoryReservation,
    _shared_memory: Option<CacheReservation>,
}

#[derive(Debug)]
struct Entry {
    chunk: Arc<CachedChunk>,
    touched: u64,
}
#[derive(Debug, Default)]
struct State {
    entries: HashMap<CacheKey, Entry>,
    clock: u64,
    hits: u64,
    misses: u64,
    evictions: u64,
    metadata: Option<CacheReservation>,
}
impl State {
    fn tick(&mut self) -> u64 {
        // Cache contents are disposable. Reset on counter exhaustion without
        // allocating a temporary ordering table or wrapping timestamps.
        if self.clock == u64::MAX {
            self.entries.clear();
            self.clock = 0;
        }
        self.clock += 1;
        self.clock
    }
    fn evict(&mut self, owner_section: Option<(u64, usize)>) -> bool {
        let key = self
            .entries
            .iter()
            .filter(|(key, _)| {
                owner_section
                    .is_none_or(|(owner, section)| key.owner == owner && key.section == section)
            })
            .min_by_key(|(_, entry)| entry.touched)
            .map(|(key, _)| *key);
        if let Some(key) = key {
            self.entries.remove(&key);
            self.evictions = self.evictions.saturating_add(1);
            true
        } else {
            false
        }
    }
}

/// Snapshot of the shared index cache's conservative retained-memory budget.
/// This excludes returned article text, parser metadata, source block caches,
/// and transient uncached reads; it is not process RSS.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct IndexChunkCacheUsage {
    /// Configured hard ceiling, including conservatively budgeted bookkeeping.
    pub maximum_bytes: usize,
    /// Retained bytes, including evicted chunks still leased by a reader.
    pub resident_bytes: usize,
    /// Highest retained byte budget observed so far.
    pub peak_bytes: usize,
    /// Number of chunks available for future cache hits.
    pub entries: usize,
    /// Successful chunk lookups.
    pub hits: u64,
    /// Chunk lookups requiring a source read.
    pub misses: u64,
    /// LRU removals made to admit other chunks.
    pub evictions: u64,
}

/// Bounded LRU of validated, uncompressed index-file chunks across dictionaries.
///
/// All indexes opened with the same `Arc` share one hard byte ceiling. At most
/// sixteen chunks are retained for any index section and at most 1024 overall.
/// Payload and conservative bookkeeping are charged lazily. A full budget,
/// cache-table allocation failure, or an oversized chunk causes an uncached read; it never
/// changes matching or checksum policy. Pool locks are not held during I/O.
#[derive(Debug)]
pub struct IndexChunkCache {
    accounting: Arc<Accounting>,
    state: Mutex<State>,
    next_owner: AtomicU64,
    maximum_entries: usize,
}
impl PartialEq for IndexChunkCache {
    fn eq(&self, other: &Self) -> bool {
        std::ptr::eq(self, other)
    }
}
impl Eq for IndexChunkCache {}

impl IndexChunkCache {
    /// Creates an empty shared pool without allocating the byte ceiling.
    /// A zero or very small ceiling simply disables retaining chunks.
    pub fn new(maximum_bytes: usize) -> Self {
        Self {
            accounting: Arc::new(Accounting {
                maximum: maximum_bytes,
                resident: AtomicUsize::new(0),
                peak: AtomicUsize::new(0),
            }),
            state: Mutex::new(State::default()),
            next_owner: AtomicU64::new(1),
            maximum_entries: (maximum_bytes / (ENTRY_OVERHEAD_BYTES * 4)).min(MAX_ENTRIES),
        }
    }
    /// Returns usage and hit/eviction counters without reading dictionary data.
    ///
    /// # Errors
    /// Returns an error if an earlier panic poisoned the pool mutex.
    pub fn usage(&self) -> Result<IndexChunkCacheUsage> {
        let state = self.lock()?;
        Ok(IndexChunkCacheUsage {
            maximum_bytes: self.accounting.maximum,
            resident_bytes: self.accounting.resident.load(Ordering::Acquire),
            peak_bytes: self.accounting.peak.load(Ordering::Relaxed),
            entries: state.entries.len(),
            hits: state.hits,
            misses: state.misses,
            evictions: state.evictions,
        })
    }
    /// Drops retained chunks. In-flight leases and bounded table bookkeeping
    /// remain accounted until they are released or this pool is dropped.
    ///
    /// # Errors
    /// Returns an error if an earlier panic poisoned the pool mutex.
    pub fn clear(&self) -> Result<()> {
        self.lock()?.entries.clear();
        Ok(())
    }
    fn lock(&self) -> Result<std::sync::MutexGuard<'_, State>> {
        self.state
            .lock()
            .map_err(|_| Error::InvalidFormat("shared index chunk cache mutex poisoned"))
    }
    pub(crate) fn owner(self: &Arc<Self>, maximum_source_bytes: usize) -> Result<CacheOwner> {
        let id = self
            .next_owner
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| n.checked_add(1))
            .map_err(|_| Error::InvalidFormat("shared index cache owner identifiers exhausted"))?;
        Ok(CacheOwner {
            cache: Arc::clone(self),
            id,
            maximum_source_bytes,
        })
    }
    pub(crate) fn get(&self, key: CacheKey) -> Result<Option<Arc<CachedChunk>>> {
        let mut state = self.lock()?;
        let age = state.tick();
        if let Some(entry) = state.entries.get_mut(&key) {
            entry.touched = age;
            let chunk = Arc::clone(&entry.chunk);
            state.hits = state.hits.saturating_add(1);
            Ok(Some(chunk))
        } else {
            state.misses = state.misses.saturating_add(1);
            Ok(None)
        }
    }
    pub(crate) fn remove_owner(&self, owner: u64) -> Result<()> {
        self.lock()?.entries.retain(|key, _| key.owner != owner);
        Ok(())
    }
    pub(crate) fn insert(
        &self,
        key: CacheKey,
        bytes: Vec<u8>,
        source_memory: MemoryReservation,
        maximum_source_bytes: usize,
    ) -> Result<Arc<CachedChunk>> {
        let mut state = self.lock()?;
        if let Some(entry) = state.entries.get(&key) {
            return Ok(Arc::clone(&entry.chunk));
        }
        let size = bytes.capacity();
        let mut reservation = None;
        let metadata_bytes = self.maximum_entries * ENTRY_OVERHEAD_BYTES;
        if self.maximum_entries != 0
            && size <= maximum_source_bytes
            && size <= self.accounting.maximum.saturating_sub(metadata_bytes)
        {
            if state.metadata.is_none() {
                if let Some(metadata) = self.accounting.claim(metadata_bytes) {
                    if state.entries.try_reserve(self.maximum_entries).is_ok() {
                        state.metadata = Some(metadata);
                    }
                }
            }
            if state.metadata.is_some() {
                // Keep most of this dictionary's remaining working budget for
                // key/record decoding rather than optional retained chunks.
                loop {
                    let retained: usize = state
                        .entries
                        .iter()
                        .filter(|(k, _)| k.owner == key.owner)
                        .map(|(_, entry)| entry.chunk.bytes.capacity())
                        .sum();
                    if retained <= maximum_source_bytes - size {
                        break;
                    }
                    let oldest = state
                        .entries
                        .iter()
                        .filter(|(k, _)| k.owner == key.owner)
                        .min_by_key(|(_, entry)| entry.touched)
                        .map(|(k, _)| *k);
                    if let Some(oldest) = oldest {
                        state.entries.remove(&oldest);
                        state.evictions = state.evictions.saturating_add(1);
                    } else {
                        break;
                    }
                }
                let section_count = state
                    .entries
                    .keys()
                    .filter(|k| k.owner == key.owner && k.section == key.section)
                    .count();
                if section_count >= MAX_SECTION_CHUNKS {
                    state.evict(Some((key.owner, key.section)));
                }
                loop {
                    if state.entries.len() < self.maximum_entries {
                        reservation = self.accounting.claim(size);
                        if reservation.is_some() {
                            break;
                        }
                    }
                    if !state.evict(None) {
                        break;
                    }
                }
            }
        }
        let retained = reservation.is_some();
        let chunk = Arc::new(CachedChunk {
            bytes,
            _source_memory: source_memory,
            _shared_memory: reservation,
        });
        if retained {
            let age = state.tick();
            state.entries.insert(
                key,
                Entry {
                    chunk: Arc::clone(&chunk),
                    touched: age,
                },
            );
        }
        Ok(chunk)
    }
}

pub(crate) struct CacheOwner {
    pub(crate) cache: Arc<IndexChunkCache>,
    pub(crate) id: u64,
    pub(crate) maximum_source_bytes: usize,
}
impl Drop for CacheOwner {
    fn drop(&mut self) {
        let _ = self.cache.remove_owner(self.id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::limits::MemoryBudget;
    fn put(
        cache: &IndexChunkCache,
        owner: u64,
        section: usize,
        chunk: u64,
        size: usize,
    ) -> Arc<CachedChunk> {
        let budget = Arc::new(MemoryBudget::new(usize::MAX));
        cache
            .insert(
                CacheKey {
                    owner,
                    section,
                    chunk,
                },
                vec![chunk as u8; size],
                budget.reserve(size, "test").unwrap(),
                usize::MAX,
            )
            .unwrap()
    }
    #[test]
    fn budget_counts_evicted_live_leases_and_falls_back_without_overcommit() {
        let cache = Arc::new(IndexChunkCache::new(16 * 1024));
        let owner = cache.owner(usize::MAX).unwrap();
        let held = put(&cache, owner.id, 0, 0, 8 * 1024);
        let second = put(&cache, owner.id, 0, 1, 8 * 1024);
        // The first lease still consumes the pool budget after eviction; the
        // second read succeeds without being admitted to the full cache.
        assert_eq!(second.bytes[0], 1);
        assert!(cache.usage().unwrap().resident_bytes <= 16 * 1024);
        assert!(
            cache
                .get(CacheKey {
                    owner: owner.id,
                    section: 0,
                    chunk: 1
                })
                .unwrap()
                .is_none()
        );
        drop(held);
        drop(second);
        drop(put(&cache, owner.id, 0, 2, 8 * 1024));
        assert!(
            cache
                .get(CacheKey {
                    owner: owner.id,
                    section: 0,
                    chunk: 2
                })
                .unwrap()
                .is_some()
        );
        assert!(cache.usage().unwrap().peak_bytes <= 16 * 1024);
    }
    #[test]
    fn recent_chunks_survive_and_section_capacity_is_bounded() {
        let cache = Arc::new(IndexChunkCache::new(128 * 1024));
        let owner = cache.owner(usize::MAX).unwrap();
        for n in 0..16 {
            drop(put(&cache, owner.id, 0, n, 64));
        }
        let key = CacheKey {
            owner: owner.id,
            section: 0,
            chunk: 0,
        };
        assert!(cache.get(key).unwrap().is_some());
        drop(put(&cache, owner.id, 0, 16, 64));
        assert!(cache.get(key).unwrap().is_some());
        assert!(cache.get(CacheKey { chunk: 1, ..key }).unwrap().is_none());
        assert_eq!(cache.usage().unwrap().entries, 16);
        drop(owner);
        assert_eq!(cache.usage().unwrap().entries, 0);
    }
    #[test]
    fn multiple_threads_and_owners_share_one_hard_budget() {
        let cache = Arc::new(IndexChunkCache::new(64 * 1024));
        std::thread::scope(|scope| {
            for _ in 0..8 {
                let cache = Arc::clone(&cache);
                scope.spawn(move || {
                    let owner = cache.owner(usize::MAX).unwrap();
                    for n in 0..100 {
                        let held = put(&cache, owner.id, (n % 4) as usize, n, 4096);
                        assert!(cache.usage().unwrap().resident_bytes <= 64 * 1024);
                        assert_eq!(held.bytes.len(), 4096);
                    }
                });
            }
        });
        let usage = cache.usage().unwrap();
        assert!(usage.peak_bytes <= usage.maximum_bytes);
        assert_eq!(usage.entries, 0);
    }
    #[test]
    fn a_tight_source_quota_does_not_consume_its_decoder_budget() {
        let cache = Arc::new(IndexChunkCache::new(64 * 1024));
        let owner = cache.owner(4096).unwrap();
        let source = Arc::new(MemoryBudget::new(16 * 1024));
        for n in 0..100 {
            let bytes = vec![n as u8; 2048];
            drop(
                cache
                    .insert(
                        CacheKey {
                            owner: owner.id,
                            section: 0,
                            chunk: n,
                        },
                        bytes,
                        source.reserve(2048, "tight source").unwrap(),
                        owner.maximum_source_bytes,
                    )
                    .unwrap(),
            );
            assert!(source.used() <= 4096);
        }
        assert!(source.reserve(12 * 1024, "record decoding").is_ok());
        drop(owner);
        assert_eq!(source.used(), 0);
    }

    #[test]
    fn disabled_or_oversized_chunks_are_read_without_retention() {
        for maximum in [0, 32, 4096] {
            let cache = IndexChunkCache::new(maximum);
            drop(put(&cache, 1, 0, 0, 8192));
            assert_eq!(cache.usage().unwrap().entries, 0);
            assert_eq!(cache.usage().unwrap().resident_bytes, 0);
        }
    }
}
