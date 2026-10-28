Native macOS app for managing your Claude Code projects. Each project points at a folder, and Claude Code runs inside the app in a real terminal, with all your sessions together in one window.

## New in 0.3.0: control Claude from your iPhone or iPad

Claudeman can now be controlled from **Claudeman Remote**, a companion app for iPhone and iPad. Its source is in the `iOS/` folder of this repo. For now, you build it with Xcode; it isn't on the App Store.

- **Pair in seconds.** On the Mac, open Settings › Remote and turn on remote control. Click **Pair Device…** and scan the QR code with your iPhone camera, or type the 6-digit code.
- **See every project and session**, with live status: running, working, or waiting on a question.
- **Start, continue, restart or stop sessions** from your phone.
- **Chat with Claude**: read the conversation, send messages, and attach photos from your camera or photo library.
- **Answer prompts.** Claude's questions and permission requests appear as tappable cards. A live view of the terminal and a key bar handle anything else.

Remote control is off until you turn it on. Each device pairs once with a code that expires after 5 minutes, and you can remove a device at any time. Traffic stays on your local network. To connect when you're away from home, use [Tailscale](https://tailscale.com). Don't forward the port to the internet.

## Download

- **Claudeman-0.3.0.dmg**: open it and drag Claudeman into Applications.
- **Claudeman-0.3.0.zip**: the same app as a zip file.

This is a universal build for Apple Silicon and Intel Macs. It needs macOS 14 Sonoma or later. The app is signed and notarized by Apple, so it opens without a security warning.

You also need [Claude Code](https://docs.claude.com/en/docs/claude-code) installed, so that `claude` works in your terminal. To browse and clone your private repositories, install the [GitHub CLI](https://cli.github.com) and log in with `gh auth login`. This is optional.

## Also in this release

- Pair by QR code as well as the 6-digit code.
- Sessions stopped with Stop now show as "stopped" instead of an exit code.
- Fixed a race that could stop the remote server from starting.
- Claudeman no longer passes its own Claude Code session settings on to the sessions it starts.
