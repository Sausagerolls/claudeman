# Claudeman

A native macOS app for managing projects built with [Claude Code](https://claude.com/claude-code).
Each project points at a folder, and Claude Code runs inside the app in a real terminal,
exactly as it does in Terminal.app, with every session kept together in one window.

![Claudeman icon](Resources/AppIcon.png)

## Features

- **Projects sidebar**: add a project from a folder (⌘N, or drag a folder onto the sidebar), or clone one straight from GitHub (⇧⌘N).
- **Clone from GitHub**: browse your repositories through the GitHub CLI, or paste any `owner/repo` or URL. The clone becomes a new project and can start a Claude session right away.
- **Session tabs**: run several Claude Code sessions per project. They keep running while you switch tabs or projects.
- **Restart ended sessions**: when Claude exits, start a new session, continue the last one (`claude --continue`), or pick an older one (`claude --resume`).
- **Customisable**: light/dark/system appearance, eight terminal themes, font and size, cursor style, Option-as-Meta, confirmations, default launch mode and clone folder.

### Shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘N | New project from folder |
| ⇧⌘N | Clone from GitHub |
| ⌘T | New session |
| ⇧⌘T | Continue last session |
| ⇧⌘R | Resume a past session |
| ⇧⌘W | Close session tab |
| ⌘, | Settings |

## Requirements

- macOS 14 or later
- Xcode command line tools (Swift 5.10+)
- [Claude Code](https://docs.claude.com/en/docs/claude-code) installed (`claude` on your PATH)
- Optional: [GitHub CLI](https://cli.github.com) logged in with `gh auth login`, to browse and clone private repositories

## Build

```sh
./scripts/bundle.sh        # builds build/Claudeman.app
open build/Claudeman.app
```

During development you can also run it directly with `swift run`.

To regenerate the app icon after editing `scripts/make-icon.swift`:

```sh
swift scripts/make-icon.swift
```

## How it works

- Sessions run in a pseudo-terminal provided by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
- Commands start through your login shell (`$SHELL -l -c`), so `claude`, `git` and `gh` are found even when the app is opened from Finder. If `claude` lives somewhere only your `.zshrc` adds to PATH, set its full path in Settings.
- Projects are stored in `~/Library/Application Support/Claudeman/projects.json`.
