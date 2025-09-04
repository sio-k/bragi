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
    DEBUG_WINDOW_SIZE      :: 1080
    DEBUG_MAX_SNAPSHOT_LEN :: 120
    DEBUG_SECTION_PADDING  :: 16

    TITLE_PADDING              :: 6

    // colors
    DEBUG_COLOR_BACKGROUND_DARK    :: 0x01080e
    DEBUG_COLOR_BACKGROUND_LIGHT   :: 0x011627
    DEBUG_COLOR_BORDER             :: 0x5f7e97
    DEBUG_COLOR_FOREGROUND         :: 0xd6deeb
    DEBUG_COLOR_BUTTON_INACTIVE_BG :: 0x0b2942
    DEBUG_COLOR_BUTTON_INACTIVE_FG :: 0x676e95
    DEBUG_COLOR_BUTTON_ACTIVE_BG   :: 0x4b6479
    DEBUG_COLOR_BUTTON_ACTIVE_FG   :: 0xffeb95
    DEBUG_COLOR_BLUE               :: 0x105390
    DEBUG_COLOR_GREEN              :: 0x1b958d
    DEBUG_COLOR_ORANGE             :: 0xe26159
    DEBUG_COLOR_RED                :: 0xe21c61
    DEBUG_COLOR_YELLOW             :: 0xfea85f

    _font_regular: ^Font
    _font_small:   ^Font
    _font_bold:    ^Font
    _font_icons:   ^Font
    _line_height:  i32
    _title_height: i32
    _heading_section_height: i32

    Debug_Tab :: enum u8 {
        Profiler,
        Buffer,
        Memory,
        Logs,
    }

    Debug_Button_Name :: enum u8 {
        Undefined,
        Window_Transparency,
        Slow_Frames,
    }

    Debug_Toggle :: struct {
        on: bool,
        rect:      Rect,
    }

    Debug_On_Toggle_Callback :: #type proc(bool)

    // fat struct that has everything to work in the debugger
    debug: struct {
        // window info and helpers
        active:         bool,
        rect:           Rect,
        texture:        ^Texture,
        grabbed:        bool,
        grab_point:     [2]f32,
        minimized:      bool,
        tabs:           [len(Debug_Tab)]Rect,
        current_tab:    Debug_Tab,
        tab_pen:        Vector2,

        font_xs: ^Font,

        buttons: [Debug_Button_Name]struct {
            on:        bool,
            rect:      Rect,
            on_toggle: Debug_On_Toggle_Callback,
        },

        // application debugging
        reset_stats:    bool,
        frame_freezed:  bool,
        snapshot_index: int,
        current_frame:  u64,

        // profiler tab
        profiler_scroll: i32,
        fps_chart_top:   f32,
        fps_current:     f32,
        fps_max:         f32,
        fps_min:         f32,
        fps_avg:         f32,
        fps_values:      [DEBUG_MAX_SNAPSHOT_LEN]f32,
        ft_current:      f64,
        ft_highest:      f64,
        ft_lowest:       f64,

        // memory tab
    }

    @(private)
    DEBUG_init :: proc() {
        debug.rect = {10, 10, DEBUG_WINDOW_SIZE, DEBUG_WINDOW_SIZE }
        debug.texture = texture_create(.TARGET, DEBUG_WINDOW_SIZE, DEBUG_WINDOW_SIZE)

        _font_regular = fonts_map[.UI_Regular]
        _font_small   = fonts_map[.UI_Small]
        _font_bold    = fonts_map[.UI_Bold]
        _font_icons   = fonts_map[.Icons]

        _line_height  = _font_bold.line_height
        _title_height = _line_height + TITLE_PADDING
        _heading_section_height = _title_height * 3

        debug.ft_lowest = 999

        debug.font_xs = fonts_map[.UI_XSmall]

        debug.buttons[.Slow_Frames] = {
            on        = true,
            on_toggle = proc(value: bool) {
                debug.reset_stats = true
            },
        }
    }

    @(private)
    DEBUG_destroy :: proc() {
        texture_destroy(debug.texture)
    }
    @(private)
    DEBUG_is_slow_frames_on :: proc() -> bool {
        return debug.buttons[.Slow_Frames].on
    }

    @(private)
    DEBUG_handle_input :: proc(event: Event) -> bool {
        #partial switch v in event.variant {
            case Event_Mouse: {
                if !debug.active do return false

                is_in_tab :: proc() -> (int, bool) {
                    mx, my := platform_get_mouse_position()

                    for tab, index in debug.tabs {
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
                    r := debug.rect
                    button_rect := debug.buttons[.Window_Transparency].rect
                    x1, x2 := r.x, r.x + r.w - (r.w - button_rect.x)
                    y1, y2 := r.y, r.y + f32(_title_height)
                    return mx >= x1 && mx <= x2 && my >= y1 && my <= y2
                }

                is_in_button :: proc() -> (bool, Debug_Button_Name) {
                    mx, my := platform_get_mouse_position()
                    r := debug.rect

                    for button, name in debug.buttons {
                        x1, x2 := r.x + button.rect.x, r.x + button.rect.x + button.rect.w
                        y1, y2 := r.y + button.rect.y, r.y + button.rect.y + button.rect.h

                        if mx >= x1 && mx <= x2 && my >= y1 && my <= y2 {
                            return true, name
                        }
                    }

                    return false, .Undefined
                }

                if v.scroll_y != 0 {
                    SCROLL_OFFSET :: 20

                    switch debug.current_tab {
                    case .Profiler:
                        debug.profiler_scroll += i32(v.scroll_y * SCROLL_OFFSET)
                        debug.profiler_scroll = clamp(debug.profiler_scroll, 0, 500)
                    case .Buffer:
                    case .Memory:
                    case .Logs:
                    }

                    return true
                }

                if debug.grabbed && !v.down && v.button == .Left {
                    debug.grabbed = false
                    return true
                }

                if index, ok := is_in_tab(); ok {
                    if v.down && v.button == .Left {
                        debug.current_tab = Debug_Tab(index)
                        return true
                    }
                }

                if is_in_title_bar() && v.down {
                    if v.button == .Left {
                        if v.clicks > 1 {
                            debug.minimized = !debug.minimized
                            return true
                        } else {
                            mx, my := platform_get_mouse_position()
                            debug.grabbed = true
                            debug.grab_point.x = mx - debug.rect.x
                            debug.grab_point.y = my - debug.rect.y
                            return true
                        }
                    }
                }

                is_button, name := is_in_button()
                if is_button && v.down {
                    button := &debug.buttons[name]
                    button.on = !button.on
                    if button.on_toggle != nil do button.on_toggle(button.on)
                    return true
                }
            }
            case Event_Keyboard:
            if v.key_code == .K_F9 {
                debug.active = !debug.active
                return true
            }
        }

        return false
    }

    @(private)
    DEBUG_update :: proc() {
        if debug.reset_stats {
            debug.reset_stats = false
            DEBUG_reset_stats()
            return
        }

        // update happens at the end of the frame. This adds some
        // slowness when working on it (moving it, for example) but we
        // shouldn't care too much about it because the important part
        // are the statistics, not the UX.
        set_transparency(debug.texture, debug.buttons[.Window_Transparency].on ? 0.5 : 1.0)

        if debug.grabbed {
            mx, my := platform_get_mouse_position()
            debug.rect.x = mx - debug.grab_point.x
            debug.rect.y = my - debug.grab_point.y
        }

        debug.current_frame += 1

        debug.snapshot_index += 1
        if debug.snapshot_index >= DEBUG_MAX_SNAPSHOT_LEN {
            debug.snapshot_index = 0
        }

        debug.ft_current = time.duration_milliseconds(frame_delta_time)
        debug.ft_highest = max(debug.ft_current, debug.ft_highest)
        debug.ft_lowest  = min(debug.ft_current, debug.ft_lowest)
        debug.fps_current = f32(1000/debug.ft_current)
        debug.fps_values[debug.snapshot_index] = debug.fps_current
        debug.fps_min, debug.fps_max, _ = slice.min_max(debug.fps_values[:])
        total := slice.reduce(debug.fps_values[:], f32(0), proc(a: f32, v: f32) -> f32 {
            return a + v
        })
        debug.fps_avg = total / f32(len(debug.fps_values))
        debug.fps_chart_top = max(debug.fps_max + 5, debug.fps_chart_top)
    }

    @(private)
    DEBUG_draw :: proc() {
        if !debug.active do return

        set_target(debug.texture)
        set_custom_color(DEBUG_COLOR_BACKGROUND_LIGHT)
        prepare_for_drawing()

        DEBUG_draw_window_content()
        DEBUG_draw_heading_content()

        set_target()
        debug.rect.h = DEBUG_WINDOW_SIZE
        if debug.minimized {
            debug.rect.h = f32(_title_height)
        }
        src_rect := Rect{0, 0, debug.rect.w, debug.rect.h}
        draw_texture(debug.texture, &src_rect, &debug.rect)
    }

    DEBUG_draw_heading_content :: proc() {
        set_custom_color(DEBUG_COLOR_BACKGROUND_LIGHT)
        draw_rect(1, 1, i32(debug.rect.w) - 1, _heading_section_height-1)

        { // heading
            w, h := i32(debug.rect.w)-1, i32(debug.rect.h)-1
            h2 := _title_height // below the title
            set_custom_color(DEBUG_COLOR_BACKGROUND_DARK)
            draw_rect(0, 0, w, h2)
            set_custom_color(DEBUG_COLOR_BORDER)
            draw_line(0, 0, 0, h)
            draw_line(0, 0, w, 0)
            draw_line(w, 0, w, h)
            draw_line(0, h, w, h)
            draw_line(0, h2, w, h2)
            set_custom_color(DEBUG_COLOR_FOREGROUND, _font_bold.texture)
            set_custom_color(DEBUG_COLOR_FOREGROUND, _font_icons.texture)
            pen_for_title := Vector2{DEBUG_SECTION_PADDING, 3}
            title_icon : rune = debug.minimized ? 0xf0d8 : 0xf0d7
            pen_for_title = draw_text(_font_icons, pen_for_title, icon_to_string(title_icon))
            draw_text(_font_bold, pen_for_title, "Bragi Debugging Tools")

            pen_for_toggle := Vector2{i32(DEBUG_right_edge()), _title_height}
            DEBUG_draw_toggle_switch(pen_for_toggle, .Window_Transparency, "transparency")
        }

        { // tabs
            pen_for_tabs := Vector2{1, _font_bold.line_height + 7}

            for tab, index in Debug_Tab {
                tab_name := fmt.tprintf("   {}   ", reflect.enum_string(tab))
                x := pen_for_tabs.x
                y := pen_for_tabs.y
                w := prepare_text(_font_bold, tab_name)
                h := _font_bold.line_height
                if debug.current_tab == tab {
                    set_custom_color(DEBUG_COLOR_BUTTON_ACTIVE_BG)
                    set_custom_color(DEBUG_COLOR_BUTTON_ACTIVE_FG, _font_bold.texture)
                } else {
                    set_custom_color(DEBUG_COLOR_BUTTON_INACTIVE_BG)
                    set_custom_color(DEBUG_COLOR_BUTTON_INACTIVE_FG, _font_bold.texture)
                }

                mx, my := platform_get_mouse_position()
                x1, y1 := debug.rect.x + f32(x), debug.rect.y + f32(y)
                x2, y2 := x1 + f32(w), y1 + f32(h)

                if mx >= x1 && mx <= x2 && my >= y1 && my <= y2 {
                    set_custom_color(DEBUG_COLOR_BUTTON_ACTIVE_FG, _font_bold.texture)
                }

                draw_rect(x, y, w, h, true)
                pen_for_tabs = draw_text(_font_bold, pen_for_tabs, tab_name)
                debug.tabs[index] = {
                    debug.rect.x + f32(x), debug.rect.y + f32(y), f32(w), f32(h),
                }
            }
        }

        { // frame info
            pen_for_frame_info := Vector2{DEBUG_SECTION_PADDING, (_title_height * 2)}
            current_frame_str := fmt.tprintf("Frame #{}\n", debug.current_frame)
            set_custom_color(DEBUG_COLOR_FOREGROUND, _font_bold.texture)
            draw_text(_font_bold, pen_for_frame_info, current_frame_str)
            pen_for_frame_info.y += _font_bold.line_height

            pen_for_toggle := Vector2{i32(DEBUG_right_edge()), pen_for_frame_info.y}
            DEBUG_draw_toggle_switch(pen_for_toggle, .Slow_Frames, "slow frames")

            set_custom_color(DEBUG_COLOR_BORDER)
            draw_line(0, pen_for_frame_info.y, i32(debug.rect.w), pen_for_frame_info.y)
        }
    }

    DEBUG_draw_window_content :: proc() {
        debug.tab_pen = Vector2{DEBUG_SECTION_PADDING, _heading_section_height}

        switch debug.current_tab {
        case .Profiler:
            debug.tab_pen.y -= debug.profiler_scroll
            DEBUG_draw_profiler_tab()
        case .Buffer:
        case .Memory:
        case .Logs:

        }
    }

    DEBUG_draw_profiler_tab :: proc() {
        DEBUG_start_section()

        { // FPS bar graph
            GRAPH_MAX_HEIGHT :: 60

            // from bottom-up
            debug.tab_pen.y += GRAPH_MAX_HEIGHT
            bar_width := DEBUG_right_edge()/DEBUG_MAX_SNAPSHOT_LEN
            graph_left := f32(debug.tab_pen.x)
            scale := f32(1.0/debug.fps_chart_top)

            // line indicators
            avg_fps_line_height := (scale * f32(debug.fps_avg)) * GRAPH_MAX_HEIGHT
            max_fps_line_height := (scale * f32(debug.fps_max)) * GRAPH_MAX_HEIGHT
            min_fps_line_height := (scale * f32(debug.fps_min)) * GRAPH_MAX_HEIGHT

            for value, index in debug.fps_values {
                if value == 0 do continue
                proportion := scale * value
                height := proportion * GRAPH_MAX_HEIGHT

                if height >= avg_fps_line_height - 1 {
                    set_custom_color(DEBUG_COLOR_GREEN)
                } else if height < avg_fps_line_height*0.75 {
                    set_custom_color(DEBUG_COLOR_RED)
                } else {
                    set_custom_color(DEBUG_COLOR_YELLOW)
                }

                draw_rect_f32(
                    graph_left + f32(index) * bar_width, f32(debug.tab_pen.y),
                    bar_width, -height,
                )
            }

            SNAPSHOT_LINE_WIDTH :: 2
            FPS_LINE_HEIGHT     :: 2

            // snapshot indicator
            set_custom_color(DEBUG_COLOR_BORDER)
            draw_rect_f32(
                graph_left + f32(debug.snapshot_index + 1) * bar_width, f32(debug.tab_pen.y),
                SNAPSHOT_LINE_WIDTH, -GRAPH_MAX_HEIGHT,
            )

            avg_line_pen := Vector2{debug.tab_pen.x, debug.tab_pen.y - i32(avg_fps_line_height)}
            max_line_pen := Vector2{debug.tab_pen.x, debug.tab_pen.y - i32(max_fps_line_height)}
            min_line_pen := Vector2{debug.tab_pen.x, debug.tab_pen.y - i32(min_fps_line_height)}
            fps_line_width := i32(DEBUG_right_edge())

            set_custom_color(DEBUG_COLOR_BLUE)
            set_custom_color(DEBUG_COLOR_BLUE, _font_small.texture)
            max_fps_str := fmt.tprintf("Max FPS: %.2f", debug.fps_max)
            max_text_pen := max_line_pen
            max_text_pen.x = fps_line_width - _font_small.em_width * i32(len(max_fps_str))
            max_text_pen.y -= _font_small.line_height
            draw_text(_font_small, max_text_pen, max_fps_str)
            draw_rect(max_line_pen.x, max_line_pen.y, fps_line_width, FPS_LINE_HEIGHT)

            set_custom_color(DEBUG_COLOR_ORANGE)
            set_custom_color(DEBUG_COLOR_ORANGE, _font_small.texture)
            min_fps_str := fmt.tprintf("Min FPS: %.2f    ", debug.fps_min)
            min_text_pen := min_line_pen
            min_text_pen.x = max_text_pen.x - _font_small.em_width * i32(len(min_fps_str))
            min_text_pen.y -= _font_small.line_height
            draw_text(_font_small, min_text_pen, min_fps_str)
            draw_rect(min_line_pen.x, min_line_pen.y, fps_line_width, FPS_LINE_HEIGHT)

            set_custom_color(DEBUG_COLOR_FOREGROUND)
            set_custom_color(DEBUG_COLOR_FOREGROUND, _font_regular.texture)
            avg_text_pen := avg_line_pen
            avg_text_pen.y -= _font_regular.line_height
            avg_fps_str := fmt.tprintf("Average FPS: %.2f", debug.fps_avg)
            draw_text(_font_regular, avg_text_pen, avg_fps_str)
            draw_rect(avg_line_pen.x, avg_line_pen.y, fps_line_width, FPS_LINE_HEIGHT)
        }

        { // frametime
            DEBUG_start_section()

            LINE_CHART_HEIGHT :: 40

            debug.tab_pen = draw_text(_font_bold, debug.tab_pen, "Frametimes\n")
            debug.tab_pen.y += 10

            set_custom_color(DEBUG_COLOR_BACKGROUND_DARK, _font_regular.texture)

            set_custom_color(DEBUG_COLOR_BLUE)
            high_frametime_str := fmt.tprintf("%.2fms", debug.ft_highest)
            high_frametime_pen := debug.tab_pen
            high_frametime_pen.x = i32(DEBUG_right_edge()) - i32(len(high_frametime_str)) * _font_regular.em_width
            high_frametime_pen.y += 2
            draw_rect(
                debug.tab_pen.x, debug.tab_pen.y,
                DEBUG_WINDOW_SIZE - debug.tab_pen.x * 2, LINE_CHART_HEIGHT,
            )
            draw_text(_font_regular, high_frametime_pen, high_frametime_str)

            set_custom_color(DEBUG_COLOR_GREEN)
            curr_proportion := f32(max(debug.ft_current/debug.ft_highest, 0.25))
            curr_proportion = f32(min(curr_proportion, 0.75))
            curr_frametime_str := fmt.tprintf("%.2fms", debug.ft_current)
            curr_frametime_pen := debug.tab_pen
            curr_frametime_pen.x = i32(debug.rect.w * curr_proportion) - i32(len(curr_frametime_str)) * _font_regular.em_width
            curr_frametime_pen.y += 2
            draw_rect(
                debug.tab_pen.x, debug.tab_pen.y,
                i32(DEBUG_WINDOW_SIZE * curr_proportion), LINE_CHART_HEIGHT,
            )
            draw_text(_font_regular, curr_frametime_pen, curr_frametime_str)

            set_custom_color(DEBUG_COLOR_YELLOW)
            low_proportion := 0.15
            low_frametime_str := fmt.tprintf("%.2fms", debug.ft_lowest)
            low_frametime_pen := debug.tab_pen
            low_frametime_pen.x = i32(DEBUG_WINDOW_SIZE * low_proportion) - i32(len(low_frametime_str)) * _font_regular.em_width
            low_frametime_pen.y += 2
            draw_rect(
                debug.tab_pen.x, debug.tab_pen.y,
                i32(DEBUG_WINDOW_SIZE * low_proportion), LINE_CHART_HEIGHT,
            )
            draw_text(_font_regular, low_frametime_pen, low_frametime_str)
        }
    }

    /* |=====================|
       |  HELPER PROCEDURES  |
       |=====================| */
    // NOTE(nawe) pen for toggle button is taken from right-to-left
    // (or better, where is the toggle indicator when it is ON). We
    // let this procedure decide the size, and set the rect, relative
    // to the debugging window, so it can also be used in input
    // handling.
    DEBUG_draw_toggle_switch :: proc(pen: Vector2, name: Debug_Button_Name, label: string = "") {
        SWITCH_BG_WIDTH  :: 60
        SWITCH_BG_HEIGHT :: 20
        INDICATOR_WIDTH  :: 20
        INDICATOR_HEIGHT :: 10

        button := &debug.buttons[name]

        x := f32(pen.x) - SWITCH_BG_WIDTH
        // for centering
        y := f32(pen.y) - SWITCH_BG_HEIGHT * 1.5

        button.rect = {x, y, SWITCH_BG_WIDTH, SWITCH_BG_HEIGHT}

        // background
        set_custom_color(DEBUG_COLOR_BUTTON_INACTIVE_BG)
        draw_rect_f32(
            button.rect.x, button.rect.y,
            button.rect.w, button.rect.h,
        )

        // foreground
        set_custom_color(button.on ? DEBUG_COLOR_GREEN : DEBUG_COLOR_RED)
        left := button.rect.x + INDICATOR_WIDTH/2
        right := button.rect.x + button.rect.w - INDICATOR_WIDTH - INDICATOR_WIDTH/2
        draw_rect_f32(
            button.on ? right : left, button.rect.y + INDICATOR_HEIGHT/2,
            INDICATOR_WIDTH, INDICATOR_HEIGHT,
        )

        if len(label) > 0 {
            font_for_label := debug.font_xs
            pen_for_label := Vector2{i32(button.rect.x), i32(button.rect.y)}
            pen_for_label.x -= font_for_label.em_width * i32(len(label) + 1)
            set_custom_color(DEBUG_COLOR_BORDER, font_for_label.texture)
            pen_after_label := draw_text(font_for_label, pen_for_label, label)
            button.rect.x = f32(pen_for_label.x)
            button.rect.w += f32(pen_after_label.x - pen_for_label.x + font_for_label.em_width)
        }
    }

    DEBUG_start_section :: proc() {
        debug.tab_pen.y += DEBUG_SECTION_PADDING
    }

    DEBUG_right_edge :: proc() -> f32 {
        return debug.rect.w - DEBUG_SECTION_PADDING*2
    }

    DEBUG_reset_stats :: proc() {
        debug.fps_chart_top = 0
        debug.fps_current   = 0
        debug.fps_max       = 0
        debug.fps_min       = 0
        debug.fps_avg       = 0
        debug.ft_current    = 0
        debug.ft_highest    = 0
        debug.ft_lowest     = 999

        for index in 0..<DEBUG_MAX_SNAPSHOT_LEN {
            debug.fps_values[index] = 0
        }
    }
} else {
    @(private)
    DEBUG_init         :: proc() {}
    @(private)
    DEBUG_destroy      :: proc() {}
    @(private)
    DEBUG_handle_input :: proc(event: Event) -> bool { return false }
    @(private)
    DEBUG_update       :: proc() {}
    @(private)
    DEBUG_draw         :: proc() {}
}

@(private)
profiling_start :: proc(name: string, loc := #caller_location) {
}

@(private)
profiling_end :: proc() {
}
