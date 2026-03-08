#+private file
package main

import "core:slice"

Zig_Tokenizer :: struct {
    using tokenizer: Tokenizer,

    prev_token: Token,
}

Token :: struct {
    using token: Basic_Token,

    variant: union {
        Operation,
        Punctuation,
    },
}

@(private)
tokenize_zig :: proc(buffer: ^Buffer, starting_offset := 0) {
    tokenizer: Zig_Tokenizer
    tokenizer.buf = buffer.text
    tokenizer.starting_offset = starting_offset

    for {
        token := get_next_token(&tokenizer)
        if token.kind == .EOF do break

        tokenizer.prev_token = token

        save_token(buffer, &tokenizer, token)
    }
}

@(private)
tokenize_zig_indentation :: proc(buffer: ^Buffer, text: string) -> []Indentation_Token {
    tokenizer: Zig_Tokenizer
    tokenizer.buf = text
    tokens := make([dynamic]Indentation_Token, context.temp_allocator)
    case_found := false
    maybe_inlined_stmt := false

    for {
        token := get_next_token(&tokenizer)
        indent: Indentation_Token

        #partial switch token.kind {
        case .EOF:
            switch {
            case case_found:
                case_found = false
                indent.action = .Open
                indent.kind = .Brace
            case maybe_inlined_stmt:
                maybe_inlined_stmt = false
                indent.action = .Line_Continuation
            }
        case .Keyword:
            switch {
            case token.text == "case":
                case_found = true
                indent.action = .Close
                indent.kind = .Brace
            case token.text == "if" || token.text == "for":
                maybe_inlined_stmt = true
            }
        case .Punctuation:
            if punctuation, is_punctuation := token.variant.(Punctuation); is_punctuation {
                #partial switch punctuation {
                case .Semicolon:
                    // the line was completed before breakign the line
                    maybe_inlined_stmt = false
                case .Newline:
                    if case_found {
                        case_found = false
                        indent.action = .Open
                        indent.kind = .Brace
                    }
                case .Brace_Left:    {
                    maybe_inlined_stmt = false
                    indent.action = .Open
                    indent.kind = .Brace
                }
                case .Brace_Right:   indent.action = .Close; indent.kind = .Brace
                case .Bracket_Left:  indent.action = .Open;  indent.kind = .Bracket
                case .Bracket_Right: indent.action = .Close; indent.kind = .Bracket
                case .Paren_Left:    indent.action = .Open;  indent.kind = .Paren
                case .Paren_Right:   indent.action = .Close; indent.kind = .Paren
                }
            }
        }

        append(&tokens, indent)
        if token.kind == .EOF do break
    }

    assert(len(tokens) > 0)
    return tokens[:]
}

get_next_token :: proc(t: ^Zig_Tokenizer) -> (token: Token) {
    skip_whitespaces(t)

    token.start = t.offset
    token.kind  = .EOF
    if is_eof(t) do return

    if is_alpha(t) || is_char(t, '_') {
        parse_identifier(t, &token)
    } else if is_number(t) {
        parse_number(t, &token)
    } else {
        switch t.buf[t.offset] {
        case '*':  parse_asterisk       (t, &token)
        case '!':  parse_bang           (t, &token)
        case ':':  parse_colon          (t, &token)
        case '#':  parse_directive      (t, &token)
        case '.':  parse_dot            (t, &token)
        case '=':  parse_equal          (t, &token)
        case '>':  parse_greater        (t, &token)
        case '<':  parse_less           (t, &token)
        case '-':  parse_minus          (t, &token)
        case '@':  parse_note           (t, &token)
        case '|':  parse_pipe           (t, &token)
        case '+':  parse_plus           (t, &token)
        case '/':  parse_slash          (t, &token)
        case '"':  parse_string_literal (t, &token)
        case '\t': parse_tab            (t, &token)
        case '~':  parse_tilde          (t, &token)

        case ';':  token.kind = .Punctuation; token.variant = .Semicolon;     t.offset += 1
        case ',':  token.kind = .Punctuation; token.variant = .Comma;         t.offset += 1
        case '{':  token.kind = .Punctuation; token.variant = .Brace_Left;    t.offset += 1
        case '}':  token.kind = .Punctuation; token.variant = .Brace_Right;   t.offset += 1
        case '[':  token.kind = .Punctuation; token.variant = .Bracket_Left;  t.offset += 1
        case ']':  token.kind = .Punctuation; token.variant = .Bracket_Right; t.offset += 1
        case '(':  token.kind = .Punctuation; token.variant = .Paren_Left;    t.offset += 1
        case ')':  token.kind = .Punctuation; token.variant = .Paren_Right;   t.offset += 1
        case '$':  token.kind = .Punctuation; token.variant = .Dollar_Sign;   t.offset += 1
        case '?':  token.kind = .Operation;   token.variant = .Question;      t.offset += 1
        case '&':  token.kind = .Operation;   token.variant = .Ampersand;     t.offset += 1
        case '%':  token.kind = .Operation;   token.variant = .Percent;       t.offset += 1
        case '^':  token.kind = .Operation;   token.variant = .Caret;         t.offset += 1
        case '`':  token.kind = .Operation;   token.variant = .Backtick;      t.offset += 1
        case '\n': token.kind = .Punctuation; token.variant = .Newline;       t.offset += 1
        }
    }

    token.length = t.offset - token.start
    return
}

parse_asterisk :: proc(t: ^Tokenizer, token: ^Token) {
    token.kind = .Operation
    token.variant = .Asterisk
    t.offset += 1
    if is_eof(t) do return

    if is_char(t, '=') {
        token.variant = .Asterisk_Equal
        t.offset += 1
    }
}

parse_bang :: proc(t: ^Tokenizer, token: ^Token) {
    token.kind = .Operation
    token.variant = .Bang
    t.offset += 1
    if is_eof(t) do return

    if is_char(t, '=') {
        token.variant = .Bang_Equal
        t.offset += 1
    }
}

parse_colon :: proc(t: ^Zig_Tokenizer, token: ^Token) {
    token.kind = .Operation
    token.variant = .Colon
    t.offset += 1
    if is_eof(t) do return

    switch t.buf[t.offset] {
    case ':': token.variant = .Colon_Colon; t.offset += 1
    case '=': token.variant = .Colon_Equal; t.offset += 1
    }
}

parse_directive :: proc(t: ^Zig_Tokenizer, token: ^Token) {
    token.kind = .None
    t.offset += 1
    if is_eof(t) do return

    token.text = read_word(t)
    if slice.contains(DIRECTIVES, token.text) do token.kind = .Directive
}

parse_dot :: proc(t: ^Zig_Tokenizer, token: ^Token) {
    token.kind = .Punctuation
    token.variant = .Dot
    t.offset += 1
    if is_eof(t) do return

    if is_char(t, '.') {
        token.variant = .Dot_Dot
        t.offset += 1
    } else if is_number(t) {
        parse_number(t, token)
    } else if t.whitespace_to_left {
        next_token := peek_next_token(t)

        if next_token.kind == .Identifier {
            token.kind = .Enum_Variant
            token.variant = nil
            t.offset = next_token.start + next_token.length
        }
    }
}

parse_equal :: proc(t: ^Tokenizer, token: ^Token) {
    token.kind = .Operation
    token.variant = .Equal
    t.offset += 1
    if is_eof(t) do return

    if is_char(t, '=') {
        token.variant = .Equal_Equal
        t.offset += 1
    }
}

parse_greater :: proc(t: ^Tokenizer, token: ^Token) {
    token.kind = .Operation
    token.variant = .Greater
    t.offset += 1
    if is_eof(t) do return

    switch {
    case is_char(t, '='):
        token.variant = .Greater_Equal
        t.offset += 1
    case is_char(t, '>'):
        token.variant = .Greater_Greater
        t.offset += 1

        if is_char(t, '=') {
            token.variant = .Greater_Greater_Equal
            t.offset += 1
        }
    }
}

parse_identifier :: proc(t: ^Zig_Tokenizer, token: ^Token) {
    token.kind = .Identifier
    token.text = read_jai_word(t)

    // keep this order, hoping to find the value in smaller slices first.
    switch {
    case token.text == "DONE":
        if t.prev_token.kind == .Directive && t.prev_token.text == "string" {
            token.kind = .String_Raw

            for !is_eof(t) {
                word := read_word(t)
                if word == "DONE" do break
                t.offset += 1
            }
        }
    case slice.contains(CONSTANTS, token.text): token.kind = .Constant
    case slice.contains(TYPES,     token.text): token.kind = .Type
    case slice.contains(KEYWORDS,  token.text): token.kind = .Keyword
    }
}

parse_less :: proc(t: ^Tokenizer, token: ^Token) {
    token.kind = .Operation
    token.variant = .Less
    t.offset += 1
    if is_eof(t) do return

    switch {
    case is_char(t, '='):
        token.variant = .Less_Equal
        t.offset += 1
    case is_char(t, '<'):
        token.variant = .Less_Less
        t.offset += 1
        if is_char(t, '=') {
            token.variant = .Less_Less_Equal
            t.offset += 1
        }
    }
}

parse_minus :: proc(t: ^Tokenizer, token: ^Token) {
    token.kind = .Operation
    token.variant = .Minus
    t.offset += 1
    if is_eof(t) do return

    switch {
    case is_char(t, '='):
        token.variant = .Minus_Equal
        t.offset += 1
    case is_char(t, '>'):
        token.variant = .Minus_Greater
        t.offset += 1
    }
}

parse_number :: proc(t: ^Zig_Tokenizer, token: ^Token) {
    is_decimal_number_continuation :: proc(t: ^Zig_Tokenizer) -> bool {
        return is_number(t) || is_char(t, '.') || is_char(t, '-') ||
            is_char(t, 'e') || is_char(t, 'E')
    }

    token.kind = .Number
    t.offset += 1
    if is_eof(t) do return

    if is_decimal_number_continuation(t) || is_char(t, '_') {
        decimal_point_found := false
        scientific_notation_found := false

        for !is_eof(t) && (is_decimal_number_continuation(t) || is_char(t, '_')) {
            if is_char(t, '.') {
                b1, ok := peek_byte(t, 1)
                if !ok do break
                if b1 == '.' do break

                if decimal_point_found do break
                decimal_point_found = true
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
    } else if is_hex_prefix(t) {
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

parse_note :: proc(t: ^Zig_Tokenizer, token: ^Token) {
    token.kind = .Note
    t.offset += 1
    if is_eof(t) do return

    for !is_eof(t) && is_alphanumeric(t) do t.offset += 1
}

parse_pipe :: proc(t: ^Tokenizer, token: ^Token) {
    token.kind = .Operation
    token.variant = .Pipe
    t.offset += 1
    if is_eof(t) do return

    switch {
    case is_char(t, '='):
        token.variant = .Pipe_Equal
        t.offset += 1
    case is_char(t, '|'):
        token.variant = .Pipe_Pipe
        t.offset += 1

        if is_char(t, '=') {
            token.variant = .Pipe_Pipe_Equal
            t.offset += 1
        }
    }
}

parse_plus :: proc(t: ^Tokenizer, token: ^Token) {
    token.kind = .Operation
    token.variant = .Plus
    t.offset += 1
    if is_eof(t) do return

    if is_char(t, '=') {
        token.variant = .Plus_Equal
        t.offset += 1
    }
}

parse_slash :: proc(t: ^Tokenizer, token: ^Token) {
    token.kind = .Operation
    token.variant = .Slash
    t.offset += 1
    if is_eof(t) do return

    switch {
    case is_char(t, '='):
        token.variant = .Slash_Equal
        t.offset += 1
    case is_char(t, '/'):
        token.kind = .Comment
        token.variant = nil
        t.offset += 1
        for !is_eof(t) && !is_char(t, '\n') do t.offset += 1
    case is_char(t, '*'):
        token.kind = .Comment_Multiline
        token.variant = nil
        t.offset += 1
        comments_block_count := 0

        for !is_eof(t) {
            if is_char(t, '*') {
                if b, ok := peek_byte(t, 1); ok && b == '/' {
                    if comments_block_count == 0 {
                        t.offset += 2
                        break
                    } else {
                        comments_block_count -= 1
                    }
                }
            } else if is_char(t, '/') {
                if b, ok := peek_byte(t, 1); ok && b == '*' {
                    comments_block_count += 1
                    t.offset += 1
                }
            }

            t.offset += 1
        }
    }
}

parse_string_literal :: proc(t: ^Zig_Tokenizer, token: ^Token) {
    token.kind = .String_Literal
    escape_found := false
    t.offset += 1

    for !is_eof(t) && !is_char(t, '\n') {
        if is_char(t, '"') && !escape_found do break
        escape_found = !escape_found && is_char(t, '\\')
        t.offset += 1
    }

    if is_eof(t) do return
    t.offset += 1
}

parse_tab :: proc(t: ^Tokenizer, token: ^Token) {
    token.kind = .Punctuation
    token.variant = .Tab
    t.offset += 1
    for !is_eof(t) && is_char(t, '\t') do t.offset += 1
}

parse_tilde :: proc(t: ^Tokenizer, token: ^Token) {
    token.kind = .Operation
    token.variant = .Tilde
    t.offset += 1
    if is_eof(t) do return

    if is_char(t, '=') {
        token.variant = .Tilde_Equal
        t.offset += 1
    }
}

read_jai_word :: proc(t: ^Tokenizer) -> string {
    start := t.offset
    escape_on := false
    for !is_eof(t) && !is_char(t, '\n') {
        if !escape_on && !is_char(t, '\\') && !is_valid_word_component(t) do break

        if !escape_on && is_char(t, '\\') {
            escape_on = true
        } else if escape_on && !is_char(t, ' ') {
            escape_on = false
        }
        t.offset += 1
    }
    end := t.offset
    return t.buf[start:end]
}

peek_next_token :: proc(t: ^Zig_Tokenizer, eat_whitespace := true) -> (next_token: Token) {
    t_copy := t^
    if eat_whitespace do skip_whitespaces(&t_copy)
    next_token = get_next_token(&t_copy)
    return
}

CONSTANTS :: []string{
    "null", "true", "false", "undefined",
}

DIRECTIVES :: []string{}

KEYWORDS :: []string{
    "addrspace", "align", "allowzero", "and", "asm", "async", "await",
    "break", "callconv", "catch", "comptime", "const", "continue",
    "defer", "else", "errdefer", "error", "export", "extern", "fn",
    "for", "if", "inline", "noalias", "noinline", "nosuspend", "or",
    "orelse", "packed", "pub", "resume", "return", "linksection", "suspend",
    "switch", "test", "threadlocal", "try", "unreachable", "usingnamespace",
    "var", "volatile", "while",

    "enum", "struct", "type", "union", "noreturn",
}

TYPES :: []string{
    "bool", "f16", "f32", "f64", "f80", "f128",
    "i16", "i32", "i64", "i8", "i128",
    "u16", "u32", "u64", "u8", "u128",
    "void",
    "anyframe", "anytype", "anyerror", "anyopaque",
    "comptime_int", "comptime_float",
    "isize", "opaque", "usize",
}
