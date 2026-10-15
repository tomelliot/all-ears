// Zoom names probe — paste into the DevTools console of the Zoom web-client
// tab that is IN the call. Strictly read-only: one snapshot, no polling, no
// listeners, no DOM mutation, and no display name in the output.
//
// The question it answers: do the selectors in `lib/identity/zoom-dom.ts`
// match this Zoom build, and if not, which class names hold the names and the
// topic? Names and free text are reduced to a 7-char hash; class names are
// emitted verbatim, because they are how the selector gets fixed.
//
//   __earsZoom.snapshot()   → re-run the snapshot
//
// Keep SELECTORS in step with ZOOM_SELECTORS in zoom-dom.ts.
(() => {
  const SELECTORS = {
    participantName: ".participants-item__display-name",
    participantLabel: ".participants-item__name-label",
    tileNames: [".video-avatar__avatar-name", ".video-avatar__avatar-footer"],
    preJoinName: "#input-for-name",
    topic: ".meeting-info-container__meeting-topic, .meeting-topic",
  };

  const hash = (s) => {
    let h = 5381;
    for (const c of String(s)) h = ((h << 5) + h + c.codePointAt(0)) >>> 0;
    return "·" + h.toString(36).padStart(7, "0").slice(-7);
  };
  const text = (el) => (el?.textContent ?? "").replace(/\s+/g, " ").trim();
  // Role/self suffixes are Zoom's own words, so they are safe to show.
  const suffix = (t) => (t.match(/\(([^()]*)\)\s*$/)?.[1] ?? "").toLowerCase();

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

  const snapshot = () => {
    const frames = documents().map(({ where, doc }) => {
      if (!doc) return { where, readable: false };
      const sel = (s) => [...doc.querySelectorAll(s)].map((el) => ({ hash: hash(text(el)), suffix: suffix(text(el)) }));
      // Census: class names that look like name, avatar, participant or topic
      // holders, so a miss shows what to select instead.
      const classes = new Map();
      for (const el of doc.querySelectorAll("[class]")) {
        for (const c of el.classList) {
          if (/name|avatar|participant|topic|meeting-info/i.test(c)) classes.set(c, (classes.get(c) ?? 0) + 1);
        }
      }
      const titleText = doc.title ?? "";
      return {
        where,
        readable: true,
        title: { hash: hash(titleText), length: titleText.length, generic: /^(zoom( meeting| workplace)?)?$/i.test(titleText.trim()) },
        participantName: sel(SELECTORS.participantName),
        participantLabel: sel(SELECTORS.participantLabel),
        tileNames: Object.fromEntries(SELECTORS.tileNames.map((s) => [s, sel(s)])),
        topic: sel(SELECTORS.topic),
        preJoinNamePresent: !!doc.querySelector(SELECTORS.preJoinName),
        classes: Object.fromEntries([...classes].sort((a, b) => b[1] - a[1]).slice(0, 60)),
      };
    });
    return { ts: new Date().toISOString(), path: location.pathname.replace(/\d{6,}/g, "<id>"), frames };
  };

  window.__earsZoom = { snapshot };
  const result = snapshot();
  console.log("[ears-probe][zoom]", JSON.stringify(result, null, 2));
  return result;
})();
