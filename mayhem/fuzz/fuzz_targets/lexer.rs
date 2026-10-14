#![no_main]
use apollo_parser::ast::{AstNode, StringValue};
use apollo_parser::{Lexer, Parser};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &str| {
    let _ = Lexer::new(data).lex();

    let tree = Parser::new(data).parse();
    let doc = tree.document();
    for node in doc.syntax().descendants() {
        if let Some(string) = StringValue::cast(node) {
            let _ = String::from(&string);
        }
    }
});
