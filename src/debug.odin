package main

import     "core:fmt"
import     "core:log"
import     "core:prof/spall"
import     "core:reflect"
import     "core:slice"
import     "core:time"
import     "core:unicode/utf8"
import sdl "vendor:sdl3"

_ :: fmt
_ :: log
_ :: reflect
_ :: spall
_ :: slice
_ :: time
_ :: sdl

debug: Debug

when BRAGI_DEBUG {
    DEBUG_WINDOW_SIZE :: MINIMUM_WINDOW_SIZE

    Debug :: struct {
        show_debug_overlay: bool,

        mouse_dragging: bool,
        minimized:      bool,

        rect:           Rect,
        transparency:   f32,
        texture:        ^Texture,

        show_debug_info: bool,
        profiling:       bool,
        spall_buf:       spall.Buffer,
        spall_ctx:       spall.Context,

    }

    Debug_Tab :: enum u8 {
        Render,
        Memory,
    }

    @(private="file")
    _debug: struct {
        show_debug_overlay: bool,

        minimized:          bool,
        mouse_dragging:     bool,

        tabs:               [len(Debug_Tab)]Rect,
        current_tab:        Debug_Tab,

        // render tab
        fps_max:            int,
        fps_min:            int,
        fps_average:        int,
        fps_values:         [100]int,
        fps_curr_index:     int,

        rect:               Rect,
        texture:            ^Texture,
        transparency:       f32,
    }

    DEBUG_init :: proc() {
        _debug.rect = {10, 10, DEBUG_WINDOW_SIZE, DEBUG_WINDOW_SIZE }
        _debug.transparency = 1.0
        _debug.texture = texture_create(.TARGET, DEBUG_WINDOW_SIZE, DEBUG_WINDOW_SIZE)

        // forcibly setting this to something high so it doesn't show 0
        _debug.fps_min = 999
    }

    DEBUG_destroy :: proc() {
        texture_destroy(_debug.texture)
    }

    DEBUG_handle_input :: proc(event: Event) -> bool {
        #partial switch v in event.variant {
        case Event_Keyboard:
            if v.key_code == .K_F8 {
                _debug.minimized = !_debug.minimized
                return true
            }
            if v.key_code == .K_F9 {
                DEBUG_toggle_overlay()
                return true
            }
        }

        return false
    }

    DEBUG_update_draw :: proc() {
        if frame_count < 60 do return
        frametime := time.duration_milliseconds(frame_delta_time)
        current_fps := int(1000/frametime)
        _debug.fps_values[_debug.fps_curr_index] = current_fps
        _debug.fps_curr_index += 1
        if _debug.fps_curr_index > 99 do _debug.fps_curr_index = 0
        _debug.fps_max = max(_debug.fps_max, current_fps)
        _debug.fps_min = min(_debug.fps_min, current_fps)
        total_fps_values := slice.reduce(_debug.fps_values[:], 0, proc(acc: int, value: int) -> int {
            return acc + value
        })
        _debug.fps_average = total_fps_values / len(_debug.fps_values)

        if !_debug.show_debug_overlay do return

        ICON :: proc(x: rune) -> string {
            return utf8.runes_to_string({x, ' '}, context.temp_allocator)
        }

        BACKGROUND_DARK    :: 0x01080e
        BACKGROUND_LIGHT   :: 0x011627
        BORDER             :: 0x5f7e97
        FOREGROUND         :: 0xd6deeb
        BUTTON_INACTIVE_BG :: 0x0b2942
        BUTTON_INACTIVE_FG :: 0x676e95
        BUTTON_ACTIVE_BG   :: 0x4b6479
        BUTTON_ACTIVE_FG   :: 0xffeb95

        TITLE_PADDING :: 6

        font_regular := fonts_map[.UI_Regular]
        font_bold := fonts_map[.UI_Bold]
        font_icons := fonts_map[.Icons]

        set_target(_debug.texture)
        set_custom_color(BACKGROUND_LIGHT)
        prepare_for_drawing()

        {
            // basic layout
            w, h := i32(_debug.rect.w)-1, i32(_debug.rect.h)-1
            h2 := font_bold.line_height + TITLE_PADDING // below the title
            set_custom_color(BACKGROUND_DARK)
            draw_rect(0, 0, w, h2)
            set_custom_color(BORDER)
            draw_line(0, 0, 0, h)
            draw_line(0, 0, w, 0)
            draw_line(w, 0, w, h)
            draw_line(0, h, w, h)
            draw_line(0, h2, w, h2)
            set_custom_color(FOREGROUND, font_bold.texture)
            set_custom_color(FOREGROUND, font_icons.texture)
            pen_for_title := Vector2{16, 3}
            title_icon : rune = _debug.minimized ? 0xf0d8 : 0xf0d7
            pen_for_title = draw_text(font_icons, pen_for_title, ICON(title_icon))
            draw_text(font_bold, pen_for_title, "Bragi Debug")
        }

        {
            // tabs
            pen_for_tabs := Vector2{1, font_bold.line_height + 7}

            for tab, index in Debug_Tab {
                tab_name := fmt.tprintf("   {}   ", reflect.enum_string(tab))
                x := pen_for_tabs.x
                y := pen_for_tabs.y
                w := prepare_text(font_bold, tab_name)
                h := font_bold.line_height
                if _debug.current_tab == tab {
                    set_custom_color(BUTTON_ACTIVE_BG)
                    set_custom_color(BUTTON_ACTIVE_FG, font_bold.texture)
                } else {
                    set_custom_color(BUTTON_INACTIVE_BG)
                    set_custom_color(BUTTON_INACTIVE_FG, font_bold.texture)
                }
                draw_rect(x, y, w, h, true)
                pen_for_tabs = draw_text(font_bold, pen_for_tabs, tab_name)
                _debug.tabs[index] = {f32(x), f32(y), f32(w), f32(h)}
            }
        }

        pen := Vector2{16, (font_bold.line_height * 2) + 10}
        set_custom_color(FOREGROUND, font_regular.texture)

        switch _debug.current_tab {
        case .Render:
            pen = draw_text(font_regular, pen, fmt.tprintf("Max FPS: {}\n", _debug.fps_max))
            pen = draw_text(font_regular, pen, fmt.tprintf("Min FPS: {}\n", _debug.fps_min))
            pen = draw_text(font_regular, pen, fmt.tprintf("Average FPS: {}\n", _debug.fps_average))
            pen = draw_text(font_regular, pen, fmt.tprintf("Current FPS: {}\n", current_fps))
            frame_count_text := fmt.tprintf(
                "Frames:\nTotal {} / No errors {}", frame_count, frame_count_no_errors,
            )
            pen = draw_text(font_regular, pen, frame_count_text)
        case .Memory:

        }

        set_target()

        _debug.rect.h = DEBUG_WINDOW_SIZE
        if _debug.minimized {
            _debug.rect.h = f32(font_bold.line_height + TITLE_PADDING)
        }

        src_rect := Rect{0, 0, _debug.rect.w, _debug.rect.h}
        draw_texture(_debug.texture, &src_rect, &_debug.rect)
    }

    DEBUG_toggle_overlay :: proc () {
        log.debug("toggling debug overlay")
        _debug.show_debug_overlay = !_debug.show_debug_overlay
    }
} else {
    DEBUG_init :: proc() {}
    DEBUG_destroy :: proc() {}
    DEBUG_handle_input :: proc(event: Event) -> bool { return false }
    DEBUG_toggle_overlay :: proc() {}
}

debug_draw :: proc() {
    if !debug.show_debug_info do return
    set_target(debug.texture)
    set_color(.debug_background)
    prepare_for_drawing()
    pane := active_pane
    lines := get_lines_array(pane)
    font_regular := fonts_map[.UI_Small]
    font_bold := fonts_map[.UI_Bold]
    pen := Vector2{10, 0}
    piece_index: int

    set_colors(.debug_foreground, {font_regular.texture, font_bold.texture})

    pen = draw_text(font_bold, pen, "-- General information --\n")

    pen = draw_text(font_bold, pen, "Current Buffer\n")
    buffer_info_str := fmt.tprintf(
        "Name: {}\nLength: {}\nPieces: {}\nLines: {}\n",
        pane.buffer.name, len(pane.contents), len(pane.buffer.pieces),
        len(pane.buffer.line_starts),
    )
    pen = draw_text(font_regular, pen, buffer_info_str)

    pen = draw_text(font_bold, pen, "Current Pane\n")
    pane_info_str := fmt.tprintf(
        "Visible: Cols {} Rows {}\nOffset: X {} Y {}\n\n",
        get_pane_visible_columns(pane), pane.visible_rows,
        pane.x_offset, pane.y_offset,
    )
    pen = draw_text(font_regular, pen, pane_info_str)

    for cursor, cursor_index in pane.cursors {
        pen = draw_text(font_bold, pen, fmt.tprintf("-- Cursor {} --\n", cursor_index + 1))
        current_byte := 0 if cursor.pos >= len(pane.contents) else pane.contents[cursor.pos]

        coords := cursor_offset_to_coords(pane, lines, cursor.pos)
        cursor_pos_str := fmt.tprintf(
            "Offset: {}\nByte: {}\nCoords:  Col {} Row {}\n\n",
            cursor.pos, current_byte, coords.column, coords.row,
        )

        pen = draw_text(font_regular, pen, cursor_pos_str)

        if cursor.pos < len(pane.buffer.tokens) {
            pen = draw_text(font_regular, pen, fmt.tprintf("Token: {}\n\n", pane.buffer.tokens[cursor.pos]))
        }

        piece_index, _ = locate_piece(pane.buffer, cursor.pos)
    }

    pen = draw_text(font_bold, pen, "--Piece Information--\n")
    piece := pane.buffer.pieces[piece_index]
    piece_info_str := fmt.tprintf(
        "Index: {}   Source: {}\nStart: {}   Length: {}\n\n",
        piece_index, piece.source, piece.start, piece.length,
    )
    pen = draw_text(font_regular, pen, piece_info_str)

    frametime := time.duration_milliseconds(frame_delta_time)
    rest_of_info_str := fmt.tprintf(
        "FPS:       {}\nFrametime: %.3fms\nMemory:    {}kb",
        int(1000 / frametime),
        frametime,
        tracking_allocator.current_memory_allocated / 1024,
    )
    pen = draw_text(font_regular, pen, rest_of_info_str)

    set_target()
    debug.rect.x = f32(window_width) - debug.rect.w
    draw_texture(debug.texture, nil, &debug.rect)
}

profiling_init :: proc() {
    log.debug("Initializing profiling")
	debug.spall_ctx = spall.context_create("profile.spall")
	buf := make([]u8, spall.BUFFER_DEFAULT_SIZE)
	debug.spall_buf = spall.buffer_create(buf)
    debug.profiling = true
}

profiling_destroy :: proc() {
    log.debug("Destroying profiling")
    buf := debug.spall_buf.data
    spall.buffer_destroy(&debug.spall_ctx, &debug.spall_buf)
    delete(buf)
    spall.context_destroy(&debug.spall_ctx)
    debug.profiling = false
}

profiling_start :: proc(name: string, loc := #caller_location) {
    if !debug.profiling do return
    spall._buffer_begin(&debug.spall_ctx, &debug.spall_buf, name, "", loc)
}

profiling_end :: proc() {
    if !debug.profiling do return
    spall._buffer_end(&debug.spall_ctx, &debug.spall_buf)
}
