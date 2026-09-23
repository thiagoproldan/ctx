{
  lib,
  stdenvNoCC,
  makeWrapper,
  bash,
  python3,
  antigravity-cli,
  bubblewrap,
  coreutils,
  findutils,
  gawk,
  gnugrep,
  gnused,
  jq,
  shfmt,
  systemd,
}:
let
  # Everything the scripts call. Appended to PATH (--suffix), not prepended: the
  # test suite builds a PATH without graphify to prove the hint stays quiet, and
  # graphify is deliberately NOT a dependency — it is optional, found on the
  # user's PATH when present.
  runtimePath = lib.makeBinPath [
    antigravity-cli
    bubblewrap
    coreutils
    findutils
    gawk
    gnugrep
    gnused
    jq
    python3
    shfmt
    systemd # busctl, for `shunt-test --live`
  ];
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "shunt";
  version = "2.0.0";

  src = ./src;

  nativeBuildInputs = [ makeWrapper ];
  # patchShebangs resolves `#!/usr/bin/env bash|python3` against these.
  buildInputs = [
    bash
    python3
  ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    root=$out/share/shunt
    mkdir -p $root $out/bin
    cp -r hooks lib bin skills report.sh test-hooks.sh $root/
    chmod +x $root/hooks/* $root/bin/* $root/report.sh $root/test-hooks.sh

    # The plugin directory holds only the manifest: Claude Code discovers
    # skills/, hooks/ and bin/ by convention inside a plugin root, and those
    # directories here are scripts, not plugin components.
    mkdir -p $root/plugin/.claude-plugin
    substitute ${./plugin.json} $root/plugin/.claude-plugin/plugin.json \
      --subst-var-by root $root \
      --subst-var-by version ${finalAttrs.version}

    runHook postInstall
  '';

  postFixup = ''
    root=$out/share/shunt
    for f in $root/hooks/* $root/bin/* $root/report.sh $root/test-hooks.sh; do
      wrapProgram "$f" --suffix PATH : ${runtimePath}
    done
    makeWrapper $root/bin/bulk-read  $out/bin/shunt-bulk-read
    makeWrapper $root/bin/code-write $out/bin/shunt-code-write
    makeWrapper $root/bin/login      $out/bin/shunt-login
    makeWrapper $root/bin/statusline $out/bin/shunt-statusline
    makeWrapper $root/report.sh      $out/bin/shunt-report
    makeWrapper $root/test-hooks.sh  $out/bin/shunt-test
  '';

  # The hermetic suite runs against the installed, wrapped hooks: what ships is
  # what was tested.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    HOME=$TMPDIR $out/bin/shunt-test
    runHook postInstallCheck
  '';

  meta = {
    description = "Claude Code plugin that shunts bulk reads and boilerplate to a sandboxed Gemini worker";
    homepage = "https://engineering.atspotify.com/2026/9/portal-by-spotify-cut-my-claude-code-token-usage-by-90";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "shunt-report";
  };
})
