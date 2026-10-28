# Continuous integration

Mechatron Prime CI builds the exact pushed commit using
[.mechatron-prime/targets](.mechatron-prime/targets). The current targets build
the native Linux x86_64 library, CLI and benchmark executables, and execute
ReleaseSafe Zig and C API tests, GMP comparisons and CLI tests in Nix sandboxes.

Run `./test` locally for the complete correctness suite, including GMP
comparisons, C API checks and CLI tests. It builds all required checks without
changing checkout output links; cached checks reuse earlier verdicts.
Run `./build` for the optimized
production build. The current CI manifest does not establish execution or
performance coverage on other platforms.
