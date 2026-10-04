use dictionary_core::{DictionaryId, DictionarySource, MdictDictionary};
use std::env;
use std::path::PathBuf;
use std::time::Instant;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut arguments = env::args_os().skip(1);
    let mdx_path = arguments
        .next()
        .map(PathBuf::from)
        .ok_or("usage: lookup_latency <dictionary.mdx> [query ...]")?;
    let mut key_index_path = None;
    let mut queries = Vec::new();
    while let Some(argument) = arguments.next() {
        if argument == "--build-index" {
            key_index_path = arguments.next().map(PathBuf::from);
            if key_index_path.is_none() {
                return Err("--build-index requires an output path".into());
            }
        } else {
            queries.push(argument.to_string_lossy().into_owned());
        }
    }
    let queries = if queries.is_empty() {
        vec![
            "increase".to_owned(),
            "day".to_owned(),
            "missing-lumalex-key".to_owned(),
        ]
    } else {
        queries
    };

    let source = DictionarySource::discover(DictionaryId::new("lookup-latency")?, &mdx_path)?;
    let should_build_index = key_index_path.is_some();
    let started = Instant::now();
    let dictionary = match key_index_path {
        Some(index_path) => MdictDictionary::open_with_key_index(source, index_path)?,
        None => MdictDictionary::open(source)?,
    };
    println!(
        "open_ms={} title={} path={}",
        started.elapsed().as_millis(),
        dictionary.metadata().title,
        mdx_path.display(),
    );

    if should_build_index {
        let started = Instant::now();
        let built = dictionary.ensure_key_index()?;
        println!("index_ms={} built={built}", started.elapsed().as_millis(),);
    }

    for query in queries {
        for pass in 1..=2 {
            let started = Instant::now();
            let article = dictionary.lookup_first(&query)?;
            println!(
                "query={query:?} pass={pass} elapsed_ms={} found={} html_bytes={}",
                started.elapsed().as_millis(),
                article.is_some(),
                article.as_ref().map_or(0, |article| article.html.len()),
            );
        }
    }
    Ok(())
}
