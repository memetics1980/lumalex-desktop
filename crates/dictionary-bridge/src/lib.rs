//! Flutter-facing adapter for the local dictionary engine.
//!
//! File parsing remains in `dictionary-core`; this crate contains only
//! serializable value types and the small API exported across the FFI boundary.

pub mod api;
mod frb_generated;
