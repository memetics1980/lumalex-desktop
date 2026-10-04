use dictionary_core::{DictionaryId, DictionarySource, MdictDictionary};
use std::env;

fn main() {
    let (Some(mdx_path), Some(prefix)) = (env::args().nth(1), env::args().nth(2)) else {
        eprintln!(
            "Usage: cargo run -p dictionary-core --example suggest -- <dictionary.mdx> <prefix>"
        );
        std::process::exit(2);
    };

    let source = DictionarySource::discover(
        DictionaryId::new("suggest-probe").expect("fixed dictionary identifier is valid"),
        mdx_path,
    )
    .unwrap_or_else(|error| exit_with_error("open dictionary source", error));
    let dictionary =
        MdictDictionary::open(source).unwrap_or_else(|error| exit_with_error("open MDX", error));
    let suggestions = dictionary
        .suggest(&prefix, 8)
        .unwrap_or_else(|error| exit_with_error("find suggestions", error));

    println!("Returned {} headword suggestion(s).", suggestions.len());
    for suggestion in suggestions {
        println!("- {suggestion}");
    }
}

fn exit_with_error(context: &str, error: impl std::fmt::Display) -> ! {
    eprintln!("Could not {context}: {error}");
    std::process::exit(1);
}
