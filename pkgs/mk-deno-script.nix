# Package a Deno script with vendored dependencies
{
  lib,
  stdenv,
  deno,
  runtimeShell,
  runCommandNoCC,
}:

{
  name,
  src,
  denoArgs ? [ ],
  denoDepsHash,
}:

let
  deps = stdenv.mkDerivation {
    name = "${name}-deps";
    inherit src;
    nativeBuildInputs = [ deno ];
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = denoDepsHash;

    phases = [
      "buildPhase"
      "installPhase"
    ];

    buildPhase = ''
      deno install --vendor --entrypoint $src
    '';

    installPhase = ''
      cp -r vendor/ $out
    '';
  };

  extraArgs = lib.concatStringsSep " " denoArgs;
in
runCommandNoCC name
  {
    passthru = {
      inherit deps;
    };
  }
  ''
    mkdir -p $out/lib
    mkdir -p $out/bin

    ln -s ${deps} $out/lib/vendor

    fullpath="${src}"
    filename="''${fullpath##*/}"
    cp "${src}" $out/lib/$filename

    cat > $out/bin/${name} << EOF
    #!${runtimeShell}
    cd $out/lib
    exec ${deno}/bin/deno run --vendor=true ${extraArgs} $filename "\$@"
    EOF

    chmod +x $out/bin/${name}
  ''
