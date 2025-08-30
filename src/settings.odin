package main

Color :: distinct [4]u8

Face_Color :: enum u8 {
    // used internally to let other system decide.
    undefined = 0,

    background,
    foreground,
    cursor_active,
    cursor_inactive,
    highlight,
    region,
    search_background,
    search_foreground,

    code_builtin,
    code_comment,
    code_constant_value,
    code_directive,
    code_enum_variant,
    code_function_name,
    code_keyword,
    code_string,
    code_type,
    code_variable_name,

    ui_border,
    ui_trailing_whitespace,
    ui_selection_background,
    ui_selection_foreground,
    ui_line_number_background,
    ui_line_number_foreground,
    ui_line_number_background_current,
    ui_line_number_foreground_current,
    ui_modeline_active_background,
    ui_modeline_active_foreground,
    ui_modeline_active_highlight,
    ui_modeline_inactive_background,
    ui_modeline_inactive_foreground,

    debug_background,
    debug_foreground,
}

Tab_Character :: enum {
    space, tab,
}

Modeline_Position :: enum {
    bottom, top,
}

Settings :: struct {
    editor_font_size:          int,
    ui_font_size:              int,

    always_wrap_lines:         bool,
    show_trailing_whitespaces: bool,
    purge_trailing_whitespaces_on_save: bool,

    cursor_is_a_block:        bool,
    cursor_width:             int,

    default_tab_size:         int,
    default_tab_character:    Tab_Character,
    show_line_numbers:        bool,
    maximize_window_on_start: bool,
    modeline_position:        Modeline_Position,
}

settings_init :: proc() {
    settings.editor_font_size  = 24
    settings.ui_font_size      = 20
    settings.cursor_is_a_block = true
    settings.cursor_width      = 2

    settings.always_wrap_lines                  = true
    settings.show_trailing_whitespaces          = true
    settings.purge_trailing_whitespaces_on_save = true

    settings.default_tab_size         = 4
    settings.default_tab_character    = .space
    settings.show_line_numbers        = true
    settings.maximize_window_on_start = true
    settings.modeline_position        = .bottom

    colorscheme[.background]                        = hex_to_color(0x050505)
    colorscheme[.foreground]                        = hex_to_color(0xa08563)
    colorscheme[.highlight]                         = hex_to_color(0xcd950c)
    colorscheme[.cursor_active]                     = hex_to_color(0xcd950c)
    colorscheme[.cursor_inactive]                   = hex_to_color(0x98a098)
    colorscheme[.region]                            = hex_to_color(0x0a0b62)
    colorscheme[.search_background]                 = hex_to_color(0xd2d2d2)
    colorscheme[.search_foreground]                 = hex_to_color(0x010101)

    colorscheme[.code_builtin]                      = hex_to_color(0x875e9a)
    colorscheme[.code_comment]                      = hex_to_color(0xe27d51)
    colorscheme[.code_constant_value]               = hex_to_color(0x5aa0b3)
    colorscheme[.code_directive]                    = hex_to_color(0x875e9a)
    colorscheme[.code_enum_variant]                 = hex_to_color(0x98a098)
    colorscheme[.code_function_name]                = hex_to_color(0xa08563)
    colorscheme[.code_keyword]                      = hex_to_color(0xcd950c)
    colorscheme[.code_string]                       = hex_to_color(0x6b8e23)
    colorscheme[.code_type]                         = hex_to_color(0x98a098)
    colorscheme[.code_variable_name]                = hex_to_color(0xa08563)

    colorscheme[.ui_border]                         = hex_to_color(0x373b41)
    colorscheme[.ui_trailing_whitespace]            = hex_to_color(0xe66250)
    colorscheme[.ui_selection_background]           = hex_to_color(0x0a0b62)
    colorscheme[.ui_selection_foreground]           = hex_to_color(0xd2d2d2)
    colorscheme[.ui_line_number_background]         = hex_to_color(0x050505)
    colorscheme[.ui_line_number_foreground]         = hex_to_color(0x373b41)
    colorscheme[.ui_line_number_background_current] = hex_to_color(0x131313)
    colorscheme[.ui_line_number_foreground_current] = hex_to_color(0x98a098)
    colorscheme[.ui_modeline_active_background]     = hex_to_color(0x131313)
    colorscheme[.ui_modeline_active_foreground]     = hex_to_color(0xa08563)
    colorscheme[.ui_modeline_active_highlight]      = hex_to_color(0xcd950c)

    colorscheme[.ui_modeline_inactive_background]   = hex_to_color(0x010101)
    colorscheme[.ui_modeline_inactive_foreground]   = hex_to_color(0x616161)

    colorscheme[.debug_background] = {16, 16, 16, 150}
    colorscheme[.debug_foreground] = {255, 255, 255, 255}

    _settings_setup_basic_bragi_keybindings()
}

// Just the default, basic, keybindings for Bragi
@(private="file")
_settings_setup_basic_bragi_keybindings :: proc() {
    commands_map["ESCAPE"] = .quit_mode

    commands_map["CTRL-+"] = .increase_font_size
    commands_map["CTRL--"] = .decrease_font_size
    commands_map["CTRL-0"] = .reset_font_size

    commands_map["ALT-B"] =  .find_buffer
    commands_map["ALT-X"] =  .find_command
    commands_map["ALT-F"] =  .find_file

    commands_map["ALT-W"] = .close_current_buffer
    commands_map["ALT-S"] = .save_buffer
    commands_map["ALT-SHIFT-S"] = .save_buffer_as

    commands_map["CTRL-S"] = .search_forward
    commands_map["CTRL-SHIFT-S"] = .search_backward

    commands_map["CTRL-1"] = .close_other_panes
    commands_map["CTRL-2"] = .close_this_pane
    commands_map["CTRL-3"] = .new_pane_to_the_right
    commands_map["CTRL-O"] = .other_pane

    commands_map["ALT-UP"]           = .clone_cursor_above
    commands_map["ALT-DOWN"]         = .clone_cursor_below
    commands_map["CTRL-L"]           = .recenter_cursor
    commands_map["CTRL-SHIFT-TAB"]   = .prev_cursor
    commands_map["CTRL-TAB"]         = .next_cursor
    commands_map["CTRL-SHIFT-A"]     = .all_cursors

    commands_map["CTRL-SHIFT-Q"]     = .move_start
    commands_map["CTRL-SHIFT-E"]     = .move_end
    commands_map["CTRL-Q"]           = .move_beginning_of_line
    commands_map["CTRL-E"]           = .move_end_of_line
    commands_map["UP"]               = .move_up
    commands_map["DOWN"]             = .move_down
    commands_map["LEFT"]             = .move_left
    commands_map["RIGHT"]            = .move_right
    commands_map["CTRL-UP"]          = .move_prev_paragraph
    commands_map["CTRL-DOWN"]        = .move_next_paragraph
    commands_map["CTRL-LEFT"]        = .move_prev_word
    commands_map["CTRL-RIGHT"]       = .move_next_word
    commands_map["CTRL-SHIFT-UP"]    = .move_prev_page
    commands_map["PAGEUP"]           = .move_prev_page
    commands_map["CTRL-SHIFT-DOWN"]  = .move_next_page
    commands_map["PAGEDOWN"]         = .move_next_page

    commands_map["CTRL-A"]           = .select_all
    commands_map["CTRL-SHIFT-Q"]     = .select_beginning_of_line
    commands_map["CTRL-SHIFT-E"]     = .select_end_of_line
    commands_map["SHIFT-UP"]         = .select_up
    commands_map["SHIFT-DOWN"]       = .select_down
    commands_map["SHIFT-LEFT"]       = .select_left
    commands_map["SHIFT-RIGHT"]      = .select_right
    commands_map["CTRL-SHIFT-LEFT"]  = .select_prev_word
    commands_map["CTRL-SHIFT-RIGHT"] = .select_next_word

    commands_map["BACKSPACE"]        = .remove_left
    commands_map["DELETE"]           = .remove_right
    commands_map["CTRL-D"]           = .remove_right
    commands_map["CTRL-BACKSPACE"]   = .remove_prev_word
    commands_map["CTRL-DELETE"]      = .remove_next_word
    commands_map["CTRL-SHIFT-D"]     = .remove_next_word

    commands_map["TAB"]              = .indent_or_tab_stop

    commands_map["CTRL-X"]           = .cut_selection
    commands_map["CTRL-SHIFT-X"]     = .cut_line
    commands_map["CTRL-C"]           = .copy_selection
    commands_map["CTRL-SHIFT-C"]     = .copy_line
    commands_map["CTRL-V"]           = .paste
    commands_map["CTRL-SHIFT-V"]     = .paste_from_history

    commands_map["CTRL-Z"]           = .undo
    commands_map["CTRL-SHIFT-Z"]     = .redo
}

hex_to_color :: proc(hex: int) -> (result: Color) {
    result.r = u8((hex >> 16) & 0xff)
    result.g = u8((hex >> 8) & 0xff)
    result.b = u8((hex) & 0xff)
    result.a = 255
    return
}
