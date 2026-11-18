{ config, ... }:

{
  condition = config.services.btcpayserver.enable;
  message = ''
    When BTCPay Server has no admin, bitcoinix now creates the admin account
    `admin@localhost` before BTCPay Server opens its port. Its password is in
    the new secret `btcpayserver-admin-password`. Before, the first account
    that registered became the admin, so any local user could take it until
    you registered. If your BTCPay Server already has an admin, bitcoinix
    keeps it. Check in Server Settings > Users that each admin is yours. If one
    isn't, treat the node as compromised. If you supply your secrets yourself,
    add the new secret before you deploy.
  '';
}
