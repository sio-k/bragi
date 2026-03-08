package main

import rt "base:runtime"

import "core:fmt"
import "core:log"
import "core:os/os2"

import "project"

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
}

Tab_Character :: enum {
    space, tab,
}

Modeline_Position :: enum {
    bottom, top,
}

Settings :: struct {
    editor_font_size:                                       int,
    ui_font_size:                                           int,

    always_wrap_lines:                                      bool,
    show_trailing_whitespaces:                              bool,
    purge_trailing_whitespaces_on_save:                     bool,

    cursor_is_a_block:                                      bool,
    cursor_width:                                           int,
    mouse_scroll_threshold:                                 int,
    hide_mouse_while_typing:                                bool,

    default_tab_size:                                       int,
    default_tab_character:                                  Tab_Character,
    derive_indentation_from_file:                           bool,

    show_line_numbers:                                      bool,
    maximize_window_on_start:                               bool,
    use_desktop_file:                                       bool,
    max_buffers_to_save_in_desktop:                         int,
    modeline_position:                                      Modeline_Position,
}

get_settings_filepath :: proc() -> string {
    return fmt.tprintf("{}/{}", platform_get_config_dir(), "settings.bragi")
}

settings_init :: proc() {
//    settings.editor_font_size        = 24
//    settings.ui_font_size            = 20
    settings.editor_font_size = 16
    settings.ui_font_size = 16
    settings.cursor_is_a_block       = true
    settings.cursor_width            = 2
    settings.mouse_scroll_threshold  = 5
    settings.hide_mouse_while_typing = true

    settings.always_wrap_lines                  = true
    settings.show_trailing_whitespaces          = true
    settings.purge_trailing_whitespaces_on_save = true

    settings.default_tab_size             = 4
    settings.default_tab_character        = .space
    settings.derive_indentation_from_file = true

    settings.show_line_numbers               = true
    settings.maximize_window_on_start        = true
    settings.use_desktop_file                = true
    settings.max_buffers_to_save_in_desktop  = 15
    settings.modeline_position               = .bottom

    colorscheme[.background]                        = hex_to_color(0x050505)
    colorscheme[.foreground]                        = hex_to_color(0xa08563)
    colorscheme[.highlight]                         = hex_to_color(0xcd950c)
    colorscheme[.cursor_active]                     = hex_to_color(0xcd950c)
    colorscheme[.cursor_inactive]                   = hex_to_color(0x98a098)
    colorscheme[.region]                            = hex_to_color(0x0a0b62)
    colorscheme[.search_background]                 = hex_to_color(0xa08563)
    colorscheme[.search_foreground]                 = hex_to_color(0x050505)

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

    _settings_setup_basic_bragi_keybindings()

    rt.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    settings_file_contents, settings_ok := project.read_file(get_settings_filepath())
    if settings_ok {
        settings_struct_info := type_info_of(Settings).variant.(rt.Type_Info_Named).base.variant.(rt.Type_Info_Struct)
        settings_bytes := transmute([^]u8) &settings
        for i: i32 = 0; i < settings_struct_info.field_count; i += 1 {
            name := settings_struct_info.names[i]
            offset := settings_struct_info.offsets[i]
            field_addr := &(settings_bytes[offset])
            type := settings_struct_info.types[i]
            v, v_ok := settings_file_contents[name]
            if !v_ok {
                log.debugf(
                    "settings file: didn't find a setting for %v (type %v)",
                    name, type,
                )
                continue
            }
            switch type.id {
            case int:
                target := transmute(^int) field_addr
                if v.kind != .Num {
                    log.errorf("Invalid value in settings for field %v (should be number): %v", name, v)
                } else {
                    target^ = int(v.num)
                }
            case bool:
                target := transmute(^bool) field_addr
                if v.kind != .B {
                    log.errorf("Invalid value in settings for field %v (should be bool): %v", name, v)
                } else {
                    target^ = v.b
                }
            case Tab_Character:
                target := transmute(^Tab_Character) field_addr
                if v.str == "space" {
                    target^ = .space
                } else if v.str == "tab" {
                    target^ = .tab
                } else {
                    log.errorf("Invalid value in settings for tab character: %v", v)
                }
            case Modeline_Position:
                target := transmute(^Modeline_Position) field_addr
                if v.str == "bottom" {
                    target^ = .bottom
                } else if v.str == "top" {
                    target^ = .top
                } else {
                    log.errorf("Invalid value in settings for modeline position: %v", v)
                }
            case:
                log.errorf("Don't know how to handle type %v in settings", type)
            }
        }
        log.debugf("settings loaded from file settings.bragi")

        // load keybinds
        keybinds, keybinds_ok := settings_file_contents["keys_global"]
        if keybinds_ok && keybinds.kind == .List {
            for keybindvalue in keybinds.list {
                if keybindvalue.kind != .List || len(keybindvalue.list) < 2 {
                    log.errorf("keys_global keybind values must be lists of strings, found non-list or too short list %v", keybindvalue)
                    continue
                }
                action := keybindvalue.list[0]
                bind := keybindvalue.list[1]
                if action.kind != .Str || bind.kind != .Str {
                    log.errorf("keys_global must contain all strings. Found non strings action %v, bind %v", action, bind)
                    continue
                }
                command_enum_info := type_info_of(Command).variant.(rt.Type_Info_Named).base.variant.(rt.Type_Info_Enum)
                command: Command
                command_ok := false
                for i := 0; i < len(command_enum_info.names); i += 1 {
                    if command_enum_info.names[i] == action.str {
                        command = Command(command_enum_info.values[i])
                        command_ok = true
                        break
                    }
                }
                if command_ok {
                    commands_map[bind.str] = command
                } else {
                    log.errorf(
                        "can't assign %v to command %v: command not found",
                        bind.str,
                        action.str,
                    )
                }
            }

            log.debugf("keybinds loaded from file settings.bragi")
        } else if keybinds_ok && keybinds.kind != .List {
            log.errorf(
                "keys_global must be list format ( { \"action\", \"keybind\", }, ); currently: %v",
                keybinds.kind
            )
        }
    } else if !os2.exists(get_settings_filepath()) {
        // TODO: write out default settings file
    }
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

    commands_map["ALT-W"]       = .close_current_buffer
    commands_map["ALT-S"]       = .save_buffer
    commands_map["ALT-SHIFT-S"] = .save_buffer_as

    commands_map["CTRL-G"]       = .search_forward
    commands_map["CTRL-SHIFT-G"] = .search_backward

    commands_map["CTRL-1"] = .close_other_panes
    commands_map["CTRL-2"] = .close_this_pane
    commands_map["CTRL-3"] = .new_pane_to_the_right

    commands_map["CTRL-PAGEUP"]      = .move_beginning_of_buffer
    commands_map["CTRL-PAGEDOWN"]    = .move_end_of_buffer
    commands_map["CTRL-Q"]           = .move_beginning_of_line
    commands_map["CTRL-E"]           = .move_end_of_line
    commands_map["UP"]               = .move_up
    commands_map["DOWN"]             = .move_down
    commands_map["LEFT"]             = .move_left
    commands_map["RIGHT"]            = .move_right
    commands_map["CTRL-LEFT"]        = .move_prev_word
    commands_map["CTRL-RIGHT"]       = .move_next_word
    commands_map["CTRL-UP"]          = .move_prev_page
    commands_map["PAGEUP"]           = .move_prev_page
    commands_map["CTRL-DOWN"]        = .move_next_page
    commands_map["PAGEDOWN"]         = .move_next_page

    commands_map["CTRL-SHIFT-A"]     = .select_beginning_of_line
    commands_map["CTRL-SHIFT-E"]     = .select_end_of_line
    commands_map["SHIFT-UP"]         = .select_up
    commands_map["SHIFT-DOWN"]       = .select_down
    commands_map["SHIFT-LEFT"]       = .select_left
    commands_map["SHIFT-RIGHT"]      = .select_right
    commands_map["CTRL-SHIFT-LEFT"]  = .select_prev_word
    commands_map["CTRL-SHIFT-RIGHT"] = .select_next_word

    commands_map["BACKSPACE"]        = .remove_left
    commands_map["SHIFT-BACKSPACE"]  = .remove_left
    commands_map["DELETE"]           = .remove_right
    commands_map["CTRL-D"]           = .remove_right
    commands_map["CTRL-BACKSPACE"]   = .remove_prev_word
    commands_map["CTRL-DELETE"]      = .remove_next_word
    commands_map["ALT-D"]            = .remove_next_word

    // keypad equivalents
    // TODO (sio): we need to handle keypad arrows the same as regular arrows
    commands_map["CTRL-KEYPAD 9"]      = .move_beginning_of_buffer
    commands_map["CTRL-KEYPAD 3"]    = .move_end_of_buffer
    commands_map["KEYPAD 8"]               = .move_up
    commands_map["KEYPAD 2"]             = .move_down
    commands_map["KEYPAD 4"]             = .move_left
    commands_map["KEYPAD 6"]            = .move_right
    commands_map["CTRL-KEYPAD 4"]        = .move_prev_word
    commands_map["CTRL-KEYPAD 6"]       = .move_next_word
    commands_map["CTRL-KEYPAD 8"]          = .move_prev_page
    commands_map["KEYPAD 9"]           = .move_prev_page
    commands_map["CTRL-KEYPAD 2"]        = .move_next_page
    commands_map["KEYPAD 3"]         = .move_next_page
    commands_map["SHIFT-KEYPAD 8"]         = .select_up
    commands_map["SHIFT-KEYPAD 2"]       = .select_down
    commands_map["SHIFT-KEYPAD 4"]       = .select_left
    commands_map["SHIFT-KEYPAD 6"]      = .select_right
    commands_map["CTRL-SHIFT-KEYPAD 4"]  = .select_prev_word
    commands_map["CTRL-SHIFT-KEYPAD 6"] = .select_next_word
    commands_map["KEYPAD PERIOD"]        = .remove_right
    commands_map["CTRL-KEYPAD PERIOD"]   = .remove_next_word

    commands_map["TAB"]              = .indent_or_tab_stop
    // TODO: shift-tab to insert tab stop
    commands_map["ENTER"]            = .newline_and_indent
    commands_map["SHIFT-ENTER"]      = .newline_and_indent

    commands_map["CTRL-SPACE"]     = .toggle_selection_mode

    commands_map["CTRL-B"]         = .find_buffer
    commands_map["ALT-X"]          = .find_command
    commands_map["CTRL-X"]         = .find_file
    commands_map["ALT-%"]          = .replace_in_buffer

    commands_map["CTRL-K"]         = .close_current_buffer
    commands_map["CTRL-S"]         = .save_buffer
    commands_map["CTRL-SHIFT-S"]   = .save_buffer_as

    commands_map["ALT-<"]          = .move_beginning_of_buffer
    commands_map["ALT->"]          = .move_end_of_buffer
    commands_map["CTRL-A"]         = .move_beginning_of_line
    commands_map["CTRL-E"]         = .move_end_of_line
    commands_map["CTRL-Z"]         = .move_up
    commands_map["CTRL-V"]         = .move_down
    commands_map["CTRL-R"]         = .move_prev_word
    commands_map["CTRL-F"]         = .move_next_word
    commands_map["ALT-R"]          = .move_left
    commands_map["ALT-F"]          = .move_right
    commands_map["ALT-V"]          = .move_next_paragraph
    commands_map["ALT-Z"]          = .move_prev_paragraph

//    commands_map["CTRL-X-CTRL-P"]  = .select_all

    commands_map["CTRL-1"]         = .close_other_panes
    commands_map["CTRL-0"]         = .close_this_pane
//    commands_map["CTRL-2"]         = .new_pane_below
    commands_map["CTRL-3"]         = .new_pane_to_the_right
    commands_map["CTRL-O"]         = .other_pane
    commands_map["ALT-O"]          = .other_pane

    commands_map["CTRL-W"]         = .cut_selection_or_remove_prev_word
    commands_map["ALT-W"]          = .copy_selection
    commands_map["CTRL-Y"]         = .paste

    commands_map["CTRL-/"]         = .undo
    commands_map["CTRL-?"]         = .redo

    commands_map["CTRL-N"]         = .new_window
    commands_map["CTRL-Q"]         = .close_window
}

hex_to_color :: proc(hex: int) -> (result: Color) {
    result.r = u8((hex >> 16) & 0xff)
    result.g = u8((hex >> 8) & 0xff)
    result.b = u8((hex) & 0xff)
    result.a = 255
    return
}
