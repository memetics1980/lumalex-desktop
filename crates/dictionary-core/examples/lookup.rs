use dictionary_core::{DictionaryId, DictionarySource, MdictDictionary};
use std::env;
use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut arguments = env::args_os().skip(1);
    let Some(mdx_path) = arguments.next() else {
        eprintln!(
            "usage: cargo run -p dictionary-core --example lookup -- <dictionary.mdx> <query>"
        );
        return ExitCode::from(2);
    };
    let Some(query) = arguments.next() else {
        eprintln!("missing lookup query");
        return ExitCode::from(2);
    };

    let source = match DictionarySource::new(
        DictionaryId::new("local-test").expect("fixed dictionary identifier is valid"),
        PathBuf::from(mdx_path),
        None,
    ) {
        Ok(source) => source,
        Err(error) => {
            eprintln!("could not describe dictionary: {error}");
            return ExitCode::FAILURE;
        }
    };

    let dictionary = match MdictDictionary::open(source) {
        Ok(dictionary) => dictionary,
        Err(error) => {
            eprintln!("could not open dictionary: {error}");
            return ExitCode::FAILURE;
        }
    };

    match dictionary.lookup(&query.to_string_lossy()) {
        Ok(result) => {
            println!("{} matching entries", result.articles.len());
            for article in result.articles.iter().take(3) {
                println!("{} ({} bytes)", article.headword, article.html.len());
            }
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("lookup failed: {error}");
            ExitCode::FAILURE
        }
    }
}
