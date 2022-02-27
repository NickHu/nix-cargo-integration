attrs:
let
  pkgs = if builtins.isAttrs attrs then attrs.pkgs else attrs;
  lib = if builtins.isAttrs attrs then attrs.lib or pkgs.lib else pkgs.lib;

  # courtesy of devshell
  resolveToPkg = key:
    let
      attrs = builtins.filter builtins.isString (builtins.split "\\." key);
      op = sum: attr: sum.${attr} or (throw "package \"${key}\" not found");
    in
    builtins.foldl' op pkgs attrs;
  resolveToPkgs = builtins.map resolveToPkg;
in
{
  inherit resolveToPkg resolveToPkgs;

  # Removes `propagatedEnv` attributes from some `crateOverride`s.
  removePropagatedEnv = builtins.mapAttrs (_: v: (prev: builtins.removeAttrs (v prev) [ "propagatedEnv" ]));

  # Creates a nixpkgs-compatible nix expression that uses `buildRustPackage`.
  createNixpkgsDrv = common: pkgs.writeTextFile {
    name = "${common.cargoPkg.name}.nix";
    text =
      let
        inherit (common) root cargoPkg pkgs buildInputs nativeBuildInputs desktopFileMetadata;
        inherit (builtins) any map hasAttr baseNameOf concatStringsSep filter length attrNames attrValues split isList isString stringLength elemAt;
        inherit (lib) optional optionalString cargoLicenseToNixpkgs concatMapStringsSep mapAttrsToList getName init filterAttrs unique hasPrefix splitString drop;
        has = i: any (oi: i == oi);

        clang = [ "clang-wrapper" "clang" ];
        gcc = [ "gcc-wrapper" "gcc" ];

        filterUnwanted = filter (n: !(has n (clang ++ gcc ++ [ "pkg-config-wrapper" "binutils-wrapper" ])));
        mapToName = map getName;
        concatForInput = i: concatStringsSep "" (map (p: "\n  ${p},") i);

        bi = filterUnwanted ((mapToName buildInputs) ++ (mapToName common.runtimeLibs));
        nbi = (filterUnwanted (mapToName nativeBuildInputs))
          ++ (optional common.mkRuntimeLibsOv "makeWrapper")
          ++ (optional common.mkDesktopFile "copyDesktopItems");
        runtimeLibs = "\${lib.makeLibraryPath ([ ${concatStringsSep " " (mapToName common.runtimeLibs)} ])}";
        stdenv = if any (n: has n clang) (mapToName nativeBuildInputs) then "clangStdenv" else null;
        putIfStdenv = optionalString (stdenv != null);

        runtimeLibsScript =
          concatStringsSep "\n" (
            map
              (line: "    ${line}")
              (init (
                filter
                  (list: if isList list then (length list) > 0 else true)
                  (split "\n" (common.mkRuntimeLibsScript runtimeLibs))
              ))
          );

        desktopItemAttrs =
          let
            desktopItem = common.mkDesktopItemConfig cargoPkg.name;
            filtered =
              filterAttrs
                (_: v: !(lib.hasPrefix "/nix/store" v) && (toString v) != "")
                desktopItem;
            attrsWithIcon =
              if !(hasAttr "icon" filtered) && (hasAttr "icon" common.desktopFileMetadata)
              then filtered // { icon = "\${src}/${lib.removePrefix "./" common.desktopFileMetadata.icon}"; }
              else filtered;
            attrs = mapAttrsToList (n: v: "    ${n} = \"${v}\";") attrsWithIcon;
          in
          concatStringsSep "\n" attrs;
        desktopItems = "\n  desktopItems = [ (makeDesktopItem {\n${desktopItemAttrs}\n  }) ];";
        desktopLink = "\n  desktopItems = [ (pkgs.runCommand \"${cargoPkg.name}-desktopFileLink\" { } ''\n    mkdir -p $out/share/applications\n    ln -sf \${src}/${desktopFileMetadata} $out/share/applications\n  '') ];";

        isGitHub = builtins.pathExists (root + "/.github");
        isGitLab = builtins.pathExists (root + "/.gitlab");

        mkForgeFetch = name: rec {
          fetcher = "fetchFrom${name}";
          fetchCode =
            let version = "v\${version}"; in
            ''
              src = ${fetcher} {
                owner = "<enter owner>";
                repo = "${cargoPkg.name}";
                rev = "${version}";
                sha256 = lib.fakeHash;
              };'';
        };

        githubFetcher = mkForgeFetch "GitHub";
        gitlabFetcher = mkForgeFetch "GitLab";

        fetcher =
          if isGitLab
          then gitlabFetcher
          else if isGitHub
          then githubFetcher
          else githubFetcher;

        envToString = value:
          let val = toString value; in
          if hasPrefix "/nix/store" value
          then
            let
              pathSegments = filter (v: (stringLength v) > 0) (splitString "/" val);

              hashName = elemAt pathSegments 2;
              nameSegments = drop 1 (splitString "-" hashName);
              name = concatStringsSep "-" nameSegments;
              drvName = getName (lib.strings.sanitizeDerivationName name);

              relPathSegments = drop 3 pathSegments;
              relPath = concatStringsSep "/" relPathSegments;
            in
            "\${${drvName}}/" + relPath
          else val;
      in
      ''
        { lib,
          rustPlatform,${putIfStdenv "\n  ${stdenv},"}
          ${fetcher.fetcher},${concatForInput (unique (bi ++ nbi))}
        }:
        rustPlatform.buildRustPackage rec {
          pname = "${cargoPkg.name}";
          version = "${cargoPkg.version}";${putIfStdenv "\n\n  stdenv = ${stdenv};"}

          # Change to use whatever source you want
          ${concatMapStringsSep "\n" (line: "  ${line}") (lib.splitString "\n" fetcher.fetchCode)}

          cargoSha256 = lib.fakeHash;${
            optionalString
              ((length (attrNames common.env)) > 0)
              "\n\n${concatStringsSep "\n" (mapAttrsToList (n: v: "  ${n} = \"${envToString v}\";") common.env)}"
          }

          buildInputs = [ ${concatStringsSep " " bi} ];
          nativeBuildInputs = [ ${concatStringsSep " " nbi} ];${
            optionalString
              common.mkRuntimeLibsOv
              "\n\n  postFixup = ''\n${runtimeLibsScript}\n  '';"
          }${
            optionalString
              common.mkDesktopFile
              (
                if isString desktopFileMetadata
                then desktopLink
                else desktopItems
              )
          }

          cargoBuildFlags = [ "--package" "${cargoPkg.name}" ];
          cargoTestFlags = cargoBuildFlags;

          meta = with lib; {
            description = "${common.meta.description or "<enter description>"}";
            homepage = "${common.meta.homepage or "<enter homepage>"}";
            license = licenses.${cargoLicenseToNixpkgs (cargoPkg.license or "unfree")};
            maintainers = with maintainers; [ ];
          };
        }
      '';
  };

  # Creates crate overrides for crate2nix to use.
  # The crate overrides will be "collected" in common.nix for naersk and devshell to use them.
  makeCrateOverrides =
    { rawTomlOverrides ? { }
    , cCompiler ? pkgs.gcc
    , useCCompilerBintools ? true
    , crateName
    }:
    let
      mainOverride = {
        ${crateName} = prev: {
          buildInputs = (prev.buildInputs or [ ]) ++ [ pkgs.zlib ];
        };
      };
      baseConf = prev: {
        # No CC since we provide our own compiler
        stdenv = pkgs.stdenvNoCC;
        nativeBuildInputs = lib.unique ((prev.nativeBuildInputs or [ ]) ++ [ cCompiler ] ++ (lib.optional useCCompilerBintools cCompiler.bintools));
        # Set CC to "cc" to workaround some weird issues (and to not bother with finding exact compiler path)
        CC = "cc";
      };
      tomlOverrides = builtins.mapAttrs
        (_: crate: prev: {
          nativeBuildInputs = lib.unique ((prev.nativeBuildInputs or [ ]) ++ (resolveToPkgs (crate.nativeBuildInputs or [ ])));
          buildInputs = lib.unique ((prev.buildInputs or [ ]) ++ (resolveToPkgs (crate.buildInputs or [ ])));
        } // (crate.env or { }) // { propagatedEnv = crate.env or { }; })
        rawTomlOverrides;
      extraOverrides = import ./extraCrateOverrides.nix pkgs;
      collectOverride = acc: el: name:
        let
          getOverride = x: x.${name} or (o: o);
          accOverride = getOverride acc;
          elOverride = getOverride el;
        in
        attrs:
        let
          overrodedAccBase = attrs // accOverride attrs;
          overrodedAcc = overrodedAccBase // (baseConf overrodedAccBase);
        in
        overrodedAcc // (elOverride overrodedAcc);
    in
    builtins.foldl'
      (acc: el: lib.genAttrs (lib.unique ((builtins.attrNames acc) ++ (builtins.attrNames el))) (collectOverride acc el))
      pkgs.defaultCrateOverrides
      [ tomlOverrides extraOverrides mainOverride ];

  # dream2nix build crate.
  buildCrate =
    { root
    , memberName ? null
    , ... # pass everything else to dream2nix
    }@args:
    let
      attrs = {
        source = root;
      } // (builtins.removeAttrs args [ "root" "memberName" ]);
      outputs = pkgs.dream2nixTools.riseAndShine attrs;
    in
    if memberName != null
    then outputs.packages.${memberName}
    else outputs.defaultPackage;
}
