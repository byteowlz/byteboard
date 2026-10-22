use crate::compile::{build, parse_combined, BuildOptions};
use crate::dict::Dict;
use crate::engine::{apply_case, Context, Engine, Kind};

const ENGLISH: &str = "\
dictionary=main:en,locale=en_US,description=test
 word=the,f=222
  bigram=world,f=2
  bigram=same,f=1
 word=they,f=200
 word=there,f=198
 word=these,f=180
 word=hello,f=160
 word=help,f=170
 word=world,f=150
 word=same,f=140
 word=keyboard,f=120
 word=damn,f=190,possibly_offensive=true
 word=shortcutonly,f=10,not_a_word=true
";

const GERMAN: &str = "\
dictionary=main:de,locale=de,description=test
 word=der,f=254
  bigram=Stadt,f=1
  bigram=Welt,f=2
 word=Haus,f=200
 word=schön,f=190
 word=schon,f=185
 word=Stadt,f=170
 word=Welt,f=160
 word=Hausaufgabe,f=120
";

fn dict(source: &str) -> Dict {
    let parsed = parse_combined(source);
    Dict::from_bytes(build(&parsed.locale, parsed.words, &BuildOptions::default())).expect("valid dictionary")
}

fn engine(sources: &[&str]) -> Engine {
    let mut engine = Engine::new();
    for source in sources {
        engine.add(dict(source));
    }
    engine
}

fn words(engine: &Engine, before: &str) -> Vec<String> {
    engine.suggest(before, 3).into_iter().map(|s| s.word).collect()
}

#[test]
fn parse_reads_locale_flags_and_skips_not_a_word() {
    let parsed = parse_combined(ENGLISH);
    assert_eq!(parsed.locale, "en_US");
    assert!(parsed.words.iter().all(|w| w.display != "shortcutonly"));
    let damn = parsed.words.iter().find(|w| w.display == "damn").unwrap();
    assert!(damn.nosuggest);
    let the = parsed.words.iter().find(|w| w.display == "the").unwrap();
    assert_eq!(the.bigrams, vec![("world".to_string(), 2), ("same".to_string(), 1)]);
}

#[test]
fn round_trip_keeps_counts_and_locale() {
    let d = dict(ENGLISH);
    assert_eq!(d.locale(), "en_US");
    // ten words; `shortcutonly` is not_a_word and dropped.
    assert_eq!(d.word_count(), 10);
}

#[test]
fn completions_come_out_in_frequency_order() {
    let d = dict(ENGLISH);
    let got: Vec<&str> = d.completions("th", 4).into_iter().map(|(e, _)| d.display(e)).collect();
    assert_eq!(got, vec!["the", "they", "there", "these"]);
}

#[test]
fn nosuggest_words_are_never_offered_but_still_known() {
    let d = dict(ENGLISH);
    let got: Vec<&str> = d.completions("da", 5).into_iter().map(|(e, _)| d.display(e)).collect();
    assert!(got.is_empty(), "offered {got:?}");
    assert!(!d.exact("damn").is_empty());
}

#[test]
fn bigram_rank_one_comes_first() {
    // The source lists world (rank 2) before same (rank 1); rank 1 must win.
    let e = engine(&[ENGLISH]);
    assert_eq!(words(&e, "the "), vec!["same", "world"]);
}

#[test]
fn transposition_is_one_cheap_correction() {
    let e = engine(&[ENGLISH]);
    let got = e.suggest("teh", 3);
    assert_eq!(got.first().map(|s| s.word.as_str()), Some("the"), "{got:?}");
    assert_eq!(got[0].kind, Kind::Correction);
}

#[test]
fn transposition_survives_when_the_typo_is_also_a_valid_prefix() {
    // "teh" starts "Tehran", which limits it to one cheap edit; a swap must still fit.
    const WITH_CITY: &str = "\
dictionary=main:en,locale=en_US,description=test
 word=the,f=222
 word=Tehran,f=60
";
    let e = engine(&[WITH_CITY]);
    assert_eq!(words(&e, "teh").first().map(String::as_str), Some("the"));
}

#[test]
fn accent_variant_of_a_common_word_competes_with_completions() {
    const SPANISH: &str = "\
dictionary=main:es,locale=es,description=test
 word=está,f=220
 word=esta,f=210
 word=estado,f=200
 word=estaba,f=190
";
    let e = engine(&[SPANISH]);
    assert!(words(&e, "esta").contains(&"está".to_string()));
}

#[test]
fn case_variants_share_one_slot() {
    const BOTH: &str = "\
dictionary=main:de,locale=de,description=test
 word=schön,f=190
 word=Schön,f=80
 word=schien,f=150
";
    let e = engine(&[BOTH]);
    let got = words(&e, "schoen");
    let lowered: Vec<String> = got.iter().map(|w| w.to_lowercase()).collect();
    assert_eq!(lowered.iter().filter(|w| *w == "schön").count(), 1, "{got:?}");
}

#[test]
fn neighbour_key_typo_corrects() {
    // 'j' sits next to 'k' on QWERTY.
    let e = engine(&[ENGLISH]);
    assert!(words(&e, "jeyboard").contains(&"keyboard".to_string()));
}

#[test]
fn umlaut_is_a_cheap_substitution() {
    let e = engine(&[GERMAN]);
    let got = words(&e, "schoen");
    assert!(got.contains(&"schön".to_string()) || got.contains(&"schon".to_string()), "{got:?}");
    let d = dict(GERMAN);
    let cheap = |typed: char, wanted: char| if typed == wanted { 0 } else if typed == 'o' && wanted == 'ö' { 1 } else { 2 };
    let found = d.corrections(&['s', 'c', 'h', 'o', 'n'], 1, &cheap);
    assert!(found.iter().any(|&(e, _)| d.display(e) == "schön"));
}

#[test]
fn german_noun_keeps_its_capital() {
    let e = engine(&[GERMAN]);
    assert_eq!(words(&e, "haus").first().map(String::as_str), Some("Haus"));
}

#[test]
fn typed_capital_is_carried_over() {
    let e = engine(&[ENGLISH]);
    let got = words(&e, "Hel");
    assert_eq!(got.first().map(String::as_str), Some("Help"), "{got:?}");
    assert!(got.contains(&"Hello".to_string()));
    assert_eq!(apply_case("HE", "hello"), "HELLO");
    assert_eq!(apply_case("he", "Haus"), "Haus");
}

#[test]
fn languages_are_searched_together() {
    let e = engine(&[ENGLISH, GERMAN]);
    assert!(words(&e, "wel").contains(&"Welt".to_string()));
    assert!(words(&e, "wor").contains(&"world".to_string()));
    assert_eq!(words(&e, "der "), vec!["Stadt", "Welt"]);
}

#[test]
fn exact_word_is_not_suggested_back() {
    let e = engine(&[ENGLISH]);
    assert!(!words(&e, "help").contains(&"help".to_string()));
}

#[test]
fn no_next_word_after_a_sentence_ends() {
    let e = engine(&[ENGLISH]);
    assert!(words(&e, "I saw the. ").is_empty());
    assert!(words(&e, "").is_empty());
}

#[test]
fn identifiers_and_triggers_are_left_alone() {
    let e = engine(&[ENGLISH]);
    for before in [":the", "user@the", "path/the", "#the"] {
        assert!(words(&e, before).is_empty(), "suggested for {before}");
    }
}

#[test]
fn context_split() {
    assert_eq!(
        Context::parse("say hel"),
        Context {
            current: "hel".into(),
            previous: Some("say".into()),
            suppressed: false,
            recent: vec!["say".into()],
        }
    );
    assert_eq!(Context::parse("Hallo, ").previous, None);
    assert_eq!(Context::parse("one\n").previous, None);
}

#[test]
fn ascii_spelling_of_umlauts_corrects_cheaply() {
    // Even when "schoen" is also the start of some rare word, "schön" must win.
    const WITH_NAME: &str = "\
dictionary=main:de,locale=de,description=test
 word=schön,f=190
 word=Schoenberg,f=60
 word=Straße,f=170
";
    let e = engine(&[WITH_NAME]);
    assert_eq!(words(&e, "schoen").first().map(String::as_str), Some("schön"));
    assert_eq!(words(&e, "Strasse").first().map(String::as_str), Some("Straße"));
}

#[test]
fn a_known_word_can_still_get_its_accents_back() {
    // "manana" exists in the English list; "mañana" must still be offered.
    const MIXED: &str = "\
dictionary=main:es,locale=es,description=test
 word=mañana,f=200
 word=manana,f=40
 word=mamada,f=150
";
    let e = engine(&[MIXED]);
    let got = words(&e, "manana");
    assert_eq!(got.first().map(String::as_str), Some("mañana"), "{got:?}");
    // Same-letters-only: a different word one edit away is still not offered.
    assert!(!got.contains(&"mamada".to_string()), "{got:?}");
}

#[test]
fn a_valid_prefix_gets_one_cheap_edit_not_two() {
    // "graci" is the start of "gracias"; two neighbour-key swaps would reach "track".
    const WORDS: &str = "\
dictionary=main:x,locale=x,description=test
 word=gracias,f=150
 word=track,f=200
";
    let e = engine(&[WORDS]);
    let got = words(&e, "graci");
    assert_eq!(got, vec!["gracias"]);
}

#[test]
fn a_correct_word_is_not_corrected() {
    // "Haus" is a word; it must not be offered "aus"-style corrections.
    let e = engine(&[GERMAN]);
    assert!(e.suggest("Haus", 3).iter().all(|s| s.kind != Kind::Correction));
}

#[test]
fn the_language_of_the_sentence_wins() {
    // Both lists know "der"; in a German sentence German followers must lead.
    const ENGLISH_WITH_DER: &str = "\
dictionary=main:en,locale=en_US,description=test
 word=der,f=40
  bigram=Hoff,f=1
 word=Hoff,f=30
 word=Wir,f=10
";
    let e = engine(&[ENGLISH_WITH_DER, GERMAN]);
    assert_eq!(words(&e, "Haus der ").first().map(String::as_str), Some("Stadt"));
}

#[test]
fn corrupt_input_is_rejected_not_trusted() {
    assert!(Dict::from_bytes(vec![0; 10]).is_err());
    let mut bytes = build("x", parse_combined(ENGLISH).words, &BuildOptions::default());
    bytes.truncate(100);
    assert!(Dict::from_bytes(bytes).is_err());
}
