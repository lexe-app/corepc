{
  # Matches the `nixpkgs` (nixos-26.05) pin in Lexe's `flake.lock`.
  nixpkgs ? builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/6f06d204d8f2d8761d9da78778745974a3216381.tar.gz";
    sha256 = "sha256-loLMnbbS4KhmG2ln9EY6f0YMNCA273Yx02oWYQ9IMeE=";
  },
  system ? builtins.currentSystem,
}:

assert builtins.elem system [
  "aarch64-darwin"
  "x86_64-linux"
];

let
  pkgs = import nixpkgs { inherit system; };

  # Rust's musl target links libc statically. Use nixpkgs' fully static package
  # set as well so native dependencies such as RocksDB are statically linked.
  targetPkgs = if system == "x86_64-linux" then pkgs.pkgsStatic else pkgs;

  rev = "ef15bf97b97814bc8ac771e8537dcf1c1779dade";

  assetOs =
    {
      aarch64-darwin = "macos";
      x86_64-linux = "linux";
    }
    .${system};

  isDarwin = targetPkgs.stdenv.hostPlatform.isDarwin;

  # Unwrapped cctools, for `otool` and `install_name_tool` on macOS.
  cctools = targetPkgs.stdenv.cc.bintools.bintools;

  blockstream-electrs = targetPkgs.rustPlatform.buildRustPackage {
    pname = "blockstream-electrs";
    version = "0.4.1-unstable-2026-07-20";

    src = targetPkgs.fetchFromGitHub {
      owner = "Blockstream";
      repo = "electrs";
      inherit rev;
      hash = "sha256-sObkyuS/BcoKMDvrpUnIhl2NlB/gJKESfUbgVLe6PGU=";
    };

    cargoHash = "sha256-P8slOt07Fu6NNzYLEso3UQtfx7Yj+C4w98lq/Wr8oTk=";

    nativeBuildInputs = [
      targetPkgs.rustPlatform.bindgenHook
    ]
    # Re-signs the binary after `preFixup` edits it.
    ++ targetPkgs.lib.optionals isDarwin [ targetPkgs.darwin.autoSignDarwinBinariesHook ];

    # Rust defaults to static PIE for musl, but nixpkgs' static libstdc++ is not
    # built as position-independent code. A non-PIE executable remains fully
    # static and links cleanly against the bundled RocksDB C++ code.
    env = targetPkgs.lib.optionalAttrs (system == "x86_64-linux") {
      RUSTFLAGS = "-C relocation-model=static";
    };

    # Use the platform allocator and build the bundled RocksDB. The latter
    # avoids the crashes we have observed with dynamically linked RocksDB.
    postPatch = ''
      substituteInPlace Cargo.toml \
        --replace-fail 'tikv-jemallocator = "0.6"' ""
      substituteInPlace src/bin/electrs.rs \
        --replace-fail $'#[global_allocator]\nstatic GLOBAL: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;\n\n' ""
    '';

    cargoBuildFlags = [
      "--package=electrs"
      "--bin=electrs"
    ];

    # The release package only needs the service binary; upstream integration
    # tests require additional dynamically linked daemons.
    doCheck = false;

    # nixpkgs' Rust links libiconv from the Nix store on macOS, so the binary
    # would only run on Macs with that store path. Point it at the system's
    # libiconv instead, which is the same Apple libiconv.
    preFixup = targetPkgs.lib.optionalString isDarwin ''
      ${cctools}/bin/otool -L $out/bin/electrs \
        | awk '$1 ~ "^/nix/store/.*/libiconv[.]2[.]dylib$" { print $1 }' \
        | while read -r lib; do
          ${cctools}/bin/install_name_tool \
            -change "$lib" /usr/lib/libiconv.2.dylib $out/bin/electrs
        done
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      $out/bin/electrs --version
    ''
    + targetPkgs.lib.optionalString isDarwin ''
      if ${cctools}/bin/otool -L $out/bin/electrs | tail -n +2 | grep /nix/store; then
        echo "electrs links libraries from the Nix store" >&2
        exit 1
      fi
    '';

    meta = {
      description = "Blockstream's Electrum server and Esplora backend";
      homepage = "https://github.com/Blockstream/electrs";
      license = targetPkgs.lib.licenses.mit;
      mainProgram = "electrs";
      platforms = [
        "aarch64-darwin"
        "x86_64-linux"
      ];
    };
  };

  # The release asset that `build.rs` downloads, plus its `sha256` entry.
  #
  # Everything zip records besides the binary is pinned, so the zip (and its
  # hash) only depends on the binary, not on the machine or zip tool used:
  # - mtime: 1980-01-01 00:00 UTC, the earliest timestamp zip can store.
  # - mode: 0755.
  # - `-X`: no uid/gid or extended timestamp fields.
  #
  # The asset name ends with a prefix of the zip's SHA-256, so a new build
  # never reuses an existing release asset name.
  blockstream-electrs-zip =
    pkgs.runCommand "blockstream-electrs-zip-${blockstream-electrs.version}"
      { nativeBuildInputs = [ pkgs.zip ]; }
      ''
        # `build.rs` names the release asset with `VERSION` from `src/versions.rs`.
        grep -xF 'const VERSION: &str = "${rev}";' ${./src/versions.rs}

        cp ${blockstream-electrs}/bin/electrs electrs
        chmod 0755 electrs
        touch --date=@315532800 electrs
        TZ=UTC zip -X electrs.zip electrs

        hash="$(sha256sum electrs.zip | cut -d ' ' -f 1)"
        name="electrs_${assetOs}_${rev}_''${hash:0:16}.zip"
        mkdir "$out"
        mv electrs.zip "$out/$name"
        echo "$hash  $name" > "$out/sha256"
      '';
in
{
  inherit blockstream-electrs blockstream-electrs-zip;
}
