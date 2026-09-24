# Installing on macOS

A start-to-finish walkthrough for a Mac, ending with the `wow-claude` command available in any terminal. The short version is in the [README](../README.md); this page spells out every step and what can go wrong. The Windows equivalent is [INSTALL-WINDOWS.md](INSTALL-WINDOWS.md).

## 1. Prerequisites

| Need | Check | Get it |
|---|---|---|
| macOS 14.2 (Sonoma) or newer | Apple menu → About This Mac | The capture helper uses ScreenCaptureKit's screenshot API, which is that new |
| World of Warcraft: Forever (the `_classic_beta_` client), any display mode | | Windowed, borderless and fullscreen all work; see [Display modes](#display-modes) |
| Apple's Command Line Tools (for `swiftc`) | `xcrun --find swiftc` prints a path | `xcode-select --install`, or Xcode from the App Store. The tools compile the screen-capture helper once during setup |
| Node.js 22.2 or newer | `node -v` prints `v22.x` or higher | [nodejs.org](https://nodejs.org) or `brew install node` |
| Git | `git --version` | Comes with the Command Line Tools |
| Claude Code, logged in | `claude --version` prints a version | [claude.com/claude-code](https://claude.com/claude-code), then run `claude` once and log in |

Any terminal works: Terminal.app, iTerm2, or the terminal inside an editor. Remember which one you use: macOS grants Screen Recording permission to that app (step 4).

## 2. Get the code

```bash
cd ~/Documents                      # or wherever you keep projects
git clone https://github.com/realworldbuilder/wow-claude-mac
cd wow-claude-mac
npm install
```

`npm install` only pulls the test tooling; the bridge itself has no dependencies.

## 3. Set up the game side

```bash
node setup.js --project "/path/to/the/project/you/want/to/work/on"
```

This:

- finds the WoW: Forever client (it looks in `/Applications/World of Warcraft/_classic_beta_` and `~/Applications/World of Warcraft/_classic_beta_`; pass `--wow "/Volumes/Games/World of Warcraft/_classic_beta_"` if yours is elsewhere),
- copies the addon into `Interface/AddOns/WoWClaude`,
- writes `bridge/config.json` with your paths and the project folder (`capture.processName` is the path of the game's `.app`),
- creates the 200 reply-slot addons and about 15,000 tiny signal files next to it. That count is normal: the client only discovers addon files when it launches, so everything the bridge might ever touch has to exist up front,
- compiles the screen-capture helper, `bridge/capture-mac.swift`, into `bridge/bin/wowclaude-capture` (a few seconds; it says `helper : built ...`).

`--project` is the fallback folder for chats. Once the `wow-claude` command is installed (step 5) you'll usually pick the folder by where you start the bridge instead.

If you have several WoW accounts, setup picks the first and says so; pass `--account <name>` to choose.

Now **fully quit and relaunch World of Warcraft** (a `/reload` is not enough, the new files have to be there at launch). On the character screen, open **AddOns** and make sure *WoW Claude* is enabled. The 200 *WoW Claude slot* entries stay enabled too; leave them alone.

## 4. First run, and the Screen Recording permission

From the `wow-claude` folder:

```bash
npm start
```

You should see a banner like:

```
WoW Claude bridge
  folder   : /path/to/your/project  (config.json; chats can override with /wow-claude cd)
  addons   : /Applications/World of Warcraft/_classic_beta_/Interface/AddOns
  slots    : 200 installed
  capture  : on (/Applications/World of Warcraft/_classic_beta_/World of Warcraft Beta.app, 200x48 cells of 4px)
  ...
```

The first time, macOS asks whether the app running the bridge (Terminal, iTerm2, the Claude app...) may record the screen. That app is what needs the permission, not the helper or Node: the bridge only ever captures the top-left corner of the game window, but macOS has no finer-grained switch. Allow it under **System Settings → Privacy & Security → Screen & System Audio Recording**, then **quit and reopen that app** (macOS applies the change on relaunch) and run `npm start` again. Until then `bridge/bridge.log` says `screen recording permission missing` and the bridge retries once a minute.

macOS 15 and later occasionally show a reminder that the app has been able to record the screen. It is informational; click *Continue To Allow*.

In the game, type `/wow-claude`. The window opens; the light in its corner should turn green within about ten seconds. Type something in the box and press Enter. The reply arrives with the whisper sound.

If the light stays red, see [Troubleshooting](#troubleshooting).

`bridge/start.command` is a double-click launcher: open it from Finder and the bridge runs in its own Terminal window. (If Finder refuses to run it, `chmod +x bridge/start.command` once.)

## 5. Install the `wow-claude` command

The bridge works in the folder you start it from, like `claude` itself. To be able to type `wow-claude` from any folder, install it once from inside the repo:

```bash
cd ~/Documents/wow-claude
npm link
```

`npm link` puts a `wow-claude` symlink into npm's global `bin` folder (`npm prefix -g` shows it; usually already on your `PATH`) that points back at this repo. Nothing is copied: pulling a newer version of the repo updates the command, and `bridge/config.json` stays where `setup.js` wrote it. If `npm link` fails with a permissions error, your npm prefix is a system folder; the usual fix is `npm config set prefix ~/.npm-global` and adding `~/.npm-global/bin` to your `PATH`.

> Don't use `npm install -g .` instead. That copies the files into npm's global folder, where there is no `config.json`, and the bridge refuses to start.

Check it:

```bash
wow-claude --help
```

Then use it from any project:

```bash
cd ~/code/realms
wow-claude
```

The banner's `folder` line now says `started here`, and every chat that hasn't chosen its own folder with `/wow-claude cd` works in `realms`. `wow-claude --project <dir>` names the folder explicitly. Only one bridge can run at a time (two would fight over the screen and the slot files), so this sets the default folder rather than running one bridge per project.

Leave the terminal open while you play. Ctrl+C stops it. It restarts itself if it ever crashes.

### Display modes

The addon draws the message strip at the top-left of the game's render area, in physical pixels, and the helper captures only the game window (other windows on top of it don't get in the way). It finds the strip whether the window has a title bar (windowed) or not (borderless / fullscreen), and whether the game renders at the display's full Retina resolution or at half of it. It works on any connected display, including one the game opens on because of `GxMonitor`.

Keep the game window on screen: a minimized window isn't captured, and the bridge waits for it to come back.

### Updating

```bash
cd ~/Documents/wow-claude
git pull
node setup.js        # re-copies the addon, rebuilds the helper if its source changed; keeps config.json and the slot pool
```

Then `/reload` in game and restart the bridge. If `setup.js` reports that it created new files, quit and relaunch the game instead of `/reload`.

### Uninstalling

```bash
npm unlink -g wow-claude      # removes the command
```

Delete `Interface/AddOns/WoWClaude` and the `WoWClaude_S001` … `WoWClaude_S200` folders next to it, and the `wow-claude` folder. Your chats' saved data is in `WTF/Account/<account>/SavedVariables/WoWClaude.lua`. To take the Screen Recording grant away from your terminal, switch it off under System Settings → Privacy & Security → Screen & System Audio Recording.

## Troubleshooting

**`helper : swiftc not found`** during setup. Install Apple's Command Line Tools with `xcode-select --install` (a dialog opens; full Xcode is not required), then run `node setup.js` again. Until then the bridge starts but the banner says `capture : OFF - helper not built`, and only the `/wow-claude mode reload` transport works.

**`helper : swiftc failed`** with an error about macOS versions. The helper needs macOS 14.2 or newer, both to build and to run.

**`bridge.log` says `screen recording permission missing: allow '<app>'`.** Grant it to the named app (System Settings → Privacy & Security → Screen & System Audio Recording), then quit and reopen that app. Toggling the switch without relaunching the app is the usual reason it "doesn't work". If the app isn't in the list, click **+** and add it, or run `npm start` once more so macOS prompts for it.

**`wow-claude: command not found`.** Open a new terminal, or check that `$(npm prefix -g)/bin` is on your `PATH`.

**"Cannot read config.json … Run node setup.js".** The command is pointing at a copy of the repo that hasn't been set up (usually `npm install -g .` was used instead of `npm link`, or the repo folder was moved). Run `npm link` again from the repo folder you set up.

**The banner says `slots : NOT INSTALLED`.** `setup.js` couldn't write into the AddOns folder, or it wrote somewhere else. Check `addonDir` in `bridge/config.json`, then run `node bridge/install-slots.js` and relaunch the game.

**`Could not start claude`.** The bridge looks for `claude` on the `PATH` and in `~/.local/bin/claude`. If yours lives elsewhere (`which claude`), put the full path in `claudePath` in `bridge/config.json`.

**The light stays red / "no sign of the bridge".** The bridge can't see the strip in the top-left corner of the game window. `bridge/bridge.log` prints `waiting for ... window` until it finds the game, `attached to '...'` when it does (with the window size, display and scale), and `strip #N` when it decodes a message. In order of likelihood: the permission above; the game window is minimized; `capture.processName` in the config doesn't match your client (it is the `.app` path; the bundle id `com.blizzard.worldofwarcraft` or the app name `Wow` also work). `/wow-claude diag` in game prints the render size the strip is drawn at.

**`strip seen but rejected: checksum`** in the log. The helper found the strip's start but misread cells. Try a different in-game display mode or turn off any screen filter or color-management tool (f.lux, Night Shift is fine); run `bridge/bin/wowclaude-capture -ProcessName "<your .app path>" -DumpImage /tmp/strip.png` for a few seconds while a message is pending and look at the image.

**Everything else** is in the README's Troubleshooting section and in `/wow-claude diag` in game.
