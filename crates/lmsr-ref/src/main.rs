//! `lmsr-ref replay <b> <op>...`: the differential fuzz's oracle (see `lmsr_ref::replay`).
//! Prints `0x`-hex ABI words on success; a refusal goes to stderr with exit status 2.

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match lmsr_ref::replay::replay(&args) {
        Ok(words) => {
            println!("{}", lmsr_ref::replay::abi_encode_words(&words));
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("lmsr-ref: {error}");
            ExitCode::from(2)
        }
    }
}
