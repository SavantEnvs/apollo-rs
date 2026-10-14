//! Known-answer probe for mayhem/test.sh: drives the real apollo-parser API on fixed inputs and
//! prints one `KAT<n> ...` line per assertion plus a final `KAT OK`. A neutered or missing
//! binary prints nothing, so test.sh fails on every missing line.
use apollo_parser::ast::{AstNode, StringValue};
use apollo_parser::{Lexer, Parser, TokenKind};

const VALID_QUERY: &str = "query Q($a: Int) {\n  hello(x: \"w\\u006Frld\")\n  count\n}\n";

fn unescaped_strings(src: &str) -> Vec<String> {
    let doc = Parser::new(src).parse().document();
    doc.syntax()
        .descendants()
        .filter_map(StringValue::cast)
        .map(|s| String::from(&s))
        .collect()
}

fn main() {
    let mut failed = false;

    let n_errors = Parser::new(VALID_QUERY).parse().errors().len();
    println!("KAT1 parser_errors={n_errors}");
    if n_errors != 0 {
        eprintln!("KAT1 FAILED: expected 0 parser errors, got {n_errors}");
        failed = true;
    }

    let strings = unescaped_strings(VALID_QUERY);
    println!("KAT2 strings={strings:?}");
    if strings != ["world"] {
        eprintln!("KAT2 FAILED: expected [\"world\"], got {strings:?}");
        failed = true;
    }

    let (tokens, errors) = Lexer::new("query { a }").lex();
    let words: Vec<&str> = tokens
        .iter()
        .filter(|t| !matches!(t.kind(), TokenKind::Whitespace | TokenKind::Eof))
        .map(|t| t.data())
        .collect();
    println!("KAT3 tokens={} errors={}", words.join(" "), errors.len());
    if words != ["query", "{", "a", "}"] || !errors.is_empty() {
        eprintln!("KAT3 FAILED: got {words:?} with {} errors", errors.len());
        failed = true;
    }

    let (_, errors) = Lexer::new("\"").lex();
    let message = errors.first().map(|e| e.message()).unwrap_or("");
    println!("KAT4 unterminated={message}");
    if errors.len() != 1 || message != "unexpected end of data while lexing string value" {
        eprintln!("KAT4 FAILED: got {} errors, first {message:?}", errors.len());
        failed = true;
    }

    if failed {
        eprintln!("KAT FAILED");
        std::process::exit(1);
    }
    println!("KAT OK");
}
