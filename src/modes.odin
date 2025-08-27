package main

import "core:slice"
import "core:strings"

Major_Mode :: enum u8 {
    Bragi = 0,
    Jai,
    Odin,
}

Major_Mode_Settings :: struct {
    visual_name:              string, // to show to the user
    electric_indent:          bool,
    file_extensions:          string, // "ext|ext2"
    visual_tokenization_proc: proc(^Buffer, int),
    indent_tokenization_proc: proc(^Buffer, string) -> []Indentation_Token,
}

major_mode_settings: map[Major_Mode]Major_Mode_Settings

major_modes_init :: proc() {
    major_mode_settings[.Bragi] = {
        visual_name     = "Bragi",
        electric_indent = false,
        visual_tokenization_proc = nil,
        indent_tokenization_proc = nil,
    }

    major_mode_settings[.Jai] = {
        visual_name = "Jai",
        electric_indent = true,
        file_extensions = ".jai",
        visual_tokenization_proc = tokenize_jai,
        indent_tokenization_proc = tokenize_jai_indentation,
    }

    major_mode_settings[.Odin] = {
        visual_name = "Odin",
        electric_indent = true,
        file_extensions = ".odin",
        visual_tokenization_proc = tokenize_odin,
        indent_tokenization_proc = tokenize_odin_indentation,
    }
}

major_modes_destroy :: proc() {
    delete(major_mode_settings)
}

get_major_mode_by_extension :: proc(ext: string) -> (result: Major_Mode) {
    result = .Bragi

    for key, value in major_mode_settings {
        slice_of_exts := strings.split(value.file_extensions, "|", context.temp_allocator)
        if slice.contains(slice_of_exts[:], ext) {
            result = key
            return
        }
    }

    return
}

should_do_electric_indent :: proc(buffer: ^Buffer) -> bool {
    return major_mode_settings[buffer.major_mode].electric_indent
}

tokenize_buffer :: proc(buffer: ^Buffer, starting_offset := 0) {
    tokenize_proc := major_mode_settings[buffer.major_mode].visual_tokenization_proc

    if tokenize_proc == nil do return
    tokenize_proc(buffer, starting_offset)
    // add the EOF token so we always have tokens.
    assign_at(&buffer.tokens, len(buffer.text_content.buf) + 1, Token_Kind.EOF)
}

get_indentation_tokens :: proc(buffer: ^Buffer, text: string) -> []Indentation_Token {
    indent_token_proc := major_mode_settings[buffer.major_mode].indent_tokenization_proc
    if indent_token_proc == nil do return {}
    return indent_token_proc(buffer, text)
}
