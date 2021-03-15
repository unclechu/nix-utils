# My own utils for Nix programming language.
# Author: Viacheslav Lotsmanov, 2020–2021

# TODO Customizable derivation name for ‘wrapExecutable’
# TODO Redirection of stdin/stdout/stderr for ‘wrapExecutable’

{ pkgs ? import <nixpkgs> {}
}:
let
  lines = str: builtins.filter builtins.isString (builtins.split "\n" str);
  unlines = builtins.concatStringsSep "\n";
in
assert lines "foo" == ["foo"];
assert unlines ["foo"] == "foo";
assert let x = "foo\nbar\nbaz";   in unlines (lines x) == x;
assert let x = "foo\nbar\nbaz\n"; in unlines (lines x) == x;
rec {
  esc = pkgs.lib.escapeShellArg;
  inherit lines unlines;

  # to get module file path use this hack: (builtins.unsafeGetAttrPos "a" { a = 0; }).file
  nameOfModuleWrapDir = moduleFilePath: baseNameOf (dirOf moduleFilePath);

  # to get module file path use this hack: (builtins.unsafeGetAttrPos "a" { a = 0; }).file
  nameOfModuleFile = moduleFilePath:
    let file = baseNameOf moduleFilePath;
    in  builtins.substring 0 (builtins.stringLength file - (builtins.stringLength ".nix")) file;

  # a helper to create a new script with a "checkPhase" for it
  writeCheckedExecutable = name: checkPhase: text:
    assert valueCheckers.isNonEmptyString name;
    assert builtins.isString checkPhase;
    assert valueCheckers.isNonEmptyString text;
    pkgs.writeTextFile {
      inherit name text;
      executable = true;
      destination = "/bin/${name}";
      checkPhase = "set -Eeuo pipefail\n${checkPhase}";
    };

  # helpers for "checkPhase"
  shellCheckers = {
    fileIsExecutable = file:
      assert builtins.isString file || pkgs.lib.isDerivation file;
      assert valueCheckers.isNonEmptyString "${file}";
      ''
        if ! [ -f ${esc file} -a -r ${esc file} -a -x ${esc file} ]; then
          >&2 printf 'File "%s" is supposed to be ' ${esc file}
          >&2 echo 'readable executable file but this assertion has failed!'
          exit 1
        fi
      '';

    fileIsReadable = file:
      assert builtins.isString file || pkgs.lib.isDerivation file;
      assert valueCheckers.isNonEmptyString "${file}";
      ''
        if ! [ -f ${esc file} -a -r ${esc file} ]; then
          >&2 printf 'File "%s" is supposed to be ' ${esc file}
          >&2 echo 'readable but this assertion has failed!'
          exit 1
        fi
      '';
  };

  # helpers for "assert"-s
  valueCheckers = {
    isPositiveNaturalNumber = x: builtins.isInt x && x >= 1;
    isNonEmptyString = x: builtins.isString x && x != "";
  };

  # set/override some environment variables and/or prepend some arguments
  wrapExecutable = executable:
    { name       ? baseNameOf executable
    , deps       ? [] # derivations to add to PATH
    , env        ? {} # environment variables to set/override
    , args       ? [] # argument to bind before inherited arguments
    , checkPhase ? ""
    }:
    let
      dash = "${pkgs.dash}/bin/dash";

      # extracting the name of an executable inherits StringContext of a derivation
      # which isn't allowed for a name of new executable. but since we're using
      # only the name it's okay to just discard that StringContext.
      nameWithoutContext = builtins.unsafeDiscardStringContext name;

      # print list items with a separator after each element
      preList = sep: builtins.foldl' (acc: x: "${acc}${x}${sep}") "";

      isValidEnvVarName = x: ! isNull (builtins.match "([a-zA-Z]|[a-zA-Z_][a-zA-Z_0-9]+)" x);
      PATH = "PATH";

      newPath =
        let
          depsToAdd = if deps == [] then "" else preList ":" (map (x: "${esc x}/bin") deps);

          valueToExtend =
            if builtins.hasAttr PATH env then esc (builtins.getAttr PATH env)
            else if deps != [] then "\"\$${PATH}\""
            else null;
        in
          if isNull valueToExtend then null else "${depsToAdd}${valueToExtend}";

      envVarsList =
        pkgs.lib.mapAttrsToList (k: v: "${k}=${esc v}") (builtins.removeAttrs env [PATH]) ++
        (if isNull newPath then [] else ["${PATH}=${newPath}"]);
    in
      assert valueCheckers.isNonEmptyString executable;
      assert builtins.isList deps;
      assert builtins.all pkgs.lib.isDerivation deps;
      assert builtins.isAttrs env;
      assert builtins.isList args;
      assert valueCheckers.isNonEmptyString nameWithoutContext;
      assert builtins.all isValidEnvVarName (builtins.attrNames env);
      assert builtins.isString checkPhase;
    let
      newExecutable = writeCheckedExecutable nameWithoutContext ''
        ${shellCheckers.fileIsExecutable dash}
        ${shellCheckers.fileIsExecutable executable}
        ${checkPhase}
      '' ''
        #! ${dash}
        ${preList " " envVarsList}exec ${esc executable} ${preList " " (map esc args)}"$@"
      '';
    in
      assert pkgs.lib.isDerivation newExecutable;
      newExecutable;

  # Wraps an executable providing some Perl 5 dependencies for that executable.
  # Overrides “PERL5LIB” environment variable (it’s uncomposable at the moment).
  # Usage example:
  #
  #   let
  #     pkgs = import <nixpkgs> {};
  #     utils = import /path/to/nix-utils { inherit pkgs; };
  #     name = "some-perl-script";
  #     perl = "${pkgs.perl}/bin/perl";
  #     checkPhase = utils.shellCheckers.fileIsExecutable perl;
  #     deps = perlPackages: [ perlPackages.IPCSystemSimple ];
  #
  #     perlScript = writeCheckedExecutable name checkPhase ''
  #       #! ${perl}
  #       # Some perl script…
  #     '';
  #   in
  #     wrapExecutableWithPerlDeps "${perlScript}/bin/${name}" { inherit deps; }
  #
  wrapExecutableWithPerlDeps = executable: { deps, checkPhase ? "" }:
    assert valueCheckers.isNonEmptyString executable;
    assert builtins.isString checkPhase;
    assert builtins.isFunction deps;
    let depsList = deps pkgs.perlPackages; in
    assert builtins.isList depsList;
    assert builtins.all pkgs.lib.isDerivation depsList;
    wrapExecutable executable {
      env = { PERL5LIB = pkgs.perlPackages.makePerlPath depsList; };
      inherit checkPhase;
    };
}
