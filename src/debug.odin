#+private file
package main

import     "core:fmt"
import     "core:log"
import     "core:reflect"
import     "core:slice"
import     "core:time"

import sdl "vendor:sdl3"

_ :: fmt
_ :: log
_ :: reflect
_ :: slice
_ :: time
_ :: sdl

when BRAGI_DEBUG {
    DEBUG_WINDOW_SIZE  :: MINIMUM_WINDOW_SIZE
    MAX_SNAPSHOT_LEN   :: 120
    TITLE_PADDING      :: 6
    CHART_MAX_HEIGHT   :: 60

    // colors
    BACKGROUND_DARK    :: 0x01080e
    BACKGROUND_LIGHT   :: 0x011627
    BORDER             :: 0x5f7e97
    FOREGROUND         :: 0xd6deeb
    BUTTON_INACTIVE_BG :: 0x0b2942
    BUTTON_INACTIVE_FG :: 0x676e95
    BUTTON_ACTIVE_BG   :: 0x4b6479
    BUTTON_ACTIVE_FG   :: 0xffeb95

    BLUE   :: 0x105390
    GREEN  :: 0x1b958d
    ORANGE :: 0xe26159
    RED    :: 0xe21c61
    YELLOW :: 0xfea85f

    _font_regular: ^Font
    _font_small:   ^Font
    _font_bold:    ^Font
    _font_icons:   ^Font
    _line_height:  i32
    _title_height: i32

    _transparency: f32 = 1.0

    _snapshot_index:             int
    _current_frame:              u64
    _frame_count_with_no_errors: u64

    Debug_Tab :: enum u8 {
        Render,
        Memory,
        Logs,
    }

    @(private="file")
    _debug: struct {
        show_debug_overlay: bool,

        minimized:          bool,
        mouse_dragging:     bool,

        tabs:               [len(Debug_Tab)]Rect,
        current_tab:        Debug_Tab,

        // render tab
        fps_chart_top: f32,
        fps_curr:      f32,
        fps_max:       f32,
        fps_min:       f32,
        fps_avg:       f32,
        fps_values:    [MAX_SNAPSHOT_LEN]f32,

        rect:               Rect,
        texture:            ^Texture,
    }

    @(private)
    DEBUG_init :: proc() {
        _debug.rect = {10, 10, DEBUG_WINDOW_SIZE, DEBUG_WINDOW_SIZE }
        _debug.texture = texture_create(.TARGET, DEBUG_WINDOW_SIZE, DEBUG_WINDOW_SIZE)

        _font_regular = fonts_map[.UI_Regular]
        _font_small   = fonts_map[.UI_Small]
        _font_bold    = fonts_map[.UI_Bold]
        _font_icons   = fonts_map[.Icons]

        _line_height  = _font_bold.line_height
        _title_height = _line_height + TITLE_PADDING
    }

    @(private)
    DEBUG_destroy :: proc() {
        texture_destroy(_debug.texture)
    }

    @(private)
    DEBUG_handle_input :: proc(event: Event) -> bool {
        #partial switch v in event.variant {
            case Event_Keyboard:
            if v.key_code == .K_F9 {
                _debug.show_debug_overlay = !_debug.show_debug_overlay
                return true
            }

            if _debug.show_debug_overlay {
                if v.key_code == .K_PLUS {
                    _transparency = min(_transparency + 0.1, 1.0)
                    sdl.SetTextureAlphaModFloat(_debug.texture, _transparency)
                    return true
                }

                if v.key_code == .K_MINUS {
                    _transparency = max(_transparency - 0.1, 0.5)
                    sdl.SetTextureAlphaModFloat(_debug.texture, _transparency)
                    return true
                }


                if v.key_code == .K_F8 {
                    _debug.minimized = !_debug.minimized
                    return true
                }
                if v.key_code == .K_TAB {
                    index := int(_debug.current_tab) + 1
                    if index >= len(Debug_Tab) {
                        index = 0
                    }
                    _debug.current_tab = Debug_Tab(index)
                    return true
                }
            }
        }

        return false
    }

    @(private)
    DEBUG_update_draw :: proc() {
        if !bragi_first_frame do return

        _current_frame += 1
        _frame_count_with_no_errors += 1

        _snapshot_index += 1
        if _snapshot_index >= MAX_SNAPSHOT_LEN {
            _snapshot_index = 0
        }

        frametime := time.duration_milliseconds(frame_delta_time)
        _debug.fps_curr = f32(1000/frametime)
        _debug.fps_values[_snapshot_index] = _debug.fps_curr
        _debug.fps_min, _debug.fps_max, _ = slice.min_max(_debug.fps_values[:])
        total_fps_values := slice.reduce(_debug.fps_values[:], f32(0), proc(acc: f32, value: f32) -> f32 {
            return acc + value
        })
        _debug.fps_avg = total_fps_values / f32(len(_debug.fps_values))
        _debug.fps_chart_top = max(_debug.fps_max + 5, _debug.fps_chart_top)

        if !_debug.show_debug_overlay do return

        DEBUG_draw_window()
    }

    DEBUG_draw_window :: proc() {
        set_target(_debug.texture)
        set_custom_color(BACKGROUND_LIGHT)
        prepare_for_drawing()

        {
            // basic layout
            w, h := i32(_debug.rect.w)-1, i32(_debug.rect.h)-1
            h2 := _title_height // below the title
            set_custom_color(BACKGROUND_DARK)
            draw_rect(0, 0, w, h2)
            set_custom_color(BORDER)
            draw_line(0, 0, 0, h)
            draw_line(0, 0, w, 0)
            draw_line(w, 0, w, h)
            draw_line(0, h, w, h)
            draw_line(0, h2, w, h2)
            set_custom_color(FOREGROUND, _font_bold.texture)
            set_custom_color(FOREGROUND, _font_icons.texture)
            pen_for_title := Vector2{16, 3}
            title_icon : rune = _debug.minimized ? 0xf0d8 : 0xf0d7
            pen_for_title = draw_text(_font_icons, pen_for_title, icon_to_string(title_icon))
            draw_text(_font_bold, pen_for_title, "Bragi Debugging Tools")
        }

        {
            // tabs
            pen_for_tabs := Vector2{1, _font_bold.line_height + 7}

            for tab, index in Debug_Tab {
                tab_name := fmt.tprintf("   {}   ", reflect.enum_string(tab))
                x := pen_for_tabs.x
                y := pen_for_tabs.y
                w := prepare_text(_font_bold, tab_name)
                h := _font_bold.line_height
                if _debug.current_tab == tab {
                    set_custom_color(BUTTON_ACTIVE_BG)
                    set_custom_color(BUTTON_ACTIVE_FG, _font_bold.texture)
                } else {
                    set_custom_color(BUTTON_INACTIVE_BG)
                    set_custom_color(BUTTON_INACTIVE_FG, _font_bold.texture)
                }
                draw_rect(x, y, w, h, true)
                pen_for_tabs = draw_text(_font_bold, pen_for_tabs, tab_name)
                _debug.tabs[index] = {f32(x), f32(y), f32(w), f32(h)}
            }
        }

        main_pen := Vector2{16, (_title_height * 2)}
        set_custom_color(FOREGROUND, _font_regular.texture)

        set_custom_color(FOREGROUND, _font_bold.texture)
        current_frame_str := fmt.tprintf("Frame #{}\n", _current_frame)
        main_pen = draw_text(_font_bold, main_pen, current_frame_str)
        main_pen.y += 5

        switch _debug.current_tab {
        case .Render:
            main_pen.y += CHART_MAX_HEIGHT + 20
            bar_width := f32(DEBUG_WINDOW_SIZE - 32)/f32(MAX_SNAPSHOT_LEN)
            chart_left := f32(main_pen.x)
            scale := f32(1.0/_debug.fps_chart_top)
            avg_fps_line_height := (scale * f32(_debug.fps_avg)) * CHART_MAX_HEIGHT
            max_fps_line_height := (scale * f32(_debug.fps_max)) * CHART_MAX_HEIGHT
            min_fps_line_height := (scale * f32(_debug.fps_min)) * CHART_MAX_HEIGHT

            for value, index in _debug.fps_values {
                if value == 0 do continue
                proportion := scale * value
                height := proportion * CHART_MAX_HEIGHT

                if height >= avg_fps_line_height - 1 {
                    set_custom_color(GREEN)
                } else if height < avg_fps_line_height*0.75 {
                    set_custom_color(RED)
                } else {
                    set_custom_color(YELLOW)
                }

                draw_rect_f32(chart_left + f32(index) * bar_width, f32(main_pen.y), bar_width, -height)
            }

            {
                avg_line_pen := Vector2{16, main_pen.y - i32(avg_fps_line_height)}
                max_line_pen := Vector2{16, main_pen.y - i32(max_fps_line_height)}
                min_line_pen := Vector2{16, main_pen.y - i32(min_fps_line_height)}
                fps_line_width := DEBUG_WINDOW_SIZE - avg_line_pen.x * 2
                fps_line_height: i32 = 2

                set_custom_color(BLUE)
                set_custom_color(BLUE, _font_small.texture)
                max_fps_str := fmt.tprintf("Max FPS: %.2f", _debug.fps_max)
                max_text_pen := max_line_pen
                max_text_pen.x = fps_line_width - _font_small.em_width * i32(len(max_fps_str))
                max_text_pen.y -= _font_small.line_height
                draw_text(_font_small, max_text_pen, max_fps_str)
                draw_rect(max_line_pen.x, max_line_pen.y, fps_line_width, fps_line_height)

                set_custom_color(ORANGE)
                set_custom_color(ORANGE, _font_small.texture)
                min_fps_str := fmt.tprintf("Min FPS: %.2f    ", _debug.fps_min)
                min_text_pen := min_line_pen
                min_text_pen.x = max_text_pen.x - _font_small.em_width * i32(len(min_fps_str))
                min_text_pen.y -= _font_small.line_height
                draw_text(_font_small, min_text_pen, min_fps_str)
                draw_rect(min_line_pen.x, min_line_pen.y, fps_line_width, fps_line_height)

                set_custom_color(FOREGROUND)
                set_custom_color(FOREGROUND, _font_regular.texture)
                avg_text_pen := avg_line_pen
                avg_text_pen.y -= _font_regular.line_height
                avg_fps_str := fmt.tprintf("Average FPS: %.2f", _debug.fps_avg)
                draw_text(_font_regular, avg_text_pen, avg_fps_str)
                draw_rect(avg_line_pen.x, avg_line_pen.y, fps_line_width, fps_line_height)
            }
        case .Memory:

        case .Logs:

        }

        set_target()
        _debug.rect.h = DEBUG_WINDOW_SIZE
        if _debug.minimized {
            _debug.rect.h = f32(_title_height)
        }
        stats_src_rect := Rect{0, 0, _debug.rect.w, _debug.rect.h}
        draw_texture(_debug.texture, &stats_src_rect, &_debug.rect)
    }
} else {
    @(private)
    DEBUG_init :: proc() {}
    @(private)
    DEBUG_destroy :: proc() {}
    @(private)
    DEBUG_handle_input :: proc(event: Event) -> bool { return false }
    @(private)
    DEBUG_update_draw :: proc() {}
}

@(private)
profiling_start :: proc(name: string, loc := #caller_location) {
}

@(private)
profiling_end :: proc() {
}
