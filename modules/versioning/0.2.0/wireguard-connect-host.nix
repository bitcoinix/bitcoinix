{ options, ... }:

{
  # Only the WireGuard preset declares these options.
  condition = options ? bitcoinix.wireguard;
  message = ''
    `nix-bitcoin-wg-connect` from the WireGuard preset now needs the node's
    address as an argument. Before, it looked up the node's public IP through
    public IP lookup services over clearnet when you passed no address. Without
    an address, it now fails. Pass your node's public IP or hostname, for
    example `nix-bitcoin-wg-connect 93.184.216.34`. Existing WireGuard clients
    keep working.
  '';
}
