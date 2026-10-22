//! bbdict — compile, inspect and benchmark byteboard dictionaries.
//!
//! ```text
//! bbdict compile <input.combined> <output.bbd> [--max-words N]
//! bbdict suggest <a.bbd> [b.bbd ...] -- <text before cursor>
//! bbdict bench   <a.bbd> [b.bbd ...]
//! ```

use std::path::Path;
use std::process::ExitCode;
use std::time::Instant;

use byteboard_core::compile::{build, parse_combined, BuildOptions};
use byteboard_core::{Dict, Engine};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("compile") => compile(&args[1..]),
        Some("suggest") => suggest(&args[1..]),
        Some("bench") => bench(&args[1..]),
        _ => Err("usage: bbdict compile|suggest|bench ... (see source header)".to_string()),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("bbdict: {message}");
            ExitCode::FAILURE
        }
    }
}

fn compile(args: &[String]) -> Result<(), String> {
    let mut positional = Vec::new();
    let mut options = BuildOptions::default();
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        if arg == "--max-words" {
            let value = iter.next().ok_or("--max-words needs a value")?;
            options.max_words = value.parse().map_err(|_| format!("bad --max-words {value}"))?;
        } else {
            positional.push(arg.as_str());
        }
    }
    let [input, output] = positional[..] else { return Err("compile <input.combined> <output.bbd>".into()) };
    let started = Instant::now();
    let text = std::fs::read_to_string(input).map_err(|e| format!("{input}: {e}"))?;
    let parsed = parse_combined(&text);
    let source_words = parsed.words.len();
    let source_bigrams: usize = parsed.words.iter().map(|w| w.bigrams.len()).sum();
    let bytes = build(&parsed.locale, parsed.words, &options);
    std::fs::write(output, &bytes).map_err(|e| format!("{output}: {e}"))?;
    let dict = Dict::from_bytes(bytes).map_err(|e| e.to_string())?;
    println!(
        "{output}: locale {}  words {} of {source_words}  next-word pairs {} of {source_bigrams}  {:.1} MB  {:.1}s",
        dict.locale(),
        dict.word_count(),
        dict.bigram_count(),
        std::fs::metadata(output).map(|m| m.len()).unwrap_or(0) as f64 / 1_048_576.0,
        started.elapsed().as_secs_f64(),
    );
    Ok(())
}

fn engine_from(paths: &[String]) -> Result<Engine, String> {
    let mut engine = Engine::new();
    for path in paths {
        engine.add(Dict::open(Path::new(path)).map_err(|e| format!("{path}: {e}"))?);
    }
    Ok(engine)
}

fn suggest(args: &[String]) -> Result<(), String> {
    let split = args.iter().position(|a| a == "--").ok_or("suggest <dicts...> -- <text>")?;
    let engine = engine_from(&args[..split])?;
    let before = args[split + 1..].join(" ");
    for s in engine.suggest(&before, 3) {
        println!("{}\t{}\t{}", s.kind.code(), s.score, s.word);
    }
    Ok(())
}

fn bench(args: &[String]) -> Result<(), String> {
    let engine = engine_from(args)?;
    // Mid-word, typo, next-word and capitalisation cases in both languages.
    let inputs = [
        "t", "th", "the", "hel", "keyb", "teh", "recieve", "jeyboard", "the ",
        "d", "di", "Haus", "haus", "schoen", "Strasse", "Entschuldigun", "der ", "ich ",
        "Wir sehen uns morgen in der St", "I will be there in a minu",
    ];
    // Warm once so the numbers measure lookup, not first page faults.
    for input in inputs {
        let _ = engine.suggest(input, 3);
    }
    let mut worst = 0.0f64;
    let mut total = 0.0f64;
    for input in inputs {
        let started = Instant::now();
        let list = engine.suggest(input, 3);
        let ms = started.elapsed().as_secs_f64() * 1000.0;
        worst = worst.max(ms);
        total += ms;
        let shown: Vec<String> = list.iter().map(|s| format!("{}:{}", s.kind.code(), s.word)).collect();
        println!("{ms:7.3} ms  {:<34} {}", format!("{input:?}"), shown.join("  "));
    }
    println!("mean {:.3} ms, worst {:.3} ms over {} inputs", total / inputs.len() as f64, worst, inputs.len());
    Ok(())
}
