{ config, lib, pkgs, ... }:

let
  cfg = config.services.bitcoind;
  secretsDir = config.nix-bitcoin.secretsDir;
in {
  systemd.services.bitcoind = {
    # Make the local bitcoin-cli work with the remote node.
    # Without this, bitcoin-cli would try to use the local RPC cookie for
    # authorization, which doesn't exist.
    preStart = lib.mkAfter ''
      printf '%s\n' ${lib.escapeShellArg "rpcuser=${cfg.rpc.users.privileged.name}"} >> '${cfg.dataDir}/bitcoin.conf'
      echo "rpcpassword=$(cat ${secretsDir}/bitcoin-rpcpassword-privileged)" >> '${cfg.dataDir}/bitcoin.conf'
    '';
    serviceConfig = {
      Type = lib.mkForce "oneshot";
      ExecStart = lib.mkForce "${pkgs.coreutils}/bin/true";
      RemainAfterExit = true;
    };
  };
}
