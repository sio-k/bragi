package main

import "base:runtime"

import "core:crypto"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:os/os2"
import "core:path/filepath"
import "core:time"

when BRAGI_DEBUG {
    NAME :: "Bragi DEBUG"
} else {
    NAME :: "Bragi"
}

ID      :: "bragi"
AUTHOR  :: "Nahuel J. Sacchetti"
URL     :: "https://github.com/nawetimebomb/bragi"
VERSION :: "0.01"
ICON    :: #load(RUN_TREE_DIR + "/icons/bragi-icon_large.png")

BRAGI_DEBUG :: #config(BRAGI_DEBUG, false) // enables functionality in debug.odin

RUN_TREE_DIR :: "../res"

FONT_EDITOR_NAME    :: "chivo-mono.ttf"
FONT_EDITOR_DATA    :: #load(RUN_TREE_DIR + "/fonts/chivo-mono.ttf")
FONT_UI_NAME        :: "roboto-regular.ttf"
FONT_UI_DATA        :: #load(RUN_TREE_DIR + "/fonts/roboto-regular.ttf")
FONT_UI_ITALIC_NAME :: "roboto-italic.ttf"
FONT_UI_ITALIC_DATA :: #load(RUN_TREE_DIR + "/fonts/roboto-italic.ttf")
FONT_UI_BOLD_NAME   :: "roboto-semibold.ttf"
FONT_UI_BOLD_DATA   :: #load(RUN_TREE_DIR + "/fonts/roboto-bold.ttf")
FONT_ICONS_NAME     :: "fontawesome.ttf"
FONT_ICONS_DATA     :: #load(RUN_TREE_DIR + "/fonts/fontawesome.ttf")

DEFAULT_SETTINGS_DATA :: #load(RUN_TREE_DIR + "/settings.bragi")
SETTINGS_FILENAME     :: "settings.bragi"

settings_file: ^os2.File
settings:      Settings

// TODO (sio): this should probably be an array rather than a map
colorscheme:   map[Face_Color]Color

open_buffers:  [dynamic]^Buffer

base_working_dir:    string // used in widget
curr_working_dir:    string // the executable directory
last_search_term:    string
commands_map:        map[string]Command
events_this_frame:   [dynamic]Event
modifiers_queue:     [dynamic]string

bragi_allocator:   runtime.Allocator
bragi_context:     runtime.Context
bragi_running:     bool

// TODO(nawe) this should probably be an arena allocator that will contain
// the editor settings and array of panes and buffers. The buffer content
// should be virtual alloc themselves on their own arena, but for now we're
// always running in debug, so we care more about the tracking allocator.
tracking_allocator: mem.Tracking_Allocator

main :: proc() {
    initialization_time := time.now()
    when BRAGI_DEBUG {
        default_allocator := context.allocator
        mem.tracking_allocator_init(&tracking_allocator, default_allocator)
        context.allocator = mem.tracking_allocator(&tracking_allocator)

        reset_tracking_allocator :: proc(a: ^mem.Tracking_Allocator) -> bool {
            err := false

            for _, value in a.allocation_map {
                log.errorf("{0}: leaked {1} bytes", value.location, value.size)
                err = true
            }

            mem.tracking_allocator_clear(a)
            return err
        }

        context.logger = log.create_console_logger()
    }

    context.random_generator = crypto.random_generator()

    bragi_allocator = context.allocator

    curr_working_dir, _ = os2.get_executable_path(bragi_allocator)

    settings_init()
    platform_init()
    fonts_init()
    windows_init()
    commands_init()
    major_modes_init()

    // NOTE (sio): debug only on primary window (for now)
    DEBUG_init(windows[0])

    if len(os.args) >= 2 {
        // either given files to open or a project file
        log.debugf("got args on command line, not using desktop file")
        handled := false
        if len(os.args) == 2 {
            runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
            // maybe project file
            pfname := filepath.base(os.args[1])
            if pfname == "project.4coder" || pfname == "project.bragi" {
                log.debugf(
                    "got a project file, loading project from file at %v",
                    os.args[1]
                )
                ok := load_project(os.args[1])
                if !ok {
                    log.errorf("failed to load project file.")
                }

                // no matter what the settings say, don't load nor save the desktop file
                // TODO: change desktop file format to 4coder file format and have project desktop files
                settings.use_desktop_file = false

                handled = true
            }
        }

        if !handled {
            for path in os.args[1:] {
                open_file_in_buffer(path)
            }
        }
    }

    desktop_init()

    // TODO: if handed a project file on the command line, load that instead of desktop, and don't use desktop file

    for w in windows {
        widget_reinit(w)
    }

    bragi_running = true

    log.debugf(
        "initialization complete in {} milliseconds",
        time.duration_milliseconds(time.since(initialization_time)),
    )

    for w in windows {
        w.previous_frame_time = time.tick_now()
    }

    for bragi_running {
        profiling_start("parsing events")

        for w in windows {
            input_update_mouse_state(w)
        }
        platform_update_events()

        // NOTE(nawe) text input events come with their singular key
        // pressed event as well. If the event was handled by the key
        // press, we need to ignore the text input.
        text_input_events_to_ignore_this_frame := 0

        for &event in events_this_frame {
            event.window.last_keystroke = time.tick_now()

            switch v in event.variant {
            case Event_Drop_File:
                found := false

                for buffer in open_buffers {
                    if buffer.filepath == v.filepath {
                        switch_to_buffer(event.window.active_pane, buffer)
                        found = true
                        break
                    }
                }

                if !found {
                    buffer := buffer_get_or_create_from_file(v.filepath, v.data)
                    switch_to_buffer(event.window.active_pane, buffer)
                }

                event.handled = true
            case Event_Keyboard:
                if v.is_text_input && settings.hide_mouse_while_typing {
                    platform_toggle_cursor(false)
                }

                if v.is_text_input && text_input_events_to_ignore_this_frame > 0 {
                    text_input_events_to_ignore_this_frame -= 1
                    event.handled = true
                    continue
                }

                // will always be false if BRAGI_DEBUG is not defined.
                handled := DEBUG_handle_input(event)

                cmd: Command = .noop
                key_combo: string

                if !v.is_text_input && !handled {
                    cmd, key_combo = map_keystroke_to_command(v.key_code, v.modifiers)

                    #partial switch cmd {
                    case .modifier:
                        append(&modifiers_queue, fmt.aprintf("{}-", key_combo))
                        handled = true

                    case .quit_mode:
                        quit_mode_command(event.window)
                        handled = true

                    case .new_window:
                        new_window()
                        handled = true

                    case .close_window:
                        if !is_last_window(event.window) {
                            close_window(event.window)
                        } else {
                            bragi_running = false
                        }
                        handled = true
                    }
                }

                if !handled {
                    if event.window.global_widget.active {
                        handled = widget_keyboard_event_handler(event.window, v, cmd)
                    } else {
                        handled = pane_keyboard_event_handler(event.window, v, cmd)
                    }
                }

                // NOTE(nawe) this event was already handled by the
                // key pressed event and so we skip the next related
                // text input. This is to allow bindings with
                // modifiers that also have regular alphanumeric or
                // symbol characters as key pressed, like in Emacs C-x-3.
                if !v.is_text_input && handled {
                    text_input_events_to_ignore_this_frame += 1
                }

                event.handled = handled
            case Event_Mouse:
                if event.window.window_in_focus {
                    event.handled = DEBUG_handle_input(event)
                }
            case Event_Quit:
                bragi_running = false
                event.handled = true
            case Event_Window:
                if v.closed {
                    if !is_last_window(event.window) {
                        close_window(event.window)
                    } else {
                        bragi_running = false
                    }
                    event.handled = true
                    continue
                }

                if v.resizing || v.moving {
                    // NOTE(nawe) The user hasn't finished moving or
                    // resizing the window yet, so we skip any kind of
                    // checks. Maybe is also good to just skip
                    // rendering this frame, though we would want to
                    // keep reading inputs.
                    event.handled = true
                    continue
                }

                should_reinit_fonts := false
                event.window.should_resize_panes = false
                event.window.window_in_focus = v.window_focused

                if v.dpi_scale != event.window.platform.dpi_scale {
                    log.debugf("updating necessary stuff after DPI change")
                    event.window.platform.dpi_scale = v.dpi_scale
                    should_reinit_fonts = true
                    event.window.should_resize_panes = true
                }

                if event.window.platform.window_width != v.window_width || event.window.platform.window_height != v.window_height {
                    event.window.platform.window_width = v.window_width
                    event.window.platform.window_height = v.window_height
                    event.window.should_resize_panes = true
                }

                if should_reinit_fonts {
                    log.debug("reinitializing fonts")
                    font_cache_destroy(event.window)
                    font_cache_init(event.window)
                }

                if event.window.should_resize_panes {
                    log.debug("updating necessary textures after resizing")
                    update_pane_layout(event.window)
                    widget_reinit(event.window)
                }

                event.handled = true
            }
        }

        for w in windows {
            // we don't want to try handling mouse events for windows that aren't in focus
            if w.window_in_focus {
                pane_handle_mouse_events(w)
            }
        }

        profiling_end()

        for w, widx in windows {
            set_color(w, .background)
            prepare_for_drawing(w)

            update_opened_buffers()
            update_and_draw_panes(w)
            update_and_draw_widget(w)

            // HACK (sio): debug is only drawn on main window
            if widx == 0 {
                DEBUG_draw()
            }

            draw_frame(w)
        }

        platform_sleep()

        for w in windows {
            w.frame_delta_time = time.tick_lap_time(&w.previous_frame_time)
        }
        DEBUG_update()
        free_all(context.temp_allocator)
    }

    desktop_save()

    input_destroy()

    DEBUG_destroy()
    windows_destroy()

    commands_destroy()
    major_modes_destroy()

    for buffer in open_buffers do buffer_destroy(buffer)

    delete(open_buffers)
    delete(colorscheme)
    delete(base_working_dir)
    delete(curr_working_dir)
    delete(last_search_term)

    fonts_destroy()
    platform_destroy()

    when BRAGI_DEBUG {
        log.destroy_console_logger(context.logger)
        reset_tracking_allocator(&tracking_allocator)
        mem.tracking_allocator_destroy(&tracking_allocator)
    }
}
