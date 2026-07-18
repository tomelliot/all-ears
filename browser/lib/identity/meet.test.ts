import { describe, expect, it } from "vitest";
import {
  PARTICIPANT_ID_ATTRIBUTES,
  extractDisplayName,
  extractParticipantId,
  findMediaElementForTrack,
  findParticipantTile,
  type DocumentLike,
  type MediaElementLike,
} from "./meet";

// Hand-rolled fake DOM (repo prefers small fakes over jsdom — see
// rtc-hook.test.ts; vitest runs in the node environment). Implements exactly
// the structural slice the helpers use: getAttribute, parentElement,
// textContent, and querySelector limited to the "[attr],[attr]" selector
// shape meet.ts passes.

interface FakeElInit {
  attrs?: Record<string, string>;
  text?: string;
  children?: FakeEl[];
  srcObject?: unknown;
  tag?: string;
  classes?: string[];
}

// Fake querySelector supports exactly the two selector shapes meet.ts uses:
// "[attr]" (attribute presence, comma-separated) and "tag.class".
interface SelectorPattern {
  attr?: string;
  tag?: string;
  cls?: string;
}

function parseFakeSelector(selector: string): SelectorPattern {
  const attrMatch = selector.match(/^\[([^\]]+)\]$/);
  if (attrMatch) return { attr: attrMatch[1]! };
  const tagClassMatch = selector.match(/^([a-zA-Z]+)\.([\w-]+)$/);
  if (tagClassMatch) return { tag: tagClassMatch[1]!.toUpperCase(), cls: tagClassMatch[2]! };
  throw new Error(`unsupported fake selector: ${selector}`);
}

class FakeEl implements MediaElementLike {
  parentElement: FakeEl | null = null;
  textContent: string | null;
  srcObject?: unknown;
  readonly tag: string;
  private readonly attrs: Map<string, string>;
  private readonly children: FakeEl[];
  private readonly classes: Set<string>;

  constructor(init: FakeElInit = {}) {
    this.attrs = new Map(Object.entries(init.attrs ?? {}));
    this.textContent = init.text ?? null;
    this.children = init.children ?? [];
    this.tag = (init.tag ?? "DIV").toUpperCase();
    this.classes = new Set(init.classes ?? []);
    for (const child of this.children) child.parentElement = this;
    if ("srcObject" in init) this.srcObject = init.srcObject;
  }

  getAttribute(name: string): string | null {
    return this.attrs.get(name) ?? null;
  }

  private matches(pattern: SelectorPattern): boolean {
    if (pattern.attr) return this.getAttribute(pattern.attr) !== null;
    if (pattern.tag && this.tag !== pattern.tag) return false;
    if (pattern.cls && !this.classes.has(pattern.cls)) return false;
    return true;
  }

  querySelector(selectors: string): FakeEl | null {
    const patterns = selectors.split(",").map((s) => parseFakeSelector(s.trim()));
    const walk = (el: FakeEl): FakeEl | null => {
      for (const child of el.children) {
        if (patterns.some((p) => child.matches(p))) return child;
        const hit = walk(child);
        if (hit) return hit;
      }
      return null;
    };
    return walk(this);
  }
}

function fakeDoc(mediaEls: FakeEl[]): DocumentLike {
  return {
    querySelectorAll: (sel) => (sel === "audio, video" ? mediaEls : []),
    querySelector: () => null,
  };
}

const fakeTrack = (id: string) => ({ id });
const fakeStream = (id: string, tracks: { id: string }[]) => ({ id, getTracks: () => tracks });

describe("extractParticipantId", () => {
  it("reads each candidate attribute", () => {
    for (const attr of PARTICIPANT_ID_ATTRIBUTES) {
      const tile = new FakeEl({ attrs: { [attr]: "spaces/abc/devices/7" } });
      expect(extractParticipantId(tile)).toBe("spaces/abc/devices/7");
    }
  });

  it("trims whitespace and treats blank values as missing", () => {
    expect(extractParticipantId(new FakeEl({ attrs: { "data-participant-id": "  spaces/x  " } }))).toBe("spaces/x");
    expect(extractParticipantId(new FakeEl({ attrs: { "data-participant-id": "   " } }))).toBeNull();
  });

  it("returns null when no candidate attribute is present", () => {
    expect(extractParticipantId(new FakeEl({ attrs: { "data-something-else": "x" } }))).toBeNull();
  });
});

describe("findParticipantTile", () => {
  it("returns the element itself when it carries the id", () => {
    const tile = new FakeEl({ attrs: { "data-participant-id": "spaces/a" } });
    expect(findParticipantTile(tile)).toBe(tile);
  });

  it("climbs ancestors to the nearest tile", () => {
    const media = new FakeEl();
    const wrapper = new FakeEl({ children: [media] });
    const tile = new FakeEl({ attrs: { "data-requested-participant-id": "spaces/b" }, children: [wrapper] });
    new FakeEl({ children: [tile] }); // grid container above the tile
    expect(findParticipantTile(media)).toBe(tile);
  });

  it("returns null when no ancestor carries an id", () => {
    const media = new FakeEl();
    new FakeEl({ children: [media] });
    expect(findParticipantTile(media)).toBeNull();
  });
});

describe("extractDisplayName", () => {
  it("prefers the tile's own data-self-name", () => {
    const tile = new FakeEl({
      attrs: { "data-self-name": "Ada Lovelace", "aria-label": "Pin Ada Lovelace" },
      children: [new FakeEl({ attrs: { "data-self-name": "Nested" } })],
    });
    expect(extractDisplayName(tile)).toBe("Ada Lovelace");
  });

  it("falls back to a descendant's data-self-name attribute", () => {
    const tile = new FakeEl({
      children: [new FakeEl({ children: [new FakeEl({ attrs: { "data-self-name": "Grace Hopper" } })] })],
    });
    expect(extractDisplayName(tile)).toBe("Grace Hopper");
  });

  it("uses the descendant's text when its attribute is blank", () => {
    const tile = new FakeEl({
      children: [new FakeEl({ attrs: { "data-self-name": "  " }, text: " Katherine Johnson " })],
    });
    expect(extractDisplayName(tile)).toBe("Katherine Johnson");
  });

  it("falls back to a descendant span.notranslate (journal #41 live shape)", () => {
    // Real Meet markup: the name lives in a tag-qualified span.notranslate
    // (Google's do-not-translate marker), not data-self-name/aria-label —
    // neither of which is present on the current build.
    const tile = new FakeEl({
      children: [new FakeEl({ tag: "span", classes: ["notranslate"], text: "Tom Elliot" })],
    });
    expect(extractDisplayName(tile)).toBe("Tom Elliot");
  });

  it("ignores non-span notranslate elements (material-icon ligatures also carry the class)", () => {
    const tile = new FakeEl({
      children: [
        new FakeEl({ tag: "i", classes: ["notranslate"], text: "keep_outline" }),
        new FakeEl({ tag: "span", classes: ["notranslate"], text: "Grace Hopper" }),
      ],
    });
    expect(extractDisplayName(tile)).toBe("Grace Hopper");
  });

  it("prefers data-self-name over span.notranslate when both are present", () => {
    const tile = new FakeEl({
      attrs: { "data-self-name": "Ada Lovelace" },
      children: [new FakeEl({ tag: "span", classes: ["notranslate"], text: "Someone Else" })],
    });
    expect(extractDisplayName(tile)).toBe("Ada Lovelace");
  });

  it("falls back to the tile's aria-label", () => {
    const tile = new FakeEl({ attrs: { "aria-label": "Alan Turing" } });
    expect(extractDisplayName(tile)).toBe("Alan Turing");
  });

  it("returns undefined when nothing name-shaped exists", () => {
    expect(extractDisplayName(new FakeEl())).toBeUndefined();
  });
});

describe("findMediaElementForTrack", () => {
  it("matches an element whose srcObject contains the exact track object", () => {
    const track = fakeTrack("t1");
    const el = new FakeEl({ srcObject: fakeStream("s1", [track]) });
    const doc = fakeDoc([new FakeEl(), el]);
    expect(findMediaElementForTrack(doc, track, null)).toBe(el);
  });

  it("matches by track id when the objects differ", () => {
    const el = new FakeEl({ srcObject: fakeStream("s1", [fakeTrack("t1")]) });
    expect(findMediaElementForTrack(fakeDoc([el]), fakeTrack("t1"), null)).toBe(el);
  });

  it("prefers a track match over an earlier stream-id match", () => {
    const track = fakeTrack("t1");
    const stream = fakeStream("msid-1", [track]);
    // Tile <video> holding a different stream with the same msid comes first
    // in DOM order; the element actually holding the track must still win.
    const videoEl = new FakeEl({ srcObject: fakeStream("msid-1", [fakeTrack("v1")]) });
    const audioEl = new FakeEl({ srcObject: fakeStream("other", [track]) });
    expect(findMediaElementForTrack(fakeDoc([videoEl, audioEl]), track, stream)).toBe(audioEl);
  });

  it("falls back to the element rendering the same MediaStream object", () => {
    const track = fakeTrack("t1");
    const stream = fakeStream("msid-1", [track]);
    const el = new FakeEl({ srcObject: stream });
    // The element's stream doesn't list our track (Meet's WASM decode path) —
    // shared stream identity still correlates.
    stream.getTracks = () => [fakeTrack("v1")];
    expect(findMediaElementForTrack(fakeDoc([el]), track, stream)).toBe(el);
  });

  it("falls back to a same-id MediaStream (tile <video> sharing the msid)", () => {
    const track = fakeTrack("t1");
    const stream = fakeStream("msid-1", [track]);
    const videoEl = new FakeEl({ srcObject: fakeStream("msid-1", [fakeTrack("v1")]) });
    expect(findMediaElementForTrack(fakeDoc([videoEl]), track, stream)).toBe(videoEl);
  });

  it("never stream-id-matches on an empty id", () => {
    const track = fakeTrack("t1");
    const stream = fakeStream("", [track]);
    const el = new FakeEl({ srcObject: fakeStream("", [fakeTrack("v1")]) });
    expect(findMediaElementForTrack(fakeDoc([el]), track, stream)).toBeNull();
  });

  it("ignores elements without a MediaStream-shaped srcObject", () => {
    const track = fakeTrack("t1");
    const doc = fakeDoc([
      new FakeEl(), // no srcObject at all
      new FakeEl({ srcObject: null }),
      new FakeEl({ srcObject: "not-a-stream" }),
      new FakeEl({ srcObject: { id: "s", getTracks: "nope" } }),
    ]);
    expect(findMediaElementForTrack(doc, track, fakeStream("s1", [track]))).toBeNull();
  });

  it("returns null when nothing matches", () => {
    const el = new FakeEl({ srcObject: fakeStream("s9", [fakeTrack("t9")]) });
    expect(findMediaElementForTrack(fakeDoc([el]), fakeTrack("t1"), fakeStream("s1", []))).toBeNull();
  });

  it("correlates end to end through the tile (pure parts): media element → tile id + name", () => {
    const track = fakeTrack("t1");
    const media = new FakeEl({ srcObject: fakeStream("s1", [track]) });
    const tile = new FakeEl({
      attrs: { "data-participant-id": "spaces/abc/devices/7" },
      children: [new FakeEl({ children: [media] }), new FakeEl({ attrs: { "data-self-name": "Ada" } })],
    });
    new FakeEl({ children: [tile] });

    const found = findMediaElementForTrack(fakeDoc([media]), track, null);
    expect(found).toBe(media);
    const foundTile = findParticipantTile(found as FakeEl);
    expect(foundTile).toBe(tile);
    expect(extractParticipantId(foundTile as FakeEl)).toBe("spaces/abc/devices/7");
    expect(extractDisplayName(foundTile as FakeEl)).toBe("Ada");
  });
});
