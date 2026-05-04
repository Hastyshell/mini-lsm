{
  description = "Mini-LSM Rust workspace";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;

        src = lib.cleanSourceWith {
          src = ./.;
          filter = path: type:
            let base = baseNameOf path;
            in !(type == "directory" && lib.elem base [ "target" ".direnv" ]);
        };

        mini-lsm = pkgs.rustPlatform.buildRustPackage {
          pname = "mini-lsm-workspace";
          version = "0.2.0";
          inherit src;

          cargoLock.lockFile = ./Cargo.lock;
          cargoBuildFlags = [ "--workspace" "--bins" ];
          cargoTestFlags = [ "--workspace" ];

          nativeBuildInputs = [ pkgs.pkg-config ];

          meta = {
            description = "Mini-LSM tutorial Rust workspace";
            homepage = "https://github.com/skyzh/mini-lsm";
            license = lib.licenses.asl20;
          };
        };
      in
      {
        packages.default = mini-lsm;
        packages.mini-lsm = mini-lsm;

        checks.default = mini-lsm;

        apps = {
          mini-lsm-cli = flake-utils.lib.mkApp {
            drv = mini-lsm;
            exePath = "/bin/mini-lsm-cli";
          };
          compaction-simulator = flake-utils.lib.mkApp {
            drv = mini-lsm;
            exePath = "/bin/compaction-simulator";
          };
          mini-lsm-cli-ref = flake-utils.lib.mkApp {
            drv = mini-lsm;
            exePath = "/bin/mini-lsm-cli-ref";
          };
          compaction-simulator-ref = flake-utils.lib.mkApp {
            drv = mini-lsm;
            exePath = "/bin/compaction-simulator-ref";
          };
          mini-lsm-cli-mvcc-ref = flake-utils.lib.mkApp {
            drv = mini-lsm;
            exePath = "/bin/mini-lsm-cli-mvcc-ref";
          };
          compaction-simulator-mvcc-ref = flake-utils.lib.mkApp {
            drv = mini-lsm;
            exePath = "/bin/compaction-simulator-mvcc-ref";
          };
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            rustc
            cargo
            rustfmt
            clippy
            rust-analyzer
            cargo-nextest
            cargo-semver-checks
            mdbook
            mdbook-toc
            pkg-config
          ];

          RUST_BACKTRACE = "1";
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
