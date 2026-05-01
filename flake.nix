{
	description = "blip_mp — BLIP-native multi-precision integers";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		flake-utils.url = "github:numtide/flake-utils";
	};

	outputs = { self, nixpkgs, flake-utils }:
		flake-utils.lib.eachDefaultSystem (system:
			let
				pkgs = nixpkgs.legacyPackages.${system};
				pname = "blip_mp";
				version = "0.0.1";
				isDarwin = pkgs.stdenv.isDarwin;

				nativeBuildInputs = [ pkgs.zig ]
					++ pkgs.lib.optionals isDarwin [
						pkgs.darwin.cctools
						pkgs.apple-sdk
					];

				# GMP is a buildInput for the benchmark comparison only.
				# The core blip_mp library has no external dependencies.
				buildInputs = [ pkgs.gmp ];

				commonBuild = ''
					export HOME="$TMPDIR"
					export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
					mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
				'';
			in {
				devShells.default = pkgs.mkShell {
					buildInputs = with pkgs; [ zig hyperfine gmp jujutsu ];
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
					inherit nativeBuildInputs buildInputs;
					dontConfigure = true;
					dontInstall = true;
					dontFixup = true;
					buildPhase = ''
						${commonBuild}
						zig build bench --prefix "$out" -Doptimize=ReleaseFast \
							-Dgmp-include-path=${pkgs.gmp.dev}/include \
							-Dgmp-lib-path=${pkgs.gmp}/lib
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
							timeout 600 zig build test || { echo "Tests failed"; exit 1; }
						'';
						installPhase = ''
							mkdir -p $out
							echo "tests passed" > $out/result
						'';
					};
				};
			}
		);
}
