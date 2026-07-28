//! The pure rules of an episode: who may claim it, when a termination counts,
//! and where the ladder goes next.
//!
//! Everything here is platform-independent and side-effecting only through the
//! `Store` it is handed, which is what makes the generation races and the
//! attempt cap ordinary unit tests.

use super::profiles::Package;
use super::state::{Claim, Phase, Record, Store, RETRY_GENERATION};

/// Identity of one attempt. The token names the rung's attempt; the generation
/// distinguishes the original from its sole retry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Episode {
    pub token: String,
    pub generation: u32,
}

/// Why a web process went away, reduced to the only distinction the ladder
/// makes. Mapping from WebKit's `#[non_exhaustive]` reason enum happens at the
/// signal boundary, so an unknown future reason lands in `Other` — the arm that
/// never downgrades anything.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Termination {
    Crashed,
    Other,
}

/// How long after launch a `Crashed` web process still counts as a startup
/// failure, and therefore how long a launch must survive to be recorded as
/// crash-free.
///
/// This is the ladder's own boundary. It is deliberately **not** the ~10 s
/// figure from the spike, which is a no-paint probe timeout for a track that
/// is out of scope here and was never a crash-eligibility cutoff.
///
/// No reporter trace carries a timing, so there is nothing to derive a number
/// from; the only measurement available is the spike's 562-780 ms floor to
/// first content under llvmpipe, which is a floor and not a prediction. Five
/// seconds is roughly six times that floor — enough headroom for a cold WebKit
/// on slow hardware, while still well inside the window in which a user would
/// say the app "never came up". The error direction is chosen: too short only
/// loses a recovery the user can still trigger with `--safe-rendering`,
/// whereas too long downgrades rendering for a crash that had nothing to do
/// with startup. So it errs short.
pub(crate) const CRASH_ELIGIBILITY_WINDOW: std::time::Duration = std::time::Duration::from_secs(5);

/// Whether this termination advances the ladder. Only a `Crashed` web process
/// inside the eligibility window does; everything else is diagnostic.
pub(crate) fn advances_ladder(termination: Termination, since_launch: std::time::Duration) -> bool {
    termination == Termination::Crashed && since_launch <= CRASH_ELIGIBILITY_WINDOW
}

/// Where the ladder goes after a tier fails.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Advance {
    /// Try this tier next.
    Tier(usize),
    /// No tier left for this package.
    Exhausted,
}

/// Step down one tier, or run out.
///
/// This is also case 10's per-package attempt cap. A crash always advances and
/// never repeats a tier, so the ladder can spend at most one attempt per tier
/// and the tier count *is* the cap — no separate counter can drift from it.
pub(crate) fn advance(package: Package, tier: usize) -> Advance {
    match tier + 1 {
        next if next <= package.terminal_tier() => Advance::Tier(next),
        _ => Advance::Exhausted,
    }
}

/// What a tagged recovery child concluded about the episode it was sent to run.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Claimed {
    /// This process exclusively owns `episode` at `tier`, and `started` is
    /// durable.
    Owner { episode: Episode, tier: usize },
    /// Another process is this episode's owner, or a newer episode has
    /// superseded it. This child must exit *without* competing for the
    /// single-instance name: if it took the name ahead of the true owner, the
    /// owner would exit as a duplicate while the durable `started` receipt
    /// still named it.
    Superseded(&'static str),
    /// Nobody owns this episode and nobody else is going to. Exiting here would
    /// cost the user their window for nothing, so this child runs on with the
    /// environment it was handed and the ladder simply stops tracking it.
    Untracked(&'static str),
}

/// Exclusively claim the prepared record this child was launched for.
///
/// `episode` comes from the child's tag, never from the record on disk. By the
/// time a delayed child runs, a retry may have prepared a newer generation, and
/// adopting the record's generation would let the stale child write the newer
/// generation's receipt.
///
/// The read, the claim, and the `started` write all happen inside one
/// transaction. Split across three unsynchronized steps they were not enough: a
/// child could read its own generation as current, be descheduled while another
/// invocation durably prepared the next generation, then resume and stamp its
/// stale `started` over the newer record.
pub(crate) fn claim(store: &Store, episode: &Episode) -> Claimed {
    let tx = match store.lock() {
        Ok(tx) => tx,
        Err(error) => {
            eprintln!("{}: could not take the state lock: {error}", super::LOG);
            return Claimed::Untracked("the state lock could not be taken");
        }
    };

    let Some(record) = store.read() else {
        return Claimed::Untracked("no episode record");
    };
    if record.token != episode.token || record.generation != episode.generation {
        return Claimed::Superseded("this episode is no longer current");
    }
    if record.phase != Phase::Prepared {
        return Claimed::Superseded("this episode was already claimed");
    }

    match store.claim(&tx, &episode.token, episode.generation) {
        Claim::Won => {}
        Claim::Lost => return Claimed::Superseded("another child claimed this episode first"),
        Claim::Failed(error) => {
            // No receipt exists to falsify, and the sibling child would hit the
            // same filesystem error, so there is nothing here to defer to.
            eprintln!("{}: claim failed: {error}", super::LOG);
            return Claimed::Untracked("the claim could not be taken exclusively");
        }
    }

    let mut started = record.clone();
    started.phase = Phase::Started;
    started.pid = Some(std::process::id());
    if let Err(error) = store.write(&tx, &started) {
        // The claim is taken and cannot be given back, so this process is the
        // owner whether or not the receipt landed. Run on untracked: the record
        // still says `prepared`, and the next launch retries or advances it.
        eprintln!("{}: failed to persist started: {error}", super::LOG);
        return Claimed::Untracked("the started receipt could not be persisted");
    }

    Claimed::Owner {
        episode: episode.clone(),
        tier: record.tier,
    }
}

/// Whether `episode` may still write `next` over `current`.
///
/// Two independent conditions, both necessary. The identity check rejects a
/// receipt from an episode that is no longer current — a `confirmed` write
/// racing the crash handoff that already prepared the next token would
/// otherwise resurrect the superseded attempt. The phase check rejects a
/// receipt that does not move the episode forward, so a duplicated or
/// out-of-order callback cannot walk the record backwards.
pub(crate) fn may_advance(current: Option<&Record>, episode: &Episode, next: Phase) -> bool {
    let Some(current) = current else {
        // Nothing on disk to advance. The record a receipt belongs to is
        // written by the parent before the child exists, so its absence means
        // this episode was cleared — not that a receipt should create it.
        return false;
    };
    current.token == episode.token
        && current.generation == episode.generation
        && current.phase.precedes(next)
}

/// The record a parent must make durable before spawning a child for `tier`.
pub(crate) fn prepare(episode: &Episode, package: Package, tier: usize, version: &str) -> Record {
    let name = package.tier(tier).map(|tier| tier.name).unwrap_or_default();
    Record::new(
        Phase::Prepared,
        &episode.token,
        episode.generation,
        name,
        tier,
        version,
    )
}

/// The retry of an unclaimed attempt: same token, one generation on.
pub(crate) fn retry_of(record: &Record) -> Episode {
    Episode {
        token: record.token.clone(),
        generation: record.generation + RETRY_GENERATION,
    }
}

/// A fresh attempt at a rung.
pub(crate) fn fresh() -> Episode {
    Episode {
        token: uuid::Uuid::new_v4().to_string(),
        generation: 0,
    }
}
