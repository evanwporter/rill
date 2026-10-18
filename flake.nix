{
	description = "Minimal Zig project with Nix dev shell and buildable package";

	inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

	outputs = {
		self,
		nixpkgs,
	}: let
		systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];

		forAllSystems = f:
			nixpkgs.lib.genAttrs systems
			(system: f nixpkgs.legacyPackages.${system});
	in {
		devShells =
			forAllSystems (pkgs: {
					default =
						pkgs.mkShell {
							packages = with pkgs; [
								zig_0_17
								river
								pkg-config
								wayland
								wayland-scanner
								wayland-protocols
								libxkbcommon
								wlr-randr
								xwayland
								swaybg
							];
						};
				});
	};
}
