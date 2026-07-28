//! Turning a durable record plus a bus observation into a boot decision.
//!
//! Pure over its inputs — the bus observation and process liveness are passed
//! in — so every arm of the decision table is a unit test rather than a
//! process-orchestration exercise.

use super::dbus::Observation;
use super::state::{Phase, Record, RETRY_GENERATION};

/// How the current name owner relates to the child the record names.
///
/// The `Uncorrelatable` arm is the one that is easy to get wrong: an owner that
/// exists but cannot be tied to our record is a handoff failure and a
/// diagnostic, and it is *never* evidence that the name is free.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Ownership {
    /// Nobody owns the name.
    Absent,
    /// The owner is the child this record names.
    Correlated,
    /// A different process owns the name.
    Mismatched,
    /// Somebody owns the name but the record cannot be matched against them —
    /// no recorded identity, no owner pid, or a receipt from another bus.
    Uncorrelatable,
}

/// What a fresh, untagged process should do about the record it found.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Decision {
    /// A live episode owns this app right now; this process is a duplicate.
    Defer(&'static str),
    /// Re-run `tier` under the same token, one generation on.
    RetrySameTier { reason: &'static str, tier: usize },
    /// The attempt at `tier` failed; move one rung down, or stop if `tier` was
    /// the last one.
    AdvanceOrStop { reason: &'static str, tier: usize },
    /// A tier started cleanly under this version. Run it again.
    ReuseProfile { tier: usize },
    /// The ladder is spent. Run `tier` and stop — no advance, no episode.
    StopExhausted { tier: usize },
    /// The record is unusable; delete it and launch from the baseline.
    DiscardAndBaseline { reason: &'static str },
}

/// Correlate the recorded child against what the bus reports.
pub(crate) fn correlate(
    record: &Record,
    observation: &Observation,
    bus_id: Option<&str>,
) -> Ownership {
    let owner = match observation {
        Observation::Free => return Ownership::Absent,
        // An unreachable bus proves nothing about the name. Treat it as an
        // owner we cannot identify rather than as a free name.
        Observation::Unavailable(_) => return Ownership::Uncorrelatable,
        Observation::Owned(owner) => owner,
    };

    match record.phase {
        // `owned` and later carry a unique name, which is the precise
        // identity — but only on the bus that issued it.
        Phase::Owned | Phase::Confirmed => match (&record.unique_name, &record.bus_id) {
            (Some(unique_name), Some(recorded_bus)) => {
                if bus_id != Some(recorded_bus.as_str()) {
                    Ownership::Uncorrelatable
                } else if *unique_name == owner.unique_name {
                    Ownership::Correlated
                } else {
                    Ownership::Mismatched
                }
            }
            _ => Ownership::Uncorrelatable,
        },
        // Before ownership the only identity is the pid.
        _ => match (record.pid, owner.pid) {
            (Some(recorded), Some(actual)) if recorded == actual => Ownership::Correlated,
            (Some(_), Some(_)) => Ownership::Mismatched,
            _ => Ownership::Uncorrelatable,
        },
    }
}

/// Decide what to do with `record`.
///
/// `pid_alive` answers whether a recorded pre-ownership child is still running;
/// `version` is the current app version, which invalidates a persisted profile
/// across an upgrade.
pub(crate) fn decide(
    record: &Record,
    observation: &Observation,
    bus_id: Option<&str>,
    version: &str,
    pid_alive: &dyn Fn(u32) -> bool,
) -> Decision {
    if record.version != version {
        return Decision::DiscardAndBaseline {
            reason: "app version changed since the record was written",
        };
    }

    let ownership = correlate(record, observation, bus_id);
    let owner_present = !matches!(observation, Observation::Free);

    match record.phase {
        // Terminal. Re-running the ladder from here would loop forever
        // against a machine no profile satisfies.
        Phase::Exhausted => Decision::StopExhausted { tier: record.tier },

        // Nobody ever claimed this attempt: the child died before its first
        // action, or never started. One retry, same tier, next generation.
        Phase::Prepared if record.generation < RETRY_GENERATION => Decision::RetrySameTier {
            reason: "prepared attempt was never claimed",
            tier: record.tier,
        },
        Phase::Prepared => Decision::AdvanceOrStop {
            reason: "prepared attempt was never claimed and the retry is spent",
            tier: record.tier,
        },

        // `started` is the bounded window between the claim and name
        // acquisition. Correlation against the *recorded* child is what
        // separates an episode in flight from a handoff failure.
        Phase::Started => match ownership {
            Ownership::Correlated => Decision::Defer("recovery child owns the name"),
            Ownership::Mismatched => Decision::AdvanceOrStop {
                reason: "a different process owns the name: handoff failed",
                tier: record.tier,
            },
            Ownership::Uncorrelatable if owner_present => Decision::AdvanceOrStop {
                reason: "the name has an owner that cannot be correlated: handoff failed",
                tier: record.tier,
            },
            // Name unowned: the child is either still in the pre-ownership
            // interval or gone.
            _ => match record.pid {
                Some(pid) if pid_alive(pid) => {
                    Decision::Defer("recovery child is alive in the pre-ownership interval")
                }
                _ => Decision::AdvanceOrStop {
                    reason: "recovery child is gone before acquiring the name",
                    tier: record.tier,
                },
            },
        },

        // `owned` means the child really did take over. Only the same
        // connection still holding the name keeps the episode in flight.
        Phase::Owned => match ownership {
            Ownership::Correlated => Decision::Defer("recovery child still owns the name"),
            Ownership::Mismatched => Decision::AdvanceOrStop {
                reason: "the recorded owner was replaced by another process",
                tier: record.tier,
            },
            Ownership::Uncorrelatable if owner_present => Decision::AdvanceOrStop {
                reason: "the name owner cannot be correlated to the recorded child",
                tier: record.tier,
            },
            _ => Decision::AdvanceOrStop {
                reason: "the recorded owner released the name",
                tier: record.tier,
            },
        },

        // A tier that reached the startup boundary. This is the persisted
        // "last crash-free startup profile" fact.
        Phase::Confirmed => match ownership {
            Ownership::Correlated => Decision::Defer("the confirmed instance is still running"),
            _ => Decision::ReuseProfile { tier: record.tier },
        },
    }
}
