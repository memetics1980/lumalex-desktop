use dictionary_core::{DictionaryId, DictionarySource, MdictDictionary};
use std::collections::BTreeSet;
use std::env;

fn main() {
    let (Some(mdx_path), Some(query)) = (env::args().nth(1), env::args().nth(2)) else {
        eprintln!(
            "Usage: cargo run -p dictionary-core --example article_assets -- <dictionary.mdx> <query>"
        );
        std::process::exit(2);
    };
    let source = DictionarySource::discover(
        DictionaryId::new("asset-probe").expect("fixed dictionary identifier is valid"),
        mdx_path,
    )
    .unwrap_or_else(|error| exit_with_error("open dictionary source", error));
    let dictionary =
        MdictDictionary::open(source).unwrap_or_else(|error| exit_with_error("open MDX", error));
    let result = dictionary
        .lookup(&query)
        .unwrap_or_else(|error| exit_with_error("look up entry", error));
    let Some(article) = result.articles.first() else {
        println!("No matching entry.");
        return;
    };

    let assets = collect_asset_references(&article.html);
    println!("Found {} resource reference(s).", assets.len());
    for asset in assets {
        println!("- {asset}");
    }
}

fn collect_asset_references(html: &str) -> BTreeSet<String> {
    let mut assets = BTreeSet::new();
    for marker in ["src=\"", "href=\"", "src='", "href='"] {
        let quote = marker.chars().last().expect("marker ends with a quote");
        let mut remainder = html;
        while let Some(index) = remainder.find(marker) {
            remainder = &remainder[index + marker.len()..];
            let Some(end) = remainder.find(quote) else {
                break;
            };
            let value = &remainder[..end];
            if is_asset_reference(value) {
                assets.insert(value.to_owned());
            }
            remainder = &remainder[end + quote.len_utf8()..];
        }
    }
    assets
}

fn is_asset_reference(value: &str) -> bool {
    value.contains("://")
        || value.ends_with(".css")
        || value.ends_with(".gif")
        || value.ends_with(".jpg")
        || value.ends_with(".mp3")
        || value.ends_with(".png")
}

fn exit_with_error(context: &str, error: impl std::fmt::Display) -> ! {
    eprintln!("Could not {context}: {error}");
    std::process::exit(1);
}
