# Create an output (packages, apps, etc.) from a common.
{
  common,
  renameOutputs ? {},
}:
let
  inherit (common) cargoToml cargoPkg packageMetadata system memberName root;
  inherit (common.internal) nci-pkgs;

  l = common.internal.lib;

  # Metadata we will use later. Defaults should be the same as Cargo defaults.
  name = renameOutputs.${cargoPkg.name} or cargoPkg.name;
  edition = cargoPkg.edition or "2018";
  bins = cargoToml.bin or [];
  autobins = cargoPkg.autobins or (edition == "2018");

  # Find the package source.
  pkgSrc =
    let
      src =
        if memberName == null
        then root + "/src"
        else root + "/${memberName}" + "/src";
    in
      l.dbg "package source for ${name} at: ${src}" src;

  # Emulate autobins behaviour, get all the binaries of this package.
  allBins =
    l.unique (
      (l.optional (l.pathExists (pkgSrc + "/main.rs")) {
        inherit name;
        exeName = cargoPkg.name;
      })
      ++ bins
      ++ (
        l.optionals
        (autobins && (l.pathExists (pkgSrc + "/bin")))
        (
          l.genAttrs
          (
            l.map
            (l.removeSuffix ".rs")
            (l.attrNames (l.readDir (pkgSrc + "/bin")))
            (name: { inherit name; })
          )
        )
      )
    );

  # Helper function to use build.nix
  mkBuild = f: r: c:
    import ./build.nix {
      inherit common;
      features = f;
      doCheck = c;
      release = r;
      renamePkgTo = name;
    };
  # Helper function to create an app output.
  # This takes one "binary output" of this Cargo package.
  mkApp = bin: n: v: let
    ex = {
      exeName = bin.exeName or bin.name;
      name = "${bin.name}${
        if v.config.release
        then ""
        else "-debug"
      }";
    };
    drv =
      if (l.length (bin.required-features or [])) < 1
      then v.package
      else (mkBuild (bin.required-features or []) v.config.release v.config.doCheck).package;
    exePath = "/bin/${ex.exeName}";
  in {
    name = ex.name;
    value = {
      type = "app";
      program = "${drv}${exePath}";
    };
  };

  # "raw" packages that will be proccesed.
  # It's called so since `build.nix` generates an attrset containing the config and the package.
  packagesRaw = {
    "${name}" = mkBuild [] true true;
    "${name}-debug" = mkBuild [] false false;
  };
  # Packages set to be put in the outputs.
  packages = {
    ${system} =
      (l.mapAttrs (_: v: v.package) packagesRaw)
      // {
        "${name}-derivation" = import ./createNixpkgsDrv common;
      };
  };
  # Checks to be put in outputs.
  checks = {
    ${system} = {
      "${name}-tests" = (mkBuild [] false true).package;
    };
  };
  # Apps to be put in outputs.
  apps = {
    ${system} =
      # Make apps for all binaries, and recursively combine them.
      l.foldAttrs l.recursiveUpdate {}
      (
        l.map
        (exe: l.mapAttrs' (mkApp exe) packagesRaw)
        (l.dbg "binaries for ${name}: ${l.concatMapStringsSep ", " (bin: bin.name) allBins}" allBins)
      );
  };
in
  l.optionalAttrs (packageMetadata.build or false) ({
    inherit packages checks;
    defaultPackage = {
      ${system} = packages.${system}.${name};
    };
  }
  // l.optionalAttrs (packageMetadata.app or false) {
    inherit apps;
    defaultApp = {
      ${system} =
        let
          appName =
            if (l.length allBins) > 0
            then (l.head allBins).name
            else name;
        in
          apps.${system}.${appName};
    };
  })
