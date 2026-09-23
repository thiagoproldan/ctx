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
    systemd # busctl, for `ctx-test --live`
  ];
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "ctx";
  version = "0.1.0";

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

    root=$out/share/ctx
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
    root=$out/share/ctx
    for f in $root/hooks/* $root/bin/* $root/report.sh $root/test-hooks.sh; do
      wrapProgram "$f" --suffix PATH : ${runtimePath}
    done
    makeWrapper $root/bin/bulk-read  $out/bin/ctx-bulk-read
    makeWrapper $root/bin/code-write $out/bin/ctx-code-write
    makeWrapper $root/bin/login      $out/bin/ctx-login
    makeWrapper $root/bin/statusline $out/bin/ctx-statusline
    makeWrapper $root/report.sh      $out/bin/ctx-report
    makeWrapper $root/test-hooks.sh  $out/bin/ctx-test
  '';

  # The hermetic suite runs against the installed, wrapped hooks: what ships is
  # what was tested.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    HOME=$TMPDIR $out/bin/ctx-test
    runHook postInstallCheck
  '';

  meta = {
    description = "Claude Code plugin that keeps the context small: bulk reads go to a sandboxed Gemini worker, and past a threshold the session hands off to ekko";
    homepage = "https://github.com/thiagoproldan/ctx";
    # Upstream shunt's license (spotify/portal-ai-plugins); see NOTICE.
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
    mainProgram = "ctx-report";
  };
})
