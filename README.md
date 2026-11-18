# Emacs configuration

Emacs with a JetBrains flavor and tight pi integration, configured to replace GoLand.

## Keyboard shortcuts

`C-` means Ctrl, `M-` means Alt/Option, and `s-` means Command on macOS.
`RET` means Enter, `SPC` means Space, and `S-` means Shift. Spaces between
shortcuts indicate a sequence: `C-c t` means press Ctrl+C, release, then press
`t`. Letters refer to the English keyboard layout. Instead of holding Meta,
you can press `Esc` followed by the key.

### Custom bindings and settings

All bindings explicitly assigned by this configuration are listed below.
Useful package defaults are listed separately in the shell table.

| Shortcut | Context / action |
| --- | --- |
| `C-c o` | Open a folder as a project in its own tab, or switch to its existing tab. |
| `C-x p p` | Choose a known project; this configuration binds it to `my-project-switch`. |
| `C-c h` | Switch to the `Start` tab. |
| `C-c q` | Close the current project tab; `Start` is protected from closing. |
| `C-c TAB o` | Alternative binding for opening a project. |
| `C-c TAB k` | Alternative binding for closing a project tab. |
| `C-c p o` | Find and open a file in the current project by name/path. |
| `RET` in file search | Open the selected result. Wait if the list is still empty while indexing. |
| `C-c p f` | Copy the current file's absolute path. |
| `C-c p r` or `C-u C-c p f` | Copy the file's path relative to the project root. |
| `F8` | Show or hide the Treemacs tree. |
| `C-c w` | Open the current project's working copy / worktree picker. |
| `C-c v` | Show repository status: Arcit for Arc, standard `vc-dir` for Git and other backends. |
| `C-c b` | Toggle inline blame annotations for the current file. |
| `Command` + left-click on a symbol | Find references to the symbol in code and open the `References` popup. |
| `C-c a` | Open/focus the Pi panel on the right; hide it when invoked from the panel. |
| `C-c t` | Open/focus the shell across the bottom of the frame; hide it without stopping the process when invoked from the shell. |
| `C-u C-c t` | Select a named shell session or create a new one. |
| `C-c C-x C-m` | Toggle Markdown editing and preview. |

**Worktree and Pi chat pickers**

| Shortcut | Action |
| --- | --- |
| `TAB` / `↓` | Select the next button or entry. |
| `Shift+TAB` / `↑` | Select the previous button or entry. |
| `RET` | Run the selected action; from the search field, run the first available action. |
| `C-s` in the worktree picker | From the copy list, search for a branch for a new copy; while searching, return focus to the search field. |
| `C-s` in Pi history | Return focus to the chat search field. |
| `Esc` / `C-g` | Close the picker. |

**Popups and mouse actions**

| Action | Result |
| --- | --- |
| `↑` / `↓` in `References` | Select the previous/next result without opening the file. |
| `RET` in `References` | Open the result and close the popup. |
| `Esc` / `C-g` in `References` | Close the popup. |
| `Esc` / `C-g` / `q` in the Messages or Eglot log popup | Close the popup. |
| Middle-click in Dired | Open the file under the pointer. |
| Click a marker in the file overview strip | Jump to the corresponding line. |
| Click the toggle in the Markdown header | Switch between preview and editing. |
| Drag the worktree / chat picker header | Move the popup. |
| Double-click / drag to select in the shell | Automatically copy the word / selected text to the system clipboard. Empty selections leave the clipboard unchanged. |
| Click a path or URL in the shell | Automatic opening is disabled. |

**Shell: useful Ghostel defaults and zsh bindings**

In input mode, many keys go to the program running inside the terminal.
For example, `C-r` searches command history in zsh, while Vim uses its own bindings.

| Shortcut | Action |
| --- | --- |
| `C-r` in zsh | Search backward through command history. |
| `↑` / `↓` in zsh | Previous/next command, or move between lines in multiline input. |
| `C-c C-c` | Send Ctrl+C to the terminal program. |
| `C-c C-d` | Send Ctrl+D (EOF; exits zsh at an empty prompt). |
| `C-c C-z` | Send Ctrl+Z (suspend the foreground process). |
| `C-c C-t` | Enter copy mode: freeze the display for browsing and selection. |
| `C-c C-j` | Return to Ghostel's normal input mode. |
| `C-c C-y` | Paste text from the kill ring / clipboard into the terminal. |
| `C-c M-w` | Copy the entire terminal scrollback buffer. |
| `C-c M-p` / `C-c M-n` | Jump to the previous/next shell prompt. |
| `C-c C-q` | Send the next key directly to the terminal program. |

### Basic Emacs shortcuts

These are standard Emacs commands in the editor. Local modes can override them;
`C-h k` shows what a shortcut does in the current buffer. A buffer holds an open
file or a utility view; a window is the area displaying it. Project tabs sit above
the windows.

| Shortcut | Action |
| --- | --- |
| `M-x` | Run a command by name, such as `goto-line`. |
| `C-g` | Cancel the current command or input. |
| `C-u` before a command | Supply a prefix argument; its meaning depends on the command. |
| `C-x C-f` | Open a file by path. |
| `C-x C-s` | Save the current file. |
| `C-x s` | Offer to save modified file buffers. |
| `C-x C-w` | Save the current buffer under another name. |
| `C-x b` | Switch buffers; Tabspaces restricts the selection to the current workspace in this configuration. |
| `C-x k` | Close a buffer, asking for confirmation if its file has unsaved changes. |
| `C-x ←` / `C-x →` | Previous/next buffer in the current window. |
| `C-/` or `C-x u` | Undo a change. |
| `C-?` | Redo an undone change (`undo-redo`). |
| `C-SPC` | Set the start of a selection, then move the cursor. |
| `C-x h` | Select the entire buffer. |
| `M-w` | Copy the selection. |
| `C-w` | Cut the selection. |
| `C-y` | Paste. |
| `M-y` immediately after pasting | Replace the pasted text with an earlier kill ring entry. |
| `C-k` | Cut to the end of the line; at the end of a line, cut the newline. |
| `C-s` / `C-r` | Incremental search forward/backward; repeat the shortcut to find the next match. |
| `RET` during search | Finish searching at the current match. |
| `M-%` | Query replace: `y` replaces, `n` skips, `!` replaces all remaining matches. |
| `M-g g` or `M-g M-g` | Go to a line: enter its number and press `RET`. |
| `C-a` / `C-e` | Beginning/end of the line. |
| `M-b` / `M-f` | Move backward/forward by a word. |
| `M-<` / `M->` | Beginning/end of the buffer. |
| `C-v` / `M-v` | Scroll forward/backward by a screen. |
| `M-.` | Go to a symbol's definition (requires xref support, such as Eglot). |
| `M-?` | Find references to a symbol. |
| `M-,` | Go back after navigating to a definition/reference. |
| `M-g n` / `M-g p` | Next/previous error or result through `next-error`. |
| `C-x 2` | Split the window, placing the new window below. |
| `C-x 3` | Split the window, placing the new window on the right. |
| `C-x 0` | Close the current window, keeping its buffer. |
| `C-x 1` | Keep one main window; our protected side panels may remain. |
| `C-x o` | Switch to the next window; shell and Pi panels are excluded, so use `C-c t` and `C-c a` for them. |
| `C-x t o` | Switch to the next tab in the top bar. |
| `C-x t 2` | Create a regular Emacs tab; use `C-c o` for a project. |
| `C-x t 0` | Close the current tab. |
| `C-h k`, then a shortcut | Describe the shortcut. |
| `C-h b` | List available bindings in the current buffer. |
| `C-h m` | Show help for the current modes and their bindings. |
| `C-h t` | Open the built-in Emacs tutorial. |
| `C-h e` | Open the `*Messages*` log. |
| `C-x C-c` | Exit Emacs, offering to save modified files. |

### Storage

- Copies: `<user-emacs-directory>/worktree/{git,arc}/<project>-<id>/<branch-slug>-<id>/`
  (ignored by Git and excluded from file search and the tree).
- Registry: `logical_projects` and `working_copies` tables in `pi/chats.sqlite`
  (schema version 2). `chats.project_root` stays the agent's working directory.
- The version 1 → 2 migration is additive and transactional. Before it runs, a
  `VACUUM INTO` backup is written to `pi/backups/chats-v1-*.sqlite`.

### Arc limitations

Arc worktrees created or mounted by this configuration use `--allow-other`,
allowing other local users (including root) to access the FUSE filesystem.
Already mounted worktrees are left running with their existing mount options.

Each mount gets its own store, and mounts do not share local branches or
unpublished commits (checked with arc `21480566`). A new Arc copy can therefore
start only from a published revision. Otherwise creation stops in a `failed`
state with an explanation, and the copy can be retried or deleted. A new copy
of an unpublished local branch is refused for the same reason. `--forget` is
refused unless every local branch in that store, `trunk` included, is at a
published commit (its remote-tracking ref, the remote head, or the verified start
commit) or is an ancestor of its upstream, and the store has no stashes or changes.
An Arc copy only counts as available when Arc lists it as mounted with its
recorded store; an empty mount-point directory does not.

