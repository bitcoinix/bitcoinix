# VM specific configuration, should be included by all NixOS-based VMs
{
  services.qemuGuest.enable = true;

  # Enable serial console access via 'virsh console' (ttyS0) while keeping the
  # standard graphical/VNC console output (tty0).
  #
  # Order matters: the LAST console specified becomes /dev/console.
  # By putting ttyS0 last, systemd boot logs will stream to 'virsh console'.
  #
  # See: https://gitlab.com/seberms/nixos-configs/-/work_items/39
  boot.kernelParams = [
    "console=ttyS0,115200"
    "console=tty0"
  ];
}
