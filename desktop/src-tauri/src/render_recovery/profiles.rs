//! Package scoping, profile-owned environment variables, and the tier table.
//!
//! Every value here is derived from the WebKitGTK source analysis recorded in
//! `RESEARCH/WEBKIT_RECOVERY_SPIKE.md` (Q2/Q4). Two rules drive the shape:
//!
//! * WebKit memoizes each of these variables once per process
//!   (`AcceleratedBackingStore.cpp` `std::call_once`), so a profile can only be
//!   applied by launching a fresh process with an exact environment.
//! * Ownership is **package-scoped**. `GDK_BACKEND=x11` is a package invariant
//!   on AppImage — linuxdeploy's GTK AppRun hook exports it unconditionally
//!   before the binary starts, so its presence there is never a user signal and
//!   a tier that sets it is a no-op.

/// Reads one environment variable. Injected so ownership and package detection
/// are testable without mutating the process environment.
pub(crate) type Env<'a> = &'a dyn Fn(&str) -> Option<String>;

/// How this process was packaged, which decides both the owned variable set
/// and the number of ladder tiers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Package {
    AppImage,
    Native,
}

/// The four WebKit renderer variables. Owned by both packages.
const WEBKIT_VARS: [&str; 4] = [
    "WEBKIT_DMABUF_RENDERER_FORCE_SHM",
    "WEBKIT_DISABLE_DMABUF_RENDERER",
    "WEBKIT_SKIA_ENABLE_CPU_RENDERING",
    // No tier sets this one — it is owned so that a user value still opts out.
    // It stays out of the ladder pending the 3-var vs 4-var isolation on #2643.
    "WEBKIT_DISABLE_COMPOSITING_MODE",
];

/// Owned on native Linux only. See the module docs.
const GDK_BACKEND: &str = "GDK_BACKEND";

const OWNED_NATIVE: [&str; 5] = [
    WEBKIT_VARS[0],
    WEBKIT_VARS[1],
    WEBKIT_VARS[2],
    WEBKIT_VARS[3],
    GDK_BACKEND,
];

/// One rung of the ladder: a name plus the exact variable set it applies.
/// The set is exhaustive — an attempt's environment is every owned variable
/// removed, then exactly these pairs added.
pub(crate) struct Tier {
    pub name: &'static str,
    pub vars: &'static [(&'static str, &'static str)],
}

const TIERS: [Tier; 5] = [
    Tier {
        name: "full-gpu",
        vars: &[],
    },
    Tier {
        // Drops zero-copy dmabuf but keeps accelerated compositing and
        // threaded scrolling: FORCE_SHM is read *after* SharedMemory is added.
        name: "shm-transport",
        vars: &[("WEBKIT_DMABUF_RENDERER_FORCE_SHM", "1")],
    },
    Tier {
        // Adds WebProcess CPU rasterization on top of the SHM transport.
        name: "cpu-raster",
        vars: &[
            ("WEBKIT_DMABUF_RENDERER_FORCE_SHM", "1"),
            ("WEBKIT_SKIA_ENABLE_CPU_RENDERING", "1"),
        ],
    },
    Tier {
        // DISABLE_DMABUF returns before SharedMemory is added, so this also
        // loses accelerated compositing and threaded scrolling.
        name: "no-accel",
        vars: &[
            ("WEBKIT_DISABLE_DMABUF_RENDERER", "1"),
            ("WEBKIT_SKIA_ENABLE_CPU_RENDERING", "1"),
        ],
    },
    Tier {
        // Native Linux only — on AppImage the backend is already pinned, so
        // this rung would spend a relaunch on a no-op.
        name: "x11-fallback",
        vars: &[
            ("WEBKIT_DISABLE_DMABUF_RENDERER", "1"),
            ("WEBKIT_SKIA_ENABLE_CPU_RENDERING", "1"),
            (GDK_BACKEND, "x11"),
        ],
    },
];

impl Package {
    /// Detected the same way `tauri::Env` does, so the launcher and the
    /// ownership check agree with `tauri::process::current_binary`.
    pub(crate) fn detect(env: Env<'_>) -> Self {
        match env("APPIMAGE") {
            Some(_) => Package::AppImage,
            None => Package::Native,
        }
    }

    /// The variables this package's profiles own, exhaustively. A user
    /// assignment of any of them disables recovery wholesale.
    pub(crate) fn owned_vars(self) -> &'static [&'static str] {
        match self {
            Package::AppImage => &WEBKIT_VARS,
            Package::Native => &OWNED_NATIVE,
        }
    }

    /// The ladder for this package: 4 rungs on AppImage, 5 on native Linux.
    pub(crate) fn tiers(self) -> &'static [Tier] {
        match self {
            Package::AppImage => &TIERS[..4],
            Package::Native => &TIERS,
        }
    }

    /// Index of the last rung. Reaching it and crashing again exhausts the
    /// ladder, which is also case 10's per-package attempt cap: one crash
    /// advances exactly one rung, so the rung count *is* the cap.
    pub(crate) fn terminal_tier(self) -> usize {
        self.tiers().len() - 1
    }

    pub(crate) fn tier(self, index: usize) -> Option<&'static Tier> {
        self.tiers().get(index)
    }

    pub(crate) fn tier_named(self, name: &str) -> Option<usize> {
        self.tiers().iter().position(|tier| tier.name == name)
    }

    pub(crate) fn label(self) -> &'static str {
        match self {
            Package::AppImage => "appimage",
            Package::Native => "native",
        }
    }
}

/// Owned variables the caller's environment actually carries, as `KEY=VALUE`.
///
/// Presence is the test, not truthiness: `VAR=0` and `VAR=` are both genuine
/// user assignments and both disable recovery.
pub(crate) fn owned_present(package: Package, env: Env<'_>) -> Vec<String> {
    package
        .owned_vars()
        .iter()
        .filter_map(|key| env(key).map(|value| format!("{key}={value}")))
        .collect()
}
