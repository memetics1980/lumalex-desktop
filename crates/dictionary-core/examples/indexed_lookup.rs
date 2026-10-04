use dictionary_core::{DictionaryId, DictionarySource, MdictDictionary};
use std::env;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Instant;

fn main() -> ExitCode {
    let mut arguments = env::args_os().skip(1);
    let (Some(mdx_path), Some(query), Some(index_path)) =
        (arguments.next(), arguments.next(), arguments.next())
    else {
        eprintln!("usage: indexed_lookup <dictionary.mdx> <query> <application-cache-index-path>");
        return ExitCode::from(2);
    };

    let source = match DictionarySource::new(
        DictionaryId::new("indexed-test").expect("fixed dictionary identifier is valid"),
        PathBuf::from(mdx_path),
        None,
    ) {
        Ok(source) => source,
        Err(error) => {
            eprintln!("could not describe dictionary: {error}");
            return ExitCode::FAILURE;
        }
    };
    let dictionary = match MdictDictionary::open_with_key_index(source, PathBuf::from(index_path)) {
        Ok(dictionary) => dictionary,
        Err(error) => {
            eprintln!("could not open dictionary: {error}");
            return ExitCode::FAILURE;
        }
    };

    let index_started = Instant::now();
    let built = match dictionary.ensure_key_index() {
        Ok(built) => built,
        Err(error) => {
            eprintln!("could not ensure index: {error}");
            return ExitCode::FAILURE;
        }
    };
    let index_elapsed = index_started.elapsed();
    let lookup_started = Instant::now();
    let result = match dictionary.lookup(&query.to_string_lossy()) {
        Ok(result) => result,
        Err(error) => {
            eprintln!("lookup failed: {error}");
            return ExitCode::FAILURE;
        }
    };

    println!(
        "index_built={built} index_ms={} lookup_ms={} matches={}",
        index_elapsed.as_millis(),
        lookup_started.elapsed().as_millis(),
        result.articles.len(),
    );
    ExitCode::SUCCESS
}
