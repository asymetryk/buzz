//! Durable episode state: the `prepared → started → owned → confirmed` record
//! and the exclusive `(token, generation)` claim.
//!
//! Phases are monotonic and each post-parent phase records the identity that
//! makes the episode verifiable — a pid, then the D-Bus unique name and bus id.
//! Only the child that wins the exclusive claim ever writes a receipt.
//!
//! Claims are keyed on `(token, generation)` rather than the token alone. The
//! sole retry reuses the same token, and an exclusive claim is one-shot by
//! design, so a token-only key would make the retry lose its own claim against
//! the first attempt's file. Claim files are never deleted: a stale claim is
//! inert evidence that a generation already ran, and deleting one cannot be
//! fused with the record write into a single durable step.

use serde::{Deserialize, Serialize};
use std::io::Write as _;
use std::path::{Path, PathBuf};

/// Where the record and claim files live, relative to the app data dir.
const DIR: &str = "render-recovery";
const RECORD: &str = "episode.json";
const CLAIMS: &str = "claims";

/// The sole retry generation. An attempt whose child never claimed is retried
/// exactly once, under generation 1; there is no generation 2.
pub(crate) const RETRY_GENERATION: u32 = 1;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Phase {
    /// Written by the parent, atomically, before spawning.
    Prepared,
    /// Written by the exclusively claiming child as its first action.
    Started,
    /// Written by the same child once it holds the single-instance name.
    Owned,
    /// Written by the same child once the startup boundary passes. Doubles as
    /// the persisted "last crash-free startup profile" fact.
    Confirmed,
    /// The ladder ran out of rungs for this package. Terminal.
    Exhausted,
}

/// The durable record. One file, rewritten atomically at each transition.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Record {
    pub phase: Phase,
    /// Attempt identity. A new rung mints a new token; the retry reuses it.
    pub token: String,
    /// Retry identity within the attempt: 0, and `RETRY_GENERATION` for the
    /// sole retry.
    pub generation: u32,
    /// Tier name, e.g. `shm-transport`. Recorded for the log; the tier index
    /// is what the ladder actually reads.
    pub profile: String,
    /// Tier index into the package's ladder.
    pub tier: usize,
    /// App version, so a persisted profile does not survive an upgrade.
    pub version: String,
    /// The claiming child's pid. Present from `started` onward.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
    /// The child's D-Bus unique name. Present from `owned` onward.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unique_name: Option<String>,
    /// The bus the unique name was issued on. A unique name is only meaningful
    /// against the bus that minted it; a different bus can reuse `:1.4`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bus_id: Option<String>,
}

impl Record {
    pub(crate) fn new(
        phase: Phase,
        token: &str,
        generation: u32,
        profile: &str,
        tier: usize,
        version: &str,
    ) -> Self {
        Record {
            phase,
            token: token.to_string(),
            generation,
            profile: profile.to_string(),
            tier,
            version: version.to_string(),
            pid: None,
            unique_name: None,
            bus_id: None,
        }
    }
}

/// Filesystem home of the episode record and its claim files.
pub(crate) struct Store {
    dir: PathBuf,
}

/// Outcome of an exclusive claim attempt.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Claim {
    /// This process owns the transition and must write the receipt.
    Won,
    /// Another process holds this `(token, generation)`. Write nothing.
    Lost,
    /// The claim could not be attempted. Also write nothing — a claim that
    /// cannot be proven exclusive is not a claim.
    Failed(String),
}

impl Store {
    pub(crate) fn new(app_data_dir: &Path) -> Self {
        Store {
            dir: app_data_dir.join(DIR),
        }
    }

    fn record_path(&self) -> PathBuf {
        self.dir.join(RECORD)
    }

    fn claim_path(&self, token: &str, generation: u32) -> PathBuf {
        self.dir.join(CLAIMS).join(format!("{token}-g{generation}"))
    }

    /// Read the record. An unreadable or unparsable record is `None` — the
    /// caller treats that as absent and starts from the baseline.
    pub(crate) fn read(&self) -> Option<Record> {
        let text = std::fs::read_to_string(self.record_path()).ok()?;
        serde_json::from_str(&text).ok()
    }

    /// Atomically replace the record. Durability matters here: a torn record
    /// after a crash would be indistinguishable from a corrupt one and would
    /// silently restart the ladder.
    pub(crate) fn write(&self, record: &Record) -> Result<(), String> {
        use atomic_write_file::AtomicWriteFile;

        std::fs::create_dir_all(&self.dir)
            .map_err(|e| format!("create {}: {e}", self.dir.display()))?;
        let path = self.record_path();
        let json = serde_json::to_vec_pretty(record).map_err(|e| format!("encode record: {e}"))?;
        let mut file =
            AtomicWriteFile::open(&path).map_err(|e| format!("open {}: {e}", path.display()))?;
        file.write_all(&json)
            .map_err(|e| format!("write {}: {e}", path.display()))?;
        file.commit()
            .map_err(|e| format!("commit {}: {e}", path.display()))
    }

    /// Delete the record and every claim. Used by `--reset-rendering-mode` and
    /// when a record cannot be parsed. Returns whether anything was there.
    pub(crate) fn clear(&self) -> bool {
        let existed = self.dir.exists();
        let _ = std::fs::remove_dir_all(&self.dir);
        existed
    }

    /// Drop the claim files of superseded episodes, before a fresh one is
    /// prepared.
    ///
    /// This is not the deletion the contract forbids. That rule protects the
    /// *current* token, whose sole retry must not be able to erase its own
    /// first attempt's evidence — hence the `(token, generation)` key. A claim
    /// belonging to an older token can strand nothing: a delayed child of a
    /// superseded episode is turned away by the token check against the record
    /// long before it looks at a claim file. Without this the directory grows
    /// by one file per relaunch, forever.
    pub(crate) fn reset_claims(&self) {
        let _ = std::fs::remove_dir_all(self.dir.join(CLAIMS));
    }

    /// Take exclusive ownership of one `(token, generation)`.
    ///
    /// `create_new` is `O_EXCL` at the filesystem level: of N racing processes
    /// exactly one gets `Ok`. This is the compare-and-transition primitive —
    /// a read-then-rename would let two children both pass the read and the
    /// loser write the last receipt.
    pub(crate) fn claim(&self, token: &str, generation: u32) -> Claim {
        let path = self.claim_path(token, generation);
        if let Some(parent) = path.parent() {
            if let Err(e) = std::fs::create_dir_all(parent) {
                return Claim::Failed(format!("create {}: {e}", parent.display()));
            }
        }
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
        {
            Ok(mut file) => {
                let _ = writeln!(file, "pid={}", std::process::id());
                Claim::Won
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => Claim::Lost,
            Err(e) => Claim::Failed(format!("claim {}: {e}", path.display())),
        }
    }

    #[cfg(test)]
    pub(crate) fn record_path_for_test(&self) -> PathBuf {
        self.record_path()
    }

    #[cfg(test)]
    pub(crate) fn claim_count(&self) -> usize {
        std::fs::read_dir(self.dir.join(CLAIMS))
            .map(|entries| entries.count())
            .unwrap_or(0)
    }

    #[cfg(test)]
    pub(crate) fn seed_claim(&self, token: &str, generation: u32) {
        assert_eq!(self.claim(token, generation), Claim::Won);
    }
}
