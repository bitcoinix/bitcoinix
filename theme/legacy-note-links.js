// Bookmarks from the single-page release and upgrade guides through v0.1.6.
(() => {
    const legacy = {
        "upgrading": {
            "upgrading-to-config-version-016": "0.1.6.html",
            "operator-access-to-lightning-onion-addresses": "0.1.6.html#operator-access-to-lightning-onion-addresses",
            "onion-address-access-requires-declared-users": "0.1.6.html#onion-address-access-requires-declared-users",
            "secret-file-validation": "0.1.6.html#secret-file-validation",
            "lnd-seed-validation-and-wallet-creation": "0.1.6.html#lnd-seed-validation-and-wallet-creation",
            "separate-root-keys-for-custom-lnd-macaroons": "0.1.6.html#separate-root-keys-for-custom-lnd-macaroons",
            "custom-lnd-macaroon-file-permissions": "0.1.6.html#custom-lnd-macaroon-file-permissions",
            "rtl-stops-with-its-backends": "0.1.6.html#rtl-stops-with-its-backends",
            "rtl-verifies-its-backends-certificates": "0.1.6.html#rtl-verifies-its-backends-certificates",
            "rtl-two-factor-authentication-persists-across-restarts": "0.1.6.html#rtl-two-factor-authentication-persists-across-restarts",
            "tor-enforcement-allows-only-local-addresses": "0.1.6.html#tor-enforcement-allows-only-local-addresses",
            "upgrading-to-config-version-015": "0.1.5.html",
            "currencyrate-plugin-replacement": "0.1.5.html#currencyrate-plugin-replacement",
            "rebalance-routing-changes": "0.1.5.html#rebalance-routing-changes",
            "mempool-rpc-password-moves-to-the-secrets-directory": "0.1.5.html#mempool-rpc-password-moves-to-the-secrets-directory",
            "upgrading-to-config-version-013": "0.1.3.html",
            "bitcoin-knots-support-removed": "0.1.3.html#bitcoin-knots-support-removed",
            "electrs-index-rebuild": "0.1.3.html#electrs-index-rebuild",
            "electrs-requires-bitcoin-core-rest-access": "0.1.3.html#electrs-requires-bitcoin-core-rest-access",
            "service-runtime-paths-become-read-only": "0.1.3.html#service-runtime-paths-become-read-only",
            "mempool-database-migration": "0.1.3.html#mempool-database-migration",
            "secret-setup-sandbox": "0.1.3.html#secret-setup-sandbox",
            "upgrading-to-config-version-012": "0.1.2.html",
            "bitcoin-core-rpc-cookie-location": "0.1.2.html#bitcoin-core-rpc-cookie-location",
            "mempool-backend-listen-address": "0.1.2.html#mempool-backend-listen-address",
            "mariadb-listens-on-localhost-by-default": "0.1.2.html#mariadb-listens-on-localhost-by-default",
            "lnd-restarts-after-a-clean-exit": "0.1.2.html#lnd-restarts-after-a-clean-exit",
            "btcpay-server-restricts-requests-to-private-networks": "0.1.2.html#btcpay-server-restricts-requests-to-private-networks",
            "upgrading-to-config-version-011": "0.1.1.html",
            "liquid-support-removed": "0.1.1.html#liquid-support-removed",
            "netns-exec-wrapper-removed": "0.1.1.html#netns-exec-wrapper-removed",
            "lightning-pool-and-lightning-loop-support-removed": "0.1.1.html#lightning-pool-and-lightning-loop-support-removed",
            "btcpay-server-wallet-utxo-scanning-disabled-by-default": "0.1.1.html#btcpay-server-wallet-utxo-scanning-disabled-by-default",
            "charge-lnd-macaroon-permissions-restricted": "0.1.1.html#charge-lnd-macaroon-permissions-restricted",
            "lnconnect-clnrest-server-certificate-corrected": "0.1.1.html#lnconnect-clnrest-server-certificate-corrected",
            "c-lightning-rest-replaced-by-clnrest": "0.1.1.html#c-lightning-rest-replaced-by-clnrest",
            "upgrading-to-config-version-010": "0.1.0.html",
            "lightning-rest-apis-listen-on-localhost-by-default": "0.1.0.html#lightning-rest-apis-listen-on-localhost-by-default",
        },
        "release-notes": {
            "016": "0.1.6.html",
            "tor-enforcement-allows-only-local-addresses": "0.1.6.html#tor-enforcement-allows-only-local-addresses",
            "unbeholden-wallet-service": "0.1.6.html#unbeholden-wallet-service",
            "rtl-package-moves-to-nixpkgs": "0.1.6.html#rtl-package-moves-to-nixpkgs",
            "trustedcoin-package-moves-to-nixpkgs": "0.1.6.html#trustedcoin-package-moves-to-nixpkgs",
            "trezor-uses-the-unmodified-nixpkgs-unstable-package": "0.1.6.html#trezor-uses-the-unmodified-nixpkgs-unstable-package",
            "lightning-python-packages-move-to-nixpkgs-unstable": "0.1.6.html#lightning-python-packages-move-to-nixpkgs-unstable",
            "secret-validation-and-lnd-wallet-creation": "0.1.6.html#secret-validation-and-lnd-wallet-creation",
            "separate-root-keys-for-custom-lnd-macaroons": "0.1.6.html#separate-root-keys-for-custom-lnd-macaroons",
            "custom-lnd-macaroon-file-permissions": "0.1.6.html#custom-lnd-macaroon-file-permissions",
            "rtl-stops-with-its-backends": "0.1.6.html#rtl-stops-with-its-backends",
            "rtl-verifies-its-backends-certificates": "0.1.6.html#rtl-verifies-its-backends-certificates",
            "rtl-two-factor-authentication-persists-across-restarts": "0.1.6.html#rtl-two-factor-authentication-persists-across-restarts",
            "onion-address-access-for-the-operator-and-declared-users": "0.1.6.html#onion-address-access-for-the-operator-and-declared-users",
            "backups-fail-when-a-database-dump-fails": "0.1.6.html#backups-fail-when-a-database-dump-fails",
            "netns-isolation-no-masquerading-within-the-bridge-mptcp-setting": "0.1.6.html#netns-isolation-no-masquerading-within-the-bridge-mptcp-setting",
            "root-scripts-ignore-config-files-in-a-service-users-home": "0.1.6.html#root-scripts-ignore-config-files-in-a-service-users-home",
            "wireguard-preset-checks-the-firewall-setup": "0.1.6.html#wireguard-preset-checks-the-firewall-setup",
            "lnd-announces-its-onion-address-with-the-port-tor-forwards": "0.1.6.html#lnd-announces-its-onion-address-with-the-port-tor-forwards",
            "clnrest-regenerates-a-broken-admin-rune": "0.1.6.html#clnrest-regenerates-a-broken-admin-rune",
            "btcpayserver-with-a-custom-clightning-group": "0.1.6.html#btcpayserver-with-a-custom-clightning-group",
            "nodeinfo-shows-the-bitcoinix-revision-and-service-versions": "0.1.6.html#nodeinfo-shows-the-bitcoinix-revision-and-service-versions",
            "extra-container-101": "0.1.6.html#extra-container-101",
            "package-updates": "0.1.6.html#package-updates",
            "015": "0.1.5.html",
            "clnrest-package-attribute-renamed": "0.1.5.html#clnrest-package-attribute-renamed",
        },
    };

    function redirectLegacyNote() {
        const section = window.location.pathname.match(/\/(upgrading|release-notes)\.html$/)?.[1];
        if (!section) return;

        const anchor = window.location.hash.slice(1);
        if (Object.hasOwn(legacy[section], anchor)) {
            window.location.replace(section + "/" + legacy[section][anchor]);
        }
    }

    redirectLegacyNote();
    window.addEventListener("hashchange", redirectLegacyNote);
})();
