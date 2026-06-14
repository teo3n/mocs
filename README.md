# MOCS (Mac Objectively Correct Shortcuts)

A background service, which converts objectively correct Linux-style keyboard shortcuts into the nonsense a focus group at Apple decided was a good idea some decades ago.

Remaps:
 - Globe -> control
 - Left Ctrl -> Fn/Globe
 - Option -> Meta
 - Command -> Alt
 - Right Command -> AltGr

If something that existed in Linux/Windows required Cmd in the shortcut, that has likely been mapped to Ctrl now. If the shortcut used Ctrl natively, it remains as-is. If it is mac-exclusive (e.g. cmd+backspace to delete a file), it remains as-is.

Requires permissions from the accessibility -section, so don't install unless you are willing to go through the code and verify it actually works as you'd want it to. If all keyboard input breaks (happened once when I removed the permission without first uninstalling the application), just reboot and it *should* just work again. No guarantees, this software is provided as-is without any warranty of any kind. "Hey it works on my machine."

Requires any shortcut this interacts with to be macos default.


### Shortcuts with CTRL as the basis:
 - tab, shift+tab: switch current window’s tabs (already works like this in macos).
 - t, w: open or close new tab.
 - left, right arrow: jump cursor whole word left/right.
 - x, c, v: copy-paste.
 - z, y: undo, redo.
 - o: open file.
 - backspace: delete word.
 - a: select all.
 - s: save.
 - l: jump to the address bar.
 - f: find.
 - r: reload.
 - n: new window.
 - p: print.
 - +/-/0: zoom functions.

### Shortcuts with META as the basis:
 - Meta+mouseclick+drag: start moving the window by dragging from anywhere on the window.
 - q: kill the active application.
 - meta+up: maximize the window (i.e. fill).
 - meta+down: minimize the window.
 - meta+left: tile the window to fill the left half of the screen.
 - meta+right: tile the window to fill the right half of the screen.
 - meta+shift+s: take a rectangle area screenshot and copy to clipboard.
 - meta+e: launch the file manager.
 - meta+t: launch the terminal.
 - meta+shift+left: move to the desktop to the left.
 - meta+shift+right: move to the desktop to the right.
 - meta+Num: launch/open app from the dock at index Num (not counting finder, which is forced index 0).

### Shortcuts with ALT as the basis:
 - alt+§ to open spotlight search. Macos default is hard to hit if you hold the laptop in a whacky position like I do.

## Build & install

```sh
./setup.sh
```

Uninstall: `./uninstall.sh`.

## Caveats

 - Only tested and likely only works on FIN-layout keyboards. Probably relatively trivial to port to any other layout.

 - Lightly inspired by (= blatantly copied from) the Karabiner open-source project, at least the use of the accessibility API to re-route shortcuts.

 - `EXPERIMENTAL_CMD2CTRL` defaults to true, will break compatibility in apps where ctrl+key and cmd+key have conflicts. Set to false if not wanted.