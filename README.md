<p align="center">
   <img src="https://github.com/nawetimebomb/bragi/blob/main/res/icons/bragi-icon_large.png?raw=true" alt="Bragi Editor" style="width:25%" />
   <br />
</p>

# Bragi

[Bragi](https://bragi.codes) is a modern text editor for programmers that prefer to use their keyboard. Inspired by Emacs, but without the need of having to maintain a repo worth of configuration, Bragi gives you keyboard interactions for anything you want to do on the editor.

> [!WARNING]
> Bragi is in pre-alpha, intended to be used by its developers.
>

## Features

- Keyboard control for everything
- Very flexible multi-cursor system
- Electric indent
- GPU rendering
- Auto-conversion from CRLF to LF
- Low RAM and CPU footprint

## Roadmap

- Settings file for easy configuration
- Find files and search in projects

## How to build from source

Get the [Odin compiler](https://odin-lang.org/) and run the build script:

```
./release.sh
```

The executable will be available for you in `<bragi-dir>/release`
