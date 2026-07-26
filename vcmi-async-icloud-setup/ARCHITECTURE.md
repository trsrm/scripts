# VCMI Async architecture

## Mental model

The system is a scheduled command, not a daemon:

```text
launchd every 60 seconds → run_once → exit
```

VCMI uses a local save. iCloud is transport only.

## Interface

The module has one external interface: execute `vcmi-async.zsh` once with a valid
`config.zsh`. It performs at most one incoming import and one outgoing check,
then exits.

Tests use the same interface with the local filesystem adapter. Production uses
the Finder adapter because `launchd` may not access a shared iCloud folder
directly.

## Protocol

```text
to-<recipient-id>.zip
```

There is one stable file per recipient. Publishing replaces it. The receiver
compares its SHA-256 with `last-incoming-archive-hash`.

## Incoming

1. Finder copies `to-SELF_ID.zip` to local staging.
2. Ignore it when its SHA-256 was already imported.
3. Validate archive integrity and every member name before extraction.
4. Extract to staging and reject directories, links and unexpected files.
5. Back up the current save.
6. Install the new save, restoring the backup on failure.
7. Persist the imported local hash before the archive hash.
8. Notify the player.

Writing the local hash first prevents an interrupted state update from sending
the imported save back.

## Outgoing

1. Hash the configured local save files.
2. The first observed change becomes `pending-local-hash`.
3. A matching hash on the next run is copied to staging.
4. Verify the staged hash, create and validate the ZIP.
5. Finder replaces `to-PEER_ID.zip`.
6. Persist `last-local-hash`, send email when enabled, and notify the player.

The pending state replaces sleeps and file-signature polling.

## Bounded local storage

- logs rotate at 1 MiB and retain three copies;
- the newest 20 save backups are retained;
- staging older than one day is removed;
- iCloud contains only the two stable transport ZIPs.

## Invariants

- save names are basenames, never paths or globs;
- player IDs are distinct and contain only `[a-z0-9_-]`;
- received ZIPs contain only the configured save filenames;
- the previous save is backed up before replacement;
- state files are atomically replaced;
- changing the sync identity resets state but not backups or configuration.
