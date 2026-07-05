{
  description = "weave — an ACP (Agent Client Protocol) client for Neovim, built on fibrous";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # The UI framework. A pinned flake input like any other: changes in the
    # sibling checkout are invisible until commit + push + `nix flake update
    # fibrous`. For day-to-day development every entry point below honors
    # FIBROUS_PATH (the Makefile defaults it to ../nui-reactive), so `make
    # test` / `make demo` always see the working tree.
    fibrous.url = "github:mbrea-c/fibrous.nvim";
  };

  outputs =
    {
      self,
      nixpkgs,
      fibrous,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in
    {
      # The plugin itself, packaged the standard nixpkgs way. fibrous is its UI
      # framework — a peer plugin, not vendored — declared as a `dependencies`
      # so any plugin manager that flattens vim-plugin deps (home-manager's
      # neovim module, nixvim, lazy-via-nixpkgs, …) pulls it onto the runtimepath
      # automatically when you add weave. Consumers need only THIS input; they
      # get weave's own pinned fibrous, no version skew.
      packages = forAllSystems (pkgs: rec {
        default = weave;
        weave = pkgs.vimUtils.buildVimPlugin {
          pname = "weave";
          version = self.shortRev or self.dirtyShortRev or "dev";
          src = self;
          dependencies = [ fibrous.packages.${pkgs.stdenv.hostPlatform.system}.default ];
          # the real gate is the test suite (`nix flake check`); the generic
          # require-check chokes on modules that need a running UI
          doCheck = false;
        };
      });

      # Runnable entry points, all against the flake's own snapshot of the
      # source (commit/stage changes to see them; use `make ...` against the
      # working tree during development):
      #   nix run .#test [-- tests/acp/load_spec.lua]   the suite / one spec
      #   nix run .#bench                               benchmarks (BENCH_N=…)
      #   nix run .#demo                                the UI in a clean nvim
      # `nix run .` (default) opens the demo.
      apps = forAllSystems (
        pkgs:
        let
          app = name: text: {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                inherit name text;
                runtimeInputs = [ pkgs.neovim ];
              }
            );
          };
        in
        rec {
          default = demo;
          test = app "weave-test" ''
            export FIBROUS_PATH="''${FIBROUS_PATH:-${fibrous}}"
            cd ${self}
            exec nvim --headless -u NONE -i NONE -l tests/run.lua "$@"
          '';
          bench = app "weave-bench" ''
            export FIBROUS_PATH="''${FIBROUS_PATH:-${fibrous}}"
            cd ${self}
            exec nvim --headless -u NONE -i NONE -l bench/run.lua "$@"
          '';
          demo = app "weave-demo" ''
            export FIBROUS_PATH="''${FIBROUS_PATH:-${fibrous}}"
            exec nvim --clean -u ${self}/demo/init.lua
          '';
        }
      );

      # `nix develop` drops you into a shell with the tools used for development:
      # neovim (the test host + target), make, the Lua language server (LuaCATS
      # type checking), and stylua (formatting).
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.neovim
            pkgs.gnumake
            pkgs.lua-language-server
            pkgs.stylua
          ];
        };
      });

      # `nix flake check` runs the full test suite in the build sandbox, in a
      # fully isolated headless Neovim (no user config, no plugins), against
      # the PINNED fibrous.
      checks = forAllSystems (pkgs: {
        tests =
          pkgs.runCommandLocal "weave-tests"
            {
              nativeBuildInputs = [
                pkgs.neovim
                pkgs.gnumake
              ];
            }
            ''
              cp -r ${self}/. work && chmod -R +w work && cd work
              export HOME="$TMPDIR"
              export FIBROUS_PATH=${fibrous}
              make test
              touch "$out"
            '';
      });
    };
}
