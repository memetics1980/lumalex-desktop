use dictionary_core::{DictionaryError, DictionaryId, DictionarySource};
use std::path::PathBuf;

#[test]
fn source_proposes_a_matching_mdd_sidecar() {
    let source = DictionarySource::new(
        DictionaryId::new("e2e-english").unwrap(),
        PathBuf::from("/dictionaries/English.mdx"),
        None,
    )
    .unwrap();

    assert_eq!(
        source.adjacent_mdd_path(),
        PathBuf::from("/dictionaries/English.mdd")
    );
}

#[test]
fn source_rejects_the_wrong_primary_extension() {
    let error = DictionarySource::new(
        DictionaryId::new("bad-input").unwrap(),
        PathBuf::from("/dictionaries/English.zip"),
        None,
    )
    .unwrap_err();

    assert!(matches!(error, DictionaryError::UnexpectedExtension { .. }));
}

#[cfg(unix)]
#[test]
fn source_discovers_mdd_symlinks_to_readable_files() {
    use std::fs;
    use std::os::unix::fs::symlink;

    let directory =
        std::env::temp_dir().join(format!("lumalex-symlink-discovery-{}", std::process::id()));
    let _ = fs::remove_dir_all(&directory);
    fs::create_dir_all(&directory).unwrap();
    fs::write(directory.join("example.mdx"), b"mdx").unwrap();
    fs::write(directory.join("example.mdd"), b"mdd").unwrap();
    symlink(
        directory.join("example.mdd"),
        directory.join("example.1.mdd"),
    )
    .unwrap();

    let source = DictionarySource::discover(
        DictionaryId::new("test").unwrap(),
        directory.join("example.mdx"),
    )
    .unwrap();

    assert_eq!(source.mdd_paths.len(), 2);
    fs::remove_dir_all(directory).unwrap();
}
