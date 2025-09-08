package main

import     "core:log"
import     "core:math"
import     "core:strings"
import     "core:unicode/utf8"

import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

Font_Face :: enum {
    UI_Regular,
    UI_Italic,
    UI_Bold,
    UI_Small,
    UI_XSmall,
    Icons,
}

Font_Texture_Bucket :: distinct [dynamic]^Texture

Glyph_Data :: struct {
    x, y:         i32,
    w, h:         i32,
    xadvance:     i32,
    bucket_index: int,
}

Font :: struct {
    name:                    string,
    face:                    ^ttf.Font,
    glyphs_map:              map[rune]^Glyph_Data,
    textures:                Font_Texture_Bucket,
    last_packed_glyph:       ^Glyph_Data,

    base_height:             i32, // the height that was used when requesting the font
    em_width:                i32,
    character_height:        i32,
    max_ascender:            i32,
    max_descender:           i32,
    xadvance:                i32,
    replacement_character:   rune,
}

// NOTE(nawe) maximum number of glyphs we can cache. This should be
// sufficient for when working with code and editing text, but it
// might need to grow according to experience in using the editor.
MAXIMUM_FONT_SIZE :: 110
MINIMUM_FONT_SIZE :: 14
MAX_SAFE_GLYPHS   :: 300
TEXTURE_WIDTH     :: 128
TEXTURE_HEIGHT    :: 128

CHAR_PADDING :: 1

@(private="file")
fonts_initialized := false

@(private="file")
fonts_cache: [dynamic]^Font

fonts_map:    map[Font_Face]^Font

fonts_init :: proc() {
    log.debug("initializing fonts")
    success := ttf.Init()
    assert(success)
    fonts_initialized = true
}

fonts_destroy :: proc() {
    log.debug("deinitializing fonts")

    for font in fonts_cache {
        for _, glyph in font.glyphs_map {
            free(glyph)
        }

        for t in font.textures {
            sdl.DestroyTexture(t)
        }
        delete(font.textures)

        delete(font.name)
        delete(font.glyphs_map)
        ttf.CloseFont(font.face)
        free(font)
    }

    delete(fonts_cache)
    delete(fonts_map)
    ttf.Quit()
}

ensure_fonts_are_initialized :: #force_inline proc() {
    if !fonts_initialized do fonts_init()
}

initialize_font_related_stuff :: proc() {
    COMMON_CHARACTERS :: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 "

    scaled_font_editor_size := font_to_scaled_pixels(f32(settings.editor_font_size))
    scaled_font_ui_size     := font_to_scaled_pixels(f32(settings.ui_font_size))
    scaled_font_icons_size  := font_to_scaled_pixels(f32(settings.ui_font_size), 0, 1.33)
    scaled_font_small_size  := font_to_scaled_pixels(f32(settings.ui_font_size), -4)
    scaled_font_xsmall_size := font_to_scaled_pixels(10)

    fonts_map[.UI_Regular] = get_font_with_size(FONT_UI_NAME,        FONT_UI_DATA,        scaled_font_ui_size    )
    fonts_map[.UI_Italic]  = get_font_with_size(FONT_UI_ITALIC_NAME, FONT_UI_ITALIC_DATA, scaled_font_ui_size    )
    fonts_map[.UI_Bold]    = get_font_with_size(FONT_UI_BOLD_NAME,   FONT_UI_BOLD_DATA,   scaled_font_ui_size    )
    fonts_map[.UI_Small]   = get_font_with_size(FONT_UI_NAME,        FONT_UI_DATA,        scaled_font_small_size )
    fonts_map[.UI_XSmall]  = get_font_with_size(FONT_UI_NAME,        FONT_UI_DATA,        scaled_font_xsmall_size)
    fonts_map[.Icons]      = get_font_with_size(FONT_ICONS_NAME,     FONT_ICONS_DATA,     scaled_font_icons_size )

    // each pane has its own font, so we only preload the default size
    // and we don't store it in fonts_map. The UI of the editor should
    // rely on the UI fonts.
    prepare_text(
        get_font_with_size(
            FONT_EDITOR_NAME, FONT_EDITOR_DATA, scaled_font_editor_size,
        ), COMMON_CHARACTERS,
    )
    prepare_text(fonts_map[.UI_Small],   "0123456789") // tipically used for numbers
}

font_to_scaled_pixels :: proc(pt: f32, size_diff: f32 = 0, scale: f32 = 1.0) -> i32 {
    result := math.ceil(((pt + size_diff) * dpi_scale) * scale)
    result = clamp(result, MINIMUM_FONT_SIZE, MAXIMUM_FONT_SIZE)
    return i32(result)
}

get_font_with_size :: proc(name: string, data: []byte, character_height: i32) -> ^Font {
    ensure_fonts_are_initialized()

    for font in fonts_cache {
        if font.base_height != character_height do continue
        if font.name != name do continue
        return font
    }

    font_data := sdl.IOFromMem(raw_data(data), len(data))
    face := ttf.OpenFontIO(font_data, true, f32(character_height))

    ttf.SetFontHinting(face, .LIGHT_SUBPIXEL)

    result := new(Font)
    // TODO(nawe) maybe I don't need to clone this but I would guess,
    // if I ever allow to change it, I might just temporary load this
    // from a config and would need to clone it. It should be a small
    // string though.
    result.name = strings.clone(name)
    result.face = face
    result.replacement_character = 0xFFFD
    result.base_height = character_height

    result.character_height = ttf.GetFontHeight(result.face)
    result.max_ascender     = ttf.GetFontAscent(result.face)
    result.max_descender    = -ttf.GetFontDescent(result.face)

    // NOTE(nawe) I read somewhere that SDL_ttf sometimes has a bug
    // with some fonts where it cannot calculate the character height
    // correctly. Sadly I didn't capture the link for it but I had
    // this code around from before.
    if result.character_height < result.max_ascender - result.max_descender {
        result.character_height = result.max_ascender - result.max_descender
    }

    append(&result.textures, texture_create(.STREAMING, TEXTURE_WIDTH, TEXTURE_HEIGHT))

    minx, maxx, xadvance: i32
    _ = ttf.GetGlyphMetrics(result.face, u32('M'), &minx, &maxx, nil, nil, &xadvance)
    result.xadvance = xadvance
    result.em_width = minx + maxx

    if !ttf.FontHasGlyph(face, u32(result.replacement_character)) {
        result.replacement_character = 0x2022

        if !ttf.FontHasGlyph(face, u32(result.replacement_character)) {
            result.replacement_character = '?'
        }
    }

    append(&fonts_cache, result)
    return result
}

prepare_text :: proc(font: ^Font, text: string) -> (width_in_pixels: i32) {
    for r in text {
        glyph := find_or_create_glyph(font, r)
        width_in_pixels += glyph.xadvance
    }

    return
}

find_or_create_glyph :: proc(font: ^Font, r: rune) -> ^Glyph_Data {
    glyph, ok := font.glyphs_map[r]
    if ok do return glyph

    if !ttf.FontHasGlyph(font.face, u32(r)) {
        return find_or_create_glyph(font, font.replacement_character)
    }

    x, y, width, height: i32

    if font.last_packed_glyph != nil {
        x, y = font.last_packed_glyph.x, font.last_packed_glyph.y
        width, height = font.last_packed_glyph.w, font.last_packed_glyph.h
        x += width
    }

    result := new(Glyph_Data)
    result.bucket_index = len(font.textures)-1

    str_from_rune := utf8.runes_to_string([]rune{r}, context.temp_allocator)
    cstr := cstring(raw_data(str_from_rune))

    if x + width + CHAR_PADDING >= TEXTURE_WIDTH {
        x = 0
        y += height + CHAR_PADDING

        if y + height >= TEXTURE_HEIGHT {
            x = 0
            y = 0
            result.bucket_index += 1
            append(&font.textures, texture_create(.STREAMING, TEXTURE_WIDTH, TEXTURE_HEIGHT))
        }
    }

    surface := sdl.CreateSurface(TEXTURE_WIDTH, TEXTURE_HEIGHT, .RGBA32)
    sdl.SetSurfaceColorKey(surface, true, sdl.MapSurfaceRGBA(surface, 0, 0, 0, 0))

    sdl.LockTextureToSurface(font.textures[result.bucket_index], nil, &surface)

    rect := sdl.Rect{x, y, width, height}

    _ = ttf.GetGlyphMetrics(font.face, u32(r), nil, nil, nil, nil, &result.xadvance)
    _ = ttf.GetStringSize(font.face, cstr, len(cstr), &rect.w, &rect.h)

    blended_text := ttf.RenderGlyph_Blended(font.face, u32(r), {255, 255, 255, 255})
    sdl.BlitSurface(blended_text, nil, surface, &rect)

    result.x = rect.x
    result.y = rect.y
    result.w = rect.w
    result.h = rect.h

    sdl.UnlockTexture(font.textures[result.bucket_index])

    font.glyphs_map[r] = result
    font.last_packed_glyph = result
    return result
}

get_gutter_indicators :: proc(font: ^Font) -> (left, right: string) {
    if ttf.FontHasGlyph(font.face, u32('«')) && ttf.FontHasGlyph(font.face, u32('»')) {
        return "«", "»"
    } else {
        return "<", ">"
    }
}
