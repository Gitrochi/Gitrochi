//! gitch-flow 실행 파일. 사람 · AI 는 `gitch flow …` · `gitch test …` 로 부르고, 앱은 같은 JSON 계약을 쓴다.

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let code = gitch_flow::cli::main(args);
    std::process::exit(code);
}
