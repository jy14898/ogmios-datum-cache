{ nixpkgs ? import <nixpkgs> {}, compiler ? "default", doBenchmark ? false }:

let

  inherit (nixpkgs) pkgs;

  f = { mkDerivation, aeson, base, base16, bytestring, conduit
      , cryptohash-sha256, directory, esqueleto, exceptions, filepath
      , http-types, lib, monad-logger, mtl, optparse-applicative
      , persistent, persistent-postgresql, resource-pool, servant
      , servant-multipart, servant-server, text, time, wai, wai-extra
      , wai-logger, warp, websockets
      }:
      mkDerivation {
        pname = "ogmios-datum-cache";
        version = "0.1.0.0";
        src = ./.;
        isLibrary = false;
        isExecutable = true;
        executableHaskellDepends = [
          aeson base base16 bytestring conduit cryptohash-sha256 directory
          esqueleto exceptions filepath http-types monad-logger mtl
          optparse-applicative persistent persistent-postgresql resource-pool
          servant servant-multipart servant-server text time wai wai-extra
          wai-logger warp websockets
        ];
        license = "unknown";
        hydraPlatforms = lib.platforms.none;
      };

  haskellPackages = if compiler == "default"
                       then pkgs.haskellPackages
                       else pkgs.haskell.packages.${compiler};

  variant = if doBenchmark then pkgs.haskell.lib.doBenchmark else pkgs.lib.id;

  drv = variant (haskellPackages.callPackage f {});

in

  if pkgs.lib.inNixShell then drv.env else drv