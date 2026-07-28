//! Boot-seam behaviour: the two flags, forced launches, and refused handoffs.
//!
//! Everything here is decided by `reconcile` before Tauri exists, which is the
//! only place a launch can still change its own environment or decline to
//! start at all.

use super::*;

// ── Flags and reset ─────────────────────────────────────────────────────────

#[test]
fn test_the_renderer_flags_parse_independently_of_position() {
    let args = [
        OsStr::new("buzz://channel/1"),
        OsStr::new("--safe-rendering"),
    ];
    let flags = cli::parse(args);
    assert!(flags.safe_rendering);
    assert!(!flags.reset_rendering_mode);

    let none = cli::parse([OsStr::new("--safe-renderingX")]);
    assert!(!none.safe_rendering);
}

#[test]
fn test_safe_rendering_forces_the_terminal_tier_without_persisting() {
    let dir = tempfile::tempdir().expect("tempdir");
    let store = Store::new(dir.path());
    store.seed_record(&record(Phase::Confirmed, 0, 0));
    let env = env_from(&[]);

    // Native, so the terminal tier is x11-fallback and the handoff would need a
    // real spawn — the assertion is that the record is left untouched.
    let boot = reconcile(
        Ok(dir.path().to_path_buf()),
        IDENTIFIER,
        VERSION,
        vec![OsString::from(cli::SAFE_RENDERING)],
        &env,
        refuse,
    );
    assert!(!matches!(boot, Boot::Reset));
    let after = store.read().expect("record");
    assert_eq!(after.phase, Phase::Confirmed);
    assert_eq!(after.tier, 0);
}

#[test]
fn test_reset_rendering_mode_clears_the_state_and_does_not_launch() {
    let dir = tempfile::tempdir().expect("tempdir");
    let store = Store::new(dir.path());
    store.seed_record(&record(Phase::Confirmed, 0, 2));
    store.seed_claim(TOKEN, 0);
    let env = env_from(&[]);

    let boot = reconcile(
        Ok(dir.path().to_path_buf()),
        IDENTIFIER,
        VERSION,
        vec![OsString::from(cli::RESET_RENDERING_MODE)],
        &env,
        refuse,
    );

    assert!(matches!(boot, Boot::Reset));
    assert_eq!(store.read(), None);
    assert_eq!(store.claim_count(), 0);
}

#[test]
fn test_recovery_is_off_when_no_state_directory_exists() {
    let env = env_from(&[]);
    let boot = reconcile(
        Err("no user data directory".to_string()),
        IDENTIFIER,
        VERSION,
        Vec::new(),
        &env,
        refuse,
    );
    assert!(matches!(boot, Boot::Off(Disabled::NoStateDir(_))));
}

#[test]
fn test_a_baseline_launch_runs_here_without_writing_a_record() {
    let dir = tempfile::tempdir().expect("tempdir");
    let store = Store::new(dir.path());
    let env = env_from(&[]);

    match reconcile(
        Ok(dir.path().to_path_buf()),
        IDENTIFIER,
        VERSION,
        Vec::new(),
        &env,
        refuse,
    ) {
        Boot::Run(session) => assert_eq!(session.profile_name(), "full-gpu"),
        _ => panic!("a first launch runs tier 0 in this process"),
    }
    assert_eq!(store.read(), None);
}

// ── Forced launches, refused handoffs, and reaching reset ───────────────────
//
// Three rules that only hold at the boot seam: a manual override must not teach
// the ladder anything, a handoff that never happened must not cost a retry, and
// the escape hatch must stay reachable for the user most likely to need it.

#[test]
fn test_a_forced_child_runs_its_profile_without_writing_a_record() {
    // A --safe-rendering parent hands off with BUZZ_RENDER_FORCED and no
    // episode. The child must run the profile and persist nothing: a forced
    // launch is not evidence about any tier.
    let dir = tempfile::tempdir().expect("tempdir");
    let store = Store::new(dir.path());
    let env = env_from(&[(PROFILE, "no-accel"), (FORCED, "1")]);

    match reconcile(
        Ok(dir.path().to_path_buf()),
        IDENTIFIER,
        VERSION,
        Vec::new(),
        &env,
        refuse,
    ) {
        Boot::Run(session) => assert_eq!(session.profile_name(), "no-accel"),
        _ => panic!("a forced child runs in this process"),
    }
    assert_eq!(store.read(), None);
    assert_eq!(store.claim_count(), 0);
}

#[test]
fn test_a_forced_child_that_crashes_does_not_advance_or_persist() {
    let dir = tempfile::tempdir().expect("tempdir");
    let store = Store::new(dir.path());
    let env = env_from(&[(PROFILE, "cpu-raster"), (FORCED, "1")]);

    // `accept`, not `refuse`: with a spawn edge that succeeds, a forced launch
    // that was wrongly tracked would really hand off and leave a record behind.
    // Against `refuse` the rollback would hide the difference.
    let Boot::Run(session) = reconcile(
        Ok(dir.path().to_path_buf()),
        IDENTIFIER,
        VERSION,
        Vec::new(),
        &env,
        accept,
    ) else {
        panic!("a forced child runs in this process");
    };

    // Even a genuine startup crash must leave a forced launch untracked —
    // otherwise the manual override would rewrite the ladder's own record.
    assert!(matches!(
        session.on_web_process_terminated(Termination::Crashed, &|| {}),
        CrashResponse::Continue
    ));
    assert_eq!(store.read(), None);
    // The confirmation receipt is the other write a forced launch must not make:
    // it is the persisted "last crash-free startup profile" fact, and a manual
    // override is not evidence about any tier.
    session.note_owned();
    session.note_confirmed();
    assert_eq!(store.read(), None);
}

#[test]
fn test_a_refused_handoff_does_not_spend_the_rungs_retry() {
    // A confirmed tier-2 record: this launch wants to re-run tier 2, which
    // needs a child. The spawn is refused, so the durable state must be exactly
    // what it was — a leftover `prepared` record would make the next launch
    // burn this rung's one retry on a failure that was never about rendering.
    let dir = tempfile::tempdir().expect("tempdir");
    let store = Store::new(dir.path());
    let before = record(Phase::Confirmed, 0, 2);
    store.seed_record(&before);
    let env = env_from(&[]);

    match reconcile(
        Ok(dir.path().to_path_buf()),
        IDENTIFIER,
        VERSION,
        Vec::new(),
        &env,
        refuse,
    ) {
        Boot::Run(session) => {
            // The handoff did not happen, so this process is still the baseline
            // it was launched as and must not claim the tier it wanted.
            assert_eq!(session.profile_name(), "full-gpu");
        }
        _ => panic!("a refused handoff leaves the app running here"),
    }
    assert_eq!(store.read(), Some(before));
}

#[test]
fn test_a_post_release_refusal_strands_the_parent_and_leaves_no_record() {
    // Same rollback rule with nothing on disk, plus the lifecycle invariant:
    // the live crash path releases the single-instance name before probing it,
    // so a refusal from the launch edge arrives *after* the plugin is destroyed.
    // This process can never take the name back, so it must not run on.
    let dir = tempfile::tempdir().expect("tempdir");
    let store = Store::new(dir.path());
    let env = env_from(&[]);
    let Boot::Run(session) = reconcile(
        Ok(dir.path().to_path_buf()),
        IDENTIFIER,
        VERSION,
        Vec::new(),
        &env,
        refuse,
    ) else {
        panic!("a first launch runs tier 0 here");
    };

    // The closure records the crossing, which is the only way to see it: a
    // no-op closure cannot distinguish a refusal before the release from one
    // after it.
    let released = std::cell::Cell::new(false);
    let response = session.on_web_process_terminated(Termination::Crashed, &|| released.set(true));

    assert!(
        released.get(),
        "the live crash path releases the name before probing it"
    );
    assert!(
        matches!(response, CrashResponse::Stranded),
        "a refusal after the release must exit, never return to normal operation"
    );
    // The prepared record is still rolled back: no child exists to claim it.
    assert_eq!(store.read(), None);
}

#[test]
fn test_a_pre_release_refusal_leaves_the_app_running_with_its_name() {
    // The mirror of the stranding rule: a refusal raised *before* the release
    // is recoverable by construction, because nothing was given up. An app data
    // path that cannot hold a directory makes the record write fail, which is
    // the earliest refusal the live crash path can reach.
    let dir = tempfile::tempdir().expect("tempdir");
    let blocker = dir.path().join("not-a-directory");
    std::fs::write(&blocker, b"").expect("blocker");
    let app_data_dir = blocker.join("state");
    let env = env_from(&[]);

    // Tier 0 needs no durable state, so this launch still comes up normally.
    let Boot::Run(session) = reconcile(
        Ok(app_data_dir),
        IDENTIFIER,
        VERSION,
        Vec::new(),
        &env,
        accept,
    ) else {
        panic!("a first launch runs tier 0 here even with no usable state dir");
    };

    let released = std::cell::Cell::new(false);
    let response = session.on_web_process_terminated(Termination::Crashed, &|| released.set(true));

    assert!(
        !released.get(),
        "a refusal that precedes the release must not have released the name"
    );
    assert!(
        matches!(response, CrashResponse::Continue),
        "the app still owns its name, so it carries on"
    );
}

#[test]
fn test_a_successful_handoff_leaves_the_prepared_record_for_the_child() {
    // The mirror of the rollback: when the child really is launched, the
    // prepared record must survive for it to claim.
    let dir = tempfile::tempdir().expect("tempdir");
    let store = Store::new(dir.path());
    let env = env_from(&[]);
    let Boot::Run(session) = reconcile(
        Ok(dir.path().to_path_buf()),
        IDENTIFIER,
        VERSION,
        Vec::new(),
        &env,
        accept,
    ) else {
        panic!("a first launch runs tier 0 here");
    };

    assert!(matches!(
        session.on_web_process_terminated(Termination::Crashed, &|| {}),
        CrashResponse::HandedOff
    ));
    let prepared = store.read().expect("the child's record");
    assert_eq!(prepared.phase, Phase::Prepared);
    assert_eq!(prepared.tier, 1);
    assert_eq!(prepared.generation, 0);
}

// ── The --safe-rendering conflict ───────────────────────────────────────────

#[test]
fn test_safe_rendering_against_a_user_set_owned_var_is_fatal_not_ignored() {
    // Two incompatible answers to one question. Starting anyway would ignore a
    // rescue flag from a user whose app does not come up; overriding would
    // discard configuration they typed. Neither is guessed.
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_from(&[("WEBKIT_DISABLE_DMABUF_RENDERER", "0")]);

    let boot = reconcile(
        Ok(dir.path().to_path_buf()),
        IDENTIFIER,
        VERSION,
        vec![OsString::from(cli::SAFE_RENDERING)],
        &env,
        refuse,
    );

    let Boot::Fatal(diagnostic) = boot else {
        panic!("--safe-rendering under a user-set owned var must not start the app");
    };
    // The diagnostic has to name what is set and what to unset, or the user
    // cannot act on it. `0` is the value a truthiness check would drop.
    assert!(diagnostic.contains(cli::SAFE_RENDERING), "{diagnostic}");
    assert!(
        diagnostic.contains("WEBKIT_DISABLE_DMABUF_RENDERER=0"),
        "{diagnostic}"
    );
}

#[test]
fn test_an_owned_var_without_the_flag_still_only_disables_recovery() {
    // The conflict is specific to the flag. On its own a user assignment is a
    // preference, not a contradiction, so the app starts under it.
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_from(&[("WEBKIT_DISABLE_DMABUF_RENDERER", "0")]);

    let boot = reconcile(
        Ok(dir.path().to_path_buf()),
        IDENTIFIER,
        VERSION,
        Vec::new(),
        &env,
        refuse,
    );

    assert!(matches!(boot, Boot::Off(Disabled::UserEnv(_))));
}

#[test]
fn test_reset_rendering_mode_works_even_with_an_owned_var_set() {
    // The user who set WEBKIT_DISABLE_DMABUF_RENDERER by hand is exactly the
    // user most likely to be clearing state an earlier run left behind. If the
    // opt-out returned first, the escape hatch would be unreachable for them.
    let dir = tempfile::tempdir().expect("tempdir");
    let store = Store::new(dir.path());
    store.seed_record(&record(Phase::Confirmed, 0, 2));
    let env = env_from(&[("WEBKIT_DISABLE_DMABUF_RENDERER", "1")]);

    let boot = reconcile(
        Ok(dir.path().to_path_buf()),
        IDENTIFIER,
        VERSION,
        vec![OsString::from(cli::RESET_RENDERING_MODE)],
        &env,
        refuse,
    );

    assert!(matches!(boot, Boot::Reset));
    assert_eq!(store.read(), None);
}
