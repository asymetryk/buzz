//! Behavioural tests for the recovery ladder.
//!
//! Every rule the ladder depends on is exercised against real files and real
//! `Command` environments; nothing here spawns a process or touches the session
//! bus, because the parts that do are the two thin edges (`dbus::observe`,
//! `Command::spawn`) whose outcomes are injected as inputs.
//!
//! This module holds the ladder's own rules — generations, injected deaths, the
//! tier table, and the environment contract — and the fixtures the two
//! submodules share. `boot` covers the pre-Tauri seam (flags, forced launches,
//! refused handoffs); `transitions` covers durable writes under contention.

mod boot;
mod transitions;

use std::ffi::{OsStr, OsString};

use super::classify::{decide, Decision, Ownership};
use super::cli;
use super::dbus::{Observation, Owner};
use super::episode::{
    advance, advances_ladder, claim, fresh, may_advance, prepare, retry_of, Advance, Claimed,
    Episode, Termination, CRASH_ELIGIBILITY_WINDOW,
};
use super::launcher::{exact_env_command, Refusal, Tag, EPISODE, FORCED, GENERATION, PROFILE};
use super::profiles::{owned_present, Package, Tier};
use super::session::{reconcile, Boot, CrashResponse, Disabled};
use super::state::{Phase, Record, Store};

const VERSION: &str = "0.4.26";
const IDENTIFIER: &str = "xyz.block.buzz.app";
const TOKEN: &str = "11111111-2222-3333-4444-555555555555";

fn store() -> (tempfile::TempDir, Store) {
    let dir = tempfile::tempdir().expect("tempdir");
    let store = Store::new(dir.path());
    (dir, store)
}

fn record(phase: Phase, generation: u32, tier: usize) -> Record {
    Record::new(phase, TOKEN, generation, "shm-transport", tier, VERSION)
}

fn env_from(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
    let owned: Vec<(String, String)> = pairs
        .iter()
        .map(|(key, value)| (key.to_string(), value.to_string()))
        .collect();
    move |key: &str| {
        owned
            .iter()
            .find(|(name, _)| name == key)
            .map(|(_, value)| value.clone())
    }
}

fn owner(unique_name: &str, pid: Option<u32>) -> Observation {
    Observation::Owned(Owner {
        unique_name: unique_name.to_string(),
        pid,
    })
}

fn dead(_pid: u32) -> bool {
    false
}

fn alive(_pid: u32) -> bool {
    true
}

/// A spawn edge that always refuses, standing in for a bus that reports the
/// name still owned. No process is ever forked from a test.
fn refuse(
    _name: &str,
    _binary: &std::path::Path,
    _args: &[OsString],
    _package: Package,
    _tier: &'static Tier,
    _tag: &Tag,
) -> Result<u32, Refusal> {
    Err(Refusal::NameNotFree(
        "owned by :1.9 (pid Some(99))".to_string(),
    ))
}

/// A spawn edge that reports a child was launched, without launching one.
fn accept(
    _name: &str,
    _binary: &std::path::Path,
    _args: &[OsString],
    _package: Package,
    _tier: &'static Tier,
    _tag: &Tag,
) -> Result<u32, Refusal> {
    Ok(4242)
}

// ── Generation races ────────────────────────────────────────────────────────
//
// The claim is keyed on `(token, generation)` because the sole retry reuses the
// token. These three cases are the reason for that key.

#[test]
fn test_stale_generation_claim_does_not_block_the_retry() {
    let (_dir, store) = store();
    // Generation 0 ran and claimed; its child then died before writing.
    store.seed_claim(TOKEN, 0);
    store.seed_record(&record(Phase::Prepared, 1, 1));

    let claimed = claim(
        &store,
        &Episode {
            token: TOKEN.to_string(),
            generation: 1,
        },
    );

    assert!(matches!(claimed, Claimed::Owner { tier: 1, .. }));
    assert_eq!(store.read().expect("record").phase, Phase::Started);
}

#[test]
fn test_two_children_of_one_generation_produce_exactly_one_receipt() {
    let (_dir, store) = store();
    store.seed_record(&record(Phase::Prepared, 1, 1));
    let episode = Episode {
        token: TOKEN.to_string(),
        generation: 1,
    };

    let first = claim(&store, &episode);
    let second = claim(&store, &episode);

    assert!(matches!(first, Claimed::Owner { .. }));
    assert!(matches!(second, Claimed::Superseded(_)));
    assert_eq!(store.claim_count(), 1);
    let written = store.read().expect("record");
    assert_eq!(written.phase, Phase::Started);
    assert_eq!(written.pid, Some(std::process::id()));
}

#[test]
fn test_delayed_child_of_a_superseded_generation_writes_nothing() {
    let (_dir, store) = store();
    // The retry has already been prepared when generation 0's child finally
    // gets scheduled. Adopting the record's generation here would let it write
    // the retry's receipt.
    let prepared = record(Phase::Prepared, 1, 1);
    store.seed_record(&prepared);

    let claimed = claim(
        &store,
        &Episode {
            token: TOKEN.to_string(),
            generation: 0,
        },
    );

    assert!(matches!(claimed, Claimed::Superseded(_)));
    assert_eq!(store.read().expect("record"), prepared);
    assert_eq!(store.claim_count(), 0);
}

#[test]
fn test_claiming_an_already_started_episode_yields() {
    let (_dir, store) = store();
    store.seed_record(&record(Phase::Started, 0, 1));

    let claimed = claim(
        &store,
        &Episode {
            token: TOKEN.to_string(),
            generation: 0,
        },
    );

    assert!(matches!(claimed, Claimed::Superseded(_)));
    assert_eq!(store.claim_count(), 0);
}

#[test]
fn test_claiming_another_tokens_episode_yields() {
    let (_dir, store) = store();
    store.seed_record(&record(Phase::Prepared, 0, 1));

    let claimed = claim(
        &store,
        &Episode {
            token: "a-different-token".to_string(),
            generation: 0,
        },
    );

    assert!(matches!(claimed, Claimed::Superseded(_)));
    assert_eq!(store.claim_count(), 0);
}

#[test]
fn test_retry_reuses_the_token_and_advances_the_generation() {
    let retry = retry_of(&record(Phase::Prepared, 0, 2));
    assert_eq!(retry.token, TOKEN);
    assert_eq!(retry.generation, 1);
}

#[test]
fn test_fresh_episodes_are_distinct_at_generation_zero() {
    let (first, second) = (fresh(), fresh());
    assert_ne!(first.token, second.token);
    assert_eq!(first.generation, 0);
}

// ── Injected deaths at the four commit points ───────────────────────────────

#[test]
fn test_death_before_the_claim_retries_the_same_tier() {
    let decision = decide(
        &record(Phase::Prepared, 0, 2),
        &Observation::Free,
        None,
        VERSION,
        &dead,
    );
    assert!(matches!(decision, Decision::RetrySameTier { tier: 2, .. }));
}

#[test]
fn test_death_before_the_claim_with_the_retry_spent_advances() {
    let decision = decide(
        &record(Phase::Prepared, 1, 2),
        &Observation::Free,
        None,
        VERSION,
        &dead,
    );
    assert!(matches!(decision, Decision::AdvanceOrStop { tier: 2, .. }));
}

#[test]
fn test_death_after_the_claim_before_ownership_advances() {
    let mut started = record(Phase::Started, 0, 1);
    started.pid = Some(4242);
    let decision = decide(&started, &Observation::Free, None, VERSION, &dead);
    assert!(matches!(decision, Decision::AdvanceOrStop { tier: 1, .. }));
}

#[test]
fn test_death_after_ownership_before_confirm_advances() {
    let mut owned = record(Phase::Owned, 0, 1);
    owned.pid = Some(4242);
    owned.unique_name = Some(":1.7".to_string());
    owned.bus_id = Some("bus-a".to_string());
    let decision = decide(&owned, &Observation::Free, Some("bus-a"), VERSION, &dead);
    assert!(matches!(decision, Decision::AdvanceOrStop { tier: 1, .. }));
}

#[test]
fn test_death_after_confirm_reuses_the_profile() {
    let mut confirmed = record(Phase::Confirmed, 0, 2);
    confirmed.unique_name = Some(":1.7".to_string());
    confirmed.bus_id = Some("bus-a".to_string());
    let decision = decide(
        &confirmed,
        &Observation::Free,
        Some("bus-a"),
        VERSION,
        &dead,
    );
    assert_eq!(decision, Decision::ReuseProfile { tier: 2 });
}

// ── Live episodes and handoff failure ───────────────────────────────────────

#[test]
fn test_live_child_in_the_pre_ownership_interval_defers() {
    let mut started = record(Phase::Started, 0, 1);
    started.pid = Some(4242);
    let decision = decide(&started, &Observation::Free, None, VERSION, &alive);
    assert!(matches!(decision, Decision::Defer(_)));
}

#[test]
fn test_recorded_child_owning_the_name_defers() {
    let mut started = record(Phase::Started, 0, 1);
    started.pid = Some(4242);
    let decision = decide(&started, &owner(":1.7", Some(4242)), None, VERSION, &dead);
    assert!(matches!(decision, Decision::Defer(_)));
}

#[test]
fn test_a_stranger_owning_the_name_is_handoff_failure() {
    let mut started = record(Phase::Started, 0, 1);
    started.pid = Some(4242);
    let decision = decide(&started, &owner(":1.7", Some(9999)), None, VERSION, &dead);
    assert!(matches!(decision, Decision::AdvanceOrStop { tier: 1, .. }));
}

#[test]
fn test_an_unidentifiable_owner_is_handoff_failure_not_a_free_name() {
    let mut started = record(Phase::Started, 0, 1);
    started.pid = Some(4242);
    // No owner pid: the bus refused GetConnectionUnixProcessID.
    let decision = decide(&started, &owner(":1.7", None), None, VERSION, &dead);
    assert!(matches!(decision, Decision::AdvanceOrStop { tier: 1, .. }));
}

#[test]
fn test_an_unreachable_bus_is_never_read_as_a_free_name() {
    let mut owned = record(Phase::Owned, 0, 1);
    owned.unique_name = Some(":1.7".to_string());
    owned.bus_id = Some("bus-a".to_string());
    let observation = Observation::Unavailable("no session bus".to_string());
    assert_eq!(
        super::classify::correlate(&owned, &observation, Some("bus-a")),
        Ownership::Uncorrelatable
    );
}

#[test]
fn test_a_receipt_from_another_bus_does_not_correlate() {
    let mut owned = record(Phase::Owned, 0, 1);
    owned.unique_name = Some(":1.7".to_string());
    owned.bus_id = Some("bus-a".to_string());
    // Same unique name, different bus — `:1.7` is only meaningful on the bus
    // that issued it.
    let decision = decide(
        &owned,
        &owner(":1.7", Some(1)),
        Some("bus-b"),
        VERSION,
        &dead,
    );
    assert!(matches!(decision, Decision::AdvanceOrStop { tier: 1, .. }));
}

#[test]
fn test_the_recorded_owner_still_holding_the_name_defers() {
    let mut owned = record(Phase::Owned, 0, 1);
    owned.unique_name = Some(":1.7".to_string());
    owned.bus_id = Some("bus-a".to_string());
    let decision = decide(
        &owned,
        &owner(":1.7", Some(1)),
        Some("bus-a"),
        VERSION,
        &dead,
    );
    assert!(matches!(decision, Decision::Defer(_)));
}

#[test]
fn test_a_confirmed_instance_still_running_defers() {
    let mut confirmed = record(Phase::Confirmed, 0, 2);
    confirmed.unique_name = Some(":1.7".to_string());
    confirmed.bus_id = Some("bus-a".to_string());
    let decision = decide(
        &confirmed,
        &owner(":1.7", Some(1)),
        Some("bus-a"),
        VERSION,
        &dead,
    );
    assert!(matches!(decision, Decision::Defer(_)));
}

// ── The crash-free startup fact, and what advances the ladder ───────────────

#[test]
fn test_a_confirmed_profile_from_another_version_is_discarded() {
    let confirmed = record(Phase::Confirmed, 0, 2);
    let decision = decide(&confirmed, &Observation::Free, None, "0.4.27", &dead);
    assert!(matches!(decision, Decision::DiscardAndBaseline { .. }));
}

#[test]
fn test_only_a_crash_inside_the_startup_window_advances_the_ladder() {
    let inside = CRASH_ELIGIBILITY_WINDOW - std::time::Duration::from_millis(1);
    let outside = CRASH_ELIGIBILITY_WINDOW + std::time::Duration::from_millis(1);

    assert!(advances_ladder(Termination::Crashed, inside));
    assert!(advances_ladder(
        Termination::Crashed,
        CRASH_ELIGIBILITY_WINDOW
    ));
    // A crash after the window is a startup-shaped failure, logged but never
    // charged against the ladder.
    assert!(!advances_ladder(Termination::Crashed, outside));
    // An OOM kill or our own terminate_web_process is not a rendering failure.
    assert!(!advances_ladder(Termination::Other, inside));
}

// ── Case 10: the per-package cap and terminal behaviour ─────────────────────

#[test]
fn test_appimage_has_four_tiers_and_native_five() {
    assert_eq!(Package::AppImage.tiers().len(), 4);
    assert_eq!(Package::Native.tiers().len(), 5);
    // The AppImage ladder stops before the x11 tier: linuxdeploy's AppRun hook
    // already pins GDK_BACKEND=x11, so that tier would spend a relaunch on a
    // no-op.
    assert!(Package::AppImage.tier_named("x11-fallback").is_none());
    assert_eq!(Package::Native.tier_named("x11-fallback"), Some(4));
}

#[test]
fn test_no_tier_sets_the_compositing_variable() {
    // Held out of the table pending the 3-var vs 4-var isolation on #2643,
    // while still owned so a user value opts out.
    for package in [Package::AppImage, Package::Native] {
        assert!(package
            .owned_vars()
            .contains(&"WEBKIT_DISABLE_COMPOSITING_MODE"));
        for tier in package.tiers() {
            assert!(!tier
                .vars
                .iter()
                .any(|(key, _)| *key == "WEBKIT_DISABLE_COMPOSITING_MODE"));
        }
    }
}

#[test]
fn test_the_ladder_spends_one_attempt_per_tier_then_stops() {
    for package in [Package::AppImage, Package::Native] {
        let terminal = package.terminal_tier();
        for tier in 0..terminal {
            assert_eq!(advance(package, tier), Advance::Tier(tier + 1));
        }
        assert_eq!(advance(package, terminal), Advance::Exhausted);
        // Nothing past the terminal tier is reachable, so the cap cannot be
        // exceeded by a record claiming a tier that does not exist.
        assert_eq!(advance(package, terminal + 1), Advance::Exhausted);
    }
}

#[test]
fn test_an_exhausted_record_stops_without_advancing() {
    let decision = decide(
        &record(Phase::Exhausted, 0, 3),
        &Observation::Free,
        None,
        VERSION,
        &dead,
    );
    assert_eq!(decision, Decision::StopExhausted { tier: 3 });
}

// ── The environment contract ────────────────────────────────────────────────

#[test]
fn test_any_owned_variable_disables_recovery_whatever_its_value() {
    // `0` and empty are the two values a truthiness check would wrongly ignore.
    for value in ["1", "0", ""] {
        let env = env_from(&[("WEBKIT_DISABLE_DMABUF_RENDERER", value)]);
        let present = owned_present(Package::Native, &env);
        assert_eq!(
            present,
            vec![format!("WEBKIT_DISABLE_DMABUF_RENDERER={value}")]
        );

        let dir = tempfile::tempdir().expect("tempdir");
        match reconcile(
            Ok(dir.path().to_path_buf()),
            IDENTIFIER,
            VERSION,
            Vec::new(),
            &env,
            refuse,
        ) {
            Boot::Off(Disabled::UserEnv(vars)) => assert_eq!(vars, present),
            _ => panic!("a user assignment of an owned var must disable recovery"),
        }
    }
}

#[test]
fn test_appimage_does_not_treat_the_pinned_gdk_backend_as_user_input() {
    // The AppRun hook exports GDK_BACKEND=x11 before the binary starts, so its
    // provenance is unrecoverable and owning it would disable the ladder on
    // every AppImage launch.
    let env = env_from(&[("APPIMAGE", "/tmp/Buzz.AppImage"), ("GDK_BACKEND", "x11")]);
    assert_eq!(Package::detect(&env), Package::AppImage);
    assert!(owned_present(Package::AppImage, &env).is_empty());
    assert!(!Package::AppImage.owned_vars().contains(&"GDK_BACKEND"));

    let native = env_from(&[("GDK_BACKEND", "x11")]);
    assert_eq!(Package::detect(&native), Package::Native);
    assert_eq!(owned_present(Package::Native, &native).len(), 1);
}

#[test]
fn test_a_recovery_child_does_not_read_its_injected_profile_as_user_input() {
    let dir = tempfile::tempdir().expect("tempdir");
    let store = Store::new(dir.path());
    store.seed_record(&record(Phase::Prepared, 0, 1));

    // Exactly what the parent hands a tier-1 child.
    let env = env_from(&[
        ("WEBKIT_DMABUF_RENDERER_FORCE_SHM", "1"),
        (PROFILE, "shm-transport"),
        (EPISODE, TOKEN),
        (GENERATION, "0"),
    ]);

    match reconcile(
        Ok(dir.path().to_path_buf()),
        IDENTIFIER,
        VERSION,
        Vec::new(),
        &env,
        refuse,
    ) {
        Boot::Run(session) => assert_eq!(session.profile_name(), "shm-transport"),
        _ => panic!("a tagged child runs the environment it was given"),
    }
    assert_eq!(store.read().expect("record").phase, Phase::Started);
}

#[test]
fn test_a_child_that_loses_its_claim_exits_instead_of_racing_the_owner() {
    let dir = tempfile::tempdir().expect("tempdir");
    let store = Store::new(dir.path());
    store.seed_record(&record(Phase::Prepared, 0, 1));
    store.seed_claim(TOKEN, 0);

    let env = env_from(&[
        ("WEBKIT_DMABUF_RENDERER_FORCE_SHM", "1"),
        (PROFILE, "shm-transport"),
        (EPISODE, TOKEN),
        (GENERATION, "0"),
    ]);
    // Exiting, not running on: a loser that reached Tauri could take the
    // single-instance name ahead of the owner named in the durable `started`
    // receipt, and the owner would then exit as a duplicate.
    match reconcile(
        Ok(dir.path().to_path_buf()),
        IDENTIFIER,
        VERSION,
        Vec::new(),
        &env,
        refuse,
    ) {
        Boot::Superseded => {}
        _ => panic!("a claim loser must exit before competing for the name"),
    }
    assert_eq!(store.read().expect("record").phase, Phase::Prepared);
}

#[test]
fn test_a_tag_without_a_generation_is_rejected_rather_than_read_as_zero() {
    // Defaulting a malformed tag to generation 0 would let it claim the
    // original attempt of an episode that has already been retried.
    let env = env_from(&[(PROFILE, "shm-transport"), (EPISODE, TOKEN)]);
    assert_eq!(Tag::read(&env), None);

    let complete = env_from(&[
        (PROFILE, "shm-transport"),
        (EPISODE, TOKEN),
        (GENERATION, "1"),
    ]);
    let tag = Tag::read(&complete).expect("tag");
    assert_eq!(tag.episode.expect("episode").generation, 1);
}

#[test]
fn test_a_forced_child_carries_a_profile_but_no_episode() {
    let env = env_from(&[(PROFILE, "no-accel"), (FORCED, "1")]);
    let tag = Tag::read(&env).expect("tag");
    assert_eq!(tag.profile, "no-accel");
    assert_eq!(tag.episode, None);
}

// ── The exact-environment child command ─────────────────────────────────────

fn envs_of(command: &std::process::Command) -> Vec<(String, Option<String>)> {
    let mut envs: Vec<(String, Option<String>)> = command
        .get_envs()
        .map(|(key, value)| {
            (
                key.to_string_lossy().into_owned(),
                value.map(|v| v.to_string_lossy().into_owned()),
            )
        })
        .collect();
    envs.sort();
    envs
}

#[test]
fn test_the_child_environment_is_the_tier_and_nothing_inherited() {
    let package = Package::Native;
    let tier = package.tier(1).expect("tier 1");
    let tag = Tag {
        episode: Some(Episode {
            token: TOKEN.to_string(),
            generation: 1,
        }),
        profile: tier.name.to_string(),
    };
    let command = exact_env_command("/bin/true".into(), &[], package, tier, &tag);
    let envs = envs_of(&command);

    // Every owned variable is cleared, so a previous tier's profile can never
    // be inherited into the next attempt.
    for key in package.owned_vars() {
        let cleared = envs
            .iter()
            .any(|(name, value)| name == key && value.is_none());
        let set = envs
            .iter()
            .any(|(name, value)| name == key && value.is_some());
        assert!(cleared != set, "{key} must be either cleared or set once");
    }
    assert_eq!(
        envs.iter()
            .find(|(name, _)| name == "WEBKIT_DMABUF_RENDERER_FORCE_SHM"),
        Some(&(
            "WEBKIT_DMABUF_RENDERER_FORCE_SHM".to_string(),
            Some("1".to_string())
        ))
    );
    assert_eq!(
        envs.iter().find(|(name, _)| name == GENERATION),
        Some(&(GENERATION.to_string(), Some("1".to_string())))
    );
    // A prepared child is never also a forced child.
    assert_eq!(
        envs.iter().find(|(name, _)| name == FORCED),
        Some(&(FORCED.to_string(), None))
    );
}

#[test]
fn test_the_appimage_child_leaves_the_pinned_backend_alone() {
    let package = Package::AppImage;
    let tier = package.tier(3).expect("terminal AppImage tier");
    let tag = Tag {
        episode: None,
        profile: tier.name.to_string(),
    };
    let command = exact_env_command("/bin/true".into(), &[], package, tier, &tag);
    // Removing GDK_BACKEND here would be theatre: AppRun re-exports it before
    // the child binary starts.
    assert!(!envs_of(&command)
        .iter()
        .any(|(name, _)| name == "GDK_BACKEND"));
}

#[test]
fn test_the_child_inherits_the_parents_arguments() {
    let package = Package::Native;
    let tier = package.tier(1).expect("tier 1");
    let tag = Tag {
        episode: None,
        profile: tier.name.to_string(),
    };
    let args = [OsString::from("buzz://channel/1")];
    let command = exact_env_command("/bin/true".into(), &args, package, tier, &tag);
    assert_eq!(
        command.get_args().collect::<Vec<_>>(),
        vec![OsStr::new("buzz://channel/1")]
    );
}

// ── Durability ──────────────────────────────────────────────────────────────

#[test]
fn test_an_unparsable_record_reads_as_absent() {
    let (_dir, store) = store();
    store.seed_record(&record(Phase::Prepared, 0, 1));
    let path = store.record_path_for_test();
    std::fs::write(&path, b"{not json").expect("corrupt");
    assert_eq!(store.read(), None);
}

#[test]
fn test_a_record_survives_a_round_trip_with_its_owner_identity() {
    let (_dir, store) = store();
    let mut written = record(Phase::Owned, 1, 2);
    written.pid = Some(4242);
    written.unique_name = Some(":1.7".to_string());
    written.bus_id = Some("bus-a".to_string());
    store.seed_record(&written);
    assert_eq!(store.read(), Some(written));
}

#[test]
fn test_preparing_a_record_names_the_tier_it_will_run() {
    let prepared = prepare(
        &Episode {
            token: TOKEN.to_string(),
            generation: 0,
        },
        Package::AppImage,
        2,
        VERSION,
    );
    assert_eq!(prepared.phase, Phase::Prepared);
    assert_eq!(prepared.profile, "cpu-raster");
    assert_eq!(prepared.tier, 2);
    assert_eq!(prepared.version, VERSION);
}
