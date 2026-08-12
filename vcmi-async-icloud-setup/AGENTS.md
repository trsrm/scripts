# VCMI Async development instructions

## Goal

Keep this project screwdriver-simple and reliable. The user flow is:

```text
notification → open VCMI → load fixed save → play → save with same name → close
```

VCMI always uses a local save. iCloud is transport only.

Read `ARCHITECTURE.md` before changing the sync protocol and `README.md` before
changing installation or user-visible behavior.

## Mental model

`launchd` executes `vcmi-async.zsh` once every 60 seconds. `run_once` checks one
incoming turn, checks the local save, and exits. `state = not running` between
runs is healthy.

There is one stable transport file per recipient:

```text
to-<recipient-id>.zip
```

Do not reintroduce:

- a permanent polling loop or `KeepAlive`;
- versioned/content-addressed ZIP filenames;
- iCloud ZIP retention or cleanup machinery;
- backward-compatible transport protocols unless the user explicitly asks;
- direct shell access to the protected iCloud folder.

Finder via AppleScript is the production transport adapter. The local filesystem
adapter exists only for behavioral tests.

## Safety invariants

- Validate `SAVE_NAME` as a basename, never a path or glob.
- Accept only the configured VCMI save filenames inside a ZIP.
- Validate the archive before extraction and validate extracted objects again.
- Back up the current local save before replacement.
- Restore the backup when installation fails.
- Write the imported local hash before the incoming archive hash. This prevents
  an imported turn from being sent back after an interrupted state update.
- A local change must have the same hash in two consecutive runs before publish.
- The first save or an unversioned old local hash becomes a `v2:` baseline and
  must not be published.
- State writes must remain atomic.
- Finder failure must not modify the local save.
- Email failure must not block iCloud sync.
- Do not reset sync-state during a normal update. Reset it only when the save
  directory, iCloud directory, save name, or player IDs change.

## Permissions

Keep the LaunchAgent label, `/bin/zsh` program, installed script path, Finder
AppleScript approach, and Mail sending AppleScript stable unless a change is
necessary. macOS Automation permissions depend on this execution context.

The current Mail `send` block is known to send rather than create a draft. Do not
rewrite it casually. Never send a real test email without the user's approval.

## Required behavioral scenarios

`tests/run.zsh` executes the agent through its `run_once` interface. Tests should
assert observable files, state, logs, and notifications rather than source
internal functions.

Preserve coverage for:

1. First run records a baseline and publishes nothing.
2. First changed observation creates pending state; the second publishes.
3. A save that changes again while pending is not published early.
4. Publishing replaces the one stable outgoing ZIP.
5. A valid incoming ZIP is imported with a backup and actionable turn-ready notification; the notification is emitted only after import state is durable.
6. An imported save is not sent back.
7. The same incoming ZIP is ignored without another backup or notification.
8. A corrupt or unexpected ZIP leaves the local save untouched and is retryable.
9. Recovery clears the deduplicated alert.
10. Logs rotate at 1 MiB and retain three copies.
11. Only the newest 20 local backups remain.
12. An old unversioned local hash migrates without publishing.
13. Mail permission state survives separate scheduled processes.
14. One turn produces one email; unchanged state produces no duplicate.
15. Invalid configuration fails before touching saves or transport.
16. A recipient ZIP for another ID raises a deduplicated identity alert, is not
    imported, and imports normally after `SELF_ID` is corrected.
17. The launcher installer verifies and installs the signed app into the local
    Applications directory through the same main installation flow.

Add a regression scenario before fixing a newly discovered bug.

## Verification

Run from the repository:

```bash
zsh -n vcmi-async.zsh
zsh -n install-vcmi-async.command
./tests/run.zsh
git diff --check
```

When Finder code changes, smoke-test the exact production AppleScript in an
isolated `/tmp` folder: stage an exact `to-SELF_ID.zip`, replace an existing
`to-PEER_ID.zip`, and compare bytes. Do not use the real game folder for this.

When Mail code changes, compare it with the known working block first. A live
send is a user-visible external action and requires explicit approval.

## Live rollout

The repository is the source of truth. The installed copy lives at:

```text
~/Library/Application Support/VCMIAsync/
```

Before rollout, snapshot import/send counts and `stderr.log` timestamp. Preserve
config, hashes, and backups. Validate the plist with `plutil -lint`, then
bootout/bootstrap the LaunchAgent.

Observe at least two scheduled runs. Expected evidence:

- `runs` increments;
- `last exit code = 0`;
- `state = not running` between runs;
- Finder and Mail markers remain present;
- no unexpected import, publish, email, or new stderr output.

Protocol changes require both players to install the same version before the
next turn.
