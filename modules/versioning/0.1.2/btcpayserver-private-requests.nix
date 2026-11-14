{ config, ... }:

{
  condition = config.services.btcpayserver.enable;
  message = ''
    BTCPay Server 2.4.5 blocks webhooks, invoice notification URLs and LNURL
    requests to private network addresses (localhost, LAN, VPN) by default.
    The Lightning node configured by bitcoinix is unaffected. To allow private
    destinations, set
    `systemd.services.btcpayserver.environment.BTCPAY_SSRFEXCEPTIONS`,
    e.g. to "192.168.1.50:8443;10.8.0.0/24". Keep exceptions narrow and never
    list the ports of node services such as the lnd REST API.
  '';
}
