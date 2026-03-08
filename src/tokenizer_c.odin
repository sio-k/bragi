#+private file
package main

import "core:slice"

C_Tokenizer :: struct {
    using tokenizer: Tokenizer,

    prev_tokens: [3]Token,
}

Token :: struct {
    using token: Basic_Token,

    variant: union {
        Operation,
        Punctuation,
    },
}

@(private)
tokenize_c :: proc(buffer: ^Buffer, starting_offset := 0) {
    tokenizer: C_Tokenizer
    tokenizer.buf = buffer.text
    tokenizer.starting_offset = starting_offset

    for {
        token := get_next_token(&tokenizer)
        if token.kind == .EOF do break

        t1, t2, _ := get_previous_tokens(&tokenizer)

        switch {
        case should_save_current_token_like_directive(&tokenizer, token):
            token.kind = .Directive
        case should_save_current_token_like_type(&tokenizer, token):
            punctuation, is_punctuation := t1.variant.(Punctuation)
            op, is_op := t1.variant.(Operation)

            if is_punctuation && punctuation == .Caret {
                // a pointer type
                t1.kind = .Type
                token.kind = .Type
                save_token(buffer, &tokenizer, t1)
            } else if is_op && op == .Colon && t2.kind == .Identifier {
                token.kind = .Type
            }
        case should_save_type_def_name(&tokenizer, token):
            t2.kind = .Type
            save_token(buffer, &tokenizer, t2)
        }

        tokenizer.prev_tokens[2] = tokenizer.prev_tokens[1]
        tokenizer.prev_tokens[1] = tokenizer.prev_tokens[0]
        tokenizer.prev_tokens[0] = token

        save_token(buffer, &tokenizer, token)
    }
}

@(private)
tokenize_c_indentation :: proc(buffer: ^Buffer, text: string) -> []Indentation_Token {
    tokenizer: C_Tokenizer
    tokenizer.buf = text
    tokens := make([dynamic]Indentation_Token, context.temp_allocator)
    case_found := false

    for {
        token := get_next_token(&tokenizer)
        indent: Indentation_Token

        #partial switch token.kind {
        case .EOF:
            if case_found {
                case_found = false
                indent.action = .Open
                indent.kind = .Brace
            } else {
                p0, _, _ := get_previous_tokens(&tokenizer)
                if p0.kind == .Operation {
                    if op, is_op := p0.variant.(Operation); is_op {
                        if op != .Colon {
                            indent.action = .Line_Continuation
                        }
                    }
                }
            }
        case .Keyword:
            if token.text == "case" {
                case_found = true
                indent.action = .Close
                indent.kind = .Brace
            }
        case .Punctuation:
            if punctuation, is_punctuation := token.variant.(Punctuation); is_punctuation {
                #partial switch punctuation {
                case .Newline:
                    if case_found {
                        case_found = false
                        indent.action = .Open
                        indent.kind = .Brace
                    }
                case .Brace_Left:    indent.action = .Open;  indent.kind = .Brace
                case .Brace_Right:   indent.action = .Close; indent.kind = .Brace
                case .Bracket_Left:  indent.action = .Open;  indent.kind = .Bracket
                case .Bracket_Right: indent.action = .Close; indent.kind = .Bracket
                case .Paren_Left:    indent.action = .Open;  indent.kind = .Paren
                case .Paren_Right:   indent.action = .Close; indent.kind = .Paren
                }
            }
        }

        tokenizer.prev_tokens[2] = tokenizer.prev_tokens[1]
        tokenizer.prev_tokens[1] = tokenizer.prev_tokens[0]
        tokenizer.prev_tokens[0] = token

        append(&tokens, indent)
        if token.kind == .EOF do break
    }

    assert(len(tokens) > 0)
    return tokens[:]
}

get_next_token :: proc(t: ^C_Tokenizer) -> (token: Token) {
    skip_whitespaces(t)

    token.start = t.offset
    token.kind = .EOF
    if is_eof(t) do return

    if is_alpha(t) || is_char(t, '_') {
        parse_identifier(t, &token)
    } else if is_number(t) {
        parse_number(t, &token)
    } else {
        switch t.buf[t.offset] {
        case '&':  parse_ampersand (t, &token)
        case '*':  parse_asterisk  (t, &token)
        case '!':  parse_bang      (t, &token)
        case ':':  parse_colon     (t, &token)
        case '#':  parse_directive (t, &token)
        case '.':  parse_dot       (t, &token)
        case '=':  parse_equal     (t, &token)
        case '>':  parse_greater   (t, &token)
        case '<':  parse_less      (t, &token)
        case '-':  parse_minus     (t, &token)
        case '%':  parse_percent   (t, &token)
        case '|':  parse_pipe      (t, &token)
        case '+':  parse_plus      (t, &token)
        case '/':  parse_slash     (t, &token)
        case '~':  parse_tilde     (t, &token)
        case '^':  parse_caret     (t, &token)
        case '\t': parse_tab       (t, &token)

        case '\'': fallthrough
        case '"':  fallthrough
        case '`':  parse_string_literal(t, &token)

        case ';':  token.kind = .Punctuation; token.variant = .Semicolon;     t.offset += 1
        case ',':  token.kind = .Punctuation; token.variant = .Comma;         t.offset += 1
        case '?':  token.kind = .Punctuation; token.variant = .Question;      t.offset += 1
        case '{':  token.kind = .Punctuation; token.variant = .Brace_Left;    t.offset += 1
        case '}':  token.kind = .Punctuation; token.variant = .Brace_Right;   t.offset += 1
        case '[':  token.kind = .Punctuation; token.variant = .Bracket_Left;  t.offset += 1
        case ']':  token.kind = .Punctuation; token.variant = .Bracket_Right; t.offset += 1
        case '(':  token.kind = .Punctuation; token.variant = .Paren_Left;    t.offset += 1
        case ')':  token.kind = .Punctuation; token.variant = .Paren_Right;   t.offset += 1
        case '$':  token.kind = .Punctuation; token.variant = .Dollar_Sign;   t.offset += 1
        case '\n': token.kind = .Punctuation; token.variant = .Newline;       t.offset += 1
        }
    }

    token.length = t.offset - token.start

    return
}

parse_ampersand :: proc(t: ^C_Tokenizer, token: ^Token) {
    token.kind = .Operation
    token.variant = .Ampersand
    t.offset += 1
    if is_eof(t) do return

    switch {
    case is_char(t, '='):
        token.variant = .Ampersand_Equal
        t.offset += 1
    case is_char(t, '&'):
        token.variant = .Ampersand_Ampersand
        t.offset += 1
    case is_char(t, '~'):
        token.variant = .Ampersand_Tilde
        t.offset += 1
        if is_eof(t) do return

        if is_char(t, '=') {
            token.variant = .Ampersand_Tilde_Equal
            t.offset += 1
        }
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

parse_caret :: proc(t: ^Tokenizer, token: ^Token) {
    token.kind = .Operation
    token.variant = .Tilde
    t.offset += 1
    if is_eof(t) do return

    if is_char(t, '=') {
        token.variant = .Tilde_Equal
        t.offset += 1
    }
}

parse_colon :: proc(t: ^C_Tokenizer, token: ^Token) {
    token.kind = .Operation
    token.variant = .Colon
    t.offset += 1
    if is_eof(t) do return

    switch t.buf[t.offset] {
    case ':': token.variant = .Colon_Colon; t.offset += 1
    case '=': token.variant = .Colon_Equal; t.offset += 1
    }
}

parse_directive :: proc(t: ^C_Tokenizer, token: ^Token) {
    token.kind = .None
    t.offset += 1
    if is_eof(t) do return

    // maybe global directives like #+private
    if is_char(t, '+') {
        t.offset += 1
        if is_eof(t) do return
    }

    token.text = read_word(t)
    if slice.contains(ATTRIBUTES, token.text) do token.kind = .Directive
    if slice.contains(DIRECTIVES, token.text) do token.kind = .Directive
}

parse_dot :: proc(t: ^C_Tokenizer, token: ^Token) {
    token.kind = .Punctuation
    token.variant = .Dot
    t.offset += 1
    if is_eof(t) do return

    switch {
    case is_char(t, '?'):
        token.kind = .Builtin_Function
    case is_char(t, '.'):
        token.variant = .Dot_Dot
        t.offset += 1
        if is_eof(t) do return

        switch {
        case is_char(t, '='):
            token.variant = .Dot_Dot_Equal
            t.offset += 1
        case is_char(t, '<'):
            token.variant = .Dot_Dot_Less
            t.offset += 1
        }
    case :
        // check for enum variant
        p1, _, _ := get_previous_tokens(t)

        if p1.kind != .Identifier && t.whitespace_to_left {
            next_token := peek_next_token(t)
            if next_token.kind == .Identifier {
                token.kind = .Enum_Variant
                t.offset = next_token.start + next_token.length
            }
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

parse_identifier :: proc(t: ^C_Tokenizer, token: ^Token) {
    token.kind = .Identifier
    token.text = read_word(t)

    switch {
    case slice.contains(CONSTANTS,  token.text): token.kind = .Constant
    case slice.contains(KEYWORDS,   token.text): token.kind = .Keyword
    case slice.contains(TYPES,      token.text): token.kind = .Type
    case slice.contains(BUILTINS,   token.text): token.kind = .Builtin_Function
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
    case is_char(t, '-'):
        token.variant = .Minus_Minus
        t.offset += 1
        if is_char(t, '=') {
            token.variant = .Minus_Minus_Equal
            t.offset += 1
        }
    }
}

parse_number :: proc(t: ^C_Tokenizer, token: ^Token) {
    is_decimal_number_continuation :: proc(t: ^C_Tokenizer) -> bool {
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

parse_percent :: proc(t: ^C_Tokenizer, token: ^Token) {
    token.kind = .Operation
    token.variant = .Percent

    t.offset += 1
    if is_eof(t) do return

    switch {
    case is_char(t, '='): token.variant = .Percent_Equal; t.offset += 1
    case is_char(t, '%'):
        token.variant = .Percent_Percent
        t.offset += 1
        if is_eof(t) do return

        if is_char(t, '=') {
            token.variant = .Percent_Percent_Equal
            t.offset += 1
        }
    }
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
    } else if is_char(t, '+') {
        token.variant = .Plus_Plus
        t.offset += 1
        if is_char(t, '=') {
            token.variant = .Plus_Plus_Equal
            t.offset += 1
        }
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

parse_string_literal :: proc(t: ^C_Tokenizer, token: ^Token) {
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

get_previous_tokens :: proc(t: ^C_Tokenizer) -> (t1, t2, t3: Token) {
    return t.prev_tokens[0], t.prev_tokens[1], t.prev_tokens[2]
}

peek_next_token :: proc(t: ^C_Tokenizer, eat_whitespace := true) -> (next_token: Token) {
    t_copy := t^
    if eat_whitespace do skip_whitespaces(&t_copy)
    next_token = get_next_token(&t_copy)
    return
}

should_save_current_token_like_directive :: proc(t: ^C_Tokenizer, token: Token) -> bool {
    if token.kind == .Identifier && slice.contains(ATTRIBUTES, token.text) {
        t1, t2, _ := get_previous_tokens(t)
        v1, ok1 := t1.variant.(Punctuation)
        v2, ok2 := t2.variant.(Punctuation)
        return (ok1 && v1 == .At) || (ok2 && v2 == .At)
    }
    return false
}

should_save_current_token_like_type :: proc(t: ^C_Tokenizer, token: Token) -> bool {
    t1, _, _ := get_previous_tokens(t)
    punctuation, ok := t1.variant.(Punctuation)
    return token.kind == .Identifier && ok && punctuation == .Caret
}

should_save_type_def_name :: proc(t: ^C_Tokenizer, token: Token) -> bool {
    is_typedef_name :: proc(s: string) -> bool {
        return (s == "struct" || s == "enum" || s == "union")
    }

    if token.kind == .Keyword && is_typedef_name(token.text) {
        t1, _, _ := get_previous_tokens(t)
        if op, is_op := t1.variant.(Operation); is_op {
            return op == .Colon_Colon
        }
    }

    return false
}

ATTRIBUTES :: []string {}
BUILTINS :: []string {}

CONSTANTS :: []string{
    "false", "nullptr", "true",
    "FALSE", "NULL", "TRUE",
}

DIRECTIVES :: []string{
    "define", "elif", "elifdef", "elifndef", "else", "embed", "endif", "error",
    "if", "ifdef", "ifndef", "include", "include_next", "line", "pragma",
    "undef", "warning",
    "_Pragma",
    "__has_include", "__has_embed", "__has_c_attribute", "#",
}

KEYWORDS :: []string{
    "alignas", "alignof", "and", "and_eq", "asm", "auto", "bitand", "bitor",
    "break", "case", "catch", "class", "compl", "concept", "const",
    "constexpr", "consteval", "constinit", "const_cast", "continue",
    "decltype", "default", "delete", "do", "dynamic_cast", "else", "enum",
    "explicit", "export", "extern", "fallthrough", "final", "for", "fortran",
    "friend", "goto", "if", "import", "inline", "module", "mutable",
    "namespace", "new", "noexcept", "not", "not_eq", "operator", "or",
    "or_eq", "override", "public", "private", "protected", "register",
    "reinterpret_cast", "required", "restrict", "return", "sizeof", "static",
    "static_assert", "static_cast", "struct", "switch", "template", "this",
    "thread_local", "throw", "try", "typedef", "typeid", "typename",
    "typeof", "typeof_unqual", "union", "using", "virtual", "volatile",
    "while", "xor", "xor_eq",
    "_Alignas", "_Alignof", "_Atomic", "_Noreturn", "_Generic", "_Static_assert", "_Thread_Local",
    "__aligned__", "__asm__", "__attribute__", "__builtin__",
    "__extension__", "__hidden__", "__inline__", "__packed__", "__restrict__",
    "__section__", "__typeof__", "__weak__",
}

TYPES :: []string{
    "bool", "char", "short", "int", "long", "void",
    "signed", "unsigned",
    "i8", "i16", "i32", "i64",
    "s8", "s16", "s32", "s64",
    "char8_t", "char16_t", "char32_t",
    "int8_t", "int16_t", "int32_t", "int64_t",
    "uint8_t", "uint16_t", "uint32_t", "uint64_t",
    "u8", "u16", "u32", "u64", "intptr_t", "uintptr_t",
    "size_t", "isize", "usize", "ssize_t", "wchar_t",
    "byte",
    "f16", "f32", "f64", "f80",
    "float", "double", "_Float16", "__fp16", "_Float32", "_Float32x", "_Float64", "_Float64x", "__float80", "_Float128", "_Float128x", "__ibm128", "__int128", "_Fract", "_Sat", "_Accum",
    "_Atomic", "_BitInt",
    "_Decimal32", "_Decimal64", "_Decimal128", "_Complex", "complex", "_Imaginary", "imaginary",
    "_Bool",
}
