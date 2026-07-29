[![MIT license](https://img.shields.io/github/license/lexe-app/corepc)](https://github.com/lexe-app/corepc/blob/master/electrsd/LICENSE)

# Electrsd

Utility to run a regtest [Blockstream electrs](https://github.com/Blockstream/electrs)
process connected to a [bitcoind](https://crates.io/crates/bitcoind) instance,
useful in integration tests.

```rust
let bitcoind = electrsd::bitcoind::BitcoinD::new("/usr/local/bin/bitcoind").unwrap();
let electrsd = electrsd::ElectrsD::new("/usr/local/bin/electrs", &bitcoind).unwrap();
let header = electrsd.client.block_headers_subscribe().unwrap();
assert_eq!(header.height, 1);
```

## Automatic binary downloads

Enable the single `download` feature to use the pinned electrs and Bitcoin Core
versions supported by this crate. Automatic downloads require `unzip` in `PATH`
to extract the downloaded electrs binary.

```toml
electrsd = { git = "https://github.com/lexe-app/corepc", branch = "<lexe fork branch>", features = ["download"] }
```

Then use it:

```rust
let bitcoind_exe = electrsd::bitcoind::downloaded_exe_path().unwrap();
let bitcoind = electrsd::bitcoind::BitcoinD::new(bitcoind_exe).unwrap();
let electrs_exe = electrsd::downloaded_exe_path().unwrap();
let electrsd = electrsd::ElectrsD::new(electrs_exe, &bitcoind).unwrap();
```

When the `ELECTRSD_DOWNLOAD_ENDPOINT` or `BITCOIND_DOWNLOAD_ENDPOINT`
environment variable is set, the corresponding crate downloads from that
endpoint instead.

When you don't use the auto-download feature you have the following options:

- have `electrs` executable in the `PATH`
- provide the `electrs` executable via the `ELECTRS_EXEC` env var

```rust
if let Ok(exe_path) = electrsd::exe_path() {
  let electrsd = electrsd::ElectrsD::new(exe_path, &bitcoind).unwrap();
}
```

Startup options can be configured via `Conf` and `ElectrsD::with_conf`.

## Nix

`default.nix` pins Nixpkgs and Blockstream electrs and exposes the
`blockstream-electrs` package:

```bash
nix-build electrsd/default.nix -A blockstream-electrs
./result/bin/electrs --version
```

It also exposes `blockstream-electrs-zip`, the release asset that the `download`
feature fetches, along with its `sha256` entry. The zip only depends on the
binary, so it's identical wherever the binary builds identically:

```bash
nix-build electrsd/default.nix -A blockstream-electrs-zip
cat ./result/sha256
```

The package supports `x86_64-linux` and `aarch64-darwin`. Linux uses the
fully-static musl package set. The package also uses the platform allocator and
bundled RocksDB, matching the production overrides used by Lexe.

Nix builds cannot access the network from `build.rs`. Downstream Nix builds can
set `ELECTRSD_SKIP_DOWNLOAD` and provide `electrs` through `ELECTRS_EXEC` or
`PATH`.

## Features

- Uses an isolated temporary index directory by default.
- Asks the OS for free Electrum, Esplora, and monitoring ports.
- Terminates the child process on drop, including when a test fails.
- Tunes electrs for small regtest chains: light mode, one RPC and RocksDB
  worker, one-block sync batches, and 1 MiB RocksDB cache/write buffers.
- The `download` feature provides [Blockstream electrs at `ef15bf97`](https://github.com/Blockstream/electrs/tree/ef15bf97b97814bc8ac771e8537dcf1c1779dade)
  and Bitcoin Core 32.1 through the `bitcoind` crate's `32_1` feature.
- Electrs binaries are built from the pinned [Nix package](default.nix) by the
  [manual workflow](../.github/workflows/build_blockstream_electrs.yml), which
  uploads them to the `electrs_releases` GitHub release. Asset names end with a
  prefix of the zip's SHA-256, so rebuilds never replace older binaries, and
  `sha256` takes the `blockstream-electrs-zip` lines as-is.

Each test can therefore run in its own isolated environment.

## Deprecations

- Starting from version `0.26` the env var `ELECTRS_EXE` is deprecated in favor of `ELECTRS_EXEC`.
