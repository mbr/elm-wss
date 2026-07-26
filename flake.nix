{
  description = "Simple WebSockets for Elm";

  inputs.nixpkgs.url = "nixpkgs/nixos-26.05";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];
      eachSystem = nixpkgs.lib.genAttrs systems;
      pkgsFor = eachSystem (system: nixpkgs.legacyPackages.${system});
    in
    {
      devShells = eachSystem (system: {
        default = pkgsFor.${system}.mkShell {
          packages = with pkgsFor.${system}; [
            elmPackages.elm
            elmPackages.elm-format
            nixfmt
            websocat
          ];
        };
      });
    };
}
