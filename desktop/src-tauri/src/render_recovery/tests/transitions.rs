//! Durable transitions under real contention, and the rules that make a late
//! writer harmless.
//!
//! The exclusive claim only serializes the creation of one claim file, so these
//! drive the transitions themselves from two threads through a barrier with the
//! state lock held across the window each race needs.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Barrier};

use super::*;

// ── Serialized transitions under real contention ────────────────────────────
//
// The exclusive claim only serializes the creation of one claim file. These
// tests drive the transitions themselves from two threads through a barrier,
// with the state lock held across the window the race needs, so the ordering is
// forced rather than hoped for.
//
// `flock` is per-open-file-description, so two `Store` values in one process
// contend exactly as two processes would — verified by the blocking assertions
// below, which only hold if the second writer really waits.

/// Give a thread parked on the state lock time to get there. Only the
/// *contention* evidence depends on this interval; every invariant assertion is
/// ordering-based and holds however the sleep lands.
const CONTENTION_WINDOW: std::time::Duration = std::time::Duration::from_millis(150);

#[test]
fn test_a_stale_generation_cannot_overwrite_a_record_prepared_while_it_waited() {
    // The interleaving Thufir named: a delayed generation-0 child is mid-claim
    // when another invocation durably prepares generation 1. Split into three
    // unsynchronized operations the child would read gen 0 as current, pause,
    // and then stamp its stale `started` over the newer record.
    let dir = tempfile::tempdir().expect("tempdir");
    let store = Store::new(dir.path());
    store.seed_record(&record(Phase::Prepared, 0, 1));

    // Held for the whole window in which the stale child is trying to claim.
    let tx = store.lock().expect("lock");

    let path = dir.path().to_path_buf();
    let arrived = Arc::new(Barrier::new(2));
    let finished = Arc::new(AtomicBool::new(false));
    let stale = {
        let (arrived, finished) = (Arc::clone(&arrived), Arc::clone(&finished));
        std::thread::spawn(move || {
            let store = Store::new(&path);
            arrived.wait();
            let claimed = claim(
                &store,
                &Episode {
                    token: TOKEN.to_string(),
                    generation: 0,
                },
            );
            finished.store(true, Ordering::SeqCst);
            claimed
        })
    };

    arrived.wait();
    std::thread::sleep(CONTENTION_WINDOW);
    assert!(
        !finished.load(Ordering::SeqCst),
        "the claim must block on the state lock, not proceed beside the holder"
    );

    // The retry becomes durable while the stale child is parked.
    let prepared = record(Phase::Prepared, 1, 1);
    store.write(&tx, &prepared).expect("prepare generation 1");
    drop(tx);

    let claimed = stale.join().expect("stale child");
    // Only reachable if the child read the record *after* the write above, which
    // is the serialization this test exists to prove.
    assert!(
        matches!(claimed, Claimed::Superseded(_)),
        "a generation-0 child must be turned away once generation 1 is current"
    );
    assert_eq!(store.read().as_ref(), Some(&prepared));
    assert_eq!(store.claim_count(), 0);
}

#[test]
fn test_a_confirmation_racing_a_handoff_does_not_resurrect_its_episode() {
    // `note_confirmed` runs from the startup-boundary thread, so it can be in
    // flight when a crash handoff has already prepared the next token. Writing
    // the old episode's `confirmed` over that token would make the ladder reuse
    // a profile the crash just disproved.
    let dir = tempfile::tempdir().expect("tempdir");
    let store = Store::new(dir.path());
    store.seed_record(&record(Phase::Prepared, 0, 1));
    let env = env_from(&[
        ("WEBKIT_DMABUF_RENDERER_FORCE_SHM", "1"),
        (PROFILE, "shm-transport"),
        (EPISODE, TOKEN),
        (GENERATION, "0"),
    ]);
    let Boot::Run(session) = reconcile(
        Ok(dir.path().to_path_buf()),
        IDENTIFIER,
        VERSION,
        Vec::new(),
        &env,
        accept,
    ) else {
        panic!("the tagged child claims its episode");
    };
    session.note_owned();
    assert_eq!(store.read().expect("record").phase, Phase::Owned);

    let tx = store.lock().expect("lock");

    let arrived = Arc::new(Barrier::new(2));
    let finished = Arc::new(AtomicBool::new(false));
    let confirming = {
        let (session, arrived, finished) = (
            Arc::clone(&session),
            Arc::clone(&arrived),
            Arc::clone(&finished),
        );
        std::thread::spawn(move || {
            arrived.wait();
            session.note_confirmed();
            finished.store(true, Ordering::SeqCst);
        })
    };

    arrived.wait();
    std::thread::sleep(CONTENTION_WINDOW);
    assert!(
        !finished.load(Ordering::SeqCst),
        "the confirmation must block on the state lock"
    );

    // What the crash handoff writes: a new token at the next rung.
    let handed_off = Record::new(
        Phase::Prepared,
        "a-newer-token",
        0,
        "cpu-raster",
        2,
        VERSION,
    );
    store
        .write(&tx, &handed_off)
        .expect("prepare the next rung");
    drop(tx);

    confirming.join().expect("confirming thread");
    assert_eq!(
        store.read().as_ref(),
        Some(&handed_off),
        "the superseded episode's confirmation must be rejected, not written"
    );
}

/// Spawn counter for the two-callback race below. A `static` because the launch
/// edge is a plain fn pointer with no captured state; only that one test reads
/// it, so no other test can perturb the count.
static SPAWNS: AtomicUsize = AtomicUsize::new(0);

fn count_spawns(
    _name: &str,
    _binary: &std::path::Path,
    _args: &[OsString],
    _package: Package,
    _tier: &'static Tier,
    _tag: &Tag,
) -> Result<u32, Refusal> {
    Ok(SPAWNS.fetch_add(1, Ordering::SeqCst) as u32 + 1)
}

#[test]
fn test_two_termination_callbacks_hand_off_exactly_once() {
    // WebKit can report a second termination while the first handoff is in
    // flight. Two handoffs would spawn two children for two episodes — two live
    // Buzz processes racing one name, with the record naming only one of them.
    SPAWNS.store(0, Ordering::SeqCst);
    let dir = tempfile::tempdir().expect("tempdir");
    let store = Store::new(dir.path());
    let env = env_from(&[]);
    let Boot::Run(session) = reconcile(
        Ok(dir.path().to_path_buf()),
        IDENTIFIER,
        VERSION,
        Vec::new(),
        &env,
        count_spawns,
    ) else {
        panic!("a first launch runs tier 0 here");
    };

    let arrived = Arc::new(Barrier::new(2));
    let callbacks: Vec<_> = (0..2)
        .map(|_| {
            let (session, arrived) = (Arc::clone(&session), Arc::clone(&arrived));
            std::thread::spawn(move || {
                arrived.wait();
                matches!(
                    session.on_web_process_terminated(Termination::Crashed, &|| {}),
                    CrashResponse::HandedOff
                )
            })
        })
        .collect();

    let handed_off = callbacks
        .into_iter()
        .map(|thread| thread.join().expect("callback"))
        .filter(|handed| *handed)
        .count();

    assert_eq!(handed_off, 1, "exactly one callback may hand off");
    assert_eq!(
        SPAWNS.load(Ordering::SeqCst),
        1,
        "exactly one child may be spawned"
    );
    // One survivor, and the durable record names the episode it was spawned for.
    let prepared = store.read().expect("the survivor's record");
    assert_eq!(prepared.phase, Phase::Prepared);
    assert_eq!(prepared.tier, 1);
    assert_eq!(prepared.generation, 0);
    assert_eq!(store.claim_count(), 0);
}

/// App-data path for the rollback race below, so the refusing launch edge can
/// write a competing record from inside the window the parent left open. A
/// `static` for the same reason as `SPAWNS`: the launch edge captures nothing.
static RACING_STORE: std::sync::Mutex<Option<std::path::PathBuf>> = std::sync::Mutex::new(None);

/// The competing record: a different episode, prepared by "another launch"
/// during the spawn window, then refused so the parent reaches its rollback.
fn refuse_after_a_competing_prepare(
    _name: &str,
    _binary: &std::path::Path,
    _args: &[OsString],
    _package: Package,
    _tier: &'static Tier,
    _tag: &Tag,
) -> Result<u32, Refusal> {
    let path = RACING_STORE.lock().expect("path").clone().expect("path");
    Store::new(&path).seed_record(&Record::new(
        Phase::Prepared,
        "a-newer-token",
        0,
        "cpu-raster",
        2,
        VERSION,
    ));
    Err(Refusal::SpawnFailed("no child".to_string()))
}

#[test]
fn test_a_rollback_does_not_erase_an_episode_prepared_after_it() {
    // The state lock is dropped between the prepared write and the spawn, which
    // is deliberate — the spawn must not run under it. So a refusal can come
    // back after another launch has prepared its own episode, and an unchecked
    // rollback would delete a record that launch's child is about to claim,
    // turning a real handoff into an untracked launch.
    let dir = tempfile::tempdir().expect("tempdir");
    let store = Store::new(dir.path());
    store.seed_record(&record(Phase::Confirmed, 0, 2));
    *RACING_STORE.lock().expect("path") = Some(dir.path().to_path_buf());
    let env = env_from(&[]);

    // Wants tier 2, so it prepares a record, spawns, and is refused.
    let boot = reconcile(
        Ok(dir.path().to_path_buf()),
        IDENTIFIER,
        VERSION,
        Vec::new(),
        &env,
        refuse_after_a_competing_prepare,
    );

    assert!(matches!(boot, Boot::Run(_)), "a refusal keeps this process");
    let current = store.read().expect("the competing episode's record");
    assert_eq!(
        current.token, "a-newer-token",
        "the rollback must leave the newer episode alone"
    );
    assert_eq!(current.phase, Phase::Prepared);
}

// ── Receipt currency and forward-only phases ────────────────────────────────

#[test]
fn test_a_receipt_requires_a_current_episode_and_a_forward_phase() {
    let current = record(Phase::Owned, 0, 1);
    let episode = Episode {
        token: TOKEN.to_string(),
        generation: 0,
    };

    assert!(may_advance(Some(&current), &episode, Phase::Confirmed));
    // Backwards and sideways are both rejected: a repeated callback has nothing
    // to add, and an out-of-order one must not undo a later phase.
    assert!(!may_advance(Some(&current), &episode, Phase::Owned));
    assert!(!may_advance(Some(&current), &episode, Phase::Started));
    // Another token's or generation's receipt is never current here.
    assert!(!may_advance(
        Some(&current),
        &Episode {
            token: "another-token".to_string(),
            generation: 0
        },
        Phase::Confirmed
    ));
    assert!(!may_advance(
        Some(&current),
        &Episode {
            token: TOKEN.to_string(),
            generation: 1
        },
        Phase::Confirmed
    ));
    // A cleared record is not something a receipt may recreate: the record a
    // receipt belongs to is written by the parent before the child exists.
    assert!(!may_advance(None, &episode, Phase::Confirmed));
}

#[test]
fn test_the_exhausted_phase_is_terminal_against_a_late_receipt() {
    // `Exhausted` outranks every other phase, so the attempt that exhausted the
    // ladder cannot reopen it with a receipt that arrives afterwards.
    let exhausted = record(Phase::Exhausted, 0, 3);
    let episode = Episode {
        token: TOKEN.to_string(),
        generation: 0,
    };
    for phase in [Phase::Started, Phase::Owned, Phase::Confirmed] {
        assert!(!may_advance(Some(&exhausted), &episode, phase));
    }
}
