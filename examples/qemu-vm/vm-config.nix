{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/virtualisation/qemu-vm.nix") ];

  config = {
    virtualisation.graphics = false;
    services.getty.autologinUser = "root";
    users.users.root = {
      openssh.authorizedKeys.keyFiles = [ ./id-vm.pub ];
    };
  };
}
