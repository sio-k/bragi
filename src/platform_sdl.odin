package main

// TODO(nawe) hopefully I will get rid of SDL at some point, but since
// I use multiple systems, I need my editor to support all three major
// systems right of the bat and I don't have any idea on how Metal
// works. So in the meantime, I leverage all the power of SDL, but I
// want to make this from scratch instead.

import rt "base:runtime"

import     "core:fmt"
import     "core:log"
import     "core:os/os2"
import     "core:path/filepath"
import     "core:reflect"
import     "core:strings"

import sdl "vendor:sdl3"
import img "vendor:sdl3/image"

_ :: filepath

MINIMUM_WINDOW_SIZE :: 800
DEFAULT_WINDOW_SIZE :: 1200

Platform_Window :: struct {
    window:          ^sdl.Window,   // 0B offset
    window_width:    i32,           // 8B offset
    window_height:   i32,           // 12B offset
    window_id:       sdl.WindowID,  // 16B offset
    dpi_scale:       f32,           // 20B offset
    renderer:        ^sdl.Renderer, // 24B offset
}                                   // size: 32B

window_icon: ^sdl.Surface

platform_window_init :: proc() -> (win: Platform_Window) {
    WINDOW_FLAGS  :: sdl.WindowFlags{.RESIZABLE, .HIGH_PIXEL_DENSITY, .OPENGL}
    // TODO: read window width and height from config
    window_width: i32 = DEFAULT_WINDOW_SIZE
    window_height: i32 = DEFAULT_WINDOW_SIZE
    win.window = sdl.CreateWindow(NAME, window_width, window_height, WINDOW_FLAGS)
    if win.window == nil {
        log.fatal("failed to open window", sdl.GetError())
    }
    log.debugf("window created with driver '{}'", sdl.GetCurrentVideoDriver())

    win.renderer = sdl.CreateRenderer(win.window, "opengl")
    if win.renderer == nil {
        log.fatal("failed to setup renderer", sdl.GetError())
    }
    log.debugf("renderer created with driver '{}'", sdl.GetRenderDriver(0))
    sdl.SetRenderVSync(win.renderer, sdl.RENDERER_VSYNC_ADAPTIVE)

    if !sdl.StartTextInput(win.window) {
        log.fatal("cannot capture user input", sdl.GetError())
    }

    win.window_id = sdl.GetWindowID(win.window)

    sdl.SetWindowMinimumSize(win.window, MINIMUM_WINDOW_SIZE, MINIMUM_WINDOW_SIZE)
    sdl.RaiseWindow(win.window)

    if settings.maximize_window_on_start {
        sdl.MaximizeWindow(win.window)
    }

    base_width, base_height: i32
    sdl.GetWindowSize(win.window, &base_width, &base_height)
    sdl.GetWindowSizeInPixels(win.window, &win.window_width, &win.window_height)

    if base_width == win.window_width && base_height == win.window_height {
        win.dpi_scale = 1.0
    } else {
        win.dpi_scale = min(
            f32(win.window_width) / f32(base_width),
            f32(win.window_height) / f32(base_height),
        )
    }

    window_icon_success := sdl.SetWindowIcon(win.window, window_icon)
    if !window_icon_success {
        log.error("failed to load window icon", sdl.GetError())
    }

    return
}

platform_window_destroy :: proc(win: Platform_Window) {
    sdl.DestroyRenderer(win.renderer)
    sdl.DestroyWindow(win.window)
}

platform_window_set_title :: proc(win: ^Platform_Window, title: string) {
    rt.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    ctitle := strings.clone_to_cstring(
        title, allocator = context.temp_allocator,
    )
    sdl.SetWindowTitle(win.window, ctitle)
}

platform_init :: proc() {
    profiling_start("init SDL")

    METADATA :: []struct{key, value: cstring}{
        {key = sdl.PROP_APP_METADATA_NAME_STRING,       value = NAME},
        {key = sdl.PROP_APP_METADATA_VERSION_STRING,    value = VERSION},
        {key = sdl.PROP_APP_METADATA_IDENTIFIER_STRING, value = ID},
        {key = sdl.PROP_APP_METADATA_CREATOR_STRING,    value = AUTHOR},
        {key = sdl.PROP_APP_METADATA_COPYRIGHT_STRING,  value = AUTHOR},
        {key = sdl.PROP_APP_METADATA_URL_STRING,        value = URL},
    }

    for item in METADATA {
        ok := sdl.SetAppMetadataProperty(item.key, item.value)
        if !ok {
            log.errorf("failed to set metadata for '{}'", item.key)
        }
    }

    when BRAGI_DEBUG {
        sdl.SetLogPriorities(.ERROR)
        sdl.SetLogOutputFunction(_platform_sdl_debug_log, nil)
    }

    if !os2.exists(platform_get_config_dir()) {
        error := os2.make_directory_all(platform_get_config_dir())

        if error != nil {
            log.fatalf("failed to create config directory")
        }
    }

    log.debug("initializing SDL")

    sdl.SetHint(sdl.HINT_VIDEO_ALLOW_SCREENSAVER, "1")
    sdl.SetHint(sdl.HINT_MAC_OPTION_AS_ALT, "both")
    sdl.SetHint(sdl.HINT_MOUSE_DEFAULT_SYSTEM_CURSOR, "1")

    if !sdl.Init({.VIDEO}) {
        log.fatal("failed to init SDL", sdl.GetError())
    }

    icon_data := sdl.IOFromMem(raw_data(ICON), len(ICON))
    window_icon = img.LoadPNG_IO(icon_data)

    when ODIN_OS == .Windows {
        base_working_dir = filepath.volume_name(curr_working_dir)
    } else {
        base_working_dir = strings.clone("/")
    }

    if !os2.is_directory(base_working_dir) {
        log.errorf("base_working_dir '{}' is not a valid dir", base_working_dir)
    }
    profiling_end()
}

platform_destroy :: proc() {
    log.debug("deinitializing SDL")
    sdl.Quit()
}

platform_sleep :: proc() {
    when BRAGI_DEBUG {
        if DEBUG_is_slow_frames_on() do sdl.Delay(32)
    }
}

@(private="file")
_platform_sdl_debug_log :: proc "c" (
    userdata: rawptr, category: sdl.LogCategory,
    priority: sdl.LogPriority, message: cstring,
) {
    context = bragi_context
    log.errorf("SDL {} [{}]: {}", category, priority, message)
}

platform_update_events :: proc() {
    profiling_start("capture platform events")
    input_update_and_prepare()

    event: sdl.Event
    for sdl.PollEvent(&event) {
        #partial switch event.type {
        case .QUIT:
            // TODO (sio): just get the first window, it's going to be the correct one at this point
            input_register(windows[0], Event_Quit{})

        case .WINDOW_CLOSE_REQUESTED:
            input_register(
                get_window_by_id(event.window.windowID),
                Event_Window { closed = true },
            )

        case .DROP_FILE:
            filepath := string(event.drop.data)
            data, error := os2.read_entire_file_from_path(filepath, context.allocator)
            if error != nil {
                log.errorf("failed to open file '{}' with error {}", filepath, error)
                continue
            }

            input_register(
                get_window_by_id(event.drop.windowID),
                Event_Drop_File{
                    filepath = strings.clone(filepath),
                    data = data,
                },
            )
        case .WINDOW_FOCUS_GAINED, .WINDOW_FOCUS_LOST, .WINDOW_MOVED, .WINDOW_RESIZED, .WINDOW_MAXIMIZED:
            // NOTE(nawe) Performance: it might be just better to
            // keep these resizes in a different list of events so
            // they can all be handled once the resizing is
            // done. The way to do it would be to register every
            // resize, once we get a list of not resizing on a
            // frame, we would process the last resizing.
            window := get_window_by_id(event.window.windowID)
            wevent := Event_Window{}
            base_width, base_height: i32
            sdl.GetWindowSize(window.platform.window, &base_width, &base_height)
            sdl.GetWindowSizeInPixels(window.platform.window, &wevent.window_width, &wevent.window_height)
            wevent.window_focused = event.type != .WINDOW_FOCUS_LOST

            if base_width == wevent.window_width && base_height == wevent.window_height {
                wevent.dpi_scale = 1.0
            } else {
                wevent.dpi_scale = min(
                    f32(wevent.window_width) / f32(base_width),
                    f32(wevent.window_height) / f32(base_height),
                )
            }

            input_register(window, wevent)
        case .MOUSE_WHEEL:
            window := get_window_by_id(event.wheel.windowID)
            window.mouse_state.scroll_x = event.wheel.x
            window.mouse_state.scroll_y = event.wheel.y * -1
            input_register(
                window,
                Event_Mouse{
                    scroll_x = event.wheel.x,
                    scroll_y = event.wheel.y * -1,
                },
            )
        case .KEY_DOWN:
            key := u32(sdl.GetKeyFromScancode(event.key.scancode, event.key.mod, false))
            key_without_shift := u32(sdl.GetKeyFromScancode(event.key.scancode, event.key.mod - sdl.KMOD_SHIFT, false))
            // this is an uppercase alpha character, make it lowercase for consistency
            if key >= 65 && key <= 90 do key += 32
            keycode := Key_Code(key)
            mods := event.key.mod
            is_modifier_key := key > 0x400000dd && key < 0x40000102

            // NOTE(nawe) testing if the shift modifier is
            // basically pushing a different key. If that's the
            // case, we remove the shift modifier from the bitset,
            // so when we are making keybindings, we allow for
            // "Ctrl-+" instead of having to write "Ctrl-Shift-+",
            // since most likely we already pressed shift to make
            // the '+' sign.
            if key_without_shift != key {
                mods = mods - sdl.KMOD_SHIFT
            }

            // changing the left tab to be Shift-Tab
            if keycode == .K_LEFT_TAB {
                keycode = .K_TAB
                mods += sdl.KMOD_SHIFT
            }

            if reflect.enum_value_has_name(keycode) && !is_modifier_key {
                kb_event := Event_Keyboard{
                    key_pressed = key,
                    key_code    = keycode,
                    repeat = event.key.repeat,
                }

                if .LCTRL  in mods  || .RCTRL  in mods  do kb_event.modifiers += {.Ctrl}
                if .LALT   in mods  || .RALT   in mods  do kb_event.modifiers += {.Alt}
                if .LGUI   in mods  || .RGUI   in mods  do kb_event.modifiers += {.Super}
                if .LSHIFT in mods  || .RSHIFT in mods  do kb_event.modifiers += {.Shift}

                input_register(get_window_by_id(event.key.windowID), kb_event)
            }
        case .TEXT_INPUT:
            input_register(
                get_window_by_id(event.text.windowID),
                Event_Keyboard{
                    is_text_input = true,
                    text = string(event.text.text),
                },
            )

        case .MOUSE_BUTTON_UP: fallthrough
        case .MOUSE_BUTTON_DOWN:
            if event.button.button >= (transmute(u8) Mouse_Button.Left + 1) && event.button.button <= (transmute(u8) Mouse_Button.Extra_2 + 1) {
                ev := Event_Mouse{
                    button = transmute(Mouse_Button) (event.button.button - 1),
                    clicks = event.button.clicks,
                    down = bool(event.button.down),
                }
                input_register(get_window_by_id(event.button.windowID), ev)
            }
        }
    }
    profiling_end()
}

platform_set_clipboard_text :: proc(text: string) {
    cstr := strings.clone_to_cstring(text, context.temp_allocator)
    success := sdl.SetClipboardText(cstr)
    if !success do log.fatalf("failed to copy text '{}'", text)
}

platform_get_clipboard_text :: proc() -> (result: string) {
    data := sdl.GetClipboardText()
    result = strings.clone(string(cstring(data)), context.temp_allocator)
    sdl.free(data)
    return
}

platform_key_name :: proc(key: u32) -> string {
    result := string(sdl.GetKeyName(sdl.Keycode(key)))

    // rename to a much better name of "Enter" instead of "Return"
    if result == "Return" do result = "Enter"

    return result
}

platform_resize_window :: #force_inline proc(window: ^Window, w, h: i32) {
    sdl.SetWindowSize(window.platform.window, w, h)
}

platform_get_config_dir :: proc() -> string {
    bragi_dir := "bragi"
    config_dir, error := os2.user_config_dir(context.temp_allocator)

    // handle error
    if error != nil {
        log.fatalf("could not find the config directory")
        config_dir = curr_working_dir
    }

    when BRAGI_DEBUG {
        bragi_dir = "bragi/debug"
    }

    return fmt.tprintf("{}/{}", config_dir, bragi_dir)
}

platform_get_mouse_position :: proc(window: ^Window) -> (f32, f32) {
    mx, my: f32
    _ = sdl.GetMouseState(&mx, &my)
    mx *= window.platform.dpi_scale
    my *= window.platform.dpi_scale
    return mx, my
}

platform_mouse_button_down :: proc(b: Mouse_Button) -> bool {
    state := sdl.GetMouseState(nil, nil)

    switch b {
    case .Left:    return .LEFT   in state
    case .Middle:  return .MIDDLE in state
    case .Right:   return .RIGHT  in state
    case .Extra_1: return .X1     in state
    case .Extra_2: return .X2     in state
    }

    return false
}

platform_toggle_cursor :: proc(show: bool) {
    if show {
        _ = sdl.ShowCursor()
    } else {
        _ = sdl.HideCursor()
    }
}
