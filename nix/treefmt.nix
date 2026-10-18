# treefmt.nix
{ pkgs, ... }:
{
  # Used to find the project root
  projectRootFile = "flake.nix";
  # Enable the terraform formatter
  programs.mix-format = {
    enable = true;
    package = pkgs.elixir;
  };
  # Formatted with its own .formatter.exs, which imports the formatter
  # settings of Ash, Phoenix, and Plug and runs Spark's plugin; the
  # repository-level formatter would add parentheses to every DSL call. The
  # credo pre-commit hook checks it with `mix format --check-formatted`.
  settings.formatter.mix-format.excludes = [ "apps/tackle_hub/**" ];

  programs.nixfmt = {
    enable = true;
  };

  programs.yamlfmt = {
    enable = true;
  };
}
