# Zquig

A lightweight screenshot annotation app for macOS, written in Swift with AppKit. Capture a region, window or the full screen, or open an image or PDF, then mark it up and export it.

## Features

- **Capture:** region, window, or full screen. You can also start from the clipboard or a blank canvas.
- **Open:** any image format macOS supports, and PDFs.
- **Annotation tools:** select, arrow, line, rectangle, ellipse, pen, highlighter, text, numbered stamp, pixelate (for redacting), and crop.
- **Editable annotations:** move and resize shapes after drawing them, change color and stroke width, and copy and paste them between windows.
- **Text:** wrapping text blocks with a resizable width, a white outline and a soft shadow.
- **Undo/redo** for every edit.
- **Export:** PNG, JPEG, TIFF or PDF. You can also copy the whole image or drag it out of the window.

## Install

Download `Zquig.zip` from the latest [release](https://github.com/raisv3n/Zquig/releases/latest). It is a universal build that runs on both Apple Silicon and Intel Macs. Unzip it, then run:

```sh
cd ~/Downloads/Zquig
./install.sh
```

This copies `Zquig.app` to `/Applications` and clears the download quarantine flag. The app isn't notarized, so without this step macOS would refuse to open it.

## Requirements

- macOS 12 or later
- Swift 5.9+ toolchain (Xcode or Command Line Tools), only needed to build from source

## Build from source

```sh
./build_app.sh
open dist/Zquig.app
```

`build_app.sh` builds an Apple Silicon (arm64) release binary, assembles `dist/Zquig.app` and ad-hoc signs it. The app is ad-hoc signed, so the first launch may need a right-click > Open.

The three capture commands use macOS's built-in `screencapture` tool, so macOS may ask you to allow screen access for Zquig (System Settings > Privacy & Security > Screen Recording). That is only so it can take a screenshot. Zquig never records video, and everything stays on your machine. If you only open images, PDFs or the clipboard, you won't be asked.

`./package.sh` builds the app and wraps it with an install script in `dist/Zquig.zip`. With `UNIVERSAL=1 ./package.sh` you get an arm64 + x86_64 build, which needs full Xcode. Pushing a `v*` tag runs `.github/workflows/release.yml`, which builds the universal zip and attaches it to a GitHub release.

For a quick development run without packaging:

```sh
swift run
```

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| New from Clipboard | Cmd N |
| Capture Region | Opt Cmd R |
| Capture Window | Opt Cmd W |
| Capture Full Screen | Opt Cmd F |
| Open | Cmd O |
| Save / Save As | Cmd S / Shift Cmd S |
| Copy Whole Image | Shift Cmd C |
| Undo / Redo | Cmd Z / Shift Cmd Z |

Inside an image window:

| Action | Key |
| --- | --- |
| Select tool | A |
| Text tool | T |
| Arrow tool | Q |
| Delete selected annotation | Delete / Forward Delete |
| Deselect | Esc |
| Nudge selected annotation | Arrow keys (1 px), Shift + Arrow keys (10 px) |
| Finish editing text | Cmd Return or Esc |

The other tools are chosen from the toolbar.

## Project layout

```
Sources/Zquig/
  main.swift            App delegate, menus, capture and open flows
  DocumentWindow.swift  Window, toolbar, saving and export
  CanvasView.swift      Drawing surface and mouse/keyboard interaction
  Annotation.swift      Tools, annotation model, rendering, serialisation
Resources/AppIcon.icns  App icon
build_app.sh            Builds and packages the .app bundle
package.sh              Builds dist/Zquig.zip for installing on other Macs
```

## License

Personal use only. See [LICENSE](LICENSE). This is not an open-source license.
