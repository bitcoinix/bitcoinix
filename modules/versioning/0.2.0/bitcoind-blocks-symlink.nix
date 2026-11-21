{ config, ... }:

let
  inherit (config.services) bitcoind;
in
{
  # On regtest, the old preStart didn't find the blocks dir and changed nothing
  condition = bitcoind.enable && bitcoind.dataDirReadableByGroup && bitcoind.network == "mainnet";
  message = ''
    With `services.bitcoind.dataDirReadableByGroup`, bitcoind no longer changes the
    permissions of a blocks dir that is a symlink, because members of group
    `${bitcoind.group}` could plant one. If your blocks dir is a symlink, the group
    can't read new block files. Replace the symlink with a dir or a bind mount.
  '';
}
