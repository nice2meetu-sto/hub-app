// ============================================================
//  Cloudflare Worker: BGG(BoardGameGeek) 검색 프록시
//
//  브라우저는 CORS·XML 때문에 BGG XML API를 직접 못 부르고,
//  Supabase Edge Function(데이터센터 IP)은 BGG 앞단 Cloudflare가
//  401/403으로 막는다. Cloudflare Worker는 Cloudflare 자체 망에서
//  나가므로 차단을 통과할 가능성이 높다.
//
//  배포: cloudflare-worker-bgg/README.md 참고 (대시보드 5분)
//  호출: GET  https://<worker>/?q=검색어
//        POST https://<worker>/   body: {"q":"검색어"}
//  반환: { results: [{ bgg_id, name_en, min_players, max_players,
//                      playtime_min, image_url }] }
// ============================================================

const BGG_HOSTS = ['https://boardgamegeek.com', 'https://api.geekdo.com'];
const BROWSER_HEADERS = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
                '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  'Accept': 'application/xml,text/xml,text/html,*/*',
  'Accept-Language': 'en-US,en;q=0.9',
};
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};

export default {
  async fetch(req) {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
    const url = new URL(req.url);
    let q = url.searchParams.get('q') || '';
    if (!q && req.method === 'POST') {
      try { const b = await req.json(); q = (b && b.q) || ''; } catch (e) {}
    }
    q = String(q).trim();
    if (!q) return json({ results: [] });
    try {
      // 1) 검색 → boardgame id 목록(최대 8, 중복 제거)
      const searchXml = await bggFetch('/xmlapi2/search?type=boardgame&query=' + encodeURIComponent(q));
      const ids = [];
      const idRe = /<item\b[^>]*\bid="(\d+)"/g; let m;
      while ((m = idRe.exec(searchXml)) && ids.length < 8) {
        if (!ids.includes(m[1])) ids.push(m[1]);
      }
      if (!ids.length) return json({ results: [] });

      // 2) 상세(thing) 한 번에 여러 id
      const thingXml = await bggFetch('/xmlapi2/thing?id=' + ids.join(','));
      const results = [];
      const itemRe = /<item\b[^>]*\bid="(\d+)"[^>]*>([\s\S]*?)<\/item>/g;
      while ((m = itemRe.exec(thingXml))) {
        const id = m[1], b = m[2];
        const nameM = b.match(/<name\b[^>]*type="primary"[^>]*value="([^"]*)"/);
        const image = (b.match(/<image>([^<]*)<\/image>/) || [])[1] ||
                      (b.match(/<thumbnail>([^<]*)<\/thumbnail>/) || [])[1] || '';
        results.push({
          bgg_id: id,
          name_en: nameM ? decodeEntities(nameM[1]) : '',
          min_players: num(firstAttr(b, 'minplayers')),
          max_players: num(firstAttr(b, 'maxplayers')),
          playtime_min: num(firstAttr(b, 'playingtime') || firstAttr(b, 'maxplaytime')),
          image_url: image,
        });
      }
      results.sort((a, b) => ids.indexOf(a.bgg_id) - ids.indexOf(b.bgg_id));
      return json({ results: results.slice(0, 6) });
    } catch (e) {
      // 실패해도 앱은 자체 도감으로 동작 — 에러는 메시지로만
      return json({ results: [], error: String((e && e.message) || e) }, 200);
    }
  },
};

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status, headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}
function num(v) { return v ? Number(v) : null; }
function firstAttr(xml, tag, attr = 'value') {
  const m = xml.match(new RegExp('<' + tag + '\\b[^>]*\\b' + attr + '="([^"]*)"'));
  return m ? m[1] : null;
}
function decodeEntities(s) {
  return s
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#(\d+);/g, (_m, n) => String.fromCharCode(+n));
}
async function bggFetch(path, tries = 4) {
  let last = '';
  for (const host of BGG_HOSTS) {
    for (let i = 0; i < tries; i++) {
      let res;
      try { res = await fetch(host + path, { headers: BROWSER_HEADERS }); }
      catch (e) { last = 'fetch ' + ((e && e.message) || e); break; }
      if (res.status === 200) return await res.text();
      if (res.status === 202 || res.status === 429) {      // 처리 중/속도제한 → 재시도
        await new Promise((r) => setTimeout(r, 800 + i * 400));
        continue;
      }
      last = 'HTTP ' + res.status;   // 401/403/5xx → 이 호스트 재시도 무의미, 다음 호스트로
      break;
    }
  }
  throw new Error('BGG ' + (last || '응답 지연'));
}
