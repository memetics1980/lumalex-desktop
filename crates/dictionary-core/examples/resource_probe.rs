use dictionary_core::{DictionaryId, DictionarySource, MdictDictionary};
use mdictlib::MddFile;
use std::env;

fn main() {
    let Some(mdx_path) = env::args().nth(1) else {
        eprintln!(
            "Usage: cargo run -p dictionary-core --example resource_probe -- <dictionary.mdx>"
        );
        std::process::exit(2);
    };

    let source = DictionarySource::discover(
        DictionaryId::new("resource-probe").expect("fixed dictionary identifier is valid"),
        &mdx_path,
    )
    .unwrap_or_else(|error| exit_with_error("discover MDD sidecars", error));
    let dictionary = MdictDictionary::open(source)
        .unwrap_or_else(|error| exit_with_error("open dictionary", error));

    println!(
        "Discovered {} MDD volume(s).",
        dictionary.resource_paths().len()
    );
    let Some(first_mdd) = dictionary.resource_paths().first() else {
        return;
    };

    if let Some(resource_path) = env::args().nth(2) {
        let resource = dictionary
            .read_resource(&resource_path, 20 * 1024 * 1024)
            .unwrap_or_else(|error| exit_with_error("read resource", error));
        match resource {
            Some(resource) => println!(
                "Read resource {} ({} bytes).",
                resource.path,
                resource.bytes.len()
            ),
            None => println!("Resource {resource_path:?} was not found."),
        }
        return;
    }

    let mdd = MddFile::open(first_mdd).unwrap_or_else(|error| exit_with_error("open MDD", error));
    let mut fallback = None;
    let mut renderable = None;
    for key in mdd.keys() {
        let key = key.unwrap_or_else(|error| exit_with_error("read MDD index", error));
        if fallback.is_none() {
            fallback = Some(key.key().to_owned());
        }
        if is_renderable_resource(key.key()) {
            renderable = Some(key.key().to_owned());
            break;
        }
    }

    let Some(key) = renderable.or(fallback) else {
        println!("The first MDD volume contains no resources.");
        return;
    };

    let resource = dictionary
        .read_resource(&key, 20 * 1024 * 1024)
        .unwrap_or_else(|error| exit_with_error("read resource", error))
        .expect("the indexed resource should be readable");
    println!(
        "Read resource {} ({} bytes).",
        resource.path,
        resource.bytes.len()
    );
}

fn is_renderable_resource(key: &str) -> bool {
    let extension = key
        .rsplit('.')
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    matches!(
        extension.as_str(),
        "css" | "gif" | "jpeg" | "jpg" | "mp3" | "ogg" | "png" | "svg" | "wav" | "webp"
    )
}

fn exit_with_error(context: &str, error: impl std::fmt::Display) -> ! {
    eprintln!("Could not {context}: {error}");
    std::process::exit(1);
}
