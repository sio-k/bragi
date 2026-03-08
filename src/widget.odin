package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

WIDGET_HEIGHT_IN_ROWS :: 15
NAMESPACE_WIDGET_SEARCH_RESULTS :: "widget.search_results"

Widget_Result :: struct {
    format:     string,
    highlights: [dynamic]Range,
    value:      Widget_Result_Value,
}

Widget_Result_Value :: union {
    Widget_Result_Buffer,
    Widget_Result_File,
    Widget_Result_Offset,
}

Widget_Result_Buffer :: ^Buffer

Widget_Result_File :: struct {
    name:     string,
    filepath: string,
    is_dir:   bool,
}

Widget_Result_Offset :: int

Find_Buffer :: struct {}
Find_File :: struct {}
Save_File_As :: struct {}
Search_In_Buffer :: struct {}

Replace_In_Buffer :: struct {
    step:     enum { step1, step2, step3 }, // 0B offset
    from:     string,                       // 8B offset (size 16B)
    to:       string,                       // 24B offset (size 16B)
}                                           // size: 40B

Widget_Action :: union {
    Find_Buffer,
    Find_File,
    Save_File_As,
    Search_In_Buffer,
    Replace_In_Buffer,
} // size 48B

Widget_Cursor :: struct {
    pos: int,   // 0B offset
    sel: int,   // 8B offset
    // the selected line or -1 if selecting the prompt
    index: int, // 16B offset
}               // size: 24B

Widget :: struct {
    // FLAGS
    active:               bool,                   // 0B offset
    cursor_selecting:     bool,                   // 1B offset
    cursor_showing:       bool,                   // 2B offset
    results_need_update:  bool,                   // 3B offset
    hide_prompt:          bool,                   // 4B offset
    ask_for_confirmation: bool,                   // 5B offset
    // 2B unused

    cursor:               Widget_Cursor,          // 8B offset (size 24B)
    cursor_blink_timer:   time.Tick,              // 32B offset

    action:               Widget_Action,          // 40B offset (size 48B)

    // the one to keep
    all_results:          [dynamic]Widget_Result, // 88B offset (size 40B)

    // the one to show, filtered and sorted
    view_results:         []Widget_Result,        // 128B offset (size 16B)

    prompt:               strings.Builder,        // 144B offset (size 40B)
    prompt_question:      string,                 // 184B offset (size 16B)

    previous_buffer:      ^Buffer,                // 200B offset

    font_regular:         ^Font,                  // 208B offset
    font_bold:            ^Font,                  // 216B offset
    rect:                 IRect,                  // 224B offset (size 16B)
    y_offset:             int,                    // 240B offset
}                                                 // size: 248B
#assert(size_of(Widget_Cursor) == 24)
#assert(size_of(time.Tick) == 8)
#assert(size_of(Widget_Action) == 48)
#assert(size_of([dynamic]Widget_Result) == 40)
#assert(size_of([]Widget_Result) == 16)
#assert(size_of(strings.Builder) == 40)
#assert(size_of(IRect) == 16)

widget_reinit :: proc(window: ^Window) {
    window.global_widget.font_regular = window.fonts_map[.UI_Regular]
    window.global_widget.font_bold    = window.fonts_map[.UI_Bold]
    assert(window.global_widget.font_regular != nil)
    assert(window.global_widget.font_bold != nil)
    widget_height := window.global_widget.font_regular.character_height * WIDGET_HEIGHT_IN_ROWS
    window.global_widget.rect = {
        0,
        window.platform.window_height - widget_height,
        window.platform.window_width,
        widget_height,
    }
}

widget_open_find_buffer :: proc(window: ^Window) {
    _widget_open(window)

    window.global_widget.action = Find_Buffer{}
    window.global_widget.prompt_question = "Switch to"

    for buffer in open_buffers {
        if window.active_pane.buffer.uuid == buffer.uuid do continue
        append(&window.global_widget.all_results, Widget_Result{
            format = _get_find_buffer_format(buffer),
            value  = buffer,
        })
    }

    slice.stable_sort_by(
        window.global_widget.all_results[:], proc(a: Widget_Result, b: Widget_Result) -> bool {
            buf1, buf2 := a.value.(^Buffer), b.value.(^Buffer)
            return time.tick_since(buf1.last_active_time) < time.tick_since(buf2.last_active_time)
        },
    )

    // ...but append the current active buffer last
    append(&window.global_widget.all_results, Widget_Result{
        format = _get_find_buffer_format(window.active_pane.buffer),
        value  = window.active_pane.buffer,
    })

    window.global_widget.view_results = slice.clone(window.global_widget.all_results[:])

    if len(window.global_widget.view_results) > 0 {
        window.global_widget.cursor.index = 0
    }
}

widget_open_find_file :: proc(window: ^Window) {
    _widget_open(window)

    current_dir := base_working_dir
    if window.active_pane.buffer.filepath != "" {
        current_dir = filepath.dir(window.active_pane.buffer.filepath, context.temp_allocator)
    }

    if !os.is_dir(current_dir) {
        current_dir = base_working_dir
    }

    strings.write_string(&window.global_widget.prompt, current_dir)

    when ODIN_OS == .Windows {
        if !strings.ends_with(current_dir, "\\") {
            strings.write_string(&window.global_widget.prompt, "\\")
        }
    } else {
        if !strings.ends_with(current_dir, "/") {
            strings.write_string(&window.global_widget.prompt, "/")
        }
    }

    _widget_find_file_open_and_read_dir(window, current_dir)

    window.global_widget.action = Find_File{}
    window.global_widget.prompt_question = "Find file"
}

widget_open_save_file_as :: proc(window: ^Window) {
    // this is like find file, but with a different prompt and a
    // different submit functionality. This will basically set the
    // current buffer's filepath to whatever the user selects.
    widget_open_find_file(window)
    window.global_widget.action = Save_File_As{}
    window.global_widget.prompt_question = "Save file as"
}

widget_open_search_in_buffer :: proc(window: ^Window) {
    _widget_open(window)

    window.global_widget.view_results = make([]Widget_Result, 0)
    window.global_widget.action = Search_In_Buffer{}
    window.global_widget.prompt_question = "Search"
}

widget_open_replace_in_buffer :: proc(window: ^Window) {
    _widget_open(window)

    window.global_widget.view_results = make([]Widget_Result, 0)
    window.global_widget.action = Replace_In_Buffer{}
    window.global_widget.prompt_question = "Replace"
}

widget_close :: proc(window: ^Window, was_quit := false) {
    if !window.global_widget.active do return
    window.global_widget.active = false

    // only when quitting
    if was_quit {
        #partial switch _ in window.global_widget.action {
        case Find_Buffer:
            switch_to_buffer(window.active_pane, window.global_widget.previous_buffer)
        }
    }

    #partial switch v in window.global_widget.action {
    case Replace_In_Buffer:
        delete(v.from)
        delete(v.to)
    }

    for r in window.global_widget.all_results {
        delete(r.format)

        switch v in r.value {
        case Widget_Result_Buffer:
        case Widget_Result_File:
            delete(v.filepath)
        case Widget_Result_Offset:
        }
    }

    delete(window.global_widget.all_results)
    _clean_up_view_results(window)

    clear(&window.active_pane.regions)
    strings.builder_destroy(&window.global_widget.prompt)

    window.global_widget.previous_buffer = nil
}

widget_keyboard_event_handler :: proc(window: ^Window, event: Event_Keyboard, cmd: Command) -> (handled: bool) {
    cursor := &window.global_widget.cursor

    _remove_selection :: proc(window: ^Window) {
        cursor := &window.global_widget.cursor

        if cursor.pos != cursor.sel {
            low := min(cursor.pos, cursor.sel)
            high := max(cursor.pos, cursor.sel)
            remove_range(&window.global_widget.prompt.buf, low, high)
            cursor.pos, cursor.sel = low, low
            window.global_widget.cursor_selecting = false
        }
    }

    if event.is_text_input {
        if cursor.pos != cursor.sel {
            _remove_selection(window)
        }

        inject_at(&window.global_widget.prompt.buf, cursor.pos, ..transmute([]byte)event.text)
        cursor.pos += len(event.text)
        cursor.sel = cursor.pos
        window.global_widget.results_need_update = true
        window.global_widget.cursor_selecting = false
        return true
    }

    word_delim_bytes := [?]byte{'\\', '/', '_', ' ', '.'}
    prompt := strings.to_string(window.global_widget.prompt)

    if window.global_widget.ask_for_confirmation && (event.key_code != .K_ENTER || event.key_code != .K_TAB) {
        window.global_widget.ask_for_confirmation = false
    }

    #partial switch cmd {
    case .toggle_selection_mode:
        if window.global_widget.cursor_selecting {
            cursor.sel = cursor.pos
        }

        window.global_widget.cursor_selecting = !window.global_widget.cursor_selecting
        return true
    case .select_all:
        cursor.pos = 0
        cursor.sel = len(prompt)
        return true
    case .move_beginning_of_buffer, .move_beginning_of_line, .select_beginning_of_buffer, .select_beginning_of_line:
        cursor.pos = 0
        if cmd != .select_beginning_of_buffer && cmd != .select_beginning_of_line && !window.global_widget.cursor_selecting {
            cursor.sel = 0
        }
        return true
    case .move_end_of_buffer, .move_end_of_line, .select_end_of_buffer, .select_end_of_line:
        cursor.pos = len(prompt)
        if cmd != .select_end_of_buffer && cmd != .select_end_of_line && !window.global_widget.cursor_selecting {
            cursor.sel = len(prompt)
        }
        return true
    case .move_up, .select_up:
        cursor.index -= 1
        if cursor.index < -1 {
            cursor.index = len(window.global_widget.view_results) - 1
        }
        return true
    case .move_down, .select_down:
        cursor.index += 1
        if cursor.index >= len(window.global_widget.view_results) {
            cursor.index = 0
        }
        return true
    case .move_left, .select_left:
        cursor.pos -= 1
        for cursor.pos > 0 && is_continuation_byte(prompt[cursor.pos]) {
            cursor.pos -= 1
        }
        cursor.pos = max(cursor.pos, 0)

        if cmd != .select_left && !window.global_widget.cursor_selecting {
            cursor.sel = cursor.pos
        }
        return true
    case .move_right, .select_right:
        cursor.pos += 1
        for cursor.pos < len(prompt) && is_continuation_byte(prompt[cursor.pos]) {
            cursor.pos += 1
        }
        cursor.pos = min(cursor.pos, len(prompt))
        if cmd != .select_right && !window.global_widget.cursor_selecting {
            cursor.sel = cursor.pos
        }
        return true
    case .move_prev_word, .move_prev_paragraph, .select_prev_word, .select_prev_paragraph:
        for cursor.pos > 0 && slice.contains(word_delim_bytes[:], prompt[cursor.pos-1])  do cursor.pos -= 1
        for cursor.pos > 0 && !slice.contains(word_delim_bytes[:], prompt[cursor.pos-1]) do cursor.pos -= 1
        if cmd != .select_prev_word && cmd != .select_prev_paragraph && !window.global_widget.cursor_selecting {
            cursor.sel = cursor.pos
        }
        return true
    case .move_next_word, .move_next_paragraph, .select_next_word, .select_next_paragraph:
        for cursor.pos < len(prompt) && !slice.contains(word_delim_bytes[:], prompt[cursor.pos]) do cursor.pos += 1
        for cursor.pos < len(prompt) && slice.contains(word_delim_bytes[:], prompt[cursor.pos])  do cursor.pos += 1
        if cmd != .select_next_word && cmd != .select_next_paragraph && !window.global_widget.cursor_selecting {
            cursor.sel = cursor.pos
        }
        return true
    case .remove_left, .remove_prev_word:
        if cursor.pos != cursor.sel {
            _remove_selection(window)
            return true
        }

        start := max(cursor.pos - 1, 0)
        if cmd == .remove_prev_word {
            for start > 0 && slice.contains(word_delim_bytes[:], prompt[start-1])  do start -= 1
            for start > 0 && !slice.contains(word_delim_bytes[:], prompt[start-1]) do start -= 1
        }

        end := cursor.pos
        remove_range(&window.global_widget.prompt.buf, start, end)
        cursor.pos = start
        cursor.sel = start
        window.global_widget.results_need_update = true
        window.global_widget.cursor_selecting = false
        return true
    case .remove_right, .remove_next_word:
        if cursor.pos != cursor.sel {
            _remove_selection(window)
            return true
        }

        start := cursor.pos
        end := min(cursor.pos + 1, len(prompt))

        if cmd == .remove_next_word {
            end = len(prompt)
        }

        remove_range(&window.global_widget.prompt.buf, start, end)
        window.global_widget.results_need_update = true
        window.global_widget.cursor_selecting = false
        return true
    case .cut_line:
        cursor.sel = len(prompt)
        _remove_selection(window)
        return true
    case .paste:
        text := platform_get_clipboard_text()
        if len(text) > 0 {
            strings.write_string(&window.global_widget.prompt, text)
            cursor.pos = len(strings.to_string(window.global_widget.prompt))
            cursor.sel = cursor.pos
            window.global_widget.results_need_update = true
        }
        return true
    }

    switch _ in window.global_widget.action {
    case Find_Buffer:       handled = find_buffer_keyboard_event_handler      (window, event, cmd)
    case Find_File:         handled = find_file_keyboard_event_handler        (window, event, cmd)
    case Save_File_As:      handled = save_file_as_keyboard_event_handler     (window, event, cmd)
    case Search_In_Buffer:  handled = search_in_buffer_keyboard_event_handler (window, event, cmd)
    case Replace_In_Buffer: handled = replace_in_buffer_keyboard_event_handler(window, event, cmd)
    }

    return
}

find_buffer_keyboard_event_handler :: proc(window: ^Window, event: Event_Keyboard, cmd: Command) -> bool {
    cursor := &window.global_widget.cursor

    #partial switch event.key_code {
    case .K_ENTER, .K_TAB:
        if cursor.index > -1 {
            result := window.global_widget.view_results[cursor.index]
            buffer := result.value.(^Buffer)
            switch_to_buffer(window.active_pane, buffer)
            widget_close(window)
            return true
        } else {
            if event.key_code == .K_TAB do return true
            if len(window.global_widget.prompt.buf) == 0 {
                // TODO(nawe) proper visual error handling here
                log.error("can't submit buffer selection without a buffer name")
                return true
            }
            buffer := buffer_get_or_create_empty(strings.to_string(window.global_widget.prompt))
            switch_to_buffer(window.active_pane, buffer)
            widget_close(window)
            return true
        }
    }

    #partial switch cmd {
    case .modifier: return true // handled as a modifier which is valid in this context
    }

    return false
}

find_file_keyboard_event_handler :: proc(window: ^Window, event: Event_Keyboard, cmd: Command) -> bool {
    cursor := &window.global_widget.cursor

    #partial switch event.key_code {
    case .K_ENTER, .K_TAB:
        if cursor.index > -1 {
            result := window.global_widget.view_results[cursor.index]
            file_info := result.value.(Widget_Result_File)

            if file_info.is_dir {
                current_dir := filepath.clean(file_info.filepath, context.temp_allocator)
                strings.builder_reset(&window.global_widget.prompt)
                strings.write_string(&window.global_widget.prompt, current_dir)
                strings.write_string(&window.global_widget.prompt, "/")
                cursor.index = -1
                _widget_find_file_open_and_read_dir(window, current_dir)
            } else {
                data, success := os.read_entire_file(file_info.filepath, context.temp_allocator)
                if !success {
                    log.fatalf("failed to read file '{}'", file_info.filepath)
                    widget_close(window)
                    return true
                }
                buffer := buffer_get_or_create_from_file(file_info.filepath, data)
                switch_to_buffer(window.active_pane, buffer)
                widget_close(window)
            }

            return true
        } else {
            if event.key_code == .K_TAB do return true
            fullpath := strings.to_string(window.global_widget.prompt)
            _, name_from_fullpath := filepath.split(fullpath)

            if len(fullpath) == 0 || len(name_from_fullpath) == 0 {
                log.errorf("cannot create empty file")
                return true
            } else {
                // if the prompt is a file that is being viewed
                // but is not selected, search it, select it and
                // resubmit the event.
                for result, index in window.global_widget.view_results {
                    file_info := result.value.(Widget_Result_File)

                    if file_info.filepath == fullpath {
                        cursor.index = index
                        return find_file_keyboard_event_handler(window, event, cmd)
                    }
                }

                // if it wasn't, create the buffer for the new file.
                buffer := buffer_get_or_create_from_file(fullpath, {})
                switch_to_buffer(window.active_pane, buffer)
                widget_close(window)
                return true
            }
        }
    }

    return false
}

save_file_as_keyboard_event_handler :: proc(window: ^Window, event: Event_Keyboard, cmd: Command) -> bool {
    cursor := &window.global_widget.cursor

    #partial switch event.key_code {
    case .K_ENTER, .K_TAB:
        new_fullpath := strings.to_string(window.global_widget.prompt)

        if window.global_widget.ask_for_confirmation && event.key_code == .K_ENTER {
            buffer_save_as(window.active_pane.buffer, new_fullpath)
            widget_close(window)
            return true
        }

        if cursor.index > -1 {
            result := window.global_widget.view_results[cursor.index]
            file_info := result.value.(Widget_Result_File)

            if file_info.is_dir {
                current_dir := filepath.clean(file_info.filepath, context.temp_allocator)
                strings.builder_reset(&window.global_widget.prompt)
                strings.write_string(&window.global_widget.prompt, current_dir)
                strings.write_string(&window.global_widget.prompt, "/")
                cursor.index = -1
                _widget_find_file_open_and_read_dir(window, current_dir)
            } else {
                strings.builder_reset(&window.global_widget.prompt)
                strings.write_string(&window.global_widget.prompt, file_info.filepath)
                cursor.pos = len(window.global_widget.prompt.buf)
                cursor.sel = cursor.pos
                cursor.index = -1
                window.global_widget.ask_for_confirmation = true
            }

            return true
        } else {
            if event.key_code == .K_TAB do return true
            _, name_from_fullpath := filepath.split(new_fullpath)

            if len(new_fullpath) == 0 || len(name_from_fullpath) == 0 {
                log.errorf("cannot create empty file")
                return true
            } else {
                // if the prompt already exists in the results,
                // select it and resubmit the event
                for result, index in window.global_widget.view_results {
                    file_info := result.value.(Widget_Result_File)

                    if file_info.filepath == new_fullpath {
                        cursor.index = index
                        return save_file_as_keyboard_event_handler(window, event, cmd)
                    }
                }

                // or just save if it wasn't in the results
                buffer_save_as(window.active_pane.buffer, new_fullpath)
                widget_close(window)
            }

            return true
        }
    }

    return false
}

search_in_buffer_keyboard_event_handler :: proc(window: ^Window, event: Event_Keyboard, cmd: Command) -> bool {
    _set_last_search_term :: proc(window: ^Window) {
        if len(window.global_widget.prompt.buf) == 0 && len(last_search_term) > 0 {
            strings.write_string(&window.global_widget.prompt, last_search_term)
            window.global_widget.results_need_update = true
        }
    }

    cursor := &window.global_widget.cursor

    #partial switch event.key_code {
    case .K_ENTER, .K_TAB:
        pane_cursor := get_first_active_cursor(window.active_pane)
        pane_cursor.sel = pane_cursor.pos
        widget_close(window)
        return true
    }

    #partial switch cmd {
    case .search_backward:
        _set_last_search_term(window)

        if len(window.global_widget.view_results) > 0 {
            cursor.index -= 1
            if cursor.index < 0 {
                cursor.index = len(window.global_widget.view_results) - 1
            }
        }

        return true
    case .search_forward:
        _set_last_search_term(window)

        if len(window.global_widget.view_results) > 0 {
            cursor.index += 1
            if cursor.index >= len(window.global_widget.view_results) {
                cursor.index = 0
            }
        }

        return true
    }

    return false
}

replace_in_buffer_keyboard_event_handler :: proc(window: ^Window, event: Event_Keyboard, cmd: Command) -> bool {
    do_select :: proc(window: ^Window) {
        action := &window.global_widget.action.(Replace_In_Buffer)
        cursor := &window.global_widget.cursor
        result := window.global_widget.view_results[cursor.index]
        offset := result.value.(int)
        pane_cursor := get_first_active_cursor(window.active_pane)
        pane_cursor.pos = offset + len(action.from)
        pane_cursor.sel = offset
        pane_maybe_recenter_cursor(window.active_pane, true)
        window.active_pane.cursor_moved = true
    }

    action := &window.global_widget.action.(Replace_In_Buffer)
    cursor := &window.global_widget.cursor

    #partial switch event.key_code {
    case .K_ENTER, .K_TAB, .K_EXCLAIM:
        switch action.step {
        case .step1:
            if len(window.global_widget.view_results) == 0 {
                log.debug("nothing to replace")
                widget_close(window)
                return true
            }

            action.step = .step2
            action.from = strings.clone(strings.to_string(window.global_widget.prompt))
            strings.builder_reset(&window.global_widget.prompt)
            cursor.pos = 0
            cursor.sel = 0
        case .step2:
            action.step = .step3
            action.to = strings.clone(strings.to_string(window.global_widget.prompt))
            strings.builder_reset(&window.global_widget.prompt)
            strings.write_string(&window.global_widget.prompt, action.from)
            cursor.pos = 0
            cursor.sel = 0
            window.global_widget.hide_prompt = true
        case .step3:
            if event.key_code == .K_EXCLAIM {
                clear(&window.active_pane.cursors)
                for result in window.global_widget.view_results {
                    offset := result.value.(int)
                    cursor := add_cursor(window.active_pane, offset)
                    cursor.pos = offset + len(action.from)
                }

                copy_cursors(window.active_pane, window.active_pane.buffer)
                pane_insert_at_points(window.active_pane, action.to)
                last_cursor := window.active_pane.cursors[len(window.active_pane.cursors) - 1]
                clear(&window.active_pane.cursors)
                add_cursor(window.active_pane, last_cursor.pos)
                widget_close(window)
            } else if event.key_code == .K_ENTER {
                copy_cursors(window.active_pane, window.active_pane.buffer)
                pane_insert_at_points(window.active_pane, action.to)
                window.active_pane.cursor_moved = true
                window.global_widget.results_need_update = true
            } else if event.key_code == .K_TAB {
                cursor.index += 1
                if cursor.index >= len(window.global_widget.view_results) {
                    cursor.index = 0
                }
                do_select(window)
            }
        }

        return true
    }

    return false
}

update_and_draw_widget :: proc(window: ^Window) {
    if !window.global_widget.active do return

    cursor := &window.global_widget.cursor

    if time.tick_diff(window.last_keystroke, time.tick_now()) < CURSOR_RESET_TIMEOUT {
        window.global_widget.cursor_showing = true
        window.global_widget.cursor_blink_timer = time.tick_now()
    }

    if time.tick_diff(window.global_widget.cursor_blink_timer, time.tick_now()) > CURSOR_BLINK_TIMEOUT {
        window.global_widget.cursor_showing = !window.global_widget.cursor_showing
        window.global_widget.cursor_blink_timer = time.tick_now()
    }

    switch _ in window.global_widget.action {
    case Find_Buffer:               _find_buffer_widget_update(window)
    case Find_File, Save_File_As:   _find_or_save_file_widget_update(window)
    case Search_In_Buffer:          _search_in_buffer_widget_update(window)
    case Replace_In_Buffer:         _replace_in_buffer_widget_update(window)
    }

    for cursor.index > WIDGET_HEIGHT_IN_ROWS - 2 + window.global_widget.y_offset {
        window.global_widget.y_offset += 1
    }
    for cursor.index < window.global_widget.y_offset {
        window.global_widget.y_offset -= 1
    }
    if cursor.index <= 0 {
        window.global_widget.y_offset = 0
    }

    set_scissors(window, &window.global_widget.rect)

    prompt_ask_str := fmt.tprintf(
        "{}/{}  {}: ",
        cursor.index + 1,
        len(window.global_widget.view_results),
        window.global_widget.prompt_question,
    )

    font_regular := window.global_widget.font_regular
    font_bold    := window.global_widget.font_bold
    line_height := font_regular.character_height
    left_padding := font_regular.xadvance
    results_pen := Vector2{left_padding, line_height}

    results_pen.y -= i32(window.global_widget.y_offset) * line_height

    for &result, index in window.global_widget.view_results {
        if results_pen.y > WIDGET_HEIGHT_IN_ROWS * line_height do break

        if results_pen.y < line_height {
            results_pen.y += line_height
            continue
        }

        is_selected := cursor.index == index

        if is_selected {
            set_color(window, .ui_selection_background)
            draw_rect(
                window,
                0, results_pen.y,
                i32(window.global_widget.rect.w), line_height,
                true,
            )
        }

        results_pen = draw_highlighted_text(
            window,
            font_regular, font_bold,
            .foreground, .ui_selection_background, .ui_selection_foreground,
            results_pen, result.format, result.highlights[:], is_selected,
        )
    }

    prompt_query_str := strings.to_string(window.global_widget.prompt)

    set_color(window, .ui_border)
    draw_line(window, 0, 0, i32(window.global_widget.rect.w), 0)
    draw_line(window, 0, line_height, i32(window.global_widget.rect.w), line_height)

    if window.global_widget.ask_for_confirmation {
        question: string
        answer: string

        switch v in window.global_widget.action {
        case Find_Buffer:
        case Find_File:
        case Save_File_As:
            question = fmt.tprintf("Overwrite: {}? ", prompt_query_str)
            answer = "<ENTER>"
        case Search_In_Buffer:
        case Replace_In_Buffer:
        }

        set_colors(window, .highlight, {font_bold, font_regular})
        prompt_pen := draw_text(window, font_bold, {left_padding, 0}, question)
        draw_text(window, font_regular, prompt_pen, answer)
    } else {
        if cursor.index == -1 {
            set_color(window, .ui_selection_background)
            draw_rect(window, 0, 0, i32(len(prompt_ask_str)) * font_bold.xadvance, line_height, true)
            set_color(window, .ui_selection_foreground, font_bold)
        } else {
            set_color(window, .highlight, font_bold)
        }

        set_color(window, .foreground, font_regular)
        prompt_ask_pen := draw_text(window, font_bold, {left_padding, 0}, prompt_ask_str)
        if !window.global_widget.hide_prompt {
            draw_text_line(window, font_regular, prompt_ask_pen, prompt_query_str, {start = cursor.pos, end = cursor.sel})
        }

        cursor_pen := prompt_ask_pen
        cursor_pen.x += prepare_text(window, font_regular, prompt_query_str[:cursor.pos])
        rune_behind_cursor := ' '
        if !window.global_widget.hide_prompt && cursor.pos < len(prompt_query_str) {
            rune_behind_cursor = utf8.rune_at(prompt_query_str, cursor.pos)
        }
        draw_cursor(window, font_regular, cursor_pen, rune_behind_cursor, window.global_widget.cursor_showing, true, true)
    }

    set_scissors(window)
}

@(private="file")
_get_find_buffer_format :: proc(buffer: ^Buffer) -> string {
    MAX_NAME_LENGTH :: 24
    MIN_PADDING     :: 5

    result := strings.builder_make(context.temp_allocator)
    truncated_name := buffer.name

    if len(buffer.name) > MAX_NAME_LENGTH {
        truncated_name = fmt.tprintf("{}...", buffer.name[:MAX_NAME_LENGTH - MIN_PADDING])
    }

    strings.write_string(&result, strings.left_justify(truncated_name, MAX_NAME_LENGTH, " ", context.temp_allocator))
    strings.write_string(&result, buffer.filepath)
    strings.write_byte(&result, '\n')
    return strings.clone(strings.to_string(result))
}

@(private="file")
_get_find_file_format :: proc(file: os.File_Info) -> string {
    result := strings.builder_make(context.temp_allocator)
    strings.write_string(&result, file.name)
    if file.is_dir do strings.write_string(&result, "/")
    strings.write_byte(&result, '\n')
    return strings.clone(strings.to_string(result))
}

@(private="file")
_get_search_in_buffer_format :: proc(window: ^Window, offset, found: int) -> string {
    MAX_LENGTH  :: 60
    MIN_PADDING :: 5

    pane := window.active_pane
    start := offset
    end := start
    coords := cursor_offset_to_coords(pane, get_lines_array(pane), found)

    for r in pane.buffer.text[start:] {
        if r == '\n' do break
        if end - start == MAX_LENGTH do break
        end += 1
    }

    search_result := fmt.tprintf("{}...", pane.buffer.text[start:end])
    line_column := fmt.tprintf("({}, {})", coords.row + 1, coords.column)

    result := strings.builder_make(context.temp_allocator)
    strings.write_string(&result, strings.left_justify(
        search_result, MAX_LENGTH + MIN_PADDING, " ", context.temp_allocator,
    ))
    strings.write_string(&result, line_column)
    strings.write_string(&result, "\n")
    return strings.clone(strings.to_string(result))
}

@(private="file")
_widget_find_file_open_and_read_dir :: proc(window: ^Window, current_dir: string) {
    // cleaning up because it was called from an already existing opened widget
    if len(window.global_widget.all_results) > 0 {
        _clean_up_view_results(window)
        for r in window.global_widget.all_results {
            delete(r.format)
            #partial switch v in r.value {
            case Widget_Result_File: delete(v.filepath)
            }
        }
        clear(&window.global_widget.all_results)
    }

    if !os.is_dir(current_dir) {
        window.global_widget.view_results = slice.clone(window.global_widget.all_results[:])
        return
    }

    dir_handle, dir_open_error := os.open(current_dir)
    if dir_open_error != nil {
        log.fatalf("failed to open directory '{}' with error {}", current_dir, dir_open_error)
        widget_close(window)
        return
    }
    defer os.close(dir_handle)
    file_infos, read_dir_error := os.read_dir(dir_handle, 0, context.temp_allocator)

    if read_dir_error != nil {
        log.fatalf("failed to read directory '{}' with error {}", current_dir, read_dir_error)
        widget_close(window)
        return
    }

    for file_info in file_infos {
        fullpath := strings.clone(file_info.fullpath)

        append(&window.global_widget.all_results, Widget_Result{
            format    = _get_find_file_format(file_info),
            value     = Widget_Result_File{
                filepath = fullpath,
                name     = filepath.base(fullpath),
                is_dir   = file_info.is_dir,
            },
        })
    }

    slice.sort_by_key(window.global_widget.all_results[:], proc(key: Widget_Result) -> string {
        return key.format
    })

    window.global_widget.view_results = slice.clone(window.global_widget.all_results[:])

    window.global_widget.cursor.pos = len(window.global_widget.prompt.buf)
    window.global_widget.cursor.sel = window.global_widget.cursor.pos
}

@(private="file")
_get_filtered_all_results_with_current_query :: proc(window: ^Window, test_query: string) -> []Widget_Result{
    profiling_start("filter all results with query")
    view_results_temp := make([dynamic]Widget_Result, 0, len(window.global_widget.all_results), context.temp_allocator)
    queries := strings.split(test_query, " ", context.temp_allocator)

    for item in window.global_widget.all_results {
        result := item
        should_process := true

        for query in queries {
            if len(query) == 0 do continue
            if !strings.contains(item.format, query) {
                should_process = false
                break
            }
        }

        // skip as one of the query components is not present in this result
        if !should_process do continue

        for query in queries {
            if len(query) == 0 do continue
            test_str := item.format
            start := strings.index(item.format, query)
            original_len := len(item.format)
            query_len := len(query)

            for start != -1 && len(test_str) > query_len {
                start += original_len - len(test_str)
                end := start + query_len
                append(&result.highlights, Range{start, end})
                test_str = item.format[end:]
                start = strings.index(test_str, query)
            }
        }

        if len(result.highlights) > 0 {
            append(&view_results_temp, result)
        }
    }
    profiling_end()

    return slice.clone(view_results_temp[:])
}

@(private="file")
_clean_up_view_results :: #force_inline proc(window: ^Window) {
    for &result in window.global_widget.view_results {
        delete(result.highlights)
    }
    delete(window.global_widget.view_results)
}

// NOTE(nawe) a generic procedure to make sure we clean up opened
// widget (if any) and set the defaults again
@(private="file")
_widget_open :: proc(window: ^Window) {
    if window.global_widget.active do widget_close(window)

    window.global_widget.all_results = make([dynamic]Widget_Result, 0, WIDGET_HEIGHT_IN_ROWS)
    window.global_widget.cursor.pos = 0
    window.global_widget.cursor.sel = 0
    window.global_widget.cursor.index = -1
    window.global_widget.active = true
    window.global_widget.hide_prompt = false
    window.global_widget.ask_for_confirmation = false
    window.global_widget.previous_buffer = window.active_pane.buffer
    flag_pane(window.active_pane, {.Need_Full_Repaint})
}

@(private="file")
_search_in_buffer_widget_update :: proc(window: ^Window) {
    _select_result_with_pane_cursor :: proc(window: ^Window) {
        cursor := &window.global_widget.cursor

        if cursor.index >= len(window.global_widget.view_results) {
            cursor.index = -1
            return
        }

        if cursor.index > -1 {
            result := window.global_widget.view_results[cursor.index]
            offset := result.value.(int)
            pane_cursor := get_first_active_cursor(window.active_pane)
            pane_cursor.pos = offset + len(window.global_widget.prompt.buf)
            pane_cursor.sel = offset
            pane_maybe_recenter_cursor(window.active_pane, true)
        }
    }

    cursor := &window.global_widget.cursor
    query := strings.to_string(window.global_widget.prompt)
    query_len := len(query)

    _select_result_with_pane_cursor(window)

    if !window.global_widget.results_need_update do return
    window.global_widget.results_need_update = false

    if len(query) == 0 {
        _clean_up_view_results(window)
        window.global_widget.view_results = make([]Widget_Result, 0)
    }

    // don't do anything if there's no content where we can search
    if len(window.active_pane.buffer.text) == 0 || len(query) == 0 do return

    // cleaning up because it was called from an already existing opened widget
    if len(window.global_widget.all_results) > 0 {
        _clean_up_view_results(window)
        for r in window.global_widget.all_results do delete(r.format)
        clear(&window.global_widget.all_results)
        clear(&window.active_pane.regions)
    }

    buf := window.active_pane.buffer.text
    buf_len := len(buf)
    left_index := 0
    right_index := buf_len - 1

    for left_index < right_index && right_index > 0 {
        // left side
        if buf[left_index] == query[0] && left_index + query_len < buf_len {
            test_word := buf[left_index:left_index + query_len]
            if query == test_word {
                word_start_index, _ := translate_position(window.active_pane, left_index, .beginning_of_word)
                start := left_index - word_start_index
                end := start+query_len

                result := Widget_Result{
                    format = _get_search_in_buffer_format(window, word_start_index, left_index),
                    value  = left_index,
                }
                append(&result.highlights, Range{start, end})
                append(&window.global_widget.all_results, result)

                append(&window.active_pane.regions, Highlight{
                    namespace  = NAMESPACE_WIDGET_SEARCH_RESULTS,
                    start      = left_index,
                    end        = left_index + query_len,
                    background = .search_background,
                    foreground = .search_foreground,
                })

                left_index += query_len
            }
        }

        // right side
        if buf[right_index] == query[0] && right_index + query_len < buf_len {
            test_word := buf[right_index:right_index + query_len]
            if query == test_word {
                word_start_index, _ := translate_position(window.active_pane, right_index, .beginning_of_word)
                start := right_index - word_start_index
                end := start+query_len

                result := Widget_Result{
                    format = _get_search_in_buffer_format(window, word_start_index, right_index),
                    value  = right_index,
                }
                append(&result.highlights, Range{start, end})
                append(&window.global_widget.all_results, result)

                append(&window.active_pane.regions, Highlight{
                    namespace  = NAMESPACE_WIDGET_SEARCH_RESULTS,
                    start      = right_index,
                    end        = right_index + query_len,
                    background = .search_background,
                    foreground = .search_foreground,
                })
            }
        }

        left_index += 1
        right_index -= 1
    }

    slice.sort_by(window.global_widget.all_results[:], proc(a: Widget_Result, b: Widget_Result) -> bool {
        offset1, offset2 := a.value.(int), b.value.(int)
        return offset1 < offset2
    })

    window.global_widget.view_results = slice.clone(window.global_widget.all_results[:])

    if len(window.global_widget.view_results) == 0 {
        cursor.index = -1
        return
    }

    // find the closest offset
    pane_cursor := get_first_active_cursor(window.active_pane)
    smallest_diff := len(window.active_pane.buffer.text)
    window.global_widget.y_offset = 0

    for result, index in window.global_widget.view_results {
        result_offset := result.value.(int)
        low := min(result_offset, pane_cursor.pos)
        high := max(result_offset, pane_cursor.pos)
        diff := high - low

        if diff < smallest_diff {
            cursor.index = index
            smallest_diff = diff
        }
    }

    _select_result_with_pane_cursor(window)

    delete(last_search_term)
    last_search_term = strings.clone(query)
}

@(private="file")
_find_buffer_widget_update :: proc(window: ^Window) {
    cursor := &window.global_widget.cursor

    if cursor.index > -1 {
        item := window.global_widget.view_results[cursor.index]
        buffer := item.value.(^Buffer)

        if window.active_pane.buffer != buffer {
            switch_to_buffer(window.active_pane, buffer)
        }
    }

    if !window.global_widget.results_need_update do return

    window.global_widget.results_need_update = false
    _clean_up_view_results(window)
    query := strings.to_string(window.global_widget.prompt)

    if len(query) > 0 {
        window.global_widget.view_results = _get_filtered_all_results_with_current_query(window, query)
    } else {
        window.global_widget.view_results = slice.clone(window.global_widget.all_results[:])
    }
    cursor.index = len(window.global_widget.view_results) > 0 ? 0 : -1
}

@(private="file")
_find_or_save_file_widget_update :: proc(window: ^Window) {
    if !window.global_widget.results_need_update do return
    window.global_widget.results_need_update = false

    cursor := &window.global_widget.cursor
    query := strings.to_string(window.global_widget.prompt)
    query_starting_index := strings.index(query, "/~/")

    if query_starting_index != -1 || strings.starts_with(query, "~/") {
        query_first_part: string

        when ODIN_OS == .Windows {
            query_first_part = base_working_dir
        } else {
            value, found := os.lookup_env("HOME", context.temp_allocator)
            query_first_part = found ? value : base_working_dir
        }

        // maybe append the rest of the query
        rest_of_query := query[query_starting_index + 3:]
        query = fmt.tprintf("{}/{}", query_first_part, rest_of_query)
        strings.builder_reset(&window.global_widget.prompt)
        strings.write_string(&window.global_widget.prompt, query)
        cursor.pos = len(query)
        cursor.sel = cursor.pos
    }

    if len(query) > 0 {
        current_dir := filepath.dir(query, context.temp_allocator)
        matches_previous_dir := false

        if len(window.global_widget.all_results) > 0 {
            previous_result_to_test := window.global_widget.all_results[0]
            file_to_test := previous_result_to_test.value.(Widget_Result_File)
            previous_dir := filepath.dir(file_to_test.filepath, context.temp_allocator)
            matches_previous_dir = current_dir == previous_dir
        }

        if !matches_previous_dir {
            _widget_find_file_open_and_read_dir(window, current_dir)
        }

        _clean_up_view_results(window)

        // only care about the last part as it is the part shown in the format
        query_replaced, _ := filepath.to_slash(query, context.temp_allocator)
        last_slash_index := max(strings.last_index_byte(query_replaced, '/'), 0)
        last_part_of_query := query[last_slash_index + 1:]

        if len(last_part_of_query) > 0 {
            window.global_widget.view_results = _get_filtered_all_results_with_current_query(window, last_part_of_query)
        } else {
            window.global_widget.view_results = slice.clone(window.global_widget.all_results[:])
        }

        cursor.index = len(window.global_widget.view_results) > 0 ? 0 : -1
    } else {
        _clean_up_view_results(window)

        if len(window.global_widget.all_results) > 0 {
            window.global_widget.view_results = slice.clone(window.global_widget.all_results[:])
        } else {
            strings.write_string(&window.global_widget.prompt, base_working_dir)
            _widget_find_file_open_and_read_dir(window, base_working_dir)
        }
    }
}

@(private="file")
_replace_in_buffer_widget_update :: proc(window: ^Window) {
    action := &window.global_widget.action.(Replace_In_Buffer)

    switch action.step {
    case .step1:
        _search_in_buffer_widget_update(window)
    case .step2:
        window.global_widget.prompt_question = fmt.tprintf("Replace {} with", action.from)
    case .step3:
        window.global_widget.prompt_question = fmt.tprintf(
            "Replace {} with {} | Yes: <ENTER> No: <TAB> All: <!>", action.from, action.to,
        )

        _search_in_buffer_widget_update(window)

        if len(window.global_widget.view_results) == 0 {
            last_cursor := window.active_pane.cursors[len(window.active_pane.cursors)-1]
            clear(&window.active_pane.cursors)
            add_cursor(window.active_pane, last_cursor.pos)
            widget_close(window)
        }
    }
}
