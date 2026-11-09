const content = document.querySelector('#content');

window.showAnswer = (source) => {
    const formulas = [];
    const prefix = 'MATH' + Math.random().toString(36).slice(2) + 'X';
    const math = /(\x60{3}[^\n]*\n[\s\S]*?(?:\x60{3}|$)|\x60[^\x60\n]+\x60)|(\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]|\\\(([^\n]+?)\\\)|\$(?!\s)([^$\n]+?)\$|\\begin\{(align\*?|equation\*?|gather\*?)\}[\s\S]+?\\end\{\7\})/g;
    const normalized = source.replace(/^([ \t]*\{[ \t]*\n)([^{}\n]*(?:\\(?:frac|sqrt|sum|int|alpha|beta)\b)[^\n]*)\n[ \t]*\}[ \t]*$/gm, (_, open, tex) => "\n$$" + tex + "$$\n");
    const markdown = normalized.replace(math, (match, code, raw, dollars, brackets, parens, inline, environment, offset) => {
        if (!code && normalized[offset - 1] === "\\") return match;
        if (code) {
            const tex = /^\x60{3}(?:latex|tex|math)\s*\n([\s\S]*?)\x60{3}$/i.exec(code);
            if (!tex) return code;
            formulas.push({ tex: tex[1], displayMode: true });
        } else {
            formulas.push({
                tex: dollars ?? brackets ?? parens ?? inline ?? raw,
                displayMode: dollars !== undefined || brackets !== undefined || environment !== undefined
            });
        }
        return prefix + (formulas.length - 1) + 'Z';
    });
    content.innerHTML = DOMPurify.sanitize(marked.parse(markdown), {
        USE_PROFILES: { html: true },
        FORBID_TAGS: ['img', 'style', 'form', 'input', 'button'],
        FORBID_ATTR: ['style', 'id', 'name']
    });
    const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    const placeholder = new RegExp(prefix + '([0-9]+)Z', 'g');
    for (const node of nodes) {
        const text = node.textContent;
        if (!text.includes(prefix)) continue;
        const fragment = document.createDocumentFragment();
        let offset = 0;
        for (const match of text.matchAll(placeholder)) {
            fragment.append(text.slice(offset, match.index));
            const formula = formulas[Number(match[1])];
            const span = document.createElement('span');
            try {
                katex.render(formula.tex, span, { displayMode: formula.displayMode, trust: false, maxExpand: 1000, maxSize: 12 });
            } catch {
                span.textContent = '（公式格式有误）';
            }
            fragment.append(span);
            offset = match.index + match[0].length;
        }
        fragment.append(text.slice(offset));
        node.replaceWith(fragment);
    }
};

new ResizeObserver(() => {
    window.webkit.messageHandlers.answerHeight.postMessage(Math.ceil(content.getBoundingClientRect().height));
}).observe(content);
