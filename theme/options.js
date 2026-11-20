// Filter for the option list of options.md, which helper/docs/options.nix renders
// as one `opt-` heading per option. Without JavaScript the full list stays visible.
(() => {
    "use strict";

    const headings = Array.from(document.querySelectorAll("main h2[id^='opt-']"));
    if (headings.length === 0) return;

    const list = document.createElement("div");
    list.id = "nb-option-list";
    headings[0].before(list);

    const isEnd = (node) => /^H[12]$/.test(node.nodeName)
        || (node.nodeType === Node.COMMENT_NODE && node.data.trim() === "bitcoinix-options-end");

    // Group each heading with the content that follows it, up to the next heading
    const options = headings.map((heading) => {
        const section = document.createElement("section");
        section.className = "nb-option";
        let node = heading.nextSibling;
        section.append(heading);
        while (node && !isEnd(node)) {
            const next = node.nextSibling;
            section.append(node);
            node = next;
        }
        list.append(section);
        return {
            section,
            name: heading.textContent.toLowerCase(),
            text: section.textContent.toLowerCase(),
        };
    });

    const input = document.createElement("input");
    input.type = "search";
    input.id = "nb-option-filter";
    input.placeholder = "Filter options, e.g. clightning port";
    input.autocomplete = "off";
    input.spellcheck = false;
    input.setAttribute("aria-label", "Filter options");
    const count = document.createElement("p");
    count.id = "nb-option-count";
    count.setAttribute("aria-live", "polite");
    list.before(input, count);

    // `?filter=` keeps a filter in links; mdBook itself uses `?search=`
    const param = "filter";

    function apply() {
        const terms = input.value.toLowerCase().split(/\s+/).filter(Boolean);
        // Options whose name contains every term come first, in their original order
        const byName = [];
        const byText = [];
        for (const option of options) {
            if (terms.every((term) => option.name.includes(term))) {
                byName.push(option);
            } else if (terms.every((term) => option.text.includes(term))) {
                byText.push(option);
            } else {
                option.section.hidden = true;
            }
        }
        for (const option of byName.concat(byText)) {
            option.section.hidden = false;
            list.append(option.section);
        }
        const shown = byName.length + byText.length;
        count.textContent = terms.length === 0
            ? `${options.length} options`
            : `${shown} of ${options.length} options`;
    }

    input.addEventListener("input", () => {
        apply();
        const url = new URL(window.location.href);
        if (input.value.trim()) {
            url.searchParams.set(param, input.value);
        } else {
            url.searchParams.delete(param);
        }
        url.hash = "";
        window.history.replaceState(null, "", url);
    });

    // A link to a single option shows the whole list, so the option stays in context
    if (window.location.hash) {
        apply();
        // The filter above the list moved the option down
        try {
            document.getElementById(decodeURIComponent(window.location.hash.slice(1)))?.scrollIntoView();
        } catch {
            // A malformed hash is not an option
        }
    } else {
        input.value = new URLSearchParams(window.location.search).get(param) ?? "";
        apply();
    }
})();
