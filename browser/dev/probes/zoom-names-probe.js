// Zoom names probe — paste into the DevTools console of the Zoom web-client
// tab that is IN the call. Strictly read-only: one snapshot, no polling, no
// listeners, no DOM mutation, and no display name in the output.
//
// The questions it answers: do the selectors in `lib/identity/zoom-dom.ts`
// match this Zoom build, and if not, which class names hold the names and the
// topic? And what marks the LOCAL user's own tile or row, if anything (the
// tiles carried no known self marker on 2026-10-26)? Names and free text are
// reduced to a 7-char hash; class names, ids, attribute names and input
// placeholders are emitted verbatim, because they are how the selector gets
// fixed.
//
//   __earsZoom.snapshot()            → re-run the snapshot
//   __earsZoom.snapshot("Your Name") → also find your own tile: each tile gets
//                                      `own: true|false`, and `self.ownOnly`
//                                      lists the classes and attributes found
//                                      on your tile's ancestry and on no other
//                                      tile's. Your name is compared, never
//                                      printed.
//
// Run it twice for the full answer: once with the Participants panel closed,
// once with it open (only the panel carries Zoom's "(me)" marker).
//
// Keep SELECTORS and GENERIC_TITLE_RE in step with zoom-dom.ts.
(() => {
  const SELECTORS = {
    participantName: ".participants-item__display-name",
    participantLabel: ".participants-item__name-label",
    tileNames: [".video-avatar__avatar-name", ".video-avatar__avatar-footer"],
    preJoinName: "#input-for-name, #inputname",
    topic: ".meeting-info-container__meeting-topic, .meeting-topic",
  };
  const GENERIC_TITLE_RE =
    /^zoom(?: workplace)?(?: (?:meeting|webinar))?(?: (?:on (?:the )?web|web(?: client| app)?))?$/i;
  // Words a developer would put in a class, id or attribute name for "the
  // local user". Matched against names, never against text.
  const SELF_WORD_RE = /self|myself|local|(?:^|[-_])(?:me|you|own)(?:$|[-_])/i;
  // Zoom's own self markers in user-visible text ("(me)", "(Host, me)", "(You)").
  const SELF_TEXT_RE = /\((?:[^()]*,\s*)?(?:me|you)\)/i;
  const ANCESTRY_DEPTH = 8;

  const hash = (s) => {
    let h = 5381;
    for (const c of String(s)) h = ((h << 5) + h + c.codePointAt(0)) >>> 0;
    return "·" + h.toString(36).padStart(7, "0").slice(-7);
  };
  const norm = (s) => String(s ?? "").replace(/\s+/g, " ").trim();
  const text = (el) => norm(el?.textContent);
  // Role/self suffixes are Zoom's own words, so they are safe to show; any
  // other trailing "(…)" is the user's text and is only flagged.
  const suffix = (t) => {
    const group = (t.match(/\(([^()]*)\)\s*$/)?.[1] ?? "").toLowerCase();
    return isRoleLabel(group) ? group : "(other)";
  };
  const stripSuffix = (t) => t.replace(/\s*\([^()]*\)\s*$/, "").trim().toLowerCase();
  // A label made only of Zoom's role words ("(Host, me)", "Me"): safe to show.
  const ROLE_WORDS = new Set(["host", "co-host", "cohost", "guest", "me", "you"]);
  const isRoleLabel = (t) => {
    const inner = norm(t).replace(/^\((.*)\)$/, "$1").trim();
    return inner === "" || inner.split(",").every((w) => ROLE_WORDS.has(w.trim().toLowerCase()));
  };

  const documents = () => {
    const docs = [{ where: "self", doc: document }];
    try {
      if (window.parent !== window) docs.push({ where: "parent", doc: window.parent.document });
    } catch {
      docs.push({ where: "parent", doc: null });
    }
    document.querySelectorAll("iframe").forEach((f, i) => {
      try {
        docs.push({ where: `iframe[${i}]`, doc: f.contentDocument });
      } catch {
        docs.push({ where: `iframe[${i}]`, doc: null });
      }
    });
    return docs;
  };

  // Developer-authored markers on one element: classes, id, attribute names
  // (not values, which can hold names), and whether its aria-label or title
  // carries a self marker.
  const markers = (el) => {
    const out = [...el.classList].map((c) => `.${c}`);
    if (el.id) out.push(`#${el.id}`);
    for (const a of el.getAttributeNames()) if (a !== "class" && a !== "id" && a !== "style") out.push(`[${a}]`);
    for (const a of ["aria-label", "title"]) {
      if (SELF_TEXT_RE.test(el.getAttribute(a) ?? "")) out.push(`[${a}~self-marker]`);
    }
    return out;
  };
  const ancestry = (el) => {
    const chain = [];
    for (let p = el; p && chain.length < ANCESTRY_DEPTH; p = p.parentElement) {
      chain.push({ tag: p.tagName.toLowerCase(), markers: markers(p), video: !!p.querySelector?.("video"), canvas: !!p.querySelector?.("canvas") });
    }
    return chain;
  };

  const snapshot = (ownName) => {
    const own = ownName ? stripSuffix(norm(ownName)) : null;
    const ownTileMarkers = [];
    const otherTileMarkers = new Set();

    const frames = documents().map(({ where, doc }) => {
      if (!doc) return { where, readable: false };
      const sel = (s) =>
        [...doc.querySelectorAll(s)].map((el) => ({
          hash: hash(text(el)),
          suffix: suffix(text(el)),
          ...(own ? { own: stripSuffix(text(el)) === own } : {}),
        }));

      // Tiles: each name element with its ancestry, so a class that only the
      // own tile carries shows up in `self.ownOnly`.
      const tiles = {};
      for (const s of SELECTORS.tileNames) {
        tiles[s] = [...doc.querySelectorAll(s)].map((el) => {
          const isOwn = own ? stripSuffix(text(el)) === own : undefined;
          const chain = ancestry(el);
          const flat = chain.flatMap((c) => c.markers);
          if (isOwn) ownTileMarkers.push(...flat);
          else if (own) flat.forEach((m) => otherTileMarkers.add(m));
          return { hash: hash(text(el)), ...(own ? { own: isOwn } : {}), ancestry: chain };
        });
      }

      // Participants panel rows: the label's text is Zoom's role words, shown
      // verbatim only when it is nothing but a "(…)" role group.
      const rows = [...doc.querySelectorAll(SELECTORS.participantName)].map((el) => {
        const label = text(el.parentElement?.querySelector(SELECTORS.participantLabel));
        const row = el.parentElement?.closest("[class*='participants-item']");
        return {
          hash: hash(text(el)),
          ...(own ? { own: stripSuffix(text(el)) === own } : {}),
          suffix: suffix(text(el)),
          label: isRoleLabel(label) ? label : hash(label),
          rowMarkers: row ? markers(row) : [],
        };
      });

      // Self hunt across the whole frame: developer names that say "self",
      // and user-visible text or labels that carry Zoom's "(me)" marker.
      const selfNames = new Map();
      const selfText = new Map();
      for (const el of doc.querySelectorAll("*")) {
        for (const m of markers(el)) if (SELF_WORD_RE.test(m)) selfNames.set(m, (selfNames.get(m) ?? 0) + 1);
        const ownText = [...el.childNodes].filter((n) => n.nodeType === 3).map((n) => n.textContent).join("");
        if (SELF_TEXT_RE.test(ownText) || SELF_TEXT_RE.test(el.getAttribute("aria-label") ?? "")) {
          const key = `${el.tagName.toLowerCase()}${[...el.classList].map((c) => `.${c}`).join("")}`;
          selfText.set(key, (selfText.get(key) ?? 0) + 1);
        }
      }

      // Pre-join name inputs: presence and value length, never the value.
      const preJoin = [...doc.querySelectorAll(SELECTORS.preJoinName)].map((el) => ({
        id: el.id,
        valueLength: (el.value ?? "").length,
        ...(own ? { own: stripSuffix(norm(el.value)) === own } : {}),
      }));
      const textInputs = [...doc.querySelectorAll("input:not([type]), input[type='text']")].map((el) => ({
        id: el.id,
        name: el.name,
        placeholder: el.placeholder,
        valueLength: (el.value ?? "").length,
      }));

      // Census: class names that look like name, avatar, participant or topic
      // holders, so a miss shows what to select instead.
      const classes = new Map();
      for (const el of doc.querySelectorAll("[class]")) {
        for (const c of el.classList) {
          if (/name|avatar|participant|topic|meeting-info|self/i.test(c)) classes.set(c, (classes.get(c) ?? 0) + 1);
        }
      }
      const titleText = doc.title ?? "";
      return {
        where,
        readable: true,
        title: { hash: hash(titleText), length: titleText.length, generic: GENERIC_TITLE_RE.test(norm(titleText).replace(/\s*[-–—|]\s*Zoom(?: Workplace)?$/i, "")) },
        participantName: sel(SELECTORS.participantName),
        participantLabel: sel(SELECTORS.participantLabel),
        participantRows: rows,
        tileNames: tiles,
        topic: sel(SELECTORS.topic),
        preJoin,
        textInputs,
        selfNames: Object.fromEntries(selfNames),
        selfText: Object.fromEntries(selfText),
        classes: Object.fromEntries([...classes].sort((a, b) => b[1] - a[1]).slice(0, 60)),
      };
    });

    const self = own
      ? {
          ownTileFound: ownTileMarkers.length > 0,
          ownOnly: [...new Set(ownTileMarkers)].filter((m) => !otherTileMarkers.has(m)),
        }
      : { hint: 'pass your display name: __earsZoom.snapshot("Your Name")' };
    return { ts: new Date().toISOString(), path: location.pathname.replace(/\d{6,}/g, "<id>"), self, frames };
  };

  window.__earsZoom = { snapshot };
  const result = snapshot();
  console.log("[ears-probe][zoom]", JSON.stringify(result, null, 2));
  return result;
})();
