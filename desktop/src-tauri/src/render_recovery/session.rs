//! Boot reconciliation and the live ladder state for the running process.
//!
//! `boot` runs before Tauri is built, while the process is still single
//! threaded and owns no D-Bus name — both things it may do (hand off to a child
//! with a different environment, or exit for `--reset-rendering-mode`) require
//! that. What it returns is either a `Session`, which the rest of the process
//! uses to react to a crash, or an instruction to exit.

use std::ffi::OsString;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use super::classify::{self, Decision};
use super::cli;
use super::dbus::{self, Observation};
use super::episode::{self, Advance, Claimed, Episode, Termination};
use super::launcher::{self, Refusal, Tag};
use super::profiles::{self, Env, Package, Tier};
use super::state::{Phase, Record, Store};
use super::LOG;

/// Why the ladder is not running this launch. In every case the app starts
/// normally with whatever environment it already has.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Disabled {
    /// The user assigned an owned variable. Their configuration wins whole: no
    /// tier selection, no relaunch, no ladder.
    UserEnv(Vec<String>),
    /// No app data dir, so no durable record is possible.
    NoStateDir(String),
}

impl std::fmt::Display for Disabled {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Disabled::UserEnv(vars) => write!(
                f,
                "{} set in the environment; renderer recovery leaves user \
                 configuration alone",
                vars.join(", ")
            ),
            Disabled::NoStateDir(error) => write!(f, "{error}"),
        }
    }
}

/// What `boot` concluded.
pub(crate) enum Boot {
    /// Continue in this process. The environment already matches the session's
    /// tier, and the session carries what is needed to react to a later crash.
    Run(Arc<Session>),
    /// A child was spawned to run the selected tier; this process must exit
    /// without starting the app. The child is Buzz now.
    HandedOff,
    /// `--reset-rendering-mode` did its work. Exit without launching.
    Reset,
    /// Recovery is off this launch, but the app still starts.
    Off(Disabled),
}

/// Everything the running process needs to react to a web-process crash.
pub(crate) struct Session {
    store: Store,
    package: Package,
    version: String,
    dbus_name: String,
    args: Vec<OsString>,
    /// The tier this process is actually running.
    tier: usize,
    /// Episode identity, present only when this process claimed a prepared
    /// record. A plain launch owns no episode.
    episode: Option<Episode>,
    /// Manual override: never advance, never persist. Set by `--safe-rendering`
    /// and by any child that could not claim the episode it was sent to run.
    frozen: bool,
    /// Set once a ladder-eligible crash is seen, so a process that observed one
    /// and failed to hand off never goes on to record a crash-free startup.
    crashed: AtomicBool,
    /// When this process started, for the crash-eligibility window.
    launched: std::time::Instant,
    /// The spawn edge. Always `launcher::spawn` in production; tests replace it
    /// so a refusal or a success can be driven without forking.
    launch: launcher::Launch,
}

/// Reconcile persisted state and select this launch's renderer tier.
///
/// `identifier` is the bundle identifier, which names both the app data dir and
/// the single-instance bus name; `version` invalidates a persisted tier across
/// an upgrade.
pub(crate) fn boot(identifier: &str, version: &str) -> Boot {
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    let app_data_dir = dirs::data_dir()
        .map(|dir| dir.join(identifier))
        .ok_or_else(|| "no user data directory".to_string());
    let boot = reconcile(
        app_data_dir,
        identifier,
        version,
        args,
        &|key| {
            // `var_os`, not `var`: presence is the test, and a non-UTF-8 value
            // is still a user assignment.
            std::env::var_os(key).map(|value| value.to_string_lossy().into_owned())
        },
        launcher::spawn,
    );
    if let Boot::Off(reason) = &boot {
        eprintln!("{LOG}: disabled — {reason}");
    }
    boot
}

/// `boot` with its environmental inputs supplied, so the decision path is
/// exercisable without touching the real process environment.
pub(super) fn reconcile(
    app_data_dir: Result<std::path::PathBuf, String>,
    identifier: &str,
    version: &str,
    args: Vec<OsString>,
    env: Env<'_>,
    launch: launcher::Launch,
) -> Boot {
    let flags = cli::parse(args.iter().map(OsString::as_os_str));
    let package = Package::detect(env);
    let tag = Tag::read(env);

    let app_data_dir = match app_data_dir {
        Ok(dir) => dir,
        Err(error) => return Boot::Off(Disabled::NoStateDir(error)),
    };

    let session = Session {
        store: Store::new(&app_data_dir),
        package,
        version: version.to_string(),
        dbus_name: dbus::single_instance_name(identifier),
        args,
        tier: 0,
        episode: None,
        frozen: false,
        crashed: AtomicBool::new(false),
        launched: std::time::Instant::now(),
        launch,
    };

    // Reset runs ahead of the opt-out check on purpose: a user who has set an
    // owned variable is exactly the user most likely to be clearing a record
    // that an earlier run left behind.
    if flags.reset_rendering_mode {
        return session.reset();
    }

    // A recovery child never reinterprets the variables its parent injected as
    // user configuration, so only an untagged launch checks for a user opt-out.
    if tag.is_none() {
        let present = profiles::owned_present(package, env);
        if !present.is_empty() {
            return Boot::Off(Disabled::UserEnv(present));
        }
    }

    match tag {
        Some(tag) => session.start_as_child(tag),
        None => session.select_tier(flags.safe_rendering),
    }
}

impl Session {
    /// `--reset-rendering-mode`: delete the persisted tier and episode state,
    /// say what was cleared, and exit without launching.
    fn reset(self) -> Boot {
        println!(
            "{}",
            match self.store.clear() {
                true => "Cleared the persisted renderer profile and episode state.",
                false => "No persisted renderer profile or episode state to clear.",
            }
        );
        Boot::Reset
    }

    /// Untagged launch: classify the record, then either run the selected tier
    /// here or hand off to a child that can.
    fn select_tier(mut self, safe_rendering: bool) -> Boot {
        // `--safe-rendering` is a manual override for this launch only: the
        // terminal tier, no episode, nothing persisted.
        if safe_rendering {
            self.tier = self.package.terminal_tier();
            self.frozen = true;
            eprintln!(
                "{LOG}: {} — forcing {} for this launch only",
                cli::SAFE_RENDERING,
                self.profile_name()
            );
            return self.run_selected_tier();
        }

        let Some(record) = self.store.read() else {
            return self.run_selected_tier();
        };
        let decision = classify::decide(
            &record,
            &dbus::observe(&self.dbus_name),
            dbus::bus_id().as_deref(),
            &self.version,
            &pid_alive,
        );
        eprintln!(
            "{LOG}: found {:?} record (token={} gen={} tier={} profile={}) → {decision:?}",
            record.phase, record.token, record.generation, record.tier, record.profile
        );

        match decision {
            // Another instance owns the app. Run on as an ordinary duplicate
            // and let the single-instance plugin forward argv and exit us.
            Decision::Defer(_) => Boot::Run(Arc::new(self)),
            Decision::DiscardAndBaseline { .. } => {
                self.store.clear();
                self.run_selected_tier()
            }
            // The persisted "last crash-free startup profile" fact.
            Decision::ReuseProfile { tier } => {
                self.tier = tier;
                self.run_selected_tier()
            }
            // No profile survived. Stop rather than relaunch: this process is
            // the baseline environment, and the user's way to the safest tier
            // is the flag, not another fork.
            Decision::StopExhausted { tier } => {
                self.frozen = true;
                eprintln!(
                    "{LOG}: the ladder was already exhausted at tier {tier} on {}; \
                     relaunch with {} to force the safest profile",
                    self.package.label(),
                    cli::SAFE_RENDERING
                );
                Boot::Run(Arc::new(self))
            }
            // An attempt that never produced a receipt: re-run the same tier
            // under the next generation.
            Decision::RetrySameTier { tier, .. } => {
                self.tier = tier;
                self.hand_off_or_run(Some(episode::retry_of(&record)), tier)
            }
            Decision::AdvanceOrStop { tier, .. } => self.step_down(tier),
        }
    }

    /// Continue here when this process already carries the selected tier's
    /// environment, otherwise hand off to a child that carries it exactly.
    fn run_selected_tier(self) -> Boot {
        if self.tier == 0 {
            // Tier 0 sets nothing, and the opt-out check above proved no owned
            // variable is present — this process already *is* tier 0.
            return Boot::Run(Arc::new(self));
        }
        // A frozen launch is a manual override, so it runs the tier without
        // owning an episode: no record, no receipt, no advance.
        let episode = (!self.frozen).then(episode::fresh);
        let tier = self.tier;
        self.hand_off_or_run(episode, tier)
    }

    /// Move one tier down for a failed attempt, or stop at the terminal tier.
    fn step_down(mut self, failed: usize) -> Boot {
        match episode::advance(self.package, failed) {
            Advance::Tier(next) => {
                self.tier = next;
                self.hand_off_or_run(Some(episode::fresh()), next)
            }
            Advance::Exhausted => {
                self.tier = failed;
                self.frozen = true;
                self.note_exhausted();
                Boot::Run(Arc::new(self))
            }
        }
    }

    /// Recovery-child path: exclusively claim the record this child was
    /// launched for, and record `started` as its first action.
    fn start_as_child(mut self, tag: Tag) -> Boot {
        let Some(tier) = self.package.tier_named(&tag.profile) else {
            // Nothing here can be trusted to describe the environment the
            // parent actually applied, so this launch is not tracked at all.
            eprintln!(
                "{LOG}: recovery tag names an unknown profile ({}); not tracking this launch",
                tag.profile
            );
            self.frozen = true;
            return Boot::Run(Arc::new(self));
        };
        self.tier = tier;

        // A forced child owns no episode, so it has nothing to claim — it just
        // runs the environment it was handed.
        let Some(episode) = tag.episode else {
            self.frozen = true;
            return Boot::Run(Arc::new(self));
        };

        match episode::claim(&self.store, &episode) {
            Claimed::Owner { episode, tier } => {
                self.tier = tier;
                self.episode = Some(episode);
            }
            // A child that is not the owner writes nothing and runs on as an
            // ordinary launch. The single-instance plugin decides whether it is
            // a duplicate; the ladder simply stops tracking it.
            Claimed::Yielded(reason) => {
                eprintln!("{LOG}: recovery child is not the episode owner — {reason}");
                self.frozen = true;
            }
        }
        Boot::Run(Arc::new(self))
    }

    pub(crate) fn profile_name(&self) -> &'static str {
        self.package.tier(self.tier).map(|t| t.name).unwrap_or("")
    }

    /// Record that this process holds the single-instance name.
    pub(crate) fn note_owned(&self) {
        self.note(Phase::Owned);
    }

    /// How long this process still has before it counts as a crash-free start.
    pub(crate) fn until_confirmation(&self) -> std::time::Duration {
        episode::CRASH_ELIGIBILITY_WINDOW.saturating_sub(self.launched.elapsed())
    }

    /// Record that this process outlived the crash-eligibility window — the
    /// "last crash-free startup profile" fact. Version-scoped, and never a
    /// claim that rendering is actually correct.
    pub(crate) fn note_confirmed(&self) {
        if self.crashed.load(Ordering::SeqCst) {
            // An eligible crash was seen and the handoff did not carry us away.
            // Recording this tier as crash-free would persist the opposite of
            // what happened.
            return;
        }
        self.note(Phase::Confirmed);
    }

    /// Write a phase receipt for the episode this process owns.
    ///
    /// The receipt is bound to the bus id as well as the unique name: a unique
    /// name like `:1.4` only identifies a connection on the bus that issued it,
    /// so without the bus id a receipt from an earlier session's bus could
    /// correlate against a stranger here.
    fn note(&self, phase: Phase) {
        let Some(episode) = &self.episode else {
            return;
        };
        let mut record = self.record(phase, episode);
        record.pid = Some(std::process::id());
        match dbus::observe(&self.dbus_name) {
            Observation::Owned(owner) => {
                record.unique_name = Some(owner.unique_name);
                record.bus_id = dbus::bus_id();
            }
            // Not owning the name does not block the receipt: the phase itself
            // is still true, and `classify` reads a receipt with no recorded
            // identity as uncorrelatable rather than as ours.
            _ => eprintln!("{LOG}: writing {phase:?} without an owner identity"),
        }
        self.write(&record);
    }

    /// React to a web-process termination. Returns `true` when a child took
    /// over and this process must exit.
    pub(crate) fn on_web_process_terminated(
        &self,
        termination: Termination,
        release_name: &dyn Fn(),
    ) -> bool {
        let elapsed = self.launched.elapsed();
        if !episode::advances_ladder(termination, elapsed) {
            eprintln!(
                "{LOG}: web process ended ({termination:?}) {elapsed:?} after launch \
                 at tier {} ({}) — not ladder-eligible",
                self.tier,
                self.profile_name()
            );
            return false;
        }
        self.crashed.store(true, Ordering::SeqCst);
        if self.frozen {
            eprintln!("{LOG}: not advancing — this launch is running a forced profile");
            return false;
        }

        match episode::advance(self.package, self.tier) {
            Advance::Exhausted => {
                self.note_exhausted();
                false
            }
            Advance::Tier(next) => match self.hand_off(episode::fresh(), next, release_name) {
                Ok(()) => true,
                Err(refusal) => {
                    eprintln!("{LOG}: relaunch refused: {refusal}");
                    false
                }
            },
        }
    }

    /// Hand off to a child at `tier`, or run on here if the handoff is refused.
    /// Only reached before the single-instance name exists, so there is nothing
    /// to release first.
    fn hand_off_or_run(mut self, episode: Option<Episode>, tier: usize) -> Boot {
        let handed = match episode {
            Some(episode) => self.hand_off(episode, tier, &|| {}),
            None => self.force(tier),
        };
        match handed {
            Ok(()) => Boot::HandedOff,
            Err(refusal) => {
                eprintln!("{LOG}: staying at the launched profile — {refusal}");
                // The handoff did not happen, so this process is still the
                // baseline it was launched as and must not claim otherwise.
                self.tier = 0;
                self.frozen = true;
                Boot::Run(Arc::new(self))
            }
        }
    }

    /// Prepare a record for `tier`, release the single-instance name, and spawn
    /// a child carrying the tier's exact environment.
    ///
    /// The order is the whole mechanism. The record must be durable before the
    /// child exists, because the child claims it as its first action and would
    /// otherwise find nothing. The name must be released before the probe,
    /// because a child that fails to take the name forwards its argv and exits
    /// 0 — indistinguishable from a successful handoff.
    fn hand_off(
        &self,
        episode: Episode,
        tier: usize,
        release_name: &dyn Fn(),
    ) -> Result<(), Refusal> {
        let rung = self.rung(tier)?;
        let previous = self.store.read();
        if episode.generation == 0 {
            // A new token supersedes every earlier episode, so their claims are
            // spent evidence. Clearing them here — never the current token's —
            // is what keeps the directory from growing one file per relaunch.
            self.store.reset_claims();
        }
        let record = episode::prepare(&episode, self.package, tier, &self.version);
        self.store
            .write(&record)
            .map_err(Refusal::StateNotDurable)?;

        let tag = Tag {
            episode: Some(episode),
            profile: rung.name.to_string(),
        };
        match self.spawn_child(rung, &tag, release_name) {
            Ok(()) => Ok(()),
            Err(refusal) => {
                // No child exists, so the prepared record describes an attempt
                // that will never be claimed. Left in place it would spend the
                // rung's one retry on a failure that was never about rendering.
                match previous {
                    Some(record) => self.write(&record),
                    None => {
                        self.store.clear();
                    }
                }
                Err(refusal)
            }
        }
    }

    /// Hand off to a child running `tier` with no episode: nothing is prepared,
    /// nothing is claimed, and nothing is persisted. This is what a manual
    /// override is — a launch the ladder runs but does not learn from.
    fn force(&self, tier: usize) -> Result<(), Refusal> {
        let rung = self.rung(tier)?;
        let tag = Tag {
            episode: None,
            profile: rung.name.to_string(),
        };
        self.spawn_child(rung, &tag, &|| {})
    }

    fn spawn_child(
        &self,
        rung: &'static Tier,
        tag: &Tag,
        release_name: &dyn Fn(),
    ) -> Result<(), Refusal> {
        // Resolved before the name is released: a failure here is a refusal
        // that must leave this process still holding the name.
        let binary = tauri::process::current_binary(&tauri::Env::default())
            .map_err(|error| error.to_string());
        release_name();
        let pid = (self.launch)(&self.dbus_name, binary, &self.args, self.package, rung, tag)?;
        eprintln!("{LOG}: handed off to {} as pid {pid}", rung.name);
        Ok(())
    }

    fn rung(&self, tier: usize) -> Result<&'static Tier, Refusal> {
        self.package
            .tier(tier)
            .ok_or_else(|| Refusal::NoTier(format!("{} has no tier {tier}", self.package.label())))
    }

    /// Record that no profile survived, so later launches stop here instead of
    /// walking the whole ladder again on every start.
    fn note_exhausted(&self) {
        let episode = self.episode.clone().unwrap_or_else(episode::fresh);
        let mut record = self.record(Phase::Exhausted, &episode);
        record.pid = Some(std::process::id());
        self.write(&record);
        eprintln!(
            "{LOG}: ladder exhausted on {} at tier {} ({}); \
             relaunch with {} to force the safest profile",
            self.package.label(),
            self.tier,
            self.profile_name(),
            cli::SAFE_RENDERING
        );
    }

    fn record(&self, phase: Phase, episode: &Episode) -> Record {
        Record::new(
            phase,
            &episode.token,
            episode.generation,
            self.profile_name(),
            self.tier,
            &self.version,
        )
    }

    fn write(&self, record: &Record) {
        if let Err(error) = self.store.write(record) {
            eprintln!("{LOG}: failed to persist {:?}: {error}", record.phase);
        }
    }
}

fn pid_alive(pid: u32) -> bool {
    // Signal 0 runs the existence and permission checks without delivering
    // anything, and unlike a /proc lookup it is not fooled by a pid namespace.
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}
