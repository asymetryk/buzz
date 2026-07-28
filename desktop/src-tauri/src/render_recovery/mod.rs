//! WebKitGTK renderer recovery ladder (Linux).
//!
//! Some Linux GPU/compositor combinations crash the WebKit web process during
//! startup, leaving Buzz with an invisible window and no way out. WebKit reads
//! each of its renderer environment variables exactly once per process, so a
//! safer configuration can only ever be applied by launching a *fresh* process
//! — the ladder is therefore built out of relaunches, not runtime toggles.
//!
//! On a `Crashed` web-process termination before the startup boundary, the app
//! prepares a durable record, releases the single-instance name, hands off to a
//! child launched with the next tier's exact environment, and exits. The child
//! claims the record, takes the name, and confirms once it has started cleanly.
//! A confirmed tier is reused on later launches — also via a relaunch, since
//! `std::env::set_var` is unsound in a process with live GTK and Tokio threads.
//!
//! Scope: crash-driven recovery, `--safe-rendering`, `--reset-rendering-mode`.
//! A window that never paints but also never crashes is **not** detected — no
//! available signal distinguishes it from a healthy window, so that track is
//! gated on validation against affected hardware.
//!
//! Layout: `profiles` (package scoping + tier table), `state` (durable record +
//! exclusive claims), `episode` (attempt identity and the pure ladder rules),
//! `dbus` (name observation), `classify` (record + observation → decision),
//! `launcher` (the explicit relaunch), `cli` (flags), `session` (the live
//! process), `wiring` (the Tauri plugin that carries it into the app).

pub(crate) mod classify;
pub(crate) mod cli;
pub(crate) mod dbus;
pub(crate) mod episode;
pub(crate) mod launcher;
pub(crate) mod profiles;
pub(crate) mod session;
pub(crate) mod state;
pub(crate) mod wiring;

#[cfg(test)]
mod tests;

pub(crate) use session::{boot, Boot};
pub(crate) use wiring::plugin;

/// Log prefix for every line this feature emits. The ladder's whole diagnostic
/// value is in its log, so the lines are greppable under one tag.
const LOG: &str = "buzz-desktop render-recovery";
