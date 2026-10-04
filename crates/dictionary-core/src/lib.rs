//! The platform-neutral core for the local dictionary application.
//!
//! This crate deliberately owns file parsing, lookup policy, and resource
//! access. The UI layer never receives raw offsets into an MDX or MDD file.

#![forbid(unsafe_code)]

mod mdict;
mod model;

pub use mdict::MdictDictionary;
pub use mdictlib::KEY_INDEX_REVISION;
pub use model::{
    Article, DictionaryError, DictionaryId, DictionaryMetadata, DictionaryResource,
    DictionarySource, LookupResult,
};
