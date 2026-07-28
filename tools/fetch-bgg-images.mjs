// ============================================================
//  BGG 박스아트 이미지 URL 한 번에 긁기 (로컬 실행용)
//
//  왜 로컬에서?  BGG는 데이터센터/Cloudflare Worker IP를 401로 막지만,
//  일반 가정용 IP + 브라우저 헤더면 대개 통과합니다. 이 스크립트를
//  '내 컴퓨터'에서 돌려 이미지 URL을 뽑아 UPDATE SQL을 만들어요.
//
//  실행:  node tools/fetch-bgg-images.mjs
//         (Node 18+ 필요 — 전역 fetch 사용)
//  결과:  supabase_seed_game_images.sql  파일 생성
//         → Supabase SQL Editor에 붙여넣고 Run 하면 도감 사진이 채워집니다.
//
//  참고:  이름은 supabase_seed_games.sql 의 name_en 과 똑같이 맞춰져 있어,
//         해당 게임의 image_url 이 비어 있을 때만 채웁니다(여러 번 안전).
// ============================================================

import { writeFileSync } from 'node:fs';

// supabase_seed_games.sql 와 동일한 영문명 목록(이 이름으로 검색 + 매칭)
const NAMES = [
  'Catan', 'Wingspan', 'Splendor', 'Ticket to Ride', 'Azul', 'Dominion',
  'Pandemic', 'Carcassonne', '7 Wonders', '7 Wonders Duel', 'Codenames',
  'Dixit', 'Love Letter', 'Skull King', 'Halli Galli', 'Rummikub', 'Ubongo',
  'Kingdomino', 'Terraforming Mars', 'Agricola', 'Stone Age', 'Puerto Rico',
  'Gloomhaven', 'Spirit Island', 'Dobble', 'Jungle Speed', 'Telestrations',
  'Clank!', 'Everdell', 'The Resistance: Avalon', 'One Night Ultimate Werewolf',
  'Ra', 'Modern Art', 'High Society', 'Tichu', 'Bang!', 'Cluedo', 'SET',
  'Blokus', 'Quoridor', 'Labyrinth', 'Jenga', 'Las Vegas', 'Lost Cities',
  'Sky Team', 'Cascadia', '6 Nimmt!', 'MicroMacro: Crime City',
];

const HEADERS = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
                '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  'Accept': 'application/xml,text/xml,*/*',
  'Accept-Language': 'en-US,en;q=0.9',
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function bggGet(path, tries = 5) {
  for (let i = 0; i < tries; i++) {
    const res = await fetch('https://boardgamegeek.com' + path, { headers: HEADERS });
    if (res.status === 200) return await res.text();
    if (res.status === 202 || res.status === 429) { await sleep(1500 + i * 700); continue; }
    throw new Error('HTTP ' + res.status);
  }
  throw new Error('응답 지연');
}

function sqlEsc(s) { return String(s).replace(/'/g, "''"); }

const updates = [];
for (const name of NAMES) {
  try {
    const searchXml = await bggGet('/xmlapi2/search?type=boardgame&query=' + encodeURIComponent(name));
    const idm = searchXml.match(/<item\b[^>]*\bid="(\d+)"/);
    if (!idm) { console.log('· 못 찾음:', name); await sleep(1200); continue; }
    const thingXml = await bggGet('/xmlapi2/thing?id=' + idm[1]);
    const img = (thingXml.match(/<image>([^<]*)<\/image>/) || [])[1] || '';
    if (img) {
      updates.push(
        `update public.games set image_url = '${sqlEsc(img)}' ` +
        `where name_en = '${sqlEsc(name)}' and coalesce(image_url,'') = '';`);
      console.log('✓', name);
    } else {
      console.log('· 이미지 없음:', name);
    }
  } catch (e) {
    console.log('× 실패:', name, '-', e.message);
  }
  await sleep(1300);   // BGG 예의상 요청 간격
}

const out =
  '-- BGG 박스아트 이미지 채우기 (tools/fetch-bgg-images.mjs 로 생성)\n' +
  '-- Supabase SQL Editor에 붙여넣고 Run. 여러 번 실행해도 안전.\n\n' +
  updates.join('\n') + '\n';
writeFileSync('supabase_seed_game_images.sql', out);
console.log(`\n완료: ${updates.length}개 → supabase_seed_game_images.sql`);
