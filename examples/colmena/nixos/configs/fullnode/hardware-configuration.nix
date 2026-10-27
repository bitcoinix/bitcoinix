{
  config,
  lib,
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot = {
    initrd = {
      availableKernelModules = [
        "ahci"
        "xhci_pci"
        "virtio_pci"
        "sr_mod"
        "virtio_blk"
      ];
      kernelModules = [ "kvm-amd" ];
    };
    kernelModules = [ ];
    extraModulePackages = [ ];
    kernelParams = [
      # Force 'none' I/O scheduler for virtio block devices. Reduces CPU
      # overhead and latency for SSD-backed VMs, crucial for Bitcoin's LevelDB.
      "elevator=none"
    ];

    loader.grub = {
      enable = true;
      device = "/dev/vda";
    };
  };

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-uuid/d40722bb-26bb-4d04-b4ee-da5bb8e043a8";
      fsType = "ext4";
      options = [ "noatime" ];
    };

    "/mnt/data" = {
      device = "/dev/vdb";
      fsType = "ext4";

      # Disable access timestamp updates on file reads ('noatime'). Eliminates
      # unnecessary disk write overhead during heavy read operations on the
      # Bitcoin LevelDB (chainstate), improving I/O performance and reducing
      # SSD wear.
      options = [ "noatime" ];
    };
  };

  swapDevices = [ ];
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
