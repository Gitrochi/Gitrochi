// Search tokenizer shared by the repository index (through Rust) and the SQLite extension.
//
// Built without exceptions, RTTI or heap allocation, so the static library the apps
// link needs no C++ runtime: everything works on the caller's buffer and a fixed
// stack buffer per token.

#include "gitrochi_text.h"

#include <cstddef>
#include <cstdint>

namespace {

// Whole identifiers longer than this are not indexed as one token (their parts still are).
constexpr int kMaxTokenBytes = 128;
// Bounds the colocated parts of one identifier, so base64 or minified text stays cheap.
constexpr int kMaxParts = 32;

struct CodePoint {
    uint32_t value;
    int size;  // 0 marks an invalid byte, which callers skip as a separator
};

inline bool continuation(unsigned char byte) noexcept { return (byte & 0xC0) == 0x80; }

CodePoint decode(const unsigned char *s, int available) noexcept {
    const unsigned char lead = s[0];
    if (lead < 0x80) return {lead, 1};
    if (lead < 0xC2) return {0, 0};
    if (lead < 0xE0) {
        if (available < 2 || !continuation(s[1])) return {0, 0};
        return {(uint32_t(lead & 0x1F) << 6) | (s[1] & 0x3F), 2};
    }
    if (lead < 0xF0) {
        if (available < 3 || !continuation(s[1]) || !continuation(s[2])) return {0, 0};
        const uint32_t value = (uint32_t(lead & 0x0F) << 12) | (uint32_t(s[1] & 0x3F) << 6) | (s[2] & 0x3F);
        if (value < 0x800 || (value >= 0xD800 && value <= 0xDFFF)) return {0, 0};
        return {value, 3};
    }
    if (lead < 0xF5) {
        if (available < 4 || !continuation(s[1]) || !continuation(s[2]) || !continuation(s[3])) return {0, 0};
        const uint32_t value = (uint32_t(lead & 0x07) << 18) | (uint32_t(s[1] & 0x3F) << 12) |
                               (uint32_t(s[2] & 0x3F) << 6) | (s[3] & 0x3F);
        if (value < 0x10000 || value > 0x10FFFF) return {0, 0};
        return {value, 4};
    }
    return {0, 0};
}

int encode(uint32_t value, char *out) noexcept {
    if (value < 0x80) {
        out[0] = char(value);
        return 1;
    }
    if (value < 0x800) {
        out[0] = char(0xC0 | (value >> 6));
        out[1] = char(0x80 | (value & 0x3F));
        return 2;
    }
    if (value < 0x10000) {
        out[0] = char(0xE0 | (value >> 12));
        out[1] = char(0x80 | ((value >> 6) & 0x3F));
        out[2] = char(0x80 | (value & 0x3F));
        return 3;
    }
    out[0] = char(0xF0 | (value >> 18));
    out[1] = char(0x80 | ((value >> 12) & 0x3F));
    out[2] = char(0x80 | ((value >> 6) & 0x3F));
    out[3] = char(0x80 | (value & 0x3F));
    return 4;
}

inline bool between(uint32_t c, uint32_t low, uint32_t high) noexcept { return c >= low && c <= high; }
inline bool even(uint32_t c) noexcept { return (c & 1) == 0; }

// Simple lower-casing for Latin (with Vietnamese), Greek, Cyrillic and Armenian, plus
// full-width ASCII, which CJK text often uses for Latin letters and digits.
uint32_t fold(uint32_t c) noexcept {
    if (c < 0x80) return between(c, 'A', 'Z') ? c + 0x20 : c;
    if (between(c, 0xFF21, 0xFF3A)) return 'a' + (c - 0xFF21);
    if (between(c, 0xFF41, 0xFF5A)) return 'a' + (c - 0xFF41);
    if (between(c, 0xFF10, 0xFF19)) return '0' + (c - 0xFF10);
    if (between(c, 0x00C0, 0x00DE) && c != 0x00D7) return c + 0x20;
    if (between(c, 0x0100, 0x012F) || between(c, 0x0132, 0x0137) || between(c, 0x014A, 0x0177)) return even(c) ? c + 1 : c;
    if (c == 0x0130) return 'i';
    if (between(c, 0x0139, 0x0148) || between(c, 0x0179, 0x017E)) return even(c) ? c : c + 1;
    if (c == 0x0178) return 0x00FF;
    if (between(c, 0x01CD, 0x01DC)) return even(c) ? c : c + 1;
    if (between(c, 0x01DE, 0x01EF) || between(c, 0x01F8, 0x021F) || between(c, 0x0222, 0x0233)) return even(c) ? c + 1 : c;
    if (c == 0x0386) return 0x03AC;
    if (between(c, 0x0388, 0x038A)) return c + 0x25;
    if (c == 0x038C) return 0x03CC;
    if (between(c, 0x038E, 0x038F)) return c + 0x3F;
    if (between(c, 0x0391, 0x03A1) || between(c, 0x03A3, 0x03AB)) return c + 0x20;
    if (between(c, 0x0400, 0x040F)) return c + 0x50;
    if (between(c, 0x0410, 0x042F)) return c + 0x20;
    if (between(c, 0x0460, 0x0481) || between(c, 0x048A, 0x04BF) || between(c, 0x04D0, 0x052F)) return even(c) ? c + 1 : c;
    if (between(c, 0x04C1, 0x04CE)) return even(c) ? c : c + 1;
    if (between(c, 0x0531, 0x0556)) return c + 0x30;
    if (between(c, 0x1E00, 0x1E95) || between(c, 0x1EA0, 0x1EFF)) return even(c) ? c + 1 : c;
    return c;
}

enum Class : uint8_t { kSeparator, kLower, kUpper, kDigit, kUnderscore, kLetter, kMark, kCjk };

// Korean, Japanese and Chinese scripts: runs of these are indexed as overlapping pairs.
bool cjk(uint32_t c) noexcept {
    if (c < 0x1100) return false;
    if (c == 0x30FB) return false;  // katakana middle dot separates words
    return between(c, 0x1100, 0x11FF) || between(c, 0x2E80, 0x2FDF) || between(c, 0x3005, 0x3007) ||
           between(c, 0x3021, 0x3029) || between(c, 0x3031, 0x3035) || between(c, 0x303B, 0x303C) ||
           between(c, 0x3040, 0x30FF) || between(c, 0x3100, 0x312F) || between(c, 0x3130, 0x318F) ||
           between(c, 0x31A0, 0x31BF) || between(c, 0x31F0, 0x31FF) || between(c, 0x3400, 0x4DBF) ||
           between(c, 0x4E00, 0x9FFF) || between(c, 0xA960, 0xA97F) || between(c, 0xAC00, 0xD7A3) ||
           between(c, 0xD7B0, 0xD7FF) || between(c, 0xF900, 0xFAFF) || between(c, 0xFF66, 0xFF9F) ||
           between(c, 0xFFA0, 0xFFDC) || between(c, 0x1B000, 0x1B16F) || between(c, 0x20000, 0x2FA1F) ||
           between(c, 0x30000, 0x323AF);
}

bool cased(uint32_t c) noexcept {
    return between(c, 0x00C0, 0x024F) || between(c, 0x0370, 0x03FF) || between(c, 0x0400, 0x052F) ||
           between(c, 0x0531, 0x0587) || between(c, 0x1E00, 0x1EFF) || between(c, 0x1F00, 0x1FFF);
}

bool uncased_letter(uint32_t c) noexcept {
    return c == 0x00AA || c == 0x00BA || between(c, 0x05D0, 0x05EA) || between(c, 0x0620, 0x064A) ||
           between(c, 0x0671, 0x06D3) || between(c, 0x0900, 0x097F) || between(c, 0x0980, 0x09FF) ||
           between(c, 0x0E00, 0x0E7F) || between(c, 0x10A0, 0x10FF);
}

bool mark(uint32_t c) noexcept {
    return between(c, 0x0300, 0x036F) || between(c, 0x0483, 0x0489) || between(c, 0x1AB0, 0x1AFF) ||
           between(c, 0x1DC0, 0x1DFF) || between(c, 0x20D0, 0x20FF) || between(c, 0xFE20, 0xFE2F);
}

Class classify(uint32_t c) noexcept {
    if (c < 0x80) {
        if (between(c, 'a', 'z')) return kLower;
        if (between(c, 'A', 'Z')) return kUpper;
        if (between(c, '0', '9')) return kDigit;
        return c == '_' ? kUnderscore : kSeparator;
    }
    if (c == 0x00B5) return kLower;
    if (between(c, 0x00C0, 0x00FF)) return (c == 0x00D7 || c == 0x00F7) ? kSeparator : (fold(c) != c ? kUpper : kLower);
    if (between(c, 0xFF10, 0xFF19)) return kDigit;
    if (between(c, 0xFF21, 0xFF3A)) return kUpper;
    if (between(c, 0xFF41, 0xFF5A)) return kLower;
    if (cased(c)) return fold(c) != c ? kUpper : kLower;
    if (mark(c)) return kMark;
    if (cjk(c)) return kCjk;
    if (uncased_letter(c)) return kLetter;
    return kSeparator;
}

inline bool word(Class k) noexcept { return k == kLower || k == kUpper || k == kDigit || k == kUnderscore || k == kLetter || k == kMark; }
inline bool letter(Class k) noexcept { return k == kLower || k == kUpper || k == kLetter; }

struct Cursor {
    const unsigned char *text;
    int length;

    // Decodes at offset; invalid bytes come back as one-byte separators.
    CodePoint at(int offset) const noexcept {
        CodePoint point = decode(text + offset, length - offset);
        if (point.size == 0) return {0xFFFD, 1};
        return point;
    }
    Class kind(int offset) const noexcept {
        const CodePoint point = decode(text + offset, length - offset);
        return point.size == 0 ? kSeparator : classify(point.value);
    }
};

class Emitter {
  public:
    Emitter(void *context, gitrochi_token_fn emit) noexcept : context_(context), emit_(emit) {}

    // Folds text[start, end) and emits it. A token that does not fit is skipped, which
    // `emitted` reports; the return value is always the callback's.
    int folded(const Cursor &cursor, int start, int end, int flags, bool &emitted) noexcept {
        char buffer[kMaxTokenBytes];
        int size = 0;
        emitted = false;
        for (int offset = start; offset < end;) {
            const CodePoint point = cursor.at(offset);
            char bytes[4];
            const int count = encode(fold(point.value), bytes);
            if (size + count > kMaxTokenBytes) return 0;
            for (int i = 0; i < count; ++i) buffer[size++] = bytes[i];
            offset += point.size;
        }
        emitted = true;
        return emit_(context_, flags, buffer, size, start, end);
    }

    int raw(const Cursor &cursor, int start, int end, int flags) noexcept {
        return emit_(context_, flags, reinterpret_cast<const char *>(cursor.text) + start, end - start, start, end);
    }

  private:
    void *context_;
    gitrochi_token_fn emit_;
};

// Emits an identifier, then (for documents) its camelCase, snake_case and digit parts at
// the same position, so `response` finds `parseHTTPResponse` while phrases still line up.
int word_run(const Cursor &cursor, int start, int end, int mode, Emitter &emitter) noexcept {
    bool placed = false;
    int rc = emitter.folded(cursor, start, end, 0, placed);
    if (rc != 0 || mode == GITROCHI_TOKENIZE_QUERY) return rc;

    int part_start = -1, part_end = -1, part_points = 0, parts = 0;
    Class previous = kSeparator;
    auto close = [&]() noexcept -> int {
        int result = 0;
        const bool whole = part_start == start && part_end == end;
        if (part_start >= 0 && part_points >= 2 && !whole && parts < kMaxParts) {
            bool emitted = false;
            result = emitter.folded(cursor, part_start, part_end, placed ? GITROCHI_TOKEN_COLOCATED : 0, emitted);
            if (emitted) {
                placed = true;
                ++parts;
            }
        }
        part_start = -1;
        part_points = 0;
        return result;
    };

    for (int offset = start; offset < end;) {
        const CodePoint point = cursor.at(offset);
        const Class current = classify(point.value);
        const int next = offset + point.size;
        if (current == kUnderscore) {
            if ((rc = close()) != 0) return rc;
            previous = kUnderscore;
            offset = next;
            continue;
        }
        if (current == kMark) {
            if (part_start >= 0) part_end = next;
            offset = next;
            continue;
        }
        bool boundary = false;
        if (part_start >= 0) {
            if (previous == kLower && current == kUpper) {
                boundary = true;  // parse|Response
            } else if (previous == kUpper && current == kUpper && next < end && cursor.kind(next) == kLower) {
                boundary = true;  // HTTP|Response
            } else if ((previous == kDigit && letter(current)) || (letter(previous) && current == kDigit)) {
                boundary = true;  // sha|256
            }
        }
        if (boundary && (rc = close()) != 0) return rc;
        if (part_start < 0) part_start = offset;
        part_end = next;
        ++part_points;
        previous = current;
        offset = next;
    }
    return close();
}

// Overlapping two-character tokens; documents also carry each character at the same
// position, so one-character queries and queries ending a run still match.
int cjk_run(const Cursor &cursor, int start, int end, int mode, Emitter &emitter) noexcept {
    int previous_start = -1, previous_end = -1, characters = 0, rc = 0;
    for (int offset = start; offset < end;) {
        const CodePoint point = cursor.at(offset);
        const int next = offset + point.size;
        if (previous_start >= 0) {
            if ((rc = emitter.raw(cursor, previous_start, next, 0)) != 0) return rc;
            if (mode == GITROCHI_TOKENIZE_DOCUMENT &&
                (rc = emitter.raw(cursor, previous_start, previous_end, GITROCHI_TOKEN_COLOCATED)) != 0) {
                return rc;
            }
        }
        previous_start = offset;
        previous_end = next;
        ++characters;
        offset = next;
    }
    if (previous_start >= 0 && (mode == GITROCHI_TOKENIZE_DOCUMENT || characters == 1)) {
        return emitter.raw(cursor, previous_start, previous_end, 0);
    }
    return 0;
}

int length_of(const char *text) noexcept {
    int size = 0;
    while (text[size] != '\0') ++size;
    return size;
}

}  // namespace

extern "C" int gitrochi_tokenize(const char *text, int length, int mode, void *context, gitrochi_token_fn emit) {
    if (text == nullptr || emit == nullptr) return 0;
    if (length < 0) length = length_of(text);
    const Cursor cursor{reinterpret_cast<const unsigned char *>(text), length};
    Emitter emitter(context, emit);
    for (int offset = 0; offset < length;) {
        const CodePoint point = cursor.at(offset);
        const Class kind = classify(point.value);
        if (!word(kind) && kind != kCjk) {
            offset += point.size;
            continue;
        }
        const bool han = kind == kCjk;
        int end = offset + point.size;
        while (end < length) {
            const Class following = cursor.kind(end);
            if (han ? following != kCjk : !word(following)) break;
            end += cursor.at(end).size;
        }
        const int rc = han ? cjk_run(cursor, offset, end, mode, emitter) : word_run(cursor, offset, end, mode, emitter);
        if (rc != 0) return rc;
        offset = end;
    }
    return 0;
}

extern "C" const char *gitrochi_text_version(void) { return "gitrochi-text 1"; }
