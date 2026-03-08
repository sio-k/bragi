package main

import rt "base:runtime"

import "core:log"
import "core:mem"
import "core:slice"
import "core:time"

import sdl "vendor:sdl3"

// TODO: layout this so it fits in a single 4K page
// the idea is that I just map a page per window, and that includes a font cache, font atlas and glyph definitions etc. Should greatly simplify managing the memory of a window - after all, if it's all just one big page...
// to do allat, though, I should just stuff all the variables directly in here
// just so I can reliably figure out what size this struct is, because right now?
// difficult to say, really
// also, then I could replace the dynamic arrays with lists I guess?
// since dynamic arrays don't play great with arenas, and lists do
// though tbh I don't think fonts change at runtime, so realistically there's no reason to have these by dynamic arrays in the first place
// panes should probably be either a dynarray or a list
// if I use an allocator within this, I guess just use arena + freelist?
//
// TODO (sio): all font stuff should share a single arena per window
// TODO (sio): we should also store open panes in a single, limited-size list that we just take a slice out of
// TODO (sio): storage for stuff that happens in panes should probably be separate, need to figure out exactly what the lifetimes involved there are
MAX_OPEN_PANES :: 16
Window :: struct {
    platform:            Platform_Window,       // 0B offset (size 32B)
    window_in_focus:     bool,                  // 32B offset
    should_resize_panes: bool,                  // 33B offset
    initialized:         bool,                  // 34B offset
    fonts_initialized:   bool,                  // 35B offset
    // 4 bytes unused

    active_pane:         ^Pane,                 // 40B offset
    open_panes:          []^Pane,               // 48B offset (size 16B)
    global_widget:       Widget,                // 54B offset (size 248B)

    mouse_state:         Mouse_State,           // 322B offset (size 128B)

    frame_delta_time:    time.Duration,         // 440B offset (size 8B)
    previous_frame_time: time.Tick,             // 448B offset (size 8B)
    last_keystroke:      time.Tick,             // 456B offset (size 8B)

    fonts_cache:         [dynamic]Font,         // 464B offset (size 40B)
    fonts_map:           [Font_Face]^Font,      // 504B offset (size 6*8 == 48B)

    open_panes_backing:  [MAX_OPEN_PANES]^Pane, // 552B offset (size 16*8 == 128B)
    open_panes_backing_fill: int,               // 680B offset

    // fill map for this is open_panes
    panes_storage:       [MAX_OPEN_PANES]Pane,  // 688B offset (size 16*232 == 3712B)
}                                               // size: 4400B
#assert(size_of(Platform_Window) == 32)
#assert(size_of(Widget) == 248)
#assert(size_of(Mouse_State) == 128)
#assert(size_of(time.Duration) == 8)
#assert(size_of(time.Tick) == 8)
#assert(size_of([16]^Pane) == 128)
#assert(size_of(Pane) == 232)
#assert(size_of([16]Pane) == 3712)

#assert(size_of(Window) == 4400)

windows: [dynamic]^Window

windows_init :: proc() {
    windows = make([dynamic]^Window)

    // create initial window
    append(&windows, window_init())
}

windows_destroy :: proc() {
    for w in windows {
        window_destroy(w)
    }
    delete(windows)
}

window_init :: proc() -> (window: ^Window) {
    window = new(Window)
    assert(len(window.panes_storage) == len(window.open_panes_backing))

    window.platform = platform_window_init()
    window.window_in_focus = true
    font_cache_init(window)
    window.initialized = true
    return
}

window_destroy :: proc(window: ^Window) {
    widget_close(window)
    for pane in window.open_panes {
        pane_destroy(pane)
    }
    window.open_panes = nil
    if window.fonts_initialized {
        font_cache_destroy(window)
    }
    platform_window_destroy(window.platform)
    window.active_pane = nil
    window.initialized = false

    free(window)
}

is_last_window :: proc(window: ^Window) -> bool {
    for w in windows {
        if w == window && len(windows) == 1 {
            return true
        } else {
            return false
        }
    }
    log.errorf("tried to query if window at %v is last window, but that window is not in the list of open windows", window)
    return false
}

new_window :: proc() {
    append(&windows, window_init())
    neww := windows[len(windows) - 1]
    neww.active_pane = pane_create(neww)
}

close_window :: proc(window: ^Window) {
    idx := -1
    for w, widx in windows {
        if w == window {
            idx = widx
        }
    }
    if idx < 0 {
        log.errorf("trying to close nonexistent window at address %v", window)
        return
    }

    rt.ordered_remove(&windows, idx)

    window_destroy(window)
}

get_focused_window :: proc() -> ^Window {
    for w in windows {
        if w.window_in_focus {
            return w
        }
    }
    return nil
}

get_window_by_id :: proc(window_id: sdl.WindowID) -> ^Window {
    for w in windows {
        if window_id == w.platform.window_id {
            return w
        }
    }
    log.errorf(
        "tried to get window by ID (%v) that doesn't appear to exist",
        window_id,
    )
    return windows[0]
}

assert_pane_in_window :: proc(window: ^Window, pane: ^Pane, loc := #caller_location) {
    assert(pane >= &window.panes_storage[0], loc = loc)
    assert(pane <= &window.panes_storage[MAX_OPEN_PANES - 1], loc = loc)
}

pane_storage_idx :: proc(window: ^Window, pane: ^Pane) -> int {
    assert_pane_in_window(window, pane)
    res := (transmute(uint) pane) - (transmute(uint) &window.panes_storage)
    res /= size_of(Pane)
    return int(res)
}

can_add_pane :: proc(window: ^Window) -> bool {
    return len(window.open_panes) < MAX_OPEN_PANES
}

pane_add :: proc(window: ^Window) -> ^Pane {
    assert(len(window.open_panes) < len(window.open_panes_backing))
    assert(len(window.open_panes) == window.open_panes_backing_fill)

    get_unused_pane_in_storage :: proc(window: ^Window) -> ^Pane {
        if len(window.open_panes) == 0 {
            return &window.panes_storage[0]
        }

        rt.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

        found := make([]int, len(window.open_panes))
        for open_pane, i in window.open_panes {
            found[i] = pane_storage_idx(window, open_pane)
        }

        slice.sort(found)

        lowest_unused_idx := 0
        for idx in found {
            if idx == lowest_unused_idx {
                lowest_unused_idx += 1
            }
        }

        assert(lowest_unused_idx < MAX_OPEN_PANES)
        assert(lowest_unused_idx >= 0)

        return &window.panes_storage[lowest_unused_idx]
    }

    new_pane := get_unused_pane_in_storage(window)
    window.open_panes_backing[window.open_panes_backing_fill] = new_pane
    window.open_panes_backing_fill += 1
    window.open_panes = window.open_panes_backing[:window.open_panes_backing_fill]
    return new_pane
}

pane_rm :: proc(window: ^Window, pane: ^Pane) {
    assert_pane_in_window(window, pane)
    assert(pane.window == window) // this will be true if the pane is active and exists
    storage_idx := pane_storage_idx(window, pane)

    pane_idx := MAX_OPEN_PANES
    for p, idx in window.open_panes {
        if p == pane {
            pane_idx = idx
        }
    }
    assert(pane_idx < MAX_OPEN_PANES)
    assert(pane_idx >= 0)

    if pane_idx + 1 < len(window.open_panes) {
        copy(window.open_panes[pane_idx:], window.open_panes[pane_idx + 1:])
    }
    window.open_panes_backing_fill -= 1
    window.open_panes = window.open_panes_backing[:window.open_panes_backing_fill]
    // TODO (sio): do we have handling here for if this was the last pane in the window? What behavior do we want in that case, anyway?

    // zero out the rest of the memory again
    slice.zero(window.open_panes_backing[window.open_panes_backing_fill:])
    mem.zero_item(&window.panes_storage[storage_idx])
}

// TODO: how do I deal with windows needing repaint at different times due to vsync? I think I might want to have a vsync-wait until next available window needs repaint, and while drawing, repaint everything and just not swap until just prior to vsync?
// should be able to just select(2) on window-needs-repaint fds or somesuch, right?
