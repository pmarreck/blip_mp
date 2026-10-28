{
	description = "blip_mp — BLIP-native multi-precision integers";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		flake-utils.url = "github:numtide/flake-utils";
		systems.url = "github:nix-systems/default";
		flake-utils.inputs.systems.follows = "systems";
		performance-profiling.url = "github:pmarreck/performance_profiling/ecf713b81a74a51f76719bf9debc44fe23a0b331";
	};

	outputs = { self, nixpkgs, flake-utils, performance-profiling, ... }:
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
					buildInputs = [ zig pkgs.hyperfine pkgs.gmp
						performance-profiling.packages.${system}.default
						self.packages.${system}.add-probe self.packages.${system}.inverse-probe
						self.packages.${system}.division-probe self.packages.${system}.multiplication-probe
						self.packages.${system}.gold-probe self.packages.${system}.powm-probe ];
					shellHook = ''
						export GMP_INCLUDE_PATH="${pkgs.gmp.dev}/include"
						export GMP_LIB_PATH="${pkgs.gmp}/lib"
					'';
				};

				packages.add-probe = pkgs.stdenv.mkDerivation {
					pname = "${pname}-add-probe";
					inherit version nativeBuildInputs;
					src = self;
					dontConfigure = true;
					dontInstall = true;
					buildPhase = ''
						${commonBuild}
						zig build add-probe --prefix "$out" -Doptimize=ReleaseFast
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
				packages.inverse-probe = self.packages.${system}.add-probe.overrideAttrs {
					pname = "${pname}-inverse-probe";
					buildPhase = ''
						${commonBuild}
						zig build inverse-probe --prefix "$out" -Doptimize=ReleaseFast -Dgmp-lib-path=${pkgs.gmp}/lib
					'';
				};
				packages.division-probe = self.packages.${system}.add-probe.overrideAttrs {
					pname = "${pname}-division-probe";
					buildPhase = ''
						${commonBuild}
						zig build division-probe --prefix "$out" -Doptimize=ReleaseFast -Dgmp-lib-path=${pkgs.gmp}/lib
					'';
				};

				packages.multiplication-probe = self.packages.${system}.add-probe.overrideAttrs {
					pname = "${pname}-multiplication-probe";
					buildPhase = ''
						${commonBuild}
						zig build multiplication-probe --prefix "$out" -Doptimize=ReleaseFast -Dgmp-lib-path=${pkgs.gmp}/lib
					'';
				};

				packages.gold-probe = self.packages.${system}.add-probe.overrideAttrs {
					pname = "${pname}-gold-probe";
					buildPhase = ''
						${commonBuild}
						zig build gold-probe --prefix "$out" -Doptimize=ReleaseFast -Dgmp-lib-path=${pkgs.gmp}/lib
					'';
				};

				packages.powm-probe = self.packages.${system}.add-probe.overrideAttrs {
					pname = "${pname}-powm-probe";
					buildPhase = ''
						${commonBuild}
						zig build powm-probe --prefix "$out" -Doptimize=ReleaseFast -Dgmp-lib-path=${pkgs.gmp}/lib
					'';
				};

				packages.debug = self.packages.${system}.default.overrideAttrs {
					pname = "${pname}-debug";
					buildPhase = ''
						${commonBuild}
						zig build --prefix "$out" -Doptimize=Debug
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
					build-driver = pkgs.runCommand "${pname}-build-driver-tests" {} ''
						mkdir bin
						cat > bin/nix <<-'STUB'
						#!${pkgs.bash}/bin/bash
						printf '%s\n' "$@" > "$ARGV"
						exit "$NIX_STATUS"
						STUB
						chmod +x bin/nix
						export PATH="$PWD/bin:$PATH" ARGV="$PWD/argv"
						printf '%s\n' build .#debug --print-build-logs > expected
						for status in 0 23; do
							if NIX_STATUS="$status" bash ${./build} --debug > stdout 2> stderr; then
								actual=0
							else
								actual=$?
							fi
							test "$actual" -eq "$status"
							cmp expected argv
							test ! -s stdout
							test ! -s stderr
						done
						${self.packages.${system}.debug}/bin/bp 2 3 + > stdout 2> stderr
						printf '5\n' > expected
						cmp expected stdout
						printf '\033[33mDEBUG BUILD!\033[0m\n' > expected
						cmp expected stderr
						${self.packages.${system}.default}/bin/bp 2 3 + > stdout 2> stderr
						printf '5\n' > expected
						cmp expected stdout
						test ! -s stderr
						mkdir -p "$out"
					'';
					probe-cli = pkgs.runCommand "${pname}-probe-cli" {
						nativeBuildInputs = [ pkgs.jq ];
					} ''
						for kind in mixed immediate promoted; do
							${self.packages.${system}.add-probe}/bin/blip-mp-add-probe "$kind" 256 > output.json 2> stderr
							test ! -s stderr
							jq -e --arg kind "$kind" '
								.schema == "performance-measurement/v1" and .correct == true and
								.build_mode == "ReleaseFast" and .fixture == $kind and
								.checksum == ({mixed: 32516, immediate: 16130, promoted: 48644}[$kind]) and
								(.rows | length) == 1 and .rows[0].size == 256 and
								(.rows[0].samples.cpu_ns | length) == 5 and
								(.rows[0].samples.wall_ns | length) == 5 and
								all(.rows[0].samples.cpu_ns[], .rows[0].samples.wall_ns[]; . > 0)
							' output.json > /dev/null
						done
						if ${self.packages.${system}.add-probe}/bin/blip-mp-add-probe mixed 0 > output.json 2> stderr; then
							exit 1
						fi
						test ! -s output.json
						mkdir -p "$out"
					'';
					probe = pkgs.stdenv.mkDerivation {
						pname = "${pname}-probe-tests";
						inherit version nativeBuildInputs;
						src = self;
						dontConfigure = true;
						buildPhase = ''
							${commonBuild}
							zig build probe-test -Doptimize=ReleaseSafe
						'';
						installPhase = "mkdir -p $out";
					};
					inverse-probe-cli = pkgs.runCommand "${pname}-inverse-probe-cli" {
						nativeBuildInputs = [ pkgs.jq ];
					} ''
						mkdir bin
						cat > bin/nix <<-'STUB'
						#!${pkgs.bash}/bin/bash
						printf '%s\n' "$@" > "$ARGV"
						STUB
						chmod +x bin/nix
						export ARGV="$PWD/argv"
						PATH="$PWD/bin:$PATH" bash ${./bm} --verified-inverse --seed 0 > stdout 2> stderr
						printf '%s\n' develop -c performance-profile run --config profiling-inverse.json --mode bm --seed 0 > expected
						cmp expected argv
						test ! -s stdout
						test ! -s stderr
						for algorithm in lehmer hgcd recursive stein; do
							${self.packages.${system}.inverse-probe}/bin/blip-mp-inverse-probe "$algorithm" 64,96 > output.json 2> stderr
							test ! -s stderr
							jq -e --arg algorithm "$algorithm" '
								.schema == "performance-measurement/v1" and .correct == true and
								.build_mode == "ReleaseFast" and .algorithm == $algorithm and
								[.rows[].size] == [64,96] and [.rows[].iterations] == [2000,1500] and
								[.rows[].modulus_bits] == [63,95] and
								all(.rows[]; (.samples.cpu_ns|length) == 5 and (.samples.wall_ns|length) == 5) and
								all(.rows[].samples.cpu_ns[], .rows[].samples.wall_ns[]; . > 0)
							' output.json > /dev/null
						done
						if ${self.packages.${system}.inverse-probe}/bin/blip-mp-inverse-probe recursive 8192 > output.json 2> stderr; then
							exit 1
						fi
						test ! -s output.json
						mkdir -p "$out"
					'';
					inverse-probe = self.checks.${system}.probe.overrideAttrs {
						pname = "${pname}-inverse-probe-tests";
						buildPhase = ''
							${commonBuild}
							zig build inverse-probe-test -Doptimize=ReleaseSafe -Dgmp-lib-path=${pkgs.gmp}/lib
						'';
					};
					division-probe = self.checks.${system}.probe.overrideAttrs {
						pname = "${pname}-division-probe-tests";
						buildPhase = ''
							${commonBuild}
							zig build division-probe-test -Doptimize=ReleaseSafe -Dgmp-lib-path=${pkgs.gmp}/lib
						'';
					};
					multiplication-probe = self.checks.${system}.probe.overrideAttrs {
						pname = "${pname}-multiplication-probe-tests";
						buildPhase = ''
							${commonBuild}
							zig build multiplication-probe-test -Doptimize=ReleaseSafe -Dgmp-lib-path=${pkgs.gmp}/lib
						'';
					};
					gold-probe = self.checks.${system}.probe.overrideAttrs {
						pname = "${pname}-gold-probe-tests";
						buildPhase = ''
							${commonBuild}
							zig build gold-probe-test -Doptimize=ReleaseSafe -Dgmp-lib-path=${pkgs.gmp}/lib
						'';
					};
					gmp-oracle = self.checks.${system}.probe.overrideAttrs {
						pname = "${pname}-gmp-oracle-tests";
						buildPhase = ''
							${commonBuild}
							zig build gmp-oracle-test -Doptimize=ReleaseSafe -Dgmp-lib-path=${pkgs.gmp}/lib
						'';
					};
					division-probe-cli = pkgs.runCommand "${pname}-division-probe-cli" {
						nativeBuildInputs = [ pkgs.jq ];
					} ''
						mkdir bin
						cat > bin/nix <<-'STUB'
						#!${pkgs.bash}/bin/bash
						printf '%s\n' "$@" > "$ARGV"
						STUB
						chmod +x bin/nix
						export ARGV="$PWD/argv"
						PATH="$PWD/bin:$PATH" bash ${./bm} --verified-division --seed 0 > stdout 2> stderr
						printf '%s\n' develop -c performance-profile run --config profiling-division.json --mode bm --seed 0 > expected
						cmp expected argv
						test ! -s stdout
						test ! -s stderr
						for kind in byte_2048 chunk_2048 chunk_4096 chunk_8192 single_byte single_chunk; do
							${self.packages.${system}.division-probe}/bin/blip-mp-division-probe "$kind" 2 > output.json 2> stderr
							test ! -s stderr
							jq -e --arg kind "$kind" '
								.schema == "performance-measurement/v1" and .correct == true and
								.build_mode == "ReleaseFast" and .fixture == $kind and
								(.rows|length) == 1 and .rows[0].size == 2 and
								(.rows[0].samples.cpu_ns|length) == 5 and (.rows[0].samples.wall_ns|length) == 5 and
								all(.rows[0].samples.cpu_ns[], .rows[0].samples.wall_ns[]; . > 0)
							' output.json > /dev/null
						done
						for comparison in paired paired-fallback paired-cutoff; do
						${self.packages.${system}.division-probe}/bin/blip-mp-division-probe "$comparison" 128,129 > paired.json 2> stderr
						test ! -s stderr
						jq -e --arg comparison "$comparison" '
							.schema == "performance-measurement/v1" and .correct == true and
							.method == (if $comparison == "paired" then "division-paired-kernels-v1" elif $comparison == "paired-fallback" then "division-paired-fallbacks-v1" else "division-paired-cutoffs-v1" end) and .build_mode == "ReleaseFast" and
							[.rows[].size] == [128,129] and all(.rows[]; . as $row |
								.fixture_count == 256 and .iterations == 1024 and .warmup_cases == 512 and
								[.components[].method] == (if $comparison == "paired" then ["knuth","burnikel_ziegler"] elif $comparison == "paired-fallback" then ["burnikel_ziegler","burnikel_ziegler_chunk_fallback"] else ["burnikel_ziegler_chunk_fallback","burnikel_ziegler_cutoff128"] end) and
								all(.samples[]; length == 5 and all(.[]; . > 0)) and
								all(.components[]; (.cpu_ns|length) == 5 and (.wall_ns|length) == 5 and all(.cpu_ns[],.wall_ns[]; . > 0)) and
								all(range(5); . as $i |
									$row.samples.cpu_ns[$i] == ([$row.components[].cpu_ns[$i]]|add/2) and
									$row.samples.wall_ns[$i] == ([$row.components[].wall_ns[$i]]|add/2)))
						' paired.json > /dev/null
						done
						if ${self.packages.${system}.division-probe}/bin/blip-mp-division-probe byte_2048 0 > output.json 2> stderr; then
							exit 1
						fi
						test ! -s output.json
						mkdir -p "$out"
					'';

					multiplication-probe-cli = pkgs.runCommand "${pname}-multiplication-probe-cli" {
						nativeBuildInputs = [ pkgs.jq ];
					} ''
						mkdir bin
						cat > bin/nix <<-'STUB'
						#!${pkgs.bash}/bin/bash
						printf '%s\n' "$@" > "$ARGV"
						STUB
						chmod +x bin/nix
						export ARGV="$PWD/argv"
						PATH="$PWD/bin:$PATH" bash ${./bm} --verified-multiplication --seed 0 > stdout 2> stderr
						printf '%s\n' develop -c performance-profile run --config profiling-multiplication.json --mode bm --seed 0 > expected
						cmp expected argv
						test ! -s stdout
						test ! -s stderr
						# Two tiny products can fall within one CPU-clock accounting quantum.
						for kind in schoolbook blocked mp_warm mp_cold blocked_tail paired_tail; do
							${self.packages.${system}.multiplication-probe}/bin/blip-mp-multiplication-probe "$kind" two 64,128 128 > output.json 2> stderr
							test ! -s stderr
							jq -e --arg kind "$kind" '
								.schema == "performance-measurement/v1" and .correct == true and
								.build_mode == "ReleaseFast" and .algorithm == $kind and .shape == "two" and
								[.rows[].size] == [64,128] and [.rows[].longer_bytes] == [128,256] and
								all(.rows[]; .iterations == 128 and (.samples.cpu_ns|length) == 5 and (.samples.wall_ns|length) == 5) and
								all(.rows[].samples.cpu_ns[], .rows[].samples.wall_ns[]; . > 0) and
								(if $kind == "paired_tail" then
									.method == "multiplication-paired-tail-v1" and
									all(.rows[]; . as $row |
										all(.pair[]; length == 5 and all(.[]; . > 0)) and
										all(range(5); . as $i |
											$row.samples.cpu_ns[$i] == (($row.pair.baseline_cpu_ns[$i] + $row.pair.candidate_cpu_ns[$i]) / 2) and
											$row.samples.wall_ns[$i] == (($row.pair.baseline_wall_ns[$i] + $row.pair.candidate_wall_ns[$i]) / 2)))
								else .method == "multiplication-gmp-verified-v1" and all(.rows[]; .pair == null) end)
							' output.json > /dev/null
						done
						if ${self.packages.${system}.multiplication-probe}/bin/blip-mp-multiplication-probe blocked two 0 2 > output.json 2> stderr; then
							exit 1
						fi
						test ! -s output.json
						mkdir -p "$out"
					'';

					powm-probe-cli = pkgs.runCommand "${pname}-powm-probe-cli" {
						nativeBuildInputs = [ pkgs.jq ];
					} ''
						${self.packages.${system}.powm-probe}/bin/blip-mp-powm-probe 512 > output.json 2> stderr
						test ! -s stderr
						jq -e '
							.schema == "performance-measurement/v1" and .correct == true and
							.build_mode == "ReleaseFast" and .method == "powm-gmp-verified-v1" and
							[.rows[].size] == [512] and all(.rows[];
								.iterations == 256 and .fixture_count == 256 and .warmup_cases == 256 and
								all(.samples[]; length == 5 and all(.[]; . > 0)))
						' output.json > /dev/null
						${self.packages.${system}.powm-probe}/bin/blip-mp-powm-probe paired 512 > paired.json 2> stderr
						test ! -s stderr
						jq -e '
							.schema == "performance-measurement/v1" and .correct == true and
							.method == "powm-paired-squaring-v1" and [.rows[].size] == [512] and
							all(.rows[]; . as $row | .iterations == 256 and .warmup_cases == 512 and
								[.components[].method] == ["general","symmetric"] and
								all(.components[]; all(.cpu_ns, .wall_ns; length == 5 and all(.[]; . > 0))) and
								all(range(5); . as $i |
									$row.samples.cpu_ns[$i] == ([$row.components[].cpu_ns[$i]]|add/2) and
									$row.samples.wall_ns[$i] == ([$row.components[].wall_ns[$i]]|add/2)))
						' paired.json > /dev/null
						${self.packages.${system}.powm-probe}/bin/blip-mp-powm-probe paired 64,128 > boundary.json 2> stderr
						test ! -s stderr
						jq -e '.correct == true and .method == "powm-paired-squaring-v1" and [.rows[].size] == [64,128] and all(.rows[]; all(.samples[]; length == 5 and all(.[]; . > 0)))' boundary.json > /dev/null
						if ${self.packages.${system}.powm-probe}/bin/blip-mp-powm-probe 513 > output.json 2> stderr; then exit 1; fi
						test ! -s output.json
						mkdir bin
						cat > bin/nix <<-'STUB'
						#!${pkgs.bash}/bin/bash
						printf '%s\n' "$@" > "$ARGV"
						STUB
						chmod +x bin/nix
						export ARGV="$PWD/argv"
						PATH="$PWD/bin:$PATH" bash ${./bm} --verified-powm --seed 0 > stdout 2> stderr
						printf '%s\n' develop -c performance-profile run --config profiling-powm.json --mode bm --seed 0 > expected
						cmp expected argv
						test ! -s stdout
						test ! -s stderr
						mkdir -p "$out"
					'';

					gold-probe-cli = pkgs.runCommand "${pname}-gold-probe-cli" {
						nativeBuildInputs = [ pkgs.jq ];
					} ''
						trap 'status=$?; if [ "$status" -ne 0 ]; then cat stderr; fi; exit "$status"' EXIT
						mkdir bin
						cat > bin/nix <<-'STUB'
						#!${pkgs.bash}/bin/bash
						printf '%s\n' "$@" > "$ARGV"
						STUB
						chmod +x bin/nix
						export ARGV="$PWD/argv"
						for config in goldilocks truncated hybrid; do
							PATH="$PWD/bin:$PATH" bash ${./bm} "--verified-$config" --seed 0 > stdout 2> stderr
							printf '%s\n' develop -c performance-profile run --config "profiling-$config.json" --mode bm --seed 0 > expected
							cmp expected argv
							test ! -s stdout
							test ! -s stderr
						done
						for mode in product passes truncated hybrid centered centered_fast; do
							${self.packages.${system}.gold-probe}/bin/blip-mp-gold-probe "$mode" 1024,2048 8 > output.json 2> stderr
							test ! -s stderr
							jq -e --arg mode "$mode" '
								.schema == "performance-measurement/v1" and .correct == true and
								.build_mode == "ReleaseFast" and .mode == $mode and
								.method == (if $mode == "centered_fast" then "gold-centered-common-header-v1" elif $mode == "centered" then "gold-centered-products-v1" elif $mode == "hybrid" then "gold-hybrid-products-v1" elif $mode == "truncated" then "gold-truncated-products-v1" else "gold-paired-layouts-v1" end) and
								[.rows[].size] == [1024,2048] and [.rows[].transform_length] == [1024,2048] and
								all(.rows[]; . as $row | .iterations == 8 and
									[.components[].layout] == (if $mode == "centered_fast" then ["fused","centered","centered_fast"] elif $mode == "centered" then ["paired","fused","centered"] elif $mode == "hybrid" then ["fused","truncated","hybrid"] elif $mode == "truncated" then ["stockham","fused","truncated"] else ["stockham","paired","fused"] end) and
									all(.samples[]; length == 6 and all(.[]; . > 0)) and
									all(.components[]; (.cpu_ns|length) == 6 and (.wall_ns|length) == 6 and all(.cpu_ns[], .wall_ns[]; . > 0)) and
									all(range(6); . as $i |
										$row.samples.cpu_ns[$i] == ([$row.components[].cpu_ns[$i]] | add / 3) and
										$row.samples.wall_ns[$i] == ([$row.components[].wall_ns[$i]] | add / 3)))
							' output.json > /dev/null
						done
						if ${self.packages.${system}.gold-probe}/bin/blip-mp-gold-probe passes 65 8 > output.json 2> stderr; then exit 1; fi
						test ! -s output.json
						mkdir -p "$out"
					'';

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
							if timeout 600 zig build test -Doptimize=ReleaseSafe -Dgmp-lib-path=${pkgs.gmp}/lib; then
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
