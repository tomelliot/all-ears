import type { LogEntry } from "./debug-log";

// Persisted debug-log ring, owned by the background service worker. IndexedDB
// (not storage.local) because the log can run to thousands of entries and must
// survive service-worker eviction and browser restarts. A single object store
// with an autoIncrement key keeps entries in chronological order; every append
// trims the oldest back down to MAX_ENTRIES, so the store is a bounded ring.
//
// The DB is opened per operation and closed after: appends arrive batched
// (~1/s), and holding a connection open across service-worker suspension buys
// nothing.

const DB_NAME = "ears-debug-log";
const STORE = "entries";
const DB_VERSION = 1;

/** Ring capacity. At ~200 bytes/entry this is a low-single-digit MB ceiling. */
export const MAX_ENTRIES = 5000;

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORE)) db.createObjectStore(STORE, { autoIncrement: true });
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

function txDone(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
  });
}

/** Delete the oldest entries (lowest keys) until at most `max` remain. */
function trim(store: IDBObjectStore, max: number): void {
  const countReq = store.count();
  countReq.onsuccess = () => {
    let over = countReq.result - max;
    if (over <= 0) return;
    const cursorReq = store.openCursor(); // ascending → oldest first
    cursorReq.onsuccess = () => {
      const cursor = cursorReq.result;
      if (!cursor || over <= 0) return;
      cursor.delete();
      over -= 1;
      cursor.continue();
    };
  };
}

/** Append entries, then trim the ring back to `max`. */
export async function appendEntries(entries: LogEntry[], max = MAX_ENTRIES): Promise<void> {
  if (entries.length === 0) return;
  const db = await openDb();
  try {
    const tx = db.transaction(STORE, "readwrite");
    const store = tx.objectStore(STORE);
    for (const entry of entries) store.add(entry);
    trim(store, max);
    await txDone(tx);
  } finally {
    db.close();
  }
}

/** Every entry, oldest first. */
export async function readAllEntries(): Promise<LogEntry[]> {
  const db = await openDb();
  try {
    const tx = db.transaction(STORE, "readonly");
    const req = tx.objectStore(STORE).getAll();
    const done = txDone(tx);
    await done;
    return (req.result as LogEntry[]) ?? [];
  } finally {
    db.close();
  }
}

/** Empty the ring. */
export async function clearEntries(): Promise<void> {
  const db = await openDb();
  try {
    const tx = db.transaction(STORE, "readwrite");
    tx.objectStore(STORE).clear();
    await txDone(tx);
  } finally {
    db.close();
  }
}
