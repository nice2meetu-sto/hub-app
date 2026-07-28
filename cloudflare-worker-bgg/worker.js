// ============================================================
//  Cloudflare Worker: BGG(BoardGameGeek) 검색 프록시
//
//  BGG XML API는 2025-07 정책부터 '앱 등록 + Authorization Bearer 토큰'이
//  사실상 필수(무등록 요청은 401). 이 Worker는 서버측 프록시(BGG 권장 구조)로,
//  등록 후 발급받은 토큰을 붙여 호출하고 결과를 JSON+CORS로 돌려준다.
//
//  ① 앱 등록: https://boardgamegeek.com/applications (Non-commercial, 승인 1주+)
//  ② 승인되면 같은 페이지 Tokens에서 토큰 생성
//  ③ Cloudflare 대시보드 → 이 Worker → Settings → Variables →
//     'BGG_TOKEN' 이름의 Secret으로 토큰 저장 → 재배포
//  (배포 방법 전체: cloudflare-worker-bgg/README.md)
//
//  호출: GET  https://<worker>/?q=검색어
//        POST https://<worker>/   body: {"q":"검색어"}
//  반환: { results: [{ bgg_id, name_en, min_players, max_players,
//                      playtime_min, image_url }] }
// ============================================================

// 정책상 요청 도메인은 boardgamegeek.com (www 없이)
const BGG_HOSTS = ['https://boardgamegeek.com', 'https://api.geekdo.com'];
const BASE_HEADERS = {
  'User-Agent': 'boardgame-hub.com (non-commercial board game club app)',
  'Accept': 'application/xml,text/xml,*/*',
};
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};
let BGG_HEADERS = BASE_HEADERS;   // env.BGG_TOKEN 있으면 Authorization 추가

export default {
  async fetch(req, env) {
    // BGG 앱 토큰(Secret): "Bearer <토큰>" 헤더 — 등록/승인 후 필수
    BGG_HEADERS = env && env.BGG_TOKEN
      ? { ...BASE_HEADERS, 'Authorization': 'Bearer ' + env.BGG_TOKEN }
      : BASE_HEADERS;
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
      try { res = await fetch(host + path, { headers: BGG_HEADERS }); }
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
