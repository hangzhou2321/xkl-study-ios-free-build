# CPocket snapshot v1

The bridge runs the copied v8 whole-word C model and recording code without
algorithm edits. `source-manifest.json` records the SHA-256 of all 13 copied
files. The bridge holds cards and a 2 MiB event buffer in iOS memory; a future
microcontroller implementation should stream its Flash partitions instead.

All integer fields below are unsigned little-endian, with no C padding. The
maximum size is bounded by the original 21,802-event log capacity. CRC is
IEEE CRC32 (`0xedb88320`, initial and final XOR `0xffffffff`).

| Offset | Bytes | Value |
|---:|---:|---|
| 0 | 4 | Magic `0x534c4b58` (`XKLS`) |
| 4 | 4 | Format version 1 |
| 8 | 4 | Header length 96 |
| 12 | 4 | Word deck ID `0x6509be5b` |
| 16 | 4 | Whole-word algorithm 3 |
| 20 | 4 | Card count 25,644 |
| 24 | 4 | Checkpoint length 2,316 |
| 28 | 4 | Original log prefix length: `4096 + 96 * record_count` |
| 32 | 4 | Total snapshot length |
| 36 | 4 | Runtime flags: bit 0 booted, 1 presented, 2 revealed, 3 resumed_next |
| 40 | 4 | Recording session sequence |
| 44 | 4 | Presentation sequence, or `UINT32_MAX` |
| 48 | 8 | Presentation monotonic microseconds |
| 56 | 8 | Reveal monotonic microseconds |
| 64 | 8 | Last accepted monotonic microseconds |
| 72 | 24 | Reserved, must be zero |
| 96 | 2,316 | Original schema-7 checkpoint, explicitly encoded field by field |
| 2,412 | 102,576 | 25,644 original packed word values in unchanged ID order |
| 104,988 | variable | Original event-log header and occupied record prefix |
| total - 4 | 4 | CRC32 of every preceding snapshot byte |

A newly seeded snapshot is 109,088 bytes and contains no invented historical
events. The original 2 MiB personal state is opened read-only with the original
storage reader. Every nonzero historical card and the original checkpoint are
preserved. New logs use a caller-provided random 16-byte stream identity.

Restore rejects wrong version/deck/count/length, reserved bits, broken CRCs,
invalid original checkpoints/cards, disagreement between active cards and the
card table, pending/uncommitted events, broken event revision/checksum chains,
and runtime presentation state inconsistent with the log. It accepts only the
committed state produced by this bridge; interrupted raw Flash transactions
must first be recovered by the original device storage implementation.

Runtime values exist so a failed atomic save can restore exactly the previous
local presentation. **After cold launch, clock discontinuity or a device
handoff, call `xkl_engine_start` before permitting grades.** Start resets the
session and reveal state and emits BOOT/START/PRESENT as appropriate. A new
monotonic clock is allowed only at that explicit boundary.

Every operation is serialized by the app. The app snapshots before a change,
performs it, saves the resulting bytes atomically, and publishes UI changes
only after persistence succeeds. Failed persistence must restore the previous
snapshot. The bridge reserves log space before each operation; it does not
erase or overwrite events when the log reaches capacity.

`xkl_engine_log` returns the compact original binary prefix. For tools expecting
the complete original event partition, append `0xff` bytes to exactly 2 MiB.
The original stream ID and event sequence numbers continue across a handoff.
