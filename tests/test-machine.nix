{ config, ... }:
{
  fileSystems."/".device = "/dev/null";
  boot.loader.grub.device = "/dev/null";
  users.users.vico = {
    isNormalUser = true;
    home = "/home/vico";
  };

  stash.users.vico = {
    stashes = {
      wallpapers = {
        path = "Pictures/wallpapers";
      };
    };

    files = {
      "static.txt".text = ''
        ASASLHFASHF
      '';

      "data/tests" = {
        source = ./.;
        recursive = true;
      };

      "wallpaper.png" = {
        source = {
          path = "/sky.png";
          stash = "wallpapers";
          static = false;
        };
        recursive = true;
      };
    };
  };
}
