use crate::{
    Article, DictionaryError, DictionaryMetadata, DictionaryResource, DictionarySource,
    LookupResult,
};
use mdictlib::{KeyIndex, KeyIndexOptions, MddFile, MdxEntry, MdxFile};
use std::collections::HashSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, RwLock};

static INDEX_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// A lazy MDX reader. `MdxFile::open` reads the header and indexes; individual
/// article blocks are decoded only when a lookup needs them.
pub struct MdictDictionary {
    source: DictionarySource,
    mdx: MdxFile,
    // Android's Storage Access Framework can expose a selected MDX before
    // its large companion MDD volumes have been made seekable. Keep the
    // opened volumes refreshable so Flutter may attach those companions only
    // when the renderer first needs a resource. The MDX itself remains open
    // and ready for lookups during that preparation.
    mdds: RwLock<(
        Vec<PathBuf>,
        Result<std::sync::Arc<Vec<MddFile>>, (String, String)>,
    )>,
    key_index: RwLock<Option<KeyIndex>>,
    key_index_path: Option<PathBuf>,
    key_index_build: Mutex<()>,
}

impl MdictDictionary {
    const MAX_SUGGESTIONS: usize = 20;
    const MAX_LINK_REDIRECTS: usize = 16;

    pub fn open(source: DictionarySource) -> Result<Self, DictionaryError> {
        Self::open_internal(source, None)
    }

    /// Opens a dictionary and reuses a valid application-owned persistent key
    /// index when one already exists. A stale or damaged cache never prevents
    /// the source dictionary from opening; [`Self::ensure_key_index`] can
    /// replace it later.
    pub fn open_with_key_index(
        source: DictionarySource,
        key_index_path: PathBuf,
    ) -> Result<Self, DictionaryError> {
        Self::open_internal(source, Some(key_index_path))
    }

    fn open_internal(
        source: DictionarySource,
        key_index_path: Option<PathBuf>,
    ) -> Result<Self, DictionaryError> {
        let mdx = MdxFile::open(&source.mdx_path).map_err(|error| DictionaryError::Open {
            path: source.mdx_path.clone(),
            message: error.to_string(),
        })?;
        let key_index = key_index_path.as_ref().and_then(|path| {
            let identity = mdx.key_index_source_identity().ok()?;
            mdx.open_key_index(path, &identity, &KeyIndexOptions::new())
                .ok()
        });

        Ok(Self {
            source,
            mdx,
            mdds: RwLock::new((Vec::new(), Ok(std::sync::Arc::new(Vec::new())))),
            key_index: RwLock::new(key_index),
            key_index_path,
            key_index_build: Mutex::new(()),
        })
    }

    /// Ensures that this dictionary has a valid on-disk key index. Returns
    /// `true` when a new artifact was built and `false` when an existing index
    /// was already usable. The index contains headwords and physical ordinals,
    /// never article bodies or MDD resources.
    pub fn ensure_key_index(&self) -> Result<bool, DictionaryError> {
        self.ensure_key_index_with_cancellation(|| false)
    }

    /// Builds the disposable index only while the caller remains idle.
    /// Frontends use this to abort background scans as soon as a lookup or
    /// article resource request begins, keeping foreground latency bounded.
    pub fn ensure_key_index_with_cancellation<C>(
        &self,
        cancelled: C,
    ) -> Result<bool, DictionaryError>
    where
        C: FnMut() -> bool,
    {
        let Some(index_path) = self.key_index_path.as_ref() else {
            return Ok(false);
        };
        if self.current_key_index(index_path)?.is_some() {
            return Ok(false);
        }

        let _build_guard = self
            .key_index_build
            .lock()
            .map_err(|_| index_error(index_path, "index build lock was poisoned"))?;
        if self.current_key_index(index_path)?.is_some() {
            return Ok(false);
        }

        let options = KeyIndexOptions::new();
        let identity = self
            .mdx
            .key_index_source_identity()
            .map_err(|error| index_error(index_path, error))?;
        if let Ok(index) = self.mdx.open_key_index(index_path, &identity, &options) {
            self.store_key_index(index_path, index)?;
            return Ok(false);
        }

        let parent = index_path
            .parent()
            .ok_or_else(|| index_error(index_path, "index path has no parent directory"))?;
        fs::create_dir_all(parent).map_err(|error| index_error(index_path, error))?;
        let sequence = INDEX_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temp_path =
            index_path.with_extension(format!("building-{}-{sequence}", std::process::id()));
        let build_result = self
            .mdx
            .build_key_index_to_path(&temp_path, &options, cancelled);
        if let Err(error) = build_result {
            let _ = fs::remove_file(&temp_path);
            return Err(index_error(index_path, error));
        }

        if let Err(error) = fs::rename(&temp_path, index_path) {
            if matches!(
                error.kind(),
                io::ErrorKind::AlreadyExists | io::ErrorKind::PermissionDenied
            ) {
                fs::remove_file(index_path).map_err(|remove_error| {
                    let _ = fs::remove_file(&temp_path);
                    index_error(index_path, remove_error)
                })?;
                fs::rename(&temp_path, index_path).map_err(|rename_error| {
                    let _ = fs::remove_file(&temp_path);
                    index_error(index_path, rename_error)
                })?;
            } else {
                let _ = fs::remove_file(&temp_path);
                return Err(index_error(index_path, error));
            }
        }

        let index = self
            .mdx
            .open_key_index(index_path, &identity, &options)
            .map_err(|error| index_error(index_path, error))?;
        self.store_key_index(index_path, index)?;
        Ok(true)
    }

    fn current_key_index(&self, index_path: &PathBuf) -> Result<Option<KeyIndex>, DictionaryError> {
        self.key_index
            .read()
            .map(|index| index.clone())
            .map_err(|_| index_error(index_path, "index read lock was poisoned"))
    }

    fn store_key_index(
        &self,
        index_path: &PathBuf,
        index: KeyIndex,
    ) -> Result<(), DictionaryError> {
        *self
            .key_index
            .write()
            .map_err(|_| index_error(index_path, "index write lock was poisoned"))? = Some(index);
        Ok(())
    }

    pub fn metadata(&self) -> DictionaryMetadata {
        // The MDict title field is optional and inconsistent in real-world
        // dictionaries. The import screen will later let the user rename it.
        let title = self
            .source
            .mdx_path
            .file_stem()
            .and_then(|stem| stem.to_str())
            .unwrap_or("Untitled dictionary")
            .to_owned();

        DictionaryMetadata {
            id: self.source.id.clone(),
            title,
            description: None,
        }
    }

    /// The resource volumes discovered next to the MDX. They are intentionally
    /// unopened until an article renderer asks for a specific resource.
    pub fn resource_paths(&self) -> &[PathBuf] {
        &self.source.mdd_paths
    }

    /// Reads one dictionary resource lazily. Approved files placed next to the
    /// MDX take precedence over an identically named resource embedded in an
    /// MDD. MDict packages commonly ship CSS/JavaScript fixes this way, and
    /// desktop readers treat those files as publisher overrides.
    ///
    /// MDD resource keys are normalized to the archive convention (a leading
    /// backslash), and path traversal components are rejected before either
    /// source is inspected.
    pub fn read_resource(
        &self,
        resource_path: &str,
        max_bytes: usize,
    ) -> Result<Option<DictionaryResource>, DictionaryError> {
        let keys = resource_key_candidates(resource_path);
        if keys.is_empty() {
            return Err(DictionaryError::Resource {
                path: resource_path.to_owned(),
                message: "resource key is empty or contains a parent-directory component"
                    .to_owned(),
            });
        }

        if let Some(resource) = self.read_sidecar_resource(resource_path, max_bytes)? {
            return Ok(Some(resource));
        }

        for mdd in self.open_resource_volumes()?.iter() {
            for key in &keys {
                let span = mdd
                    .lookup_span(key)
                    .map_err(|error| DictionaryError::Resource {
                        path: key.clone(),
                        message: error.to_string(),
                    })?;
                let Some(span) = span else {
                    continue;
                };

                if span.len() > max_bytes as u64 {
                    return Err(DictionaryError::ResourceTooLarge {
                        path: span.key().to_owned(),
                        size: span.len(),
                        max_size: max_bytes,
                    });
                }

                let resource = span.read().map_err(|error| DictionaryError::Resource {
                    path: key.clone(),
                    message: error.to_string(),
                })?;
                return Ok(Some(DictionaryResource {
                    path: resource.key().to_owned(),
                    bytes: resource.bytes().to_vec(),
                }));
            }
        }

        Ok(None)
    }

    fn open_resource_volumes(&self) -> Result<std::sync::Arc<Vec<MddFile>>, DictionaryError> {
        // Do not rely solely on `source.mdd_paths`: the source is described
        // when the MDX opens, whereas an Android stream-only provider may
        // require the app to materialize MDD companions later. Rediscovering
        // this small directory listing makes the transition atomic from the
        // reader's perspective and avoids reopening the much larger MDX.
        let paths = DictionarySource::discover_mdd_paths(&self.source.mdx_path)?;

        {
            let cached = self.mdds.read().map_err(|_| DictionaryError::Resource {
                path: self.source.mdx_path.display().to_string(),
                message: "resource volume cache read lock was poisoned".to_owned(),
            })?;
            if cached.0 == paths {
                return cached
                    .1
                    .clone()
                    .map_err(|(path, message)| DictionaryError::Resource { path, message });
            }
        }

        let opened = paths
            .iter()
            .map(|path| {
                MddFile::open(path).map_err(|error| (path.display().to_string(), error.to_string()))
            })
            .collect::<Result<Vec<_>, _>>()
            .map(std::sync::Arc::new);

        let mut cached = self.mdds.write().map_err(|_| DictionaryError::Resource {
            path: self.source.mdx_path.display().to_string(),
            message: "resource volume cache write lock was poisoned".to_owned(),
        })?;
        if cached.0 != paths {
            *cached = (paths, opened);
        }
        cached
            .1
            .clone()
            .map_err(|(path, message)| DictionaryError::Resource { path, message })
    }

    /// Reads an approved sidecar used by a few MDict publishers for stylesheet,
    /// font, and publisher-script assets. Canonical paths must always remain
    /// inside the selected dictionary folder.
    fn read_sidecar_resource(
        &self,
        resource_path: &str,
        max_bytes: usize,
    ) -> Result<Option<DictionaryResource>, DictionaryError> {
        let Some(relative_path) = sidecar_relative_path(resource_path) else {
            return Ok(None);
        };
        let Some(extension) = relative_path.extension().and_then(|value| value.to_str()) else {
            return Ok(None);
        };
        if !matches!(
            extension.to_ascii_lowercase().as_str(),
            "css" | "js" | "otf" | "ttf" | "woff" | "woff2"
        ) {
            return Ok(None);
        }

        let parent = self
            .source
            .mdx_path
            .parent()
            .ok_or_else(|| DictionaryError::Resource {
                path: resource_path.to_owned(),
                message: "the MDX file has no parent folder".to_owned(),
            })?;
        let root = fs::canonicalize(parent).map_err(|error| DictionaryError::Resource {
            path: parent.display().to_string(),
            message: error.to_string(),
        })?;
        let candidate = root.join(relative_path);
        let candidate = if is_android_saf_source(&self.source.mdx_path) {
            // Android SAF files are exposed by the Flutter layer as private
            // links to `/proc/self/fd/*`. Some physical-device providers only
            // offer sequential streams, which Flutter stages as regular files
            // in the same private virtual source directory. Canonicalizing a
            // descriptor link resolves outside that directory even though the
            // link itself was created from a system-granted document URI.
            match fs::symlink_metadata(&candidate) {
                Ok(metadata)
                    if metadata.file_type().is_symlink()
                        && is_android_saf_descriptor_link(&candidate) =>
                {
                    candidate
                }
                // Private SAF staging links are created only inside the app's
                // own cache directory. They avoid a second full-file copy of
                // large dictionaries while remaining inaccessible to other
                // apps, so they are safe publisher-sidecar sources too.
                Ok(metadata) if metadata.file_type().is_symlink() => candidate,
                Ok(metadata) if metadata.file_type().is_file() => candidate,
                Ok(_) => {
                    return Err(DictionaryError::Resource {
                        path: resource_path.to_owned(),
                        message: "Android SAF sidecar is not an approved private source file"
                            .to_owned(),
                    });
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
                Err(error) => {
                    return Err(DictionaryError::Resource {
                        path: resource_path.to_owned(),
                        message: error.to_string(),
                    });
                }
            }
        } else {
            let candidate = match fs::canonicalize(&candidate) {
                Ok(path) => path,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
                Err(error) => {
                    return Err(DictionaryError::Resource {
                        path: resource_path.to_owned(),
                        message: error.to_string(),
                    });
                }
            };
            if !candidate.starts_with(&root) {
                return Err(DictionaryError::Resource {
                    path: resource_path.to_owned(),
                    message: "sidecar path escapes the dictionary folder".to_owned(),
                });
            }
            candidate
        };

        let size = fs::metadata(&candidate)
            .map_err(|error| DictionaryError::Resource {
                path: candidate.display().to_string(),
                message: error.to_string(),
            })?
            .len();
        if size > max_bytes as u64 {
            return Err(DictionaryError::ResourceTooLarge {
                path: resource_path.to_owned(),
                size,
                max_size: max_bytes,
            });
        }
        let bytes = fs::read(&candidate).map_err(|error| DictionaryError::Resource {
            path: candidate.display().to_string(),
            message: error.to_string(),
        })?;
        Ok(Some(DictionaryResource {
            path: resource_path.to_owned(),
            bytes,
        }))
    }

    /// Returns a small, de-duplicated set of normalized-prefix headwords
    /// without decoding their definitions. This is intentionally capped so an
    /// untrusted dictionary cannot turn an input keystroke into unbounded work.
    pub fn suggest(&self, prefix: &str, limit: usize) -> Result<Vec<String>, DictionaryError> {
        let prefix = prefix.trim();
        if prefix.is_empty() || limit == 0 {
            return Ok(Vec::new());
        }

        let limit = limit.min(Self::MAX_SUGGESTIONS);
        let index = self.read_key_index_for_suggestion(prefix)?;
        let Some(index) = index.as_ref() else {
            // Completion runs for every debounced keystroke and may be
            // requested across a large enabled library. Building a complete
            // in-memory locator here would make typing after import launch a
            // full key scan per dictionary. Exact lookup has a responsive
            // session-local fallback, but suggestions wait for the durable
            // background index instead.
            return Ok(Vec::new());
        };
        let keys = self
            .mdx
            .prefix_keys_with_index(index, prefix, limit)
            .map_err(|error| DictionaryError::Suggestion {
                prefix: prefix.to_owned(),
                message: error.to_string(),
            })?;
        let mut suggestions = Vec::with_capacity(keys.len());
        for key in keys {
            if !suggestions.iter().any(|suggestion| suggestion == key.key()) {
                suggestions.push(key.key().to_owned());
            }
        }
        Ok(suggestions)
    }

    /// Returns every physical entry matching the key, preserving duplicate
    /// headwords. This matters for dictionaries that intentionally store
    /// several senses under one spelling.
    pub fn lookup(&self, query: &str) -> Result<LookupResult, DictionaryError> {
        let query = query.trim();
        if query.is_empty() {
            return Ok(LookupResult {
                query: String::new(),
                articles: Vec::new(),
            });
        }

        // See the matching note in `suggest`: persistent indexing must never
        // turn the first lookup after import into a synchronous build. The
        // in-memory fallback is retained only for this open dictionary; the
        // importer continues preparing the reusable index in the background.
        let index = self.read_key_index_for_lookup(query)?;
        let matches = match index.as_ref() {
            Some(index) => self.mdx.locate_with_key_index(index, query),
            None => self.mdx.locate(query),
        }
        .map_err(|error| DictionaryError::Lookup {
            query: query.to_owned(),
            message: error.to_string(),
        })?;

        let mut articles = Vec::new();
        if let Some(matches) = matches {
            for ordinal in matches.iter() {
                let entry =
                    self.mdx
                        .entry_at(ordinal)
                        .map_err(|error| DictionaryError::Lookup {
                            query: query.to_owned(),
                            message: error.to_string(),
                        })?;

                if let Some(entry) = entry {
                    articles.push(Article {
                        dictionary_id: self.source.id.clone(),
                        headword: entry.key().to_owned(),
                        html: entry.text().to_owned(),
                    });
                }
            }
        }

        Ok(LookupResult {
            query: query.to_owned(),
            articles,
        })
    }

    /// Resolves the first article needed by the mobile reader. With a durable
    /// key index this is identical to the first result of [`Self::lookup`].
    /// Before that background index exists, it first uses the MDX key-block
    /// summaries to decode only the candidate key block and the matching
    /// record block. A miss deliberately falls back to the complete locator,
    /// preserving case/StripKey matching; [`Self::lookup`] remains the
    /// duplicate-complete API for callers that need every physical article.
    ///
    /// The UI presents one article per dictionary, so returning the first
    /// physical match is both sufficient and avoids holding first interaction
    /// hostage to a full headword scan after a new import. Standard MDict
    /// `@@@LINK=target` alias records are followed with a bounded cycle check,
    /// so inflected aliases never leak into the renderer as plain text.
    pub fn lookup_first(&self, query: &str) -> Result<Option<Article>, DictionaryError> {
        let query = query.trim();
        if query.is_empty() {
            return Ok(None);
        }

        let mut target = query.to_owned();
        let mut visited = HashSet::new();
        for _ in 0..=Self::MAX_LINK_REDIRECTS {
            if !visited.insert(target.to_lowercase()) {
                return Err(DictionaryError::Lookup {
                    query: query.to_owned(),
                    message: format!("cyclic MDict link redirect at {target:?}"),
                });
            }
            let Some(entry) = self.lookup_first_entry(&target)? else {
                return Ok(None);
            };
            if let Some(next_target) = mdx_link_target(entry.text()) {
                target = next_target.to_owned();
                continue;
            }
            return Ok(Some(Article {
                dictionary_id: self.source.id.clone(),
                headword: entry.key().to_owned(),
                html: entry.text().to_owned(),
            }));
        }
        Err(DictionaryError::Lookup {
            query: query.to_owned(),
            message: format!(
                "MDict link redirect exceeds {} hops",
                Self::MAX_LINK_REDIRECTS
            ),
        })
    }

    fn lookup_first_entry(&self, query: &str) -> Result<Option<MdxEntry>, DictionaryError> {
        let index = self.read_key_index_for_lookup(query)?;
        let ordinal = match index.as_ref() {
            Some(index) => self
                .mdx
                .locate_with_key_index(index, query)
                .map_err(|error| DictionaryError::Lookup {
                    query: query.to_owned(),
                    message: error.to_string(),
                })?
                .map(|matches| matches.first()),
            None => match self
                .mdx
                .locate_first_raw_exact_in_candidate_blocks(query)
                .map_err(|error| DictionaryError::Lookup {
                    query: query.to_owned(),
                    message: error.to_string(),
                })? {
                Some(ordinal) => Some(ordinal),
                None => self
                    .mdx
                    .locate(query)
                    .map_err(|error| DictionaryError::Lookup {
                        query: query.to_owned(),
                        message: error.to_string(),
                    })?
                    .map(|matches| matches.first()),
            },
        };

        let Some(ordinal) = ordinal else {
            return Ok(None);
        };
        self.mdx
            .entry_at(ordinal)
            .map_err(|error| DictionaryError::Lookup {
                query: query.to_owned(),
                message: error.to_string(),
            })
    }

    fn read_key_index_for_suggestion(
        &self,
        prefix: &str,
    ) -> Result<Option<KeyIndex>, DictionaryError> {
        let Some(index_path) = self.key_index_path.as_ref() else {
            return self
                .key_index
                .read()
                .map(|index| index.clone())
                .map_err(|_| DictionaryError::Suggestion {
                    prefix: prefix.to_owned(),
                    message: "index read lock was poisoned".to_owned(),
                });
        };
        self.key_index
            .read()
            .map(|index| index.clone())
            .map_err(|_| DictionaryError::Suggestion {
                prefix: prefix.to_owned(),
                message: format!("index read lock was poisoned for {}", index_path.display()),
            })
    }

    fn read_key_index_for_lookup(&self, query: &str) -> Result<Option<KeyIndex>, DictionaryError> {
        let index_path = self.key_index_path.as_ref();
        self.key_index
            .read()
            .map(|index| index.clone())
            .map_err(|_| DictionaryError::Lookup {
                query: query.to_owned(),
                message: match index_path {
                    Some(path) => format!("index read lock was poisoned for {}", path.display()),
                    None => "index read lock was poisoned".to_owned(),
                },
            })
    }
}

fn is_android_saf_descriptor_link(path: &Path) -> bool {
    fs::read_link(path)
        .map(|target| target.starts_with(Path::new("/proc/self/fd")))
        .unwrap_or(false)
}

fn is_android_saf_source(path: &Path) -> bool {
    is_android_saf_descriptor_link(path)
        || path
            .parent()
            .map(|parent| parent.join(".lumalex-saf-staged-source").is_file())
            .unwrap_or(false)
}

fn index_error(path: &PathBuf, error: impl std::fmt::Display) -> DictionaryError {
    DictionaryError::Index {
        path: path.clone(),
        message: error.to_string(),
    }
}

fn mdx_link_target(article_html: &str) -> Option<&str> {
    let record = article_html.trim_matches(|character: char| {
        character.is_whitespace() || character == '\u{feff}' || character == '\0'
    });
    let target = record.strip_prefix("@@@LINK=")?.trim();
    if target.is_empty()
        || target.len() > 1024
        || target
            .chars()
            .any(|character| matches!(character, '\r' | '\n' | '\0'))
    {
        return None;
    }
    Some(target)
}

fn resource_key_candidates(resource_path: &str) -> Vec<String> {
    let trimmed = resource_path.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }

    let normalized = trimmed.replace('/', "\\");
    let components = normalized
        .split('\\')
        .filter(|part| !part.is_empty() && *part != ".")
        .collect::<Vec<_>>();
    if components.is_empty() || components.contains(&"..") {
        return Vec::new();
    }

    vec![format!("\\{}", components.join("\\"))]
}

fn sidecar_relative_path(resource_path: &str) -> Option<PathBuf> {
    let normalized = resource_path.replace('\\', "/");
    let components = normalized
        .split('/')
        .filter(|part| !part.is_empty() && *part != ".")
        .collect::<Vec<_>>();
    if components.is_empty() || components.contains(&"..") {
        return None;
    }

    let mut path = PathBuf::new();
    for component in components {
        path.push(component);
    }
    Some(path)
}

#[cfg(test)]
mod tests {
    use super::{
        is_android_saf_source, mdx_link_target, resource_key_candidates, sidecar_relative_path,
    };
    use std::fs;
    use std::path::PathBuf;

    #[test]
    fn normalizes_web_paths_to_mdd_keys() {
        assert_eq!(
            resource_key_candidates("images/icon.png"),
            vec!["\\images\\icon.png"]
        );
    }

    #[test]
    fn rejects_parent_directory_components() {
        assert!(resource_key_candidates("images/../secrets.png").is_empty());
    }

    #[test]
    fn preserves_hashes_used_in_sound_filenames() {
        assert_eq!(
            resource_key_candidates("_test#_us_1.mp3"),
            vec!["\\_test#_us_1.mp3"]
        );
    }

    #[test]
    fn parses_only_complete_mdict_link_records() {
        assert_eq!(
            mdx_link_target("\u{feff}  @@@LINK=responsibility\r\n"),
            Some("responsibility")
        );
        assert_eq!(mdx_link_target("@@@LINK="), None);
        assert_eq!(mdx_link_target("<p>definition</p>@@@LINK=another"), None);
        assert_eq!(mdx_link_target("@@@LINK=one\ntwo"), None);
    }

    #[test]
    fn sidecars_are_confined_to_the_dictionary_folder() {
        assert_eq!(
            sidecar_relative_path("styles/oald.css"),
            Some(PathBuf::from("styles/oald.css"))
        );
        assert_eq!(sidecar_relative_path("../outside.css"), None);
    }

    #[test]
    fn recognizes_a_private_staged_android_source_folder() {
        let directory = std::env::temp_dir().join(format!(
            "lumalex-saf-source-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system time is after the Unix epoch")
                .as_nanos(),
        ));
        fs::create_dir_all(&directory).expect("creates temporary source folder");
        let mdx_path = directory.join("dictionary.mdx");
        fs::write(&mdx_path, b"fixture").expect("writes temporary MDX");

        assert!(!is_android_saf_source(&mdx_path));
        fs::write(directory.join(".lumalex-saf-staged-source"), b"staged")
            .expect("writes source marker");
        assert!(is_android_saf_source(&mdx_path));

        fs::remove_dir_all(&directory).expect("cleans temporary source folder");
    }
}
