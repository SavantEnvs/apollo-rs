#![no_main]
use apollo_compiler::parser::Parser;
use libfuzzer_sys::fuzz_target;

// Arbitrary text through parse + schema build + full validation (type system and executable
// definitions): deep fragment chains and selection nesting reach the recursive validation walks.
fuzz_target!(|data: &str| {
    let _ = Parser::new().parse_mixed_validate(data, "fuzz.graphql");
});
