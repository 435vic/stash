{
  imports = [
    ../modules
  ];

  fileSystems."/".device = "/dev/null";
  boot.loader.grub.device = "/dev/null";
  users.users.vico = {
    isNormalUser = true;
    home = "/home/vico";
    uid = 1000;
  };

  stash.users.vico = {
    stashes = {
      dotfiles = {
        path = "vicOS/config";
      };
    };

    files = {
      ".config/static" = {
        text = ''
          ASASLHFASHF
        '';
      };

      ".config/nvim" = {
        source = ../lib;
        recursive = true;
      };

      ".config/waybar" = {
        stash.source = "dotfiles/waybar";
        recursive = true;
      };
    };
  };
}

