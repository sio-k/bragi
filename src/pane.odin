package main

import "core:encoding/uuid"
import "core:fmt"
import "core:log"
import "core:slice"
import "core:time"
import "core:unicode/utf8"

CURSOR_BLINK_MAX_COUNT :: 6
CURSOR_BLINK_TIMEOUT   :: 500 * time.Millisecond
CURSOR_RESET_TIMEOUT   :: 100 * time.Millisecond

MINIMUM_GUTTER_PADDING     :: 3
GUTTER_LINE_NUMBER_JUSTIFY :: 2

Pane_Flags :: bit_set[Pane_Flag; u8]

Pane_Flag :: enum u8 {
    Line_Wrappings    = 0,
    Need_Full_Repaint = 1,
}

Translation :: enum u16 {
    start, end,
    down, left, right, up,
    prev_word, next_word,
    prev_paragraph, next_paragraph,
    prev_page, next_page,
    beginning_of_line, end_of_line,
}

Pane :: struct {
    uuid:                uuid.Identifier,
    cursors:             [dynamic]Cursor,
    cursor_moved:        bool,
    cursor_selecting:    bool, // mode like region-mode in Emacs
    cursor_showing:      bool, // for rendering, hiding during blink interludes
    cursor_blink_count:  int,
    cursor_blink_timer:  time.Tick,

    buffer:              ^Buffer,
    regions:             [dynamic]Highlight,
    wrapped_line_starts: [dynamic]int,
    local_font_size:     f32,
    font:                ^Font,
    flags:               Pane_Flags,

    // rendering stuff
    rect:                Rect,
    texture:             ^Texture,
    x_offset:            int,
    y_offset:            int,
}

Cursor :: struct {
    active: bool,
    pos:    int,
    sel:    int,

    // NOTE(nawe) like Emacs, I want to align the cursor to the last
    // largest offset if possible, this is very helpful when
    // navigating up and down a buffer. If the current row is larger
    // than last_column, the cursor will be positioned at last_cursor,
    // if it is smaller, it will be positioned at the end of the
    // row. Some commands will reset this value to -1.
    last_column: int,
}

Code_Line :: struct {
    line:               string,
    line_is_wrapped:    bool, // this line continues on the next line
    start_offset:       int,
    tokens:             []Token_Kind,
}

pane_create :: proc(pane: ^Pane = nil) -> ^Pane {
    log.debug("creating new pane")
    result := new(Pane)

    result.uuid = uuid.generate_v6()
    result.cursor_moved = true
    result.cursor_showing = true
    result.cursor_blink_count = 0
    result.cursor_blink_timer = time.tick_now()
    result.local_font_size = f32(settings.editor_font_size)

    if settings.always_wrap_lines {
        flag_pane(result, {.Line_Wrappings})
    }

    if pane == nil {
        add_cursor(result)
        result.buffer = buffer_get_or_create_empty()
    } else {
        delete(result.cursors)
        result.cursors = slice.clone_to_dynamic(pane.cursors[:])
        result.buffer = pane.buffer
        result.local_font_size = pane.local_font_size
    }

    append(&open_panes, result)
    update_all_pane_textures()
    return result
}

pane_destroy :: proc(pane: ^Pane) {
    pane.buffer = nil
    delete(pane.regions)
    delete(pane.cursors)
    delete(pane.wrapped_line_starts)
    free(pane)
}

update_active_pane :: proc() {
    should_cursor_blink :: proc(pane: ^Pane) -> bool {
        return pane.cursor_blink_count < CURSOR_BLINK_MAX_COUNT &&
            time.tick_diff(pane.cursor_blink_timer, time.tick_now()) > CURSOR_BLINK_TIMEOUT
    }
    profiling_start("active_pane")
    pane := active_pane

    if time.tick_diff(last_keystroke, time.tick_now()) < CURSOR_RESET_TIMEOUT {
        pane.cursor_showing = true
        pane.cursor_blink_count = 0
        pane.cursor_blink_timer = time.tick_now()
        flag_pane(pane, {.Need_Full_Repaint})
    }

    if should_cursor_blink(pane) {
        pane.cursor_showing = !pane.cursor_showing
        pane.cursor_blink_count += 1
        pane.cursor_blink_timer = time.tick_now()

        if pane.cursor_blink_count >= CURSOR_BLINK_MAX_COUNT {
            pane.cursor_showing = true
        }

        flag_pane(pane, {.Need_Full_Repaint})
    }

    if pane.cursor_moved {
        pane.cursor_moved = false
        maybe_scroll_pane_to_cursor_view(pane)
    }

    profiling_end()
}

draw_panes :: proc() {
    profiling_start("draw all panes")

    for pane in open_panes {
        assert(pane.buffer != nil)
        assert(pane.texture != nil)
        assert(len(pane.cursors) > 0)

        if .Need_Full_Repaint not_in pane.flags {
            draw_texture(pane.texture, nil, &pane.rect)
            continue
        }

        set_target(pane.texture)
        set_color(.background)
        prepare_for_drawing()

        visible_rows := get_pane_visible_rows(pane)
        size_of_gutter := get_gutter_size(pane)
        initial_pen := Vector2{size_of_gutter, 0}
        if settings.modeline_position == .top do initial_pen.y = get_modeline_height()

        lines := get_lines_array(pane)
        first_row := pane.y_offset
        last_row := min(pane.y_offset + visible_rows + 1, len(lines) - 1)
        first_offset, last_offset := lines[first_row], lines[last_row]
        code_lines := make([dynamic]Code_Line, context.temp_allocator)
        highlights := make([dynamic]Highlight, 0, len(pane.cursors), context.temp_allocator)

        for cursor in pane.cursors {
            if !has_selection(cursor) do continue
            if (cursor.pos < first_offset || cursor.pos > last_offset) &&
                (cursor.sel < first_offset || cursor.sel > last_offset) {
                    continue
                }

            low, high := sorted_cursor(cursor)
            append(&highlights, Highlight{
                start        = low,
                end          = high,
                background   = .region,
                foreground   = .undefined, // let the tokenizer decide
                expands_line = true,
            })
        }

        append(&highlights, ..pane.regions[:])

        for line_number in first_row..<last_row {
            code_line := Code_Line{}
            start, end := get_line_boundaries(line_number, lines)
            code_line.start_offset = start
            code_line.line = pane.buffer.text[start:end]
            code_line.line_is_wrapped = is_line_wrapped(pane, line_number)

            if end <= len(pane.buffer.tokens) {
                code_line.tokens = pane.buffer.tokens[start:end]
            }

            append(&code_lines, code_line)
        }

        draw_code(pane, pane.font, initial_pen, code_lines[:], highlights[:])

        for cursor in pane.cursors {
            out_of_bounds, cursor_pen, rune_behind_cursor :=
                prepare_cursor_for_drawing(pane, pane.font, initial_pen, cursor)
            _ = rune_behind_cursor

            if !out_of_bounds do draw_cursor(
                pane.font, cursor_pen, rune_behind_cursor,
                pane.cursor_showing, is_pane_focused(pane), cursor.active,
            )
        }

        draw_gutter(pane)
        draw_modeline(pane)

        set_target()
        draw_texture(pane.texture, nil, &pane.rect)
        unflag_pane(pane, {.Need_Full_Repaint})
    }
    profiling_end()
}

update_pane_font :: #force_inline proc(pane: ^Pane) {
    scaled_character_height := font_to_scaled_pixels(pane.local_font_size)
    pane.font = get_font_with_size(FONT_EDITOR_NAME, FONT_EDITOR_DATA, scaled_character_height)
}

update_all_pane_textures :: proc() {
    // should be safe to clean up textures here since we're probably
    // recreating them due to the change in size
    pane_width := window_width / i32(len(open_panes))
    pane_height := window_height

    for &pane, index in open_panes {
        update_pane_font(pane)
        texture_destroy(pane.texture)

        pane.rect = make_rect(pane_width * i32(index), 0, pane_width, pane_height)
        pane.texture = texture_create(.TARGET, i32(pane_width), i32(pane_height))
        if .Line_Wrappings in pane.flags do recalculate_line_wrappings(pane)
        flag_pane(pane, {.Need_Full_Repaint})
    }
}

recalculate_line_wrappings :: proc(pane: ^Pane) {
    should_carry_over :: proc(pane: ^Pane, offset: int) -> bool {
        return pane.buffer.text[offset] != ' ' && pane.buffer.text[offset] != '\n'
    }

    go_back_one :: proc(pane: ^Pane, offset: ^int) {
        offset^ -=1
        for is_continuation_byte(pane.buffer.text[offset^]) do offset^ -= 1
    }

    // less than this per line looks weird in code, so maybe we just
    // don't wrap it.
    MINIMUM_COLUMN_SPACE_REQUIRED_TO_WRAP :: 50
    // if we don't find a space before this, we break anyways
    MAX_ROLLBACK_THRESHOLD :: 20

    buffer_lines := pane.buffer.line_starts[:]
    max_column_space := get_pane_visible_columns(pane)

    if max_column_space < MINIMUM_COLUMN_SPACE_REQUIRED_TO_WRAP {
        delete(pane.wrapped_line_starts)
        pane.wrapped_line_starts = slice.clone_to_dynamic(pane.buffer.line_starts[:])
        return
    }

    clear(&pane.wrapped_line_starts)
    reserve(&pane.wrapped_line_starts, len(buffer_lines))

    for line_index := 0; line_index < len(buffer_lines) - 1; line_index += 1 {
        start, end := get_line_boundaries(line_index, buffer_lines)
        actual_columns := utf8.rune_count_in_string(pane.buffer.text[start:end])

        append(&pane.wrapped_line_starts, start)

        if actual_columns >= max_column_space {
            count := 0

            for offset := start; offset < end; offset += 1 {
                count += 1

                for offset < end && is_continuation_byte(pane.buffer.text[offset]) do offset += 1

                if count >= max_column_space {
                    // go back to the beginning of the word, we only
                    // want word wrapping.
                    before_rollback_offset := offset
                    go_back_one(pane, &offset)

                    for !should_carry_over(pane, offset) do go_back_one(pane, &offset)
                    for should_carry_over(pane, offset) {
                        go_back_one(pane, &offset)

                        if before_rollback_offset - offset > MAX_ROLLBACK_THRESHOLD {
                            offset = before_rollback_offset
                            go_back_one(pane, &offset)
                            break
                        }
                    }

                    count = 0
                    append(&pane.wrapped_line_starts, offset + 1)
                }
            }
        }
    }

    append(&pane.wrapped_line_starts, len(pane.buffer.text) + 1)
}

flag_pane :: #force_inline proc(pane: ^Pane, flags: Pane_Flags) {
    pane.flags += flags
}

unflag_pane :: #force_inline proc(pane: ^Pane, flags: Pane_Flags) {
    pane.flags -= flags
}

add_cursor :: proc(pane: ^Pane, pos := 0) {
    append(&pane.cursors, Cursor{
        active = true,
        pos = pos,
        sel = pos,
        last_column = -1,
    })
}

clone_cursor :: proc(pane: ^Pane, cursor_to_clone: Cursor) -> ^Cursor {
    append(&pane.cursors, cursor_to_clone)
    return &pane.cursors[len(pane.cursors) - 1]
}

cursor_has_selection :: proc(cursor: Cursor) -> bool {
    return cursor.pos != cursor.sel
}

get_first_active_cursor :: #force_inline proc(pane: ^Pane) -> (result: ^Cursor) {
    for &cursor in pane.cursors {
        if cursor.active do return &cursor
    }

    unreachable()
}

are_all_cursors_active :: #force_inline proc(pane: ^Pane) -> bool {
    if len(pane.cursors) == 1 do return true
    for cursor in pane.cursors {
        if !cursor.active do return false
    }
    return true
}

prepare_cursor_for_drawing :: #force_inline proc(
    pane: ^Pane, font: ^Font, starting_pen: Vector2, cursor: Cursor,
) -> (out_of_screen: bool, pen: Vector2, rune_behind_cursor: rune) {
    lines := get_lines_array(pane)
    coords := cursor_offset_to_coords(pane, lines, cursor.pos)
    start, _ := get_line_boundaries(coords.row, lines)

    if !is_within_viewport(pane, coords) do return true, {}, ' '

    pen = starting_pen
    line_text := pane.buffer.text[start:cursor.pos]

    pen.x += prepare_text(font, line_text)
    if .Line_Wrappings not_in pane.flags {
        pen.x -= i32(pane.x_offset) * font.xadvance
    }
    pen.y += i32(coords.row - pane.y_offset) * font.character_height
    rune_behind_cursor = ' '

    if cursor.pos < len(pane.buffer.text) {
        rune_behind_cursor = utf8.rune_at(pane.buffer.text, cursor.pos)
    }

    return false, pen, rune_behind_cursor
}

is_within_viewport :: #force_inline proc(pane: ^Pane, coords: Coords) -> bool {
    last_column := get_pane_visible_columns(pane) + pane.x_offset
    last_row := get_pane_visible_rows(pane) + pane.y_offset
    return coords.column >= pane.x_offset && coords.column < last_column &&
        coords.row >= pane.y_offset && coords.row < last_row
}

cursor_offset_to_coords :: proc(pane: ^Pane, lines: []int, offset: int) -> (result: Coords) {
    result.row = get_line_index(offset, lines)
    start, end := get_line_boundaries(result.row, lines)
    buf := pane.buffer.text[start:end]
    index := 0

    for index < offset - start {
        result.column += 1
        index += 1
        for index < len(buf) && is_continuation_byte(buf[index]) do index += 1
    }

    return
}

cursor_coords_to_offset :: proc(pane: ^Pane, lines: []int, coords: Coords) -> (offset: int) {
    offset = lines[coords.row]
    column := coords.column
    buf := pane.buffer.text

    for column > 0 {
        column -= 1
        offset += 1
        for offset < len(buf) && is_continuation_byte(buf[offset]) do offset += 1
    }
    return
}

is_line_wrapped :: proc(pane: ^Pane, line_index: int) -> bool {
    if .Line_Wrappings not_in pane.flags do return false
    start, _ := get_line_boundaries(line_index, pane.wrapped_line_starts[:])
    return slice.contains(pane.buffer.line_starts[:], start)
}

get_visual_line_size :: proc(pane: ^Pane, test_buffer_line: int, loc := #caller_location) -> int {
    // if we're not wrapping, lines are always 1:1
    if .Line_Wrappings not_in pane.flags do return 1
    buffer_lines := pane.buffer.line_starts[:]
    wrapped_lines := pane.wrapped_line_starts[:]

    // first and last lines only?
    if len(buffer_lines) == 2 {
        return max(len(wrapped_lines) - 2, 1)
    } else {
        current_line_safe := min(test_buffer_line, len(buffer_lines) - 1)
        next_line_safe := min(test_buffer_line + 1, len(buffer_lines) - 1)
        buffer_line_start := buffer_lines[current_line_safe]
        buffer_next_line_start := buffer_lines[next_line_safe]
        line_index_wrapped := get_line_index(buffer_line_start, wrapped_lines)
        next_line_index_wrapped := get_line_index(buffer_next_line_start, wrapped_lines)
        return max(next_line_index_wrapped - line_index_wrapped, 1)
    }
}

get_line_indent_count :: proc(pane: ^Pane, line_index: int, lines: []int) -> (level: int) {
    start, end := get_line_boundaries(line_index, lines)
    count_spaces := 0
    count_tabs := 0

    for index in start..<end {
        b := pane.buffer.text[index]

        if b == ' ' {
            count_spaces += 1
        } else if b == '\t' {
            count_tabs += 1
        } else {
            break
        }
    }

    if count_spaces > 0 && count_tabs > 0 {
        log.warnf("line {} in buffer {} contains both spaces and tabs", line_index, pane.buffer.name)
    }

    if count_spaces > 0 {
        return count_spaces
    } else {
        return count_tabs
    }
}

get_line_index :: #force_inline proc(offset: int, lines: []int) -> (line_index: int) {
    if len(lines) < 2 do return 0

    top_index := 0
    bottom_index := len(lines) - 2
    line_index = 0

    if offset >= lines[bottom_index] {
        line_index = bottom_index
    } else {
        for bottom_index - top_index > 1 {
            middle_index := top_index + (bottom_index - top_index)/2

            if offset < lines[middle_index] {
                bottom_index = middle_index
            } else {
                top_index = middle_index
            }
        }

        line_index = top_index
    }

    return
}

get_line_text :: #force_inline proc(pane: ^Pane, line_index: int, lines: []int) -> (result: string) {
    start, end := get_line_boundaries(line_index, lines)
    return pane.buffer.text[start:end]
}

get_line_boundaries :: #force_inline proc(line_index: int, lines: []int) -> (start, end: int) {
    next_line_index := min(line_index + 1, len(lines) - 1)
    start = lines[line_index]
    end = lines[next_line_index] - 1
    return
}

get_lines_array :: #force_inline proc(pane: ^Pane) -> []int {
    if .Line_Wrappings in pane.flags {
        return pane.wrapped_line_starts[:]
    } else {
        return pane.buffer.line_starts[:]
    }
}

has_selection :: #force_inline proc(cursor: Cursor) -> bool {
    return cursor.pos != cursor.sel
}

sorted_cursor :: #force_inline proc(cursor: Cursor) -> (low, high: int) {
    low  = min(cursor.pos, cursor.sel)
    high = max(cursor.pos, cursor.sel)
    return
}

sort_cursors_by_offset :: proc(pane: ^Pane) {
    slice.stable_sort_by(pane.cursors[:], proc(i, j: Cursor) -> bool {
        return i.pos < j.pos
    })
}

is_pane_focused :: proc(pane: ^Pane) -> bool {
    return !global_widget.active && active_pane.uuid == pane.uuid
}

get_gutter_size :: proc(pane: ^Pane) -> (gutter_size: i32) {
    font := fonts_map[.UI_Small]
    gutter_size = font.em_width

    if settings.show_line_numbers {
        buffer_lines := pane.buffer.line_starts[:]
        test_str := fmt.tprintf("{}", len(buffer_lines))
        gutter_size = i32(len(test_str)) * font.em_width + MINIMUM_GUTTER_PADDING * font.em_width
    }

    return
}

get_pane_visible_columns :: proc(pane: ^Pane) -> (result: int) {
    profiling_start("get_pane_visible_columns")
    COLUMNS_RESERVED_FOR_PADDING :: 1
    pane_width := int(pane.rect.w)
    gutter_size := int(get_gutter_size(pane))
    font_width := int(pane.font.em_width)
    result = (pane_width - gutter_size) / font_width - COLUMNS_RESERVED_FOR_PADDING
    profiling_end()
    return
}

get_pane_visible_rows :: proc(pane: ^Pane) -> (result: int) {
    profiling_start("get_pane_visible_rows")
    pane_height := pane.rect.h
    font_height := f32(pane.font.line_height)
    modeline_height := f32(get_modeline_height())
    result = int((pane_height - modeline_height)/font_height)
    return result

}

get_modeline_height :: #force_inline proc() -> i32 {
    MODELINE_PADDING :: 8
    font := fonts_map[.UI_Regular]
    return font.line_height + MODELINE_PADDING
}

switch_to_buffer :: proc(pane: ^Pane, buffer: ^Buffer) {
    profiling_start("switching buffers in pane")
    assert(buffer != nil)
    clear(&pane.regions)
    if pane.buffer != nil do copy_cursors(pane, pane.buffer)

    if len(buffer.cursors) > 0 {
        delete(pane.cursors)
        pane.cursors = slice.clone_to_dynamic(buffer.cursors)
    } else {
        clear(&pane.cursors)
        add_cursor(pane)
    }

    pane.buffer = buffer
    if .Line_Wrappings in pane.flags do recalculate_line_wrappings(pane)
    pane.cursor_moved = true
    profiling_end()
}

maybe_scroll_pane_to_cursor_view :: proc(pane: ^Pane) {
    assert(.Dirty not_in pane.buffer.flags)
    lines := get_lines_array(pane)
    visible_rows := get_pane_visible_rows(pane)

    if len(lines) < visible_rows {
        pane.y_offset = 0
        return
    }

    sort_cursors_by_offset(pane)

    active_cursor := get_first_active_cursor(pane)
    coords := cursor_offset_to_coords(pane, lines, active_cursor.pos)
    has_scrolled := false
    visible_columns := get_pane_visible_columns(pane)

    if .Line_Wrappings not_in pane.flags {
        for coords.column < pane.x_offset {
            pane.x_offset -= 1
            has_scrolled = true
        }

        for coords.column >= visible_columns + pane.x_offset {
            pane.x_offset += 1
            has_scrolled = true
        }
    }

    for coords.row < pane.y_offset {
        pane.y_offset -= 1
        has_scrolled = true
    }

    for coords.row >= visible_rows + pane.y_offset {
        pane.y_offset += 1
        has_scrolled = true
    }

    if has_scrolled do flag_pane(pane, {.Need_Full_Repaint})
}

translate_position :: proc(pane: ^Pane, pos: int, t: Translation, max_column := -1) -> (result, last_column: int) {
    is_space :: proc(b: byte) -> bool {
        return b == ' ' || b == '\n' || b == '\t'
    }

    is_word_delim :: proc(b: byte) -> bool {
        return is_space(b) || b == '_' || b == '-' || b == '{' || b == '}' ||
            b == '(' || b == ')' || b == '.'
    }

    buf := pane.buffer.text
    result = clamp(pos, 0, len(buf))
    lines := get_lines_array(pane)
    visible_rows := get_pane_visible_rows(pane)

    switch t {
    case .start: result = 0
    case .end:   result = len(buf)

    case .down:
        coords := cursor_offset_to_coords(pane, lines, result)
        coords.row = min(coords.row + 1, len(lines))
        start, end := get_line_boundaries(coords.row, lines)
        column_length := end - start
        if coords.column == 0 do coords.column = max(0, max_column)
        coords.column = min(coords.column, column_length)
        result = cursor_coords_to_offset(pane, lines, coords)
    case .left:
        result -= 1
        for result >= 0 && is_continuation_byte(buf[result]) do result -= 1
    case .right:
        result += 1
        for result < len(buf) && is_continuation_byte(buf[result]) do result += 1
    case .up:
        coords := cursor_offset_to_coords(pane, lines, result)

        if coords.row > 0 {
            coords.row -= 1
            start, end := get_line_boundaries(coords.row, lines)
            column_length := end - start
            if coords.column == 0 do coords.column = max(0, max_column)
            coords.column = min(coords.column, column_length)
            result = cursor_coords_to_offset(pane, lines, coords)
        } else {
            result = 0
            last_column = -1
            return
        }
    case .prev_word:
        for result > 0 && is_word_delim(buf[result-1])  do result -= 1
        for result > 0 && !is_word_delim(buf[result-1]) do result -= 1
    case .next_word:
        for result < len(buf) && !is_word_delim(buf[result]) do result += 1
        for result < len(buf) && is_word_delim(buf[result])  do result += 1
    case .prev_paragraph:
        coords := cursor_offset_to_coords(pane, lines, result)
        coords.row = max(coords.row - 1, 0)
        start, end := get_line_boundaries(coords.row, lines)
        for coords.row > 0 && end - start > 1 {
            coords.row -= 1
            start, end = get_line_boundaries(coords.row, lines)
        }

        coords.column = 0
        last_column = -1
        result = cursor_coords_to_offset(pane, lines, coords)
    case .next_paragraph:
        coords := cursor_offset_to_coords(pane, lines, result)
        coords.row = min(coords.row + 1, len(lines))
        start, end := get_line_boundaries(coords.row, lines)

        for coords.row < len(lines) && end - start > 1 {
            coords.row += 1
            start, end = get_line_boundaries(coords.row, lines)
        }

        coords.column = 0
        last_column = -1
        result = cursor_coords_to_offset(pane, lines, coords)
    case .prev_page:
        coords := cursor_offset_to_coords(pane, lines, result)
        coords.row = max(coords.row - visible_rows, 0)
        result = cursor_coords_to_offset(pane, lines, coords)
    case .next_page:
        coords := cursor_offset_to_coords(pane, lines, result)
        coords.row = min(coords.row + visible_rows, len(lines) - 1)
        result = cursor_coords_to_offset(pane, lines, coords)
    case .beginning_of_line:
        coords := cursor_offset_to_coords(pane, lines, result)
        last_column = -1

        if coords.column == 0 {
            // go to soft beginning of line (a.k.a. tab stop)
            for result < len(buf) && buf[result] != '\n' && is_space(buf[result]) {
                result += 1
            }
        } else {
            coords.column = 0
            result = cursor_coords_to_offset(pane, lines, coords)
        }
    case .end_of_line:
        coords := cursor_offset_to_coords(pane, lines, result)
        _, end := get_line_boundaries(coords.row, lines)
        last_column = -1
        result = end
    }

    result = clamp(result, 0, len(buf))
    if max_column != - 1 {
        result_coords := cursor_offset_to_coords(pane, lines, result)
        last_column = max(max_column, result_coords.column)
    }

    return
}
