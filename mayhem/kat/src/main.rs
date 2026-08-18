//! Known-answer probe for the apollo-rs commit-image oracle (mayhem/test.sh).
//!
//! Drives the real apollo-parser / apollo-compiler API against fixed inputs and prints one
//! `KAT<n> ...` line per assertion plus a final `KAT OK` marker. Every assertion is
//! unconditional: any mismatch (or a missing/neutered binary, which prints nothing before the
//! sabotage shim `_exit(0)`s the process) fails `test.sh`.
use apollo_compiler::coordinate::SchemaCoordinate;
use apollo_compiler::Schema;
use apollo_parser::Parser;
use std::str::FromStr;

const VALID_SCHEMA: &str = "type Query {\n  hello: String\n  count: Int\n}\n\nschema {\n  query: Query\n}\n";
const INVALID_SCHEMA: &str = "type Query { hello: NoSuchType }\nschema { query: Query }\n";

fn main() {
    let mut failed = false;

    // KAT1: apollo-parser lexes+parses a fixed, syntactically valid document with zero errors.
    let tree = Parser::new(VALID_SCHEMA).parse();
    let n_errors = tree.errors().count();
    println!("KAT1 parser_errors={n_errors}");
    if n_errors != 0 {
        eprintln!("KAT1 FAILED: expected 0 parser errors, got {n_errors}");
        failed = true;
    }

    // KAT2: apollo-compiler validates the same schema and reports the exact field count.
    match Schema::parse_and_validate(VALID_SCHEMA, "kat_valid.graphql") {
        Ok(schema) => {
            let n_fields = schema
                .get_object("Query")
                .map(|o| o.fields.len())
                .unwrap_or(0);
            println!("KAT2 query_fields={n_fields}");
            if n_fields != 2 {
                eprintln!("KAT2 FAILED: expected 2 fields on Query, got {n_fields}");
                failed = true;
            }
        }
        Err(e) => {
            println!("KAT2 query_fields=ERROR");
            eprintln!("KAT2 FAILED: valid schema rejected: {e:?}");
            failed = true;
        }
    }

    // KAT3: apollo-compiler REJECTS a schema referencing an undefined type.
    match Schema::parse_and_validate(INVALID_SCHEMA, "kat_invalid.graphql") {
        Ok(_) => {
            println!("KAT3 bad_schema=ACCEPTED");
            eprintln!("KAT3 FAILED: invalid schema was accepted");
            failed = true;
        }
        Err(_) => {
            println!("KAT3 bad_schema=REJECTED");
        }
    }

    // KAT4: SchemaCoordinate parses and round-trips to the exact same string.
    match SchemaCoordinate::from_str("Query.hello") {
        Ok(coord) => {
            let rendered = coord.to_string();
            println!("KAT4 coordinate={rendered}");
            if rendered != "Query.hello" {
                eprintln!("KAT4 FAILED: expected 'Query.hello', got '{rendered}'");
                failed = true;
            }
        }
        Err(e) => {
            println!("KAT4 coordinate=ERROR");
            eprintln!("KAT4 FAILED: valid coordinate rejected: {e:?}");
            failed = true;
        }
    }

    if failed {
        eprintln!("KAT FAILED");
        std::process::exit(1);
    }
    println!("KAT OK");
}
