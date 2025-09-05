#+private file
package main

import "core:slice"

JS_Tokenizer :: struct {
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
tokenize_js :: proc(buffer: ^Buffer, starting_offset := 0) {
    tokenizer: JS_Tokenizer
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
tokenize_js_indentation :: proc(buffer: ^Buffer, text: string) -> []Indentation_Token {
    tokenizer: JS_Tokenizer
    tokenizer.buf = text
    tokens := make([dynamic]Indentation_Token, context.temp_allocator)

    for {
        token := get_next_token(&tokenizer)
        indent: Indentation_Token

        #partial switch token.kind {
        case .Punctuation:
            if punctuation, is_punctuation := token.variant.(Punctuation); is_punctuation {
                #partial switch punctuation {
                case .Brace_Left:    indent.action = .Open;  indent.kind = .Brace
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

    return tokens[:]
}

get_next_token :: proc(t: ^JS_Tokenizer) -> (token: Token) {
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
        case '*':  parse_asterisk(t, &token)
        case '!':  parse_bang    (t, &token)
        case '=':  parse_equal   (t, &token)
        case '>':  parse_greater (t, &token)
        case '<':  parse_less    (t, &token)
        case '-':  parse_minus   (t, &token)
        case '|':  parse_pipe    (t, &token)
        case '+':  parse_plus    (t, &token)
        case '/':  parse_slash   (t, &token)
        case '\t': parse_tab     (t, &token)
        case '~':  parse_tilde   (t, &token)

        case '`':  fallthrough
        case '"':  fallthrough
        case '\'': parse_string_literal    (t, &token)

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
        case '\n': token.kind = .Punctuation; token.variant = .Newline;       t.offset += 1
        }
    }

    token.length = t.offset - token.start
    return
}

parse_equal :: proc(t: ^JS_Tokenizer, token: ^Token) {
    token.kind = .Operation
    token.variant = .Equal
    t.offset += 1
    if is_eof(t) do return

    switch {
    case is_char(t, '='):
        token.variant = .Equal_Equal
        t.offset += 1
    case is_char(t, '>'):
        token.variant = .Equal_Greater
        t.offset += 1
    }
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

parse_identifier :: proc(t: ^JS_Tokenizer, token: ^Token) {
    token.kind = .Identifier
    token.text = read_word(t)

    switch {
    case slice.contains(CONSTANTS, token.text): token.kind = .Constant
    case slice.contains(KEYWORDS,  token.text): token.kind = .Keyword
    }
}

parse_greater :: proc(t: ^JS_Tokenizer, token: ^Token) {
    t.offset += 1
    if is_eof(t) do return
}

parse_less :: proc(t: ^JS_Tokenizer, token: ^Token) {
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

parse_number :: proc(t: ^JS_Tokenizer, token: ^Token) {
    t.offset += 1
    if is_eof(t) do return
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

parse_string_literal :: proc(t: ^JS_Tokenizer, token: ^Token) {
    escape_found := false
    delimiter := t.buf[t.offset]
    token.kind = .String_Literal
    t.offset += 1

    for !is_eof(t) {
        if delimiter == '`' {
            if is_char(t, '`') do break
        } else {
            if is_char(t, '\n') || (is_char(t, delimiter) && !escape_found) do break
            escape_found = !escape_found && is_char(t, '\\')
            t.offset += 1
        }
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

CONSTANTS :: []string{
    "this", "null", "undefined", "true", "false",
}

KEYWORDS :: []string{
    "async", "await", "const", "export", "default", "from", "function", "import", "let",
    "return",
}
