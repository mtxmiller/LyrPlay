// File: MonotonicGate.swift
//
// A last-write-wins gate for out-of-order async responses.
//
// Several async requests (e.g. the ~6 fetchCurrentTrackMetadata call sites) can
// be in flight at once and complete in any order. Each request is stamped with a
// monotonically increasing sequence number; the gate admits a response only if
// its seq is NEWER than the last one ADMITTED.
//
// Crucially it tracks last-ADMITTED, not last-ISSUED. If the newest request
// fails outright (HTTP error, never reaches the gate), an earlier good response
// is still admitted instead of being dropped for being "stale" — which would
// otherwise leave the UI showing the old track until the next boundary (the
// exact self-heal-next-track symptom this guards against).
//
// Not thread-safe by design: callers confine use to a single thread (the main
// thread, for metadata). Kept as a tiny value type so the accept/drop decision
// is unit-testable in isolation from the managers it gates.
struct MonotonicGate {
    /// The highest seq admitted so far. 0 means nothing admitted yet.
    private(set) var lastAdmitted: Int = 0

    /// Returns true and advances the gate if `seq` is newer than everything
    /// admitted so far; returns false (drops) otherwise.
    mutating func admit(_ seq: Int) -> Bool {
        guard seq > lastAdmitted else { return false }
        lastAdmitted = seq
        return true
    }
}
