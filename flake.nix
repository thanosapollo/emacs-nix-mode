{
  description = "Tree-sitter Emacs major mode and tooling for Nix";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;

      keymapPopupVersion = "0.3.1";

      sourceFiles = [
        ".gitignore"
        "LICENSE"
        "Makefile"
        "README.md"
        "flake.lock"
        "flake.nix"
        "lisp/nix-commands.el"
        "lisp/nix-core.el"
        "lisp/nix-flake.el"
        "lisp/nix-menu.el"
        "lisp/nix-mode.el"
        "lisp/nix-prettify.el"
        "lisp/nix-repl.el"
        "lisp/nix-shell.el"
        "lisp/nix-store.el"
        "tests/nix-test-commands.el"
        "tests/nix-test-core.el"
        "tests/nix-test-flake.el"
        "tests/nix-test-mode.el"
        "tests/nix-test-prettify.el"
        "tests/nix-test-repl.el"
        "tests/nix-test-shell.el"
        "tests/nix-test-store.el"
      ];

      # Build everything for one concrete Emacs.  Called once per
      # variant (full build, and emacs-nox) so the test matrix can
      # exercise both.
      mkVariant =
        pkgs: emacs:
        let
          lib = pkgs.lib;
          emacsPackages = pkgs.emacsPackagesFor emacs;

          source = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions (map (file: ./. + "/${file}") sourceFiles);
          };
          sourceManifest = pkgs.writeText "nix-mode-source-files" (
            lib.concatStringsSep "\n" sourceFiles + "\n"
          );

          # Pinned to a git revision until the next ELPA release: the
          # 0.3.1 tarball's switch macro generates over-wide docstrings
          # that trip byte-compile warnings in client code.
          keymapPopup = emacsPackages.trivialBuild {
            pname = "keymap-popup";
            version = keymapPopupVersion;
            src = pkgs.fetchgit {
              url = "https://codeberg.org/thanosapollo/emacs-keymap-popup";
              rev = "fe0e538d35e8bb63e165e78506eff3253fd234d8";
              hash = "sha256-QU/QxlKEWBRClDb4cM4vhaRizsJ3ooNrn0f6zzJ4RC4=";
            };
            packageRequires = [ ];
          };

          # Prebuilt tree-sitter-nix grammar.  The bundle contains
          # lib/libtree-sitter-nix.so, which is the directory Emacs
          # expects on `treesit-extra-load-path'.
          nixGrammars = emacsPackages.treesit-grammars.with-grammars (g: [ g.tree-sitter-nix ]);

          emacsWithPackages = emacsPackages.emacsWithPackages (epkgs: [
            keymapPopup
            epkgs.package-lint
            epkgs.relint
          ]);

          # Run a Makefile test target in a sandbox that mirrors a
          # buildd: clean HOME/XDG, grammar provided via env.
          mkTests =
            { pname, target }:
            pkgs.stdenv.mkDerivation {
              inherit pname;
              version = "git";
              src = source;
              nativeBuildInputs = [
                emacsWithPackages
                pkgs.gnumake
              ];
              dontConfigure = true;

              buildPhase = ''
                runHook preBuild
                find . -type f -printf '%P\n' | LC_ALL=C sort > "$TMPDIR/source-files"
                diff -u ${sourceManifest} "$TMPDIR/source-files"
                export HOME="$TMPDIR/home"
                export XDG_CACHE_HOME="$TMPDIR/cache"
                export XDG_CONFIG_HOME="$TMPDIR/config"
                export XDG_DATA_HOME="$TMPDIR/share"
                export XDG_STATE_HOME="$TMPDIR/state"
                mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" \
                  "$XDG_DATA_HOME" "$XDG_STATE_HOME"
                EMACS_CMD=emacs \
                  NIX_MODE_TS_DIR="${nixGrammars}/lib" \
                  NIX_MODE_ENV_WRAPPED=1 \
                  make ${target}
                runHook postBuild
              '';

              installPhase = ''
                runHook preInstall
                mkdir -p $out
                touch $out/tests-passed
                runHook postInstall
              '';
            };
        in
        {
          inherit
            emacs
            emacsWithPackages
            keymapPopup
            nixGrammars
            ;
          # Per-file: one Emacs per test file (fast, good isolation).
          tests = mkTests {
            pname = "nix-mode-tests";
            target = "test";
          };
          # Combined: every file in one Emacs, suite run twice -- mirrors
          # dh_elpa_test and catches cross-test state pollution.
          testsOneshot = mkTests {
            pname = "nix-mode-tests-oneshot";
            target = "test-oneshot";
          };
        };

      mkNixMode =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          inherit pkgs;
          full = mkVariant pkgs (pkgs.emacs30 or pkgs.emacs29 or pkgs.emacs);
          nox = mkVariant pkgs pkgs.emacs-nox;
        };
    in
    {
      checks = forAllSystems (
        system:
        let
          nixMode = mkNixMode system;
        in
        {
          # Test matrix: {full, nox} x {per-file, combined-twice}.
          test = nixMode.full.tests;
          test-nox = nixMode.nox.tests;
          test-oneshot = nixMode.full.testsOneshot;
          test-oneshot-nox = nixMode.nox.testsOneshot;
        }
      );

      devShells = forAllSystems (
        system:
        let
          nixMode = mkNixMode system;
        in
        {
          default = nixMode.pkgs.mkShell {
            packages = with nixMode.pkgs; [
              cacert
              git
              gnumake
              nix
              nixfmt
              nixMode.full.emacsWithPackages
            ];

            shellHook = ''
              export EMACS_CMD=emacs
              export NIX_MODE_TS_DIR="${nixMode.full.nixGrammars}/lib"
            '';
          };
        }
      );
    };
}
