package main

Token_Kind :: enum u8 {
    None = 0,
    EOF,
    Invalid,
    Error,

    String_Literal,
    String_Raw, // maybe multiline

    Comment,
    Comment_Multiline,

    Identifier,
    Operation,
    Punctuation,

    Constant,
    Decorator,
    Directive,
    Enum_Variant,
    Function,
    Keyword,
    Note,
    Number,
    Type,
    Variable,

    Builtin_Function,
    Builtin_Variable,

    Bragi_Header1,
    Bragi_Header2,
    Bragi_Header3,
    Bragi_Header4,
    Bragi_Header5,
}

Operation :: enum {
    Ampersand, Ampersand_Ampersand, Ampersand_Equal, Ampersand_Tilde, Ampersand_Tilde_Equal,
    Asterisk, Asterisk_Equal, Bang, Bang_Equal, Colon, Colon_Colon, Colon_Equal,
    Equal, Equal_Equal, Equal_Greater, Minus, Minus_Equal, Minus_Greater, Plus, Plus_Equal,
    Slash, Slash_Equal, Greater, Greater_Equal, Greater_Greater, Greater_Greater_Equal,
    Backtick, Less, Less_Equal, Less_Less, Less_Less_Equal, Dot_Dot_Equal, Dot_Dot_Less,
    Percent, Percent_Equal, Percent_Percent, Percent_Percent_Equal,
    Pipe, Pipe_Equal, Pipe_Pipe, Pipe_Pipe_Equal, Tilde, Tilde_Equal,
}

Punctuation :: enum {
    Brace_Left,   Brace_Right,
    Bracket_Left, Bracket_Right,
    Paren_Left,   Paren_Right,
    Dot, Dot_Dot,

    At, Caret, Dollar_Sign, Comma,
    Question, Newline, Semicolon, Tab,
}

Basic_Token :: struct {
    kind: Token_Kind,
    start, length: int,
    text: string,
}

Indentation_Token :: struct {
    action: enum u8 {
        None, // ensure we at least register one token
        Close,
        Open,
        // tokens that will make the line continue in the next line
        // and want some indentation, but that indentation not to carry over.
        Line_Continuation,
    },
    kind: enum u8 {
        Unimportant, // just a default
        Brace,
        Bracket,
        Paren,
    },
}

Tokenizer :: struct {
    starting_offset: int,
    buf: string,
    offset: int,
    whitespace_to_left: bool,
}

save_token :: proc(buffer: ^Buffer, t: ^Tokenizer, token: Basic_Token) {
    start := t.starting_offset + token.start
    end := start + token.length
    for index in start..<end do assign_at(&buffer.tokens, index, token.kind)
}

skip_whitespaces :: proc(t: ^Tokenizer) {
    old_offset := t.offset
    for !is_eof(t) && is_whitespace(t) { t.offset += 1 }
    t.whitespace_to_left = t.offset != old_offset
}

peek_byte :: proc(t: ^Tokenizer, index_offset: int) -> (b: byte, ok: bool) {
    if t.offset + index_offset < len(t.buf) do return t.buf[t.offset + index_offset], true
    return 0, false
}

read_word :: proc(t: ^Tokenizer) -> string {
    start := t.offset
    for !is_eof(t) && is_valid_word_component(t) do t.offset += 1
    end := t.offset
    return t.buf[start:end]
}

is_alpha :: proc(t: ^Tokenizer) -> bool {
    return is_alpha_lowercase(t) || is_alpha_uppercase(t)
}

is_alphanumeric :: proc(t: ^Tokenizer) -> bool {
    return is_alpha(t) || is_number(t)
}

is_alpha_lowercase :: proc(t: ^Tokenizer) -> bool {
    b := t.buf[t.offset]
    return b >= 'a' && b <= 'z'
}

is_alpha_uppercase :: proc(t: ^Tokenizer) -> bool {
    b := t.buf[t.offset]
    return b >= 'A' && b <= 'Z'
}

is_char :: proc(t: ^Tokenizer, b: byte) -> bool {
    return !is_eof(t) && t.buf[t.offset] == b
}

is_eof :: proc(t: ^Tokenizer) -> bool {
    return t.offset >= len(t.buf)
}

is_hex_prefix :: proc(t: ^Tokenizer) -> bool {
    return is_char(t, 'h') || is_char(t, 'x')
}

is_hex :: proc(t: ^Tokenizer) -> bool {
    b := t.buf[t.offset]
    return is_number(t) || (b >= 'a' && b <= 'f') || (b >= 'A' && b <= 'F')
}

is_newline :: proc(t: ^Tokenizer) -> bool {
    return t.buf[t.offset] == '\n'
}

is_number :: proc(t: ^Tokenizer) -> bool {
    b := t.buf[t.offset]
    return b >= '0' && b <= '9'
}

is_octal :: proc(t: ^Tokenizer) -> bool {
    return is_number(t) && t.buf[t.offset] < '8'
}

is_valid_word_component :: proc(t: ^Tokenizer) -> bool {
    return is_alpha(t) || is_number(t) || is_char(t, '_')
}

is_whitespace :: proc(t: ^Tokenizer) -> bool {
    b := t.buf[t.offset]
    return b == ' ' || b == '\t'
}
