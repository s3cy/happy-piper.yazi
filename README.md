# happy-piper.yazi

A lockless re-imagining of [`faster-piper.yazi`](https://github.com/alberti42/faster-piper.yazi).

Refer to the upstream README for installation, configuration syntax, preview-command variables (`$1`, `$w`, `$h`), `--format=url`, `--rely-on-preloader`, the jump-to-top/bottom seek heuristic, and recommended keymaps. `happy-piper` is a drop-in replacement: rename `faster-piper` to `happy-piper` in your rules.

## Differences from `faster-piper`

- **No lock.** `faster-piper` serialises cache writes with a directory-based lock and a 60-second TTL. Coroutine cancellation (e.g. on terminal resize) can orphan the lock and produce a multi-second `locked-timeout` stall. `happy-piper` removes the lock entirely.
- **Atomic-publish cache generation.** Each generator writes to a per-call temp file (suffixed with the spawned shell's PID) and publishes via `rename(2)`. Readers always observe either the previous cache or the new one — never a partial. Concurrent generators are tolerated; the later rename wins. Worst case during a race: one redundant generator invocation, instead of a stall.
- **Single peek flow.** The `if rely_on_preloader then wait_for_lock else regenerate` split in `peek()` is gone. One path: fresh → render; not fresh → regenerate (or, with `--rely-on-preloader` on a cold file with no recipe in args, render `warming up…` and let the preloader populate).
- **Preloaders are optional.** With the lock removed, preloaders are purely an anticipatory latency optimisation — not a coordination primitive. You can omit `prepend_preloaders` entirely; `peek()` will generate on demand.

Configuration syntax, behaviour, and the on-disk cache header layout are otherwise identical.

## License

MIT. Inherits all credit and design lineage from [`faster-piper`](https://github.com/alberti42/faster-piper.yazi) and, transitively, [`piper.yazi`](https://github.com/yazi-rs/plugins/tree/main/piper.yazi).
# happy-piper.yazi
