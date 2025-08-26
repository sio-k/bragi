package main

import "base:runtime"

import "core:encoding/uuid"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

UNDO_TIMEOUT_URGENT_EDIT :: 500 * time.Millisecond
UNDO_TIMEOUT_LINEAR_EDIT :: 2 * time.Second

Buffer_Flags :: bit_set[Buffer_Flag; u8]

Buffer_Flag :: enum u8 {
    Dirty     = 0, // change in the buffer state, needs to redraw
    Modified  = 1, // contents change compared to previous version
    Read_Only = 2, // can't be changed
    CRLF      = 3, // was saved before as CRLF, it will be converted to LF
    Scratch   = 4, // created by Bragi as scratchpad. If saved as file, this flag will be removed.
}

Major_Mode :: enum u8 {
    Bragi = 0,
    Jai,
    Odin,
}

Source_Buffer :: enum {
    Add,
    Original,
}

Buffer :: struct {
    allocator:        runtime.Allocator,
    uuid:             uuid.Identifier,

    cursors:          []Cursor, // for undo/redo and switch buffer, a copy to the pane's cursors
    original_source:  strings.Builder,
    add_source:       strings.Builder,
    pieces:           [dynamic]Piece,
    text_content:     strings.Builder,
    tokens:           [dynamic]Token_Kind,

    indent: struct {
        tab_char: Tab_Character,
        tab_size: int,
    },

    history_enabled:  bool,
    redo, undo:       [dynamic]History_State,
    last_backup_time: time.Tick,

    name:             string,
    filepath:         string,
    major_mode:       Major_Mode,
    flags:            Buffer_Flags,
}

Piece :: struct {
    source:      Source_Buffer,
    start:       int,
    length:      int,
    line_starts: [dynamic]int,
}

History_State :: struct {
    cursors: []Cursor,
    pieces:  []Piece,
}

buffer_get_or_create_empty :: proc(name: string = "*scratchpad*") -> ^Buffer {
    for buffer in open_buffers {
        if buffer.name == name {
            log.debugf("using existing buffer with name '{}'", name)
            return buffer
        }
    }

    log.debugf("creating new buffer with name '{}'", name)
    result := new(Buffer)
    buffer_init(result, {})
    result.name = strings.clone(name)
    if name == "*scratchpad*" do flag_buffer(result, {.Scratch})
    _buffer_set_major_mode(result)
    append(&open_buffers, result)
    return result
}

buffer_get_or_create_from_file :: proc(fullpath: string, contents: []byte) -> ^Buffer {
    for buffer in open_buffers {
        if buffer.filepath == fullpath {
            log.debugf("found buffer for '{}'", fullpath)
            return buffer
        }
    }

    log.debugf("creating buffer for file '{}'", fullpath)
    result := new(Buffer)
    buffer_init(result, contents)
    result.filepath = strings.clone(fullpath)
    result.name = strings.clone(_get_unique_buffer_name(fullpath))
    _buffer_set_major_mode(result)
    append(&open_buffers, result)
    return result
}

buffer_init :: proc(buffer: ^Buffer, contents: []byte, allocator := context.allocator) {
    buffer.allocator = allocator
    buffer.uuid = uuid.generate_v6()
    buffer.original_source = strings.builder_make_len_cap(0, len(contents))
    buffer.add_source = strings.builder_make()
    buffer.history_enabled = true
    buffer.indent.tab_char = settings.default_tab_character
    buffer.indent.tab_size = settings.default_tab_size
    flag_buffer(buffer, {.Dirty})

    for b in contents {
        if b == '\r' {
            // remove carriage returns
            flag_buffer(buffer, {.CRLF, .Modified})
            continue
        }

        strings.write_byte(&buffer.original_source, b)
    }

    contents_length := len(buffer.original_source.buf)

    original_piece := Piece{
        source = .Original,
        start  = 0,
        length = contents_length,
    }
    update_piece_line_starts(buffer, &original_piece)
    append(&buffer.pieces, original_piece)
}

buffer_index :: proc(buffer: ^Buffer) -> int {
    for other, index in open_buffers {
        if buffer.uuid == other.uuid do return index
    }

    unreachable()
}

get_major_mode_by_extension :: proc(ext: string) -> Major_Mode {
    switch ext {
    case ".jai":  return .Jai
    case ".odin": return .Odin
    }

    return .Bragi
}

@(private="file")
_buffer_set_major_mode :: proc(buffer: ^Buffer) {
    if buffer.filepath != "" {
        ext := filepath.ext(buffer.filepath)
        buffer.major_mode = get_major_mode_by_extension(ext)
    } else {
        ext := filepath.ext(buffer.name)
        buffer.major_mode = get_major_mode_by_extension(ext)
    }
}

@(private="file")
_get_unique_buffer_name :: proc(fullpath: string) -> (result: string) {
    _gen_name_from_fullpath :: proc(prev_name: string, fullpath: string) -> (new_name: string) {
        posix_fullpath, _ := filepath.to_slash(fullpath, context.temp_allocator)
        substr_index := strings.index(posix_fullpath, prev_name)
        substr_index = max(substr_index - 1, 0)
        for substr_index > 0 && posix_fullpath[substr_index-1] != '/' do substr_index -= 1
        new_name = posix_fullpath[substr_index:len(posix_fullpath)]
        return
    }

    matching_name := filepath.base(fullpath)
    result = matching_name
    buffers_with_matching_names := make([dynamic]^Buffer, context.temp_allocator)

    for {
        // find the buffers with matching_name
        for buffer in open_buffers {
            if buffer.filepath != "" {
                if buffer.name == result {
                    append(&buffers_with_matching_names, buffer)
                } else if filepath.base(buffer.filepath) == result {
                    append(&buffers_with_matching_names, buffer)
                }
            }
        }

        if len(buffers_with_matching_names) == 0 do break

        // rename older existing buffers to be their minimal
        // expression of uniqueness while having the new one be very
        // unique, appending as much as it is needed so it doesn't
        // repeat.
        for len(buffers_with_matching_names) > 0 {
            buffer := pop(&buffers_with_matching_names)
            delete(buffer.name)
            new_name := _gen_name_from_fullpath(filepath.base(buffer.filepath), buffer.filepath)
            buffer.name = strings.clone(new_name)
        }

        result = _gen_name_from_fullpath(result, fullpath)
    }

    return
}

buffer_save_as :: proc(buffer: ^Buffer, fullpath: string) {
    flag_buffer(buffer, {.Modified})

    delete(buffer.filepath)
    delete(buffer.name)
    buffer.filepath = strings.clone(fullpath)
    buffer.name = strings.clone(_get_unique_buffer_name(fullpath))
    buffer_save(buffer)
}

buffer_save :: proc(buffer: ^Buffer) {
    if .Modified not_in buffer.flags {
        log.debug("no changes need to be saved")
        return
    }

    // ensure file ends in newline to be POSIX compliant
    temp_builder := strings.builder_make(context.temp_allocator)
    buffer_len := len(buffer.text_content.buf)
    buf := buffer.text_content.buf
    if buf[buffer_len - 1] != '\n' do strings.write_byte(&temp_builder, '\n')

    if len(temp_builder.buf) > 0 {
        temp_str := strings.to_string(temp_builder)
        insert_at(buffer, buffer_len, temp_str)
        strings.write_string(&buffer.text_content, temp_str)
    }

    unflag_buffer(buffer, {.CRLF, .Modified})

    if !os.exists(buffer.filepath) {
        // since the file doesn't exists, we might need to also make the directory
        expected_dir := filepath.dir(buffer.filepath, context.temp_allocator)
        error := _maybe_make_directories_recursive(expected_dir)

        if error != nil {
            log.fatalf("could not make directories for buffer '{}' at {} with error {}", buffer.name, buffer.filepath, error)
            return
        }
    }

    error := os.write_entire_file_or_err(buffer.filepath, buffer.text_content.buf[:])
    if error != nil {
        log.fatalf("could not save buffer '{}' at {} due to {}", buffer.name, buffer.filepath, error)
        return
    }

    log.debugf("wrote {}", buffer.filepath)
}

@(private="file")
_maybe_make_directories_recursive :: proc(check_dir: string) -> os.Error {
    if !os.exists(check_dir) {
        _maybe_make_directories_recursive(filepath.dir(check_dir, context.temp_allocator))
        error := os.make_directory(check_dir)
        return error
    }

    return nil
}

buffer_destroy :: proc(buffer: ^Buffer) {
    strings.builder_destroy(&buffer.original_source)
    strings.builder_destroy(&buffer.add_source)
    strings.builder_destroy(&buffer.text_content)
    undo_clear(buffer, &buffer.undo)
    undo_clear(buffer, &buffer.redo)
    delete(buffer.cursors)
    for piece in buffer.pieces do delete(piece.line_starts)
    delete(buffer.pieces)
    delete(buffer.tokens)
    delete(buffer.undo)
    delete(buffer.redo)
    delete(buffer.name)
    if buffer.filepath != "" do delete(buffer.filepath)
    free(buffer)
}

update_opened_buffers :: proc() {
    profiling_start("updating opened buffers")
    for buffer in open_buffers {
        is_active_in_panes := false

        for pane in open_panes {
            if pane.buffer.uuid == buffer.uuid {
                is_active_in_panes = true
                break
            }
        }

        if !is_active_in_panes do continue

        if .Dirty in buffer.flags {
            profiling_start("putting pieces together and making lines array")
            unflag_buffer(buffer, {.Dirty})
            strings.builder_reset(&buffer.text_content)
            lines_array := make([dynamic]int, 1, context.temp_allocator)
            collect_pieces_from_buffer(buffer, &buffer.text_content, &lines_array)
            tokenize_buffer(buffer)
            profiling_end()

            profiling_start("passing buffer text to pane")
            for pane in open_panes {
                if pane.buffer != buffer do continue
                delete(pane.line_starts)
                pane.contents = strings.to_string(buffer.text_content)
                pane.line_starts = slice.clone_to_dynamic(lines_array[:])
                if .Line_Wrappings in pane.flags do recalculate_line_wrappings(pane)
                flag_pane(pane, {.Need_Full_Repaint})
            }
            profiling_end()
        }
    }
    profiling_end()
}

undo_clear :: proc(buffer: ^Buffer, undo: ^[dynamic]History_State) {
    for len(undo) > 0 {
        item := pop(undo)
        delete(item.cursors)
        delete(item.pieces)
    }
}

undo_state_push :: proc(buffer: ^Buffer, undo: ^[dynamic]History_State) -> mem.Allocator_Error {
    log.debug("pushing new undo state")
    item: History_State

    item.cursors = slice.clone(buffer.cursors[:])
    item.pieces  = slice.clone(buffer.pieces[:])
    buffer.last_backup_time = time.tick_now()

    append(undo, item) or_return
    return nil
}

maybe_save_undo_state :: proc(buffer: ^Buffer, timeout: time.Duration) {
    if time.tick_diff(buffer.last_backup_time, time.tick_now()) > timeout {
        undo_state_push(buffer, &buffer.undo)
    }
}

undo :: proc(buffer: ^Buffer, undo, redo: ^[dynamic]History_State) -> (bool, []Cursor, []Piece) {
    if len(undo) > 0 {
        undo_state_push(buffer, redo)
        item := pop(undo)
        cursors := slice.clone(item.cursors, context.temp_allocator)
        pieces := slice.clone(item.pieces, context.temp_allocator)
        delete(item.cursors)
        delete(item.pieces)
        flag_buffer(buffer, {.Dirty, .Modified})
        return true, cursors, pieces
    }

    return false, {}, {}
}

copy_cursors :: proc(pane: ^Pane, buffer: ^Buffer) {
    delete(buffer.cursors)
    buffer.cursors = slice.clone(pane.cursors[:])
}

flag_buffer :: #force_inline proc(buffer: ^Buffer, flags: Buffer_Flags) {
    buffer.flags += flags
}

unflag_buffer :: #force_inline proc(buffer: ^Buffer, flags: Buffer_Flags) {
    buffer.flags -= flags
}

is_modified :: #force_inline proc(buffer: ^Buffer) -> bool {
    return .Modified in buffer.flags
}

is_crlf :: #force_inline proc(buffer: ^Buffer) -> bool {
    return .CRLF in buffer.flags
}

is_continuation_byte :: proc(b: byte) -> bool {
	return b >= 0x80 && b < 0xc0
}

get_major_mode_name :: proc(buffer: ^Buffer) -> string {
    switch buffer.major_mode {
    case .Bragi: return "Bragi"
    case .Jai:   return "Jai"
    case .Odin:  return "Odin"
    }

    unreachable()
}

collect_pieces_from_buffer :: proc(
    buffer: ^Buffer, builder: ^strings.Builder, lines_array: ^[dynamic]int,
) {
    // request_up_to_line provides a escape hatch in case we need to
    // break once we eat the amount of lines requested

    // NOTE(nawe) the user should provide a lines array where the
    // first line should already be the index 0, the rest will be
    // filled up by this procedure, including the last line. The
    // builder should be given empty.
    if lines_array != nil do assert(len(lines_array) == 1 && lines_array[0] == 0)
    if builder != nil do assert(len(builder.buf) == 0)

    total_length := 0

    for piece in buffer.pieces {
        if builder != nil {
            start, end := piece.start, piece.start + piece.length

            switch piece.source {
            case .Add:
                strings.write_string(
                    builder, strings.to_string(buffer.add_source)[start:end],
                )
            case .Original:
                strings.write_string(
                    builder, strings.to_string(buffer.original_source)[start:end],
                )
            }
        }

        if lines_array != nil {
            for line_start in piece.line_starts {
                append(lines_array, total_length + line_start)
            }
        }

        total_length += piece.length
    }

    // the last line for safety
    append(lines_array, total_length + 1)
}

insert_at :: proc(buffer: ^Buffer, offset: int, text: string) -> (length_of_text: int) {
    add_source_length := len(buffer.add_source.buf)
    length_of_text = len(text)
    piece_index, new_offset := locate_piece(buffer, offset)
    piece := &buffer.pieces[piece_index]
    end_of_piece := piece.start + piece.length
    flag_buffer(buffer, {.Dirty, .Modified})

    maybe_save_undo_state(buffer, UNDO_TIMEOUT_LINEAR_EDIT)

    strings.write_string(&buffer.add_source, text)

    // If the cursor is at the end of a piece, and that also points to the end
    // of the add buffer, we just need to grow the length of that piece. This is
    // the most common operation while entering text in sequence.
    if piece.source == .Add && new_offset == end_of_piece && add_source_length == end_of_piece {
        piece.length += length_of_text
        update_piece_line_starts(buffer, piece)
        return
    }

    // We may need to split the piece into up to three pieces if the text was
    // added in the middle of an existing piece. We only care about the pieces
    // that have positive length to be added back.
    left := Piece{
        source = piece.source,
        start  = piece.start,
        length = new_offset - piece.start,
    }
    middle := Piece{
        source = .Add,
        start  = add_source_length,
        length = length_of_text,
    }
    right := Piece{
        source = piece.source,
        start  = new_offset,
        length = piece.length - (new_offset - piece.start),
    }

    maybe_save_undo_state(buffer, UNDO_TIMEOUT_URGENT_EDIT)

    new_pieces := slice.filter([]Piece{left, middle, right}, proc(new_piece: Piece) -> bool {
        return new_piece.length > 0
    }, context.temp_allocator)
    for &new_piece in new_pieces do update_piece_line_starts(buffer, &new_piece)
    delete(buffer.pieces[piece_index].line_starts)
    ordered_remove(&buffer.pieces, piece_index)
    inject_at(&buffer.pieces, piece_index, ..new_pieces)

    return
}

remove_at :: proc(buffer: ^Buffer, offset: int, amount: int) {
    assert(offset >= 0)
    if amount == 0 do return

    if amount < 0 {
        remove_at(buffer, offset + amount, -amount)
        return
    }

    maybe_save_undo_state(buffer, UNDO_TIMEOUT_LINEAR_EDIT)

    // Remove may affect multiple pieces.
    first_piece_index, first_offset := locate_piece(buffer, offset)
    last_piece_index, last_offset := locate_piece(buffer, offset + amount)
    flag_buffer(buffer, {.Dirty, .Modified})

    // Only one piece was affected, either at the beginning of the piece or at the end.
    if first_piece_index == last_piece_index {
        piece := &buffer.pieces[first_piece_index]

        if first_offset == piece.start {
            piece.start += amount
            piece.length -= amount
            update_piece_line_starts(buffer, piece)
            return
        } else if last_offset == piece.start + piece.length {
            piece.length -= amount
            update_piece_line_starts(buffer, piece)
            return
        }
    }

    // Multiple pieces were affected, we need to correct them.
    first_piece := buffer.pieces[first_piece_index]
    last_piece := buffer.pieces[last_piece_index]

    left := Piece{
        source = first_piece.source,
        start  = first_piece.start,
        length = first_offset - first_piece.start,
    }
    right := Piece{
        source = last_piece.source,
        start  = last_offset,
        length = last_piece.length - (last_offset - last_piece.start),
    }

    maybe_save_undo_state(buffer, UNDO_TIMEOUT_URGENT_EDIT)

    new_pieces := slice.filter([]Piece{left, right}, proc(new_piece: Piece) -> bool {
        return new_piece.length > 0
    }, context.temp_allocator)
    for &new_piece in new_pieces do update_piece_line_starts(buffer, &new_piece)
    for piece in buffer.pieces[first_piece_index:last_piece_index + 1] do delete(piece.line_starts)
    remove_range(&buffer.pieces, first_piece_index, last_piece_index + 1)
    inject_at(&buffer.pieces, first_piece_index, ..new_pieces)
}

make_sure_pieces_have_lines :: proc(buffer: ^Buffer) {
    for &piece in buffer.pieces {
        piece.line_starts = make([dynamic]int)
        update_piece_line_starts(buffer, &piece)
    }
}

update_piece_line_starts :: proc(buffer: ^Buffer, piece: ^Piece) {
    buf: []byte
    start := piece.start
    end := piece.start + piece.length
    clear(&piece.line_starts)

    switch piece.source {
    case .Add:      buf = buffer.add_source.buf[start:end]
    case .Original: buf = buffer.original_source.buf[start:end]
    }

    for c, index in buf {
        if c == '\n' do append(&piece.line_starts, index + 1)
    }
}

locate_piece :: proc(buffer: ^Buffer, offset: int) -> (piece_index, remaining: int) {
    assert(offset >= 0)
    remaining = offset

    for piece, index in buffer.pieces {
        if remaining <= piece.length {
            return index, piece.start + remaining
        }
        remaining -= piece.length
    }

    unreachable()
}
