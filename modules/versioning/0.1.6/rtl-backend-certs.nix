{ config, ... }:

{
  condition = config.services.rtl.enable;
  message = ''
    RTL now checks TLS certificates. A connection to lnd or clnrest must present
    the backend's pinned certificate (services.lnd.certPath, or server.pem in
    clnrest's cert dir). Other HTTPS connections get the normal checks against the
    system CAs. RTL doesn't start with LN_SERVER_URL or LND_SERVER_URL set, and
    evaluation fails when a node's extraConfig changes Settings.lnServerUrl. A proxy
    without no_proxy for the backend address and self-signed servers set through
    extraConfig no longer work. For such a server, add its certificate with
    NODE_EXTRA_CA_CERTS in RTL's environment.
  '';
}
