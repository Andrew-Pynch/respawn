#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="$HOME/.local/share/respawn"
STATE_FILE="$STATE_DIR/state.json"
RESURRECT_SAVE="$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh"
RESURRECT_RESTORE="$HOME/.tmux/plugins/tmux-resurrect/scripts/restore.sh"

mkdir -p "$STATE_DIR"

#───────────────────────────────────────────────────────────────────────────────
# Helpers
#───────────────────────────────────────────────────────────────────────────────

_ppid_of() { awk '/^PPid:/ {print $2}' "/proc/$1/status" 2>/dev/null || echo 0; }
_comm_of() { cat "/proc/$1/comm" 2>/dev/null || echo "?"; }

# Walk from a PID up the process tree until we find a process whose comm
# matches the target. Returns that PID, or empty string.
_find_ancestor() {
    local pid=$1 target=$2
    while (( pid > 1 )); do
        pid=$(_ppid_of "$pid")
        if [[ "$(_comm_of "$pid")" == "$target" ]]; then
            echo "$pid"
            return 0
        fi
    done
    return 1
}

# Get full command line for a PID
_cmdline_of() {
    tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | sed 's/ $//'
}

#───────────────────────────────────────────────────────────────────────────────
# save
#───────────────────────────────────────────────────────────────────────────────
cmd_save() {
    echo "respawn: saving state..."

    # 1. Trigger tmux-resurrect save
    if [[ -x "$RESURRECT_SAVE" ]]; then
        bash "$RESURRECT_SAVE" || echo "warning: resurrect save returned non-zero"
    else
        echo "warning: resurrect save script not found, skipping"
    fi

    # 2. Capture Hyprland state
    local clients monitors workspaces
    clients=$(hyprctl clients -j)
    monitors=$(hyprctl monitors -j)
    workspaces=$(hyprctl workspaces -j)

    # 3. Build tmux-client → alacritty PID map
    # tmux list-clients gives us: /dev/pts/N <client_pid> <session_name>
    declare -A alacritty_to_session=()
    while IFS=' ' read -r _ client_pid session_name; do
        [[ -z "$client_pid" ]] && continue
        local ala_pid
        ala_pid=$(_find_ancestor "$client_pid" "alacritty") || true
        if [[ -n "$ala_pid" ]]; then
            alacritty_to_session[$ala_pid]="$session_name"
        fi
    done < <(tmux list-clients -F '#{client_name} #{client_pid} #{session_name}' 2>/dev/null)

    # 4. Build per-tmux-session detail
    local sessions_json="[]"
    while IFS= read -r sname; do
        [[ -z "$sname" ]] && continue
        local active_window
        active_window=$(tmux display-message -t "$sname" -p '#{window_index}' 2>/dev/null || echo "1")

        local windows_json="[]"
        while IFS=$'\t' read -r windex wname wlayout; do
            local panes_json="[]"
            while IFS=$'\t' read -r pindex ppath pcmd ppid; do
                local full_cmd
                full_cmd=$(_cmdline_of "$ppid")
                panes_json=$(jq -c --arg idx "$pindex" --arg path "$ppath" \
                    --arg cmd "$pcmd" --arg pid "$ppid" --arg full "$full_cmd" \
                    '. + [{index: ($idx|tonumber), path: $path, command: $cmd, pid: ($pid|tonumber), full_command: $full}]' \
                    <<< "$panes_json")
            done < <(tmux list-panes -t "$sname:$windex" \
                -F '#{pane_index}	#{pane_current_path}	#{pane_current_command}	#{pane_pid}' 2>/dev/null)

            windows_json=$(jq -c --arg idx "$windex" --arg name "$wname" \
                --arg layout "$wlayout" --argjson panes "$panes_json" \
                '. + [{index: ($idx|tonumber), name: $name, layout: $layout, panes: $panes}]' \
                <<< "$windows_json")
        done < <(tmux list-windows -t "$sname" \
            -F '#{window_index}	#{window_name}	#{window_layout}' 2>/dev/null)

        sessions_json=$(jq -c --arg name "$sname" --arg aw "$active_window" \
            --argjson windows "$windows_json" \
            '. + [{name: $name, active_window: ($aw|tonumber), windows: $windows}]' \
            <<< "$sessions_json")
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)

    # 5. Build Alacritty windows array (with tmux session mapping)
    local alacritty_windows="[]"
    local pids
    pids=$(jq -r '.[] | select(.class == "Alacritty") | .pid' <<< "$clients")
    for apid in $pids; do
        local session_name="${alacritty_to_session[$apid]:-}"
        local win_info
        win_info=$(jq -c --arg pid "$apid" --arg sess "$session_name" \
            '[.[] | select(.class == "Alacritty" and (.pid|tostring) == $pid)] |
             .[0] + {tmux_session: $sess}' <<< "$clients")
        alacritty_windows=$(jq -c --argjson w "$win_info" '. + [$w]' <<< "$alacritty_windows")
    done

    # 6. Build Brave windows array
    local brave_windows
    brave_windows=$(jq -c '[.[] | select(.class == "brave-browser") |
        {title, workspace: .workspace.id, monitor, floating, at, size}]' <<< "$clients")

    # 7. All other windows (Slack, etc.) for reference
    local other_windows
    other_windows=$(jq -c '[.[] | select(.class != "Alacritty" and .class != "brave-browser") |
        {class, title, workspace: .workspace.id, monitor, floating, at, size, pid}]' <<< "$clients")

    # 8. Write state file
    local timestamp
    timestamp=$(date -Iseconds)
    jq -n \
        --arg ts "$timestamp" \
        --argjson monitors "$monitors" \
        --argjson workspaces "$workspaces" \
        --argjson sessions "$sessions_json" \
        --argjson alacritty "$alacritty_windows" \
        --argjson brave "$brave_windows" \
        --argjson other "$other_windows" \
        '{
            timestamp: $ts,
            monitors: $monitors,
            workspaces: $workspaces,
            tmux_sessions: $sessions,
            alacritty_windows: $alacritty,
            brave_windows: $brave,
            other_windows: $other
        }' > "$STATE_FILE"

    echo "respawn: saved to $STATE_FILE"
    echo "  $(jq '.alacritty_windows | length' "$STATE_FILE") alacritty windows"
    echo "  $(jq '.tmux_sessions | length' "$STATE_FILE") tmux sessions"
    echo "  $(jq '.brave_windows | length' "$STATE_FILE") brave windows"
    echo "  $(jq '.other_windows | length' "$STATE_FILE") other windows"
}

#───────────────────────────────────────────────────────────────────────────────
# restore
#───────────────────────────────────────────────────────────────────────────────
cmd_restore() {
    echo "respawn: restoring state..."

    if [[ ! -f "$STATE_FILE" ]]; then
        echo "respawn: no saved state found at $STATE_FILE"
        exit 1
    fi

    # 1. Wait for Hyprland IPC
    echo "respawn: waiting for Hyprland..."
    local attempts=0
    while ! hyprctl monitors -j &>/dev/null; do
        (( attempts++ ))
        if (( attempts > 30 )); then
            echo "respawn: Hyprland not ready after 30s, aborting"
            exit 1
        fi
        sleep 1
    done
    echo "respawn: Hyprland is ready"

    # 2. Start tmux server; continuum should auto-restore
    echo "respawn: starting tmux server..."
    tmux start-server 2>/dev/null || true
    sleep 2

    # 3. Check if sessions were restored; if not, trigger resurrect manually
    local session_count
    session_count=$(tmux list-sessions 2>/dev/null | wc -l)
    if (( session_count == 0 )); then
        echo "respawn: no sessions found, waiting for continuum..."
        local waited=0
        while (( waited < 15 )); do
            sleep 1
            (( waited++ ))
            session_count=$(tmux list-sessions 2>/dev/null | wc -l)
            if (( session_count > 0 )); then
                break
            fi
        done
    fi

    if (( session_count == 0 )) && [[ -x "$RESURRECT_RESTORE" ]]; then
        echo "respawn: triggering manual resurrect restore..."
        bash "$RESURRECT_RESTORE" || echo "warning: resurrect restore returned non-zero"
        sleep 3
    fi

    echo "respawn: $(tmux list-sessions 2>/dev/null | wc -l) tmux sessions available"

    # 4. Restore Alacritty windows sorted by workspace
    local alacritty_windows
    alacritty_windows=$(jq -c '.alacritty_windows | sort_by(.workspace.id)' "$STATE_FILE")
    local win_count
    win_count=$(jq 'length' <<< "$alacritty_windows")

    for (( i=0; i<win_count; i++ )); do
        local win
        win=$(jq -c ".[$i]" <<< "$alacritty_windows")

        local session workspace token
        session=$(jq -r '.tmux_session // empty' <<< "$win")
        workspace=$(jq -r '.workspace.id' <<< "$win")
        token="respawn-$(date +%s%N)-$i"

        if [[ -z "$session" ]]; then
            echo "respawn: skipping alacritty window with no tmux session (workspace $workspace)"
            continue
        fi

        # Check the session actually exists
        if ! tmux has-session -t "$session" 2>/dev/null; then
            echo "respawn: tmux session '$session' not found, skipping"
            continue
        fi

        echo "respawn: opening $session on workspace $workspace"

        # Inject a temporary window rule to place on the right workspace
        hyprctl --batch "keyword windowrulev2 workspace $workspace silent,initialTitle:$token" &>/dev/null

        # Launch alacritty with the token as initial title, attaching to the session
        alacritty -T "$token" -e tmux attach-session -t "$session" &
        local ala_pid=$!

        # Wait for the window to appear (up to 5s)
        local appeared=0
        for (( w=0; w<50; w++ )); do
            if hyprctl clients -j | jq -e --arg t "$token" '.[] | select(.initialTitle == $t)' &>/dev/null; then
                appeared=1
                break
            fi
            sleep 0.1
        done

        if (( !appeared )); then
            echo "respawn: warning: window for $session did not appear"
        fi

        # Clean up the temporary window rule
        hyprctl keyword windowrulev2 "unset,initialTitle:$token" &>/dev/null || true
    done

    # 5. Launch Brave (it restores its own session)
    local brave_count
    brave_count=$(jq '.brave_windows | length' "$STATE_FILE")
    if (( brave_count > 0 )); then
        echo "respawn: launching Brave..."
        brave &>/dev/null &
        disown

        # 6. Wait for Brave windows, then move to saved workspaces
        echo "respawn: waiting for Brave windows..."
        sleep 5

        # Move Brave windows to their saved workspaces by title matching
        local brave_wins
        brave_wins=$(jq -c '.brave_windows' "$STATE_FILE")
        local bcount
        bcount=$(jq 'length' <<< "$brave_wins")

        for (( i=0; i<bcount; i++ )); do
            local saved_title saved_ws
            saved_title=$(jq -r ".[$i].title" <<< "$brave_wins")
            saved_ws=$(jq -r ".[$i].workspace" <<< "$brave_wins")

            # Find a matching Brave window by substring of title
            # Use first significant words of the title for matching
            local match_addr
            match_addr=$(hyprctl clients -j | jq -r --arg t "$saved_title" \
                '.[] | select(.class == "brave-browser" and .title == $t) | .address' | head -1)

            if [[ -n "$match_addr" ]]; then
                hyprctl dispatch movetoworkspacesilent "$saved_ws,address:$match_addr" &>/dev/null || true
            fi
        done
    fi

    echo "respawn: restore complete"
}

#───────────────────────────────────────────────────────────────────────────────
# shutdown / reboot
#───────────────────────────────────────────────────────────────────────────────
cmd_shutdown() {
    cmd_save
    echo "respawn: shutting down..."
    systemctl poweroff
}

cmd_reboot() {
    cmd_save
    echo "respawn: rebooting..."
    systemctl reboot
}

#───────────────────────────────────────────────────────────────────────────────
# status
#───────────────────────────────────────────────────────────────────────────────
cmd_status() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "respawn: no saved state"
        exit 0
    fi

    local ts ala_count sess_count brave_count other_count
    ts=$(jq -r '.timestamp' "$STATE_FILE")
    ala_count=$(jq '.alacritty_windows | length' "$STATE_FILE")
    sess_count=$(jq '.tmux_sessions | length' "$STATE_FILE")
    brave_count=$(jq '.brave_windows | length' "$STATE_FILE")
    other_count=$(jq '.other_windows | length' "$STATE_FILE")

    echo "respawn: saved state"
    echo "  timestamp:  $ts"
    echo "  alacritty:  $ala_count windows"
    echo "  tmux:       $sess_count sessions"
    echo "  brave:      $brave_count windows"
    echo "  other:      $other_count windows"

    echo ""
    echo "  tmux sessions:"
    jq -r '.tmux_sessions[] | "    \(.name) (\(.windows | length) windows, active: \(.active_window))"' "$STATE_FILE"

    echo ""
    echo "  alacritty → tmux mapping:"
    jq -r '.alacritty_windows[] | "    workspace \(.workspace.id): \(.tmux_session // "detached") (pid \(.pid))"' "$STATE_FILE"

    echo ""
    echo "  brave windows:"
    jq -r '.brave_windows[] | "    workspace \(.workspace): \(.title | .[0:60])"' "$STATE_FILE"

    if (( other_count > 0 )); then
        echo ""
        echo "  other windows:"
        jq -r '.other_windows[] | "    workspace \(.workspace): \(.class) — \(.title | .[0:60])"' "$STATE_FILE"
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# Main
#───────────────────────────────────────────────────────────────────────────────
case "${1:-}" in
    save)     cmd_save ;;
    restore)  cmd_restore ;;
    shutdown) cmd_shutdown ;;
    reboot)   cmd_reboot ;;
    status)   cmd_status ;;
    *)
        echo "Usage: respawn {save|restore|shutdown|reboot|status}"
        exit 1
        ;;
esac
