package main

import "core:encoding/uuid"
import "core:fmt"
import "core:log"
import "core:slice"
import "core:strings"
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
    down, left, right, up,
    prev_word, next_word,
    prev_paragraph, next_paragraph,
    prev_page, next_page,
    beginning_of_buffer, end_of_buffer,
    beginning_of_line, end_of_line,
    beginning_of_word, end_of_word,
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

update_pane_font :: #force_inline proc(pane: ^Pane) {
    scaled_character_height := font_to_scaled_pixels(pane.local_font_size)
    pane.font = get_font_with_size(FONT_EDITOR_NAME, FONT_EDITOR_DATA, scaled_character_height)
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

cursor_clone :: proc(pane: ^Pane, cursor_to_clone: Cursor) -> ^Cursor {
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
    font_height := f32(pane.font.character_height)
    modeline_height := f32(get_modeline_height())
    result = int((pane_height - modeline_height)/font_height)
    return result

}

get_modeline_height :: #force_inline proc() -> i32 {
    MODELINE_PADDING :: 8
    font := fonts_map[.UI_Regular]
    return font.character_height + MODELINE_PADDING
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

pane_handle_mouse_events :: proc() {
    set_pane_at_mouse_pos_as_active :: proc() {
        mx, my := mouse_state.position.x, mouse_state.position.y
        result: ^Pane

        for pane in open_panes {
            left := i32(pane.rect.x)
            right := left + i32(pane.rect.w)
            up := i32(pane.rect.y)
            down := up + i32(pane.rect.h)

            if mx >= left && mx <= right && my >= up && my <= down {
                result = pane
                break
            }
        }

        if result == nil {
            flag_pane(active_pane, {.Need_Full_Repaint})
        } else {
            flag_pane(active_pane, {.Need_Full_Repaint})
            active_pane = result
            flag_pane(active_pane, {.Need_Full_Repaint})
        }
    }

    if mouse_state.scroll_x != 0 || mouse_state.scroll_y != 0 {
        set_pane_at_mouse_pos_as_active()
        pane := active_pane
        lines := get_lines_array(pane)
        visible_rows := get_pane_visible_rows(pane)
        scroll_x := int(mouse_state.scroll_x) * settings.mouse_scroll_threshold
        scroll_y := int(mouse_state.scroll_y) * settings.mouse_scroll_threshold

        if .Line_Wrappings in pane.flags {
            new_offset := pane.x_offset + scroll_x
            pane.x_offset = max(new_offset, 0)
        }

        if len(lines) > visible_rows {
            new_y_offset := pane.y_offset + scroll_y
            pane.y_offset = clamp(new_y_offset, 0, len(lines) - visible_rows/2)
        }
    }

    if mouse_state.left_button.is_dragging {
        // we don't change panes while dragging
        pane := active_pane
        cursor := get_first_active_cursor(pane)
        current := mouse_state.position
        curr_mpos := Vector2{current.x - i32(pane.rect.x), current.y - i32(pane.rect.y)}
        pos_offset := mouse_pos_to_offset(pane, curr_mpos)
        cursor.pos = pos_offset
    } else if mouse_state.left_button.just_clicked {
        set_pane_at_mouse_pos_as_active()
        pane := active_pane

        if len(pane.buffer.text) == 0 do return

        lines := get_lines_array(pane)
        mx, my := mouse_state.position.x, mouse_state.position.y
        relative_mouse_pos := Vector2{ mx - i32(pane.rect.x), my - i32(pane.rect.y) }
        offset := mouse_pos_to_offset(pane, relative_mouse_pos)
        clear(&pane.cursors)
        add_cursor(pane, offset)
        pane.cursor_moved = true

        if mouse_state.left_button.just_double_clicked {
            cursor := get_first_active_cursor(pane)
            pos, _ := translate_position(pane, cursor.pos, .next_word)
            sel, _ := translate_position(pane, cursor.pos, .prev_word)
            cursor.pos = pos
            cursor.sel = sel
        } else if mouse_state.left_button.just_triple_clicked {
            cursor := get_first_active_cursor(pane)
            line_index := get_line_index(cursor.pos, lines)
            start, end := get_line_boundaries(line_index, lines)
            cursor.pos = end + 1
            cursor.sel = start
        }
    }
}

mouse_pos_to_offset :: proc(pane: ^Pane, relative_mouse_pos: Vector2) -> int {
    lines := get_lines_array(pane)
    gutter_size := get_gutter_size(pane)
    coords: Coords
    Y := relative_mouse_pos.y/pane.font.character_height + i32(pane.y_offset)
    X := max((relative_mouse_pos.x - gutter_size)/pane.font.xadvance, 0) + i32(pane.x_offset)

    if settings.modeline_position == .top {
        Y = max(Y - 1, 0)
    }

    if len(lines) == 2 {
        coords.row = 0
        coords.column = min(int(X), len(pane.buffer.text)-1)
    } else {
        coords.row = clamp(int(Y), 0, len(lines)-1)
        start, end := get_line_boundaries(coords.row, lines)
        coords.column = clamp(int(X), 0, end - start)
    }

    return clamp(cursor_coords_to_offset(pane, lines, coords), 0, len(pane.buffer.text)-1)
}

pane_keyboard_event_handler :: proc(event: Event_Keyboard, cmd: Command) -> bool {
    pane := active_pane
    buffer := pane.buffer

    copy_cursors(pane, buffer)

    if event.is_text_input {
        pane_insert_at_points(pane, event.text)
        return true
    }

    switch cmd {
    case .noop: return false // nothing
    case .modifier:  // handled globally
    case .quit_mode: // handled globally

    case .find_buffer:
        widget_open_find_buffer()
        return true
    case .find_command:
        return false
    case .find_file:
        widget_open_find_file()
        return true
    case .search_backward: fallthrough
    case .search_forward:
        widget_open_search_in_buffer()
        return true

    case .close_this_pane:
        if len(open_panes) == 1 do return true
        pane_index_to_close := -1
        for other, index in open_panes {
            if active_pane.uuid == other.uuid {
                pane_index_to_close = index
                break
            }
        }
        new_pane_index := pane_index_to_close < len(open_panes) - 1 ? pane_index_to_close + 1 : 0
        old_pane := active_pane
        active_pane = open_panes[new_pane_index]
        ordered_remove(&open_panes, pane_index_to_close)
        pane_destroy(old_pane)
        update_all_pane_textures()
        return true
    case .close_other_panes:
        if len(open_panes) == 1 do return true
        ids_to_remove := make([dynamic]uuid.Identifier, 0, len(open_panes), context.temp_allocator)
        for other in open_panes {
            if active_pane.uuid != other.uuid do append(&ids_to_remove, other.uuid)
        }
        for len(ids_to_remove) > 0 {
            pane_id := pop(&ids_to_remove)

            for other, index in open_panes {
                if other.uuid == pane_id {
                    unordered_remove(&open_panes, index)
                    pane_destroy(other)
                    break
                }
            }
        }
        update_all_pane_textures()
        flag_buffer(pane.buffer, {.Dirty})
        return true
    case .new_pane_to_the_right:
        result := pane_create(pane)
        active_pane = result
        return true
    case .other_pane:
        if len(open_panes) == 1 do return true
        other_pane_index := -1
        for other, index in open_panes {
            if active_pane.uuid == other.uuid {
                other_pane_index = index
                break
            }
        }
        other_pane_index = other_pane_index < len(open_panes) - 1 ? other_pane_index + 1 : 0
        old_pane := active_pane
        active_pane = open_panes[other_pane_index]
        // repaiting the old pane and the new pane
        flag_pane(old_pane, {.Need_Full_Repaint})
        flag_pane(active_pane, {.Need_Full_Repaint})
        return true
    case .close_current_buffer:
        index := buffer_index(buffer)
        ordered_remove(&open_buffers, index)
        buffer_destroy(buffer)
        active_pane.buffer = nil
        if len(open_buffers) == 0 {
            switch_to_buffer(active_pane, buffer_get_or_create_empty())
        } else {
            index = clamp(index, 0, len(open_buffers) - 1)
            switch_to_buffer(active_pane, open_buffers[index])
        }
        return true
    case .save_buffer:
        if buffer.filepath == "" {
            widget_open_save_file_as()
        } else {
            buffer_save(buffer)
        }
        return true
    case .save_buffer_as:
        widget_open_save_file_as()
        return true


    case .increase_font_size:
        new_font_size := pane.local_font_size * 1.25
        if new_font_size < MAXIMUM_FONT_SIZE {
            pane.local_font_size = new_font_size
            update_all_pane_textures()
        }
        return true
    case .decrease_font_size:
        new_font_size := pane.local_font_size * 0.8
        if new_font_size > MINIMUM_FONT_SIZE {
            pane.local_font_size = new_font_size
            update_all_pane_textures()
        }
        return true
    case .reset_font_size:
        default_font_size := f32(settings.editor_font_size)

        if pane.local_font_size != default_font_size {
            pane.local_font_size = default_font_size
            update_all_pane_textures()
        }
        return true

    case .toggle_selection_mode:
        pane_toggle_selection(pane)
        return true
    case .toggle_line_wrappings:
        pane_toggle_line_wrappings(pane)
        return true

    case .newline_and_indent:
        pane_insert_newlines_and_indent(pane)
        return true
    case .indent_or_tab_stop:
        pane_maybe_indent_or_go_to_tab_stop(pane)
        return true

    case .prev_cursor:
        pane_switch_cursor(pane, .prev)
        return true
    case .next_cursor:
        pane_switch_cursor(pane, .next)
        return true
    case .all_cursors:
        pane_switch_cursor(pane, .all)
        return true
    case .clone_cursor_above:
        pane_clone_cursor_to(pane, .up)
        return true
    case .clone_cursor_below:
        pane_clone_cursor_to(pane, .down)
        return true
    case .recenter_cursor:
        pane_maybe_recenter_cursor(pane, true)
        return true

    case .move_beginning_of_buffer:
        pane_cursor_move_to(pane, .beginning_of_buffer)
        return true
    case .move_beginning_of_line:
        pane_cursor_move_to(pane, .beginning_of_line)
        return true
    case .move_end_of_buffer:
        pane_cursor_move_to(pane, .end_of_buffer)
        return true
    case .move_end_of_line:
        pane_cursor_move_to(pane, .end_of_line)
        return true
    case .move_left:
        pane_cursor_move_to(pane, .left)
        return true
    case .move_right:
        pane_cursor_move_to(pane, .right)
        return true
    case .move_down:
        pane_cursor_move_to(pane, .down)
        return true
    case .move_up:
        pane_cursor_move_to(pane, .up)
        return true
    case .move_prev_word:
        pane_cursor_move_to(pane, .prev_word)
        return true
    case .move_next_word:
        pane_cursor_move_to(pane, .next_word)
        return true
    case .move_prev_paragraph:
        pane_cursor_move_to(pane, .prev_paragraph)
        return true
    case .move_next_paragraph:
        pane_cursor_move_to(pane, .next_paragraph)
        return true
    case .move_prev_page:
        pane_cursor_move_to(pane, .prev_page)
        pane_maybe_recenter_cursor(pane)
        return true
    case .move_next_page:
        pane_cursor_move_to(pane, .next_page)
        pane_maybe_recenter_cursor(pane)
        return true

    case .remove_left:
        pane_remove_at_points(pane, .left)
        return true
    case .remove_right:
        pane_remove_at_points(pane, .right)
        return true
    case .remove_prev_word:
        pane_remove_at_points(pane, .prev_word)
        return true
    case .remove_next_word:
        pane_remove_at_points(pane, .next_word)
        return true

    case .select_all:
        clear(&pane.cursors)
        add_cursor(pane, len(buffer.text))
        pane.cursors[0].pos = 0
        pane.cursor_moved = true
        return true
    case .select_beginning_of_buffer:
        pane_cursor_select_to(pane, .beginning_of_buffer)
        return true
    case .select_beginning_of_line:
        pane_cursor_select_to(pane, .beginning_of_line)
        return true
    case .select_end_of_buffer:
        pane_cursor_select_to(pane, .end_of_buffer)
        return true
    case .select_end_of_line:
        pane_cursor_select_to(pane, .end_of_line)
        return true
    case .select_left:
        pane_cursor_select_to(pane, .left)
        return true
    case .select_right:
        pane_cursor_select_to(pane, .right)
        return true
    case .select_down:
        pane_cursor_select_to(pane, .down)
        return true
    case .select_up:
        pane_cursor_select_to(pane, .up)
        return true
    case .select_prev_word:
        pane_cursor_select_to(pane, .prev_word)
        return true
    case .select_next_word:
        pane_cursor_select_to(pane, .next_word)
        return true
    case .select_prev_paragraph:
        pane_cursor_select_to(pane, .prev_paragraph)
        return true
    case .select_next_paragraph:
        pane_cursor_select_to(pane, .next_paragraph)
        return true
    case .select_prev_page:
        pane_cursor_select_to(pane, .prev_page)
        return true
    case .select_next_page:
        pane_cursor_select_to(pane, .next_page)
        return true

    case .undo:
        undo_done, cursors, pieces := undo(buffer, &buffer.undo, &buffer.redo)

        if !undo_done {
            log.debug("no more history to undo")
            return true
        }
        profiling_start("doing undo")
        for piece in buffer.pieces do delete(piece.line_starts)
        delete(pane.cursors)
        delete(buffer.pieces)
        pane.cursors = slice.clone_to_dynamic(cursors)
        buffer.pieces = slice.clone_to_dynamic(pieces)
        make_sure_pieces_have_lines(buffer)
        pane_toggle_selection(pane, true)
        profiling_end()
        return true
    case .redo:
        redo_done, cursors, pieces := undo(buffer, &buffer.redo, &buffer.undo)

        if !redo_done {
            log.debug("no more history to redo")
            return true
        }

        profiling_start("doing redo")
        for piece in buffer.pieces do delete(piece.line_starts)
        delete(pane.cursors)
        delete(buffer.pieces)
        pane.cursors = slice.clone_to_dynamic(cursors)
        buffer.pieces = slice.clone_to_dynamic(pieces)
        make_sure_pieces_have_lines(buffer)
        pane_toggle_selection(pane, true)
        profiling_end()
        return true

    case .cut_selection:
        pane_copy_selected_text(pane, true)
        pane_remove_selections(pane)
        return true
    case .cut_line:
        pane_cursor_select_to(pane, .end_of_line)

        // if there's no selection, we add plus one to kill the line.
        for &cursor in pane.cursors {
            if !cursor.active do continue
            if cursor.pos == cursor.sel {
                cursor.pos = min(cursor.pos + 1, len(pane.buffer.text))
            }
        }

        pane_copy_selected_text(pane, true)
        pane_remove_selections(pane)
        return true
    case .copy_selection:
        pane_copy_selected_text(pane)
        pane.cursor_selecting = false
        return true
    case .copy_line:
        pane_cursor_select_to(pane, .end_of_line)
        pane_copy_selected_text(pane)
        return true
    case .paste:
        text := platform_get_clipboard_text()
        if len(text) > 0 do pane_insert_at_points(pane, text)
        return true
    case .paste_from_history:
    }

    return false
}

pane_copy_selected_text :: proc(pane: ^Pane, keep_selection := false) {
    text_to_copy := strings.builder_make(context.temp_allocator)
    sort_cursors_by_offset(pane)
    for &cursor in pane.cursors {
        if !cursor.active do continue
        if !has_selection(cursor) do continue
        low, high := sorted_cursor(cursor)
        strings.write_string(&text_to_copy, pane.buffer.text[low:high])
        if !keep_selection do cursor.sel = cursor.pos
    }
    platform_set_clipboard_text(strings.to_string(text_to_copy))
}

pane_toggle_selection :: proc(pane: ^Pane, force_reset := false) {
    if pane.cursor_selecting || force_reset {
        pane.cursor_selecting = false
        for &cursor in pane.cursors {
            cursor.sel = cursor.pos
        }
    } else {
        pane.cursor_selecting = true
        for &cursor in pane.cursors {
            cursor.active = true
        }
    }
}

pane_toggle_line_wrappings :: proc(pane: ^Pane) {
    if .Line_Wrappings in pane.flags {
        unflag_pane(pane, {.Line_Wrappings})
    } else {
        flag_pane(pane, {.Line_Wrappings})
    }

    pane.cursor_moved = true
}

pane_clone_cursor_to :: proc(pane: ^Pane, t: Translation) {
    if len(pane.cursors) == 1 {
        cloned_cursor := cursor_clone(pane, pane.cursors[0])
        pane_cursor_move_to(pane, t, cloned_cursor)
    } else if !are_all_cursors_active(pane) {
        cursor_to_clone := get_first_active_cursor(pane)
        cloned_cursor := cursor_clone(pane, cursor_to_clone^)
        pane_cursor_move_to(pane, t, cloned_cursor)
        cursor_to_clone.active = false
        cloned_cursor.active = true
    } else {
        pane_toggle_selection(pane, true)
        sort_cursors_by_offset(pane)

        cloned_cursor: ^Cursor

        if t == .up {
            cloned_cursor = cursor_clone(pane, pane.cursors[0])
        } else if t == .down {
            cloned_cursor = cursor_clone(pane, pane.cursors[len(pane.cursors)-1])
        }

        pane_cursor_move_to(pane, t, cloned_cursor)
    }

    sort_cursors_by_offset(pane)
    pane.cursor_moved = true
}

pane_maybe_recenter_cursor :: proc(pane: ^Pane, force_recenter := false) {
    cursor := get_first_active_cursor(pane)
    lines := get_lines_array(pane)
    coords := cursor_offset_to_coords(pane, lines, cursor.pos)
    visible_rows := get_pane_visible_rows(pane)
    top_edge := pane.y_offset
    bottom_edge := pane.y_offset + visible_rows
    right_edge := get_pane_visible_columns(pane)

    if force_recenter || coords.row < top_edge || coords.row > bottom_edge {
        if len(lines) < visible_rows {
            pane.y_offset = 0
        } else {
            pane.y_offset = max(coords.row - visible_rows/2, 0)
        }

        if coords.column < right_edge {
            pane.x_offset = 0
        } else {
            pane.x_offset = coords.column/2
        }
    }
}

pane_switch_cursor :: proc(pane: ^Pane, op: enum {all, prev, next}) {
    if len(pane.cursors) == 1 do return

    sort_cursors_by_offset(pane)

    if op == .all {
        for &cursor in pane.cursors do cursor.active = true
        pane.cursor_moved = true
        return
    }

    if are_all_cursors_active(pane) {
        for &cursor in pane.cursors do cursor.active = false

        if op == .prev {
            pane.cursors[len(pane.cursors)-1].active = true
        } else {
            pane.cursors[0].active = true
        }

        pane.cursor_moved = true
        return
    }

    current_index := -1
    for &cursor, index in pane.cursors {
        if cursor.active {
            cursor.active = false
            current_index = index
            break
        }
    }

    current_index += op == .next ? 1 : -1

    if current_index < 0 {
        current_index = len(pane.cursors)-1
    } else if current_index >= len(pane.cursors) {
        current_index = 0
    }

    pane.cursors[current_index].active = true
    pane.cursor_moved = true
}

pane_cursor_move_to :: proc(pane: ^Pane, t: Translation, cursor_to_move: ^Cursor = nil) {
    move :: #force_inline proc(pane: ^Pane, cursor: ^Cursor, t: Translation) {
        if t == .left && has_selection(cursor^) {
            low, _ := sorted_cursor(cursor^)
            cursor.pos = low
            cursor.sel = low
        } else if t == .right && has_selection(cursor^) {
            _, high := sorted_cursor(cursor^)
            cursor.pos = high
            cursor.sel = high
        } else {
            coords := cursor_offset_to_coords(pane, get_lines_array(pane), cursor.pos)
            last_column := -1 if t != .up && t != .down else max(cursor.last_column, coords.column)
            result, result_column := translate_position(pane, cursor.pos, t, last_column)
            cursor.pos = result
            cursor.sel = result
            cursor.last_column = result_column
        }
    }

    if cursor_to_move != nil {
        move(pane, cursor_to_move, t)
    } else {
        if pane.cursor_selecting {
            pane_cursor_select_to(pane, t)
        } else {
            for &cursor in pane.cursors {
                if !cursor.active do continue
                move(pane, &cursor, t)
            }
        }
    }

    _maybe_merge_overlapping_cursors(pane)
    pane.cursor_moved = true
}

pane_cursor_select_to :: proc(pane: ^Pane, t: Translation, cursor_to_select: ^Cursor = nil) {
    if cursor_to_select != nil {
        cursor_to_select.pos, _ = translate_position(pane, cursor_to_select.pos, t)
    } else {
        for &cursor in pane.cursors {
            if !cursor.active do continue
            cursor.pos, _ = translate_position(pane, cursor.pos, t)
        }
    }

    _maybe_merge_overlapping_cursors(pane)
    pane.cursor_moved = true
}

pane_insert_at_points :: proc(pane: ^Pane, text: string) {
    if buffer_is_readonly(pane.buffer) {
        show_buffer_readonly_message(pane.buffer)
        return
    }

    profiling_start("inserting text")
    sort_cursors_by_offset(pane)

    // check if the inserted text may need indentation
    indent_tokens := get_indentation_tokens(pane.buffer, text)
    maybe_should_reindent := len(indent_tokens) > 0 && indent_tokens[0].action == .Close
    temp_lines_to_indent := make([dynamic]int, context.temp_allocator)

    pane_remove_selections(pane)

    if maybe_should_reindent {
        buffer_lines := pane.buffer.line_starts[:]

        for cursor in pane.cursors {
            append(&temp_lines_to_indent, get_line_index(cursor.pos, buffer_lines))
        }
    }

    for cursor, current_index in pane.cursors {
        if !cursor.active do continue

        offset := insert_at(pane.buffer, cursor.pos, text)

        for &other, other_index in pane.cursors {
            if current_index > other_index do continue
            other.pos += offset
            other.sel = other.pos
        }
    }

    if len(temp_lines_to_indent) > 0 {
        unique_lines_to_indent := slice.unique(temp_lines_to_indent[:])
        slice.stable_sort(unique_lines_to_indent)
        _indent_multi_line(
            pane.buffer, unique_lines_to_indent,
            _on_indent_realign_active_pane_cursors,
        )
    }

    pane.cursor_moved = true
    profiling_end()
}

pane_insert_newlines_and_indent :: proc(pane: ^Pane) {
    if buffer_is_readonly(pane.buffer) {
        show_buffer_readonly_message(pane.buffer)
        return
    }

    profiling_start("insert newlines and indent")
    sort_cursors_by_offset(pane)
    pane_remove_selections(pane)

    // remove selection may have taken part of our lines, so we need
    // to make sure we remap then before we ask for reindent
    temp_lines_to_indent := make([dynamic]int, context.temp_allocator)
    temp_lines_array := make([dynamic]int, context.temp_allocator)

    if should_do_electric_indent(pane.buffer) {
        collect_pieces_from_buffer(pane.buffer, nil, &temp_lines_array)

        for cursor, index in pane.cursors {
            if !cursor.active do continue
            // because each cursor will add offset, and we sorted the
            // cursors by their position, it is safe to add the index
            current_line := get_line_index(cursor.pos, temp_lines_array[:]) + index
            // and we indent current and next line
            append(&temp_lines_to_indent, current_line, current_line + 1)
        }
    }

    for cursor, current_index in pane.cursors {
        if !cursor.active do continue
        offset := insert_at(pane.buffer, cursor.pos, "\n")

        for &other, other_index in pane.cursors {
            // cursors are sorted, we can just do this
            if current_index > other_index do continue
            other.pos += offset
            other.sel = other.pos
        }
    }

    if len(temp_lines_to_indent) > 0 {
        unique_lines_to_indent := slice.unique(temp_lines_to_indent[:])
        slice.stable_sort(unique_lines_to_indent)
        _indent_multi_line(
            pane.buffer, unique_lines_to_indent,
            _on_indent_realign_active_pane_cursors,
        )
    }

    pane.cursor_moved = true
    profiling_end()
}

pane_maybe_indent_or_go_to_tab_stop :: proc(pane: ^Pane) {
    // only call this in current pane
    assert(pane.uuid == active_pane.uuid)

    // if the buffer is not expecting indentation, just treat it as
    // moving to the beginning of line.
    if !should_do_electric_indent(pane.buffer) {
        pane_cursor_move_to(pane, .beginning_of_line)
        return
    }

    temp_lines_to_indent := make([dynamic]int, context.temp_allocator)
    buffer_lines := pane.buffer.line_starts[:]

    for &cursor in pane.cursors {
        if !cursor.active do continue

        low, high := sorted_cursor(cursor)
        low_coords  := cursor_offset_to_coords(pane, buffer_lines, low)
        high_coords := cursor_offset_to_coords(pane, buffer_lines, high)

        for line_index in low_coords.row..<high_coords.row + 1 {
            append(&temp_lines_to_indent, line_index)
        }

        coords: Coords

        if cursor.pos == low {
            coords = low_coords
        } else {
            coords = high_coords
        }

        new_pos, _ := get_line_boundaries(coords.row, buffer_lines)
        for new_pos < len(pane.buffer.text) {
            b := pane.buffer.text[new_pos]
            if b != ' ' && b != '\t' do break
            new_pos += 1
        }

        cursor.pos = max(cursor.pos, new_pos)
        cursor.sel = cursor.pos
    }


    unique_lines_to_indent := slice.unique(temp_lines_to_indent[:])

    if len(unique_lines_to_indent) == 1 {
        line_index := unique_lines_to_indent[0]
        _indent_single_line(
            pane.buffer, pane.buffer.text,
            line_index, buffer_lines,
            _on_indent_realign_active_pane_cursors,
        )
    } else {
        slice.stable_sort(unique_lines_to_indent)
        _indent_multi_line(
            pane.buffer, unique_lines_to_indent,
            _on_indent_realign_active_pane_cursors,
        )
    }

    pane.cursor_selecting = false
    pane.cursor_moved = true
}

pane_remove_at_points :: proc(pane: ^Pane, t: Translation) {
    profiling_start("removing text")
    buffer_lines := pane.buffer.line_starts[:]

    for &cursor in pane.cursors {
        if !cursor.active do continue

        line_index := get_line_index(cursor.pos, buffer_lines)
        _, end := get_line_boundaries(line_index, buffer_lines)

        if t == .end_of_line && cursor.pos == end {
            cursor.pos, _ = translate_position(pane, cursor.pos, .right)
        } else {
            if !has_selection(cursor) {
                cursor.pos, _ = translate_position(pane, cursor.pos, t)
            }
        }
    }

    pane_remove_selections(pane)
    pane.cursor_moved = true
    profiling_end()
}

pane_remove_selections :: proc(pane: ^Pane, array: ^[dynamic]Cursor = nil) {
    cursors_array := array == nil ? &pane.cursors : array

    for &cursor, current_index in cursors_array {
        if !cursor.active do continue

        if has_selection(cursor) {
            low, high := sorted_cursor(cursor)
            offset := high - low

            if low != high {
                remove_at(pane.buffer, low, offset)
                cursor.pos = low
                cursor.sel = low
            }

            for &other, other_index in cursors_array {
                if current_index == other_index do continue

                if other.pos > cursor.pos {
                    other.pos -= offset
                    other.sel -= offset
                }
            }
        }
    }

    _maybe_merge_overlapping_cursors(pane)
    pane.cursor_selecting = false
    pane.cursor_moved = true
}


translate_position :: proc(pane: ^Pane, pos: int, t: Translation, max_column := -1) -> (result, last_column: int) {
    is_space :: proc(b: byte) -> bool {
        return b == ' ' || b == '\n' || b == '\t'
    }

    is_alphanumeric :: proc(b: byte) -> bool {
        return b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9'
    }

    // TODO(nawe) this really needs to improve...
    is_word_delim :: proc(b: byte) -> bool {
        return is_space(b) || b == '_' || b == '-' || b == '{' || b == '}' || b == '(' ||
            b == ')' || b == '.' || b == '[' || b == ']' || b == ',' || b == '/' ||
            b == '\\' || b == '"'
    }

    buf := pane.buffer.text
    result = clamp(pos, 0, len(buf))
    lines := get_lines_array(pane)
    visible_rows := get_pane_visible_rows(pane)

    switch t {
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
        for result < len(buf) && is_word_delim(buf[result])  do result += 1
        for result < len(buf) && !is_word_delim(buf[result]) do result += 1
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

    case .beginning_of_buffer: result = 0
    case .end_of_buffer:       result = len(buf)
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
    case .beginning_of_word:
        for result > 0 && !is_space(buf[result-1]) do result -= 1
    case .end_of_word:
        for result < len(buf) && !is_space(buf[result]) do result += 1
    }

    result = clamp(result, 0, len(buf))
    if max_column != - 1 {
        result_coords := cursor_offset_to_coords(pane, lines, result)
        last_column = max(max_column, result_coords.column)
    }

    return
}

@(private="file")
Indent_Callback_Proc :: #type proc(prev_offset, new_offset, amount: int)

@(private="file")
_on_indent_realign_active_pane_cursors :: proc(prev_offset, new_offset, amount: int) {
    pane := active_pane

    for &cursor in pane.cursors {
        if cursor.pos >= prev_offset {
            cursor.pos += amount
            cursor.sel = cursor.pos
        }
    }
}

@(private="file")
_indent_multi_line :: proc(buffer: ^Buffer, lines_to_indent: []int, after_single_line_indent_callback: Indent_Callback_Proc) {
    profiling_start("indenting region or multiple lines")
    for line_index in lines_to_indent {
        // somewhat slow here, but we need to reconstruct some lines
        // in order to figure out how much we need to
        // indent. Hopefully we don't have to go to the end of the file.
        temp_line_starts := make([dynamic]int, context.temp_allocator)
        contents := strings.builder_make(context.temp_allocator)
        collect_pieces_from_buffer(buffer, &contents, &temp_line_starts)

        _indent_single_line(
            buffer, strings.to_string(contents),
            line_index, temp_line_starts[:],
            after_single_line_indent_callback,
        )
    }
    profiling_end()
}

@(private="file")
_indent_single_line :: proc(buffer: ^Buffer, text: string, line_index: int, lines: []int, after_indent_callback: Indent_Callback_Proc) {
    profiling_start("indenting single line")
    count_indent_chars :: proc(text: string) -> (result: int) {
        if len(text) == 0 do return 0
        for r in text {
            if r == ' ' || r == '\t' {
                result += 1
            } else {
                break
            }
        }
        return result
    }

    line_has_code :: proc(text: string) -> bool {
        for r in text {
            if r != '\t' && r != ' ' do return true
        }
        return false
    }

    // we indent by looking to the previous line, so don't even try to
    // indent the first line.
    if line_index == 0 do return
    indent_chars_wanted := 0

    test_line_index := line_index - 1
    for test_line_index > 0 {
        start, end := get_line_boundaries(test_line_index, lines)
        if start == end {
            test_line_index -= 1
            continue
        }

        indent_chars_wanted = count_indent_chars(text[start:end])
        break
    }

    curr_line_start, curr_line_end := get_line_boundaries(line_index, lines)
    indent_chars_in_curr_line := count_indent_chars(text[curr_line_start:curr_line_end])

    prev_line_start, prev_line_end := get_line_boundaries(line_index - 1, lines)
    prev_line_tokens := get_indentation_tokens(buffer, text[prev_line_start:prev_line_end])
    curr_line_tokens := get_indentation_tokens(buffer, text[curr_line_start:curr_line_end])
    delta := _calculate_indent_delta(prev_line_tokens)

    // the start of the previous line was a closing token
    if len(prev_line_tokens) > 0 && prev_line_tokens[0].action == .Close {
        delta += 1
    }

    // the start of this line is a closing token
    if len(curr_line_tokens) > 0 && curr_line_tokens[0].action == .Close {
        delta -= 1
    }

    indent_chars_wanted = _calculate_new_indent(buffer, indent_chars_wanted, delta)

    if indent_chars_wanted != indent_chars_in_curr_line {
        offset := indent_chars_wanted - indent_chars_in_curr_line

        if offset > 0 {
            builder := strings.builder_make(context.temp_allocator)
            for _ in 0..<offset {
                switch buffer.indent.tab_char {
                case .space: strings.write_string(&builder, " ")
                case .tab:   strings.write_string(&builder, "\t")
                }
            }

            insert_at(buffer, curr_line_start, strings.to_string(builder))
        } else {
            remove_at(buffer, curr_line_start, abs(offset))
        }

        if after_indent_callback != nil {
            after_indent_callback(curr_line_start, curr_line_start + offset, offset)
        }
    }
    profiling_end()
}

@(private="file")
_maybe_merge_overlapping_cursors :: proc(pane: ^Pane) {
    if len(pane.cursors) < 2 do return
    sort_cursors_by_offset(pane)

    for i in 0..<len(pane.cursors) {
        for j in 1..<len(pane.cursors) {
            if i == j do continue
            icursor := pane.cursors[i]
            jcursor := pane.cursors[j]

            if !has_selection(icursor) && !has_selection(jcursor) {
                ipos := icursor.pos
                jpos := jcursor.pos

                if ipos == jpos {
                    log.debugf("merging cursors {} and {}", i + 1, j + 1)
                    pane.cursors[i].active = true
                    ordered_remove(&pane.cursors, j)
                    flag_pane(pane, {.Need_Full_Repaint})
                }
            } else {
                _, ihi := sorted_cursor(icursor)
                jlo, jhi := sorted_cursor(jcursor)

                if ihi >= jlo && ihi < jhi {
                    if icursor.pos > icursor.sel {
                        // going to the right
                        pane.cursors[i].pos = max(icursor.pos, jcursor.pos)
                        pane.cursors[i].sel = min(icursor.sel, jcursor.sel)
                    } else {
                        // going to the left
                        pane.cursors[i].pos = min(icursor.pos, jcursor.pos)
                        pane.cursors[i].sel = max(icursor.sel, jcursor.sel)
                    }

                    log.debugf("merging cursors {} and {}", i + 1, j + 1)
                    pane.cursors[i].last_column = -1
                    pane.cursors[i].active = true
                    ordered_remove(&pane.cursors, j)
                    flag_pane(pane, {.Need_Full_Repaint})
                }
            }
        }
    }
}

@(private="file")
_calculate_new_indent :: #force_inline proc(buffer: ^Buffer, current_indent, delta: int) -> (result: int) {
    result = current_indent
    switch buffer.indent.tab_char {
    case .space: result += delta * buffer.indent.tab_size
    case .tab:   result += delta
    }
    return max(result, 0)
}

@(private="file")
_calculate_indent_delta :: proc(tokens: []Indentation_Token) -> (delta: int) {
    // maybe this should be a little bit more consistent, making sure
    // that the token that opened the next level of indentation is the
    // first one to be used to close it?

    // Emacs doesn't care if you're closing a block with the correct
    // token, so for now we'll follow the same approach.
    for token in tokens {
        switch token.action {
        case .None: // do nothi
        case .Close: delta -= 1
        case .Open:  delta += 1
        }
    }
    return
}
