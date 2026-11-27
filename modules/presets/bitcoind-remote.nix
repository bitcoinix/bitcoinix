{ config, lib, pkgs, ... }:

let
  cfg = config.services.bitcoind;
  secretsDir = config.bitcoinix.secretsDir;
in {
  systemd.services.bitcoind = {
    # Make the local bitcoin-cli work with the remote node. bitcoin-cli takes the
    # credentials from the RPC cookie file, see ../bitcoind.nix. No local bitcoind
    # writes that file, so write the remote node's credentials there.
    # A cookie file holds `<user>:<password>`.
    preStart = lib.mkAfter ''
      # An assignment fails the script when the secret is missing
      password=$(< '${secretsDir}/bitcoin-rpcpassword-privileged')
      install -T -m 640 <(
        printf '%s:%s\n' ${lib.escapeShellArg cfg.rpc.users.privileged.name} "$password"
      ) /run/bitcoind/.cookie
    '';
    serviceConfig = {
      Type = lib.mkForce "oneshot";
      ExecStart = lib.mkForce "${pkgs.coreutils}/bin/true";
      RemainAfterExit = true;
      # Keep the cookie file when the unit stops. bitcoin-cli still works then,
      # because the remote node keeps running.
      RuntimeDirectoryPreserve = true;
    };
  };
}
