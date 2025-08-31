#+private file
package main

import     "core:fmt"
import     "core:log"
import     "core:reflect"
import     "core:slice"
import     "core:time"

_ :: fmt
_ :: log
_ :: reflect
_ :: slice
_ :: time

when BRAGI_DEBUG {
    DEBUG_WINDOW_SIZE          :: MINIMUM_WINDOW_SIZE
    TRANSPARENCY_BAR_WIDTH     :: 50
    TRANSPARENCY_BAR_HEIGHT    :: 4
    TRANSPARENCY_SLIDER_WIDTH  :: 10
    TRANSPARENCY_SLIDER_HEIGHT :: 6
    MAX_SNAPSHOT_LEN           :: 120
    TITLE_PADDING              :: 6
    CHART_MAX_HEIGHT           :: 60

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

    _transparency_enabled: bool

    _snapshot_index:             int
    _current_frame:              u64
    _frame_count_with_no_errors: u64

    Debug_Tab :: enum u8 {
        Frame_Info,
        Memory,
        Logs,
    }

    @(private="file")
    _debug: struct {
        show_debug_overlay: bool,

        grabbed:        bool,
        grab_point:     [2]f32,
        slider_grabbed: bool,
        minimized:      bool,

        tabs:          [len(Debug_Tab)]Rect,
        current_tab:   Debug_Tab,

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
            case Event_Mouse: {
                if !_debug.show_debug_overlay do return false

                is_in_tab :: proc() -> (int, bool) {
                    mx, my := platform_get_mouse_position()

                    for tab, index in _debug.tabs {
                        x1, x2 := tab.x, tab.x + tab.w
                        y1, y2 := tab.y, tab.y + tab.h
                        if mx >= x1 && mx <= x2 && my >= y1 && my <= y2 {
                            return index, true
                        }
                    }

                    return -1, false
                }

                is_in_title_bar :: proc() -> bool {
                    mx, my := platform_get_mouse_position()
                    r := _debug.rect
                    x1, x2 := r.x, r.x + r.w - TRANSPARENCY_BAR_WIDTH - 20
                    y1, y2 := r.y, r.y + r.h
                    return mx >= x1 && mx <= x2 && my >= y1 && my <= y2
                }

                is_in_transparency_bar :: proc() -> bool {
                    mx, my := platform_get_mouse_position()
                    r := _debug.rect
                    x1, x2 := r.x + r.w - TRANSPARENCY_BAR_WIDTH - 10, r.x + r.w
                    y1, y2 := r.y, r.y + r.h
                    return mx >= x1 && mx <= x2 && my >= y1 && my <= y2
                }

                if _debug.grabbed && !v.down && v.button == .Left {
                    _debug.grabbed = false
                    return true
                }

                if index, ok := is_in_tab(); ok {
                    if v.down && v.button == .Left {
                        _debug.current_tab = Debug_Tab(index)
                        return true
                    }
                }

                if is_in_title_bar() && v.down {
                    if v.button == .Left {
                        if v.clicks > 1 {
                            _debug.minimized = !_debug.minimized
                            return true
                        } else {
                            mx, my := platform_get_mouse_position()
                            _debug.grabbed = true
                            _debug.grab_point.x = mx - _debug.rect.x
                            _debug.grab_point.y = my - _debug.rect.y
                            return true
                        }
                    }
                }

                if is_in_transparency_bar() && v.down {
                    _transparency_enabled = !_transparency_enabled
                    set_transparency(_debug.texture, _transparency_enabled ? 0.5 : 1.0)
                    return true
                }
            }
            case Event_Keyboard:
            if v.key_code == .K_F9 {
                _debug.show_debug_overlay = !_debug.show_debug_overlay
                return true
            }
        }

        return false
    }

    @(private)
    DEBUG_update_draw :: proc() {
        if !bragi_first_frame do return

        if _debug.grabbed {
            mx, my := platform_get_mouse_position()
            _debug.rect.x = mx - _debug.grab_point.x
            _debug.rect.y = my - _debug.grab_point.y
        }

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
        total := slice.reduce(_debug.fps_values[:], f32(0), proc(a: f32, v: f32) -> f32 {
            return a + v
        })
        _debug.fps_avg = total / f32(len(_debug.fps_values))
        _debug.fps_chart_top = max(_debug.fps_max + 5, _debug.fps_chart_top)

        if !_debug.show_debug_overlay do return

        DEBUG_draw_window()
    }

    DEBUG_draw_window :: proc() {
        set_target(_debug.texture)
        set_custom_color(BACKGROUND_LIGHT)
        prepare_for_drawing()

        {
            // heading
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

            set_custom_color(BUTTON_INACTIVE_BG)
            draw_rect(
                w - TRANSPARENCY_BAR_WIDTH - 10, _title_height/2 - TRANSPARENCY_BAR_HEIGHT/2,
                TRANSPARENCY_BAR_WIDTH, TRANSPARENCY_BAR_HEIGHT,
            )

            slider_left := w - 10 - TRANSPARENCY_BAR_WIDTH
            slider_right := w - 10 - TRANSPARENCY_SLIDER_WIDTH
            set_custom_color(_transparency_enabled ? GREEN : RED)
            draw_rect(
                _transparency_enabled ? slider_right : slider_left,
                TRANSPARENCY_SLIDER_HEIGHT,
                TRANSPARENCY_SLIDER_WIDTH,
                _title_height - TRANSPARENCY_SLIDER_HEIGHT * 2,
            )
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

                mx, my := platform_get_mouse_position()
                x1, y1 := _debug.rect.x + f32(x), _debug.rect.y + f32(y)
                x2, y2 := x1 + f32(w), y1 + f32(h)

                if mx >= x1 && mx <= x2 && my >= y1 && my <= y2 {
                    set_custom_color(BUTTON_ACTIVE_FG, _font_bold.texture)
                }

                draw_rect(x, y, w, h, true)
                pen_for_tabs = draw_text(_font_bold, pen_for_tabs, tab_name)
                _debug.tabs[index] = {
                    _debug.rect.x + f32(x), _debug.rect.y + f32(y), f32(w), f32(h),
                }
            }
        }

        main_pen := Vector2{16, (_title_height * 2)}
        set_custom_color(FOREGROUND, _font_regular.texture)

        set_custom_color(FOREGROUND, _font_bold.texture)
        current_frame_str := fmt.tprintf("Frame #{}\n", _current_frame)
        main_pen = draw_text(_font_bold, main_pen, current_frame_str)
        main_pen.y += 5

        switch _debug.current_tab {
        case .Frame_Info:
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
        src_rect := Rect{0, 0, _debug.rect.w, _debug.rect.h}
        draw_texture(_debug.texture, &src_rect, &_debug.rect)
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
