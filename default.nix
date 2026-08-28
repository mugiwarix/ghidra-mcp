{
  lib,
  stdenv,
  stdenvNoCC,
  symlinkJoin,
  runCommand,
  writeShellApplication,
  makeWrapper,
  coreutils,
  curl,
  findutils,
  gradle,
  ghidra,
  jdk21,
  python3,
  unzip,
  buildGhidraExtension ? null,
  ghidraInstallDir ? "${ghidra}/lib/ghidra",
}:

let
  pname = "ghidra-mcp";
  extensionName = "GhidraMCP";
  version = "7.0.0";

  meta = {
    description = "Ghidra MCP bridge, GUI extension, and headless server";
    homepage = "https://github.com/bethington/ghidra-mcp";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
  };

  src = lib.cleanSourceWith {
    src = ./.;
    filter =
      path: type:
      let
        rel = lib.removePrefix (toString ./. + "/") (toString path);
      in
      rel == "pom.xml"
      || rel == "settings.gradle"
      || rel == "build.gradle"
      || rel == "python"
      || rel == "src"
      || lib.hasPrefix "python/" rel
      || lib.hasPrefix "src/" rel;
  };

  pythonEnv = python3.withPackages (ps: [
    ps.mcp
    ps.requests
  ]);

  javaArtifacts = stdenv.mkDerivation {
    pname = "${pname}-artifacts";
    inherit version src meta;

    nativeBuildInputs = [
      gradle
      jdk21
    ];

    buildPhase = ''
      runHook preBuild

      export HOME="$TMPDIR/home"
      export GRADLE_USER_HOME="$TMPDIR/gradle-home"
      export XDG_CONFIG_HOME="$TMPDIR/xdg-config"
      mkdir -p "$HOME" "$GRADLE_USER_HOME" "$XDG_CONFIG_HOME"

      gradle --no-daemon --offline --no-build-cache \
        buildExtension \
        -PGHIDRA_INSTALL_DIR=${ghidraInstallDir}

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      install -Dm644 build/distributions/${extensionName}-${version}.zip \
        "$out/share/${pname}/${extensionName}-${version}.zip"
      install -Dm644 build/libs/${extensionName}-${version}.jar \
        "$out/share/${pname}/${extensionName}-${version}.jar"

      runHook postInstall
    '';

    passthru = {
      inherit ghidraInstallDir;
      extensionZip = "${javaArtifacts}/share/${pname}/${extensionName}-${version}.zip";
      jar = "${javaArtifacts}/share/${pname}/${extensionName}-${version}.jar";
    };
  };

  extensionZip = runCommand "${pname}-extension-zip-${version}" { inherit meta; } ''
    mkdir -p "$out/share/${pname}"
    ln -s ${javaArtifacts}/share/${pname}/${extensionName}-${version}.zip \
      "$out/share/${pname}/${extensionName}-${version}.zip"
  '';

  extension = stdenvNoCC.mkDerivation {
    pname = "${pname}-extension";
    inherit version meta;

    dontUnpack = true;
    nativeBuildInputs = [ unzip ];

    installPhase = ''
      runHook preInstall

      mkdir -p "$out/lib/ghidra/Ghidra/Extensions"
      unzip -q ${javaArtifacts}/share/${pname}/${extensionName}-${version}.zip \
        -d "$out/lib/ghidra/Ghidra/Extensions"

      touch "$out/lib/ghidra/Ghidra/Extensions/${extensionName}/.dbDirLock"

      runHook postInstall
    '';

    passthru = {
      inherit javaArtifacts extensionZip buildGhidraExtension;
    };
  };

  bridge = stdenvNoCC.mkDerivation {
    pname = "${pname}-bridge";
    inherit version src meta;

    nativeBuildInputs = [ makeWrapper ];

    installPhase = ''
      runHook preInstall

      mkdir -p "$out/lib/${pname}"
      cp -r python/bridge_mcp_ghidra "$out/lib/${pname}/"
      makeWrapper ${pythonEnv}/bin/python "$out/bin/bridge_mcp_ghidra" \
        --prefix PYTHONPATH : "$out/lib/${pname}" \
        --add-flags "-m bridge_mcp_ghidra"
      runHook postInstall
    '';

    passthru = {
      inherit pythonEnv;
    };
  };

  headless = writeShellApplication {
    name = "ghidra-mcp-headless";
    runtimeInputs = [
      findutils
      jdk21
    ];
    text = ''
      ghidra_home="''${GHIDRA_HOME:-${ghidraInstallDir}}"
      app_jar="${javaArtifacts}/share/${pname}/${extensionName}-${version}.jar"

      classpath="$app_jar"
      for jar_root in \
        "$ghidra_home/Ghidra/Framework" \
        "$ghidra_home/Ghidra/Features" \
        "$ghidra_home/Ghidra/Debug" \
        "$ghidra_home/Ghidra/Processors"; do
        if [ -d "$jar_root" ]; then
          while IFS= read -r -d ''' jar; do
            classpath="$classpath:$jar"
          done < <(find "$jar_root" -path '*/lib/*.jar' -type f -print0)
        fi
      done

      java_opts_string="''${JAVA_OPTS:--Xmx4g -XX:+UseG1GC}"
      # shellcheck disable=SC2206
      java_opts=($java_opts_string)

      exec ${jdk21}/bin/java \
        "''${java_opts[@]}" \
        -Dghidra.home="$ghidra_home" \
        -Dapplication.name=GhidraMCP \
        -classpath "$classpath" \
        com.xebyte.headless.GhidraMCPHeadlessServer \
        "$@"
    '';
    meta = meta;
  };

  opencode = writeShellApplication {
    name = "ghidra-mcp-opencode";
    runtimeInputs = [
      coreutils
      curl
    ];
    text = ''
      port="''${GHIDRA_MCP_PORT:-8090}"
      bind_address="''${GHIDRA_MCP_BIND_ADDRESS:-127.0.0.1}"
      if [ -n "''${GHIDRA_MCP_URL:-}" ]; then
        url="$GHIDRA_MCP_URL"
        autostart="''${GHIDRA_MCP_OPENCODE_AUTOSTART:-0}"
      else
        url="http://127.0.0.1:$port"
        autostart="''${GHIDRA_MCP_OPENCODE_AUTOSTART:-1}"
      fi
      export GHIDRA_MCP_URL="$url"

      state_home="''${XDG_STATE_HOME:-$HOME/.local/state}"
      log_file="''${GHIDRA_MCP_HEADLESS_LOG:-$state_home/ghidra-mcp/headless.log}"
      mkdir -p "$(dirname "$log_file")"

      started_pid=""
      if ! curl -fsS "$url/check_connection" >/dev/null 2>&1 && [ "$autostart" = "1" ]; then
        headless_args=(--port "$port" --bind "$bind_address")
        if [ -n "''${GHIDRA_MCP_FILE:-}" ]; then
          headless_args+=(--file "$GHIDRA_MCP_FILE")
        fi
        if [ -n "''${GHIDRA_MCP_PROJECT:-}" ]; then
          headless_args+=(--project "$GHIDRA_MCP_PROJECT")
        fi
        if [ -n "''${GHIDRA_MCP_PROGRAM:-}" ]; then
          headless_args+=(--program "$GHIDRA_MCP_PROGRAM")
        fi

        ${headless}/bin/ghidra-mcp-headless "''${headless_args[@]}" >>"$log_file" 2>&1 &
        started_pid="$!"

        attempts=0
        until curl -fsS "$url/check_connection" >/dev/null 2>&1; do
          attempts=$((attempts + 1))
          if [ "$attempts" -ge "''${GHIDRA_MCP_STARTUP_TIMEOUT:-120}" ]; then
            if [ -n "$started_pid" ]; then
              kill "$started_pid" >/dev/null 2>&1 || true
            fi
            printf 'GhidraMCP headless server did not become ready. See %s\n' "$log_file" >&2
            exit 1
          fi
          sleep 1
        done
      fi

      set +e
      ${bridge}/bin/bridge_mcp_ghidra --transport stdio --no-lazy "$@"
      status="$?"
      set -e

      if [ -n "$started_pid" ]; then
        kill "$started_pid" >/dev/null 2>&1 || true
        wait "$started_pid" >/dev/null 2>&1 || true
      fi

      exit "$status"
    '';
    meta = meta;
  };
in
symlinkJoin {
  name = "${pname}-${version}";
  paths = [
    bridge
    headless
    opencode
    extensionZip
  ];
  inherit meta;
  passthru = {
    inherit
      bridge
      buildGhidraExtension
      extension
      extensionZip
      ghidraInstallDir
      headless
      javaArtifacts
      opencode
      pythonEnv
      version
      ;
  };
}
