# My own utils for Nix programming language.
# Author: Viacheslav Lotsmanov, 2020–2021
# License: MIT https://raw.githubusercontent.com/unclechu/nix-utils/master/LICENSE

# TODO Customizable derivation name for ‘wrapExecutable’
# TODO Redirection of stdin/stdout/stderr for ‘wrapExecutable’
# TODO Normal dependencies for ‘wrapExecutableWithPerlDeps’
# TODO Export ‘perlDependencies’ from ‘wrapExecutableWithPerlDeps’
# TODO Shell checker for a directory

# The easiest way to import this module is by using ‘nixpkgs.callPackage’, an example:
/*
  (import <nixpkgs> {}).callPackage (fetchTarball {
    url = "https://github.com/unclechu/nix-utils/archive/master.tar.gz";
  }) {}
*/
# Or from the directory where this file is:
/*
  (import <nixpkgs> {}).callPackage ./. {}
*/
{ lib, writeTextFile, dash, perlPackages }:
rec {
  esc = lib.escapeShellArg;

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
    writeTextFile {
      inherit name text;
      executable = true;
      destination = "/bin/${name}";
      checkPhase = "set -Eeuo pipefail || exit\n${checkPhase}";
    };

  # helpers for "checkPhase"
  shellCheckers = {
    fileIsExecutable = file:
      assert builtins.isString file || lib.isDerivation file;
      assert valueCheckers.isNonEmptyString "${file}";
      ''
        if ! [ -f ${esc file} -a -r ${esc file} -a -x ${esc file} ]; then
          >&2 printf 'File "%s" is supposed to be ' ${esc file}
          >&2 echo 'readable executable file but this assertion has failed!'
          exit 1
        fi
      '';

    fileIsReadable = file:
      assert builtins.isString file || lib.isDerivation file;
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
      dash-exe = "${dash}/bin/dash";

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
        lib.mapAttrsToList (k: v: "${k}=${esc v}") (builtins.removeAttrs env [PATH]) ++
        (if isNull newPath then [] else ["${PATH}=${newPath}"]);
    in
      assert valueCheckers.isNonEmptyString executable;
      assert builtins.isList deps;
      assert builtins.all lib.isDerivation deps;
      assert builtins.isAttrs env;
      assert builtins.isList args;
      assert valueCheckers.isNonEmptyString nameWithoutContext;
      assert builtins.all isValidEnvVarName (builtins.attrNames env);
      assert builtins.isString checkPhase;
    let
      newExecutable = writeCheckedExecutable nameWithoutContext ''
        ${shellCheckers.fileIsExecutable dash-exe}
        ${shellCheckers.fileIsExecutable executable}
        ${checkPhase}
      '' ''
        #! ${dash-exe}
        ${preList " " envVarsList}exec ${esc executable} ${preList " " (map esc args)}"$@"
      '';
    in
      assert lib.isDerivation newExecutable;
      newExecutable;

  # Wraps an executable providing some Perl 5 dependencies for that executable.
  # Overrides “PERL5LIB” environment variable (it’s uncomposable at the moment).
  # Usage example:
  #
  #   let
  #     pkgs = import <nixpkgs> {};
  #     utils = pkgs.callPackage /path/to/nix-utils {};
  #     name = "some-perl-script";
  #     perl = "${pkgs.perl}/bin/perl";
  #     checkPhase = utils.shellCheckers.fileIsExecutable perl;
  #     deps = perlPackages: [ perlPackages.IPCSystemSimple ];
  #
  #     perlScript = utils.writeCheckedExecutable name checkPhase ''
  #       #! ${perl}
  #       # Some perl script…
  #     '';
  #   in
  #     utils.wrapExecutableWithPerlDeps "${perlScript}/bin/${name}" { inherit deps; }
  #
  wrapExecutableWithPerlDeps = executable: { deps, checkPhase ? "" }:
    assert valueCheckers.isNonEmptyString executable;
    assert builtins.isString checkPhase;
    assert builtins.isFunction deps;
    let depsList = deps perlPackages; in
    assert builtins.isList depsList;
    assert builtins.all lib.isDerivation depsList;
    wrapExecutable executable {
      env = { PERL5LIB = perlPackages.makePerlPath depsList; };
      inherit checkPhase;
    };

  # Take a string, split it into a list of lines, apply provided callback function to the list,
  # take resulting list of lines and concatenate those lines back to a single string preserving the
  # string context.
  #
  # Mind that “builtins.split” drops all string context from the provided string.
  # This function helps to avoid mistakes based on this fact.
  # See also https://github.com/NixOS/nix/issues/2547
  #
  # String -> ([String] -> [String]) -> String
  mapStringAsLines = srcString: mapLines:
    lib.pipe srcString [
      (builtins.split "\n")
      (builtins.filter builtins.isString)
      mapLines
      (builtins.concatStringsSep "\n")
      (lib.flip builtins.appendContext (builtins.getContext srcString))
    ];
}
