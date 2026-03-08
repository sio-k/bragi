// parse 4coder project/settings files
package project

import rt "base:runtime"

import "core:fmt"
import "core:log"
import "core:os/os2"
import "core:strconv"
import "core:unicode"
import "core:unicode/utf8"

Token_Type :: enum {
    Ident, Dot_Ident, String, Bool, Number,
    Paren_Open, Paren_Close,
    Equals, Semicolon, Comma,
    Brace_Open, Brace_Close,
    Comment,
}

Token :: struct {
    type: Token_Type,
    contents: string,
    boolvalue: bool,
    numvalue: f64,

    line: u64,
    column_start: u64,

    offset_start: u64,
    len: u64,
}

token_is_punctuation :: proc (t: Token) -> bool {
    return t.type == .Paren_Open ||
        t.type == .Paren_Close ||
        t.type == .Equals ||
        t.type == .Semicolon ||
        t.type == .Comma ||
        t.type == .Brace_Open ||
        t.type == .Brace_Close
}

Lex_Context :: struct {
    offset: u64,
    line: u64,
    column: u64,
}

Lex_Proc :: #type proc (lex_ctx: Lex_Context, contents: string) -> (token: Token, success: bool)

lex_procs :: [?]Lex_Proc {
    lex_punctuation,
    lex_bool,
    lex_number,
    lex_comment,
    lex_string,
    lex_dot_ident,
    lex_ident,
}

lex_punctuation :: proc (
    lex_ctx: Lex_Context, contents: string,
) -> (token: Token, success: bool) {
    mktoken :: proc (lex_ctx: Lex_Context, contents: string, type: Token_Type) -> Token {
        return Token {
            type = type,
            contents = contents[:1],
            boolvalue = false,
            numvalue = 0,
            line = lex_ctx.line,
            column_start = lex_ctx.column,
            offset_start = lex_ctx.offset,
            len = 1,
        }
    }

    switch contents[0] {
    case '(':
        token = mktoken(lex_ctx, contents, .Paren_Open)
    case ')':
        token = mktoken(lex_ctx, contents, .Paren_Close)
    case '=':
        token = mktoken(lex_ctx, contents, .Equals)
    case ';':
        token = mktoken(lex_ctx, contents, .Semicolon)
    case ',':
        token = mktoken(lex_ctx, contents, .Comma)
    case '{':
        token = mktoken(lex_ctx, contents, .Brace_Open)
    case '}':
        token = mktoken(lex_ctx, contents, .Brace_Close)
    case:
        success = false
        return
    }
    success = true
    return
}

lex_bool :: proc (
    lex_ctx: Lex_Context, contents: string,
) -> (token: Token, success: bool) {
    valstrings := [2]string { "true", "false" }
    valbools := [2]bool { true, false }
    valnums := [2]f64 { 1, 0 }
    for i := 0; i < 2; i += 1 {
        valstring := valstrings[i]
        valbool := valbools[i]
        valnum := valnums[i]
        if len(contents) >= len(valstring) && contents[:len(valstring)] == valstring {
            token = Token {
                type = .Bool,
                contents = contents[:len(valstring)],
                boolvalue = valbool,
                numvalue = valnum,
                line = lex_ctx.line,
                column_start = lex_ctx.column,
                offset_start = lex_ctx.offset,
                len = u64(len(valstring)),
            }
            success = true
            return
        }
    }
    success = false
    return
}

lex_number :: proc (
    lex_ctx: Lex_Context, contents: string,
) -> (token: Token, success: bool) {
    v: f64
    count: int
    v, count, success = strconv.parse_f64_prefix(contents)
    if !success {
        return
    }
    token = {
        type = .Number,
        contents = contents[:count],
        boolvalue = v != 0,
        numvalue = v,
        line = lex_ctx.line,
        column_start = lex_ctx.column,
        offset_start = lex_ctx.offset,
        len = u64(count),
    }
    return
}

lex_comment :: proc (
    lex_ctx: Lex_Context, contents: string,
) -> (token: Token, success: bool) {
    if len(contents) > 2 && contents[:2] == "//" {
        count: u64 = 2
        // count to end-of-line
        for count < u64(len(contents)) && contents[count] != '\n' {
            count += 1
        }
        success = true
        token = Token {
            type = .Comment,
            contents = contents[:count],
            boolvalue = false,
            numvalue = 0,
            line = lex_ctx.line,
            column_start = lex_ctx.column,
            offset_start = lex_ctx.offset,
            len = count,
        }
        return
    }
    success = false
    return
}

lex_string :: proc (
    lex_ctx: Lex_Context, contents: string,
) -> (token: Token, success: bool) {
    if contents[0] != '"' {
        success = false
        return
    }
    count: u64 = 1
    for count < u64(len(contents)) && contents[count] != '"' && contents[count] != '\n' {
        if contents[count] == '\\' && count + 1 < u64(len(contents)) && contents[count + 1] == '"' {
            count += 1 // skip an extra char
        }
        count += 1
    }
    if count < u64(len(contents)) && contents[count] != '\n' {
        count += 1 // walk past ending '"'
    } else {
        log.errorf("4coder file lexer: string not terminated properly at line %v, column %v, offset %v", lex_ctx.line, lex_ctx.column, lex_ctx.offset)
        // TODO: log error better: string not terminated properly
    }

    // NOTE (sio): for convenience, we parse these here if we can
    // sometimes, numbers and bools might wind up in strings for some reason
    // we just parse them here to not have to deal with this in the future
    numvalue, _, num_success := strconv.parse_f64_prefix(contents[1:])
    if num_success != true { numvalue = 0 }
    boolvalue := false
    if count > len("true") && contents[1:len("true") + 1] == "true" {
        boolvalue = true
    }
    token = Token {
        type = .String,
        contents = contents[1:count-1],
        boolvalue = boolvalue,
        numvalue = numvalue,
        line = lex_ctx.line,
        column_start = lex_ctx.column,
        offset_start = lex_ctx.offset,
        len = count,
    }
    success = true
    return
}

lex_dot_ident :: proc (
    lex_ctx: Lex_Context, contents: string,
) -> (token: Token, success: bool) {
    if contents[0] != '.' {
        success = false
        return
    }
    nctx := lex_ctx
    nctx.offset += 1
    nctx.column += 1
    token, success = lex_ident(nctx, contents[1:])
    if success {
        token.type = .Dot_Ident
        token.len += 1
        token.offset_start -= 1
        token.column_start -= 1
    }
    return
}

lex_ident :: proc (
    lex_ctx: Lex_Context, contents: string,
) -> (token: Token, success: bool) {
    lex_is_identletter :: proc (r: u8, count: u64) -> bool {
        switch r {
        case '_': return true
        case 'A'..='Z', 'a'..='z': return true
            // if it's past the first char, we allow numbers
        }
        switch {
        case count > 0 && '0' <= r && r <= '9': return true
        }
        return false
    }

    count: u64 = 0
    for count < u64(len(contents)) && lex_is_identletter(contents[count], count) {
        count += 1
    }
    success = count > 0
    if success {
        token = Token {
            type = .Ident,
            contents = contents[:count],
            boolvalue = false,
            numvalue = 0,
            line = lex_ctx.line,
            column_start = lex_ctx.column,
            offset_start = lex_ctx.offset,
            len = count,
        }
    }
    return
}

// contents must have same or longer lifetime as results
lex :: proc (
    name, contents: string,
    arena := context.temp_allocator,
) -> (res: []Token, ok: bool) {
    results := make([dynamic]Token, allocator = arena)
    contents_length := u64(len(contents))

    lex_ctx := Lex_Context {
        offset = 0,
        line = 1,
        column = 1,
    }
lex_top_loop:
    for lex_ctx.offset < contents_length {
        for p in lex_procs {
            result, ok := p(lex_ctx, contents[lex_ctx.offset:])
            if ok {
                // we lex comments correctly, but leaving them in the tokenstream causes trouble
                if result.type != .Comment {
                    append(&results, result)
                }
                lex_ctx.offset += result.len
                lex_ctx.column += result.len
                continue lex_top_loop
            }
        }

        if contents[lex_ctx.offset] == '\r'{
            if lex_ctx.offset + 1 < contents_length {
                if contents[lex_ctx.offset + 1] == '\n' {
                    lex_ctx.offset += 2
                    lex_ctx.line += 1
                    lex_ctx.column = 1
                    continue lex_top_loop
                }
            }
        } else if contents[lex_ctx.offset] == '\n' {
            lex_ctx.offset += 1
            lex_ctx.line += 1
            lex_ctx.column = 1
            continue lex_top_loop
        } else if contents[lex_ctx.offset] == '\r' ||
            contents[lex_ctx.offset] == '\t' ||
            contents[lex_ctx.offset] == ' '
        {
            lex_ctx.offset += 1
            continue lex_top_loop
        }

        // TODO: return error to be displayed
        // TODO: properly and nicely format this with some context around it so it's clear where the error is
        log.errorf("failed to parse file %v, don't know what to make of line %v, column %v (offset %v)", name, lex_ctx.line, lex_ctx.column, lex_ctx.offset)
        res = results[:]
        ok = false
        return
    }

    res = results[:]
    ok = true
    return
}


Value_Type :: enum { Obj, List, Str, Num, B }
Value :: struct {
    kind: Value_Type,
    obj: map[string]Value,
    list: []Value,
    str: string,
    num: f64,
    b: bool,
}

parse_obj :: proc (
    tokens: []Token, assignments: ^map[string]Value,
) -> (value: Value, rest: []Token, ok: bool) {
    tokens := tokens
    start := tokens[0]
    ok = tokens[0].type == .Brace_Open
    if !ok { return }
    tokens = tokens[1:]
    tmpa := rt.default_temp_allocator_temp_begin()
    defer if !ok { rt.default_temp_allocator_temp_end(tmpa) }
    list := make(map[string]Value, allocator = context.temp_allocator)
    for len(tokens) > 0 && tokens[0].type != .Brace_Close {
        name: string
        name, value, rest, ok =
            parse_assignment(tokens, assignments, toplevel = false)
        if !ok {
            return
        }
        list[name] = value
        if len(rest) < 1 {
            log.errorf(
                "unterminated object starting at (%v, %v)",
                start.line,
                start.column_start
            )
            ok = false
            return
        } else if rest[0].type != .Comma {
            log.errorf(
                "object assignment statement not terminated with comma at %v, %v",
                tokens[0].line,
                tokens[0].column_start
            )
            ok = false
            return
        }
        tokens = rest[1:]
    }
    if len(tokens) <= 0 {
        // TODO: proper error message
        log.errorf("unterminated object starting at line %v, column %v (offset %v)", start.line, start.column_start, start.offset_start)
        rest = nil
    } else {
        rest = tokens[1:]
    }
    value = Value {
        kind = .Obj,
        obj = list,
    }
    ok = true
    return
}

parse_list :: proc (
    tokens: []Token, assignments: ^map[string]Value,
) -> (value: Value, rest: []Token, ok: bool) {
    tokens := tokens
    start := tokens[0]
    ok = tokens[0].type == .Brace_Open
    if !ok { return }
    rest = tokens[1:]
    if len(rest) > 0 && rest[0].type == .Dot_Ident {
        ok = false // this is an object, early-out
        return
    }
    tmpa := rt.default_temp_allocator_temp_begin()
    defer if !ok { rt.default_temp_allocator_temp_end(tmpa) }
    list := make([dynamic]Value, allocator = context.temp_allocator)
    for len(rest) > 0 && rest[0].type != .Brace_Close {
        nrest: []Token
        value, nrest, ok = parse_value(rest, assignments)
        if !ok {
            return
        }
        append(&list, value)
        if len(nrest) > 0 && nrest[0].type == .Comma {
            rest = nrest[1:]
        } else {
            log.errorf(
                "list element (%v, %v) in list starting at (%v, %v) not terminated with comma",
                rest[0].line, rest[0].column_start,
                start.line, start.column_start
            )
            ok = false
            return
        }
    }
    if len(rest) <= 0 {
        // TODO: proper error message
        log.errorf("unterminated list starting at line %v, column %v (offset %v)", start.line, start.column_start, start.offset_start)
        rest = nil
    } else {
        rest = rest[1:]
    }
    value = Value {
        kind = .List,
        list = list[:],
    }
    ok = true
    return
}

parse_string :: proc (
    tokens: []Token, assignments: ^map[string]Value,
) -> (value: Value, rest: []Token, ok: bool) {
    ok = tokens[0].type == .String
    if !ok { return }
    value.kind = .Str
    value.str = tokens[0].contents
    rest = tokens[1:]
    return
}

parse_num :: proc (
    tokens: []Token, assignments: ^map[string]Value,
) -> (value: Value, rest: []Token, ok: bool) {
    ok = tokens[0].type == .Number
    if !ok { return }
    value.kind = .Num
    value.num = tokens[0].numvalue
    rest = tokens[1:]
    return
}

parse_bool :: proc (
    tokens: []Token, assignments: ^map[string]Value,
) -> (value: Value, rest: []Token, ok: bool) {
    ok = tokens[0].type == .Bool
    if !ok { return }
    value.kind = .B
    value.b = tokens[0].boolvalue
    rest = tokens[1:]
    return
}

parse_ident :: proc (
    tokens: []Token, assignments: ^map[string]Value,
) -> (value: Value, rest: []Token, ok: bool) {
    ok = tokens[0].type == .Ident
    if !ok { return }
    value, ok = assignments[tokens[0].contents]
    if !ok {
        log.errorf(
            "identifier %v found without previously defined value, used at line %v, column %v (offset %v)",
            tokens[0].contents, tokens[0].line,
            tokens[0].column_start, tokens[0].offset_start,
        )
        // TODO: emit properly readable error
        return
    }
    rest = tokens[1:]
    return
}

// FIXME FIXME FIXME arena needs to be passed down to all parsing functions
parse_value :: proc (
    tokens: []Token,
    assignments: ^map[string]Value,
) -> (value: Value, rest: []Token, ok: bool) {
    value, rest, ok = parse_bool(tokens, assignments)
    if ok {
        return
    }
    value, rest, ok = parse_num(tokens, assignments)
    if ok {
        return
    }
    value, rest, ok = parse_string(tokens, assignments)
    if ok {
        return
    }
    value, rest, ok = parse_list(tokens, assignments)
    if ok {
        return
    }
    value, rest, ok = parse_obj(tokens, assignments)
    if ok {
        return
    }
    value, rest, ok = parse_ident(tokens, assignments)
    if ok {
        return
    }
    // TODO: proper error message
    log.errorf("failed to parse value at line %v, column %v (offset %v)", tokens[0].line, tokens[0].column_start, tokens[0].offset_start);
    return
}

parse_assignment :: proc (
    tokens: []Token, assignments: ^map[string]Value, toplevel := true,
) -> (name: string, value: Value, rest: []Token, ok: bool) {
    ok = len(tokens) > 3
    if !ok {
        if toplevel {
            log.errorf(
                "can't parse assignment at line %v, column %v (offset %v)",
                tokens[0].line,
                tokens[0].column_start,
                tokens[0].offset_start
            )
        }
        return
    }

    ok = tokens[0].type == .Ident || (!toplevel && tokens[0].type == .Dot_Ident)
    if !ok {
        if toplevel {
            log.errorf(
                "can't parse assignment at line %v, column %v (offset %v)",
                tokens[0].line,
                tokens[0].column_start,
                tokens[0].offset_start
            )
        }
        return
    }
    name = tokens[0].contents

    ok = tokens[1].type == .Equals
    if !ok {
        log.errorf(
            "can't parse assignment at line %v, column %v (offset %v)",
            tokens[0].line,
            tokens[0].column_start,
            tokens[0].offset_start
        )
        return
    }

    value, rest, ok = parse_value(tokens[2:], assignments)

    if toplevel {
        ok = len(rest) > 0 && rest[0].type == .Semicolon
        if !ok {
            if len(rest) > 0 {
                log.errorf(
                    "missing semicolon before line %v, column %v",
                    rest[0].line,
                    rest[0].column_start
                )
            } else {
                log.errorf(
                    "unterminated assignment starting at line %v, column %v",
                     tokens[0].line,
                     tokens[0].column_start
                )
            }
            return
        }
        rest = rest[1:]
    }

    return
}

parse :: proc (
    name: string, tokens: []Token, arena := context.temp_allocator,
) -> (version: u64, assignments: map[string]Value, ok: bool) {
    tokens := tokens;
    ok = true
    version = 2
    assignments = make(map[string]Value, allocator = arena)
    if len(tokens) >= 5 &&
        tokens[0].type == .Ident &&
        tokens[0].contents == "version" &&
        tokens[1].type == .Paren_Open &&
        tokens[2].type == .Number &&
        tokens[3].type == .Paren_Close &&
        tokens[4].type == .Semicolon
    {
        // found version
        version = u64(tokens[2].numvalue)
        tokens = tokens[5:]
    }

    for len(tokens) > 0 {
        name, value, rest, assignment_ok := parse_assignment(tokens, &assignments)
        if !assignment_ok {
            // TODO: print error message properly
            log.errorf("failed to parse assignment starting at %v:%v, column %v", name, tokens[0].line, tokens[0].column_start);
            ok = false
            break
        }
        assignments[name] = value
        tokens = rest
    }
    return
}

read_file :: proc (
    filename: string,
    arena := context.temp_allocator,
) -> (assignments: map[string]Value, ok: bool) {
    tmpa := rt.default_temp_allocator_temp_begin()
    defer if !ok { rt.default_temp_allocator_temp_end(tmpa) }
    filecontents, err := os2.read_entire_file_from_path(
        filename, allocator = context.temp_allocator,
    )
    ok = err == nil
    if !ok {
        log.errorf(
            "failed to read contents of 4coder/bragi file %v, got error %v",
            filename,
            err,
        )
        return
    }
    tokens: []Token
    tokens, ok = lex(filename, transmute(string) filecontents, arena)
    if !ok {
        log.errorf("failed to lex 4coder/bragi file %v", filename)
        return
    }

    _, assignments, ok = parse(filename, tokens, arena)
    if !ok {
        log.errorf("failed to parse 4coder/bragi file %v", filename)
    }
    return
}

current_os :: proc () -> string {
    when ODIN_OS == .Windows {
        return "win"
    } else when ODIN_OS == .Darwin {
        return "mac"
    } else when ODIN_OS == .Linux {
        return "linux"
    } else when ODIN_OS == .Essence {
        return "essence"
    } else when ODIN_OS == .FreeBSD {
        return "freebsd"
    } else when ODIN_OS == .OpenBSD {
        return "openbsd"
    } else when ODIN_OS == .NetBSD {
        return "netbsd"
    } else when ODIN_OS == .Haiku {
        return "haiku"
    } else {
        assert(false, message = "don't know this OS, please fill in OS in project.current_os()")
    }
}

// TODO: function that lexes, parses, extracts values we care about, and sets whatever we need to set, depending:
// - bindings for a bindings.bragi file
// - settings for a settings.bragi file
// - load a theme for a .4coder file with "theme" in the name (or if told this is a theme)
// - load a project for a project.4coder file
//
// TODO: highlighting for this type of files

// TODO: tokenizer for 4coder files for highlighting with no autoindent

// TODO: file opening based on patterns, excl. blacklist patterns, and in paths
// TODO: variables (see paths in raddebugger 4coder project file)

// TODO: custom commands

// TODO: lex, then parse, then "interpret" the resulting AST into the following vars:
// - patterns
// - blacklist_patterns
// - all the known 4coder settings
// - 4coder bindings (where they make sense)
// - 4coder themes
// - load_paths
// - fkey_command
// - commands
// - fkey_command_override per user

// in essence, this is relatively simple:
// extract and fully resolve the nodes as we go through the AST, inorder
// tbh that should be all that's necessary for now?
