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
use super::launcher::{self, Handoff, Refusal, Tag};
use super::profiles::{self, Env, Package, Tier};
use super::state::{Phase, Record, Store, Transaction};
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
    /// Another process owns this episode. Exit without starting the app and
    /// without competing for the single-instance name. The reason is already
    /// logged where it was decided, so nothing is carried here.
    Superseded,
    /// The user asked for something that cannot be delivered. Exit before Tauri
    /// with a diagnostic and a non-zero status rather than starting an app that
    /// silently ignores the request.
    Fatal(String),
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
    /// and failed to hand off never goes on to record a crash-free startup, and
    /// so the handoff itself happens at most once per process.
    crashed: AtomicBool,
    /// When this process started, for the crash-eligibility window.
    launched: std::time::Instant,
    /// The spawn edge. Always `launcher::spawn` in production; tests replace it
    /// so a refusal or a success can be driven without forking.
    launch: launcher::Launch,
}

/// What this process must give up before a child may take the single-instance
/// name — and, decisively, whether giving it up can be undone.
///
/// The two callers of the launcher sit on opposite sides of that question, and
/// a bare closure could not tell them apart: at boot no name is held yet, so a
/// refusal is harmless, while a live app has to destroy its single-instance
/// plugin and can never re-register it. Naming the distinction here is what
/// stops a refusal from being mistaken for a recoverable one.
enum Release<'a> {
    /// Boot, before Tauri exists. Nothing is held, so nothing is released.
    NothingHeld,
    /// A live app holding the name. Running this destroys the single-instance
    /// plugin; there is no way back.
    SingleInstanceName(&'a dyn Fn()),
}

impl Release<'_> {
    /// Release, and report whether the process just crossed an irreversible
    /// boundary.
    fn run(&self) -> bool {
        match self {
            Release::NothingHeld => false,
            Release::SingleInstanceName(destroy) => {
                destroy();
                true
            }
        }
    }
}

/// What a live app must do about a web-process termination.
pub(crate) enum CrashResponse {
    /// A child carrying the next tier is Buzz now. Exit.
    HandedOff,
    /// The relaunch was refused *after* the single-instance name was released.
    /// This process no longer owns the name it needs to be the app, and cannot
    /// take it back, so it must exit rather than linger as a second instance.
    Stranded,
    /// Nothing was released and nothing was launched. Carry on.
    Continue,
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
            // `--safe-rendering` and a user-set owned variable are two
            // incompatible answers to the same question, and the ladder has no
            // basis for picking one: honouring the flag would overwrite
            // configuration the user typed, and honouring the environment would
            // silently ignore a rescue flag from a user whose app will not
            // start. So neither is guessed — the request is refused, loudly,
            // before Tauri.
            return match flags.safe_rendering {
                true => Boot::Fatal(conflict_message(&present)),
                false => Boot::Off(Disabled::UserEnv(present)),
            };
        }
    }

    match tag {
        Some(tag) => session.start_as_child(tag),
        None => session.select_tier(flags.safe_rendering),
    }
}

/// The diagnostic for `--safe-rendering` against a user-set owned variable.
///
/// `present` carries `KEY=value` assignments, so it both shows the user what is
/// set and names the keys to unset — the two things needed to act on this.
fn conflict_message(present: &[String]) -> String {
    let keys: Vec<&str> = present
        .iter()
        .map(|assignment| match assignment.split_once('=') {
            Some((key, _)) => key,
            None => assignment.as_str(),
        })
        .collect();
    format!(
        "{} cannot be applied: {} already set in the environment. \
         Either unset {} and run {} again, or keep that environment and drop \
         the flag.",
        cli::SAFE_RENDERING,
        present.join(", "),
        keys.join(", "),
        cli::SAFE_RENDERING,
    )
}

impl Session {
    /// `--reset-rendering-mode`: delete the persisted tier and episode state,
    /// say what was cleared, and exit without launching.
    fn reset(self) -> Boot {
        let cleared = match self.store.lock() {
            Ok(tx) => self.store.clear(&tx),
            Err(error) => {
                // Another process is mid-transition. Clearing without the lock
                // could delete a record a live child is about to claim, so this
                // reports the refusal rather than racing it.
                return Boot::Fatal(format!("could not clear renderer state: {error}"));
            }
        };
        println!(
            "{}",
            match cleared {
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
                if let Ok(tx) = self.store.lock() {
                    self.store.clear(&tx);
                }
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
                Boot::Run(Arc::new(self))
            }
            // Someone else owns this episode. Exiting here rather than running
            // on is the point: a loser that continued into Tauri could win the
            // single-instance name ahead of the true owner, and the owner would
            // then exit as a duplicate while the durable `started` receipt still
            // named it — a record pointing at a dead process, which the next
            // launch reads as a failed handoff and charges to the ladder.
            Claimed::Superseded(reason) => {
                eprintln!("{LOG}: recovery child is not the episode owner — {reason}; exiting");
                Boot::Superseded
            }
            // No owner to defer to, so exiting would cost the user their window
            // for nothing. Run the environment that was handed over, untracked.
            Claimed::Untracked(reason) => {
                eprintln!("{LOG}: not tracking this recovery launch — {reason}");
                self.frozen = true;
                Boot::Run(Arc::new(self))
            }
        }
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
    /// Two conditions gate the write, both under the transaction lock. The
    /// identity check (`episode::may_advance`) rejects a receipt for an episode
    /// that is no longer current: `note_confirmed` runs from a timer thread and
    /// can be racing a crash handoff that has already prepared the next token,
    /// and without the check it would overwrite that token with the superseded
    /// episode's `confirmed`. The phase check rejects a receipt that does not
    /// move the record forward, so a repeated or out-of-order callback cannot
    /// walk it backwards.
    ///
    /// The receipt is bound to the bus id as well as the unique name: a unique
    /// name like `:1.4` only identifies a connection on the bus that issued it,
    /// so without the bus id a receipt from an earlier session's bus could
    /// correlate against a stranger here.
    fn note(&self, phase: Phase) {
        let Some(episode) = &self.episode else {
            return;
        };
        let Ok(tx) = self.store.lock() else {
            eprintln!("{LOG}: skipping the {phase:?} receipt — the state lock was unavailable");
            return;
        };
        if !episode::may_advance(self.store.read().as_ref(), episode, phase) {
            eprintln!("{LOG}: skipping the {phase:?} receipt — this episode is no longer current");
            return;
        }

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
        self.write(&tx, &record);
    }

    /// React to a web-process termination.
    pub(crate) fn on_web_process_terminated(
        &self,
        termination: Termination,
        destroy_single_instance: &dyn Fn(),
    ) -> CrashResponse {
        let elapsed = self.launched.elapsed();
        if !episode::advances_ladder(termination, elapsed) {
            eprintln!(
                "{LOG}: web process ended ({termination:?}) {elapsed:?} after launch \
                 at tier {} ({}) — not ladder-eligible",
                self.tier,
                self.profile_name()
            );
            return CrashResponse::Continue;
        }
        // One-shot: the signal can fire again while a handoff is in flight (a
        // second webview, or WebKit respawning and re-crashing), and a second
        // handoff would spawn a second child for a second episode — two live
        // Buzz processes racing one name. `swap` makes the first caller the only
        // one that proceeds; later callers still see `crashed` set, so they also
        // suppress the crash-free receipt.
        if self.crashed.swap(true, Ordering::SeqCst) {
            eprintln!("{LOG}: a ladder-eligible crash was already handled; not advancing again");
            return CrashResponse::Continue;
        }
        if self.frozen {
            eprintln!("{LOG}: not advancing — this launch is running a forced profile");
            return CrashResponse::Continue;
        }

        match episode::advance(self.package, self.tier) {
            Advance::Exhausted => {
                self.note_exhausted();
                CrashResponse::Continue
            }
            Advance::Tier(next) => {
                let release = Release::SingleInstanceName(destroy_single_instance);
                match self.hand_off(episode::fresh(), next, &release) {
                    Handoff::Launched => CrashResponse::HandedOff,
                    // Nothing was released, so this process is still the app.
                    Handoff::RefusedBeforeRelease(refusal) => {
                        eprintln!("{LOG}: relaunch refused: {refusal}");
                        CrashResponse::Continue
                    }
                    // The single-instance plugin is destroyed and cannot be
                    // re-registered. Staying would leave a Buzz that no longer
                    // owns the name — a later launch would start a second app
                    // beside it, and deep links would go to whichever won.
                    Handoff::RefusedAfterRelease(refusal) => {
                        eprintln!(
                            "{LOG}: relaunch refused after releasing the single-instance name \
                             ({refusal}); exiting rather than running without it"
                        );
                        CrashResponse::Stranded
                    }
                }
            }
        }
    }

    /// Hand off to a child at `tier`, or run on here if the handoff is refused.
    /// Only reached before Tauri exists, so nothing is held and every refusal
    /// leaves this process exactly as it was launched.
    fn hand_off_or_run(mut self, episode: Option<Episode>, tier: usize) -> Boot {
        let handed = match episode {
            Some(episode) => self.hand_off(episode, tier, &Release::NothingHeld),
            None => self.force(tier),
        };
        match handed {
            Handoff::Launched => Boot::HandedOff,
            Handoff::RefusedBeforeRelease(refusal) => {
                eprintln!("{LOG}: staying at the launched profile — {refusal}");
                // The handoff did not happen, so this process is still the
                // baseline it was launched as and must not claim otherwise.
                self.tier = 0;
                self.frozen = true;
                Boot::Run(Arc::new(self))
            }
            // Unreachable by construction: `Release::NothingHeld` releases
            // nothing, so there is no post-release side to land on. Handled as a
            // refusal rather than a panic — if the invariant ever breaks, the
            // safe reading of "we may have released something" is to not run.
            Handoff::RefusedAfterRelease(refusal) => Boot::Fatal(format!(
                "renderer handoff refused after an unexpected release: {refusal}"
            )),
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
    fn hand_off(&self, episode: Episode, tier: usize, release: &Release<'_>) -> Handoff {
        let rung = match self.rung(tier) {
            Ok(rung) => rung,
            Err(refusal) => return Handoff::RefusedBeforeRelease(refusal),
        };
        let tx = match self.store.lock() {
            Ok(tx) => tx,
            Err(error) => {
                return Handoff::RefusedBeforeRelease(Refusal::StateNotDurable(error));
            }
        };
        let previous = self.store.read();
        let record = episode::prepare(&episode, self.package, tier, &self.version);
        if let Err(error) = self.store.write(&tx, &record) {
            return Handoff::RefusedBeforeRelease(Refusal::StateNotDurable(error));
        }
        if episode.generation == 0 {
            // Only now that the new record is durable. Pruning first would, on a
            // failed record write, leave the old record current with its claim
            // evidence already gone — and an old child that had passed its
            // record read could then re-create its claim and write a receipt
            // over the record.
            self.store.prune_claims(&tx, &episode.token);
        }
        // Released before the spawn: the record is durable and every check that
        // does not need the name released has already run.
        drop(tx);

        let tag = Tag {
            episode: Some(episode),
            profile: rung.name.to_string(),
        };
        let handoff = self.spawn_child(rung, &tag, release);
        if handoff.refused() {
            // No child exists, so the prepared record describes an attempt that
            // will never be claimed. Left in place it would spend the rung's one
            // retry on a failure that was never about rendering.
            self.roll_back(&record, previous);
        }
        handoff
    }

    /// Restore the record a refused handoff had already overwritten.
    ///
    /// Identity-checked, because the lock is dropped between the prepared write
    /// and the spawn: by the time a refusal comes back, a concurrent launch may
    /// have prepared its own episode, and a blind restore would erase a record
    /// that a live child is about to claim — turning that child's handoff into
    /// an untracked launch. Only the record this call itself wrote is rolled
    /// back.
    fn roll_back(&self, prepared: &Record, previous: Option<Record>) {
        let Ok(tx) = self.store.lock() else {
            eprintln!("{LOG}: could not roll back the prepared record — the state lock was busy");
            return;
        };
        match self.store.read() {
            Some(current)
                if current.token == prepared.token && current.generation == prepared.generation => {
            }
            _ => {
                eprintln!("{LOG}: not rolling back — another episode is current now");
                return;
            }
        }
        match previous {
            Some(record) => self.write(&tx, &record),
            None => {
                self.store.clear(&tx);
            }
        }
    }

    /// Hand off to a child running `tier` with no episode: nothing is prepared,
    /// nothing is claimed, and nothing is persisted. This is what a manual
    /// override is — a launch the ladder runs but does not learn from.
    fn force(&self, tier: usize) -> Handoff {
        match self.rung(tier) {
            Ok(rung) => {
                let tag = Tag {
                    episode: None,
                    profile: rung.name.to_string(),
                };
                self.spawn_child(rung, &tag, &Release::NothingHeld)
            }
            Err(refusal) => Handoff::RefusedBeforeRelease(refusal),
        }
    }

    /// The release boundary itself: every preflight that can fail runs *before*
    /// `release.run()`, and everything after it is reported as a post-release
    /// outcome.
    ///
    /// Resolving the binary belongs on this side of the line. Held as an
    /// unresolved `Result` and passed onward it would surface only inside the
    /// launcher — after the name was already gone — turning a plainly
    /// recoverable "cannot find my own executable" into a stranded app.
    fn spawn_child(&self, rung: &'static Tier, tag: &Tag, release: &Release<'_>) -> Handoff {
        let binary = match tauri::process::current_binary(&tauri::Env::default()) {
            Ok(binary) => binary,
            Err(error) => {
                return Handoff::RefusedBeforeRelease(Refusal::NoBinary(error.to_string()));
            }
        };

        let released = release.run();
        match (self.launch)(
            &self.dbus_name,
            &binary,
            &self.args,
            self.package,
            rung,
            tag,
        ) {
            Ok(pid) => {
                eprintln!("{LOG}: handed off to {} as pid {pid}", rung.name);
                Handoff::Launched
            }
            Err(refusal) => match released {
                true => Handoff::RefusedAfterRelease(refusal),
                false => Handoff::RefusedBeforeRelease(refusal),
            },
        }
    }

    fn rung(&self, tier: usize) -> Result<&'static Tier, Refusal> {
        self.package
            .tier(tier)
            .ok_or_else(|| Refusal::NoTier(format!("{} has no tier {tier}", self.package.label())))
    }

    /// Record that no profile survived, so later launches stop here instead of
    /// walking the whole ladder again on every start.
    ///
    /// `Exhausted` outranks every other phase, so this write passes the forward
    /// check from anywhere in the chain — which is what makes the terminal state
    /// terminal even against a late receipt from the attempt that got here.
    fn note_exhausted(&self) {
        let episode = self.episode.clone().unwrap_or_else(episode::fresh);
        let Ok(tx) = self.store.lock() else {
            eprintln!("{LOG}: could not record the exhausted ladder — the state lock was busy");
            return;
        };
        let mut record = self.record(Phase::Exhausted, &episode);
        record.pid = Some(std::process::id());
        self.write(&tx, &record);
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

    fn write(&self, tx: &Transaction, record: &Record) {
        if let Err(error) = self.store.write(tx, record) {
            eprintln!("{LOG}: failed to persist {:?}: {error}", record.phase);
        }
    }
}

fn pid_alive(pid: u32) -> bool {
    // Signal 0 runs the existence and permission checks without delivering
    // anything, and unlike a /proc lookup it is not fooled by a pid namespace.
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}
