#+private file
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"

DESKTOP_FILENAME :: "bragi-desktop"

Parsing_Section :: enum { undefined, buffers, panes, settings }

Desktop_File_Parser :: struct {
    data:              string,
    offset:            int,
    section:           Parsing_Section,
    subsection:        int,

    failed_to_parse:   bool,
    buffers_to_open:   [dynamic]string,
    panes_to_open:     [dynamic]Pane_Info,
    active_pane_index: int,
}

Token :: struct {
    kind:   enum {
        EOF, Section, Subsection, Key_Value,
    },
    start:  int,
    length: int,
    text:   string,
}

Pane_Info :: struct {
    cursors:         [dynamic]int,
    buffer_filepath: string,
    font_size:       int,
    index:           int,
}

@(private)
desktop_init :: proc() {
    if !settings.use_desktop_file {
        active_pane = pane_create()
        return
    }

    desktop_filepath := get_desktop_filepath()

    if !os.exists(desktop_filepath) {
        active_pane = pane_create()
        return
    }

    desktop_data, desktop_success := os.read_entire_file(desktop_filepath, context.temp_allocator)

    if !desktop_success {
        active_pane = pane_create()
        return
    }

    info := parse_desktop_file(string(desktop_data))

    if info.failed_to_parse {
        active_pane = pane_create()
        return
    }

    for len(info.buffers_to_open) > 0 {
        fullpath := pop(&info.buffers_to_open)
        buffer_data, buffer_success := os.read_entire_file(fullpath, context.temp_allocator)

        if !buffer_success {
            log.errorf("couldn't open file '{}'", fullpath)
            continue
        }

        buffer_get_or_create_from_file(fullpath, buffer_data)
    }

    // we reverse it so we open it as intended
    slice.reverse(info.panes_to_open[:])

    for len(info.panes_to_open) > 0 {
        buffer_found := false
        pane_info := pop(&info.panes_to_open)
        new_pane := pane_create()

        new_pane.local_font_size = f32(pane_info.font_size)

        if pane_info.buffer_filepath != "" {
            for buffer in open_buffers {
                if buffer.filepath == pane_info.buffer_filepath {
                    new_pane.buffer = buffer
                    buffer_found = true
                    break
                }
            }
        }

        if buffer_found {
            clear(&new_pane.cursors)
            for cursor in pane_info.cursors do add_cursor(new_pane, cursor)
        }

        delete(pane_info.cursors)
    }

    delete(info.buffers_to_open)
    delete(info.panes_to_open)
    active_pane = open_panes[info.active_pane_index]
    update_all_pane_textures()
}

@(private)
desktop_save :: proc() {
    if !settings.use_desktop_file do return

    result := strings.builder_make(context.temp_allocator)
    buffers_count := 0
    active_pane_index := -1

    strings.write_string(&result, "::buffers\n")

    for buffer in open_buffers {
        if buffer.filepath != "" {
            strings.write_string(&result, fmt.tprintf(":{}\n", buffers_count))

            strings.write_string(&result, fmt.tprintf("filepath={}\n", buffer.filepath))
            buffers_count += 1
        }
    }

    strings.write_string(&result, "::panes\n")

    for pane, index in open_panes {
        if pane.uuid == active_pane.uuid do active_pane_index = index

        strings.write_string(&result, fmt.tprintf(":{}\n", index))

        strings.write_string(&result, "cursors=")
        for cursor in pane.cursors {
            strings.write_string(&result, fmt.tprintf("{},", cursor.pos))
        }
        strings.write_string(&result, "\n")

        if pane.buffer.filepath != "" {
            strings.write_string(&result, fmt.tprintf("buffer_filepath={}\n", pane.buffer.filepath))
        }

        strings.write_string(&result, fmt.tprintf("font_size={}\n", int(pane.local_font_size)))
    }

    strings.write_string(&result, "::settings\n")
    strings.write_string(&result, fmt.tprintf("active_pane_index={}\n", active_pane_index))

    success := os.write_entire_file(get_desktop_filepath(), result.buf[:])
    if success do log.debug("desktop file saved")
}

get_desktop_filepath :: proc() -> string {
    return fmt.tprintf("{}/{}", curr_working_dir, DESKTOP_FILENAME)
}

parse_desktop_file :: proc(data: string) -> (result: Desktop_File_Parser) {
    result.data = data
    result.offset = 0

    for {
        token := get_next_token(&result)
        if token.kind == .EOF do break

        switch token.kind {
        case .EOF: break
        case .Section:
            value, ok := reflect.enum_from_name(Parsing_Section, token.text)
            if !ok {
                log.fatalf("failed to parse, unknown section '{}'", token.text)
                result.failed_to_parse = true
                return
            }
            result.section = value
        case .Subsection:
            value, ok := strconv.parse_int(token.text)
            if !ok {
                log.fatalf("failed to parse, unknown subsection '{}'", token.text)
                result.failed_to_parse = true
                return
            }
            result.subsection = value

            if result.section == .panes {
                append(&result.panes_to_open, Pane_Info{index = result.subsection})
            }
        case .Key_Value:
            key_value := strings.split(token.text, "=", context.temp_allocator)
            parse_key_value(&result, key_value[:])
        }
    }

    return
}

get_next_token :: proc(p: ^Desktop_File_Parser) -> (token: Token) {
    token.start = p.offset
    token.kind  = .EOF
    if p.offset >= len(p.data) do return

    if p.data[p.offset] == ':' {
        p.offset += 1
        token.kind = .Subsection

        if p.data[p.offset] == ':' {
            p.offset += 1
            token.kind = .Section
        }

        token.start = p.offset
    }

    for p.offset < len(p.data) && p.data[p.offset] != '\n' do p.offset += 1
    if token.kind == .EOF do token.kind = .Key_Value
    token.text = p.data[token.start:p.offset]
    p.offset += 1
    return
}

parse_key_value :: proc(p: ^Desktop_File_Parser, key_value: []string) {
    if len(key_value) != 2 do return

    key := key_value[0]
    value := key_value[1]

    switch p.section {
    case .undefined: unreachable()
    case .buffers:
        switch key {
        case "filepath":
            append(&p.buffers_to_open, value)
        case:
            log.fatalf("unknown option '{}' at '{}'", key, p.offset)
            return
        }
    case .panes:
        pane_info := &p.panes_to_open[len(p.panes_to_open)-1]

        switch key {
        case "cursors":
            cursors := strings.split(value, ",", context.temp_allocator)
            for c in cursors {
                _v, ok := strconv.parse_int(c)
                if ok do append(&pane_info.cursors, _v)
            }
        case "buffer_filepath":
            pane_info.buffer_filepath = value
        case "font_size":
            _v, ok := strconv.parse_int(value)
            if ok do pane_info.font_size = _v
        case:
            log.fatalf("unknown option '{}' at '{}'", key, p.offset)
            return
        }
    case .settings:
        switch key {
        case "active_pane_index":
            _v, ok := strconv.parse_int(value)
            if ok do p.active_pane_index = clamp(_v, 0, len(p.panes_to_open)-1)
        case:
            log.fatalf("unknown option '{}' at '{}'", key, p.offset)
            return
        }
    }
}
