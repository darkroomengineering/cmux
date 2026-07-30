import Foundation

#if DEBUG
/// In-process accumulator of individual duration samples, keyed by a caller-chosen
/// bucket name, with percentile stats computed on read.
///
/// This exists because `ProgramaMainThreadTurnProfiler` (see `TypingProfiler.swift`)
/// aggregates per run-loop turn and resets its buckets on every `.entry`/`.afterWaiting`
/// activity — it can answer "how much time did bucket X take this turn" but not
/// "what is the p95 of bucket X across the last 200 keystrokes". This class answers
/// the latter by keeping every sample around (up to a cap) until explicitly reset.
///
/// Gating: reuses `ProgramaTypingTiming.isEnabled` rather than introducing a third
/// env var. Setting `PROGRAMA_TYPING_TIMING_LOGS=1` or `PROGRAMA_KEY_LATENCY_PROBE=1`
/// (or the matching UserDefaults keys) enables both the existing dlog instrumentation
/// and duration-sample recording, so there is a single knob for main-thread timing
/// instrumentation rather than a proliferation of flags. `record` is a no-op when
/// disabled, so the hot path costs one static-bool check when not in use.
///
/// Threading: `record` is main-thread-only, matching its sole call site (the
/// `keyDown` text-input refresh path, which always runs on the main thread). This is
/// asserted, not locked — adding a lock to a per-keystroke hot path to guard against
/// a call pattern that cannot currently occur would be the wrong tradeoff. `stats`,
/// `reset`, and `bucketNames` are not thread-safe either; callers reading from a
/// background thread (e.g. a socket command handler) must hop onto the main thread
/// first, the same way `record` is only ever invoked there.
///
/// Capping: each bucket stops recording once it reaches `maxSamplesPerBucket`
/// (10,000) rather than overwriting ring-buffer style. A dropped-tail cap keeps the
/// hot-path check to a single `count < capacity` comparison (no modulo index
/// bookkeeping), and the intended use (bounded test/profiling runs of a few hundred
/// keystrokes between resets) never gets near the cap in practice — it exists purely
/// so an accidentally long-running DEBUG session with sampling left on cannot grow a
/// bucket's array without bound.
final class ProgramaDurationSamples {
    static let shared = ProgramaDurationSamples()

    private static let maxSamplesPerBucket = 10_000

    private var buckets: [String: [Double]] = [:]

    private init() {}

    /// Records one duration sample for `bucket`. Cheap and allocation-free once the
    /// bucket's backing array has grown to its steady-state size (capacity is
    /// reserved up front on first use of a bucket). No-op when
    /// `ProgramaTypingTiming.isEnabled` is false, or once the bucket has reached
    /// `maxSamplesPerBucket` samples.
    @inline(__always)
    func record(_ bucket: String, milliseconds: Double) {
        guard ProgramaTypingTiming.isEnabled else { return }
        assert(Thread.isMainThread, "ProgramaDurationSamples.record must be called from the main thread")

        // Mutate the stored array in place through the dictionary's `subscript(_:default:)`
        // `_modify` accessor.
        //
        // Binding it to a local first -- `var values = buckets[bucket]; values.append(...);
        // buckets[bucket] = values` -- leaves the dictionary holding a second reference to
        // the same buffer, so the append triggers copy-on-write and copies the WHOLE array.
        // That is an allocation plus an O(count) memcpy on every keystroke, on the exact
        // path this type exists to measure: the sampler would perturb its own samples.
        buckets[bucket, default: Self.makeBucket()].appendCapped(
            milliseconds,
            cap: Self.maxSamplesPerBucket
        )
    }

    /// A fresh bucket with capacity reserved up front, so appends do not reallocate
    /// as it fills.
    private static func makeBucket() -> [Double] {
        var array: [Double] = []
        array.reserveCapacity(maxSamplesPerBucket)
        return array
    }

    /// Returns count/p50/p95/p99/max/mean for `bucket`, or `nil` if no samples have
    /// been recorded for it. Percentiles are computed here (on read), never on write.
    func stats(for bucket: String) -> (count: Int, p50: Double, p95: Double, p99: Double, maxMs: Double, meanMs: Double)? {
        guard let values = buckets[bucket], !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let count = sorted.count
        let mean = sorted.reduce(0, +) / Double(count)
        let maxMs = sorted[count - 1]

        func percentile(_ p: Double) -> Double {
            if count == 1 { return sorted[0] }
            let idx = Double(count - 1) * p
            let lower = Int(idx)
            let upper = min(lower + 1, count - 1)
            let fraction = idx - Double(lower)
            return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
        }

        return (count, percentile(0.50), percentile(0.95), percentile(0.99), maxMs, mean)
    }

    /// Clears samples for `bucket`, or every bucket when `bucket` is `nil`.
    func reset(bucket: String?) {
        if let bucket {
            buckets.removeValue(forKey: bucket)
        } else {
            buckets.removeAll(keepingCapacity: true)
        }
    }

    /// Names of all buckets that currently have at least one recorded sample.
    func bucketNames() -> [String] {
        Array(buckets.keys)
    }
}

private extension Array where Element == Double {
    /// Appends unless the array has already reached `cap`.
    ///
    /// Exists so the cap check can happen *inside* the dictionary's `_modify` access in
    /// `record`, keeping the whole operation an in-place mutation. Reading the count
    /// separately would require a second lookup and reintroduce the copy this avoids.
    @inline(__always)
    mutating func appendCapped(_ value: Double, cap: Int) {
        guard count < cap else { return }
        append(value)
    }
}
#endif
