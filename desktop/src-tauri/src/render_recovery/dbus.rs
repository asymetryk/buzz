//! Facts about the single-instance well-known name, read from the session bus.
//!
//! This module only *observes*; correlating an observation against a recorded
//! child is `classify`'s job. The distinction matters because "somebody owns
//! the name" is never evidence that our recovery child survived, and "the bus
//! did not answer" is never evidence that the name is free.

/// The single-instance name `tauri-plugin-single-instance` registers: the app
/// identifier plus `.SingleInstance` (the `semver` feature, which would append
/// a version suffix, is not enabled in this build).
pub(crate) fn single_instance_name(identifier: &str) -> String {
    format!("{identifier}.SingleInstance")
}

/// Who currently holds the well-known name.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Owner {
    pub unique_name: String,
    /// `None` when the bus refused `GetConnectionUnixProcessID` — the owner
    /// exists but cannot be identified.
    pub pid: Option<u32>,
}

/// What the bus said about the name.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Observation {
    /// `GetNameOwner` reported no owner. The only state in which a handoff may
    /// proceed.
    Free,
    Owned(Owner),
    /// The bus could not be reached or the call failed. Deliberately distinct
    /// from `Free`.
    Unavailable(String),
}

/// Identity of the session bus itself. A unique name like `:1.4` is only
/// meaningful against the bus that issued it, so `owned` receipts are bound to
/// this value as well as to the unique name.
pub(crate) fn bus_id() -> Option<String> {
    call::<String>("GetId", &())
}

/// Observe the current owner of `name`.
pub(crate) fn observe(name: &str) -> Observation {
    let connection = match zbus::blocking::Connection::session() {
        Ok(connection) => connection,
        Err(error) => return Observation::Unavailable(format!("session bus: {error}")),
    };
    match connection.call_method(
        Some("org.freedesktop.DBus"),
        "/org/freedesktop/DBus",
        Some("org.freedesktop.DBus"),
        "GetNameOwner",
        &name,
    ) {
        Ok(reply) => match reply.body().deserialize::<String>() {
            Ok(unique_name) => {
                let pid = call::<u32>("GetConnectionUnixProcessID", &unique_name);
                Observation::Owned(Owner { unique_name, pid })
            }
            Err(error) => Observation::Unavailable(format!("GetNameOwner reply: {error}")),
        },
        // The bus answers NameHasNoOwner as an error reply; that is the one
        // failure that genuinely means "free".
        Err(zbus::Error::MethodError(name, _, _))
            if name.as_str() == "org.freedesktop.DBus.Error.NameHasNoOwner" =>
        {
            Observation::Free
        }
        Err(error) => Observation::Unavailable(format!("GetNameOwner: {error}")),
    }
}

fn call<T>(method: &str, body: &(impl serde::Serialize + zbus::zvariant::DynamicType)) -> Option<T>
where
    T: for<'d> zbus::zvariant::Type + serde::de::DeserializeOwned,
{
    let connection = zbus::blocking::Connection::session().ok()?;
    let reply = connection
        .call_method(
            Some("org.freedesktop.DBus"),
            "/org/freedesktop/DBus",
            Some("org.freedesktop.DBus"),
            method,
            body,
        )
        .ok()?;
    reply.body().deserialize::<T>().ok()
}
