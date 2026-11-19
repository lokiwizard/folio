"use strict";
const answer = document.getElementById("answer");
let previousFormulas = new Map();

const inlineTokens = /\\[\*_]|\*\*|__|`+|\\\$|\$\$|\\\(|\\\[|\$(?!\s)/;
const blockTokens = /^ {0,3}\\?(#{1,6})[ \t]+([^\r\n]*)(?:\r\n?|\n|$)|^ {0,3}(`{3,}|~{3,})[^\r\n]*(?:\r\n?|\n|$)/;
const answerTokens = new RegExp(blockTokens.source + "|" + inlineTokens.source, "gm");

// Build prose and code as text nodes. Only KaTeX creates math markup.
function appendMarkdown(source, nodes, formulas, allowBlocks) {
    const tokens = allowBlocks ? new RegExp(answerTokens) : new RegExp(inlineTokens, "g");
    let target = nodes;
    let emphasis = "";
    let start = 0, match;
    while ((match = tokens.exec(source))) {
        const [, hashes, title, fence] = match;
        if (hashes) {
            target.append(source.slice(start, match.index));
            if (emphasis) nodes.append(emphasis, ...target.childNodes);
            target = nodes;
            emphasis = "";
            const heading = document.createElement("h" + hashes.length);
            appendMarkdown(title.replace(/[ \t]+#+[ \t]*$/, "").trimEnd(), heading, formulas, false);
            nodes.append(heading);
            start = tokens.lastIndex;
            continue;
        }
        if (fence) {
            const closing = new RegExp("^ {0,3}" + fence[0] + "{" + fence.length + ",}[ \\t]*(?=\\r?$)", "gm");
            closing.lastIndex = tokens.lastIndex;
            tokens.lastIndex = closing.exec(source) ? closing.lastIndex : source.length;
            const code = document.createElement("code");
            code.textContent = source.slice(match.index, tokens.lastIndex);
            target.append(source.slice(start, match.index), code);
            start = tokens.lastIndex;
            continue;
        }
        const open = match[0];
        if (open === "\\$") continue;
        if (open === "**" || open === "__") {
            if (emphasis && open !== emphasis) continue;
            target.append(source.slice(start, match.index));
            start = tokens.lastIndex;
            if (!emphasis) {
                emphasis = open;
                target = document.createElement("strong");
            } else {
                nodes.append(target);
                target = nodes;
                emphasis = "";
            }
            continue;
        }
        if (open.length === 2 && open[0] === "\\" && (open[1] === "*" || open[1] === "_")) {
            target.append(source.slice(start, match.index), open[1]);
            start = tokens.lastIndex;
            continue;
        }
        if (open.startsWith("`")) {
            target.append(source.slice(start, match.index));
            const code = document.createElement("code");
            const closeAt = source.indexOf(open, tokens.lastIndex);
            tokens.lastIndex = closeAt < 0 ? source.length : closeAt + open.length;
            code.textContent = source.slice(match.index, tokens.lastIndex);
            target.append(code);
            start = tokens.lastIndex;
            continue;
        }
        const display = open === "$$" || open === "\\[";
        const close = open === "\\[" ? "\\]" : open === "\\(" ? "\\)" : open;
        const from = tokens.lastIndex;
        let end = from;
        while ((end = source.indexOf(close, end)) !== -1) {
            let back = end;
            while (back > from && source[back - 1] === "\\") back--;
            if ((end - back) % 2 === 0) break;
            end += close.length;
        }
        if (end < 0) {
            if (open !== "$") break;
            continue;
        }
        const math = source.slice(from, end);
        if (!math.trim() || (open === "$" && (/\s$|\n/.test(math) || /\d/.test(source[end + 1] || "")))) continue;
        const literal = source.slice(match.index, end + close.length);
        let element = formulas.get(literal) || previousFormulas.get(literal);
        if (!element) {
            element = document.createElement(display ? "div" : "span");
            element.className = display ? "formula display" : "formula";
            try {
                katex.render(math, element, {displayMode: display, output: "mathml", trust: false,
                                             maxExpand: 500, maxSize: 20, throwOnError: true, strict: "ignore"});
            } catch {
                element.textContent = literal;
            }
        }
        formulas.set(literal, element);
        target.append(source.slice(start, match.index), element.cloneNode(true));
        start = tokens.lastIndex = end + close.length;
    }
    target.append(source.slice(start));
    if (emphasis) nodes.append(emphasis, ...target.childNodes);
}

function renderAnswer(source, dark) {
    document.documentElement.style.colorScheme = dark ? "dark" : "light";
    const nodes = document.createDocumentFragment();
    const formulas = new Map();
    appendMarkdown(source, nodes, formulas, true);
    previousFormulas = formulas;
    answer.replaceChildren(nodes);
}

new ResizeObserver(() => {
    window.webkit.messageHandlers.answerHeight.postMessage(Math.ceil(answer.getBoundingClientRect().height));
}).observe(answer);
