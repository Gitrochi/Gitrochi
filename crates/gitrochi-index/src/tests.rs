use crate::query::{fts_match, parse, parse_time, Term};
use crate::text;

const NOW: i64 = 1_790_000_000;

#[test]
fn filters_quotes_and_shas_are_recognized() {
    let query = parse(
        r#"login "exact words" author:"Kim Ha" path:./src/app since:2026-01-31 merge:no 3f2a9c1 https://example.com"#,
        NOW,
    )
    .unwrap();
    assert_eq!(
        query.terms,
        vec![
            Term {
                text: "login".into(),
                phrase: false
            },
            Term {
                text: "exact words".into(),
                phrase: true
            },
            Term {
                text: "https://example.com".into(),
                phrase: false
            },
        ]
    );
    assert_eq!(query.authors, vec!["Kim Ha"]);
    assert_eq!(query.paths, vec!["src/app"]);
    assert_eq!(query.shas, vec!["3f2a9c1"]);
    assert_eq!(query.since, Some(1_769_817_600));
    assert_eq!(query.merge, Some(false));
}

#[test]
fn short_hex_words_stay_words() {
    let query = parse("cafe 12345", NOW).unwrap();
    assert!(query.shas.is_empty());
    assert_eq!(query.terms.len(), 2);
}

#[test]
fn bad_filters_are_errors() {
    assert_eq!(
        parse("since:yesterday", NOW).unwrap_err().code,
        "INVALID_ARGUMENT"
    );
    assert_eq!(
        parse("merge:maybe", NOW).unwrap_err().code,
        "INVALID_ARGUMENT"
    );
}

#[test]
fn match_expressions_quote_every_term() {
    let terms = vec![
        Term {
            text: "say \"hi\"".into(),
            phrase: true,
        },
        Term {
            text: "pars*".into(),
            phrase: false,
        },
        // Only punctuation: the tokenizer drops it, so it must not become an empty phrase.
        Term {
            text: "+++".into(),
            phrase: false,
        },
        Term {
            text: "OR".into(),
            phrase: false,
        },
    ];
    assert_eq!(
        fts_match(&terms).unwrap(),
        r#""say ""hi""" AND "pars"* AND "OR"*"#
    );
    assert_eq!(
        fts_match(&[Term {
            text: "...".into(),
            phrase: false
        }]),
        None
    );
}

#[test]
fn times_parse_dates_relative_and_seconds() {
    assert_eq!(parse_time("1970-01-01", NOW, false).unwrap(), 0);
    assert_eq!(parse_time("2000-03-01", NOW, false).unwrap(), 951_868_800);
    assert_eq!(parse_time("2024-02-29", NOW, true).unwrap(), 1_709_251_200);
    assert_eq!(parse_time("@42", NOW, false).unwrap(), 42);
    assert_eq!(parse_time("2w", NOW, false).unwrap(), NOW - 14 * 86_400);
    assert!(parse_time("2024-13-01", NOW, false).is_err());
}

#[test]
fn the_linked_tokenizer_is_the_cpp_one() {
    let tokens: Vec<String> = text::tokenize("RepoStore 로그인", false)
        .into_iter()
        .map(|t| t.text)
        .collect();
    assert_eq!(
        tokens,
        [
            "repostore",
            "repo",
            "store",
            "로그",
            "로",
            "그인",
            "그",
            "인"
        ]
    );
    assert!(text::version().starts_with("gitrochi-text "));
}
