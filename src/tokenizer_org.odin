#+private file
package main

Org_Tokenizer :: struct {
    using tokenizer: Tokenizer,
    depth: int,
    leading_stars: bool,
    at_start_of_line: bool,
}

Token :: Basic_Token

@(private)
tokenize_org :: proc(buffer: ^Buffer, starting_offset := 0) {
    tokenizer: Org_Tokenizer
    tokenizer.buf = buffer.text
    tokenizer.starting_offset = starting_offset
    tokenizer.leading_stars = false
    tokenizer.at_start_of_line = true

    for {
        token := get_next_token(&tokenizer)
        if token.kind == .EOF do break

        save_token(buffer, &tokenizer, token)
    }
}

get_next_token :: proc(t: ^Org_Tokenizer) -> (token: Token) {
    skip_whitespaces(t)

    token.start = t.offset
    token.kind = .EOF
    if is_eof(t) {
        return
    }

    // parse TODO (comment) / DONE (string)
    if t.leading_stars && (len(t.buf) > t.offset + 4) {
        buf := t.buf[t.offset:t.offset + 4]
        if buf == "TODO" {
            token.kind = .Comment
            t.offset += 4
            token.length = t.offset - token.start
            token.text = "TODO"
            return
        } else if buf == "DONE" {
            token.kind = .String_Literal
            t.offset += 4
            token.length = t.offset - token.start
            token.text = "DONE"
            return
        }
    }

    if is_char(t, '*') && t.at_start_of_line {
        t.depth += 1
        t.leading_stars = true
        token_kind_depth(t, &token)
        token.text = "*"

        t.offset += 1
    } else if is_newline(t) {
        t.depth = 0
        t.leading_stars = false
        token.kind = .Punctuation
        t.at_start_of_line = true

        t.offset += 1
    } else {
        t.at_start_of_line = false
        // any other word: is an identifier, as Bragi_Header#n depending on nesting depth and if we're currently on a line with *s leading it
        token_kind_depth(t, &token)

        for !(is_eof(t) || is_whitespace(t) || is_newline(t)) {
            t.offset += 1
        }
        if len(t.buf) > t.offset + 1 {
            token.text = t.buf[token.start:t.offset + 1]
        } else {
            token.text = t.buf[token.start:len(t.buf)]
        }
    }

    token.length = t.offset - token.start

    return
}

token_kind_depth :: proc (t: ^Org_Tokenizer, token: ^Token) {
    switch t.depth % 6 {
    case 0: token.kind = .Identifier
    case 1: token.kind = .Builtin_Function // .Bragi_Header1
    case 2: token.kind = .Type // .Bragi_Header2
    case 3: token.kind = .Constant // .Bragi_Header3
    case 4: token.kind = .Keyword // .Bragi_Header4
    case 5: token.kind = .Enum_Variant // .Bragi_Header5
    case: unreachable()
    }
}

