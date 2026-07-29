fn main() { download::start().unwrap(); }

#[cfg(any(docsrs, not(feature = "download")))]
mod download {
    pub(crate) fn start() -> Result<(), ()> { Ok(()) }
}

#[cfg(feature = "download")]
mod download {
    use std::fs::File;
    use std::io::{BufRead, BufReader};
    use std::os::unix::fs::PermissionsExt;
    use std::path::Path;
    use std::process::Command;
    use std::str::FromStr;

    use anyhow::Context;
    use bitcoin_hashes::{sha256, Hash};

    include!("src/versions.rs");

    const GITHUB_URL: &str =
        "https://github.com/lexe-app/corepc/releases/download/electrs_releases";

    /// Returns the pinned release asset filename and SHA-256 for this OS.
    ///
    /// Asset names end with the first 16 hex chars of their SHA-256, so a new
    /// build never reuses an old asset name or local download path.
    fn pinned_asset() -> anyhow::Result<(String, sha256::Hash)> {
        let prefix = format!("{}_", electrs_name());
        let file = File::open("sha256")?;
        let entries: Vec<_> = BufReader::new(file)
            .lines()
            .map_while(Result::ok)
            .filter_map(|line| {
                let (hash, filename) = line.split_once("  ")?;
                filename.starts_with(&prefix).then(|| (hash.to_owned(), filename.to_owned()))
            })
            .collect();
        anyhow::ensure!(
            entries.len() == 1,
            "expected exactly one {}<hash>.zip entry in electrsd/sha256, found {}",
            prefix,
            entries.len()
        );
        let (hex, filename) = entries.into_iter().next().unwrap();
        let hash = sha256::Hash::from_str(&hex)
            .with_context(|| format!("invalid SHA-256 for {} in electrsd/sha256", filename))?;
        let expected_filename = format!("{}{}.zip", prefix, &hex[..16]);
        anyhow::ensure!(
            filename == expected_filename,
            "electrsd/sha256 entry {} should be named {}",
            filename,
            expected_filename
        );
        Ok((filename, hash))
    }

    pub(crate) fn start() -> anyhow::Result<()> {
        println!("cargo:rerun-if-changed=sha256");
        println!("cargo:rerun-if-changed=src/versions.rs");
        println!("cargo:rerun-if-env-changed=ELECTRSD_SKIP_DOWNLOAD");
        println!("cargo:rerun-if-env-changed=ELECTRSD_DOWNLOAD_ENDPOINT");
        if std::env::var_os("ELECTRSD_SKIP_DOWNLOAD").is_some() {
            return Ok(());
        }

        let (download_filename, expected_hash) = pinned_asset()?;
        let download_filename_without_extension = download_filename.trim_end_matches(".zip");
        let out_dir = std::env::var_os("OUT_DIR").unwrap();
        let electrs_exe_home = Path::new(&out_dir).join("electrs");
        let destination_filename =
            electrs_exe_home.join(download_filename_without_extension).join("electrs");

        if !destination_filename.exists() {
            println!("filename:{} version:{} hash:{}", download_filename, VERSION, expected_hash);

            let download_endpoint =
                std::env::var("ELECTRSD_DOWNLOAD_ENDPOINT").unwrap_or(GITHUB_URL.to_string());
            let url = format!("{}/{}", download_endpoint, download_filename);

            let response = bitreq::get(url.clone()).send()?;
            anyhow::ensure!(
                response.status_code == 200,
                "{} returned HTTP {}",
                url,
                response.status_code
            );
            let downloaded_bytes = response.into_bytes();

            let downloaded_hash = sha256::Hash::hash(&downloaded_bytes);
            assert_eq!(expected_hash, downloaded_hash, "expected hash of {} is not matching", url);
            let archive_path = Path::new(&out_dir).join(&download_filename);
            std::fs::write(&archive_path, &downloaded_bytes)?;
            let output = Command::new("unzip")
                .arg("-p")
                .arg(&archive_path)
                .arg("electrs")
                .output()
                .context("failed to run unzip; install unzip and ensure it is in PATH")?;
            anyhow::ensure!(
                output.status.success(),
                "unzip failed to extract {}: {}",
                download_filename,
                String::from_utf8_lossy(&output.stderr)
            );
            let parent = destination_filename.parent().unwrap();
            std::fs::create_dir_all(parent)?;
            std::fs::write(&destination_filename, output.stdout)?;
            std::fs::set_permissions(
                &destination_filename,
                std::fs::Permissions::from_mode(0o755),
            )?;
            std::fs::remove_file(&archive_path)?;
        }

        // `lib.rs` reads this in `downloaded_exe_path`.
        println!("cargo:rustc-env=ELECTRSD_DOWNLOADED_EXE_PATH={}", destination_filename.display());
        Ok(())
    }
}
