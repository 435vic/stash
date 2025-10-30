{ config, ... }: {
  imports = [
    ../modules
  ];

  fileSystems."/".device = "/dev/null";
  boot.loader.grub.device = "/dev/null";
  users.users.vico = {
    isNormalUser = true;
    home = "/home/vico";
  };

  stash.users.vico = {
    stashes = {
      dotfiles = {
        path = "vicOS/config";
      };
    };

    files = {
      ".config/static".text = ''
        ASASLHFASHF
      '';

      ".config/nvim" = {
        source = ../lib;
        recursive = true;
      };

      # ".config/vivaldi" = {
      #   source = config.lib.stash.fromStash { stash = "non-existent"; path = "/vivaldi"; };
      # };

      ".config/waybar" = {
        source = {
          path = "/waybar";
          stash = "dotfiles";
          static = false;
        };
        recursive = true;
      };
    };
  };
}

