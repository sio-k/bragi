package main

import ast "core:odin/ast"
import parser "core:odin/parser"

import sdl "vendor:sdl3"

// TODO (sio): this works
// TODO (sio): next step: visualize this so I can look at it and maybe mutate the AST directly
parse_odin :: proc(buffer: ^Buffer) -> (file: ast.File) {
    file.src = buffer.text
    file.fullpath = buffer.filepath
    file_parser := parser.default_parser()
    parser.parse_file(&file_parser, &file)
    return
}

// TODO: make everything take a window/renderer parameter so I can use the fonts bits
// specifically, find_or_create_glyph and texture_create need to take another parameter
// and the font texture bucket needs to be bucketed by renderer
// also, I'm gonna need to make sure the input bits also branch by window

// TODO: all that above is gonna make it easy to just create new windows with dedicated new panes at the press of a button

Ast_Window :: struct {
    win: ^sdl.Window,
    ren: ^sdl.Renderer,
    // TODO: font rendering bits
}

init_ast_renderer :: proc() -> (window: Ast_Window) {
    // TODO
    return Ast_Window { nil, nil }
}

destroy_ast_renderer :: proc(window: Ast_Window) {
    // TODO
}

// TODO: visualize the AST
draw_ast :: proc(file: ast.File, ren: sdl.Renderer) {
    // TODO
}
