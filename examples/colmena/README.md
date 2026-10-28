# Example Deployment via Colmena

This example uses [`colmena`](https://github.com/nix-community/colmena) as its
deployment tool. The Colmena manual can be found
[here](https://colmena.cli.rs/unstable/).

Note that there is **no need to set all the options** in the `nixos/common.nix`
or `nixos/fullnode/{hardware-,}configuration.nix` modules. I cleaned up the
code but kept the options that could be interesting to other users.

In any case, it will be necessary to review the entire configuration and adjust
it according to your requirements, preferences, target environment, and
hardware.


## Basic Steps & Hints

**Enter the Nix environment**: Enable direnv (`direnv allow`) or run:

```shell
nix develop
```

Build and deploy the `fullnode` Colmena host configuration to the target node,
and apply it **after boot**. In some cases, you can also switch the
configuration directly by replacing the `boot` action with `switch`:

```shell
colmena apply --verbose --on "fullnode" boot
....
ssh fullnode.example.com
reboot
```
