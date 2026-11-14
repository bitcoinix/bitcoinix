{ config, ... }:

{
  condition = config.nix-bitcoin ? secure-node-preset-enabled &&
              config.nix-bitcoin.secretsDir == "/etc/nix-bitcoin-secrets";
  message = ''
    The `secure-node.nix` preset does not set the secrets directory
    to "/secrets" anymore.
    Instead, the default location "/etc/nix-bitcoin-secrets" is used.

    To upgrade, choose one of the following:

    - Continue using "/secrets":
      Add `nix-bitcoin.secretsDir = "/secrets";` to your configuration.nix.

    - Move your secrets to the default location:
      Run the following command as root on your node:
      `rsync -a /secrets/ /etc/nix-bitcoin-secrets`.
      You can delete the old "/secrets" directory after deploying the new system
      config to your node.
  '';
}
