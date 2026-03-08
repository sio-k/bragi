#+private file
package main

import "core:slice"

Nix_Tokenizer :: struct {
    using tokenizer: Tokenizer,
}

Token :: struct {
    using token: Basic_Token,

    variant: union {
        Operation,
        Punctuation,
    },
}

@(private)
tokenize_nix :: proc(buffer: ^Buffer, starting_offset := 0) {
    tokenizer: Nix_Tokenizer
    tokenizer.buf = buffer.text
    tokenizer.starting_offset = starting_offset

    for {
        token := get_next_token(&tokenizer)
        if token.kind == .EOF do break

        save_token(buffer, &tokenizer, token)
    }
}

get_next_token :: proc(t: ^Nix_Tokenizer) -> (token: Token) {
    skip_whitespaces(t)

    token.start = t.offset
    token.kind = .EOF
    if is_eof(t) do return

    if (is_alpha(t) || is_char(t, '_')) {
        parse_identifier(t, &token)
    } else if is_number(t) {
        parse_number(t, &token)
    } else {
        switch t.buf[t.offset] {
        case '\t': parse_tab(t, &token)

            // TODO TODO TODO other nix punctuation
            // TODO TODO TODO multiline string literals that are '' delimited
        case '\'':
            if len(t.buf) > t.offset + 1 {
                if t.buf[t.offset + 1] == '\'' {
                    t.offset += 1
                    parse_multiline_string(t, &token)
                } else {
                    parse_char_lit(t, &token)
                }
            }
        case '"':  parse_string_literal(t, &token)

        case '.':  token.kind = .Punctuation; token.variant = .Dot; t.offset += 1
        case ',':  token.kind = .Punctuation; token.variant = .Comma;         t.offset += 1
        case '{':  token.kind = .Punctuation; token.variant = .Brace_Left;    t.offset += 1
        case '}':  token.kind = .Punctuation; token.variant = .Brace_Right;   t.offset += 1
        case '[':  token.kind = .Punctuation; token.variant = .Bracket_Left;  t.offset += 1
        case ']':  token.kind = .Punctuation; token.variant = .Bracket_Right; t.offset += 1
        case '(':  token.kind = .Punctuation; token.variant = .Paren_Left;    t.offset += 1
        case ')':  token.kind = .Punctuation; token.variant = .Paren_Right;   t.offset += 1
        case '$':  token.kind = .Punctuation; token.variant = .Dollar_Sign;   t.offset += 1
        case '\n': token.kind = .Punctuation; token.variant = .Newline;       t.offset += 1
        case ';': token.kind = .Punctuation; token.variant = .Semicolon; t.offset += 1
        case '^': token.kind = .Punctuation; token.variant = .Caret; t.offset += 1
        case '~': token.kind = .Operation; token.variant = .Tilde; t.offset += 1
        case ':': token.kind = .Operation; token.variant = .Colon; t.offset += 1
        case '+': token.kind = .Operation; token.variant = .Plus; t.offset += 1
        case '*': token.kind = .Operation; token.variant = .Asterisk; t.offset += 1
        case '|': token.kind = .Operation; token.variant = .Pipe; t.offset += 1
        case '=': token.kind = .Operation; token.variant = .Equal; t.offset += 1
        case '!': token.kind = .Operation; token.variant = .Bang; t.offset += 1
        case '\\': token.kind = .Operation; token.variant = .Slash; t.offset += 1
        case '%': token.kind = .Operation; token.variant = .Percent; t.offset += 1
        case '@': token.kind = .Punctuation; token.variant = .At; t.offset += 1
        case '<': token.kind = .Operation; token.variant = .Less; t.offset += 1
        case '>': token.kind = .Operation; token.variant = .Greater; t.offset += 1
        case '/': token.kind = .Operation; token.variant = .Slash; t.offset += 1
        case '-': token.kind = .Operation; token.variant = .Minus; t.offset += 1
        case '&': token.kind = .Operation; token.variant = .Ampersand; t.offset += 1
        case '#': parse_comment(t, &token)
        case:
            token.kind = .Identifier; t.offset += 1
        }
    }

    token.length = t.offset - token.start

    return
}

parse_comment :: proc(t: ^Nix_Tokenizer, token: ^Token) {
    token.kind = .Comment
    t.offset += 1
    for !is_eof(t) && !is_newline(t) {
        t.offset += 1
    }
}

parse_number :: proc(t: ^Nix_Tokenizer, token: ^Token) {
    is_decimal_number_continuation :: proc(t: ^Nix_Tokenizer) -> bool {
        return is_number(t) || is_char(t, '.') || is_char(t, '-') ||
            is_char(t, 'e') || is_char(t, 'E') || is_char(t, 'i') ||
            is_char(t, 'j') || is_char(t, 'k')
    }

    token.kind = .Number
    t.offset += 1
    if is_eof(t) do return

    if is_decimal_number_continuation(t) || is_char(t, '_') {
        decimal_point_found := false
        scientific_notation_found := false

        for !is_eof(t) && (is_decimal_number_continuation(t) || is_char(t, '_')) {
            if is_char(t, '.') {
                // break early for range operation (..< or ..=)
                b1, b2: byte
                ok: bool

                b1, ok = peek_byte(t, 1)
                if !ok do break

                if b1 == '.' {
                    b2, ok = peek_byte(t, 2)
                    if !ok do break
                    if b2 == '<' || b2 == '=' do break
                }

                if decimal_point_found do break
                decimal_point_found = true
            } else if is_char(t, 'i') || is_char(t, 'j') || is_char(t, 'k') {
                // imaginary or quaternion
                t.offset += 1
                break
            } else if is_char(t, 'e') || is_char(t, 'E') {
                if scientific_notation_found || !decimal_point_found do break
                scientific_notation_found = true
            } else if is_char(t, '-') {
                // negative exponent in scientific notation
                if !scientific_notation_found do break
                prev_byte, _ := peek_byte(t, -1)
                if prev_byte != 'e' || prev_byte != 'E' do break
            }

            t.offset += 1
        }
    } else if is_hex_prefix(t) || is_char(t, 'H') || is_char(t, 'X') {
        t.offset += 1
        for !is_eof(t) && (is_hex(t) || is_char(t, '_')) do t.offset += 1
    } else if is_char(t, 'o') {
        t.offset += 1
        for !is_eof(t) && (is_octal(t) || is_char(t, '_')) do t.offset += 1
    } else if is_char(t, 'b') {
        t.offset += 1
        for !is_eof(t) && (is_char(t, '0') || is_char(t, '1') || is_char(t, '_')) do t.offset += 1
    }
}

parse_string_literal :: proc(t: ^Nix_Tokenizer, token: ^Token) {
    delimiter := t.buf[t.offset]

    if delimiter == '`' {
        token.kind = .String_Raw
        t.offset += 1
        for !is_eof(t) && !is_char(t, '`') do t.offset += 1
    } else {
        token.kind = .String_Literal
        escape_found := false
        t.offset += 1

        for !is_eof(t) && !is_char(t, '\n') {
            if is_char(t, delimiter) && !escape_found do break
            escape_found = !escape_found && is_char(t, '\\')
            t.offset += 1
        }
    }

    if is_eof(t) do return
    t.offset += 1
}

parse_multiline_string :: proc(t: ^Nix_Tokenizer, token: ^Token) {
    t.offset += 1
    token.kind = .String_Raw
    for !is_eof(t) {
        if is_char(t, '\'') {
            t.offset += 1
            if is_eof(t) || is_char(t, '\'') {
                break
            }
        }
        t.offset += 1
    }
    t.offset += 1
}

parse_char_lit :: proc(t: ^Nix_Tokenizer, token: ^Token) {
    t.offset += 1
    for !is_char(t, '\'') {
        t.offset += 1
    }
    t.offset += 1
    token.kind = .String_Literal
}

parse_tab :: proc(t: ^Tokenizer, token: ^Token) {
    token.kind = .Punctuation
    token.variant = .Tab
    t.offset += 1
    for !is_eof(t) && is_char(t, '\t') do t.offset += 1
}

parse_identifier :: proc(t: ^Nix_Tokenizer, token: ^Token) {
    token.kind = .Identifier
    token.text = read_word(t)

    switch {
    case slice.contains(STATEMENT, token.text): token.kind = .Directive
    case slice.contains(SPECIAL,   token.text): token.kind = .Constant
    }
}

STATEMENT :: []string {
    "let", "in", "with", "import", "rec", "inherit",
}

SPECIAL :: []string {
    "Ellipsis", "null", "self", "super", "true", "false", "abort",
}

