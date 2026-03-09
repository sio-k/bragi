package main

import rt "base:runtime"

import "core:fmt"
import "core:log"
import "core:os"
import "core:os/os2"
import "core:path/filepath"
import "core:strings"
import "core:text/regex"

import "project"

match_in_regex_list :: proc (
    path: string,
    relist: []regex.Regular_Expression
) -> bool {
    for re in relist {
        rt.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
        _, match := regex.match_and_allocate_capture(
            re, filepath.base(path),
            permanent_allocator = context.temp_allocator,
            temporary_allocator = context.temp_allocator
        )
        if match { return true }
    }
    return false
}

load_project_load_path :: proc (
    project_file_path: string,
    path: string, recursive: bool,
    patterns: []regex.Regular_Expression,
    blacklist_patterns: []regex.Regular_Expression,
) {
    if !os2.is_dir(path) {
        log.errorf("path provided in project file at %v is not a directory: %v", project_file_path, path)
        return
    }
    dir_file, dir_file_err := os2.open(path)
    if dir_file_err != nil {
        log.errorf("path provided in project file at %v can't be opened: path %v, error %v", project_file_path, path, dir_file_err)
        return
    }
    defer os2.close(dir_file)

    dir_it := os2.read_directory_iterator_create(dir_file)
    defer os2.read_directory_iterator_destroy(&dir_it)
    for finfo in os2.read_directory_iterator(&dir_it) {
        if match_in_regex_list(finfo.name, blacklist_patterns) {
            continue
        }

        if os2.is_dir(finfo.fullpath) && recursive {
            load_project_load_path(
                project_file_path,
                finfo.fullpath,
                true,
                patterns,
                blacklist_patterns
            )
        } else if match_in_regex_list(finfo.name, patterns) {
            open_file_in_buffer(finfo.fullpath)
        }
    }
}

load_project_load_paths :: proc (
    file_path: string,
    load_paths: []project.Value,
    file_contents: map[string]project.Value,
) {
    rt.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    patterns, patterns_ok := file_contents["patterns"]
    if patterns_ok {
        patterns_ok = patterns.kind == .List
        if !patterns_ok {
            log.errorf(
                "project file at %v: patterns must be a list of strings",
                file_path,
            )
        }
    }
    blacklist_patterns, blacklist_ok := file_contents["blacklist_patterns"]
    if blacklist_ok {
        blacklist_ok = patterns.kind == .List
        if !blacklist_ok {
            log.errorf(
                "project file at %v: blacklist_patterns must be a list of strings",
                file_path,
            )
        }
    }

    regexlist_from_value_list :: proc (
        file_path: string,
        vlst: []project.Value,
    ) -> []regex.Regular_Expression {
        res := make([dynamic]regex.Regular_Expression, allocator = context.temp_allocator)
        for v in vlst {
            if v.kind != .Str {
                log.errorf(
                    "project_file at %v: regex patterns must be strings",
                    file_path
                )
                continue
            }
            flags: regex.Flags = {
                .Case_Insensitive, // windows compat
                .Unicode,          // standard at this point
                .No_Capture,       // we don't care about captures
            }
            b := strings.builder_make(allocator = context.temp_allocator)
            strings.write_string(&b, "^")
            strings.write_string(&b, v.str)
            strings.builder_replace_all(&b, ".", "\\.")
            strings.builder_replace_all(&b, "*", ".*")
            strings.write_string(&b, "$")
            re, re_err := regex.create(
                strings.to_string(b), flags,
                permanent_allocator = context.temp_allocator,
                temporary_allocator = context.temp_allocator,
            )
            if re_err == nil {
                append(&res, re)
            } else {
                log.errorf(
                    "project file at %v: failed to parse regex pattern \"%v\", got error %v",
                    file_path,
                    v.str,
                    re_err,
                )
            }
        }
        return res[:]
    }

    blacklist_list := []regex.Regular_Expression {}
    patterns_list := []regex.Regular_Expression {}
    if blacklist_ok {
        blacklist_list = regexlist_from_value_list(
            file_path,
            blacklist_patterns.list
        )
    }
    if patterns_ok {
        patterns_list = regexlist_from_value_list(
            file_path,
            patterns.list,
        )
    }

    for p in load_paths {
        if p.kind != .Obj {
            log.errorf("project file at %v: individual paths must be an object containing path, recursive (=false), relative (=true)", file_path)
            continue
        }
        path, path_ok := p.obj["path"]
        if !path_ok || (path_ok && path.kind != .Str) {
            log.errorf("project file at %v: individual paths must contain a path member that is a string", file_path)
            continue
        }
        recursive, recursive_ok := p.obj["recursive"]
        if !recursive_ok || (recursive_ok && recursive.kind != .B) {
            recursive.kind = .B
            recursive.b = false
        }
        relative, relative_ok := p.obj["relative"]
        if !relative_ok || (relative_ok && relative.kind != .B) {
            relative.kind = .B
            relative.b = true
        }

        if !relative.b {
            // TODO: implement this properly
            log.errorf("don't know how to handle non-relative paths")
            continue
        }

        load_project_load_path(
            file_path,
            path.str,
            recursive.b,
            patterns_list,
            blacklist_list,
        )
    }
}

// parse project file, then open both it and everything it specifies to open
load_project :: proc (path: string) -> bool {
    rt.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    file_contents, file_ok := project.read_file(path)
    if !file_ok { return false }
    load_paths, load_paths_ok := file_contents["load_paths"]
    if load_paths_ok {
        if load_paths.kind != .Obj && load_paths.kind != .List {
            log.errorf(
                "project file at %v: load paths must be an object of OSs or a list of objects",
                path
            )
        } else if load_paths.kind == .List {
            load_project_load_paths(path, load_paths.list, file_contents)
        } else if load_paths.kind == .Obj {
            current_os_paths, paths_ok := load_paths.obj[project.current_os()]
            if paths_ok {
                load_project_load_paths(
                    path,
                    current_os_paths.list,
                    file_contents,
                )
            } else {
                log.errorf(
                    "project file at %v: load paths don't contain any load paths for current OS (%v)",
                    path,
                    project.current_os()
                )
            }
        }
    }

    commands, commands_ok := file_contents["commands"]
    if commands_ok {
        // TODO: parse project commands usefully somehow
    }

    fkey_commands, fkey_commands_ok := file_contents["fkey_command"]
    if fkey_commands_ok {
        // TODO: load fkey command mappings
    }

    fkey_commands_override, fkey_commands_override_ok := file_contents["fkey_command_override"]
    if fkey_commands_override_ok {
        // TODO: check username, and if username matches, load overrides
    }

    project_name, project_name_ok := file_contents["project_name"]
    if project_name_ok && project_name.kind == .Str {
        title := fmt.tprintf("%s - %s", NAME, project_name.str)
        windows_set_titles(title)
    }

    return load_paths_ok ||
        commands_ok ||
        fkey_commands_ok ||
        fkey_commands_override_ok
}
