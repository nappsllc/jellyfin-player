// JellyPlayer demo server: a tiny Jellyfin-compatible API on a Cloudflare Worker,
// for App Review and testing. No real music. Every song is a short melody generated
// on the fly, and every cover is a generated gradient, so there is nothing to license.
//
// Sign in with username "demo" and password "demo".

const USER = { id: "demo-user", name: "demo", password: "demo" };
const TOKEN = "demo-token-jellyplayer";
const RATE = 16000;          // samples per second, mono, 16-bit
const TICKS = 10_000_000;    // Jellyfin ticks per second

// Library -> albums -> songs. Each song: [title, artist, seconds, root note, tempo, hue]
const ALBUMS = [
  { id: "album-morning", name: "Morning Tones", artist: "Demo Ensemble", hue: 28, songs: [
    ["Sunrise Walk", "Demo Ensemble", 48, 60, 100],
    ["Coffee Steam", "Demo Ensemble", 52, 62, 92],
    ["Open Window", "Demo Ensemble", 45, 65, 110],
    ["A Very Long Song Title That Does Not Fit On One Line Under The Cover", "Demo Ensemble featuring The Extremely Long Artist Name Orchestra", 60, 57, 96],
  ]},
  { id: "album-night", name: "Night Drive", artist: "Synth Example", hue: 230, songs: [
    ["Highway Lights", "Synth Example", 55, 55, 120],
    ["Tunnel", "Synth Example", 40, 53, 128],
    ["Neon Rain", "Synth Example", 50, 58, 116],
    ["Last Exit", "Synth Example", 46, 52, 104],
  ]},
  { id: "album-garden", name: "Garden", artist: "Placeholder Trio", hue: 120, songs: [
    ["Bees", "Placeholder Trio", 42, 67, 132],
    ["Rain on Leaves", "Placeholder Trio", 58, 60, 84],
    ["Garden", "Placeholder Trio", 44, 64, 100],
  ]},
];
const LIBRARY = { Id: "lib-music", Name: "Music", Type: "CollectionFolder", IsFolder: true, CollectionType: "music" };

const SONGS = [];
for (const a of ALBUMS) {
  a.songs.forEach(([name, artist, seconds, root, tempo], i) => {
    SONGS.push({ id: `${a.id}-${i + 1}`, name, artist, seconds, root, tempo, index: i + 1, album: a, hue: (a.hue + i * 18) % 360 });
  });
}
const byId = new Map(SONGS.map(s => [s.id, s]));
const albumById = new Map(ALBUMS.map(a => [a.id, a]));

function songItem(s) {
  return {
    Id: s.id, Name: s.name, Type: "Audio", IsFolder: false,
    Album: s.album.name, AlbumId: s.album.id, AlbumArtist: s.album.artist, Artists: [s.artist],
    RunTimeTicks: s.seconds * TICKS, IndexNumber: s.index, ParentId: s.album.id,
    ImageTags: { Primary: `${s.id}-v1` }, AlbumPrimaryImageTag: `${s.album.id}-v1`,
  };
}
function albumItem(a) {
  return { Id: a.id, Name: a.name, Type: "MusicAlbum", IsFolder: true, AlbumArtist: a.artist, ParentId: LIBRARY.Id,
           ImageTags: { Primary: `${a.id}-v1` } };
}

// ---------- Audio: deterministic melody, any byte range can be computed directly ----------

const HEADER = 44;
function wavSize(s) { return HEADER + s.seconds * RATE * 2; }

function wavHeader(dataBytes) {
  const b = new DataView(new ArrayBuffer(HEADER));
  const str = (o, t) => [...t].forEach((c, i) => b.setUint8(o + i, c.charCodeAt(0)));
  str(0, "RIFF"); b.setUint32(4, 36 + dataBytes, true); str(8, "WAVE");
  str(12, "fmt "); b.setUint32(16, 16, true); b.setUint16(20, 1, true); b.setUint16(22, 1, true);
  b.setUint32(24, RATE, true); b.setUint32(28, RATE * 2, true); b.setUint16(32, 2, true); b.setUint16(34, 16, true);
  str(36, "data"); b.setUint32(40, dataBytes, true);
  return new Uint8Array(b.buffer);
}

const SCALE = [0, 2, 4, 7, 9, 12, 9, 7];  // pentatonic up and down
function noteFreq(midi) { return 440 * Math.pow(2, (midi - 69) / 12); }

// Melody note n for a song: a simple seeded walk over the scale.
function melody(s, n) {
  const x = Math.sin((n + 1) * 12.9898 + s.root * 78.233) * 43758.5453;
  const step = Math.floor((x - Math.floor(x)) * SCALE.length);
  return s.root + SCALE[step];
}

// Each eighth-note beat is one of a few (melody note, bass note) pairs, so the beats are
// rendered once into small byte chunks and a song is just those chunks copied in order.
// That keeps CPU time per request tiny (Workers' free plan allows 10 ms).
const chunkCache = new Map();
function beatSamples(s) { return Math.round(RATE * 60 / s.tempo / 2); }
function beatNotes(s, n) { return [melody(s, n), s.root - 12 + (Math.floor(n / 8) % 2 ? 5 : 0)]; }

function beatChunk(s, n) {
  const [note, bass] = beatNotes(s, n);
  const key = `${note}|${bass}|${s.tempo}`;
  let chunk = chunkCache.get(key);
  if (chunk) return chunk;
  const len = beatSamples(s);
  chunk = new Uint8Array(len * 2);
  const f = 2 * Math.PI * noteFreq(note) / RATE, fb = 2 * Math.PI * noteFreq(bass) / RATE;
  for (let i = 0; i < len; i++) {
    const t = i / RATE;
    const env = Math.min(1, t * 80) * Math.exp(-t * 5);
    const benv = Math.min(1, t * 200, (len - i) / RATE * 200);   // no clicks between beats
    const v = 0.35 * env * Math.sin(f * i) + 0.12 * env * Math.sin(2 * f * i) + 0.18 * benv * Math.sin(fb * i);
    const q = Math.max(-1, Math.min(1, v)) * 32767 | 0;
    chunk[2 * i] = q & 0xff; chunk[2 * i + 1] = (q >> 8) & 0xff;
  }
  chunkCache.set(key, chunk);
  return chunk;
}

function wavBytes(s, start, end) {      // inclusive byte range
  const out = new Uint8Array(end - start + 1);
  const header = wavHeader(s.seconds * RATE * 2);
  for (let p = start; p <= Math.min(end, HEADER - 1); p++) out[p - start] = header[p];
  const beatBytes = beatSamples(s) * 2;
  let p = Math.max(start, HEADER);
  while (p <= end) {
    const off = p - HEADER;
    const n = Math.floor(off / beatBytes), inBeat = off - n * beatBytes;
    const chunk = beatChunk(s, n);
    const take = Math.min(beatBytes - inBeat, end - p + 1);
    out.set(chunk.subarray(inBeat, inBeat + take), p - start);
    p += take;
  }
  return out;
}

function audioResponse(request, s) {
  const size = wavSize(s);
  const headers = { "Content-Type": "audio/wav", "Accept-Ranges": "bytes", "Cache-Control": "public, max-age=86400" };
  let start = 0, end = size - 1, status = 200;
  const range = request.headers.get("Range");
  const m = range && /bytes=(\d*)-(\d*)/.exec(range);
  if (m) {
    if (m[1] === "") { start = Math.max(0, size - Number(m[2])); }
    else { start = Number(m[1]); if (m[2] !== "") end = Math.min(Number(m[2]), size - 1); }
    if (start > end || start >= size) return new Response(null, { status: 416, headers: { "Content-Range": `bytes */${size}` } });
    status = 206;
    headers["Content-Range"] = `bytes ${start}-${end}/${size}`;
  }
  headers["Content-Length"] = String(end - start + 1);
  if (request.method === "HEAD") return new Response(null, { status, headers });
  return new Response(wavBytes(s, start, end), { status, headers });
}

// ---------- Covers: a gradient BMP with a few circles (no compression needed) ----------

function hsl(h, sat, l) {
  const a = sat * Math.min(l, 1 - l);
  const f = n => { const k = (n + h / 30) % 12; return l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1)); };
  return [f(0) * 255, f(8) * 255, f(4) * 255];
}

const imageCache = new Map();
function coverBMP(hue, seed, size) {
  const row = size * 3;                 // size is a multiple of 4, so no row padding
  const data = new Uint8Array(54 + row * size);
  const v = new DataView(data.buffer);
  data[0] = 0x42; data[1] = 0x4d; v.setUint32(2, data.length, true); v.setUint32(10, 54, true);
  v.setUint32(14, 40, true); v.setInt32(18, size, true); v.setInt32(22, -size, true);
  v.setUint16(26, 1, true); v.setUint16(28, 24, true); v.setUint32(34, row * size, true);
  const top = hsl(hue, 0.65, 0.55), bottom = hsl((hue + 50) % 360, 0.7, 0.3);
  const circles = [0, 1, 2].map(k => {
    const r = Math.sin((seed + k) * 91.7) * 0.5 + 0.5;
    return { x: size * (0.2 + 0.6 * r), y: size * (0.25 + 0.2 * k), r: size * (0.12 + 0.08 * k), c: hsl((hue + 120 + 40 * k) % 360, 0.6, 0.7) };
  });
  for (let y = 0; y < size; y++) {
    const t = y / size;
    for (let x = 0; x < size; x++) {
      let c = [top[0] + (bottom[0] - top[0]) * t, top[1] + (bottom[1] - top[1]) * t, top[2] + (bottom[2] - top[2]) * t];
      for (const ci of circles) {
        const dx = x - ci.x, dy = y - ci.y;
        if (dx * dx + dy * dy < ci.r * ci.r) c = [(c[0] + ci.c[0]) / 2, (c[1] + ci.c[1]) / 2, (c[2] + ci.c[2]) / 2];
      }
      const o = 54 + y * row + x * 3;
      data[o] = c[2]; data[o + 1] = c[1]; data[o + 2] = c[0];
    }
  }
  return data;
}

// ---------- API ----------

const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

function authorized(request, url) {
  const q = url.searchParams.get("api_key") || url.searchParams.get("ApiKey");
  const h = request.headers.get("X-Emby-Token") || "";
  const auth = request.headers.get("Authorization") || "";
  return q === TOKEN || h === TOKEN || auth.includes(`Token="${TOKEN}"`);
}

function page(items, url) {
  const start = Number(url.searchParams.get("StartIndex") || 0);
  const limit = Number(url.searchParams.get("Limit") || items.length);
  return json({ Items: items.slice(start, start + limit), TotalRecordCount: items.length, StartIndex: start });
}

async function handle(request) {
  const url = new URL(request.url);
  // Jellyfin paths are case-insensitive; also allow the server to live under a sub-path.
  const path = url.pathname.replace(/\/+$/, "").toLowerCase();
  const parts = path.split("/").filter(Boolean);

  if (path === "" ) return new Response("JellyPlayer demo server. Sign in with demo / demo.\n");
  if (path === "/system/info/public") {
    return json({ ServerName: "JellyPlayer Demo", Version: "10.11.0", ProductName: "Jellyfin Server", Id: "jellyplayer-demo", StartupWizardCompleted: true });
  }
  if (path === "/users/authenticatebyname" && request.method === "POST") {
    let body = {};
    try { body = await request.json(); } catch {}
    if ((body.Username || "").toLowerCase() !== USER.name || (body.Pw ?? body.Password) !== USER.password) {
      return json({ error: "Invalid username or password" }, 401);
    }
    return json({ AccessToken: TOKEN, ServerId: "jellyplayer-demo", User: { Id: USER.id, Name: USER.name } });
  }

  // Images are public on real Jellyfin servers too.
  if (parts[0] === "items" && parts[2] === "images") {
    const id = url.pathname.split("/").filter(Boolean)[1];
    const s = byId.get(id), a = albumById.get(id);
    if (!s && !a) return new Response("Not found", { status: 404 });
    let bmp = imageCache.get(id);
    if (!bmp) { bmp = coverBMP(s ? s.hue : a.hue, s ? s.index * 7 + s.root : a.hue, 256); imageCache.set(id, bmp); }
    return new Response(bmp, { headers: { "Content-Type": "image/bmp", "Cache-Control": "public, max-age=604800" } });
  }

  if (!authorized(request, url)) return json({ error: "Unauthorized" }, 401);

  if (parts[0] === "users" && parts[2] === "views") return json({ Items: [LIBRARY], TotalRecordCount: 1 });

  if (path === "/items") {
    const parent = url.searchParams.get("ParentId") || url.searchParams.get("parentId");
    const recursive = (url.searchParams.get("Recursive") || "").toLowerCase() === "true";
    const types = (url.searchParams.get("IncludeItemTypes") || "").toLowerCase();
    if (recursive && types.includes("audio")) {
      const songs = parent === LIBRARY.Id ? SONGS : SONGS.filter(s => s.album.id === parent);
      return page(songs.map(songItem), url);
    }
    if (parent === LIBRARY.Id) return page(ALBUMS.map(albumItem), url);
    if (albumById.has(parent)) {
      const isFolder = (url.searchParams.get("IsFolder") || "").toLowerCase() === "true";
      return page(isFolder ? [] : SONGS.filter(s => s.album.id === parent).map(songItem), url);
    }
    return json({ Items: [], TotalRecordCount: 0 });
  }

  if (parts[0] === "audio" && (parts[2] === "stream" || parts[2] === "universal" || parts[2]?.startsWith("stream."))) {
    const id = url.pathname.split("/").filter(Boolean)[1];
    const s = byId.get(id);
    if (!s) return new Response("Not found", { status: 404 });
    return audioResponse(request, s);
  }

  return json({ error: "Not found" }, 404);
}

export default {
  async fetch(request) {
    try { return await handle(request); }
    catch (e) { return json({ error: String(e) }, 500); }
  },
};
