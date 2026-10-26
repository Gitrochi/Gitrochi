//! The gitch-flow executable. People and AI agents call it through `gitch flow …` and `gitch test …`; the apps use the same JSON contract.

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let code = gitch_flow::cli::main(args);
    std::process::exit(code);
}
