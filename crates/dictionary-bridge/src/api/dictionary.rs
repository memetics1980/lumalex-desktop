use anyhow::{Context, Result};
use dictionary_core::{
    DictionaryId, DictionaryResource as CoreDictionaryResource, DictionarySource, MdictDictionary,
    KEY_INDEX_REVISION,
};
use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock, RwLock};
use std::time::UNIX_EPOCH;

static DICTIONARY_CACHE: OnceLock<RwLock<HashMap<String, CachedDictionary>>> = OnceLock::new();
static INDEX_CACHE_DIRECTORY: OnceLock<PathBuf> = OnceLock::new();
// Incremented by every foreground lookup/resource request. Background index
// construction captures an epoch and stops at the next parser checkpoint when
// interactive work arrives.
static FOREGROUND_EPOCH: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct SourceVersion {
    bytes: u64,
    modified_unix_nanos: Option<u128>,
}

struct CachedDictionary {
    version: SourceVersion,
    dictionary: Arc<MdictDictionary>,
}

#[flutter_rust_bridge::frb]
pub struct DictionaryInfo {
    pub title: String,
    pub mdx_path: String,
    pub mdd_paths: Vec<String>,
}

#[flutter_rust_bridge::frb]
pub struct DictionaryArticle {
    pub dictionary_name: String,
    pub headword: String,
    pub html: String,
}

#[flutter_rust_bridge::frb]
pub struct DictionaryResource {
    pub resource_path: String,
    pub mime_type: String,
    pub bytes: Vec<u8>,
}

/// Selects the application-owned directory used for disposable persistent key
/// indexes. This must be called once during startup before dictionaries open.
pub fn configure_index_cache(index_cache_directory: String) -> Result<()> {
    let path = PathBuf::from(index_cache_directory);
    fs::create_dir_all(&path)
        .with_context(|| format!("could not create index cache {}", path.display()))?;
    if let Some(existing) = INDEX_CACHE_DIRECTORY.get() {
        if existing != &path {
            anyhow::bail!(
                "index cache is already configured as {}",
                existing.display()
            );
        }
        return Ok(());
    }
    INDEX_CACHE_DIRECTORY
        .set(path)
        .map_err(|_| anyhow::anyhow!("index cache was configured concurrently"))
}

/// Validates and opens an MDX while the import progress UI is still visible.
/// Keeping the reader in the process cache removes the hidden first-query open
/// cost. Record bodies and MDD resources remain lazy.
pub fn inspect_mdx(mdx_path: String) -> Result<DictionaryInfo> {
    let source = DictionarySource::new(
        DictionaryId::new("dictionary-inspection").expect("fixed dictionary identifier is valid"),
        PathBuf::from(&mdx_path),
        None,
    )
    .context("invalid MDX path")?;
    validate_importable_mdx(&source.mdx_path)?;
    let title = open_dictionary(&mdx_path)?.metadata().title;

    Ok(DictionaryInfo {
        title,
        mdx_path,
        // Android already pairs MDD documents through the folder scan. The
        // application does not consume this field during import, and avoiding
        // directory discovery here keeps the hot import path metadata-only.
        mdd_paths: Vec::new(),
    })
}

/// Builds and activates a reusable key index for one MDX. The source
/// dictionary remains untouched; only the configured cache directory changes.
pub fn ensure_mdx_index(mdx_path: String) -> Result<bool> {
    let epoch = FOREGROUND_EPOCH.load(Ordering::Acquire);
    open_dictionary(&mdx_path)?
        .ensure_key_index_with_cancellation(|| FOREGROUND_EPOCH.load(Ordering::Acquire) != epoch)
        .with_context(|| format!("could not prepare key index for {mdx_path}"))
}

/// Lazily resolves an image, sound, stylesheet, font, or other attachment
/// from MDD volumes (and approved CSS/font/local-script sidecars) beside an
/// MDX. Dart receives no filesystem handles, only the bounded byte payload
/// needed by its locked-down renderer.
pub fn read_mdd_resource(
    mdx_path: String,
    resource_path: String,
    max_bytes: u32,
) -> Result<Option<DictionaryResource>> {
    FOREGROUND_EPOCH.fetch_add(1, Ordering::AcqRel);
    let dictionary = open_dictionary(&mdx_path)?;
    let resource = dictionary
        .read_resource(&resource_path, max_bytes as usize)
        .with_context(|| format!("resource lookup failed for {resource_path:?}"))?;

    Ok(resource.map(resource_for_bridge))
}

/// Returns at most twenty local headword completions without reading article
/// definitions. The cap is enforced again in the core for callers outside the
/// Flutter bridge.
pub fn suggest_mdx(mdx_path: String, prefix: String, limit: u32) -> Result<Vec<String>> {
    FOREGROUND_EPOCH.fetch_add(1, Ordering::AcqRel);
    let dictionary = open_dictionary(&mdx_path)?;
    dictionary
        .suggest(&prefix, limit as usize)
        .with_context(|| format!("suggestion lookup failed for {prefix:?}"))
}

/// Looks up a key in one MDX dictionary. The default FRB mode runs this work
/// asynchronously relative to Dart so file parsing cannot block the UI thread.
pub fn lookup_mdx(mdx_path: String, query: String) -> Result<Vec<DictionaryArticle>> {
    FOREGROUND_EPOCH.fetch_add(1, Ordering::AcqRel);
    let dictionary = open_dictionary(&mdx_path)?;
    let dictionary_name = dictionary.metadata().title;
    let article = dictionary
        .lookup_first(&query)
        .with_context(|| format!("lookup failed for {query:?}"))?;

    Ok(article
        .into_iter()
        .map(|article| DictionaryArticle {
            dictionary_name: dictionary_name.clone(),
            headword: article.headword,
            html: article.html,
        })
        .collect())
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

fn open_dictionary(mdx_path: &str) -> Result<Arc<MdictDictionary>> {
    let cache = DICTIONARY_CACHE.get_or_init(|| RwLock::new(HashMap::new()));
    let version = source_version(Path::new(mdx_path))?;
    if let Some(dictionary) = cache
        .read()
        .map_err(|_| anyhow::anyhow!("dictionary cache read lock was poisoned"))?
        .get(mdx_path)
        .filter(|cached| cached.version == version)
        .map(|cached| cached.dictionary.clone())
    {
        return Ok(dictionary);
    }

    let source = DictionarySource::discover(
        DictionaryId::new("active-dictionary").expect("fixed dictionary identifier is valid"),
        mdx_path,
    )
    .context("invalid MDX path")?;

    let opened = Arc::new(
        match INDEX_CACHE_DIRECTORY.get() {
            Some(directory) => {
                MdictDictionary::open_with_key_index(source, key_index_path(directory, mdx_path))
            }
            None => MdictDictionary::open(source),
        }
        .with_context(|| format!("could not open {mdx_path}"))?,
    );
    let mut cache = cache
        .write()
        .map_err(|_| anyhow::anyhow!("dictionary cache write lock was poisoned"))?;
    if let Some(current) = cache
        .get(mdx_path)
        .filter(|cached| cached.version == version)
    {
        return Ok(current.dictionary.clone());
    }
    cache.insert(
        mdx_path.to_owned(),
        CachedDictionary {
            version,
            dictionary: opened.clone(),
        },
    );
    Ok(opened)
}

fn source_version(path: &Path) -> Result<SourceVersion> {
    let metadata = fs::metadata(path)
        .with_context(|| format!("could not read dictionary metadata {}", path.display()))?;
    let modified_unix_nanos = metadata
        .modified()
        .ok()
        .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_nanos());
    Ok(SourceVersion {
        bytes: metadata.len(),
        modified_unix_nanos,
    })
}

fn key_index_path(directory: &Path, mdx_path: &str) -> PathBuf {
    // Stable FNV-1a keeps source paths out of cache filenames while retaining
    // deterministic cross-run names without another hashing dependency.
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in mdx_path.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    directory.join(format!("{hash:016x}-{KEY_INDEX_REVISION}.mdx-key-index"))
}

/// Checks the small, fixed MDX header envelope without parsing key or record
/// metadata. It rejects empty/wrongly framed documents early while keeping
/// folder import independent from dictionary size.
fn validate_importable_mdx(path: &Path) -> Result<()> {
    let metadata = fs::metadata(path)
        .with_context(|| format!("could not read dictionary metadata {}", path.display()))?;
    if !metadata.is_file() {
        anyhow::bail!(
            "dictionary source is not a readable file: {}",
            path.display()
        );
    }
    let source_bytes = metadata.len();
    if source_bytes < 8 {
        anyhow::bail!("dictionary source is too small to contain an MDX header");
    }

    let mut length_bytes = [0_u8; 4];
    fs::File::open(path)
        .with_context(|| format!("could not open dictionary header {}", path.display()))?
        .read_exact(&mut length_bytes)
        .with_context(|| format!("could not read dictionary header {}", path.display()))?;
    let xml_bytes = u64::from(u32::from_be_bytes(length_bytes));
    if xml_bytes == 0 || !xml_bytes.is_multiple_of(2) {
        anyhow::bail!("dictionary has an invalid UTF-16 MDX header length");
    }
    let header_end = 4_u64
        .checked_add(xml_bytes)
        .and_then(|value| value.checked_add(4))
        .ok_or_else(|| anyhow::anyhow!("dictionary header length overflows"))?;
    if header_end > source_bytes {
        anyhow::bail!("dictionary header extends beyond the source file");
    }
    Ok(())
}

fn resource_for_bridge(resource: CoreDictionaryResource) -> DictionaryResource {
    DictionaryResource {
        mime_type: mime_type_for(&resource.path).to_owned(),
        resource_path: resource.path,
        bytes: resource.bytes,
    }
}

fn mime_type_for(path: &str) -> &'static str {
    let extension = path
        .rsplit('.')
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    match extension.as_str() {
        "css" => "text/css",
        "gif" => "image/gif",
        "htm" | "html" => "text/html",
        "jpeg" | "jpg" => "image/jpeg",
        "js" => "text/javascript",
        "mp3" => "audio/mpeg",
        "mp4" => "video/mp4",
        "ogg" => "audio/ogg",
        "otf" => "font/otf",
        "png" => "image/png",
        "svg" => "image/svg+xml",
        "ttf" => "font/ttf",
        "wav" => "audio/wav",
        "webp" => "image/webp",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        _ => "application/octet-stream",
    }
}

#[cfg(test)]
mod tests {
    use super::{inspect_mdx, key_index_path, source_version};
    use std::fs;
    use std::path::Path;

    #[test]
    fn key_index_cache_names_are_stable_and_path_specific() {
        let directory = Path::new("cache");
        assert_eq!(
            key_index_path(directory, "/dictionaries/one.mdx"),
            key_index_path(directory, "/dictionaries/one.mdx")
        );
        assert_ne!(
            key_index_path(directory, "/dictionaries/one.mdx"),
            key_index_path(directory, "/dictionaries/two.mdx")
        );
    }

    #[test]
    fn inspection_rejects_an_mdx_that_has_only_a_header_envelope() {
        let directory = std::env::temp_dir().join(format!(
            "lumalex-inspection-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system time is after the Unix epoch")
                .as_nanos(),
        ));
        fs::create_dir_all(&directory).expect("creates temporary directory");
        let path = directory.join("Fast import.mdx");
        // Passing the fixed envelope check is insufficient: import now opens
        // the lazy reader so a corrupt/truncated file cannot be registered and
        // the first real lookup has no hidden reader-initialization cost.
        fs::write(&path, [0, 0, 0, 2, 0, 0, 0, 0, 0, 0]).expect("writes MDX envelope");

        assert!(inspect_mdx(path.display().to_string()).is_err());

        fs::remove_dir_all(directory).expect("removes temporary directory");
    }

    #[test]
    fn source_version_changes_when_a_dictionary_is_replaced() {
        let directory = std::env::temp_dir().join(format!(
            "lumalex-source-version-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system time is after the Unix epoch")
                .as_nanos(),
        ));
        fs::create_dir_all(&directory).expect("creates temporary directory");
        let path = directory.join("dictionary.mdx");
        fs::write(&path, b"first").expect("writes first source");
        let first = source_version(&path).expect("reads first source version");

        fs::write(&path, b"a longer replacement").expect("replaces source");
        let second = source_version(&path).expect("reads replacement version");

        assert_ne!(first, second);
        fs::remove_dir_all(directory).expect("removes temporary directory");
    }
}
