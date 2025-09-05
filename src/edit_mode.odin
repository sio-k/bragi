package main

import "core:encoding/uuid"
import "core:log"
import "core:slice"
import "core:strings"

// edit mode is when we're editing a file
edit_mode_keyboard_event_handler :: proc(event: Event_Keyboard, cmd: Command) -> bool {
    pane := active_pane
    buffer := pane.buffer

    if event.is_text_input {
        insert_at_points(pane, event.text)
        return true
    }

    switch cmd {
    case .noop:      return false // not handled, it should report for now
    case .modifier:  // handled globally
    case .quit_mode: // handled globally

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
        editor_toggle_selection(pane)
        return true

    case .toggle_line_wrappings:
        if .Line_Wrappings in pane.flags {
            unflag_pane(pane, {.Line_Wrappings})
        } else {
            flag_pane(pane, {.Line_Wrappings})
        }
        return true

    case .newline_and_indent:
        insert_newlines_and_indent(pane)
        return true
    case .indent_or_tab_stop:
        maybe_indent_and_go_to_tab_stop(pane)
        return true

    case .clone_cursor_above:
        clone_to(pane, .up)
        return true
    case .clone_cursor_below:
        clone_to(pane, .down)
        return true
    case .prev_cursor:
        if pane.cursor_selecting {
            pane.cursor_selecting = false
            for &cursor in pane.cursors do cursor.sel = cursor.pos
        }

        current_cursor_index := -1

        for &cursor, index in pane.cursors {
            if cursor.active {
                current_cursor_index = index
                cursor.active = false
            }
        }

        current_cursor_index -= 1
        if current_cursor_index < 0 do current_cursor_index = len(pane.cursors) - 1
        pane.cursors[current_cursor_index].active = true
        pane.cursor_moved = true
        return true
    case .next_cursor:
        if pane.cursor_selecting {
            pane.cursor_selecting = false
            for &cursor in pane.cursors do cursor.sel = cursor.pos
        }

        current_cursor_index := -1

        for &cursor, index in pane.cursors {
            if cursor.active {
                current_cursor_index = index
                cursor.active = false
            }
        }

        current_cursor_index += 1
        if current_cursor_index > len(pane.cursors) - 1 do current_cursor_index = 0
        pane.cursors[current_cursor_index].active = true
        pane.cursor_moved = true
        return true
    case .all_cursors:
        for &cursor in pane.cursors do cursor.active = true
        return true
    case .recenter_cursor:
        maybe_recenter_cursor(pane, true)
        return true

    case .move_start:
        move_to(pane, .start)
        return true
    case .move_end:
        move_to(pane, .end)
        return true
    case .move_left:
        move_to(pane, .left)
        return true
    case .move_right:
        move_to(pane, .right)
        return true
    case .move_down:
        move_to(pane, .down)
        return true
    case .move_up:
        move_to(pane, .up)
        return true
    case .move_prev_word:
        move_to(pane, .prev_word)
        return true
    case .move_next_word:
        move_to(pane, .next_word)
        return true
    case .move_prev_paragraph:
        move_to(pane, .prev_paragraph)
        return true
    case .move_next_paragraph:
        move_to(pane, .next_paragraph)
        return true
    case .move_prev_page:
        move_to(pane, .prev_page)
        maybe_recenter_cursor(pane)
        return true
    case .move_next_page:
        move_to(pane, .next_page)
        maybe_recenter_cursor(pane)
        return true
    case .move_beginning_of_line:
        move_to(pane, .beginning_of_line)
        return true
    case .move_end_of_line:
        move_to(pane, .end_of_line)
        return true

    case .select_all:
        clear(&pane.cursors)
        add_cursor(pane, len(buffer.text))
        pane.cursors[0].pos = 0
        pane.cursor_moved = true
        return true
    case .select_start:
        select_to(pane, .start)
        return true
    case .select_end:
        select_to(pane, .end)
        return true
    case .select_left:
        select_to(pane, .left)
        return true
    case .select_right:
        select_to(pane, .right)
        return true
    case .select_down:
        select_to(pane, .down)
        return true
    case .select_up:
        select_to(pane, .up)
        return true
    case .select_prev_word:
        select_to(pane, .prev_word)
        return true
    case .select_next_word:
        select_to(pane, .next_word)
        return true
    case .select_prev_paragraph:
        select_to(pane, .prev_paragraph)
        return true
    case .select_next_paragraph:
        select_to(pane, .next_paragraph)
        return true
    case .select_prev_page:
        select_to(pane, .prev_page)
        return true
    case .select_next_page:
        select_to(pane, .next_page)
        return true
    case .select_beginning_of_line:
        select_to(pane, .beginning_of_line)
        return true
    case .select_end_of_line:
        select_to(pane, .end_of_line)
        return true

    case .remove_left:
        remove_to(pane, .left)
        return true
    case .remove_right:
        remove_to(pane, .right)
        return true
    case .remove_prev_word:
        remove_to(pane, .prev_word)
        return true
    case .remove_next_word:
        remove_to(pane, .next_word)
        return true

    case .find_buffer:
        widget_open_find_buffer()
        return true
    case .find_command:
        return false
    case .find_file:
        widget_open_find_file()
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

    case .undo:
        copy_cursors(pane, buffer)
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
        editor_toggle_selection(pane, true)
        profiling_end()
        return true
    case .redo:
        copy_cursors(pane, buffer)
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
        editor_toggle_selection(pane, true)
        profiling_end()
        return true

    case .cut_selection:
        copy_selected_text(pane, true)
        remove_selections(pane)
        return true
    case .cut_line:
        select_to(pane, .end_of_line)
        copy_selected_text(pane, true)
        remove_selections(pane)
        return true
    case .copy_selection:
        copy_selected_text(pane)
        pane.cursor_selecting = false
        return true
    case .copy_line:
        select_to(pane, .end_of_line)
        copy_selected_text(pane)
        return true
    case .paste:
        text := platform_get_clipboard_text()
        if len(text) > 0 do insert_at_points(pane, text)
        return true
    case .paste_from_history:
    }

    return false
}

copy_selected_text :: proc(pane: ^Pane, keep_selection := false) {
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

clone_to :: proc(pane: ^Pane, t: Translation) {
    if len(pane.cursors) == 1 {
        cloned := clone_cursor(pane, pane.cursors[0])
        move_to(pane, t, cloned)
    } else if !are_all_cursors_active(pane) {
        cursor_to_clone := get_first_active_cursor(pane)
        cloned := clone_cursor(pane, cursor_to_clone^)
        move_to(pane, t, cloned)
        cursor_to_clone.active = false
        cloned.active = true
    } else {
        pane.cursor_selecting = false
        for &cursor in pane.cursors do cursor.sel = cursor.pos

        if t == .up {
            cursor_to_clone: Cursor
            lo_pos := len(pane.buffer.text)

            for cursor in pane.cursors {
                lo_pos = min(lo_pos, cursor.pos)
                if lo_pos == cursor.pos do cursor_to_clone = cursor
            }
            cloned := clone_cursor(pane, cursor_to_clone)
            move_to(pane, t, cloned)
        } else if t == .down {
            cursor_to_clone: Cursor
            hi_pos := 0

            for cursor in pane.cursors {
                hi_pos = max(hi_pos, cursor.pos)
                if hi_pos == cursor.pos do cursor_to_clone = cursor
            }
            cloned := clone_cursor(pane, cursor_to_clone)
            move_to(pane, t, cloned)
        }
    }
}

move_to :: proc(pane: ^Pane, t: Translation, cursor_to_move: ^Cursor = nil) {
    move_cursor :: #force_inline proc(pane: ^Pane, cursor: ^Cursor, t: Translation) {
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
        move_cursor(pane, cursor_to_move, t)
    } else {
        if pane.cursor_selecting {
            select_to(pane, t)
        } else {
            for &cursor in pane.cursors {
                if !cursor.active do continue
                move_cursor(pane, &cursor, t)
            }
        }
    }

    _maybe_merge_overlapping_cursors(pane)
    pane.cursor_moved = true
}

select_to :: proc(pane: ^Pane, t: Translation, cursor_to_select: ^Cursor = nil) {
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

remove_to :: proc(pane: ^Pane, t: Translation) -> (total_amount_of_removed_characters: int) {
    profiling_start("removing text")
    copy_cursors(pane, pane.buffer)

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

    remove_selections(pane)
    pane.cursor_moved = true
    profiling_end()
    return
}

remove_selections :: proc(pane: ^Pane, array: ^[dynamic]Cursor = nil) {
    cursors_array := array == nil ? &pane.cursors : array
    copy_cursors(pane, pane.buffer)

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

    pane.cursor_selecting = false
    pane.cursor_moved = true
    _maybe_merge_overlapping_cursors(pane)
}

insert_at_points :: proc(pane: ^Pane, text: string) {
    profiling_start("inserting text")
    copy_cursors(pane, pane.buffer)
    sort_cursors_by_offset(pane)

    // check if the inserted text may need indentation
    indent_tokens := get_indentation_tokens(pane.buffer, text)
    maybe_should_reindent := len(indent_tokens) > 0 && indent_tokens[0].action == .Close
    temp_lines_to_indent := make([dynamic]int, context.temp_allocator)

    remove_selections(pane)

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

insert_newlines_and_indent :: proc(pane: ^Pane) {
    if .Read_Only in pane.buffer.flags {
        log.debugf("buffer {} is a read only buffer", pane.buffer.name)
        return
    }

    profiling_start("insert newlines and indent")
    copy_cursors(pane, pane.buffer)
    remove_selections(pane)
    sort_cursors_by_offset(pane)

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

maybe_indent_and_go_to_tab_stop :: proc(pane: ^Pane) {
    // only call this in current pane
    assert(pane.uuid == active_pane.uuid)

    copy_cursors(pane, pane.buffer)

    // if the buffer is not expecting indentation, just treat it as
    // moving to the beginning of line.
    if !should_do_electric_indent(pane.buffer) {
        move_to(pane, .beginning_of_line)
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
}

maybe_recenter_cursor :: proc(pane: ^Pane, force_recenter := false) {
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

editor_toggle_selection :: proc(pane: ^Pane, force_reset := false) {
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

Indent_Callback_Proc :: #type proc(prev_offset, new_offset, amount: int)

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
