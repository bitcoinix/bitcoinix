{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/virtualisation/qemu-vm.nix") ];

  config = {
    virtualisation = {
      graphics = false;
      memorySize = 2048;
      cores = 4;
    };
    services.getty.autologinUser = "root";
    users.users.root = {
      openssh.authorizedKeys.keyFiles = [ ./id-vm.pub ];
    };
  };
}
