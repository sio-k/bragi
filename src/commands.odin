package main

import "core:log"
import "core:strings"

Command :: enum u32 {
    noop,     // nothing
    modifier, // register and save to modify the next command

    increase_font_size,
    decrease_font_size,
    reset_font_size,

    quit_mode, // resets all modes

    toggle_selection_mode,
    toggle_line_wrappings,

    remove_left,
    remove_right,
    remove_prev_word,
    remove_next_word,

    indent_or_tab_stop,

    clone_cursor_above,
    clone_cursor_below,
    recenter_cursor,
    prev_cursor,
    next_cursor,
    all_cursors,

    move_start,
    move_end,
    move_up,
    move_down,
    move_left,
    move_right,
    move_prev_word,
    move_next_word,
    move_prev_paragraph,
    move_next_paragraph,
    move_prev_page,
    move_next_page,
    move_beginning_of_line,
    move_end_of_line,

    select_all,
    select_start,
    select_end,
    select_up,
    select_down,
    select_left,
    select_right,
    select_prev_word,
    select_next_word,
    select_prev_paragraph,
    select_next_paragraph,
    select_prev_page,
    select_next_page,
    select_beginning_of_line,
    select_end_of_line,

    find_buffer,
    find_command,
    find_file,

    close_current_buffer,
    save_buffer,
    save_buffer_as,

    search_backward,
    search_forward,

    close_this_pane,
    close_other_panes,
    new_pane_to_the_right,
    other_pane,

    undo,
    redo,

    cut_selection,
    cut_line,
    copy_selection,
    copy_line,
    paste,
    paste_from_history,
}

commands_init :: proc() {
    log.warn("setting default commands, this should be replaced for commands in settings.bragi")
}

commands_destroy :: proc() {
    delete(commands_map)
    delete(modifiers_queue)
}

map_keystroke_to_command :: proc(key: Key_Code, modifiers: Modifiers_Set, loc := #caller_location) -> (Command, string) {
    key_combo := strings.builder_make(context.temp_allocator)

    for len(modifiers_queue) > 0 {
        mod := pop(&modifiers_queue)
        strings.write_string(&key_combo, mod)
        delete(mod)
    }

    if .Ctrl    in modifiers do strings.write_string(&key_combo, "CTRL-")
    if .Command in modifiers do strings.write_string(&key_combo, "CMD-")
    if .Alt     in modifiers do strings.write_string(&key_combo, "ALT-")
    if .Shift   in modifiers do strings.write_string(&key_combo, "SHIFT-")
    if .Super   in modifiers do strings.write_string(&key_combo, "SUPER-")

    strings.write_string(
            &key_combo,
        strings.to_upper(input_key_code_to_string(key), context.temp_allocator),
    )
    cmd_key_combo := strings.to_string(key_combo)

    cmd, ok := commands_map[cmd_key_combo]

    if ok {
        return cmd, cmd_key_combo
    }

    return .noop, cmd_key_combo
}

quit_mode_command :: proc() {
    widget_close()
    active_pane.cursor_selecting = false

    if len(active_pane.cursors) > 1 {
        last_cursor_pos := active_pane.cursors[len(active_pane.cursors) - 1].pos
        clear(&active_pane.cursors)
        add_cursor(active_pane, last_cursor_pos)
    } else {
        cursor := get_first_active_cursor(active_pane)
        cursor.sel = cursor.pos
    }
}
