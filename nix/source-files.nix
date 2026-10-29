# Compilation inputs shared by the library, CLI and arithmetic probes.
{ lib, root }:
lib.fileset.unions (map (path: root + "/${path}") [
	"build.zig"
	"build.zig.zon"
	"src"
	"tests"
	"include"
	"cli"
])
