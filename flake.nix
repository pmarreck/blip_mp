{
	description = "blip_mp — BLIP-native multi-precision integers";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		flake-utils.url = "github:numtide/flake-utils";
		systems.url = "github:nix-systems/default";
		flake-utils.inputs.systems.follows = "systems";
	};

	outputs = { self, nixpkgs, flake-utils, ... }:
		flake-utils.lib.eachDefaultSystem (system:
			let
				pkgs = nixpkgs.legacyPackages.${system};
				pname = "blip_mp";
				version = "0.0.1";
				isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
				zig = pkgs.zig_0_16;

				nativeBuildInputs = [ zig ]
					++ pkgs.lib.optionals isDarwin [
						pkgs.darwin.cctools
						pkgs.apple-sdk
					];

				# GMP is a buildInput for the benchmark comparison only.
				# The core blip_mp library has no external dependencies.
				buildInputs = [ pkgs.gmp ];

				# A second GMP build with hand-tuned assembly DISABLED, so the
				# inner mpn_* loops use only the C reference code. This isolates
				# the BLIP-vs-limb-storage question from Zig-vs-aarch64-asm.
				# blip_mp vs gmp-noasm = controlled storage-paradigm comparison.
				# On x86_64, GMP's default 'fat build' (runtime CPU dispatch
				# across Intel/AMD micro-architectures) is incompatible with
				# --disable-assembly — configure errors with "when doing a fat
				# build, disabling assembly will not work". Filter out
				# --enable-fat from the inherited configureFlags before adding
				# --disable-assembly. Harmless on aarch64 (no fat build there).
				gmp-noasm = pkgs.gmp.overrideAttrs (old: {
					configureFlags = (builtins.filter
						(f: f != "--enable-fat")
						(old.configureFlags or []))
						++ [ "--disable-assembly" ];
				});

				commonBuild = ''
					export HOME="$TMPDIR"
					export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
					mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
				'';
			in {
				devShells.default = pkgs.mkShell {
					buildInputs = [ zig pkgs.hyperfine pkgs.gmp ];
					shellHook = ''
						export GMP_INCLUDE_PATH="${pkgs.gmp.dev}/include"
						export GMP_LIB_PATH="${pkgs.gmp}/lib"
					'';
				};

				packages.default = pkgs.stdenv.mkDerivation {
					inherit pname version;
					src = self;
					inherit nativeBuildInputs buildInputs;
					dontConfigure = true;
					dontInstall = true;
					dontFixup = true;
					buildPhase = ''
						${commonBuild}
						zig build --prefix "$out" -Doptimize=ReleaseFast \
							-Dgmp-include-path=${pkgs.gmp.dev}/include \
							-Dgmp-lib-path=${pkgs.gmp}/lib
					'';
				};

				packages.bench = pkgs.stdenv.mkDerivation {
					pname = "${pname}-bench";
					inherit version;
					src = self;
					nativeBuildInputs = nativeBuildInputs;
					buildInputs = buildInputs ++ [ gmp-noasm ];
					dontConfigure = true;
					dontInstall = true;
					dontFixup = true;
					buildPhase = ''
						${commonBuild}
						zig build bench --prefix "$out" -Doptimize=ReleaseFast \
							-Dgmp-include-path=${pkgs.gmp.dev}/include \
							-Dgmp-lib-path=${pkgs.gmp}/lib \
							-Dgmp-noasm-include-path=${gmp-noasm.dev}/include \
							-Dgmp-noasm-lib-path=${gmp-noasm}/lib
					'';
				};

				checks = {
					build = self.packages.${system}.default;

					test = pkgs.stdenv.mkDerivation {
						pname = "${pname}-tests";
						inherit version;
						src = self;
						inherit nativeBuildInputs buildInputs;
						dontConfigure = true;
						dontFixup = true;
						buildPhase = ''
							${commonBuild}
							# Keep overlap and bounds checks in the complete correctness suite.
							failures=0
							if timeout 600 zig build test -Doptimize=ReleaseSafe; then
								echo "Unit tests passed"
							else
								failures=$((failures + 1))
							fi
							if zig build c-smoke-run -Doptimize=ReleaseSafe; then
								echo "C API tests passed"
							else
								failures=$((failures + 1))
							fi
							test "$failures" -eq 0
						'';
						installPhase = ''
							mkdir -p $out
							echo "tests passed" > $out/result
						'';
					};

					integration = pkgs.runCommand "${pname}-integration-tests" {
						nativeBuildInputs = [ pkgs.bash ];
					} ''
						failures=0
						if ${self.packages.${system}.bench}/bin/cross_check; then
							echo "GMP comparisons passed"
						else
							failures=$((failures + 1))
						fi
						if BP_BIN=${self.packages.${system}.default}/bin/bp bash ${./tests/cli/bp_smoke.sh}; then
							echo "CLI tests passed"
						else
							failures=$((failures + 1))
						fi
						test "$failures" -eq 0
						mkdir -p "$out"
						echo "GMP and CLI tests passed" > "$out/result"
					'';
				};
			}
		);
}
