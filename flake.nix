{
  description = "GhidraMCP packaged for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          ghidraMcp = pkgs.callPackage ./default.nix {
            buildGhidraExtension = pkgs."ghidra-extensions".buildGhidraExtension or null;
          };
        in
        {
          default = ghidraMcp;
          inherit (ghidraMcp)
            bridge
            extension
            extensionZip
            headless
            javaArtifacts
            opencode
            ;
        }
      );

      apps = forAllSystems (
        pkgs:
        let
          packages = self.packages.${pkgs.system};
        in
        {
          default = self.apps.${pkgs.system}.bridge;
          bridge = {
            type = "app";
            program = "${packages.bridge}/bin/bridge_mcp_ghidra";
          };
          headless = {
            type = "app";
            program = "${packages.headless}/bin/ghidra-mcp-headless";
          };
          opencode = {
            type = "app";
            program = "${packages.opencode}/bin/ghidra-mcp-opencode";
          };
        }
      );

      devShells = forAllSystems (
        pkgs:
        let
          ghidraMcp = self.packages.${pkgs.system}.default;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.ghidra
              pkgs.gradle
              pkgs.jdk21
              pkgs.maven
              ghidraMcp.pythonEnv
            ];

            GHIDRA_INSTALL_DIR = "${pkgs.ghidra}/lib/ghidra";
            TOOLS_SETUP_BACKEND = "gradle";
          };
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}
