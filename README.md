# Emacs configuration

Emacs with a JetBrains flavor and tight pi integration, configured to replace GoLand.

### Storage

- Copies: `<user-emacs-directory>/worktree/{git,arc}/<project>-<id>/<branch-slug>-<id>/`
  (ignored by Git and excluded from file search and the tree).
- Registry: `logical_projects` and `working_copies` tables in `pi/chats.sqlite`
  (schema version 2). `chats.project_root` stays the agent's working directory.
- The version 1 → 2 migration is additive and transactional. Before it runs, a
  `VACUUM INTO` backup is written to `pi/backups/chats-v1-*.sqlite`.

### Arc limitations

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

