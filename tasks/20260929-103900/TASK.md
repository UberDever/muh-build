# Path case on case-insensitive filesystems

- STATUS: OPEN
- PRIORITY: 100
- TAGS:
- KIND: TASK
- PARENT: 20260927-074554

- (agent, 2026-09-29) On macOS and Windows filesystems (case-insensitive by default), a path in a
  depfile may differ in case from the same path as `scan` reports it. The snapshot looks paths up by
  exact string, so such a header would miss the snapshot and fall back to `host.stat`, or, where it
  compares paths (`domain.is_within`), be treated as outside its tree. Background: `20260927-074554/platforms.md`.
- Open (agent): normalize case in the macOS and Windows hosts, or in the snapshot, or declare it a
  host property (`host.case_insensitive`) that the core consults.
- Done when: the macOS and Windows hosts exist and a test on each shows a depfile path in another case
  is still found in the snapshot.
