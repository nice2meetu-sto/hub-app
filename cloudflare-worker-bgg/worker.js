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
//                      playtime_min, image_url, weight, best_players }] }
//  (weight = BGG 평균 난이도, best_players = 커뮤니티 투표 '베스트 인원')
//
//  게임 설명: GET https://<worker>/?desc=<bgg_id>
//  반환: { description_kr, description_en }  — 앞 몇 문장만 잘라 반환.
//  한글은 Workers AI 번역(m2m100) — 대시보드에서 이 Worker의 Bindings에
//  'AI' 이름으로 Workers AI 바인딩을 추가해야 동작(없으면 영문만 반환).
//
//  Supabase 재우기 방지(keep-alive):
//  Supabase 무료 플랜은 7일간 요청이 하나도 없으면 프로젝트를 자동 일시정지한다.
//  Cron Trigger로 하루 한 번 가벼운 조회 RPC를 호출해 '활동 중'으로 유지한다.
//    · 설정: 대시보드 → 이 Worker → Settings → Triggers → Cron Triggers →
//            Add Cron Trigger → 예) 0 3 * * *  (매일 UTC 03:00 = 한국 낮 12시)
//    · 수동 확인: GET https://<worker>/?keepalive=1 → {"ok":true,"status":200,...}
// ============================================================

// Supabase 프로젝트 주소·anon key — 앱(app.js)에 이미 공개된 값과 동일하다.
// anon key는 공개를 전제로 설계된 키라 시크릿이 아니며, 여기 적어도 안전하다.
// 대시보드에 SUPABASE_URL / SUPABASE_ANON_KEY 변수를 넣으면 그 값이 우선한다.
const SUPABASE_URL_DEFAULT = 'https://pqnvfcxstfyjsufdrgcm.supabase.co';
const SUPABASE_ANON_DEFAULT = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBxbnZmY3hzdGZ5anN1ZmRyZ2NtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQzNDM2OTEsImV4cCI6MjA5OTkxOTY5MX0.drHD0rkKgKuzY2h4T0CW4Mo68KqW6k3nVOGJGvGnfHU';

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
    // ---- keep-alive 수동 확인 (Cron이 매일 하는 일과 똑같은 요청) ----
    if (url.searchParams.get('keepalive')) return json(await keepAlive(env));
    // ---- 게임 설명(+한글 번역) ----
    const descId = (url.searchParams.get('desc') || '').replace(/\D/g, '');
    if (descId) {
      try {
        const xml = await bggFetch('/xmlapi2/thing?id=' + descId);
        let desc = (xml.match(/<description>([\s\S]*?)<\/description>/) || [])[1] || '';
        desc = decodeEntities(desc).replace(/<[^>]+>/g, ' ').replace(/[ \t]+/g, ' ').trim();
        const short = firstSentences(desc, 3, 400);   // 요약 용도: 앞 3문장/400자
        let kr = '', trErr = '';
        const aiBound = !!(env && env.AI);
        if (short && aiBound) {
          const r = await translateKo(env, short);
          kr = r.kr; trErr = r.err;
        }
        // ai / tr_error: 진단용 — AI 바인딩이 배포에 포함됐는지, 번역 에러가 뭔지
        return json({ description_kr: kr, description_en: short, ai: aiBound, tr_error: trErr });
      } catch (e) {
        return json({ description_kr: '', description_en: '', error: String((e && e.message) || e) });
      }
    }
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

      // 2) 상세(thing) 한 번에 여러 id — stats=1로 난이도(averageweight)까지
      const thingXml = await bggFetch('/xmlapi2/thing?id=' + ids.join(',') + '&stats=1');
      const results = [];
      const itemRe = /<item\b[^>]*\bid="(\d+)"[^>]*>([\s\S]*?)<\/item>/g;
      while ((m = itemRe.exec(thingXml))) {
        const id = m[1], b = m[2];
        const nameM = b.match(/<name\b[^>]*type="primary"[^>]*value="([^"]*)"/);
        const image = (b.match(/<image>([^<]*)<\/image>/) || [])[1] ||
                      (b.match(/<thumbnail>([^<]*)<\/thumbnail>/) || [])[1] || '';
        // 난이도: 평점 통계의 averageweight (소수 둘째 자리 반올림)
        const wM = b.match(/<averageweight\b[^>]*value="([^"]*)"/);
        const weight = wM && Number(wM[1]) > 0 ? Math.round(Number(wM[1]) * 100) / 100 : null;
        // 베스트 인원: 투표 요약 "Best with 2–3 players" → "2-3"
        const bwM = b.match(/<result\b[^>]*name="bestwith"[^>]*value="([^"]*)"/);
        let best = bwM ? decodeEntities(bwM[1]) : '';
        best = best.replace(/^Best with\s*/i, '').replace(/\s*players?\.?\s*$/i, '')
                   .replace(/[–—]/g, '-').trim();
        results.push({
          bgg_id: id,
          name_en: nameM ? decodeEntities(nameM[1]) : '',
          min_players: num(firstAttr(b, 'minplayers')),
          max_players: num(firstAttr(b, 'maxplayers')),
          playtime_min: num(firstAttr(b, 'playingtime') || firstAttr(b, 'maxplaytime')),
          image_url: image,
          weight,
          best_players: best || null,
        });
      }
      results.sort((a, b) => ids.indexOf(a.bgg_id) - ids.indexOf(b.bgg_id));
      return json({ results: results.slice(0, 6) });
    } catch (e) {
      // 실패해도 앱은 자체 도감으로 동작 — 에러는 메시지로만
      return json({ results: [], error: String((e && e.message) || e) }, 200);
    }
  },

  // Cron Trigger가 부르는 진입점 — Supabase가 잠들지 않게 하루 한 번 깨운다
  async scheduled(event, env, ctx) {
    ctx.waitUntil(keepAlive(env).then((r) => {
      // 실패해도 앱 동작에는 영향 없음. 로그는 대시보드 → Logs 에서 확인.
      console.log('keep-alive', r.ok ? 'OK' : 'FAIL', JSON.stringify(r));
    }));
  },
};

// Supabase에 가벼운 조회 RPC 한 번 — '활동 있음'으로 기록되어 자동 일시정지를 막는다.
// get_categories는 로그인 없이(anon) 호출되는 앱의 기본 조회라 부담이 거의 없다.
async function keepAlive(env) {
  const base = (env && env.SUPABASE_URL) || SUPABASE_URL_DEFAULT;
  const key = (env && env.SUPABASE_ANON_KEY) || SUPABASE_ANON_DEFAULT;
  const at = new Date().toISOString();
  try {
    const res = await fetch(base + '/rest/v1/rpc/get_categories', {
      method: 'POST',
      headers: {
        'apikey': key,
        'Authorization': 'Bearer ' + key,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ p_hub_id: 'H001' }),
    });
    const body = (await res.text()).slice(0, 200);
    // 200이면 정상. 프로젝트가 잠들어 있으면 5xx가 돌아온다(깨우는 건 대시보드에서).
    return { ok: res.status === 200, status: res.status, at, body };
  } catch (e) {
    return { ok: false, status: 0, at, error: String((e && e.message) || e) };
  }
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status, headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}
function num(v) { return v ? Number(v) : null; }
// 영→한 번역: ① 전용 번역 모델(m2m100) — 혼잡(3040)이면 잠깐 쉬고 재시도
//            ② 그래도 안 되면 범용 LLM(llama)에게 번역 지시로 폴백
async function translateKo(env, text) {
  let lastErr = '';
  for (let i = 0; i < 2; i++) {
    try {
      const out = await env.AI.run('@cf/meta/m2m100-1.2b',
        { text, source_lang: 'english', target_lang: 'korean' });
      const kr = (out && out.translated_text || '').trim();
      if (kr) return { kr, err: '' };
    } catch (e) {
      lastErr = String((e && e.message) || e);
      if (!/3040|capacity/i.test(lastErr)) break;      // 혼잡 외 에러는 재시도 무의미
      await new Promise((r) => setTimeout(r, 700));
    }
  }
  try {
    const out = await env.AI.run('@cf/meta/llama-3.1-8b-instruct', {
      messages: [
        { role: 'system', content: 'Translate the user\'s text into natural Korean. Output ONLY the Korean translation, no explanations.' },
        { role: 'user', content: text },
      ],
      max_tokens: 512,
    });
    const kr = (out && out.response || '').trim();
    if (kr) return { kr, err: '' };
  } catch (e2) {
    lastErr += ' / llama: ' + String((e2 && e2.message) || e2);
  }
  return { kr: '', err: lastErr };
}
// 앞 n문장(최대 maxLen자)만 — 요약칸에 넣을 만큼만 자른다
function firstSentences(text, n, maxLen) {
  const parts = String(text).split(/(?<=[.!?])\s+/).slice(0, n);
  let out = parts.join(' ').trim();
  if (out.length > maxLen) out = out.slice(0, maxLen).replace(/\s+\S*$/, '') + '…';
  return out;
}
function firstAttr(xml, tag, attr = 'value') {
  const m = xml.match(new RegExp('<' + tag + '\\b[^>]*\\b' + attr + '="([^"]*)"'));
  return m ? m[1] : null;
}
function decodeEntities(s) {
  return s
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&ndash;/g, '–').replace(/&mdash;/g, '—')
    .replace(/&#(\d+);/g, (_m, n) => String.fromCharCode(+n));
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
