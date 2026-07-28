//! The two renderer flags.
//!
//! Parsed from raw argv before Tauri starts, because the tier they select has
//! to be in the process environment before WebKit initializes.

/// Force the safest profile for this launch only. The ladder does not advance
/// and the persisted record is untouched.
pub(crate) const SAFE_RENDERING: &str = "--safe-rendering";
/// Delete the persisted profile and episode state, report it, and exit.
pub(crate) const RESET_RENDERING_MODE: &str = "--reset-rendering-mode";

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct Flags {
    pub safe_rendering: bool,
    pub reset_rendering_mode: bool,
}

pub(crate) fn parse<'a>(args: impl IntoIterator<Item = &'a std::ffi::OsStr>) -> Flags {
    let mut flags = Flags::default();
    for arg in args {
        match arg.to_str() {
            Some(SAFE_RENDERING) => flags.safe_rendering = true,
            Some(RESET_RENDERING_MODE) => flags.reset_rendering_mode = true,
            _ => {}
        }
    }
    flags
}
