{ pkgs, lib, ... }:
let
  commonPackages = with pkgs; [
    # utils for dependencies
    git
    openssh
    gh
  ];

  linuxOnly = lib.optionals pkgs.stdenv.isLinux [
    pkgs.inotify-tools
  ];

  basePackages = commonPackages ++ linuxOnly;

in {
  languages = {
    elixir.enable = true;
    erlang.enable = true;
    rust.enable = true;
  };

  cachix = {
    enable = true;
    pull = [ "fermuch" ];
  };

  # Install packages
  packages = basePackages;

  # publish the libraries to the environment
  env.LIBRARY_PATH = pkgs.lib.makeLibraryPath basePackages;
  env.LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath basePackages;
  env.PKG_CONFIG_PATH = pkgs.lib.makeSearchPath "lib/pkgconfig" basePackages;

  # Enable shell history for erlang/elixir
  env.ERL_AFLAGS = "-kernel shell_history enabled";

  # Force local NIF build for development (precompiled NIFs not yet published)
  env.REED_SOLOMON_EX_FORCE_BUILD = "1";

  # Configure UTF-8 locale for proper Unicode support
  env.LC_ALL = "en_US.UTF-8";
  env.LANG = "en_US.UTF-8";
}
