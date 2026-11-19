{
  lib,
  stdenv,
  zig_0_17,
  gitMinimal,
  bash,
  coreutils,
  gnugrep,
  makeBinaryWrapper,
  versionCheckHook,
}:
let
  zig = zig_0_17;

  # Single source of truth for the version is build.zig.zon.
  version = lib.head (
    builtins.match ".*\\.version = \"([^\"]+)\".*" (builtins.readFile ../build.zig.zon)
  );
in
# Kept in step with pkgs/by-name/zi/ziggity/package.nix in nixpkgs, except
# that this builds the working tree rather than a release tag.
stdenv.mkDerivation (finalAttrs: {
  pname = "ziggity";
  inherit version;
  strictDeps = true;
  __structuredAttrs = true;

  # Only what the build needs (mirrors `.paths` in build.zig.zon), so editing
  # docs or CI files does not trigger a rebuild.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../src
      ../LICENSE
      ../README.md
    ];
  };

  # The Zig package dependencies from build.zig.zon (libvaxis and its own
  # dependencies), fetched ahead of time because the build sandbox has no
  # network. When build.zig.zon's dependencies change, set this to
  # `lib.fakeHash`, run `nix build`, and paste the hash it reports.
  zigDeps = zig.fetchDeps {
    inherit (finalAttrs) src pname version;
    fetchAll = true;
    hash = "sha256-OjvuVDDu5l6pxx0Yew0TxqZQ6OsnPeU7x3ZMfnvhdLU=";
  };

  # Tests run git with a hardcoded macOS-style PATH
  postPatch = ''
    substituteInPlace src/app.zig src/git.zig \
      --replace-fail "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
        "${
          lib.makeBinPath [
            gitMinimal
            bash
            coreutils
            gnugrep
          ]
        }"
  '';

  postConfigure = ''
    ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
  '';

  nativeBuildInputs = [
    zig
    makeBinaryWrapper
  ];

  doCheck = true;
  nativeCheckInputs = [ gitMinimal ];

  preCheck = ''
    export HOME=$TMPDIR
    git config --global user.name nixbld
    git config --global user.email nixbld@localhost
  '';

  # Ziggity drives `git` as a subprocess. Append ours as a fallback so a git
  # already on the user's PATH (with their config and credential helpers)
  # still wins.
  postInstall = ''
    wrapProgram $out/bin/ziggity \
      --suffix PATH : ${lib.makeBinPath [ gitMinimal ]}
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];

  meta = {
    description = "Fast, keyboard-driven terminal UI for Git";
    homepage = "https://ziggity.dev";
    license = lib.licenses.mit;
    mainProgram = "ziggity";
    inherit (zig.meta) platforms;
  };
})
