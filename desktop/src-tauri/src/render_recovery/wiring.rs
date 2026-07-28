//! The Tauri plugin that carries a `Session` into the running app.
//!
//! Three attachments, and nothing else lives here:
//!
//! * plugin setup — the single-instance plugin is registered before this one,
//!   so by now the name is held and the `owned` receipt can name this
//!   connection;
//! * a boundary thread — writes the crash-free startup receipt once the startup
//!   window closes;
//! * the `main` webview's `web-process-terminated` signal — the crash edge.
//!
//! Tauri's own `on_web_content_process_terminate` hook is macOS/iOS only
//! (`tauri-2.11.5/src/webview/mod.rs`), so the crash edge is taken straight
//! from `webkit2gtk`, which is already in the dependency graph via wry.

use std::sync::Arc;

use tauri::plugin::TauriPlugin;
use tauri::{Manager, Runtime};
use webkit2gtk::{WebProcessTerminationReason, WebViewExt};

use super::episode::Termination;
use super::session::{CrashResponse, Session};
use super::LOG;

/// Everything the ladder needs from the live app.
pub(crate) fn plugin<R: Runtime>(session: Arc<Session>) -> TauriPlugin<R> {
    let for_webview = Arc::clone(&session);
    tauri::plugin::Builder::<R, ()>::new("render-recovery")
        .setup(move |_app, _api| {
            session.note_owned();
            confirm_at_startup_boundary(Arc::clone(&session));
            Ok(())
        })
        .on_webview_ready(move |webview| {
            if webview.label() != "main" {
                return;
            }
            let session = Arc::clone(&for_webview);
            let app = webview.app_handle().clone();
            if let Err(error) = webview.with_webview(move |platform| {
                platform
                    .inner()
                    .connect_web_process_terminated(move |_, reason| {
                        let response = session.on_web_process_terminated(classify(reason), &|| {
                            tauri_plugin_single_instance::destroy(&app)
                        });
                        // Exit through Tauri in both terminal cases so the
                        // ordinary shutdown path still runs. `HandedOff`: a
                        // child owns the app now, and two Buzz processes must
                        // never be live at once. `Stranded`: the single-instance
                        // name was released and cannot be taken back, so this
                        // process is no longer able to be the app.
                        match response {
                            CrashResponse::HandedOff | CrashResponse::Stranded => app.exit(0),
                            CrashResponse::Continue => {}
                        }
                    });
            }) {
                eprintln!("{LOG}: could not attach the crash hook: {error}");
            }
        })
        .build()
}

/// Write the crash-free startup receipt once the startup window closes.
///
/// A plain thread rather than an async task: it sleeps for the whole window and
/// then does blocking file and D-Bus work, which is the opposite of what an
/// async worker is for.
fn confirm_at_startup_boundary(session: Arc<Session>) {
    std::thread::spawn(move || {
        std::thread::sleep(session.until_confirmation());
        session.note_confirmed();
    });
}

/// Reduce WebKit's termination reason to the only distinction the ladder makes.
///
/// The enum is `#[non_exhaustive]`, and the fallback arm is deliberately the
/// one that never downgrades anything: an unknown future reason must not cost a
/// user their hardware rendering.
fn classify(reason: WebProcessTerminationReason) -> Termination {
    match reason {
        WebProcessTerminationReason::Crashed => Termination::Crashed,
        _ => Termination::Other,
    }
}
