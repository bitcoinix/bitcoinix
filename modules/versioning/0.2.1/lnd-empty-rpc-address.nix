{ config, ... }:

let
  inherit (config.services) lnd;
in {
  condition = lnd.enable && builtins.elem lnd.rpcAddress [ "" "[]" ];
  message = ''
    An empty LND RPC host now fails evaluation. Remove `services.lnd.rpcAddress`
    to use loopback (`127.0.0.1`). Set it to `::` to keep the previous IPv6-only
    wildcard listener, or `0.0.0.0` for an IPv4-only wildcard listener.
    If you supply the TLS certificate, include the chosen IP address in its
    subject alternative names so local gRPC clients can verify it.
  '';
}
