//! The one explicit recovery launcher.
//!
//! `tauri::App::request_restart` cannot serve here: it has no child-environment
//! parameter, and its failure branch is crate-private and skips the
//! single-instance plugin's name release, so every child born from it dies as a
//! duplicate. `std::env::set_var` is equally out — it is unsound in a process
//! with live GTK and Tokio threads, and WebKit memoizes each renderer variable
//! once per process anyway, so a late assignment would be read by nothing.
//!
//! So the sequence is written out in full, in Buzz's own code:
//!
//! ```text
//! prepare the record atomically
//!   → release the single-instance name (running app only)
//!   → prove the name is free
//!   → spawn a Command with an exact environment
//!   → the child claims the prepared record
//!   → the parent exits
//! ```
//!
//! Spawn success and a zero exit code are both worthless as survival signals —
//! a child that loses the name forwards its argv and exits 0. Only the child's
//! claim receipt, correlated against the name's owner, proves a handoff.

use super::dbus::{self, Observation};
use super::episode::Episode;
use super::profiles::{Env, Package, Tier};

/// Environment tag carried by a recovery child.
pub(crate) const EPISODE: &str = "BUZZ_RENDER_EPISODE";
pub(crate) const GENERATION: &str = "BUZZ_RENDER_GENERATION";
pub(crate) const PROFILE: &str = "BUZZ_RENDER_PROFILE";
pub(crate) const FORCED: &str = "BUZZ_RENDER_FORCED";

const TAGS: [&str; 4] = [EPISODE, GENERATION, PROFILE, FORCED];

/// The tag a recovery child was launched with. Its presence is what tells the
/// child that the owned variables in its environment are its parent's profile
/// rather than the user's configuration.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Tag {
    /// `None` for a forced launch, which owns no episode and persists nothing.
    pub episode: Option<Episode>,
    pub profile: String,
}

impl Tag {
    /// Read from the environment, or `None` for an ordinary launch.
    ///
    /// A tag missing its generation is malformed rather than generation 0:
    /// defaulting would let a corrupted tag claim the original attempt.
    pub(crate) fn read(env: Env<'_>) -> Option<Self> {
        let profile = env(PROFILE)?;
        if env(FORCED).is_some() {
            return Some(Tag {
                episode: None,
                profile,
            });
        }
        let token = env(EPISODE).filter(|token| !token.is_empty())?;
        let generation = env(GENERATION)?.parse().ok()?;
        Some(Tag {
            episode: Some(Episode { token, generation }),
            profile,
        })
    }
}

/// Why a relaunch did not happen. Every arm leaves the current process running.
#[derive(Debug)]
pub(crate) enum Refusal {
    /// The name has an owner, or the bus could not answer. Either way this is
    /// a handoff failure, never a free name.
    NameNotFree(String),
    /// The binary to re-execute could not be resolved.
    NoBinary(String),
    /// `Command::spawn` itself failed: no child exists.
    SpawnFailed(String),
    /// The prepared record could not be made durable. Refusing here is the
    /// point: a child that arrives to claim a record that was never written
    /// would run untracked, and the ladder would lose the attempt.
    StateNotDurable(String),
    /// The requested rung is not in this package's ladder.
    NoTier(String),
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Refusal::NameNotFree(detail) => write!(f, "single-instance name not free: {detail}"),
            Refusal::NoBinary(detail) => write!(f, "cannot locate the app binary: {detail}"),
            Refusal::SpawnFailed(detail) => write!(f, "spawn failed: {detail}"),
            Refusal::StateNotDurable(detail) => {
                write!(f, "episode record not durable: {detail}")
            }
            Refusal::NoTier(detail) => write!(f, "no such renderer tier: {detail}"),
        }
    }
}

/// Build a child command whose owned-variable environment is exactly `tier`.
///
/// Every owned variable is removed first, then only the tier's pairs are
/// added, so an attempt never inherits the previous attempt's profile. Package
/// scoping applies to the removals too: on AppImage `GDK_BACKEND` is
/// re-exported by the AppRun hook before the child binary starts, so removing
/// it here would be theatre.
pub(crate) fn exact_env_command(
    binary: std::path::PathBuf,
    args: &[std::ffi::OsString],
    package: Package,
    tier: &Tier,
    tag: &Tag,
) -> std::process::Command {
    let mut command = std::process::Command::new(binary);
    command.args(args);
    for key in package.owned_vars().iter().chain(TAGS.iter()) {
        command.env_remove(key);
    }
    command.envs(tier.vars.iter().copied());
    command.env(PROFILE, &tag.profile);
    match &tag.episode {
        Some(episode) => {
            command.env(EPISODE, &episode.token);
            command.env(GENERATION, episode.generation.to_string());
        }
        None => {
            command.env(FORCED, "1");
        }
    }
    command
}

/// The spawn edge, as a plain function pointer so tests can drive the refusal
/// and success branches without ever forking a real process.
pub(crate) type Launch = fn(
    &str,
    Result<std::path::PathBuf, String>,
    &[std::ffi::OsString],
    Package,
    &'static Tier,
    &Tag,
) -> Result<u32, Refusal>;

/// Prove the name is free, then spawn the attempt.
///
/// Any prepared record must already be durable: the child claims it as its
/// first action, and a child that arrives before the record does would find
/// nothing to claim.
pub(crate) fn spawn(
    dbus_name: &str,
    binary: Result<std::path::PathBuf, String>,
    args: &[std::ffi::OsString],
    package: Package,
    tier: &Tier,
    tag: &Tag,
) -> Result<u32, Refusal> {
    match dbus::observe(dbus_name) {
        Observation::Free => {}
        Observation::Owned(owner) => {
            return Err(Refusal::NameNotFree(format!(
                "owned by {} (pid {:?})",
                owner.unique_name, owner.pid
            )))
        }
        Observation::Unavailable(detail) => return Err(Refusal::NameNotFree(detail)),
    }

    exact_env_command(binary.map_err(Refusal::NoBinary)?, args, package, tier, tag)
        .spawn()
        .map(|child| child.id())
        .map_err(|error| Refusal::SpawnFailed(error.to_string()))
}
