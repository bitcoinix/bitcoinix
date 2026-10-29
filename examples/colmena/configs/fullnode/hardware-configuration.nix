# FIXME: Placeholder. Replace this file with the hardware-configuration.nix
# that `nixos-generate-config` writes on your node. It depends entirely on
# your hardware (boot loader, disks, kernel modules), e.g. a Raspberry Pi 4,
# an old laptop or a VM.
{
  boot.loader.grub.device = "/dev/sda";

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
    };

    # Extra disk for the bitcoind and fulcrum data, see configuration.nix
    "/mnt/data" = {
      device = "/dev/disk/by-label/data";
      fsType = "ext4";
      # No access time updates: fewer disk writes while bitcoind reads its
      # chainstate
      options = [ "noatime" ];
    };
  };
}
