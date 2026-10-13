Native macOS app for managing your Claude Code projects. Each project points at a folder, and Claude Code runs inside the app in a real terminal, with all your sessions together in one window.

## Download

- **Claudeman-*.dmg**: open it and drag Claudeman into Applications.
- **Claudeman-*.zip**: the same app as a zip file.

This is a universal build for Apple Silicon and Intel Macs. It needs macOS 14 Sonoma or later. The app is signed and notarized by Apple, so it opens without a security warning.

You also need [Claude Code](https://docs.claude.com/en/docs/claude-code) installed, so that `claude` works in your terminal. To browse and clone your private repositories, install the [GitHub CLI](https://cli.github.com) and log in with `gh auth login`. This is optional.

## Features

- Add projects from a folder, or clone them straight from GitHub.
- Run several Claude Code sessions per project in tabs. They keep running in the background.
- When a session ends, start a new one, continue the last one, or resume an older one.
- Light, dark or system appearance. Eight terminal themes, plus font, cursor and keyboard options.
