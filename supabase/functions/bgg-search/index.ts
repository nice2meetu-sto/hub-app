// ============================================================
//  Supabase Edge Function: bgg-search
//  BGG(BoardGameGeek) XML API를 서버에서 대신 호출해 JSON으로 돌려줌
//  (브라우저는 CORS·XML 때문에 직접 못 부름 → 이 함수가 프록시)
//
//  배포: Supabase 대시보드 → Edge Functions → Create function
//        이름 'bgg-search' 로 만들고 이 파일 내용 전체 붙여넣기 → Deploy
//  호출: 앱에서 sb.functions.invoke('bgg-search', { body: { q: '검색어' } })
//  반환: { results: [{ bgg_id, name_en, min_players, max_players,
//                      playtime_min, image_url }] }
// ============================================================

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

function decodeEntities(s: string): string {
  return s
    .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"').replace(/&#(\d+);/g, (_m, n) => String.fromCharCode(+n));
}

// BGG는 가끔 202(처리 중)·429(속도 제한)를 주므로 짧게 재시도
async function bggFetch(url: string, tries = 4): Promise<string> {
  for (let i = 0; i < tries; i++) {
    const res = await fetch(url, { headers: { "User-Agent": "boardgamehub/1.0" } });
    if (res.status === 200) return await res.text();
    if (res.status === 202 || res.status === 429) {
      await new Promise((r) => setTimeout(r, 800 + i * 400));
      continue;
    }
    throw new Error("BGG HTTP " + res.status);
  }
  throw new Error("BGG 응답 지연");
}

function firstAttr(xml: string, tag: string, attr = "value"): string | null {
  const m = xml.match(new RegExp("<" + tag + "\\b[^>]*\\b" + attr + '="([^"]*)"'));
  return m ? m[1] : null;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const body = await req.json().catch(() => ({}));
    const query = String(body.q || "").trim();
    if (!query) return json({ results: [] });

    // 1) 검색 → boardgame id 목록(중복 제거, 최대 8개)
    const searchXml = await bggFetch(
      "https://boardgamegeek.com/xmlapi2/search?type=boardgame&query=" +
        encodeURIComponent(query),
    );
    const ids: string[] = [];
    const idRe = /<item\b[^>]*\bid="(\d+)"/g;
    let m: RegExpExecArray | null;
    while ((m = idRe.exec(searchXml)) && ids.length < 8) {
      if (!ids.includes(m[1])) ids.push(m[1]);
    }
    if (!ids.length) return json({ results: [] });

    // 2) 상세(한 번에 여러 id)
    const thingXml = await bggFetch(
      "https://boardgamegeek.com/xmlapi2/thing?id=" + ids.join(","),
    );
    const results: unknown[] = [];
    const itemRe = /<item\b[^>]*\bid="(\d+)"[^>]*>([\s\S]*?)<\/item>/g;
    while ((m = itemRe.exec(thingXml))) {
      const id = m[1], b = m[2];
      const nameM = b.match(/<name\b[^>]*type="primary"[^>]*value="([^"]*)"/);
      const image = (b.match(/<image>([^<]*)<\/image>/) || [])[1] ||
        (b.match(/<thumbnail>([^<]*)<\/thumbnail>/) || [])[1] || "";
      const minp = firstAttr(b, "minplayers");
      const maxp = firstAttr(b, "maxplayers");
      const time = firstAttr(b, "playingtime") || firstAttr(b, "maxplaytime");
      results.push({
        bgg_id: id,
        name_en: nameM ? decodeEntities(nameM[1]) : "",
        min_players: minp ? Number(minp) : null,
        max_players: maxp ? Number(maxp) : null,
        playtime_min: time ? Number(time) : null,
        image_url: image,
      });
    }
    // 검색 관련도 순서 유지
    results.sort((a: any, b: any) =>
      ids.indexOf(a.bgg_id) - ids.indexOf(b.bgg_id));
    return json({ results: results.slice(0, 6) });
  } catch (e) {
    // 실패해도 앱은 자체 도감으로 동작 — 에러는 메시지로만
    return json({ results: [], error: String((e as Error).message || e) });
  }
});
