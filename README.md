# respawn

Session restore for [Hyprland](https://hyprland.org/). Saves and restores your desktop environment — terminal windows, tmux sessions, workspaces, and browser windows — across reboots.

## What it does

- **Save**: Snapshots Hyprland window state, tmux sessions, and workspace layout to JSON
- **Restore**: Relaunches Alacritty terminals attached to the correct tmux sessions, places them on their original workspaces, and opens Brave with its own session restore

## Dependencies

- [Hyprland](https://hyprland.org/)
- [tmux](https://github.com/tmux/tmux) + [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect)
- [Alacritty](https://alacritty.org/)
- [jq](https://jqlang.github.io/jq/)
- [Brave](https://brave.com/) (optional — any Chromium browser works)

## Install

```bash
cp respawn ~/.local/bin/respawn
chmod +x ~/.local/bin/respawn
```

### Hyprland autostart (restore on login)

Add to `~/.config/hypr/autostart.conf`:

```
exec-once = ~/.local/bin/respawn restore
```

### Shutdown/reboot integration

Use `respawn shutdown` and `respawn reboot` instead of raw `systemctl` calls — they save state first, then power off/reboot.

## Usage

```
respawn save       # snapshot current session
respawn restore    # restore saved session
respawn shutdown   # save + power off
respawn reboot     # save + reboot
respawn status     # show saved state summary
```

## How it works

**Save** captures:
1. All Hyprland windows via `hyprctl clients -j`
2. Monitor and workspace layout
3. Tmux sessions with window/pane details
4. Alacritty-to-tmux-session mapping (by walking the process tree)
5. Triggers `tmux-resurrect` save for pane contents

**Restore**:
1. Waits for Hyprland IPC to be ready
2. Starts tmux server and waits for resurrect/continuum to restore sessions
3. Launches Alacritty windows with temporary `windowrulev2` rules to place them on the correct workspace
4. Launches Brave (which restores its own tabs)
5. Matches Brave windows by title and moves them to saved workspaces

State is stored at `~/.local/share/respawn/state.json`.

## License

MIT
