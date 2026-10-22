/* Floating AI's offline Markdown/math renderer. All message content is untrusted. */
(() => {
  "use strict";

  const LIMITS = Object.freeze({ message: 128000, formula: 8192, formulas: 200, totalMath: 65536, height: 100000 });
  const escapeHTML = value => String(value).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const escapedAt = (text, offset) => {
    let backslashes = 0;
    while (offset > 0 && text[--offset] === "\\") backslashes++;
    return backslashes % 2 === 1;
  };

  // Tokenize before Markdown consumes backslash escapes. Marked handles fenced and
  // inline code first at their opening delimiter, so their contents never reach here.
  function scanMath(source, blockOnly = false) {
    let open, close, display;
    if (source.startsWith("$$")) { open = close = "$$"; display = true; }
    else if (source.startsWith("\\[")) { open = "\\["; close = "\\]"; display = true; }
    else if (!blockOnly && source.startsWith("\\(")) { open = "\\("; close = "\\)"; display = false; }
    else if (!blockOnly && source[0] === "$" && source[1] && !/[\s$]/.test(source[1])) {
      open = close = "$"; display = false;
    } else return undefined;

    const singleDollar = open === "$";
    const maximum = Math.min(source.length, LIMITS.formula + open.length + close.length);
    let offset = open.length;
    while (offset < maximum) {
      const end = source.indexOf(close, offset);
      if (end < 0 || end >= maximum || (singleDollar && source.slice(open.length, end).includes("\n"))) break;
      if (escapedAt(source, end)) {
        offset = end + close.length;
        continue;
      }
      // Do not search past a currency-like dollar into a later actual formula.
      if (singleDollar && (/\s/.test(source[end - 1]) || /[\d$]/.test(source[end + 1] || ""))) return undefined;
      const raw = source.slice(0, end + close.length);
      return { raw, text: source.slice(open.length, end), display, complete: true };
    }

    // A lone dollar before a number is usually currency. A likely unfinished
    // formula stays literal so Markdown cannot turn its underscores into emphasis.
    if (singleDollar && !/[A-Za-z\\]/.test(source[1] || "")) return undefined;
    const end = blockOnly || display ? source.length : (source.indexOf("\n") < 0 ? source.length : source.indexOf("\n"));
    return { raw: source.slice(0, end), text: source.slice(0, end), display, complete: false };
  }

  let slots = [];
  let mathCharacters = 0;
  function mathPlaceholder(token) {
    const index = slots.length;
    if (index >= LIMITS.formulas || mathCharacters + token.text.length > LIMITS.totalMath) {
      return `<span class="math-source">${escapeHTML(token.raw)}</span>`;
    }
    mathCharacters += token.text.length;
    slots.push(token);
    return `<span data-math="${index}">${escapeHTML(token.raw)}</span>`;
  }

  const parser = new marked.Marked({
    gfm: true,
    breaks: true,
    renderer: {
      html(token) { return escapeHTML(token.text); },
      image(token) { return escapeHTML(token.text || "[image]"); },
      code(token) { return `<pre><code>${escapeHTML(token.text)}</code></pre>`; },
      link(token) {
        const label = this.parser.parseInline(token.tokens);
        try {
          const url = new URL(token.href);
          if (url.protocol === "https:" || url.protocol === "http:") {
            return `<a href="${escapeHTML(url.href)}" rel="noreferrer noopener">${label}</a>`;
          }
        } catch (_) { /* Unsupported or relative destinations become plain text. */ }
        return label;
      }
    },
    extensions: [
      {
        name: "floatingMathBlock", level: "block",
        start(source) { const match = /(?:^|\n)[ ]{0,3}(?:\$\$|\\\[)/.exec(source); return match ? match.index : undefined; },
        tokenizer(source) {
          const indent = /^[ ]{0,3}/.exec(source)[0];
          const math = scanMath(source.slice(indent.length), true);
          return math ? { type: "floatingMathBlock", ...math, raw: indent + math.raw } : undefined;
        },
        renderer: mathPlaceholder
      },
      {
        name: "floatingMathInline", level: "inline",
        start(source) { const match = /\$|\\[\[(]/.exec(source); return match ? match.index : undefined; },
        tokenizer(source) {
          const math = scanMath(source);
          return math ? { type: "floatingMathInline", ...math } : undefined;
        },
        renderer: mathPlaceholder
      }
    ]
  });

  function prepareMarkdown(text) {
    slots = [];
    mathCharacters = 0;
    const html = parser.parse(text);
    return { html, slots: slots.slice() };
  }

  // Pure parsing helpers are also usable by the repository's offline Node checks.
  if (typeof document === "undefined") {
    if (typeof module !== "undefined") module.exports = { scanMath, prepareMarkdown, LIMITS };
    return;
  }

  const content = document.getElementById("content");
  let revision = 0;
  let scheduled = false;
  function reportLayout() {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => {
      scheduled = false;
      // Native rejects extreme heights and shows the complete source instead.
      const height = Math.max(1, Math.ceil(content.getBoundingClientRect().height + 2));
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.layout;
      if (handler) handler.postMessage({ height, revision });
    });
  }

  function copyText(text, button) {
    const previousFocus = document.activeElement;
    const selection = window.getSelection();
    const ranges = selection ? Array.from({ length: selection.rangeCount }, (_, i) => selection.getRangeAt(i).cloneRange()) : [];
    const textarea = document.createElement("textarea");
    textarea.value = text;
    textarea.readOnly = true;
    textarea.style.cssText = "position:fixed;left:-10000px;top:0;opacity:0";
    document.body.appendChild(textarea);
    textarea.select();
    let copied = false;
    try { copied = document.execCommand("copy"); } catch (_) { /* The full-message native copy action remains available. */ }
    textarea.remove();
    if (previousFocus && typeof previousFocus.focus === "function") previousFocus.focus({ preventScroll: true });
    if (selection) { selection.removeAllRanges(); ranges.forEach(range => selection.addRange(range)); }
    const label = button.textContent;
    button.textContent = copied ? "Copied" : "Select and copy";
    window.setTimeout(() => { if (button.isConnected) button.textContent = label; }, 1200);
  }

  function copyButton(label, className, source) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = className;
    button.textContent = label;
    button.setAttribute("aria-label", label);
    button.addEventListener("click", () => copyText(source, button));
    return button;
  }

  // Browser selection normally copies both the visual glyphs and hidden MathML.
  // Replace selected formulas with their original delimiters/LaTeX instead.
  document.addEventListener("copy", event => {
    if (document.activeElement && /^(TEXTAREA|INPUT)$/.test(document.activeElement.tagName)) return;
    const selection = window.getSelection();
    if (!selection || !selection.rangeCount || !event.clipboardData) return;
    const original = selection.getRangeAt(0);
    if (!content.contains(original.commonAncestorContainer)) return;
    const mathNodes = Array.from(content.querySelectorAll(".math-inline, .math-display"));
    if (!mathNodes.some(node => original.intersectsNode(node))) return;
    const range = original.cloneRange();
    const formulaAt = node => (node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement)?.closest(".math-inline, .math-display");
    const first = formulaAt(range.startContainer), last = formulaAt(range.endContainer);
    if (first) range.setStartBefore(first);
    if (last) range.setEndAfter(last);
    const fragment = range.cloneContents();
    fragment.querySelectorAll(".math-inline, .math-display").forEach(node => node.replaceWith(document.createTextNode(node.dataset.latex || node.textContent)));
    fragment.querySelectorAll("button").forEach(node => node.remove());
    const plainText = node => {
      if (node.nodeType === Node.TEXT_NODE) return node.textContent;
      if (node.nodeName === "BR") return "\n";
      const text = Array.from(node.childNodes, plainText).join("");
      return /^(P|PRE|LI|BLOCKQUOTE|H[1-6]|TR)$/.test(node.nodeName) ? text + "\n" : text;
    };
    event.clipboardData.setData("text/plain", plainText(fragment));
    event.preventDefault();
  });

  function renderMath(node, token) {
    node.removeAttribute("data-math");
    node.className = token.display ? "math-display" : "math-inline";
    node.dataset.latex = token.raw;
    if (!token.complete || token.text.length > LIMITS.formula) {
      node.classList.add("math-source");
      node.textContent = token.raw;
      return;
    }
    const target = document.createElement("span");
    target.className = token.display ? "math-scroll" : "math-content";
    try {
      katex.render(token.text, target, {
        displayMode: token.display, output: "htmlAndMathml", throwOnError: true,
        trust: false, strict: "ignore", maxExpand: 200, maxSize: 20,
        macros: Object.create(null), globalGroup: false
      });
      node.replaceChildren(target);
      if (token.display) node.appendChild(copyButton("Copy LaTeX", "copy-math", token.raw));
    } catch (_) {
      node.classList.add("math-source");
      node.textContent = token.raw;
    }
  }

  window.setAppearance = function (darkMode) {
    document.body.dataset.theme = darkMode ? "dark" : "light";
    reportLayout();
  };

  window.renderMessage = function (text, nextRevision, darkMode) {
    revision = Number.isSafeInteger(nextRevision) && nextRevision >= 0 ? nextRevision : 0;
    window.setAppearance(darkMode);
    const source = typeof text === "string" ? text : "";
    if (source.length > LIMITS.message) throw new RangeError("Message exceeds the math renderer limit");
    {
      content.style.whiteSpace = "";
      try {
        const result = prepareMarkdown(source);
        const clean = DOMPurify.sanitize(result.html, {
          RETURN_DOM_FRAGMENT: true,
          ALLOWED_TAGS: ["p", "br", "strong", "em", "del", "s", "a", "code", "pre", "blockquote", "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "table", "thead", "tbody", "tr", "th", "td", "span"],
          ALLOWED_ATTR: ["href", "rel", "class", "data-math", "start", "align"],
          ADD_URI_SAFE_ATTR: ["data-math"],
          ALLOW_DATA_ATTR: false,
          ALLOW_ARIA_ATTR: false,
          ALLOWED_URI_REGEXP: /^https?:\/\//i
        });
        content.replaceChildren(clean);
        content.querySelectorAll("span[data-math]").forEach(node => {
          const token = result.slots[Number(node.dataset.math)];
          if (token) renderMath(node, token);
        });
        content.querySelectorAll("pre > code").forEach(code => {
          code.parentNode.appendChild(copyButton("Copy code", "copy-code", code.textContent));
        });
      } catch (_) {
        content.textContent = source;
        content.style.whiteSpace = "pre-wrap";
      }
    }
    content.dataset.revision = String(revision);
    reportLayout();
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(reportLayout);
  };

  new ResizeObserver(reportLayout).observe(content);
  window.addEventListener("resize", reportLayout);
})();
