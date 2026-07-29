// Only used by `build.rs`, which `include!`s this file.

#[cfg(target_os = "macos")]
const OS: &str = "macos";

#[cfg(target_os = "linux")]
const OS: &str = "linux";

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
const OS: &str = "undefined";

/// The pinned Blockstream electrs commit, built by `electrsd/default.nix`.
const VERSION: &str = "ef15bf97b97814bc8ac771e8537dcf1c1779dade";

pub fn electrs_name() -> String { format!("electrs_{}_{}", OS, VERSION) }
