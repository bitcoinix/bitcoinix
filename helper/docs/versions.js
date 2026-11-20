// Version selector for docs.bitcoinix.net, added to every page by build.py.
// The latest release is served at `/` and each release at `/v/<version>/`.
(() => {
    "use strict";

    const versionPattern = /^\d+\.\d+\.\d+$/;
    const match = window.location.pathname.match(/^\/v\/(\d+\.\d+\.\d+)\/(.*)$/);
    // The page path relative to the root of its version
    const page = match ? match[2] : window.location.pathname.replace(/^\//, "");

    function versionRoot(version, latest) {
        return version === latest ? "/" : `/v/${version}/`;
    }

    async function exists(url) {
        try {
            return (await fetch(url, { method: "HEAD" })).ok;
        } catch {
            return false;
        }
    }

    function addStyle() {
        const style = document.createElement("style");
        style.textContent = `
            #nb-version-select { margin: auto 8px; font: inherit; color: var(--icons);
                background: var(--bg); border: 1px solid var(--searchbar-border-color);
                border-radius: 4px; }
            #nb-version-banner { margin: 16px 0; padding: 8px 12px;
                border: 1px solid var(--warning-border, #f0b37e); border-radius: 4px; }
        `;
        document.head.append(style);
    }

    function addSelector(versions, latest, current) {
        const bar = document.querySelector("#mdbook-menu-bar .right-buttons");
        if (!bar) return;
        const select = document.createElement("select");
        select.id = "nb-version-select";
        select.title = "Documentation version";
        select.setAttribute("aria-label", "Documentation version");
        for (const version of versions) {
            const option = document.createElement("option");
            option.value = version;
            option.textContent = version === latest ? `v${version} (latest)` : `v${version}`;
            option.selected = version === current;
            select.append(option);
        }
        select.addEventListener("change", async () => {
            const version = select.value;
            const root = versionRoot(version, latest);
            // Releases differ in their pages, so fall back to the start page of the release
            window.location.href = page && await exists(root + page) ? root + page : root;
        });
        bar.prepend(select);
    }

    function addBanner(latest, current) {
        const main = document.querySelector("main");
        if (!main) return;
        const banner = document.createElement("p");
        banner.id = "nb-version-banner";
        const link = document.createElement("a");
        link.href = "/";
        link.textContent = `latest release, v${latest}`;
        banner.append(`This is the documentation of bitcoinix v${current}. See the `, link, ".");
        main.prepend(banner);
    }

    async function init() {
        let data;
        try {
            const response = await fetch("/versions.json");
            if (!response.ok) return;
            data = await response.json();
        } catch {
            return;
        }
        const { latest, versions } = data ?? {};
        if (typeof latest !== "string" || !versionPattern.test(latest)
            || !Array.isArray(versions) || !versions.includes(latest)
            || !versions.every((version) => typeof version === "string" && versionPattern.test(version))) {
            return;
        }
        const current = match ? match[1] : latest;
        addStyle();
        addSelector(versions, latest, current);
        if (current !== latest) {
            addBanner(latest, current);
        }
    }

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", init);
    } else {
        init();
    }
})();
