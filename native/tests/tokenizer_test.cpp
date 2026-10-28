// Unit tests for the tokenizer (native/build.sh runs them). They link only
// tokenizer.cpp, so they also prove it builds without SQLite.

#include "gitrochi_text.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

struct Token {
    std::string text;
    int start;
    int end;
    bool colocated;
};

int failures = 0;

int collect(void *context, int flags, const char *token, int length, int start, int end) {
    static_cast<std::vector<Token> *>(context)->push_back(
        {std::string(token, size_t(length)), start, end, (flags & GITROCHI_TOKEN_COLOCATED) != 0});
    return 0;
}

std::vector<Token> tokens(const std::string &text, int mode = GITROCHI_TOKENIZE_DOCUMENT) {
    std::vector<Token> out;
    const int rc = gitrochi_tokenize(text.data(), int(text.size()), mode, &out, collect);
    if (rc != 0) {
        std::printf("FAIL tokenize returned %d for \"%s\"\n", rc, text.c_str());
        ++failures;
    }
    return out;
}

// Renders tokens as "text" or "+text" for colocated ones, separated by spaces.
std::string render(const std::vector<Token> &list) {
    std::string out;
    for (const Token &token : list) {
        if (!out.empty()) out += ' ';
        if (token.colocated) out += '+';
        out += token.text;
    }
    return out;
}

void expect(const char *name, const std::string &actual, const std::string &expected) {
    if (actual != expected) {
        std::printf("FAIL %s\n  expected: %s\n  actual:   %s\n", name, expected.c_str(), actual.c_str());
        ++failures;
    } else {
        std::printf("ok   %s\n", name);
    }
}

void expect_true(const char *name, bool value) {
    if (!value) {
        std::printf("FAIL %s\n", name);
        ++failures;
    } else {
        std::printf("ok   %s\n", name);
    }
}

// Every token's byte range must point back at the text it came from.
bool offsets_hold(const std::string &text, const std::vector<Token> &list, bool folded) {
    for (const Token &token : list) {
        if (token.start < 0 || token.end > int(text.size()) || token.start >= token.end) return false;
        const std::string source = text.substr(size_t(token.start), size_t(token.end - token.start));
        if (!folded && source != token.text) return false;
    }
    return true;
}

int stop_after_two(void *context, int, const char *, int, int, int) {
    int *count = static_cast<int *>(context);
    return ++*count == 2 ? 99 : 0;
}

}  // namespace

int main() {
    expect("words are lower-cased", render(tokens("Fix Login Bug")), "fix login bug");
    expect("camelCase and acronyms split in documents", render(tokens("parseHTTPResponse")),
           "parsehttpresponse +parse +http +response");
    expect("queries keep whole identifiers", render(tokens("parseHTTPResponse", GITROCHI_TOKENIZE_QUERY)),
           "parsehttpresponse");
    expect("snake_case parts", render(tokens("user_name")), "user_name +user +name");
    expect("letters and digits split", render(tokens("sha256sum")), "sha256sum +sha +256 +sum");
    expect("trailing acronym", render(tokens("parseJSON IOError")), "parsejson +parse +json ioerror +io +error");
    expect("one-letter parts are dropped", render(tokens("iOS")), "ios +os");
    expect("underscores around a word", render(tokens("__init__")), "__init__ +init");
    expect("paths split on separators", render(tokens("macos/Sources/Store/RepoStore+Search.swift")),
           "macos sources store repostore +repo +store search swift");

    const std::string korean = "로그인오류";
    const std::vector<Token> document = tokens(korean);
    expect("Korean documents get pairs and single characters", render(document),
           "로그 +로 그인 +그 인오 +인 오류 +오 류");
    expect_true("Korean offsets are byte ranges of the source", offsets_hold(korean, document, false));
    expect("Korean queries are pairs only", render(tokens("로그인", GITROCHI_TOKENIZE_QUERY)), "로그 그인");
    expect("a one-character query stays one token", render(tokens("인", GITROCHI_TOKENIZE_QUERY)), "인");
    expect("scripts split runs", render(tokens("로그인error 수정")), "로그 +로 그인 +그 인 error 수정 +수 정");
    expect("Japanese runs", render(tokens("テスト追加", GITROCHI_TOKENIZE_QUERY)), "テス スト ト追 追加");
    expect("Chinese runs", render(tokens("修复错误", GITROCHI_TOKENIZE_QUERY)), "修复 复错 错误");
    expect("katakana middle dot separates", render(tokens("ア・イ", GITROCHI_TOKENIZE_QUERY)), "ア イ");

    expect("Latin, Greek and Cyrillic fold", render(tokens("ÀÉÎ Straße ΑΒΓ Привет Ǎ Ạ")),
           "àéî straße αβγ привет ǎ ạ");
    expect("full-width letters and digits fold to ASCII", render(tokens("ＡＢＣ１２")), "abc12 +abc +12");
    expect("invalid UTF-8 separates", render(tokens(std::string("\xff\xfe" "abc\xc3", 6))), "abc");
    expect("emoji separates", render(tokens("fix\xF0\x9F\x90\x9B" "bug")), "fix bug");
    expect("empty text", render(tokens("")), "");

    const std::string mixed = "parseHTTPResponse ok";
    const std::vector<Token> parts = tokens(mixed);
    expect_true("part offsets cover their source", offsets_hold(mixed, parts, true) && parts[3].start == 9 &&
                                                       parts[3].end == 17 && parts.back().text == "ok");

    const std::string long_word(200, 'a');
    expect("an identifier over 128 bytes is skipped", render(tokens(long_word)), "");
    expect("parts of a long identifier remain", render(tokens(long_word + "_tail")), "tail");

    int count = 0;
    const int stopped = gitrochi_tokenize("one two three", -1, GITROCHI_TOKENIZE_QUERY, &count, stop_after_two);
    expect_true("a callback result stops tokenizing", stopped == 99 && count == 2);
    expect_true("version is set", std::strncmp(gitrochi_text_version(), "gitrochi-text ", 14) == 0);

    if (failures != 0) {
        std::printf("%d tokenizer test(s) failed\n", failures);
        return 1;
    }
    std::printf("all tokenizer tests passed\n");
    return 0;
}
