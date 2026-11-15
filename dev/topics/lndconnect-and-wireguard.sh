#―――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
# Test Tor and WireGuard connections on a mobile device

# 1. Run container
run-tests.sh -s wireguard-lndconnect-online container

# 2. Test connecting via Tor
# Print QR codes for lnd and clnrest connections via Tor
c lndconnect
c lnconnect-clnrest
# Add these to Zeus >= 0.9.0.
# To explicitly check if the connection is successful, press the node logo in the top
# left corner, and then "Node Info".

# Debug
c lndconnect --url
c lnconnect-clnrest --url

# 3. Test connecting via WireGuard

# 3.1 Forward WireGuard port from the container host to the container
iptables -t nat -A PREROUTING -p udp --dport 51821 -j DNAT --to-destination 10.225.255.2

# 3.2. Optional: When your container host has an external firewall,
# forward the WireGuard port to the container host:
# - Port: 51821
# - Protocol: UDP
# - Destination: IPv4 of the container host

# 3.2 Print QR code and setup wireguard on the mobile device.
# Set `host` to the IPv4 of the container host that your mobile device reaches.
host=192.168.1.10
c nix-bitcoin-wg-connect "$host"
c nix-bitcoin-wg-connect --text "$host"

# Print QR codes for lnd and clnrest connections via WireGuard
c lndconnect-wg
c lnconnect-clnrest-wg
# Add these to Zeus >= 0.9.0.
# To explicitly check if the connection is successful, press the menu button in the top
# left corner, and then "Node Info".

# Debug
c lndconnect-wg --url
c lnconnect-clnrest-wg --url

# 3.3.remove external firewall port forward, remove local port forward:
iptables -t nat -D PREROUTING -p udp --dport 51821 -j DNAT --to-destination 10.225.255.2
# Now exit the container shell

#―――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
# Debug lndconnect

run-tests.sh -s wireguard-lndconnect-online container

c nodeinfo

c lndconnect --url
c lndconnect-wg --url
c lnconnect-clnrest --url
c lnconnect-clnrest-wg --url

c lndconnect
c lndconnect-wg
c lnconnect-clnrest
c lnconnect-clnrest-wg
