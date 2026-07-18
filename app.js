// ============================================================
//  설정: Supabase 프로젝트 URL / anon public key
//  (README의 "HTML 키 교체" 단계 참고)
// ============================================================
const SUPABASE_URL = "https://pqnvfcxstfyjsufdrgcm.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBxbnZmY3hzdGZ5anN1ZmRyZ2NtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQzNDM2OTEsImV4cCI6MjA5OTkxOTY5MX0.drHD0rkKgKuzY2h4T0CW4Mo68KqW6k3nVOGJGvGnfHU";

// 카테고리 탭 로드 실패 시 폴백
const DEFAULT_CATEGORIES_FALLBACK =
  ['전략', '마피아', '파티게임', '트릭테이킹', '1대1 게임', '카드게임', '경매게임', '협력게임'];

// Supabase 클라이언트
const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// ===== 전역 상태 =====
const state = {
  hub: null,           // {hub_id, name, invite?} — 현재 허브 컨텍스트
  user: null,          // {player_id, name, role}
  games: [],
  plays: [],
  players: [],
  gameFilter: { category: null, playerCount: null, weight: null, search: '' },
  myTab: 'overview',
  myGameSort: 'winrate',
  authMode: 'login',   // 'login' | 'signup'
};

// ===== API (Supabase) =====
// 기존 Apps Script api(action, params) 인터페이스를 그대로 유지하는 호환 레이어.
// 조회는 RPC/뷰(anon 허용), 쓰기는 전부 PIN을 검증하는 Postgres RPC로 처리.
function acErr(error) { return (error && (error.message || error.hint)) || '요청 실패'; }

// 현재 허브 ID (없으면 기본 허브 — 개편 전 사용자 하위호환)
function hubId() { return state.hub ? state.hub.hub_id : 'H001'; }

async function sbrpc(fn, args = {}) {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw new Error(acErr(error));
  return data;
}

// player_id·pin이 payload 안에 들어있는 쓰기(addGame/addPlay)용
async function sbWriteWithPayload(fn, payloadStr) {
  const pl = JSON.parse(payloadStr);
  const { player_id, pin, ...rest } = pl;
  return sbrpc(fn, { p_player_id: player_id, p_pin: pin, p_payload: rest });
}

async function api(action, params = {}) {
  const P = params;
  switch (action) {
    case 'login': {
      // v2: 실패 시 예외 대신 {ok:false, error}를 반환(PIN 시도 잠금 카운터 유지용)
      const d = await sbrpc('login', { p_name: P.name, p_pin: P.pin, p_hub_id: hubId() });
      if (d && d.ok === false) throw new Error(d.error || '로그인에 실패했습니다.');
      return d;
    }
    case 'signup':         return sbrpc('signup', { p_name: P.name, p_pin: P.pin,
                             p_hub_id: hubId(), p_invite: (state.hub && state.hub.invite) || null });
    case 'getGames':       return sbrpc('get_games', { p_hub_id: hubId() });
    case 'getPlays':       return sbrpc('get_plays', { p_hub_id: hubId() });
    case 'getPlayerStats': return sbrpc('get_player_stats', { p_player_id: P.playerId });
    case 'getMyRatings':   return sbrpc('get_my_ratings',   { p_player_id: P.playerId });
    case 'getPlayers': {
      const { data, error } = await sb.from('players_public')
        .select('player_id,name,role,status,linked').eq('hub_id', hubId()).order('player_id');
      if (error) throw new Error(acErr(error));
      return (data || []).filter(p => p.status !== 'left');
    }
    case 'getCategories': {
      const { data, error } = await sb.from('categories').select('name')
        .order('sort_order').order('name');
      if (error || !data || !data.length) return DEFAULT_CATEGORIES_FALLBACK;
      return data.map(r => r.name);
    }
    case 'saveRating':
      return sbrpc('save_rating', {
        p_player_id: P.playerId, p_pin: P.pin, p_game_id: P.gameId, p_rating: Number(P.rating)
      });
    case 'saveReview':
      return sbrpc('save_review', {
        p_player_id: P.playerId, p_pin: P.pin, p_game_id: P.gameId, p_review: P.review || ''
      });
    case 'saveMemo':
      return sbrpc('save_memo', {
        p_player_id: P.playerId, p_pin: P.pin, p_game_id: P.gameId, p_memo: P.memo || ''
      });
    case 'getReviews': return sbrpc('get_reviews', { p_game_id: P.gameId, p_hub_id: hubId() });
    case 'getReviewsAll': return sbrpc('get_reviews_all', { p_game_id: P.gameId });
    // ===== 관리자 페이지 전용 =====
    case 'adminGetPlayers':
      return sbrpc('admin_get_players', { p_player_id: P.playerId, p_pin: P.pin });
    case 'adminUpdatePin':
      return sbrpc('admin_update_pin', { p_player_id: P.playerId, p_pin: P.pin, p_target_id: P.targetId, p_new_pin: P.newPin });
    case 'adminDeleteGame':
      return sbrpc('admin_delete_game', { p_player_id: P.playerId, p_pin: P.pin, p_game_id: P.gameId });
    case 'getCategoriesFull': {
      const { data, error } = await sb.from('categories').select('name,sort_order')
        .order('sort_order').order('name');
      if (error) throw new Error(acErr(error));
      return data || [];
    }
    case 'addPlay':   return sbWriteWithPayload('add_play', P.payload);
    case 'addGame':   return sbWriteWithPayload('add_game', P.payload);
    case 'updatePlay':
      return sbrpc('update_play', { p_player_id: P.playerId, p_pin: P.pin, p_payload: JSON.parse(P.payload) });
    case 'deletePlay':
      return sbrpc('delete_play', { p_player_id: P.playerId, p_pin: P.pin, p_session_id: P.sessionId });
    case 'updateGame':
      return sbrpc('update_game', { p_player_id: P.playerId, p_pin: P.pin, p_payload: JSON.parse(P.payload) });
    // ===== 멀티허브 / 이메일 계정 =====
    case 'hubByInvite':   return sbrpc('hub_by_invite', { p_code: P.code });
    case 'getHub':        return sbrpc('get_hub', { p_hub_id: hubId() });
    case 'createHub':     return sbrpc('create_hub', { p_name: P.name, p_kind: P.kind || 'hub' });
    case 'loginLinked':   return sbrpc('login_linked', { p_hub_id: hubId() });
    case 'searchCatalog': return sbrpc('search_catalog', { p_hub_id: hubId(), p_term: P.term });
    case 'myHubs':        return sbrpc('my_hubs');
    case 'hubGetInvite':  return sbrpc('hub_get_invite', { p_hub_id: hubId() });
    case 'linkPlayer':    return sbrpc('link_player', { p_hub_id: hubId(), p_player_id: P.playerId, p_pin: P.pin });
    case 'unlinkPlayer':  return sbrpc('unlink_player', { p_player_id: P.playerId });
    case 'getMyLinks':    return sbrpc('get_my_links');
    case 'getMyStatsAll': return sbrpc('get_my_stats_all');
    case 'getMyPlaysAll': return sbrpc('get_my_plays_all');
    case 'getMyGamesAll': return sbrpc('get_my_games_all');
    case 'hubRename':     return sbrpc('hub_rename', { p_hub_id: hubId(), p_name: P.name });
    case 'hubRotateInvite': return sbrpc('hub_rotate_invite', { p_hub_id: hubId() });
    default: throw new Error('Unknown action: ' + action);
  }
}

function showLoader(txt) {
  const l = document.getElementById('loader');
  l.querySelector('.ltxt').textContent = txt || '불러오는 중…';
  l.classList.add('show');
}
function hideLoader() { document.getElementById('loader').classList.remove('show'); }

let toastTimer;
function toast(msg, isErr) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.className = isErr ? 'err show' : 'show';
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.className = ''; }, 2600);
}

// ===== 오버레이 히스토리 스택 (하드웨어/브라우저 뒤로가기 대응) =====
// 오버레이를 열 때 openOverlay(hide)로 등록하면 히스토리 항목이 1개 쌓이고,
// 뒤로가기(popstate) 또는 closeOverlay()로 맨 위 오버레이부터 하나씩 닫힘.
const _overlays = [];
function openOverlay(hideFn) {
  _overlays.push(hideFn);
  try { history.pushState({ ov: _overlays.length }, ''); } catch (e) {}
}
function closeOverlay() {   // UI 닫기 버튼/백드롭에서 호출 → 히스토리와 동기화
  if (!_overlays.length) return;
  try { history.back(); } catch (e) { const h = _overlays.pop(); if (h) h(); }
}
function replaceTopOverlay(hideFn) {  // 시트→상세 등 같은 depth로 화면 교체
  if (_overlays.length) _overlays[_overlays.length - 1] = hideFn;
  else openOverlay(hideFn);
}
window.addEventListener('popstate', () => {
  if (_overlays.length) { const h = _overlays.pop(); if (h) { try { h(); } catch (e) {} } }
});
// detail-overlay(공용 시트)는 내용만 바뀌며 여러 번 열리므로, 처음 열 때만 히스토리 push
function showDetailSheet() {
  const el = document.getElementById('detail-overlay');
  const wasOpen = el.classList.contains('show');
  el.classList.add('show');
  if (!wasOpen) openOverlay(() => el.classList.remove('show'));
}

// ===== 유틸 =====
function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, c =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
function fmtDate(d) {
  if (!d) return '';
  const s = String(d).substring(0, 10);
  const parts = s.split('-');
  if (parts.length === 3) return `${parts[1]}.${parts[2]}`;
  return s;
}
function thumb(url, cls) {
  // referrerpolicy=no-referrer: BGG 이미지 CDN의 핫링크 차단(403) 회피용.
  // 로드 실패 시 img를 제거하면 뒤의 🎲 플레이스홀더가 그대로 보임.
  const img = url
    ? `<img src="${esc(url)}" loading="lazy" referrerpolicy="no-referrer" alt="" onerror="this.remove()"/>`
    : '';
  return `<div class="thumb ${cls}">${img}</div>`;
}
function gameById(id) { return state.games.find(g => g.game_id === id); }

// ===== 네비게이션 =====
function switchView(name) {
  ['play', 'games', 'my'].forEach(v => {
    document.getElementById('view-' + v).classList.toggle('active', v === name);
    document.getElementById('tab-' + v).classList.toggle('on', v === name);
  });
  if (name === 'my') renderMy();
  if (name === 'games') renderGames();
  if (name === 'play') renderPlay();
}

// ============================================================
//  데이터 로드
// ============================================================
async function loadCore(manual) {
  if (!state.hub) return;   // 허브 미선택 상태(시작 화면)
  showLoader(manual ? '업데이트 중…' : '데이터 불러오는 중…');
  try {
    // getCategories는 옛 백엔드엔 없을 수 있으므로 실패해도 기본값 유지
    const [games, plays, players, categories] = await Promise.all([
      api('getGames'), api('getPlays'), api('getPlayers'),
      api('getCategories').catch(() => null)
    ]);
    state.games = games;
    state.plays = plays;
    state.players = players;
    if (Array.isArray(categories) && categories.length) CATEGORIES = categories;
    // 개인 통계/평점 캐시 무효화 → 다음 렌더 시 새로 로드
    state._myStats = null; state._myStatsHub = null; state._myStatsAll = null; state._myStatsBy = null;
    state._myRatings = null;
    state._myRatingsPromise = null;
    // 기록장: 플레이·게임 탭도 전 허브 통합으로 — 렌더 전에 통합 데이터 준비
    state._myAllPlays = null; state._myAllGames = null;
    if (isPersonalHub(state.hub)) {
      try { await loadMyLinks(); } catch (e) {}
      if (hubIntegrated()) {
        try {
          const [ap, ag] = await Promise.all([api('getMyPlaysAll'), api('getMyGamesAll')]);
          state._myAllPlays = ap || [];
          state._myAllGames = ag || [];
        } catch (e) { /* 미지원(마이그레이션 전) → 기록장 자체 데이터로 표시 */ }
      }
    }
    renderPlay();
    renderGames();
    if (state.user && document.getElementById('view-my').classList.contains('active')) renderMy();
    if (manual) toast('최신 데이터로 업데이트했어요.');
  } catch (e) {
    toast('연결 실패: ' + e.message, true);
  } finally {
    hideLoader();
  }
}

// 🔄 수동 업데이트 버튼용
function refreshAll() { loadCore(true); }

// ============================================================
//  VIEW: 플레이
// ============================================================
function setPlayScope(scope) {
  state.playScope = scope;
  renderPlay();
}

function renderPlay() {
  const nowYM = new Date().toISOString().substring(0, 7);
  const scope = state.playScope || 'month';
  // 기록장 통합이면 전 허브의 내 세션·게임이 소스
  const plays = hubPlays();
  const gamesSrc = hubGamesList();

  // game_id -> category 맵
  const catOf = {};
  gamesSrc.forEach(g => { catOf[g.game_id] = g.category || '기타'; });
  state.games.forEach(g => { if (!catOf[g.game_id]) catOf[g.game_id] = g.category || '기타'; });

  // 게임별 + 카테고리별 플레이 횟수 집계(전체/이번 달)
  const agg = {};       // gid -> {id, name, image, all, month}
  const catAgg = {};    // category -> {all, month}
  let totalMonth = 0;
  plays.forEach(s => {
    const isMonth = String(s.play_date).substring(0, 7) === nowYM;
    if (isMonth) totalMonth++;
    const gid = s.game_id || s.game_name;
    if (!agg[gid]) agg[gid] = { id: s.game_id, name: s.game_name, image: s.game_image, all: 0, month: 0 };
    agg[gid].all++;
    if (isMonth) agg[gid].month++;
    const cat = catOf[s.game_id] || '기타';
    if (!catAgg[cat]) catAgg[cat] = { all: 0, month: 0 };
    catAgg[cat].all++;
    if (isMonth) catAgg[cat].month++;
  });
  const totalAll = plays.length;

  // 최고 평점 = 평점(club_rating: 통합이면 전체 평점)이 가장 높은 게임
  let topGame = '-', topRating = -1, topCnt = -1, topId = '';
  gamesSrc.forEach(g => {
    if (g.club_rating == null) return;
    const r = Number(g.club_rating), c = Number(g.rating_count || 0);
    if (r > topRating || (r === topRating && c > topCnt)) {
      topRating = r; topCnt = c; topGame = g.name_kr || g.name_en || g.game_id; topId = g.game_id;
    }
  });
  const topClick = topId ? `style="cursor:pointer;" onclick="showGameInfo('${topId}')"` : '';

  // 1) 누적 카드를 맨 왼쪽에
  document.getElementById('play-summary').innerHTML = `
    <div class="stat ${scope === 'all' ? 'hero' : ''}" style="cursor:pointer;" onclick="setPlayScope('all')">
      <div class="num">${totalAll}</div><div class="lbl">누적 플레이</div></div>
    <div class="stat ${scope === 'month' ? 'hero' : ''}" style="cursor:pointer;" onclick="setPlayScope('month')">
      <div class="num">${totalMonth}</div><div class="lbl">이번 달 플레이</div></div>
    <div class="stat" ${topClick}><div class="num" id="play-top-rated" style="font-size:14px;padding-top:6px;max-width:100%;">${esc(topGame)}</div><div class="lbl">최고 평점</div></div>`;
  fitText(document.getElementById('play-top-rated'), 14, 9);

  // 3) 카테고리별 플레이 횟수 세로 막대그래프(선택 범위 반영)
  const catList = Object.keys(catAgg)
    .map(c => ({ cat: c, count: scope === 'month' ? catAgg[c].month : catAgg[c].all }))
    .filter(c => c.count > 0)
    .sort((a, b) => b.count - a.count);
  const catEl = document.getElementById('play-catchart');
  if (catList.length) {
    const maxCat = Math.max(...catList.map(c => c.count));
    catEl.innerHTML = `<div class="card">
      <div class="section-title" style="margin-top:0;">카테고리별 플레이 횟수 ${scope === 'month' ? '(이번 달)' : '(누적)'}</div>
      <div class="barchart">${catList.map(c => {
        const h = Math.max(4, Math.round(c.count / maxCat * 74));
        return `<div class="bar-col">
          <div class="bc">${c.count}</div>
          <div class="bar" style="height:${h}px;"></div>
          <div class="bm">${esc(c.cat)}</div>
        </div>`;
      }).join('')}</div>
    </div>`;
  } else {
    catEl.innerHTML = '';
  }

  document.getElementById('play-list-title').textContent =
    scope === 'month' ? '이번 달 게임별 플레이 횟수' : '게임별 플레이 횟수';

  // 게임별 순위(선택 범위 기준, 횟수 내림차순). 평점은 매 렌더 시 state.games에서 조회 → 새 게임에도 자동 반영
  const ginfo = {};
  gamesSrc.forEach(g => { ginfo[g.game_id] = g; });
  const list = Object.keys(agg)
    .map(gid => {
      const gm = ginfo[agg[gid].id] || gameById(agg[gid].id) || {};
      return {
        id: agg[gid].id, name: agg[gid].name, image: agg[gid].image,
        count: scope === 'month' ? agg[gid].month : agg[gid].all,
        club_rating: gm.club_rating, rating_count: gm.rating_count, review_count: gm.review_count
      };
    })
    .filter(g => g.count > 0)
    .sort((a, b) => b.count - a.count || String(a.name).localeCompare(String(b.name)));

  const el = document.getElementById('play-list');
  if (!list.length) {
    el.innerHTML = `<div class="empty"><div class="big">🎲</div>${scope === 'month' ? '이번 달 플레이 기록이 없어요.' : '아직 플레이 기록이 없어요.'}<br/>+ 버튼으로 결과를 추가해보세요.</div>`;
    return;
  }
  const ranks = competitionRanks(list, g => g.count);   // 동일 판수 = 공동 순위
  el.innerHTML = list.map((g, i) => `
    <div class="session" style="display:flex;align-items:center;gap:12px;position:relative;${g.id ? 'cursor:pointer;' : ''}" ${g.id ? `onclick="showGameInfo('${g.id}')"` : ''}>
      ${g.id ? `<div class="gcard-actions br">${reviewPillHtml(g.id, g.review_count)}</div>` : ''}
      <div class="grow-rank">${ranks[i]}</div>
      ${thumb(g.image, 'session-thumb')}
      <div style="flex:1;min-width:0;">
        <div class="g-name" style="font-weight:700;">${esc(g.name)}</div>
        <div class="g-meta">${g.count}판 · ${clubRatingMini(g.club_rating, g.rating_count)}</div>
      </div>
    </div>`).join('');
}

// 동점 공동 순위: 정렬된 배열에서 기준값이 같으면 같은 순위(1,2,2,2,5 방식)
function competitionRanks(list, keyFn) {
  const ranks = [];
  list.forEach((item, i) => {
    ranks.push(i > 0 && keyFn(item) === keyFn(list[i - 1]) ? ranks[i - 1] : i + 1);
  });
  return ranks;
}

// 칸 너비에 맞게 글씨 크기를 줄임(한 줄 유지, 넘치면 min까지 축소)
function fitText(el, max, min) {
  if (!el) return;
  el.style.whiteSpace = 'nowrap';
  el.style.overflow = 'hidden';
  el.style.textOverflow = 'ellipsis';
  requestAnimationFrame(() => {
    const avail = el.clientWidth;
    if (avail <= 0) return;
    let fs = max;
    el.style.fontSize = fs + 'px';
    while (el.scrollWidth > avail && fs > min) { fs -= 0.5; el.style.fontSize = fs + 'px'; }
  });
}

// 게임 카드처럼 컴팩트한 평점 표시(★ 8.5 (3) / 평가없음)
function clubRatingMini(rating, count) {
  return (rating != null)
    ? `<span style="color:var(--win);">★</span> <b style="color:var(--main);">${Number(rating).toFixed(1)}</b> <small class="muted">(${count || 0})</small>`
    : `<span class="muted">★ 평가없음</span>`;
}

// 게임 기본 정보 블록(재사용): 썸네일 + 이름/분류 + 메타 + 우리Hub평점 + 요약
function gameInfoInnerHtml(g) {
  const meta = [];
  if (g.min_players || g.max_players) {
    const mn = g.min_players || '?', mx = g.max_players || '?';
    meta.push(`👥 ${mn}${mx !== mn ? '~' + mx : ''}명`);
  }
  if (g.playtime_min) meta.push(`⏱ ${g.playtime_min}분`);
  if (g.weight) meta.push(`🧠 ${Number(g.weight).toFixed(2)}`);

  const ratingLbl = hubIntegrated() ? '전체 평점' : '우리Hub평점';
  const club = g.club_rating != null
    ? `<span class="rate-club"><span class="star">★</span> ${g.club_rating.toFixed(1)}</span> <small class="muted">${ratingLbl} (평가 ${g.rating_count || 0})</small>`
    : `<span class="muted">${ratingLbl} 없음</span>`;

  return `
    <div style="display:flex;gap:12px;align-items:center;margin-bottom:12px;">
      ${thumb(g.image_url, 'gcard-img')}
      <div style="flex:1;min-width:0;">
        <div style="font-weight:800;font-size:17px;">${esc(g.name_kr || g.name_en)}
          ${g.category ? `<span class="badge" style="margin-left:6px;">${esc(g.category)}</span>` : ''}</div>
        ${g.name_en && g.name_kr ? `<div class="muted" style="font-size:12px;margin-top:2px;">${esc(g.name_en)}</div>` : ''}
      </div>
    </div>
    <div class="gcard-meta" style="margin-bottom:5px;">${meta.map(m => `<span>${m}</span>`).join('')}</div>
    <div style="margin-bottom:12px;">${club}</div>
    <div style="white-space:pre-wrap;font-size:13px;color:#444;">${g.summary_kr ? esc(g.summary_kr) : '<span class="muted">등록된 요약이 없습니다.</span>'}</div>`;
}

// 게임 정보 보기(읽기 전용 시트) — 기록장 통합이면 도감(전체 평점) 기준
function showGameInfo(gameId) {
  const g = hubIntegrated()
    ? (myGameInfo(gameId, 'all') || gameById(gameId))
    : gameById(gameId);
  if (!g) { toast('게임 정보를 찾을 수 없습니다.', true); return; }
  document.getElementById('detail-body').innerHTML = gameInfoInnerHtml(g);
  showDetailSheet();
}

// MY-게임기록 펼침: 게임 기본 정보 + 일자별 플레이 요약(일자·승패·내점수·최고점수)
function myGameDetailHtml(g) {
  // 기록장 통합 범위에서는 전 허브의 내 세션 합산
  const mine = myScopeSessions()
    .filter(s => s.game_id === g.game_id && s.participants.some(p => isMyPid(p.player_id)))
    .slice()
    .sort((a, b) => String(b.play_date).localeCompare(String(a.play_date)));

  let rows;
  if (!mine.length) {
    rows = `<div class="muted" style="font-size:12px;padding:6px 2px;">플레이 기록이 없어요.</div>`;
  } else {
    rows = mine.map(s => {
      const me = s.participants.find(p => isMyPid(p.player_id)) || {};
      const scores = s.participants
        .map(p => p.score == null || p.score === '' ? null : Number(p.score))
        .filter(v => v != null && !isNaN(v));
      const top = scores.length ? Math.max(...scores) : null;
      const myScore = (me.score == null || me.score === '') ? null : me.score;
      const win = me.is_win;
      return `<div class="pdate-row" onclick="showSessionDetail('${esc(s.session_id)}','${esc(s.hub_id || '')}')">
        <span class="pdate-d">${esc(String(s.play_date).substring(0, 10))}</span>
        <span class="pdate-wl ${win ? 'win' : 'loss'}">${win ? '승 👑' : '패 🥈'}</span>
        <span class="pdate-s">나 ${myScore == null ? '-' : esc(myScore) + '점'}</span>
        <span class="pdate-s muted">최고 ${top == null ? '-' : top + '점'}</span>
        <span class="pdate-arrow">›</span>
      </div>`;
    }).join('');
  }

  // 헤더(게임 정보 + 요약 제목)는 상단 고정, 아래 일자별 리스트만 스크롤
  return `<div class="mgstat-head">
      <div class="gcard-top" style="position:relative;">
        ${gameCardTopHtml(g, true)}
        <button class="gcard-detail-btn" onclick="openGameDetail('${g.game_id}')">상세</button>
      </div>
      <div class="pdate-head">📅 일자별 플레이 요약</div>
    </div>
    <div class="pdate-list">${rows}</div>`;
}

// 단일 세션 세부 기록(참가자 전체) 보기 — MY 플레이 기록과 동일 형식
// hub 인자: 통합 범위에서 세션 ID가 허브 간 겹칠 수 있어 허브까지 지정
function showSessionDetail(sid, hub) {
  const s = myScopeSessions().find(x => String(x.session_id) === String(sid)
        && (!hub || x.hub_id === hub))
    || state.plays.find(x => String(x.session_id) === String(sid));
  if (!s) { toast('플레이 기록을 찾을 수 없습니다.', true); return; }
  const dur = s.duration_min ? ` · ${s.duration_min}분` : '';
  const parts = s.participants.map(p => `
    <div class="prow ${p.is_win ? 'win' : ''}">
      <span class="pname">${esc(p.name)}${p.is_win ? '<span class="crown">👑</span>' : ''}</span>
      <span class="pscore">${p.score == null || p.score === '' ? '' : esc(p.score) + '점'}</span>
    </div>`).join('');
  document.getElementById('detail-body').innerHTML = `
    <div class="session-head" style="margin-bottom:10px;">
      ${thumb(s.game_image, 'session-thumb')}
      <div style="flex:1;min-width:0;">
        <div class="g-name">${esc(s.game_name)}</div>
        <div class="g-meta">${esc(String(s.play_date).substring(0, 10))}${dur} · ${s.participants.length}명${
          s.hub_name && state.hub && s.hub_id !== state.hub.hub_id
            ? ` · <span style="color:var(--main);">${esc(s.hub_name)}</span>` : ''}</div>
      </div>
    </div>
    <div class="participants">${parts}</div>
    <button class="btn ghost sm" style="margin-top:14px;width:100%;" onclick="showGameInfoBackFromSession('${esc(s.game_id)}')">‹ 게임 정보로</button>`;
  showDetailSheet();
}

// 전체기록의 게임별 통계 카드 탭 → 게임 정보 + 일자별 플레이 요약
async function showMyGameStat(gameId) {
  await ensureMyAllData();
  const g = myGameInfo(gameId);
  if (!g) { toast('게임 정보를 찾을 수 없습니다.', true); return; }
  document.getElementById('detail-body').innerHTML = myGameDetailHtml(g);
  showDetailSheet();
}

// 세션 세부 → 게임 상세(일자별 요약 포함)로 돌아가기
function showGameInfoBackFromSession(gameId) {
  const g = myGameInfo(gameId);
  if (!g) { showGameInfo(gameId); return; }
  document.getElementById('detail-body').innerHTML = myGameDetailHtml(g);
  showDetailSheet();
}

// ============================================================
//  게임 상세 페이지 (MY-게임기록 카드 → 게임명 탭)
// ============================================================
// 이 게임을 함께 플레이한 플레이어별 통계(나 포함, 게스트 포함)
function gamePlayerStats(gid) {
  const map = new Map();
  myScopeSessions().forEach(s => {
    if (s.game_id !== gid) return;
    // '함께 플레이한 기록': 내가 참가한 세션만 집계 → 같이 한 사람의
    // 통계도 나와 함께한 판만으로 계산됨 (통합 범위면 전 허브)
    if (state.user && !s.participants.some(p => isMyPid(p.player_id))) return;
    s.participants.forEach(p => {
      // 통합 범위: 허브마다 다른 내 player_id를 '나' 한 줄로 합침
      const key = isMyPid(p.player_id) ? 'me'
        : (p.player_id ? ('m:' + p.player_id) : ('g:' + (p.name || '')));
      let r = map.get(key);
      if (!r) { r = { name: p.name || '(이름없음)', wins: 0, games: 0, scores: [], isMe: key === 'me' }; map.set(key, r); }
      r.games += 1;
      if (p.is_win) r.wins += 1;
      const sc = (p.score == null || p.score === '') ? null : Number(p.score);
      if (sc != null && !isNaN(sc)) r.scores.push(sc);
    });
  });
  return Array.from(map.values()).map(r => ({
    name: r.name, isMe: r.isMe, wins: r.wins, games: r.games,
    winrate: r.games ? Math.round(r.wins / r.games * 1000) / 10 : 0,
    avg: r.scores.length ? Math.round(r.scores.reduce((a, b) => a + b, 0) / r.scores.length * 10) / 10 : null,
    best: r.scores.length ? Math.max(...r.scores) : null
  }));
}

// 추이선: 점들을 직선으로 연결한 path 생성
function smoothPath(pts) {
  if (!pts.length) return '';
  if (pts.length === 1) { const p = pts[0]; return `M${(p.x - 0.1).toFixed(1)},${p.y.toFixed(1)} L${(p.x + 0.1).toFixed(1)},${p.y.toFixed(1)}`; }
  return `M${pts[0].x.toFixed(1)},${pts[0].y.toFixed(1)}` +
    pts.slice(1).map(p => ` L${p.x.toFixed(1)},${p.y.toFixed(1)}`).join('');
}

// 상단만 둥근 막대 path
function topRoundRect(x, yy, w, h, r) {
  r = Math.max(0, Math.min(r, w / 2, h));
  return `M${x.toFixed(1)},${(yy + h).toFixed(1)} L${x.toFixed(1)},${(yy + r).toFixed(1)} Q${x.toFixed(1)},${yy.toFixed(1)} ${(x + r).toFixed(1)},${yy.toFixed(1)} L${(x + w - r).toFixed(1)},${yy.toFixed(1)} Q${(x + w).toFixed(1)},${yy.toFixed(1)} ${(x + w).toFixed(1)},${(yy + r).toFixed(1)} L${(x + w).toFixed(1)},${(yy + h).toFixed(1)} Z`;
}

function gameChartSvg(sessions) {
  const pts = sessions.map(s => {
    const scores = s.participants.map(p => (p.score == null || p.score === '') ? null : Number(p.score)).filter(v => v != null && !isNaN(v));
    const me = s.participants.find(p => isMyPid(p.player_id)) || {};
    const mine = (me.score == null || me.score === '') ? null : Number(me.score);
    return { date: String(s.play_date).substring(5, 10), best: scores.length ? Math.max(...scores) : null, mine, sid: s.session_id, hub: s.hub_id || '' };
  });
  if (!pts.length) return `<div class="muted" style="font-size:12px;padding:10px 2px;text-align:center;">점수 기록이 없어요.</div>`;
  const W = 340, H = 116, padT = 24, padB = 20, padX = 8;
  const plotH = H - padT - padB, baseY = padT + plotH;
  const n = pts.length, slot = (W - padX * 2) / n;
  const maxV = Math.max(1, ...pts.map(p => Math.max(p.best || 0, p.mine || 0)));
  const y = v => padT + plotH * (1 - v / maxV);
  const cx = i => padX + slot * (i + 0.5);
  const bw = Math.min(slot * 0.56, 26);
  let bars = '', labels = '';
  const line = [];
  pts.forEach((p, i) => {
    const x = cx(i);
    if (p.best != null) {
      const by = y(p.best);
      bars += `<path d="${topRoundRect(x - bw / 2, by, bw, baseY - by, 5)}" fill="var(--main)" style="cursor:pointer;" onclick="showBarSession('${esc(p.sid)}','${esc(p.hub)}')"/>`;
      labels += `<text x="${x.toFixed(1)}" y="${(by - 8).toFixed(1)}" text-anchor="middle" font-size="9.5" fill="#8a86a8" style="pointer-events:none;">${p.best}</text>`;
    }
    if (p.mine != null) {
      const my = y(p.mine);
      line.push({ x, y: my });
      labels += `<text x="${x.toFixed(1)}" y="${(my + 13).toFixed(1)}" text-anchor="middle" font-size="9.5" font-weight="700" fill="#d9d5f3" style="pointer-events:none;">${p.mine}</text>`;
    }
    labels += `<text x="${x.toFixed(1)}" y="${(H - 5).toFixed(1)}" text-anchor="middle" font-size="9" fill="#9a97a8" style="pointer-events:none;">${p.date}</text>`;
  });
  const curve = smoothPath(line);
  const path = curve ? `<path d="${curve}" fill="none" stroke="#d9d5f3" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="pointer-events:none;"/>` : '';
  return `<svg viewBox="0 0 ${W} ${H}" width="100%" style="display:block;max-height:${H}px;margin:0 auto;">${bars}${path}${labels}</svg>`;
}

async function openGameDetail(gameId) {
  await ensureMyAllData();   // 통합 범위면 전 허브 데이터 준비
  const el = document.getElementById('detail-overlay');
  const fromSheet = el.classList.contains('show');   // 공용 시트에서 열렸는지
  el.classList.remove('show');
  state._gd = { gid: gameId, col: 'winrate', dir: 'desc' };
  renderGameDetail();
  const hideFn = () => document.getElementById('gd-page').classList.remove('show');
  // 시트→상세는 같은 depth로 교체, 카드에서 바로 열면 새 항목 push
  if (fromSheet && _overlays.length) replaceTopOverlay(hideFn);
  else openOverlay(hideFn);
}

function closeGameDetail() { closeOverlay(); }

// 차트 막대 클릭 → 그날 참가자 점수 표
function showBarSession(sid, hub) {
  const s = myScopeSessions().find(x => String(x.session_id) === String(sid)
        && (!hub || x.hub_id === hub))
    || state.plays.find(x => String(x.session_id) === String(sid));
  if (!s) return;
  const rows = s.participants.slice().sort((a, b) => {
    const av = (a.score == null || a.score === '') ? -Infinity : Number(a.score);
    const bv = (b.score == null || b.score === '') ? -Infinity : Number(b.score);
    return bv - av;
  }).map(p => {
    const isMe = !!isMyPid(p.player_id);
    return `<tr class="${isMe ? 'me' : ''}">
      <td>${esc(p.name)}${p.is_win ? ' 👑' : ''}${isMe ? ' <span style="color:var(--main);font-size:10px;">나</span>' : ''}</td>
      <td style="text-align:right;">${p.score == null || p.score === '' ? '-' : esc(p.score) + '점'}</td>
    </tr>`;
  }).join('');
  document.getElementById('gd-session-card').innerHTML = `
    <h3>${esc(String(s.play_date).substring(0, 10))} 기록</h3>
    <div class="muted" style="font-size:12px;">${esc(s.game_name)} · ${s.participants.length}명</div>
    <table class="gd-table" style="margin-top:10px;"><tbody>${rows}</tbody></table>
    <button class="btn ghost sm" style="margin-top:14px;width:100%;" onclick="closeBarSession()">닫기</button>`;
  document.getElementById('gd-session-overlay').classList.add('show');
  openOverlay(() => document.getElementById('gd-session-overlay').classList.remove('show'));
}
function closeBarSession() { closeOverlay(); }

// 후기 버튼 HTML: 후기 개수 > 0 이면 연하고 작게 (N) 표시, 0이면 개수 없이
function reviewPillHtml(gameId, count, extraClass) {
  const n = Number(count) || 0;
  const cnt = n > 0 ? ` <small style="font-weight:500;color:var(--text-sub);">(${n})</small>` : '';
  return `<button class="gcard-pill review${extraClass ? ' ' + extraClass : ''}" onclick="event.stopPropagation(); openReviews('${gameId}')">💬${cnt}</button>`;
}

// 게임 탭: [후기] 버튼 → 사람들이 남긴 후기(닉네임 + 코멘트)
// 기록장 통합이면 모든 허브의 후기를 모아 표시
async function openReviews(gameId) {
  const g = hubIntegrated()
    ? (myGameInfo(gameId, 'all') || gameById(gameId))
    : gameById(gameId);
  const title = g ? esc(g.name_kr || g.name_en) : '';
  const head = `<h2 style="font-size:20px;font-weight:900;margin:2px 2px 12px;">💬<span class="muted" style="font-size:13px;font-weight:500;">· ${title}</span></h2>`;
  const body = document.getElementById('detail-body');
  body.innerHTML = head + `<div class="empty"><div class="spinner" style="margin:0 auto;"></div></div>`;
  showDetailSheet();
  try {
    const reviews = await api(hubIntegrated() ? 'getReviewsAll' : 'getReviews', { gameId });
    const list = (reviews && reviews.length)
      ? reviews.map(r => `<div class="rv-row">
          <div class="rv-name">${esc(r.name)}<span class="rv-when">${esc(String(r.updated_at || '').substring(0, 10))}${r.hub_name ? ' · ' + esc(r.hub_name) : ''}</span></div>
          <div class="rv-text">${esc(r.review)}</div>
        </div>`).join('')
      : `<div class="empty"><div class="big">💬</div>아직 남긴 후기가 없어요.<br/>플레이한 게임이면<br/>MY-게임기록에서 후기를 남겨보세요.</div>`;
    body.innerHTML = head + `<div>${list}</div>`;
  } catch (e) {
    body.innerHTML = head + `<div class="empty">불러오지 못했습니다.<br/>${esc(e.message)}</div>`;
  }
}

// 게임 상세: [게임메모] 개인 메모(비공개) 편집
function openMemoEditor() {
  const gd = state._gd; if (!gd) return;
  const existing = (state._myRatings && state._myRatings[gd.gid]) || {};
  document.getElementById('gd-memo-text').value = existing.memo || '';
  document.getElementById('gd-memo-overlay').classList.add('show');
  openOverlay(() => document.getElementById('gd-memo-overlay').classList.remove('show'));
}
function closeMemoEditor() { closeOverlay(); }
async function saveMemo() {
  const gd = state._gd; if (!gd || !state.user) return;
  const pin = await promptPin(); if (pin == null) return;
  const memo = document.getElementById('gd-memo-text').value;
  showLoader('저장 중…');
  try {
    await api('saveMemo', { playerId: state.user.player_id, pin, gameId: gd.gid, memo });
    if (!state._myRatings) state._myRatings = {};
    state._myRatings[gd.gid] = Object.assign({}, state._myRatings[gd.gid], { game_id: gd.gid, memo });
    closeMemoEditor();
    toast('게임메모가 저장되었습니다!');
  } catch (e) { toast(e.message, true); } finally { hideLoader(); }
}

function sortGameDetail(col) {
  const gd = state._gd; if (!gd) return;
  if (gd.col === col) gd.dir = gd.dir === 'desc' ? 'asc' : 'desc';
  else { gd.col = col; gd.dir = col === 'name' ? 'asc' : 'desc'; }
  renderGameDetail();
}

function renderGameDetail() {
  const gd = state._gd; if (!gd) return;
  const g = myGameInfo(gd.gid);
  if (!g) { toast('게임 정보를 찾을 수 없습니다.', true); return; }

  // 1) 상단: 사진 + 내 통계(판수·승수·평균·최고) — 통합 범위면 전 허브 합산
  let myGames = 0, myWins = 0; const myScores = [];
  myScopeSessions().forEach(s => {
    if (s.game_id !== gd.gid) return;
    const me = s.participants.find(p => isMyPid(p.player_id));
    if (me) {
      myGames++; if (me.is_win) myWins++;
      const sc = (me.score == null || me.score === '') ? null : Number(me.score);
      if (sc != null && !isNaN(sc)) myScores.push(sc);
    }
  });
  const myAvg = myScores.length ? Math.round(myScores.reduce((a, b) => a + b, 0) / myScores.length * 10) / 10 : null;
  const myBest = myScores.length ? Math.max(...myScores) : null;
  const scoreTxt = myScores.length ? `평균 ${myAvg}점 · 최고 ${myBest}점` : '점수 없음';
  const top = `<div class="gd-top">
    ${thumb(g.image_url, 'gcard-img')}
    <div style="flex:1;min-width:0;">
      <div class="gcard-name">${esc(g.name_kr || g.name_en)}
        ${g.category ? `<span class="badge" style="margin-left:6px;">${esc(g.category)}</span>` : ''}</div>
      <div class="gd-mystat">${myGames}판 · ${myWins}승 · ${scoreTxt}</div>
    </div>
  </div>`;

  // 2) 최근 판 차트(내가 참가한 세션 — 통합 범위면 전 허브)
  const mine = myScopeSessions()
    .filter(s => s.game_id === gd.gid && s.participants.some(p => isMyPid(p.player_id)))
    .slice()
    .sort((a, b) => String(a.play_date).localeCompare(String(b.play_date)));
  const recent = mine.slice(-10);
  const chart = `<div class="gd-sec">
    <div class="gd-sec-title" style="display:flex;justify-content:space-between;align-items:center;gap:8px;flex-wrap:wrap;">
      <span>📈 최근 ${recent.length}판 점수 추이</span>
      <span class="gd-legend" style="margin-top:0;gap:10px;"><span><i style="background:var(--main);"></i>최고 점수</span><span><i style="background:#d9d5f3;"></i>내 점수</span></span>
    </div>
    <div class="gd-chart">${gameChartSvg(recent)}</div>
  </div>`;

  // 3) 플레이어 통계 표(정렬 가능)
  const players = gamePlayerStats(gd.gid);
  const dir = gd.dir === 'asc' ? 1 : -1;
  players.sort((a, b) => {
    if (gd.col === 'name') return a.name.localeCompare(b.name) * dir;
    const av = a[gd.col], bv = b[gd.col];
    const an = av == null, bn = bv == null;
    if (an && bn) return 0; if (an) return 1; if (bn) return -1;  // 값 없으면 항상 아래
    return (av - bv) * dir;
  });
  const arrow = c => gd.col === c ? (gd.dir === 'asc' ? ' ▲' : ' ▼') : '';
  const th = (c, label) => `<th class="${gd.col === c ? 'act' : ''}" onclick="sortGameDetail('${c}')">${label}${arrow(c)}</th>`;
  const rows = players.map(p => `<tr class="${p.isMe ? 'me' : ''}">
    <td>${esc(p.name)}${p.isMe ? ' <span style="color:var(--main);font-size:10px;">나</span>' : ''}</td>
    <td>${p.wins}</td><td>${p.winrate}%</td><td>${p.games}</td>
    <td>${p.avg == null ? '-' : p.avg}</td><td>${p.best == null ? '-' : p.best}</td>
  </tr>`).join('');
  const table = `<div class="gd-sec">
    <div class="gd-sec-title">👥 함께 플레이한 기록 (${players.length}명)</div>
    <div class="gd-table-wrap"><table class="gd-table">
      <thead><tr>${th('name', '플레이어')}${th('wins', '승수')}${th('winrate', '승률')}${th('games', '게임수')}${th('avg', '평균')}${th('best', '최고')}</tr></thead>
      <tbody>${rows}</tbody>
    </table></div>
  </div>`;

  document.getElementById('gd-body').innerHTML = top + chart + table;
  const page = document.getElementById('gd-page');
  page.classList.add('show');
  page.scrollTop = 0;
}

// 마지막 렌더 컨텍스트(수정 모드 전환 시 같은 목록을 다시 그리기 위함)
let _sessCtx = null;
function rerenderSessList() { if (_sessCtx) renderSessionList(_sessCtx.containerId, _sessCtx.sessions, _sessCtx.opts); }

function renderSessionList(containerId, sessions, opts = {}) {
  _sessCtx = { containerId, sessions, opts };
  const el = document.getElementById(containerId);
  if (!sessions.length) {
    el.innerHTML = `<div class="empty"><div class="big">🎲</div>아직 플레이 기록이 없어요.<br/>+ 버튼으로 결과를 추가해보세요.</div>`;
    return;
  }
  el.innerHTML = sessions.map(s => {
    // 관리자 페이지에서는 모든 기록 수정 가능
    const canEdit = state.user && (opts.admin || (s.created_by && String(s.created_by) === String(state.user.player_id)));
    const editing = state._editSid === s.session_id;
    const dur = s.duration_min ? ` · ${s.duration_min}분` : '';
    // 관리자 페이지: 작성자 표시(회색 배지)
    const creator = opts.admin && s.created_by
      ? `<span class="adm-creator">작성 ${esc(playerNameById(s.created_by))}</span>` : '';

    if (editing) {
      const eparts = s.participants.map(p => `
        <div class="prow" data-rid="${esc(p.record_id)}" style="gap:8px;">
          <span class="pname" style="flex:1;min-width:0;">${esc(p.name)}</span>
          <input type="number" inputmode="numeric" class="edit-score" placeholder="점수" value="${p.score == null ? '' : esc(p.score)}"
                 style="width:64px;padding:6px 8px;border:1px solid var(--border);border-radius:8px;background:#fff;" />
          <button type="button" class="wintoggle edit-win ${p.is_win ? 'on' : ''}" data-win="${p.is_win ? '1' : '0'}" onclick="toggleEditWin(this)" style="padding:6px 10px;">${p.is_win ? '승 👑' : '패 🥈'}</button>
        </div>`).join('');
      return `<div class="session" data-sid="${esc(s.session_id)}">
        <div class="session-head">
          ${thumb(s.game_image, 'session-thumb')}
          <div style="flex:1;min-width:0;"><div class="g-name">${esc(s.game_name)}</div></div>
          <button class="btn ghost sm" style="padding:6px 14px;flex:0 0 auto;" onclick="cancelEditSession()">취소</button>
        </div>
        <div class="row2 wrapdate" style="margin:8px 0;">
          <div class="field" style="margin:0;"><label>날짜</label><input class="input edit-date" type="date" value="${esc(String(s.play_date).substring(0,10))}" /></div>
          <div class="field" style="margin:0;"><label>시간(분)</label><input class="input edit-duration" type="number" inputmode="numeric" value="${s.duration_min || ''}" /></div>
        </div>
        <div class="participants">${eparts}</div>
        <div style="display:flex;gap:8px;margin-top:10px;">
          <button class="btn danger sm" style="flex:1;" onclick="deleteSession('${esc(s.session_id)}')">🗑 삭제</button>
          <button class="btn sm" style="flex:1;" onclick="saveEditSession('${esc(s.session_id)}')">저장</button>
        </div>
      </div>`;
    }

    const parts = s.participants.map(p => `
      <div class="prow ${p.is_win ? 'win' : ''}">
        <span class="pname">${esc(p.name)}${p.is_win ? '<span class="crown">👑</span>' : ''}</span>
        <span class="pscore">${p.score == null ? '' : esc(p.score) + '점'}</span>
      </div>`).join('');
    return `<div class="session">
      <div class="session-head">
        ${thumb(s.game_image, 'session-thumb')}
        <div style="flex:1;min-width:0;">
          <div class="g-name">${esc(s.game_name)}</div>
          <div class="g-meta">${esc(String(s.play_date).substring(0,10))}${dur} · ${s.participants.length}명${
            s.hub_name && state.hub && s.hub_id !== state.hub.hub_id
              ? ` · <span style="color:var(--main);">${esc(s.hub_name)}</span>` : ''}${creator}</div>
        </div>
        ${canEdit ? `<button class="btn ghost sm" style="padding:5px 12px;font-size:12px;flex:0 0 auto;" onclick="startEditSession('${esc(s.session_id)}')">수정</button>` : ''}
      </div>
      <div class="participants">${parts}</div>
    </div>`;
  }).join('');
}

function playerNameById(pid) {
  const p = (state.players || []).find(x => String(x.player_id) === String(pid));
  return p ? p.name : pid;
}

// ===== 내 플레이 기록: 수정/삭제 (입력자 본인만, 관리자 페이지는 전체) =====
function refreshMySessions() {
  if (myScope() !== 'hub') {   // 통합/다른 허브 범위: 서버에서 다시 합산
    state._myAllPlays = null;
    state._myAllGames = null;
    renderMyPlaysTab().then(() => {
      if (hubIntegrated()) { renderPlay(); renderGames(); }   // 플레이·게임 탭도 갱신
    });
    return;
  }
  state._mySessions = state.plays.filter(s =>
    s.participants.some(p => p.player_id === state.user.player_id));
  filterMyPlays();
}
// 저장/삭제 후: 관리자 페이지가 열려 있으면 관리자 목록을, 아니면 MY 목록을 갱신
function refreshSessionsView() {
  const adm = document.getElementById('admin-page');
  if (adm && adm.classList.contains('show')) adminPlaySearch();
  else refreshMySessions();
}
function startEditSession(sid) { state._editSid = sid; rerenderSessList(); }
function cancelEditSession() { state._editSid = null; rerenderSessList(); }
function toggleEditWin(btn) {
  const on = btn.getAttribute('data-win') === '1';
  btn.setAttribute('data-win', on ? '0' : '1');
  btn.classList.toggle('on', !on);
  btn.textContent = on ? '패 🥈' : '승 👑';
}

async function saveEditSession(sid) {
  if (!state.user) return;
  const card = document.querySelector(`.session[data-sid="${sid}"]`);
  if (!card) return;
  const play_date = card.querySelector('.edit-date').value;
  const duration_min = card.querySelector('.edit-duration').value;
  const rows = Array.from(card.querySelectorAll('.prow[data-rid]')).map(row => ({
    record_id: row.getAttribute('data-rid'),
    score: row.querySelector('.edit-score').value,
    is_win: row.querySelector('.edit-win').getAttribute('data-win') === '1'
  }));
  const pin = await promptPin();
  if (pin == null) return;
  showLoader('저장 중…');
  try {
    await api('updatePlay', { playerId: state.user.player_id, pin, payload: JSON.stringify({ session_id: sid, play_date, duration_min, rows }) });
    state.plays = await api('getPlays');
    state._myStats = null;
    state._editSid = null;
    toast('수정되었습니다.');
    refreshSessionsView();
  } catch (e) {
    toast(e.message, true);
  } finally {
    hideLoader();
  }
}

async function deleteSession(sid) {
  if (!confirm('이 기록을 삭제하면 함께 플레이한 모든 참가자의 기록에서도 사라집니다.\n정말 삭제할까요?')) return;
  const pin = await promptPin();
  if (pin == null) return;
  showLoader('삭제 중…');
  try {
    await api('deletePlay', { playerId: state.user.player_id, pin, sessionId: sid });
    state.plays = await api('getPlays');
    state._myStats = null;
    state._editSid = null;
    toast('삭제되었습니다.');
    refreshSessionsView();
  } catch (e) {
    toast(e.message, true);
  } finally {
    hideLoader();
  }
}

// ============================================================
//  VIEW: 게임
// ============================================================
// 난이도(weight) 필터 구간
const WEIGHT_BUCKETS = [
  { key: '0-2', label: '0~2', lo: 0, hi: 2 },
  { key: '2-3', label: '2~3', lo: 2, hi: 3 },
  { key: '3-4', label: '3~4', lo: 3, hi: 4 },
  { key: '4-5', label: '4~5', lo: 4, hi: 5 }
];

function renderGames() {
  renderCategoryFilter();
  renderPlayerCountFilter();
  renderWeightFilter();
  renderGameCards();
}

function renderCategoryFilter() {
  const cats = [...new Set(hubGamesList().map(g => g.category).filter(Boolean))];
  const cur = state.gameFilter.category;
  const el = document.getElementById('cat-filter');
  el.innerHTML =
    `<span class="chip ${!cur ? 'on' : ''}" onclick="setCatFilter(null)">전체</span>` +
    cats.map(c => `<span class="chip ${cur === c ? 'on' : ''}" onclick="setCatFilter('${esc(c)}')">${esc(c)}</span>`).join('');
}
function setCatFilter(c) { state.gameFilter.category = c; renderGames(); }

function renderPlayerCountFilter() {
  const cur = state.gameFilter.playerCount;
  const el = document.getElementById('player-filter');
  const counts = [2, 3, 4, 5, 6];
  el.innerHTML =
    `<span class="chip ${!cur ? 'on' : ''}" onclick="setPcFilter(null)">인원 전체</span>` +
    counts.map(n => `<span class="chip ${cur === n ? 'on' : ''}" onclick="setPcFilter(${n})">${n}명</span>`).join('') +
    `<span class="chip ${cur === 7 ? 'on' : ''}" onclick="setPcFilter(7)">7명+</span>`;
}
function setPcFilter(n) { state.gameFilter.playerCount = n; renderGames(); }

function renderWeightFilter() {
  const cur = state.gameFilter.weight;
  const el = document.getElementById('weight-filter');
  el.innerHTML =
    `<span class="chip ${!cur ? 'on' : ''}" onclick="setWeightFilter(null)">난이도 전체</span>` +
    WEIGHT_BUCKETS.map(b => `<span class="chip ${cur === b.key ? 'on' : ''}" onclick="setWeightFilter('${b.key}')">${b.label}</span>`).join('');
}
function setWeightFilter(key) { state.gameFilter.weight = key; renderGames(); }

document.getElementById('game-search').addEventListener('input', e => {
  state.gameFilter.search = e.target.value.trim().toLowerCase();
  renderGameCards();
});

function filteredGames() {
  const f = state.gameFilter;
  let list = hubGamesList().slice();
  if (f.category) list = list.filter(g => g.category === f.category);
  if (f.playerCount) {
    const n = f.playerCount;
    list = list.filter(g => {
      const min = g.min_players, max = g.max_players;
      if (min == null && max == null) return false;
      const lo = min == null ? 1 : min;
      const hi = max == null ? 99 : max;
      return lo <= n && n <= hi;
    });
  }
  if (f.weight) {
    const b = WEIGHT_BUCKETS.find(x => x.key === f.weight);
    if (b) list = list.filter(g => {
      const w = g.weight;
      if (w == null) return false;
      // 경계값은 위 구간에 포함(2→2~3, 3→3~4, 4→4~5), 마지막 구간만 상한 포함
      return b.key === '4-5' ? (w >= b.lo && w <= b.hi) : (w >= b.lo && w < b.hi);
    });
  }
  if (f.search) {
    list = list.filter(g =>
      (g.name_kr || '').toLowerCase().includes(f.search) ||
      (g.name_en || '').toLowerCase().includes(f.search));
  }
  // 기본 정렬: 최근 추가 순(통합이면 내 최근 플레이 순)
  if (hubIntegrated()) {
    list.sort((a, b) => (a._first ?? 1e9) - (b._first ?? 1e9));
  } else {
    const gidNum = g => parseInt(String(g.game_id).replace(/\D/g, ''), 10) || 0;
    list.sort((a, b) => gidNum(b) - gidNum(a));
  }
  return list;
}

// 게임 카드 헤더(사진 옆 정보 정렬): 이름·분류·메타·Hub평점(+내 평점)
// showMine=true 이면 Hub 평점 옆에 '나 ★ X.X' 표시(게임 기록 카드와 동일)
function gameCardTopHtml(g, showMine) {
  const meta = [];
  if (g.min_players || g.max_players) {
    const mn = g.min_players || '?', mx = g.max_players || '?';
    meta.push(`👥 ${mn}${mx !== mn ? '~' + mx : ''}명`);
  }
  if (g.playtime_min) meta.push(`⏱ ${g.playtime_min}분`);
  if (g.weight) meta.push(`🧠 ${Number(g.weight).toFixed(2)}`);

  const club = g.club_rating != null
    ? `<span class="rate-club"><span class="star">★</span> ${g.club_rating.toFixed(1)} <small>(${g.rating_count})</small></span>`
    : `<span class="rate-club muted"><span class="star" style="color:#dcdce3">★</span> - <small>평가없음</small></span>`;

  let mine = '';
  if (showMine) {
    // 통합 보기: 카드에 담아온 내 평점(_my_rating) 우선, 아니면 현재 허브 내 평점
    const r = (g._my_rating != null) ? g._my_rating
      : ((state._myRatings && state._myRatings[g.game_id]) ? state._myRatings[g.game_id].rating : null);
    mine = (r != null)
      ? `<span class="rate-mine">나 <span class="star">★</span> ${Number(r).toFixed(1)}</span>`
      : `<span style="font-size:12px;color:var(--text-sub);">내 평점 없음</span>`;
  }

  return `${thumb(g.image_url, 'gcard-img')}
      <div class="gcard-body">
        <div class="gcard-name">${esc(g.name_kr || g.name_en)}
          ${g.category ? `<span class="badge" style="margin-left:6px;">${esc(g.category)}</span>` : ''}</div>
        ${g.name_en && g.name_kr ? `<div class="gcard-en">${esc(g.name_en)}</div>` : ''}
        <div class="gcard-meta">${meta.map(m => `<span>${m}</span>`).join('')}</div>
        <div class="gcard-ratings">${club}${mine}</div>
      </div>`;
}

function gameCardHtml(g, opts = {}) {
  // 펼침 영역: 내 게임기록은 '평점 에디터', 그 외는 '게임 요약'
  const detail = opts.ratingEditor
    ? `<div class="gcard-editwrap">${ratingEditorHtml(g)}</div>`
    : (g.summary_kr
        ? `<div class="gcard-detail">${esc(g.summary_kr)}</div>`
        : `<div class="gcard-detail muted">등록된 요약이 없습니다.</div>`);

  const acts = [];
  if (opts.adminEdit) acts.push(`<button class="gcard-pill edit" title="정보 수정 (admin)" onclick="event.stopPropagation(); openEditGame('${g.game_id}')">✏️</button>`);
  const actsHtml = acts.length ? `<div class="gcard-actions">${acts.join('')}</div>` : '';
  // 상세·후기 버튼은 평점 줄 오른쪽 끝(우측 하단)에 배치
  const br = [];
  if (opts.ratingEditor || opts.myDetail) br.push(`<button class="gcard-pill" onclick="event.stopPropagation(); openGameDetail('${g.game_id}')">상세</button>`);
  if (opts.review) br.push(reviewPillHtml(g.game_id, g.review_count));
  const reviewHtml = br.length ? `<div class="gcard-actions br">${br.join('')}</div>` : '';

  return `<div class="gcard" data-gid="${g.game_id}">
    ${actsHtml}
    <div class="gcard-top" onclick="toggleCard(this)">
      ${gameCardTopHtml(g, opts.ratingEditor || opts.showMine)}
      ${reviewHtml}
    </div>
    ${detail}
  </div>`;
}

function toggleCard(topEl) {
  topEl.parentElement.classList.toggle('open');
}

// ===== 평점 정렬 토글 (없음 → 내림차순 → 오름차순 → 없음) =====
function nextSortMode(cur) { return cur === 'desc' ? 'asc' : cur === 'asc' ? null : 'desc'; }
function sortBtnLabel(mode) { return mode === 'desc' ? '평점↓' : mode === 'asc' ? '평점↑' : '평점'; }
// 평점 없는 게임: 내림차순이면 맨 아래, 오름차순(낮은 평점부터)이면 맨 위.
// 해제(null)면 원본 순서 그대로.
function applyRatingSort(list, mode, getRating) {
  if (!mode) return list;
  return list.slice().sort((a, b) => {
    const av = getRating(a), bv = getRating(b);
    const an = av == null, bn = bv == null;
    if (an && bn) return 0;
    if (an) return mode === 'asc' ? -1 : 1;
    if (bn) return mode === 'asc' ? 1 : -1;
    return mode === 'asc' ? av - bv : bv - av;
  });
}

function cycleGameSort() {
  state.gameSortRating = nextSortMode(state.gameSortRating);
  const b = document.getElementById('game-sort-btn');
  b.textContent = sortBtnLabel(state.gameSortRating);
  b.classList.toggle('on', !!state.gameSortRating);
  renderGameCards();
}

function renderGameCards() {
  const list = applyRatingSort(filteredGames(), state.gameSortRating,
    g => g.club_rating == null ? null : Number(g.club_rating));
  const el = document.getElementById('games-list');
  if (!list.length) {
    el.innerHTML = `<div class="empty"><div class="big">🎯</div>조건에 맞는 게임이 없어요.</div>`;
    return;
  }
  // 게임 수정은 관리자 페이지에서만 — 통합 게임탭은 모두 동일 UI
  el.innerHTML = list.map(g => gameCardHtml(g, { review: true })).join('');
}

// ============================================================
//  VIEW: MY
// ============================================================


// 이메일 계정에는 개인 기록장을 자동으로 하나 마련(이미 있으면 그대로)
async function ensurePersonalHub(nick, pin) {
  try {
    const hub = await sbrpc('create_hub', { p_name: nick + '의 기록장', p_kind: 'personal' });
    if (!hub.existing) {
      const u = await sbrpc('signup', { p_name: nick, p_pin: pin, p_hub_id: hub.hub_id, p_invite: hub.invite_code });
      await sbrpc('link_player', { p_hub_id: hub.hub_id, p_player_id: u.player_id, p_pin: pin });
    }
    state._myLinks = null;   // 드롭다운/칩 목록 갱신
  } catch (e) { /* 자동 생성 실패는 치명적이지 않음 */ }
}

// ===== 좌측 상단: 내 허브 드롭다운 =====
// 허브 전환 메뉴의 한 줄: 이름 + 초대코드(탭=초대 문구 복사) + 이동 표시
function hubMenuRowHtml(hid, name, kind, invite, cur, clickable) {
  const inv = invite
    ? `<span class="invite-mini" onclick="event.stopPropagation(); copyInvite('${esc(name)}','${esc(invite)}')" title="초대 문구 복사">🔑 ${esc(invite)}</span>`
    : '';
  return `<button class="hubmenu-item ${cur ? 'cur' : ''}" ${clickable ? `onclick="switchToHub('${hid}')"` : 'onclick="closeHubMenu()"'}>
    <span style="min-width:0;overflow:hidden;text-overflow:ellipsis;">${kind === 'personal' ? '📔' : '🏠'} ${esc(name)}</span>
    <span style="display:flex;align-items:center;gap:8px;flex:0 0 auto;">
      ${inv}${cur ? '<span class="hint">현재 ✓</span>' : '<span class="hint">›</span>'}
    </span>
  </button>`;
}

async function openHubMenu() {
  try { await loadMyLinks(); } catch (e) {}
  const links = state._myLinks || [];
  const el = document.getElementById('hubmenu-body');
  let rows;
  if (links.length) {
    rows = links.map(l => {
      const cur = state.hub && state.hub.hub_id === l.hub_id;
      const inv = l.invite || (cur && state.hub.invite) || '';
      return hubMenuRowHtml(l.hub_id, l.hub_name, isPersonalHub(l) ? 'personal' : 'hub', inv, cur, true);
    }).join('');
  } else if (state.hub) {
    // 이메일 미연결: 현재 허브 정보(이름·초대코드)만 동일한 형식으로
    rows = hubMenuRowHtml(state.hub.hub_id, state.hub.name,
      isPersonalHub(state.hub) ? 'personal' : 'hub', state.hub.invite || '', true, false);
  } else { openStartPage(true); return; }
  el.innerHTML = `
    <h2 style="font-size:17px;font-weight:900;margin:2px 2px 12px;">내 허브</h2>
    ${rows}
    <button class="btn ghost sm" style="width:100%;margin-top:12px;" onclick="closeHubMenu(); goMain();">🏠 메인으로</button>`;
  document.getElementById('hubmenu-overlay').classList.add('show');
}
function closeHubMenu() { document.getElementById('hubmenu-overlay').classList.remove('show'); }

async function switchToHub(hid) {
  const link = (state._myLinks || []).find(l => l.hub_id === hid);
  if (!link) return;
  // 같은 허브라도 멤버 로그인이 풀려 있으면(메인으로 나온 뒤) 다시 로그인해서 입장
  if (state.hub && state.hub.hub_id === hid && state.user) {
    closeHubMenu(); closeStartPage(); return;
  }
  showLoader('이동 중…');
  try {
    const u = await sbrpc('login_linked', { p_hub_id: hid });   // 연결 계정 자동 로그인
    saveHub({ hub_id: hid, name: link.hub_name, kind: link.kind || 'hub' });
    state.myScope = null;
    applyAuth({ player_id: u.player_id, name: u.name, role: u.role, hub_id: u.hub_id },
              u.pin, link.hub_name + '(으)로 이동!');
    closeHubMenu();
    closeStartPage();
    await loadCore();
  } catch (e) {
    toast(e.message, true);
  } finally { hideLoader(); }
}

// ===== 이메일 연동 통합 기록 (2-5) =====
// 내 계정에 연결된 허브 목록(이메일 세션 있을 때만). 없으면 [].
async function loadMyLinks() {
  if (state._myLinks != null) return;
  state._myLinks = [];
  try {
    const { data } = await sb.auth.getSession();
    if (!data || !data.session) return;
    state._myLinks = await api('getMyLinks') || [];
    // 기록장에서 연결 목록이 늦게 도착하면 현재 MY 탭을 다시 그려 범위 칩 반영
    if (state._myLinks.length >= 2 && state.user
        && isPersonalHub(state.hub)) renderMy();
  } catch (e) { /* 비로그인/미지원 → 통합 숨김 */ }
}

function setMyScope(sc) {
  state.myScope = sc;
  renderMy();   // 전체기록·플레이기록·게임기록 세 탭이 같은 범위를 공유
}

// MY 탭 공통 범위: 'hub'(현재 허브) | 'all'(통합) | hub_id(특정 허브)
// 통합/허브별 전환은 '개인 기록장'에서 연결이 2개 이상일 때만 제공
function myScope() {
  const links = state._myLinks || [];
  if (!(isPersonalHub(state.hub) && links.length >= 2)) return 'hub';
  let sc = state.myScope || 'all';
  if (state.hub && sc === state.hub.hub_id) sc = 'hub';   // 기록장 자신 = 일반 모드
  return sc;
}

// 현재 MY 범위의 '내' 세션 소스: 기록장 통합이면 전 허브, 아니면 현재 허브
function myScopeSessions() {
  const scope = myScope();
  if (scope === 'hub') return state.plays;
  const all = state._myAllPlays || [];
  return scope === 'all' ? all : all.filter(s => s.hub_id === scope);
}

// 통합 범위 화면에 필요한 전 허브 데이터(세션·게임 집계)를 준비
async function ensureMyAllData() {
  if (myScope() === 'hub') return;
  try {
    if (!state._myAllPlays) state._myAllPlays = await api('getMyPlaysAll') || [];
    if (!state._myAllGames) state._myAllGames = await api('getMyGamesAll') || [];
  } catch (e) { /* 미지원(마이그레이션 전) → 현재 허브 데이터로 표시 */ }
}

// 이 player_id가 '나'인지 — 통합 범위에서는 연결된 모든 허브의 내 멤버가 나
function isMyPid(pid) {
  if (!pid || !state.user) return false;
  if (myScope() === 'hub') return pid === state.user.player_id;
  return (state._myLinks || []).some(l => l.player_id === pid);
}

// 게임 정보: 선반(gameById) 우선, 통합 범위에서는 도감 집계(_myAllGames)로 구성
// scopeOverride: 게임탭 등 MY 범위 선택과 무관하게 'all'로 강제할 때 사용
function myGameInfo(gid, scopeOverride) {
  const scope = scopeOverride || myScope();
  if (scope === 'hub') return gameById(gid);
  let rows = (state._myAllGames || []).filter(r => r.game_id === gid);
  if (scope !== 'all') {
    const sub = rows.filter(r => r.hub_id === scope);
    if (sub.length) rows = sub;
  }
  if (!rows.length) return gameById(gid);
  const r = rows[0];
  const myRatings = rows.filter(x => x.my_rating != null && x.my_rating !== '')
    .map(x => Number(x.my_rating));
  return {
    game_id: gid, name_kr: r.name_kr, name_en: r.name_en || '',
    category: r.category || '', image_url: r.image_url || '',
    min_players: r.min_players, max_players: r.max_players,
    playtime_min: r.playtime_min, weight: r.weight, summary_kr: r.summary_kr || '',
    club_rating: r.all_rating != null ? Number(r.all_rating) : null,
    rating_count: r.all_rating_count || 0, review_count: r.all_review_count || 0,
    _my_rating: myRatings.length
      ? Math.round(myRatings.reduce((a, b) => a + b, 0) / myRatings.length * 10) / 10 : null,
  };
}

// ===== 기록장의 플레이·게임 탭 통합 =====
// 개인 기록장(연결 2개 이상)에서는 플레이·게임 탭도 전 허브의 내 기록 기준
function hubIntegrated() {
  return isPersonalHub(state.hub) && (state._myLinks || []).length >= 2;
}
// 플레이 탭 세션 소스
function hubPlays() {
  return hubIntegrated() ? (state._myAllPlays || []) : state.plays;
}
// 게임 탭 게임 소스: 통합이면 내가 플레이한 도감 게임(내 최근 플레이 순, ★=전체 평점)
function hubGamesList() {
  if (!hubIntegrated()) return state.games;
  const rows = state._myAllGames || [];
  if (!rows.length) return state.games;
  const order = []; const seen = new Set();
  rows.slice().sort((a, b) => a.first_rn - b.first_rn).forEach(r => {
    if (!seen.has(r.game_id)) { seen.add(r.game_id); order.push(r.game_id); }
  });
  return order.map((gid, i) => {
    const g = myGameInfo(gid, 'all');
    if (g) g._first = i;
    return g;
  }).filter(Boolean);
}

function myScopeChipsHtml(scope) {
  const links = state._myLinks || [];
  if (!(isPersonalHub(state.hub) && links.length >= 2)) return '';
  return `
    <div class="chip-row" style="padding-bottom:8px;">
      <span class="chip ${scope === 'all' ? 'on' : ''}" style="cursor:pointer;" onclick="setMyScope('all')">전체(통합)</span>
      ${links.map(l => {
        const on = (scope === 'hub' && state.hub && l.hub_id === state.hub.hub_id) || scope === l.hub_id;
        return `<span class="chip ${on ? 'on' : ''}" style="cursor:pointer;" onclick="setMyScope('${l.hub_id}')">${isPersonalHub(l) ? '📔 ' : ''}${esc(l.hub_name)}</span>`;
      }).join('')}
    </div>`;
}

// MY 하단: 계정 연결 상태/버튼
function renderMyLinkRow() {
  const el = document.getElementById('my-linkrow');
  if (!el || !state.user) return;
  const me = (state.players || []).find(p => p.player_id === state.user.player_id);
  if (me && me.linked) {
    el.innerHTML = `<span class="hint">✓ 이메일 계정 연결됨 · 여러 허브 기록을 모아볼 수 있어요</span>`;
  } else {
    el.innerHTML = `<button class="logout-link" style="color:var(--main);" onclick="linkCurrentMember()">📧 이메일 계정에 연결하기</button>
      <div class="hint" style="margin-top:4px;">연결하면 여러 허브의 내 기록을 통합해 볼 수 있어요</div>`;
  }
}

function renderMy() {
  if (!state.user) { renderLoginForm(); return; }
  document.getElementById('my-login').style.display = 'none';
  document.getElementById('my-content').style.display = 'block';
  loadMyLinks();
  renderMyLinkRow();
  // 게임기록 탭 데이터(내 평점)를 전체기록 통계와 병렬로 미리 로드 → 탭 전환 시 즉시 표시
  ensureMyRatings().catch(() => {});
  const tab = state.myTab || 'overview';
  if (tab === 'overview') renderMyOverview();
  else if (tab === 'plays') renderMyPlaysTab();
  else renderMyGames();
}

function switchMyTab(tab) {
  state.myTab = tab;
  ['overview', 'plays', 'games'].forEach(t => {
    document.getElementById('mytab-' + t).classList.toggle('on', t === tab);
    document.getElementById('my-' + t).style.display = t === tab ? 'block' : 'none';
  });
  renderMy();
}

function renderLoginForm() {
  document.getElementById('my-content').style.display = 'none';
  const el = document.getElementById('my-login');
  el.style.display = 'block';
  // 로그인/가입은 시작 화면에서 한 번에 끝나는 구조 — 여기서는 안내만
  el.innerHTML = `
    <div class="center-login">
      <div class="lg-ico">🔐</div>
      <h2>MY 페이지</h2>
      <div class="hint" style="text-align:center;margin-bottom:20px;">
        로그인 정보가 없어요.<br/>메인 화면에서 로그인하고 들어와주세요.
      </div>
      <button class="btn" onclick="goMain()">메인으로</button>
    </div>`;
}

// 메인(시작 화면)으로 이동 — 멤버 세션은 그대로 (계정 로그아웃은 메인에서)
function applyAuth(user, pin, welcome) {
  state.user = user;
  localStorage.setItem('bg_user', JSON.stringify(user));
  localStorage.setItem('bg_pin', pin);
  state._myStats = null; state._myStatsHub = null; state._myStatsAll = null; state._myStatsBy = null;   // 사용자별 캐시 초기화
  state._myAllPlays = null; state._myAllGames = null;
  state._myRatings = null;
  state._myRatingsPromise = null;
  updateWhoami();
  renderGames();
  toast(welcome);
  renderMy();
}

// 현재 멤버를 이메일 계정에 수동 연결(자동 연결 없음 — 버튼으로만).
// 이미 이 허브에 연결된 멤버가 있는 계정이면 중복 연결을 막는다
async function linkCurrentMember() {
  if (!state.user) return;
  let session = null;
  try { const { data } = await sb.auth.getSession(); session = data && data.session; } catch (e) {}
  if (!session) { openEmailAuth('link'); return; }   // 이메일 로그인부터
  state._myLinks = null;
  try { await loadMyLinks(); } catch (e) {}
  if ((state._myLinks || []).some(l => l.hub_id === hubId())) {
    toast('이미 연결된 허브예요.', true); return;
  }
  showLoader('연결 중…');
  try {
    const pin = localStorage.getItem('bg_pin');
    await api('linkPlayer', { playerId: state.user.player_id, pin });
    state._myLinks = null;
    try { state.players = await api('getPlayers'); } catch (e) {}
    toast('이 허브가 내 계정에 연결됐어요 🔗');
    renderMyLinkRow();
  } catch (e) { toast(e.message, true); } finally { hideLoader(); }
}

function goMain() { openStartPage(true); }

function updateWhoami() {
  const el = document.getElementById('whoami');
  if (state.user) {
    el.innerHTML = `<b>${esc(state.user.name)}</b>${state.user.role === 'admin' ? ' 👑' : ''}`;
  } else {
    el.textContent = '비로그인';
  }
  // [관리자] 버튼은 admin 로그인 시에만 표시
  const ab = document.getElementById('admin-btn');
  if (ab) ab.style.display = (state.user && state.user.role === 'admin') ? '' : 'none';
}

// ===== MY > 전체 기록 =====
async function renderMyOverview() {
  const el = document.getElementById('my-overview');
  const links = state._myLinks || [];
  const scope = myScope();
  state._myStatsBy = state._myStatsBy || {};
  if (!state._myStatsBy[scope]) {
    el.innerHTML = `<div class="empty"><div class="spinner" style="margin:0 auto;"></div></div>`;
    try {
      if (scope === 'all') {
        state._myStatsBy[scope] = await api('getMyStatsAll');
      } else if (scope === 'hub') {
        state._myStatsBy[scope] = await api('getPlayerStats', { playerId: state.user.player_id });
      } else {
        const link = links.find(l => l.hub_id === scope);
        state._myStatsBy[scope] = await api('getPlayerStats', { playerId: link.player_id });
      }
    } catch (e) {
      el.innerHTML = `<div class="empty">통계를 불러오지 못했습니다.<br/>${esc(e.message)}</div>`;
      return;
    }
  }
  state._myStats = state._myStatsBy[scope];
  await ensureMyAllData();   // 통합 범위: 점수·상세·카테고리 차트용 전 허브 데이터
  try {
    const stats = state._myStats;
    const scopeChips = myScopeChipsHtml(scope);
    // '플레이 게임' = 내 플레이 기록이 있는 게임 수(= MY-게임기록 목록 개수와 동일)
    const playedIds = new Set();
    state.plays.forEach(s => {
      if (s.participants.some(p => p.player_id === state.user.player_id)) playedIds.add(s.game_id);
    });
    const playedGamesCount = scope !== 'hub'
      ? (stats.by_game || []).length
      : state.games.filter(g => playedIds.has(g.game_id)).length;

    const sort = state.myGameSort || 'winrate';
    el.innerHTML = `${scopeChips}
      <div class="summary-row">
        <div class="stat hero"><div class="num">${stats.total_plays}</div><div class="lbl">총 플레이</div></div>
        <div class="stat"><div class="num">${playedGamesCount}</div><div class="lbl">플레이 게임</div></div>
        <div class="stat" id="my-winstat" style="cursor:pointer;" onclick="toggleMyWinStat()">${myWinStatInner()}</div>
      </div>
      <div class="card" id="my-chart-card" style="cursor:pointer;">${myChartCardInner()}</div>
      <div class="searchbox"><span>🔍</span><input id="my-gamestat-search" placeholder="게임 이름 검색" oninput="renderMyGameStatList()" /></div>
      <div class="card">
        <div class="section-title" style="margin-top:0;display:flex;justify-content:space-between;align-items:center;gap:8px;flex-wrap:wrap;">
          <span>게임별 플레이</span>
          <span style="display:flex;gap:6px;">
            <span class="chip ${sort === 'winrate' ? 'on' : ''}" id="mgsort-winrate" style="cursor:pointer;" onclick="setMyGameSort('winrate')">승률</span>
            <span class="chip ${sort === 'plays' ? 'on' : ''}" id="mgsort-plays" style="cursor:pointer;" onclick="setMyGameSort('plays')">판수</span>
          </span>
        </div>
        <div id="my-gamestat-list"></div>
      </div>`;
    renderMyGameStatList();
  } catch (e) {
    el.innerHTML = `<div class="empty">통계를 불러오지 못했습니다.<br/>${esc(e.message)}</div>`;
  }
}

// 세 번째 요약카드: 누를 때마다 '전체 승률' ↔ '승수' 전환
function myWinStatInner() {
  const stats = state._myStats; if (!stats) return '';
  return state.myWinStatMode === 'wins'
    ? `<div class="num">${stats.total_wins}</div><div class="lbl">승수</div>`
    : `<div class="num">${stats.win_rate}%</div><div class="lbl">전체 승률</div>`;
}
function toggleMyWinStat() {
  state.myWinStatMode = state.myWinStatMode === 'wins' ? 'rate' : 'wins';
  const el = document.getElementById('my-winstat');
  if (el) el.innerHTML = myWinStatInner();
}

// 그래프 카드: 누를 때마다 '월별 플레이 결과' ↔ '카테고리별 플레이' 전환
function toggleMyChart() {
  state.myChartMode = state.myChartMode === 'category' ? 'monthly' : 'category';
  const el = document.getElementById('my-chart-card');
  if (el) el.innerHTML = myChartCardInner();
}

function myChartCardInner() {
  const stats = state._myStats; if (!stats) return '';
  const titleStyle = 'margin-top:0;margin-bottom: 10px;display:flex;justify-content:space-between;align-items:center;gap:8px;flex-wrap:wrap;';
  if (state.myChartMode === 'category') {
    return `
      <div class="section-title" style="${titleStyle}" onclick="toggleMyChart()">
        <span>카테고리별 플레이</span>
        <small class="legend-chips">
          <small><i style="background:var(--main);"></i>플레이 횟수</small>
          <small><i style="background:#d9d5f3;"></i>플레이 게임</small>
        </small>
      </div>
      <div onclick="toggleMyChart()" style="margin:0 -8px -10px;">${myCategoryChartSvg()}</div>`;
  }
  const maxMonth = Math.max(1, ...stats.monthly.map(m => m.count));
  const bars = stats.monthly.map(m => {
    const wr = (m.win_rate != null) ? Number(m.win_rate) : (m.count ? Math.round((m.wins || 0) / m.count * 100) : 0);
    const wh = Math.round(wr / 100 * 74);           // 승률: 0~100% 고정 스케일
    const ch = Math.round(m.count / maxMonth * 74);  // 판수: 최대 판수 기준
    return `<div class="bar-col">
      <div class="bars">
        <div class="bwrap">
          <div class="bc soft">${m.count ? wr + '%' : ''}</div>
          <div class="bar soft" style="height:${m.count ? Math.max(wh, 4) : 3}px;${m.count ? '' : 'opacity:.3;'}"></div>
        </div>
        <div class="bwrap">
          <div class="bc">${m.count || ''}</div>
          <div class="bar" style="height:${m.count ? Math.max(ch, 4) : 3}px;${m.count ? '' : 'opacity:.3;'}"></div>
        </div>
      </div>
      <div class="bm">${m.month.substring(5)}월</div>
    </div>`;
  }).join('');
  return `
    <div class="section-title" style="${titleStyle}" onclick="toggleMyChart()">
      <span>월별 플레이 결과</span>
      <small class="legend-chips">
        <small><i style="background:var(--main-soft);"></i>승률</small>
        <small><i style="background:var(--main);"></i>판수</small>
      </small>
    </div>
    <div class="barchart" onclick="toggleMyChart()" style="margin:0 -8px -10px;">${bars}</div>`;
}

// 카테고리별: 막대=내 플레이 횟수, 추이선=플레이한 게임 수 (동일 스케일)
// 기록장 통합 범위에서는 전 허브 세션 기준
function myCategoryChartSvg() {
  const byCat = {};
  myScopeSessions().forEach(s => {
    if (!s.participants.some(p => isMyPid(p.player_id))) return;
    const g = gameById(s.game_id)
      || (state._myAllGames || []).find(r => r.game_id === s.game_id);
    const cat = (g && g.category) || '기타';
    if (!byCat[cat]) byCat[cat] = { plays: 0, games: new Set() };
    byCat[cat].plays++;
    byCat[cat].games.add(s.game_id);
  });
  const cats = Object.keys(byCat)
    .map(c => ({ cat: c, plays: byCat[c].plays, games: byCat[c].games.size }))
    .sort((a, b) => b.plays - a.plays);
  if (!cats.length) return `<div class="muted" style="font-size:12px;padding:10px 2px;text-align:center;">플레이 기록이 없어요.</div>`;

  const W = 340, H = 116, padT = 24, padB = 20, padX = 8;
  const plotH = H - padT - padB, baseY = padT + plotH;
  const n = cats.length, slot = (W - padX * 2) / n;
  const maxV = Math.max(1, ...cats.map(c => c.plays));
  const y = v => padT + plotH * (1 - v / maxV);
  const cx = i => padX + slot * (i + 0.5);
  const bw = Math.min(slot * 0.56, 26);
  let bars = '', labels = '';
  const line = [];
  cats.forEach((c, i) => {
    const x = cx(i), by = y(c.plays);
    bars += `<path d="${topRoundRect(x - bw / 2, by, bw, baseY - by, 5)}" fill="var(--main)"/>`;
    labels += `<text x="${x.toFixed(1)}" y="${(by - 8).toFixed(1)}" text-anchor="middle" font-size="9.5" fill="#8a86a8">${c.plays}</text>`;
    const gy = y(c.games);
    line.push({ x, y: gy });
    labels += `<text x="${x.toFixed(1)}" y="${(gy + 13).toFixed(1)}" text-anchor="middle" font-size="9.5" font-weight="700" fill="#d9d5f3">${c.games}</text>`;
    labels += `<text x="${x.toFixed(1)}" y="${(H - 5).toFixed(1)}" text-anchor="middle" font-size="9" fill="#9a97a8">${esc(c.cat)}</text>`;
  });
  const curve = smoothPath(line);
  const path = curve ? `<path d="${curve}" fill="none" stroke="#d9d5f3" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>` : '';
  return `<svg viewBox="0 0 ${W} ${H}" width="100%" style="display:block;max-height:${H}px;margin:0 auto;">${bars}${path}${labels}</svg>`;
}

function setMyGameSort(sort) {
  state.myGameSort = sort;
  const w = document.getElementById('mgsort-winrate'), p = document.getElementById('mgsort-plays');
  if (w) w.classList.toggle('on', sort === 'winrate');
  if (p) p.classList.toggle('on', sort === 'plays');
  renderMyGameStatList();
}

// 게임별 플레이 리스트(정렬: 승률순/판수순, 게임 이름 검색)
function renderMyGameStatList() {
  const stats = state._myStats;
  if (!stats) return;
  const sort = state.myGameSort || 'winrate';
  const input = document.getElementById('my-gamestat-search');
  const term = (input ? input.value : '').trim().toLowerCase();
  let rows = stats.by_game.slice();
  if (term) rows = rows.filter(g => String(g.game || '').toLowerCase().includes(term));
  rows.sort((a, b) => sort === 'plays'
    ? (b.plays - a.plays || b.win_rate - a.win_rate)
    : (b.win_rate - a.win_rate || b.plays - a.plays));

  const listEl = document.getElementById('my-gamestat-list');
  if (!listEl) return;
  if (!rows.length) {
    listEl.innerHTML = `<div class="empty">${term ? '검색 결과가 없어요.' : '아직 플레이 기록이 없어요.'}</div>`;
    return;
  }
  // 동일 값(정렬 기준) = 공동 순위. 승률순이면 승률, 판수순이면 판수 기준
  const ranks = competitionRanks(rows, g => sort === 'plays' ? g.plays : g.win_rate);
  listEl.innerHTML = rows.map((g, i) => {
    const sc = myGameScores(g.game_id);
    const scoreText = sc.has ? `평균 ${sc.avg}점 · 최고 ${sc.max}점` : '점수 없음';
    const rightNum = sort === 'plays' ? `${g.plays}` : `${g.win_rate}%`;
    const rightLbl = sort === 'plays' ? '판수' : '승률';
    return `<div class="grow" style="cursor:pointer;" onclick="showMyGameStat('${esc(g.game_id)}')">
      <div class="grow-rank">${ranks[i]}</div>
      <div class="grow-body">
        <div class="grow-name">${esc(g.game)}</div>
        <div class="grow-sub">${g.plays}판 · ${g.wins}승 · ${scoreText}</div>
        <div class="winbar"><i style="width:${g.win_rate}%"></i></div>
      </div>
      <div class="grow-rate"><div class="r">${rightNum}</div><div class="rl">${rightLbl}</div></div>
    </div>`;
  }).join('');
}

// ===== MY > 플레이 기록 (내 플레이 기록만) =====
// 기록장에서는 범위 칩(전체/허브별)에 따라 전 허브 세션을 통합 표시
async function renderMyPlaysTab() {
  const el = document.getElementById('my-plays');
  state._editSid = null;   // 탭 진입 시 수정 모드 해제
  const scope = myScope();
  const shell = `${myScopeChipsHtml(scope)}
    <div class="searchbox" style="margin-top:2px;">
      <span>🔍</span>
      <input id="my-play-search" placeholder="일자 · 게임명 · 참가자 검색 (쉼표로 여러 조건)" oninput="filterMyPlays()" />
    </div>
    <div id="my-sessions"></div>`;
  if (scope === 'hub') {
    state._mySessions = state.plays.filter(s =>
      s.participants.some(p => p.player_id === state.user.player_id));
    el.innerHTML = shell;
    filterMyPlays();
    return;
  }
  if (!state._myAllPlays) {
    el.innerHTML = `${myScopeChipsHtml(scope)}<div class="empty"><div class="spinner" style="margin:0 auto;"></div></div>`;
    try {
      state._myAllPlays = await api('getMyPlaysAll') || [];
    } catch (e) {
      el.innerHTML = `${myScopeChipsHtml(scope)}<div class="empty">통합 기록을 불러오지 못했습니다.<br/>${esc(e.message)}</div>`;
      return;
    }
  }
  state._mySessions = scope === 'all'
    ? state._myAllPlays
    : state._myAllPlays.filter(s => s.hub_id === scope);
  el.innerHTML = shell;
  filterMyPlays();
}

// 로그인한 본인이 특정 게임에서 낸 점수들의 평균/최고 (점수 없으면 has=false)
// 기록장 통합 범위에서는 전 허브의 내 점수를 합산
function myGameScores(gameId) {
  const scores = [];
  myScopeSessions().forEach(s => {
    if (s.game_id !== gameId) return;
    s.participants.forEach(p => {
      if (isMyPid(p.player_id) && p.score != null && p.score !== '') {
        const n = Number(p.score);
        if (!isNaN(n)) scores.push(n);
      }
    });
  });
  if (!scores.length) return { has: false };
  const avg = Math.round((scores.reduce((a, b) => a + b, 0) / scores.length) * 10) / 10;
  const max = Math.max(...scores);
  return { has: true, avg, max };
}

// 내 플레이 기록 세션 검색: 쉼표(,)로 여러 조건 AND 검색
// 각 조건은 일자 · 게임명 · 참가자 이름 어디든 포함되면 매칭, 모든 조건을 만족해야 표시.
function filterMyPlays() {
  const all = state._mySessions || [];
  const input = document.getElementById('my-play-search');
  const raw = input ? input.value : '';
  const terms = raw.split(',').map(t => t.trim().toLowerCase()).filter(Boolean);
  const list = !terms.length ? all : all.filter(s => {
    const hay = [
      String(s.play_date || ''),
      String(s.game_name || ''),
      String(s.hub_name || ''),
      ...s.participants.map(p => String(p.name || ''))
    ].join(' ').toLowerCase();
    return terms.every(t => hay.includes(t));
  });
  renderSessionList('my-sessions', list);
}

// 내 평점을 (중복 없이) 한 번만 불러오는 공용 로더.
// MY 진입 시 전체기록 통계와 '병렬로' 미리 당겨두어 게임기록 탭을 즉시 표시.
function ensureMyRatings() {
  if (state._myRatings) return Promise.resolve(state._myRatings);
  if (state._myRatingsPromise) return state._myRatingsPromise;
  state._myRatingsPromise = api('getMyRatings', { playerId: state.user.player_id })
    .then(list => {
      const map = {};
      (list || []).forEach(r => { map[r.game_id] = r; });
      state._myRatings = map;
      state._myRatingsPromise = null;
      return map;
    })
    .catch(e => { state._myRatingsPromise = null; throw e; });
  return state._myRatingsPromise;
}

async function renderMyGames() {
  const el = document.getElementById('my-games');
  const scope = myScope();
  if (scope !== 'hub') { renderMyGamesAll(el, scope); return; }
  // 캐시가 없으면 로드(진입 시 미리 당겨뒀다면 즉시 완료)
  if (!state._myRatings) {
    el.innerHTML = `<div class="empty"><div class="spinner" style="margin:0 auto;"></div></div>`;
    try {
      await ensureMyRatings();
    } catch (e) {
      el.innerHTML = `<div class="empty">불러오지 못했습니다.<br/>${esc(e.message)}</div>`;
      return;
    }
  }
  try {
    // 본인이 참가한 게임만. state.plays는 서버가 '일자 → 같으면 저장 최신'
    // 순으로 내려주므로(플레이기록 탭과 동일), 게임별로 내 세션이 처음
    // 등장하는 위치를 기억해 그 순서대로 정렬 → 두 탭의 순서가 항상 일치
    const playedGameIds = new Set();
    const firstIdx = {};   // game_id -> 내 최신 세션의 위치
    state.plays.forEach((s, i) => {
      if (s.participants.some(p => p.player_id === state.user.player_id)) {
        playedGameIds.add(s.game_id);
        if (firstIdx[s.game_id] == null) firstIdx[s.game_id] = i;
      }
    });
    // 내가 최근에 플레이(저장)한 게임이 위로
    const games = state.games.filter(g => playedGameIds.has(g.game_id))
      .sort((a, b) => firstIdx[a.game_id] - firstIdx[b.game_id]);
    if (!games.length) {
      el.innerHTML = `${myScopeChipsHtml('hub')}<div class="empty"><div class="big">🎮</div>아직 참가한 게임이 없어요.<br/>플레이 결과를 추가하면 여기에 표시됩니다.</div>`;
      return;
    }
    state._myGamesList = games;
    el.innerHTML = `${myScopeChipsHtml('hub')}
      <div class="hint" style="margin-bottom:10px;text-align:center;">내가 참가한 게임에 평점과 메모를 남겨보세요. <br>평점 평균이 '우리Hub평점'이 됩니다.</div>
      <div class="searchrow">
        <div class="searchbox"><span>🔍</span><input id="my-games-search" placeholder="게임 이름, 카테고리 검색" oninput="filterMyGames()" /></div>
        <button class="sortbtn ${state.myGamesSortRating ? 'on' : ''}" id="my-games-sort-btn" title="내 평점 정렬" onclick="cycleMyGamesSort()">${sortBtnLabel(state.myGamesSortRating)}</button>
      </div>
      <div id="my-games-cards"></div>`;
    filterMyGames();
  } catch (e) {
    el.innerHTML = `<div class="empty">불러오지 못했습니다.<br/>${esc(e.message)}</div>`;
  }
}

// 게임 기록 통합(전체/특정 허브): 허브 게임 기록과 같은 카드 형식.
// ★=전체 이용자 평점(공용 도감 기준), 나 ★=내 평점(허브별 평균).
// 평점·후기·메모 편집은 각 허브의 게임 기록에서.
async function renderMyGamesAll(el, scope) {
  const chips = myScopeChipsHtml(scope);
  if (!state._myAllGames) {
    el.innerHTML = `${chips}<div class="empty"><div class="spinner" style="margin:0 auto;"></div></div>`;
    try {
      state._myAllGames = await api('getMyGamesAll') || [];
    } catch (e) {
      el.innerHTML = `${chips}<div class="empty">통합 기록을 불러오지 못했습니다.<br/>${esc(e.message)}</div>`;
      return;
    }
  }
  // 내 최근 플레이 순으로 게임 목록 구성(카드 정보는 myGameInfo가 합산)
  const rows = state._myAllGames.filter(r => scope === 'all' || r.hub_id === scope);
  const order = []; const seen = new Set();
  rows.slice().sort((a, b) => a.first_rn - b.first_rn).forEach(r => {
    if (!seen.has(r.game_id)) { seen.add(r.game_id); order.push(r.game_id); }
  });
  const games = order.map(gid => myGameInfo(gid)).filter(Boolean);
  if (!games.length) {
    el.innerHTML = `${chips}<div class="empty"><div class="big">🎮</div>이 범위에는 아직 참가한 게임이 없어요.</div>`;
    return;
  }
  state._myGamesAllList = games;
  el.innerHTML = `${chips}
    <div class="hint" style="margin-bottom:10px;text-align:center;">여러 허브의 내 게임 기록을 모아 보여줘요. (★=전체 이용자 평점)<br>평점·후기·메모는 각 허브의 게임 기록에서 남길 수 있어요.</div>
    <div class="searchrow">
      <div class="searchbox"><span>🔍</span><input id="my-gamesall-search" placeholder="게임 이름, 카테고리 검색" oninput="filterMyGamesAll()" /></div>
      <button class="sortbtn ${state.myGamesSortRating ? 'on' : ''}" id="my-gamesall-sort-btn" title="내 평점 정렬" onclick="cycleMyGamesAllSort()">${sortBtnLabel(state.myGamesSortRating)}</button>
    </div>
    <div id="my-gamesall-cards"></div>`;
  filterMyGamesAll();
}

function cycleMyGamesAllSort() {
  state.myGamesSortRating = nextSortMode(state.myGamesSortRating);
  const b = document.getElementById('my-gamesall-sort-btn');
  b.textContent = sortBtnLabel(state.myGamesSortRating);
  b.classList.toggle('on', !!state.myGamesSortRating);
  filterMyGamesAll();
}

function filterMyGamesAll() {
  const all = state._myGamesAllList || [];
  const input = document.getElementById('my-gamesall-search');
  const term = (input ? input.value : '').trim().toLowerCase();
  let list = !term ? all : all.filter(g =>
    String(g.name_kr || '').toLowerCase().includes(term) ||
    String(g.name_en || '').toLowerCase().includes(term) ||
    String(g.category || '').toLowerCase().includes(term));
  // 내 평점 기준 정렬(해제 시 최근 플레이 순 유지)
  list = applyRatingSort(list, state.myGamesSortRating, g => g._my_rating);
  const cards = document.getElementById('my-gamesall-cards');
  if (!cards) return;
  cards.innerHTML = list.length
    ? list.map(g => gameCardHtml(g, { showMine: true, myDetail: true })).join('')
    : `<div class="empty">검색 결과가 없어요.</div>`;
}

function cycleMyGamesSort() {
  state.myGamesSortRating = nextSortMode(state.myGamesSortRating);
  const b = document.getElementById('my-games-sort-btn');
  b.textContent = sortBtnLabel(state.myGamesSortRating);
  b.classList.toggle('on', !!state.myGamesSortRating);
  filterMyGames();
}

function filterMyGames() {
  const all = state._myGamesList || [];
  const input = document.getElementById('my-games-search');
  const term = (input ? input.value : '').trim().toLowerCase();
  let list = !term ? all : all.filter(g =>
    String(g.name_kr || '').toLowerCase().includes(term) ||
    String(g.name_en || '').toLowerCase().includes(term) ||
    String(g.category || '').toLowerCase().includes(term));
  // 내 평점 기준 정렬(해제 시 최근 플레이 순 유지)
  list = applyRatingSort(list, state.myGamesSortRating, g => {
    const r = state._myRatings && state._myRatings[g.game_id];
    return (r && r.rating != null && r.rating !== '') ? Number(r.rating) : null;
  });
  const cards = document.getElementById('my-games-cards');
  if (!cards) return;
  cards.innerHTML = list.length
    ? list.map(g => gameCardHtml(g, { ratingEditor: true })).join('')
    : `<div class="empty">검색 결과가 없어요.</div>`;
}

// ===== 별점 에디터 =====
function ratingEditorHtml(g) {
  const existing = (state._myRatings && state._myRatings[g.game_id]) || null;
  const val = existing ? existing.rating : 0;
  const review = existing ? (existing.review || '') : '';
  return `<div class="rate-edit" data-gid="${g.game_id}">
    <label style="font-size:12px;font-weight:700;color:var(--text-sub);">내 평점 (1~10, 0.5 단위)</label>
    <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;">
      <div class="stars" id="stars-${g.game_id}" data-val="${val || ''}">${starsHtml(val)}</div>
      <div class="rate-val" id="rateval-${g.game_id}" style="margin:0;white-space:nowrap;">${val ? val.toFixed(1) + ' 점' : '평점 선택'}</div>
    </div>
    <label style="font-size:12px;font-weight:700;color:var(--text-sub);display:block;margin-top:10px;margin-bottom:5px;">한줄 후기 <span class="muted" style="font-weight:500;">(게임 탭에 공개돼요)</span></label>
    <textarea class="input" id="review-${g.game_id}" placeholder="이 게임 어땠나요? 후기를 공유해 주세요!">${esc(review)}</textarea>
    <button class="btn" style="margin-top:5px;width:100%;padding:9px;" onclick="saveRating('${g.game_id}')">평점·후기 저장</button>
  </div>`;
}

function starsHtml(val) {
  // 별 10개 = 10점 만점. 별 1개 = 1점, 별 왼쪽 절반 = 0.5점 (0.5 단위)
  let html = '';
  for (let i = 1; i <= 10; i++) {
    const full = val >= i;
    const half = !full && val >= i - 0.5;
    html += `<span class="s ${full ? 'filled' : (half ? 'half' : '')}"
      data-star="${i}"
      onclick="pickStar(event, ${i})"
      oncontextmenu="return false;">★</span>`;
  }
  return html;
}

// 별 왼쪽 절반 탭 = 0.5점, 오른쪽 = 1.0점
function pickStar(e, starIndex) {
  const rect = e.target.getBoundingClientRect();
  const isLeft = (e.clientX - rect.left) < rect.width / 2;
  const val = starIndex - (isLeft ? 0.5 : 0);
  const gid = e.target.closest('.rate-edit').dataset.gid;
  const container = document.getElementById('stars-' + gid);
  container.innerHTML = starsHtml(val);
  container.dataset.val = val;
  document.getElementById('rateval-' + gid).textContent = (val / 1).toFixed(1) + ' 점';
}

async function saveRating(gameId) {
  if (!state.user) { toast('로그인이 필요합니다.', true); return; }
  const container = document.getElementById('stars-' + gameId);
  const val = Number(container.dataset.val || 0);
  const review = document.getElementById('review-' + gameId).value;
  const hasRating = val > 0;
  const hasReview = review.trim() !== '';
  // 둘 중 하나만 입력해도 저장(빈 칸은 기존 값 그대로 유지)
  if (!hasRating && !hasReview) { toast('평점이나 후기 중 하나 이상 입력하세요.', true); return; }
  const pin = await promptPin();
  if (pin == null) return;
  showLoader('저장 중…');
  try {
    if (hasRating) await api('saveRating', { playerId: state.user.player_id, pin, gameId, rating: val });
    if (hasReview) await api('saveReview', { playerId: state.user.player_id, pin, gameId, review });
    if (!state._myRatings) state._myRatings = {};
    const upd = { game_id: gameId };
    if (hasRating) upd.rating = val;
    if (hasReview) upd.review = review;
    state._myRatings[gameId] = Object.assign({}, state._myRatings[gameId], upd);
    // 평점이 바뀌었으면 Hub 평점 갱신 위해 게임 목록 재로드
    if (hasRating) state.games = await api('getGames');
    toast('저장되었습니다!');
    if (state.myTab === 'games' && document.getElementById('my-games-cards')) filterMyGames();
  } catch (e) {
    toast(e.message, true);
  } finally {
    hideLoader();
  }
}

// PIN 재확인 (간단 prompt)
function promptPin() {
  return new Promise(resolve => {
    const cached = localStorage.getItem('bg_pin');
    if (cached) { resolve(cached); return; }
    const pin = window.prompt('PIN을 입력하세요 (본인 확인)');
    if (pin) localStorage.setItem('bg_pin', pin);
    resolve(pin);
  });
}

// ============================================================
//  Add Sheet: 게임 추가 / 플레이 결과
// ============================================================
function openAddSheet() {
  if (!state.user) {
    toast('입력하려면 MY에서 로그인하세요.', true);
    switchView('my');
    return;
  }
  document.getElementById('add-overlay').classList.add('show');
  openOverlay(() => document.getElementById('add-overlay').classList.remove('show'));
  switchAddTab('play');
}
function closeAddSheet() { closeOverlay(); }
document.getElementById('add-overlay').addEventListener('click', e => {
  if (e.target.id === 'add-overlay') closeOverlay();
});

function switchAddTab(tab) {
  document.getElementById('addtab-game').classList.toggle('on', tab === 'game');
  document.getElementById('addtab-play').classList.toggle('on', tab === 'play');
  document.getElementById('add-game-form').style.display = tab === 'game' ? 'block' : 'none';
  document.getElementById('add-play-form').style.display = tab === 'play' ? 'flex' : 'none';
  if (tab === 'game') renderAddGameForm();
  else renderAddPlayForm();
}

// ----- 게임 추가 -----
// 기본 분류(폴백). 앱 시작 시 Supabase categories 테이블에서 읽어와 덮어씀
let CATEGORIES = ['전략', '마피아', '파티게임', '트릭테이킹', '1대1 게임', '카드게임', '경매게임', '협력게임'];
function renderAddGameForm() {
  const el = document.getElementById('add-game-form');
  el.innerHTML = `
    <div class="field">
      <label>한글 게임명 *</label>
      <div class="ac-wrap">
        <input class="input" id="ag-namekr" placeholder="예: 스컬킹" autocomplete="off"
               oninput="checkNewGameName(); acRender(this,'game')" onblur="acHide(this)" />
        <div class="ac-menu"></div>
      </div>
      <div class="mchk" id="ag-namecheck" style="margin-top:4px;display:none;"></div>
    </div>
    <div class="field">
      <label>영문 게임명 (선택)</label>
      <input class="input" id="ag-nameen" placeholder="예: Skull King" />
    </div>
    <div class="field">
      <label>보드게임 분류 *</label>
      <select class="input" id="ag-category">
        ${CATEGORIES.map(c => `<option value="${c}">${c}</option>`).join('')}
      </select>
    </div>
    <div class="row2">
      <div class="field"><label>최소 인원</label><input class="input" id="ag-min" type="number" inputmode="numeric" /></div>
      <div class="field"><label>최대 인원</label><input class="input" id="ag-max" type="number" inputmode="numeric" /></div>
    </div>
    <div class="row2">
      <div class="field"><label>플레이타임(분)</label><input class="input" id="ag-time" type="number" inputmode="numeric" /></div>
      <div class="field"><label>난이도(weight)</label><input class="input" id="ag-weight" type="number" step="0.01" inputmode="decimal" /></div>
    </div>
    <div class="field"><label>이미지 URL (선택)</label><input class="input" id="ag-image" placeholder="https://..." /></div>
    <div class="field"><label>게임 요약</label><textarea class="input" id="ag-summary" placeholder="게임 설명"></textarea></div>
    <div class="field">
      <label>게임 사진 (선택 — 찍거나 앨범에서 선택)</label>
      <input class="input" id="ag-photo" type="file" accept="image/*" onchange="onPhotoPick(this,'ag')" />
      <div id="ag-photo-preview"></div>
      <div class="hint">사진을 올리면 작게 압축해서 저장합니다. 올리면 url 대신 사용합니다</div>
    </div>
    <button class="btn sheet-save" onclick="submitAddGame()">게임 추가</button>`;
  photoState.ag = '';
}

// ===== 사진 업로드(썸네일 압축) =====
const photoState = { ag: '', eg: '' };

// 파일을 최대 maxDim px 썸네일 JPEG data URI로 변환. GET 전송 위해 targetLen 이하로 압축.
function fileToThumbDataUrl(file, maxDim, targetLen) {
  // 카드 썸네일은 작으므로(≤68px) 240px면 충분. GET URL 길이 안전하게 ~6.5KB 이하로 압축.
  maxDim = maxDim || 240;
  targetLen = targetLen || 6500;
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(new Error('read fail'));
    reader.onload = () => {
      const img = new Image();
      img.onerror = () => reject(new Error('decode fail'));
      img.onload = () => {
        const scale = Math.min(1, maxDim / Math.max(img.width, img.height));
        const w = Math.max(1, Math.round(img.width * scale));
        const h = Math.max(1, Math.round(img.height * scale));
        const canvas = document.createElement('canvas');
        canvas.width = w; canvas.height = h;
        canvas.getContext('2d').drawImage(img, 0, 0, w, h);
        let q = 0.6;
        let out = canvas.toDataURL('image/jpeg', q);
        while (out.length > targetLen && q > 0.25) { q -= 0.1; out = canvas.toDataURL('image/jpeg', q); }
        resolve(out);
      };
      img.src = reader.result;
    };
    reader.readAsDataURL(file);
  });
}

async function onPhotoPick(input, prefix) {
  const file = input.files && input.files[0];
  if (!file) return;
  showLoader('사진 처리 중…');
  try {
    const dataUrl = await fileToThumbDataUrl(file);
    photoState[prefix] = dataUrl;
    document.getElementById(prefix + '-photo-preview').innerHTML =
      `<div style="margin-top:8px;display:flex;align-items:center;gap:10px;">
         <img src="${dataUrl}" style="width:64px;height:64px;object-fit:cover;border-radius:10px;"/>
         <button type="button" class="btn ghost sm" onclick="clearPhoto('${prefix}')">사진 제거</button>
       </div>`;
  } catch (e) {
    toast('사진을 불러오지 못했습니다.', true);
  } finally {
    hideLoader();
  }
}

function clearPhoto(prefix) {
  photoState[prefix] = '';
  const pv = document.getElementById(prefix + '-photo-preview');
  if (pv) pv.innerHTML = '';
  const inp = document.getElementById(prefix + '-photo');
  if (inp) inp.value = '';
}

async function submitAddGame() {
  const nameKr = document.getElementById('ag-namekr').value.trim();
  const category = document.getElementById('ag-category').value;
  if (!nameKr) { toast('한글 게임명을 입력하세요.', true); return; }
  // 중복 게임명 등록 차단(공백·대소문자 무시, 닉네임 중복 방지와 동일)
  const nk = normGameName(nameKr);
  if (state.games.some(g => normGameName(g.name_kr) === nk)) {
    toast('이미 등록된 게임명입니다.', true); return;
  }
  const pin = await promptPin();
  if (pin == null) return;

  const payload = {
    player_id: state.user.player_id, pin,
    name_kr: nameKr,
    name_en: document.getElementById('ag-nameen').value.trim(),
    category,
    min_players: document.getElementById('ag-min').value,
    max_players: document.getElementById('ag-max').value,
    playtime_min: document.getElementById('ag-time').value,
    weight: document.getElementById('ag-weight').value,
    image_url: photoState.ag || document.getElementById('ag-image').value.trim(),
    summary_kr: document.getElementById('ag-summary').value
  };

  showLoader('저장 중…');
  try {
    // payload는 api()의 URLSearchParams가 인코딩하므로 여기서 추가 인코딩하지 않음
    await api('addGame', { payload: JSON.stringify(payload) });
    state.games = await api('getGames');
    toast('게임이 추가되었습니다!');
    closeAddSheet();
    switchView('games');
    renderGames();
  } catch (e) {
    toast(e.message, true);
  } finally {
    hideLoader();
  }
}

// ----- 플레이 결과 추가 -----
const addPlayState = { participants: [] };

// 한글 자모 분해 → 오타 유사도(레벤슈타인) 계산용
function decomposeHangul(str) {
  const CHO = 'ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ';
  const JUNG = 'ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ';
  const JONG = ' ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ';
  let out = '';
  for (const ch of String(str)) {
    const c = ch.charCodeAt(0);
    if (c >= 0xAC00 && c <= 0xD7A3) {
      const s = c - 0xAC00;
      out += CHO[Math.floor(s / 588)] + JUNG[Math.floor((s % 588) / 28)] + JONG[s % 28];
    } else out += ch;
  }
  return out.replace(/\s/g, '');
}
function editDistance(a, b) {
  const m = a.length, n = b.length;
  if (!m) return n; if (!n) return m;
  let prev = Array.from({ length: n + 1 }, (_, i) => i);
  for (let i = 1; i <= m; i++) {
    const cur = [i];
    for (let j = 1; j <= n; j++) {
      cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
    prev = cur;
  }
  return prev[n];
}
// 오타 수준으로 비슷한 기존 게임명 찾기(자모 기준 편집거리 ≤ 2, 길이 비례)
function similarGameName(name) {
  const q = decomposeHangul(name.trim());
  if (q.length < 2) return null;
  let best = null, bestD = Infinity;
  state.games.forEach(g => {
    [g.name_kr, g.name_en].forEach(nm => {
      if (!nm) return;
      const d = editDistance(q, decomposeHangul(String(nm).trim()));
      if (d < bestD) { bestD = d; best = nm; }
    });
  });
  const limit = q.length <= 4 ? 1 : 2;   // 짧은 이름은 더 엄격
  return (best && bestD > 0 && bestD <= limit) ? best : null;
}

// 게임명 정규화: 공백 제거 + 소문자 (띄어쓰기·대소문자만 다른 건 같은 게임으로 취급)
function normGameName(s) { return String(s || '').replace(/\s+/g, '').toLowerCase(); }

// 게임 추가: 한글명 실시간 중복/유사 검사
function checkNewGameName() {
  const el = document.getElementById('ag-namecheck');
  const inp = document.getElementById('ag-namekr');
  if (!el || !inp) return;
  const name = inp.value.trim();
  if (!name) { el.style.display = 'none'; return; }
  el.style.display = 'block';
  const key = normGameName(name);
  const dup = state.games.find(g => normGameName(g.name_kr) === key);
  if (dup) {
    el.className = 'mchk dup';
    el.textContent = '⚠ 이미 등록된 게임명이에요 — 추가할 수 없어요';
    return;
  }
  const sim = similarGameName(name);
  if (sim) {
    el.className = 'mchk no';
    el.textContent = `혹시 "${sim}"인가요? (없으면 그대로 추가하셔도 돼요)`;
  } else {
    el.className = 'mchk ok';
    el.textContent = '✓ 등록 가능한 새 게임명이에요';
  }
  // 공용 도감(다른 허브 등록분) 검사 — 있으면 정보를 끌어온다고 안내
  clearTimeout(state._catalogTimer);
  state._catalogTimer = setTimeout(async () => {
    try {
      const list = await api('searchCatalog', { term: name });
      if (document.getElementById('ag-namekr')?.value.trim() !== name) return;  // 입력이 바뀜
      const hit = (list || []).find(g => normGameName(g.name_kr) === key && !g.on_shelf);
      if (hit) {
        el.className = 'mchk ok';
        el.textContent = `📚 "${hit.name_kr}" — 다른 허브에 등록된 게임이에요. 추가하면 정보를 그대로 가져와요`;
      }
    } catch (e) {}
  }, 350);
}

// 정확히 일치하는 게임/플레이어만 허용(데이터 오류 방지)
function gameByExactName(name) {
  name = (name || '').trim();
  if (!name) return null;
  return state.games.find(g => (g.name_kr || '') === name || (g.name_en || '') === name) || null;
}
function playerByExactName(name) {
  name = (name || '').trim();
  if (!name) return null;
  return state.players.find(p => (p.name || '') === name) || null;
}

function renderAddPlayForm() {
  if (!addPlayState.participants.length) {
    addPlayState.participants = [{ name: '', score: '', is_win: false, is_guest: false }];
  }
  const el = document.getElementById('add-play-form');
  const today = new Date().toISOString().substring(0, 10);

  el.innerHTML = `
    <div class="row2 wrapdate">
      <div class="field"><label>플레이 일자</label><input class="input" id="ap-date" type="date" value="${today}" /></div>
      <div class="field"><label>플레이 시간(분)</label><input class="input" id="ap-duration" type="number" inputmode="numeric" placeholder="예: 45" /></div>
    </div>
    <div class="field">
      <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:6px;">
        <label style="margin:0;flex:0 0 auto;">게임 *</label>
        <div class="mchk no" id="gmchk" style="min-width:0;text-align:right;word-break:keep-all;">아직 등록되지 않은 게임은 추가해 주세요</div>
      </div>
      <div class="ac-wrap">
        <input class="input" id="ap-game" placeholder="게임명 입력" autocomplete="off"
               oninput="acRender(this,'game'); updateGameBadge()" onblur="acHide(this)" />
        <div class="ac-menu"></div>
      </div>
    </div>
    <div class="field ap-parts-field">
      <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:6px;flex:0 0 auto;">
        <label style="margin:0;">참가자 (비회원은 체크)</label>
        <span style="display:flex;gap:6px;flex:0 0 auto;">
          <button class="btn ghost sm" id="ap-scroll-btn" style="padding:5px 12px;font-size:12px;" onclick="apScrollToggle()">↓ 아래로</button>
          <button class="btn ghost sm" style="padding:5px 12px;font-size:12px;" onclick="addParticipant()">+ 참가자 추가</button>
        </span>
      </div>
      <div id="ap-participants" onscroll="apScrollBtnUpdate()"></div>
    </div>
    <button class="btn sheet-save" onclick="submitAddPlay()">플레이 결과 저장</button>`;
  renderParticipants();
}

// ===== 접두어 자동완성 (입력한 글자로 '시작하는' 항목만 표시) =====
function acNames(kind) {
  if (kind === 'game') return state.games.map(g => g.name_kr || g.name_en).filter(Boolean);
  return (state.players || []).map(p => p.name).filter(Boolean);
}

// 공용 도감 검색 결과 캐시(정규화 이름 → 게임). 플레이 추가·게임 추가에서 공용.
async function fetchCatalog(term) {
  try {
    const list = await api('searchCatalog', { term });
    state._catalogHits = state._catalogHits || {};
    (list || []).forEach(g => { if (g.name_kr) state._catalogHits[normGameName(g.name_kr)] = g; });
    return list || [];
  } catch (e) { return []; }
}

function acRender(inp, kind) {
  const wrap = inp.closest('.ac-wrap');
  const menu = wrap && wrap.querySelector('.ac-menu');
  if (!menu) return;
  const term = inp.value.trim().toLowerCase();
  if (!term) { menu.classList.remove('show'); menu.innerHTML = ''; return; }
  const seen = new Set();
  const matches = acNames(kind).filter(n => {
    const low = n.toLowerCase();
    if (!low.startsWith(term) || seen.has(low)) return false;
    seen.add(low); return true;
  }).sort((a, b) => a.localeCompare(b)).slice(0, 8);
  // 후보가 없거나, 이미 정확히 일치하는 하나뿐이면 표시하지 않음
  const emptySync = !matches.length || (matches.length === 1 && matches[0].toLowerCase() === term);
  if (emptySync) {
    menu.classList.remove('show'); menu.innerHTML = '';
    if (kind !== 'game') return;   // 게임은 도감 검색을 이어감
  } else {
    menu.innerHTML = matches.map(n => `<div class="ac-item" onmousedown="acPick(event, this)">${esc(n)}</div>`).join('');
    menu.classList.add('show');
  }

  // 게임 검색: 우리 선반에 없어도 공용 도감에서 찾아 함께 제시(📚)
  if (kind === 'game') {
    clearTimeout(state._acCatTimer);
    state._acCatTimer = setTimeout(async () => {
      const now = inp.value.trim().toLowerCase();
      const list = await fetchCatalog(inp.value.trim());
      if (inp.value.trim().toLowerCase() !== now) return;   // 입력이 바뀜
      const extra = (list || []).filter(g =>
        !g.on_shelf && g.name_kr &&
        g.name_kr.toLowerCase().includes(now) &&
        !seen.has(g.name_kr.toLowerCase())
      ).slice(0, 5);
      if (!extra.length) { updateGameBadge(); return; }
      const shelfItems = emptySync ? '' : matches.map(n => `<div class="ac-item" onmousedown="acPick(event, this)">${esc(n)}</div>`).join('');
      menu.innerHTML = shelfItems
        + extra.map(g => `<div class="ac-item" data-name="${esc(g.name_kr)}" onmousedown="acPick(event, this)">📚 ${esc(g.name_kr)}</div>`).join('');
      menu.classList.add('show');
      updateGameBadge();
    }, 300);
  }
}
function acPick(e, item) {
  e.preventDefault();   // 클릭 시 input이 blur되지 않도록 → 포커스 유지
  const wrap = item.closest('.ac-wrap');
  const inp = wrap.querySelector('input');
  inp.value = item.dataset.name || item.textContent;
  const menu = wrap.querySelector('.ac-menu');
  menu.classList.remove('show'); menu.innerHTML = '';
  inp.dispatchEvent(new Event('input', { bubbles: true }));  // 상태 갱신(updatePart 등)
}
function acHide(inp) {
  const wrap = inp.closest('.ac-wrap');
  const menu = wrap && wrap.querySelector('.ac-menu');
  if (menu) setTimeout(() => menu.classList.remove('show'), 120);
}

// 게임명 일치 배지: 정확히 일치하는 게임이면 초록, 아니면 회색 안내
function updateGameBadge() {
  const el = document.getElementById('gmchk');
  const inp = document.getElementById('ap-game');
  if (!el || !inp) return;
  const v = inp.value.trim();
  if (gameByExactName(v)) {
    el.textContent = '✓ 등록된 게임이에요';
    el.className = 'mchk ok';
    return;
  }
  const cat = v && state._catalogHits && state._catalogHits[normGameName(v)];
  if (cat) {
    el.textContent = '📚 도감의 게임이에요 · 저장하면 우리 허브에 자동 등록';
    el.className = 'mchk ok';
    return;
  }
  el.textContent = '일치하는 게임이 없어요';
  el.className = 'mchk no';
}

// 회원 일치 배지: 정확히 일치하는 회원이면 초록 '회원이에요', 아니면 '일치하는 회원이 없어요'
function memberBadgeHtml(i, pt) {
  if (pt.is_guest) return '';
  const ok = !!playerByExactName((pt.name || '').trim());
  return `<span class="mchk ${ok ? 'ok' : 'no'}" id="mchk-${i}">${ok ? '✓ 회원이에요' : '일치하는 회원이 없어요'}</span>`;
}
function updateMemberBadge(i) {
  const el = document.getElementById('mchk-' + i);
  if (!el) return;
  const ok = !!playerByExactName((addPlayState.participants[i].name || '').trim());
  el.textContent = ok ? '✓ 회원이에요' : '일치하는 회원이 없어요';
  el.className = 'mchk ' + (ok ? 'ok' : 'no');
}

function renderParticipants() {
  const el = document.getElementById('ap-participants');
  el.innerHTML = addPlayState.participants.map((pt, i) => `
    <div style="margin-bottom:10px;">
      <div class="ppart" style="margin-bottom:4px;">
        <span style="flex:0 0 auto;min-width:16px;text-align:center;font-size:12px;font-weight:800;color:var(--text-sub);">${i + 1}</span>
        ${pt.is_guest
          ? `<input class="input" placeholder="게스트 닉네임" autocomplete="off" style="flex:2;min-width:0;"
               value="${esc(pt.name)}" oninput="updatePart(${i}, 'name', this.value)" />`
          : `<div class="ac-wrap" style="flex:2;min-width:0;">
               <input class="input" placeholder="회원 이름 입력" autocomplete="off"
                 value="${esc(pt.name)}" oninput="updatePart(${i}, 'name', this.value); acRender(this,'player')" onblur="acHide(this)" />
               <div class="ac-menu"></div>
             </div>`}
        <input class="input" type="number" inputmode="numeric" placeholder="점수" value="${esc(pt.score)}" oninput="updatePart(${i}, 'score', this.value)" style="flex:1;min-width:0;" />
        <button class="wintoggle ${pt.is_win ? 'on' : ''}" onclick="toggleWin(${i})">${pt.is_win ? '승 👑' : '패 🥈'}</button>
        ${addPlayState.participants.length > 1 ? `<button class="rm-btn" onclick="removePart(${i})">×</button>` : ''}
      </div>
      <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;padding-left:2px;">
        ${memberBadgeHtml(i, pt)}
        <label style="display:inline-flex;align-items:center;gap:5px;font-size:12px;color:var(--text-sub);cursor:pointer;margin-left:auto;">
          <input type="checkbox" ${pt.is_guest ? 'checked' : ''} onchange="toggleGuest(${i}, this.checked)" style="width:15px;height:15px;margin:0;" />
          비회원(게스트)
        </label>
      </div>
    </div>`).join('');
}

function addParticipant() {
  addPlayState.participants.push({ name: '', score: '', is_win: false, is_guest: false });
  renderParticipants();
  // 새로 추가된 참가자 입력칸이 보이도록 목록을 맨 아래로 스크롤
  const el = document.getElementById('ap-participants');
  if (el) el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' });
}

// 참가자 목록 스크롤 토글: 맨 위에 있으면 [↓ 아래로], 내려가 있으면 [↑ 위로]
function apScrollToggle() {
  const el = document.getElementById('ap-participants');
  if (!el) return;
  const atTop = el.scrollTop < 10;
  el.scrollTo({ top: atTop ? el.scrollHeight : 0, behavior: 'smooth' });
}
function apScrollBtnUpdate() {
  const el = document.getElementById('ap-participants');
  const b = document.getElementById('ap-scroll-btn');
  if (!el || !b) return;
  b.textContent = el.scrollTop < 10 ? '↓ 아래로' : '↑ 위로';
}
function removePart(i) { addPlayState.participants.splice(i, 1); renderParticipants(); }
function updatePart(i, field, val) {
  addPlayState.participants[i][field] = val;
  if (field === 'name') updateMemberBadge(i);   // 회원 일치 배지 실시간 갱신
}
function toggleWin(i) { addPlayState.participants[i].is_win = !addPlayState.participants[i].is_win; renderParticipants(); }
function toggleGuest(i, checked) { addPlayState.participants[i].is_guest = checked; renderParticipants(); }

async function submitAddPlay() {
  const nameV = document.getElementById('ap-game').value.trim();
  let game = gameByExactName(nameV);
  if (!game && nameV && state._catalogHits) {
    // 우리 선반엔 없지만 공용 도감에 있는 게임 → 그대로 기록(서버가 선반에 자동 등재)
    const c = state._catalogHits[normGameName(nameV)];
    if (c) game = { game_id: c.game_id, name_kr: c.name_kr };
  }
  if (!game) { toast('게임을 목록에 있는 이름으로 정확히 입력/선택하세요.', true); return; }
  const playDate = document.getElementById('ap-date').value;
  const duration = document.getElementById('ap-duration').value;

  const rawParts = addPlayState.participants.filter(p => (p.name || '').trim());
  if (!rawParts.length) { toast('참가자를 추가하세요.', true); return; }
  const resolved = [];
  const seen = new Set();
  for (const p of rawParts) {
    const nm = p.name.trim();
    let player_id = '', player_name = nm;
    if (p.is_guest) {
      // 게스트: 자유 닉네임 그대로 저장(회원 계정 연결 안 함)
      player_id = '';
      player_name = nm;
    } else {
      const pl = playerByExactName(nm);
      if (!pl) { toast(`"${nm}"은(는) 회원 명단에 없어요. 비회원이면 아래 '비회원(게스트)'를 체크하세요.`, true); return; }
      player_id = pl.player_id;
      player_name = pl.name;
    }
    const key = player_id ? ('m:' + player_id) : ('g:' + player_name);
    if (seen.has(key)) { toast('참가자가 중복되었습니다.', true); return; }
    seen.add(key);
    resolved.push({ player_id, player_name, score: p.score, is_win: !!p.is_win });
  }

  const pin = await promptPin();
  if (pin == null) return;

  const payload = {
    player_id: state.user.player_id, pin,
    play_date: playDate, duration_min: duration, game_id: game.game_id,
    participants: resolved
  };

  showLoader('저장 중…');
  try {
    await api('addPlay', { payload: JSON.stringify(payload) });
    state.plays = await api('getPlays');
    state.games = await api('getGames');
    state._myStats = null;    // 새 플레이는 개인 통계에 영향 → 다음 MY 진입 시 새로 로드
    addPlayState.participants = [];
    toast('플레이 결과가 저장되었습니다!');
    closeAddSheet();
    switchView('play');
    renderPlay();
  } catch (e) {
    toast(e.message, true);
  } finally {
    hideLoader();
  }
}

// ============================================================
//  Admin: 게임 정보 수정
// ============================================================
function openEditGame(gameId) {
  const g = gameById(gameId);
  if (!g) return;
  const el = document.getElementById('detail-body');
  el.innerHTML = `
    <h2>게임 정보 수정</h2>
    <div class="field"><label>한글명</label><input class="input" id="eg-namekr" value="${esc(g.name_kr)}" /></div>
    <div class="field"><label>영문명</label><input class="input" id="eg-nameen" value="${esc(g.name_en)}" /></div>
    <div class="field"><label>분류</label>
      <select class="input" id="eg-category">
        ${CATEGORIES.map(c => `<option value="${c}" ${g.category === c ? 'selected' : ''}>${c}</option>`).join('')}
      </select>
    </div>
    <div class="row2">
      <div class="field"><label>최소 인원</label><input class="input" id="eg-min" type="number" value="${g.min_players ?? ''}" /></div>
      <div class="field"><label>최대 인원</label><input class="input" id="eg-max" type="number" value="${g.max_players ?? ''}" /></div>
    </div>
    <div class="row2">
      <div class="field"><label>플레이타임(분)</label><input class="input" id="eg-time" type="number" value="${g.playtime_min ?? ''}" /></div>
      <div class="field"><label>난이도(weight)</label><input class="input" id="eg-weight" type="number" step="0.01" value="${g.weight ?? ''}" /></div>
    </div>
    <div class="field"><label>이미지 URL</label><input class="input" id="eg-image" value="${esc(g.image_url)}" /></div>
    <div class="field"><label>게임 요약</label><textarea class="input" id="eg-summary">${esc(g.summary_kr)}</textarea></div>
    <div class="field">
      <label>게임 사진 (찍거나 앨범에서 선택 — 올리면 URL 대신 사용)</label>
      <input class="input" id="eg-photo" type="file" accept="image/*" onchange="onPhotoPick(this,'eg')" />
  			<div id="eg-photo-preview"></div>
    </div>
    <div class="sheet-save" style="display:flex;gap:8px;">
      <button class="btn danger" style="flex:1;" onclick="deleteGameAdmin('${g.game_id}')">🗑 삭제</button>
      <button class="btn" style="flex:1;" onclick="submitEditGame('${g.game_id}')">수정 저장</button>
    </div>`;
  photoState.eg = '';
  showDetailSheet();
}
document.getElementById('detail-overlay').addEventListener('click', e => {
  if (e.target.id === 'detail-overlay') closeOverlay();
});
// 막대 클릭 세션 팝업: 바깥(백드롭) 아무 곳이나 누르면 닫힘
document.getElementById('gd-session-overlay').addEventListener('click', e => {
  if (e.target.id === 'gd-session-overlay') closeOverlay();
});

async function deleteGameAdmin(gameId) {
  const g = gameById(gameId);
  const nm = g ? (g.name_kr || g.name_en) : gameId;
  if (!confirm(`"${nm}" 게임을 삭제할까요?\n이 게임의 평점·후기도 함께 삭제됩니다.\n(플레이 기록은 남아 있어요)`)) return;
  const pin = await promptPin();
  if (pin == null) return;
  showLoader('삭제 중…');
  try {
    await api('adminDeleteGame', { playerId: state.user.player_id, pin, gameId });
    state.games = await api('getGames');
    state._myRatings = null; state._myRatingsPromise = null;
    toast('삭제되었습니다.');
    closeOverlay();
    renderGames();
    if (document.getElementById('admin-page').classList.contains('show')) adminGameSearch();
  } catch (e) { toast(e.message, true); } finally { hideLoader(); }
}

async function submitEditGame(gameId) {
  const pin = await promptPin();
  if (pin == null) return;
  const payload = {
    game_id: gameId,
    name_kr: document.getElementById('eg-namekr').value,
    name_en: document.getElementById('eg-nameen').value,
    category: document.getElementById('eg-category').value,
    min_players: document.getElementById('eg-min').value,
    max_players: document.getElementById('eg-max').value,
    playtime_min: document.getElementById('eg-time').value,
    weight: document.getElementById('eg-weight').value,
    image_url: photoState.eg || document.getElementById('eg-image').value,
    summary_kr: document.getElementById('eg-summary').value
  };
  showLoader('저장 중…');
  try {
    await api('updateGame', {
      playerId: state.user.player_id, pin,
      payload: JSON.stringify(payload)
    });
    state.games = await api('getGames');
    toast('수정되었습니다!');
    closeOverlay();
    renderGames();
    // 관리자 페이지가 열려 있으면 게임 목록도 갱신
    if (document.getElementById('admin-page').classList.contains('show')) adminGameSearch();
  } catch (e) {
    toast(e.message, true);
  } finally {
    hideLoader();
  }
}

// ============================================================
//  관리자 페이지
// ============================================================
// 쉼표(,) 다중 조건 AND 매칭 (플레이기록 검색과 동일 규칙)
function matchAllTerms(hay, raw) {
  const terms = String(raw || '').split(',').map(t => t.trim().toLowerCase()).filter(Boolean);
  if (!terms.length) return true;
  const h = hay.toLowerCase();
  return terms.every(t => h.includes(t));
}

function openAdminPage() {
  if (!state.user || state.user.role !== 'admin') { toast('관리자만 사용할 수 있습니다.', true); return; }
  const page = document.getElementById('admin-page');
  page.classList.add('show');
  page.scrollTop = 0;
  openOverlay(() => page.classList.remove('show'));
  switchAdminTab('games');
}
function closeAdminPage() { closeOverlay(); }

function switchAdminTab(tab) {
  ['games', 'plays', 'players'].forEach(t => {
    document.getElementById('admtab-' + t).classList.toggle('on', t === tab);
    document.getElementById('adm-' + t).style.display = t === tab ? 'block' : 'none';
  });
  if (tab === 'games') renderAdminGames();
  else if (tab === 'plays') renderAdminPlays();
  else renderAdminPlayers();
}

// ----- 게임 탭 -----
function renderAdminGames() {
  const el = document.getElementById('adm-games');
  if (!el.dataset.ready) {
    el.innerHTML = `
      <div class="searchbox"><span>🔍</span><input id="adm-game-search" placeholder="이름·분류·요약 검색" oninput="adminGameSearch()" /></div>
      <div id="adm-game-list"></div>`;
    el.dataset.ready = '1';
  }
  adminGameSearch();
}

function adminGameSearch() {
  const listEl = document.getElementById('adm-game-list');
  if (!listEl) return;
  const raw = (document.getElementById('adm-game-search') || {}).value || '';
  const list = state.games.filter(g =>
    matchAllTerms([g.name_kr, g.name_en, g.category, g.summary_kr].map(v => v || '').join(' '), raw))
    .slice().sort((a, b) => String(a.name_kr || a.name_en || '').localeCompare(String(b.name_kr || b.name_en || '')));
  if (!list.length) { listEl.innerHTML = `<div class="empty">검색 결과가 없어요.</div>`; return; }
  listEl.innerHTML = list.map(g => {
    const meta = [];
    if (g.min_players || g.max_players) {
      const mn = g.min_players || '?', mx = g.max_players || '?';
      meta.push(`👥 ${mn}${mx !== mn ? '~' + mx : ''}명`);
    }
    if (g.playtime_min) meta.push(`⏱ ${g.playtime_min}분`);
    if (g.weight) meta.push(`🧠 ${Number(g.weight).toFixed(2)}`);
    return `<div class="adm-gcard" onclick="openEditGame('${g.game_id}')">
      <div class="gcard-top">
        ${thumb(g.image_url, 'gcard-img')}
        <div class="gcard-body">
          <div class="gcard-name">${esc(g.name_kr || g.name_en)}
            ${g.category ? `<span class="badge" style="margin-left:6px;">${esc(g.category)}</span>` : ''}</div>
          ${g.name_en && g.name_kr ? `<div class="gcard-en">${esc(g.name_en)}</div>` : ''}
          <div class="gcard-meta">${meta.map(m => `<span>${m}</span>`).join('')}</div>
          <div class="adm-summary">${g.summary_kr ? esc(g.summary_kr) : '<span class="muted">등록된 요약이 없습니다.</span>'}</div>
        </div>
      </div>
    </div>`;
  }).join('');
}

// 분류 관리는 통합 관리자(운영자)가 전역으로 수행 — 허브 관리자 UI 제거

// ----- 플레이 탭 (검색 후에만 표시) -----
function renderAdminPlays() {
  const el = document.getElementById('adm-plays');
  if (!el.dataset.ready) {
    el.innerHTML = `
      <div class="adm-searchrow">
        <div class="searchbox"><span>🔍</span><input id="adm-play-search" placeholder="일자·게임·참가자·작성자" onkeydown="if(event.key==='Enter')adminPlaySearch()" /></div>
        <button class="adm-pill" onclick="adminPlaySearch()">검색</button>
      </div>
      <div class="adm-daterow">
        <div class="adm-datefield"><label>시작일</label><input class="input" id="adm-play-from" type="date" /></div>
        <div class="adm-datefield"><label>종료일</label><input class="input" id="adm-play-to" type="date" /></div>
      </div>
      <div id="adm-play-list"><div class="empty"><div class="big">🔍</div>조건을 입력하고 검색을 누르면<br/>플레이 기록이 표시됩니다.</div></div>`;
    el.dataset.ready = '1';
  }
}

function adminPlaySearch() {
  const listEl = document.getElementById('adm-play-list');
  if (!listEl) return;
  state._editSid = null;
  const raw = (document.getElementById('adm-play-search') || {}).value || '';
  const from = (document.getElementById('adm-play-from') || {}).value || '';
  const to = (document.getElementById('adm-play-to') || {}).value || '';
  const list = state.plays.filter(s => {
    const d = String(s.play_date).substring(0, 10);
    if (from && d < from) return false;
    if (to && d > to) return false;
    const hay = [s.play_date, s.game_name, playerNameById(s.created_by),
      ...s.participants.map(p => p.name || '')].join(' ');
    return matchAllTerms(hay, raw);
  });
  if (!list.length) { listEl.innerHTML = `<div class="empty">조건에 맞는 기록이 없어요.</div>`; return; }
  renderSessionList('adm-play-list', list, { admin: true });
}

// ----- 가입자 탭 -----

// ===== 허브 설정 (허브 개설 계정 전용 — 이름·초대코드) =====
function renderAdminHubSection() {
  const el = document.getElementById('adm-hub-section');
  if (!el) return;
  el.innerHTML = `
    <div class="card" style="margin-bottom:14px;">
      <div class="section-title" style="margin-top:0;">🏠 허브 설정 <small class="muted" style="font-weight:500;">(허브 개설 계정 전용)</small></div>
      <div style="display:flex;gap:8px;">
        <input class="input" id="adm-hub-name" value="${esc(state.hub ? state.hub.name : '')}" maxlength="30" style="flex:1;min-width:0;" />
        <button class="btn sm" style="flex:0 0 auto;" onclick="adminHubRename()">이름 저장</button>
      </div>
      <div style="display:flex;gap:8px;margin-top:10px;align-items:center;">
        <div id="adm-invite-view" style="flex:1;min-width:0;font-weight:800;color:var(--main);letter-spacing:2px;">초대코드 ●●●●●●</div>
        <button class="btn ghost sm" style="flex:0 0 auto;" onclick="adminShowInvite()">보기</button>
        <button class="btn ghost sm" style="flex:0 0 auto;" onclick="adminCopyInvite()">복사</button>
        <button class="btn ghost sm" style="flex:0 0 auto;" onclick="adminRotateInvite()">재발급</button>
      </div>
    </div>`;
}

// 허브 설정 호출 공통: 관리자 Auth 필요 에러면 이메일 로그인 유도
async function hubAuthCall(fn) {
  try { return await fn(); }
  catch (e) {
    if (/로그인이 필요|관리자가 아닙니다/.test(e.message)) {
      toast('허브 개설 계정으로 로그인해주세요.', true);
      openEmailAuth('admin');
      return null;
    }
    toast(e.message, true);
    return null;
  }
}

async function adminHubRename() {
  const name = document.getElementById('adm-hub-name').value.trim();
  if (!name) { toast('허브 이름을 입력하세요.', true); return; }
  const r = await hubAuthCall(() => api('hubRename', { name }));
  if (r) { saveHub(Object.assign({}, state.hub, { name: r.name })); toast('허브 이름을 바꿨어요.'); }
}

async function adminShowInvite() {
  const r = await hubAuthCall(() => api('hubGetInvite'));
  if (r) document.getElementById('adm-invite-view').textContent = '초대코드 ' + r.invite_code;
}

// 초대 문구 복사(허브 개설 완료 화면과 같은 멘트)
async function adminCopyInvite() {
  const r = await hubAuthCall(() => api('hubGetInvite'));
  if (r) {
    document.getElementById('adm-invite-view').textContent = '초대코드 ' + r.invite_code;
    copyInvite(state.hub ? state.hub.name : '', r.invite_code);
  }
}

async function adminRotateInvite() {
  if (!confirm('초대코드를 재발급하면 기존 코드는 못 쓰게 됩니다. 계속할까요?')) return;
  const r = await hubAuthCall(() => api('hubRotateInvite'));
  if (r) {
    document.getElementById('adm-invite-view').textContent = '초대코드 ' + r.invite_code;
    saveHub(Object.assign({}, state.hub, { invite: r.invite_code }));
    toast('새 초대코드가 발급됐어요.');
  }
}

async function renderAdminPlayers() {
  const el = document.getElementById('adm-players');
  el.innerHTML = `<div class="empty"><div class="spinner" style="margin:0 auto;"></div></div>`;
  const pin = await promptPin();
  if (pin == null) { el.innerHTML = `<div class="empty">PIN 확인이 필요합니다.</div>`; return; }
  try {
    state._admPlayers = await api('adminGetPlayers', { playerId: state.user.player_id, pin });
    el.innerHTML = `
      <div id="adm-hub-section"></div>
      <div class="searchbox" style="margin-bottom:12px;"><span>🔍</span><input id="adm-player-search" placeholder="닉네임 검색 (쉼표로 여러 조건)" oninput="adminPlayerSearch()" /></div>
      <div id="adm-player-list"></div>`;
    renderAdminHubSection();
    adminPlayerSearch();
  } catch (e) {
    el.innerHTML = `<div class="empty">불러오지 못했습니다.<br/>${esc(e.message)}</div>`;
  }
}

function adminPlayerSearch() {
  const listEl = document.getElementById('adm-player-list');
  if (!listEl) return;
  const raw = (document.getElementById('adm-player-search') || {}).value || '';
  const list = (state._admPlayers || []).filter(p =>
    matchAllTerms([p.name, p.player_id, p.joined_at].join(' '), raw));
  if (!list.length) { listEl.innerHTML = `<div class="empty">검색 결과가 없어요.</div>`; return; }
  // 이메일 계정에 연결된 멤버는 PIN 대신 배지 표시(눌러야 백업PIN 공개)
  const linkedSet = new Set((state.players || []).filter(x => x.linked).map(x => x.player_id));
  state._admShowPin = state._admShowPin || {};
  listEl.innerHTML = list.map(p => `
    <div class="adm-prow" data-pid="${esc(p.player_id)}">
      <div class="nm">${esc(p.name)}${p.role === 'admin' ? ' 👑' : ''}
        <div class="jd">가입 ${esc(p.joined_at || '-')}</div>
      </div>
      ${linkedSet.has(p.player_id) && !state._admShowPin[p.player_id]
        ? `<button class="btn ghost sm" style="flex:0 0 auto;padding:8px 12px;color:var(--main);" onclick="admRevealPin('${esc(p.player_id)}')" title="누르면 백업PIN 표시">📧 이메일가입</button>`
        : `<input class="pin" inputmode="numeric" maxlength="4" value="${esc(p.pin)}" />
      <button class="btn sm" style="padding:8px 12px;flex:0 0 auto;" onclick="adminSavePin(this)">저장</button>`}
    </div>`).join('');
}

function admRevealPin(pid) {
  state._admShowPin = state._admShowPin || {};
  state._admShowPin[pid] = true;
  adminPlayerSearch();
}

async function adminSavePin(btn) {
  const row = btn.closest('.adm-prow');
  const targetId = row.getAttribute('data-pid');
  const newPin = row.querySelector('.pin').value.trim();
  if (!/^\d{4}$/.test(newPin)) { toast('비밀번호는 숫자 4자리로 입력하세요.', true); return; }
  const pin = await promptPin(); if (pin == null) return;
  showLoader('저장 중…');
  try {
    await api('adminUpdatePin', { playerId: state.user.player_id, pin, targetId, newPin });
    const t = (state._admPlayers || []).find(x => x.player_id === targetId);
    if (t) t.pin = newPin;
    // 내 PIN을 바꿨다면 캐시도 갱신
    if (targetId === state.user.player_id) localStorage.setItem('bg_pin', newPin);
    toast('비밀번호가<br/>변경되었습니다!');
  } catch (e) { toast(e.message, true); } finally { hideLoader(); }
}

// ============================================================
//  초기화
// ============================================================
const APP_VERSION = 'v2127 캐시버스팅·MY 로그인폼 정리·입장 후 게임탭';

// ============================================================
//  멀티허브: 허브 컨텍스트 / 시작 화면 / 이메일 계정 플로우
// ============================================================
function saveHub(h) {
  state.hub = h;
  localStorage.setItem('bg_hub', JSON.stringify(h));
  updateHubTitle();
}

function updateHubTitle() {
  const el = document.getElementById('hub-title');
  if (el) el.textContent = state.hub ? state.hub.name + ' Hub' : '보드게임 Hub';
}

// 허브 이름 최신화(관리자가 이름을 바꿨을 수 있음) — 실패해도 무시
async function refreshHubName() {
  try {
    const h = await api('getHub');
    if (h && h.name && state.hub && h.hub_id === state.hub.hub_id
        && (h.name !== state.hub.name || (h.kind || 'hub') !== (state.hub.kind || 'hub'))) {
      saveHub(Object.assign({}, state.hub, { name: h.name, kind: h.kind || 'hub' }));
    }
  } catch (e) {}
}

// 시작/허브전환 화면. closable=true면 우측 상단 ✕ 표시(허브 있는 상태에서 전환용)
function openStartPage(closable) {
  const el = document.getElementById('start-page');
  document.getElementById('start-close').style.display = closable ? '' : 'none';
  const inv = document.getElementById('start-invite');
  if (inv) inv.value = '';
  const jn = document.getElementById('ji-name'); if (jn) jn.value = '';
  const jp = document.getElementById('ji-pin'); if (jp) jp.value = '';
  if (document.getElementById('ji-tab-signup')) jiSetMode('signup');
  el.classList.add('show');
  startShow('home');
  // 이메일 세션이 이미 있으면 바로 내 허브 목록으로
  sb.auth.getSession().then(({ data }) => {
    if (data && data.session
        && el.classList.contains('show')
        && document.getElementById('sv-home').style.display !== 'none') loadStartHubs();
  }).catch(() => {});
}

// 시작 페이지 내부 화면 전환
function startShow(view) {
  document.querySelectorAll('#start-page .start-view').forEach(v => v.style.display = 'none');
  const el = document.getElementById('sv-' + view);
  if (el) el.style.display = 'block';
}

// 개인 기록장 여부: kind 우선, 없으면 이름 패턴 폴백(마이그레이션 이전 데이터 호환)
function isPersonalHub(h) {
  if (!h) return false;
  return h.kind === 'personal' || /의 기록장$/.test(h.name || h.hub_name || '');
}

// 초대 문구 붙여넣기 → 코드만 추출 ("... 초대코드: AB12CD" / 6자리 토큰)
function extractInvite(text) {
  const t = String(text || '');
  const m = t.match(/초대코드[^A-Za-z0-9]*([A-Za-z0-9]{6})/);
  if (m) return m[1].toUpperCase();
  const all = t.match(/(?:^|[^A-Za-z0-9])([A-Za-z0-9]{6})(?![A-Za-z0-9])/g);
  if (all && all.length) {
    const last = all[all.length - 1].match(/[A-Za-z0-9]{6}/);
    return last[0].toUpperCase();
  }
  return t.trim().toUpperCase();
}
function inviteAutoExtract(inp) {
  const v = inp.value;
  if (v.length > 8 || /초대코드/.test(v)) inp.value = extractInvite(v);
}

// ----- 이메일로 시작 -----
function startEmailEntry() {
  sb.auth.getSession().then(({ data }) => {
    if (data && data.session) loadStartHubs();
    else { seSetMode('login'); startShow('email'); }
  }).catch(() => { seSetMode('login'); startShow('email'); });
}

function seSetMode(mode) {
  state._seMode = mode;
  document.getElementById('se-tab-login').classList.toggle('on', mode === 'login');
  document.getElementById('se-tab-signup').classList.toggle('on', mode === 'signup');
  document.getElementById('se-nick-row').style.display = mode === 'signup' ? 'block' : 'none';
  document.getElementById('se-pin-row').style.display = mode === 'signup' ? 'block' : 'none';
  document.getElementById('se-go').textContent = mode === 'signup' ? '가입하고 시작하기' : '로그인';
}

async function doStartEmail() {
  const email = document.getElementById('se-email').value.trim();
  const pw = document.getElementById('se-pw').value;
  const isSignup = state._seMode === 'signup';
  const nick = document.getElementById('se-nick').value.trim();
  const bpin = document.getElementById('se-pin').value.trim();
  if (!email || !pw) { toast('이메일과 비밀번호를 입력하세요.', true); return; }
  if (isSignup && !nick) { toast('닉네임을 입력하세요.', true); return; }
  if (isSignup && !/^\d{4}$/.test(bpin)) { toast('백업PIN은 숫자 4자리로 입력하세요.', true); return; }
  showLoader(isSignup ? '가입 중…' : '로그인 중…');
  try {
    const { data, error } = isSignup
      ? await sb.auth.signUp({ email, password: pw,
          options: { emailRedirectTo: location.origin + location.pathname } })
      : await sb.auth.signInWithPassword({ email, password: pw });
    if (error) {
      if (/already registered|already exists/i.test(error.message)) {
        seSetMode('login');
        throw new Error('이미 가입된 이메일이에요. 비밀번호로 로그인해주세요.');
      }
      if (/rate limit|security purposes.*after \d+ seconds/i.test(error.message)) {
        throw new Error('메일 발송이 잠시 제한됐어요(한도/재요청 대기). 잠시 후 다시 시도해주세요.');
      }
      throw new Error(error.message === 'Invalid login credentials'
        ? '이메일 또는 비밀번호가 올바르지 않아요.' : error.message);
    }
    // 이미 가입·인증된 이메일로 다시 가입하면 supabase가 에러 대신
    // identities가 빈 가짜 응답을 줌(이메일 존재 여부 감춤) → 여기서 구분
    if (isSignup && data.user && Array.isArray(data.user.identities)
        && data.user.identities.length === 0) {
      seSetMode('login');
      throw new Error('이미 가입된 이메일이에요. 비밀번호로 로그인해주세요.');
    }
    if (!data.session) { toast('확인 메일을 보냈어요. 메일 인증 후 로그인해주세요.'); return; }
    if (isSignup) await ensurePersonalNamed(nick, bpin);   // 가입 = 개인 기록장 자동 생성(닉네임+백업PIN)
    await loadStartHubs();
  } catch (e) {
    toast(e.message, true);
  } finally { hideLoader(); }
}

// 개인 기록장 자동 생성(닉네임 지정, PIN은 자동 발급 — 이메일 로그인이 열쇠).
// 기록장은 있는데 멤버 연결이 없는 예전 계정도 여기서 복구됨.
// 실패 원인은 state._personalErr에 남겨 목록 화면에 표시(조용히 삼키지 않음)
async function ensurePersonalNamed(nick, backupPin) {
  state._personalErr = null;
  try {
    const hub = await sbrpc('create_hub', { p_name: nick + '의 기록장', p_kind: 'personal' });
    const linked = (state._myLinks || []).some(l => l.hub_id === hub.hub_id);
    if (!linked) {
      const name = hub.existing
        ? ((hub.name || '').replace(/의 기록장$/, '') || nick) : nick;
      const pin = /^\d{4}$/.test(backupPin || '') ? backupPin
        : String(Math.floor(1000 + Math.random() * 9000));
      const u = await sbrpc('signup', { p_name: name, p_pin: pin, p_hub_id: hub.hub_id, p_invite: hub.invite_code });
      await sbrpc('link_player', { p_hub_id: hub.hub_id, p_player_id: u.player_id, p_pin: pin });
    }
    state._myLinks = null;
  } catch (e) {
    state._personalErr = /function|schema cache|could not find/i.test(e.message || '')
      ? '서버 DB에 최신 마이그레이션이 아직 적용되지 않았어요 — supabase_fix_all.sql을 실행해주세요'
      : e.message;
  }
}

async function forgotPw() {
  const email = document.getElementById('se-email').value.trim();
  if (!email) { toast('먼저 이메일을 입력해주세요.', true); return; }
  showLoader('메일 보내는 중…');
  try {
    const { error } = await sb.auth.resetPasswordForEmail(email,
      { redirectTo: location.origin + location.pathname });
    if (error) throw new Error(/rate limit|security purposes.*after \d+ seconds/i.test(error.message)
      ? '메일 발송이 잠시 제한됐어요(한도/재요청 대기). 잠시 후 다시 시도해주세요.'
      : error.message);
    toast('비밀번호 재설정 메일을 보냈어요. 메일함을 확인해주세요! (스팸함도 확인)');
  } catch (e) { toast(e.message, true); } finally { hideLoader(); }
}

async function doRecovery() {
  const pw = document.getElementById('sr-pw').value;
  if (!pw || pw.length < 6) { toast('6자 이상으로 입력해주세요.', true); return; }
  showLoader('변경 중…');
  try {
    const { error } = await sb.auth.updateUser({ password: pw });
    if (error) throw new Error(error.message);
    toast('비밀번호를 변경했어요!');
    await loadStartHubs();
  } catch (e) { toast(e.message, true); } finally { hideLoader(); }
}

// 로그인 후: 내 허브/기록장 목록 + 허브 개설
async function loadStartHubs() {
  startShow('hubs');
  const el = document.getElementById('sv-hubs');
  el.innerHTML = `<div class="empty"><div class="spinner" style="margin:0 auto;"></div></div>`;
  state._myLinks = null;
  try { await loadMyLinks(); } catch (e) {}
  let owned = [];
  try { owned = await api('myHubs') || []; } catch (e) {}
  // 기록장이 하나도 없으면 자동 생성(기록장 도입 이전에 가입한 계정 보수)
  if (![...(state._myLinks || []), ...owned.map(h => ({ ...h, hub_name: h.name }))].some(isPersonalHub)) {
    let nick = ((state._myLinks || [])[0] || {}).name || '';
    if (!nick) {
      try {
        const { data } = await sb.auth.getSession();
        nick = ((data.session.user || {}).email || '').split('@')[0];
      } catch (e) {}
    }
    if (nick) {
      await ensurePersonalNamed(nick);
      try { await loadMyLinks(); } catch (e) {}
      try { owned = await api('myHubs') || []; } catch (e) {}
    }
  }
  const links = state._myLinks || [];
  // 개설했지만 멤버 연결이 없는 허브도 목록에 포함(입장 시 자동 연결)
  const seen = new Set(links.map(l => l.hub_id));
  const items = [...links, ...owned.filter(h => !seen.has(h.hub_id))
    .map(h => ({ hub_id: h.hub_id, hub_name: h.name, kind: h.kind }))];
  el.innerHTML = `
    <h3 style="margin:0 0 12px;">어디로 들어갈까요?</h3>
    ${items.map(l => `
      <button class="hubmenu-item" onclick="startPickHub('${l.hub_id}')">
        <span>${isPersonalHub(l) ? '📔' : '🏠'} ${esc(l.hub_name)}</span><span class="hint">›</span>
      </button>`).join('') || '<div class="hint" style="margin-bottom:10px;">아직 연결된 허브가 없어요</div>'}
    ${!items.some(isPersonalHub) && state._personalErr
      ? `<div class="hint" style="margin:6px 0 4px;color:var(--danger);">📔 기록장 준비 실패: ${esc(state._personalErr)}</div>` : ''}
    <button class="btn ghost" style="margin-top:10px;" onclick="startShow('create')">🏠 새 허브 개설</button>
    <button class="btn ghost" style="margin-top:8px;" onclick="startShow('invite')">🔑 초대코드로 허브 입장</button>
    <div class="row2" style="margin-top:16px;justify-content:center;gap:12px;">
      <button class="logout-link" style="color:var(--text-sub);" onclick="startShow('home')">‹ 처음으로</button>
      <button class="logout-link" style="color:var(--text-sub);" onclick="startShowLinks()">🔗 계정연결확인</button>
      <button class="logout-link" style="color:var(--text-sub);" onclick="startSignOut()">🚪 계정 로그아웃</button>
    </div>`;
}

// 계정 연결 확인: 연결된 허브·닉네임 목록 + [연결해제]
// · 비밀번호(PIN)는 표시하지 않음 — 잘못 연결된 남의 PIN 노출 방지
// · 개인 기록장은 연결이 유일한 열쇠(PIN 자동발급·미공개)라 해제 불가
async function startShowLinks() {
  startShow('links');
  const el = document.getElementById('sv-links');
  el.innerHTML = `<div class="empty"><div class="spinner" style="margin:0 auto;"></div></div>`;
  state._myLinks = null;
  try { await loadMyLinks(); } catch (e) {}
  const links = state._myLinks || [];
  el.innerHTML = `
    <h3 style="margin:0 0 6px;">🔗 계정 연결 확인</h3>
    <div class="hint" style="margin-bottom:12px;">이 계정에 연결된 허브와 닉네임이에요.<br>잘못 연결된 멤버는 [연결해제]로 정리할 수 있어요.</div>
    ${links.map(l => `
      <div class="card" style="display:flex;align-items:center;gap:10px;margin-bottom:8px;text-align:left;">
        <div style="flex:1;min-width:0;">
          <div style="font-weight:700;">${isPersonalHub(l) ? '📔' : '🏠'} ${esc(l.hub_name)}</div>
          <div class="hint">닉네임: ${esc(l.name)}</div>
        </div>
        ${isPersonalHub(l)
          ? `<span class="hint" style="flex:0 0 auto;">내 기록장 · 해제 불가</span>`
          : `<button class="btn danger sm" style="flex:0 0 auto;padding:7px 12px;" onclick="unlinkFromStart('${esc(l.player_id)}','${esc(l.hub_name)}')">연결해제</button>`}
      </div>`).join('') || '<div class="hint" style="margin-bottom:10px;">연결된 허브가 없어요</div>'}
    <button class="logout-link" style="margin-top:14px;color:var(--text-sub);" onclick="loadStartHubs()">‹ 뒤로</button>`;
}

async function unlinkFromStart(pid, hubName) {
  if (!confirm(hubName + ' 연결을 해제할까요?\n\n해제하면 통합 기록에서 이 허브가 빠져요.\n(그 허브에서 닉네임+비밀번호로 로그인하면 다시 연결돼요)')) return;
  showLoader('해제 중…');
  try {
    await api('unlinkPlayer', { playerId: pid });
    state._myLinks = null;
    state._myAllPlays = null; state._myAllGames = null;
    state._myStatsBy = null;
    toast('연결을 해제했어요.');
    await startShowLinks();
  } catch (e) { toast(e.message, true); } finally { hideLoader(); }
}

// 계정(이메일) 로그아웃 — 허브 멤버(닉네임) 세션은 그대로 둔다
async function startSignOut() {
  showLoader('로그아웃 중…');
  try { await sb.auth.signOut(); } catch (e) {}
  hideLoader();
  state._myLinks = null;
  if (state._myStatsBy) state._myStatsBy = {};
  toast('계정에서 로그아웃했어요.');
  startShow('home');
}

async function startPickHub(hid) {
  // 개설자인데 멤버 연결이 없는 허브/기록장 → 자동 가입·연결 후 입장
  if (!(state._myLinks || []).some(l => l.hub_id === hid)) {
    showLoader('연결 중…');
    try {
      const hub = await sbrpc('get_hub', { p_hub_id: hid });
      const inv = await sbrpc('hub_get_invite', { p_hub_id: hid });
      const links = state._myLinks || [];
      const personal = links.find(l => isPersonalHub(l));
      let nick = isPersonalHub(hub) ? (hub.name || '').replace(/의 기록장$/, '') : '';
      nick = nick || (personal && personal.name) || ((links[0] || {}).name) || '허브장';
      const pin = String(Math.floor(1000 + Math.random() * 9000));
      const u = await sbrpc('signup', { p_name: nick, p_pin: pin, p_hub_id: hid, p_invite: inv.invite_code });
      await sbrpc('link_player', { p_hub_id: hid, p_player_id: u.player_id, p_pin: pin });
      state._myLinks = null;
      await loadMyLinks();
    } catch (e) { hideLoader(); toast(e.message, true); return; }
    hideLoader();
  }
  await switchToHub(hid);
}

// 허브 개설(개설자는 기록장 닉네임으로 자동 가입·연결)
async function startCreateHub() {
  const name = document.getElementById('sc-name').value.trim();
  if (!name) { toast('허브 이름을 입력하세요.', true); return; }
  const scPinChk = document.getElementById('sc-pin').value.trim();
  if (!/^\d{4}$/.test(scPinChk)) { toast('백업PIN은 숫자 4자리로 입력하세요.', true); return; }
  showLoader('허브 만드는 중…');
  try {
    const hub = await api('createHub', { name, kind: 'hub' });
    saveHub({ hub_id: hub.hub_id, name: hub.name, invite: hub.invite_code, kind: 'hub' });
    const links = state._myLinks || [];
    const personal = links.find(l => isPersonalHub(l));
    const nick = document.getElementById('sc-nick').value.trim()
      || (personal && personal.name)
      || (document.getElementById('se-nick').value.trim() || '허브장');
    const scPin = document.getElementById('sc-pin').value.trim();
    const pin = /^\d{4}$/.test(scPin) ? scPin : String(Math.floor(1000 + Math.random() * 9000));
    const u = await sbrpc('signup', { p_name: nick, p_pin: pin, p_hub_id: hub.hub_id, p_invite: hub.invite_code });
    await sbrpc('link_player', { p_hub_id: hub.hub_id, p_player_id: u.player_id, p_pin: pin });
    applyAuth({ player_id: u.player_id, name: u.name, role: u.role, hub_id: hub.hub_id }, pin, hub.name + ' 개설 완료!');
    state._myLinks = null;
    startShow('created');
    document.getElementById('sv-created').innerHTML = `
      <h3 style="margin:0 0 8px;">🎉 ${esc(hub.name)} Hub 개설 완료!</h3>
      <div class="hint" style="margin-bottom:10px;">멤버들에게 초대코드를 공유하세요.</div>
      <div class="invite-code">${esc(hub.invite_code)}</div>
      <button class="btn ghost" style="margin-top:12px;" onclick="copyInvite('${esc(hub.name)}','${esc(hub.invite_code)}')">📋 초대 문구 복사</button>
      <button class="btn" style="margin-top:8px;" onclick="startEnterHub()">시작하기</button>`;
    await loadCore();
  } catch (e) { toast(e.message, true); } finally { hideLoader(); }
}

function startEnterHub() { closeStartPage(); switchView('play'); }

function copyInvite(name, code) {
  const text = '같이 ' + name + ' Hub에서 보드게임 기록해요! 초대코드: ' + code;
  const done = () => toast('초대 문구를 복사했어요!');
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(done).catch(() => prompt('아래 문구를 복사하세요', text));
  } else { prompt('아래 문구를 복사하세요', text); }
}
function closeStartPage() { document.getElementById('start-page').classList.remove('show'); }

// 초대코드로 허브 입장/전환
// 초대코드 입장: 처음이에요(가입) / 로그인 탭
function jiSetMode(mode) {
  state._jiMode = mode;
  document.getElementById('ji-tab-signup').classList.toggle('on', mode !== 'login');
  document.getElementById('ji-tab-login').classList.toggle('on', mode === 'login');
  document.getElementById('ji-go').textContent = mode === 'login' ? '로그인하고 입장' : '가입하고 입장';
}

// 초대코드 + 닉네임/비밀번호 한 번에 → 로그인(또는 가입)까지 끝내고 입장
async function joinByInvite() {
  const code = extractInvite(document.getElementById('start-invite').value.trim());
  const name = document.getElementById('ji-name').value.trim();
  const pin = document.getElementById('ji-pin').value.trim();
  const isSignup = state._jiMode !== 'login';
  if (!code) { toast('초대코드를 입력하세요.', true); return; }
  if (!name) { toast('닉네임을 입력하세요.', true); return; }
  if (isSignup && !/^\d{4}$/.test(pin)) { toast('비밀번호는 숫자 4자리로 입력하세요.', true); return; }
  if (!pin) { toast('비밀번호를 입력하세요.', true); return; }
  showLoader(isSignup ? '가입하고 입장 중…' : '입장 중…');
  try {
    const h = await api('hubByInvite', { code });
    // 인증까지 성공한 뒤에만 허브를 전환(중간 실패 시 기존 상태 유지)
    let user;
    if (isSignup) {
      user = await sbrpc('signup', { p_name: name, p_pin: pin, p_hub_id: h.hub_id, p_invite: code.toUpperCase() });
    } else {
      const d = await sbrpc('login', { p_name: name, p_pin: pin, p_hub_id: h.hub_id });
      if (d && d.ok === false) throw new Error(d.error || '로그인에 실패했습니다.');
      user = d;
    }
    const switching = !state.hub || state.hub.hub_id !== h.hub_id;
    if (switching) { state._myStats = null; state._myRatings = null; state._myRatingsPromise = null; }
    saveHub({ hub_id: h.hub_id, name: h.name, invite: code.toUpperCase(), kind: h.kind || 'hub' });
    state.myScope = null;
    closeStartPage();
    applyAuth({ player_id: user.player_id, name: user.name, role: user.role, hub_id: h.hub_id },
              pin, (isSignup ? '가입 완료! ' : '') + h.name + ' 허브에 들어왔어요!');
    await loadCore();
    switchView('games');   // 입장하면 그 허브의 통합 게임 탭이 메인
  } catch (e) {
    toast(e.message, true);
  } finally { hideLoader(); }
}

// ----- 이메일 계정 플로우 (허브 만들기 / 개인 기록장) -----
const emailFlow = { purpose: null };   // 'create' | 'personal'

function openEmailAuth(purpose) {
  emailFlow.purpose = purpose;
  document.getElementById('email-overlay').classList.add('show');
  renderEmailStep('auth');
}
function closeEmailAuth() { document.getElementById('email-overlay').classList.remove('show'); }

function renderEmailStep(step, extra) {
  const el = document.getElementById('email-body');
  const isCreate = emailFlow.purpose === 'create';
  if (step === 'auth') {
    const titles = { create: '🏠 새 허브 만들기', personal: '📔 개인 기록장 시작',
                     link: '📧 이메일 계정에 연결', admin: '🔐 허브 관리자 로그인',
                     signin: '📧 이메일로 로그인' };
    const hints = { create: '허브 개설에는 이메일 계정이 필요해요 (관리자 계정).',
                    personal: '개인 기록장은 이메일 계정으로 관리돼요.',
                    link: '연결하면 여러 허브의 내 기록을 모아볼 수 있어요.',
                    admin: '허브 이름·초대코드 관리는 허브 개설 계정으로 로그인해야 해요.',
                    signin: '계정에 연결된 멤버로 PIN 없이 로그인해요.' };
    el.innerHTML = `
      <h2>${titles[emailFlow.purpose] || titles.create}</h2>
      <div class="hint" style="margin-bottom:14px;">${hints[emailFlow.purpose] || ''}</div>
      <div class="field"><label>이메일</label>
        <input class="input" id="em-email" type="email" placeholder="you@example.com" autocomplete="email" /></div>
      <div class="field"><label>비밀번호 (6자 이상)</label>
        <input class="input" id="em-pw" type="password" placeholder="••••••" autocomplete="current-password" /></div>
      <button class="btn" onclick="emailAuthGo(false)">로그인</button>
      <button class="btn ghost" style="margin-top:8px;" onclick="emailAuthGo(true)">처음이에요 — 이메일로 가입</button>`;
  } else if (step === 'setup') {
    el.innerHTML = `
      <h2>${isCreate ? '허브 정보 입력' : '기록장 정보 입력'}</h2>
      ${isCreate ? `<div class="field"><label>허브 이름</label>
        <input class="input" id="em-hubname" placeholder="예: 슈필" maxlength="30" /></div>` : ''}
      <div class="field"><label>내 닉네임</label>
        <input class="input" id="em-nick" placeholder="허브에서 쓸 이름" maxlength="20" /></div>
      <div class="field"><label>백업PIN (숫자 4자리)</label>
        <input class="input" id="em-pin" type="password" inputmode="numeric" maxlength="4" placeholder="••••" /></div>
      <button class="btn" onclick="emailSetupGo()">${isCreate ? '허브 만들기' : '기록장 만들기'}</button>`;
  } else if (step === 'sent') {
    el.innerHTML = `
      <h2>📮 확인 메일을 보냈어요</h2>
      <div class="hint" style="margin-bottom:14px;">메일함에서 인증 링크를 누른 뒤,<br/>여기로 돌아와 <b>로그인</b>을 눌러주세요.<br/><small>(메일이 안 보이면 스팸함도 확인!)</small></div>
      <button class="btn" onclick="renderEmailStep('auth')">로그인하러 가기</button>`;
  } else if (step === 'done') {
    el.innerHTML = `
      <h2>${extra && extra.existing ? '다시 만나서 반가워요! 👋' : '완료! 🎉'}</h2>
      ${extra && extra.existing ? `<div class="hint" style="margin-bottom:10px;">이미 만든 기록장이 있어서 그리로 들어왔어요.</div>` : ''}
      ${isCreate && !(extra && extra.existing) ? `<div class="hint" style="margin-bottom:10px;">멤버들에게 초대코드를 알려주세요.</div>
      <div class="invite-code">${esc(extra.invite_code)}</div>` : ''}
      <button class="btn" style="margin-top:14px;" onclick="closeEmailAuth()">시작하기</button>`;
  }
}

async function emailAuthGo(isSignup) {
  const email = document.getElementById('em-email').value.trim();
  const pw = document.getElementById('em-pw').value;
  if (!email || !pw) { toast('이메일과 비밀번호를 입력하세요.', true); return; }
  showLoader(isSignup ? '가입 중…' : '로그인 중…');
  try {
    const { data, error } = isSignup
      ? await sb.auth.signUp({ email, password: pw,
          options: { emailRedirectTo: location.origin + location.pathname } })
      : await sb.auth.signInWithPassword({ email, password: pw });
    if (error) throw new Error(/already registered|already exists/i.test(error.message)
      ? '이미 가입된 이메일이에요. 로그인 탭에서 로그인해주세요.' : error.message);
    // 이미 가입·인증된 이메일로 가입 시 supabase는 메일을 보내지 않고
    // identities가 빈 가짜 성공 응답을 줌 → '메일 보냈어요'로 오인하지 않게 구분
    if (isSignup && data.user && Array.isArray(data.user.identities)
        && data.user.identities.length === 0) {
      throw new Error('이미 가입된 이메일이에요. 로그인 탭에서 로그인해주세요.');
    }
    if (!data.session) {
      renderEmailStep('sent');
      return;
    }
    if (emailFlow.purpose === 'signin') {
      try {
        const u = await sbrpc('login_linked', { p_hub_id: hubId() });
        applyAuth({ player_id: u.player_id, name: u.name, role: u.role, hub_id: u.hub_id },
                  u.pin, u.name + '님 환영합니다!');
        state._myLinks = null;
        closeEmailAuth();
      } catch (err) {
        closeEmailAuth();
        toast('이 허브에 연결된 멤버가 없어요. 닉네임+PIN 로그인 후 [연결하기]를 눌러주세요.', true);
        // 세션은 만들어졌으므로, 멤버 로그인 뒤 MY 하단 [연결하기]로 수동 연결
      }
      return;
    }
    if (emailFlow.purpose === 'link') {          // 현재 멤버를 이 계정에 연결
      state._myLinks = null;
      try { await loadMyLinks(); } catch (err) {}
      if ((state._myLinks || []).some(l => l.hub_id === hubId())) {
        closeEmailAuth();
        toast('이미 연결된 허브예요.', true);
        return;
      }
      const pin = localStorage.getItem('bg_pin');
      await api('linkPlayer', { playerId: state.user.player_id, pin });
      closeEmailAuth();
      toast('계정에 연결됐어요! 이제 여러 허브 기록을 모아볼 수 있어요.');
      state._myLinks = null;
      ensurePersonalHub(state.user.name, pin);   // 개인 기록장 자동 마련
      renderMy();
      return;
    }
    if (emailFlow.purpose === 'admin') {         // 허브 설정용 로그인
      closeEmailAuth();
      renderAdminHubSection();
      return;
    }
    if (emailFlow.purpose === 'personal') {
      // 이미 이 계정의 기록장이 있으면 정보 입력 없이 바로 이동
      try {
        const hubs = await sbrpc('my_hubs');
        const per = (hubs || []).find(h => h.kind === 'personal');
        if (per) {
          const u = await sbrpc('login_linked', { p_hub_id: per.hub_id });
          saveHub({ hub_id: per.hub_id, name: per.name, kind: 'personal' });
          applyAuth({ player_id: u.player_id, name: u.name, role: u.role, hub_id: u.hub_id },
                    u.pin, '기록장으로 들어왔어요!');
          state._myLinks = null;
          renderEmailStep('done', { existing: true });
          closeStartPage();
          await loadCore();
          return;
        }
      } catch (err) { /* 확인 실패 시 아래 일반 흐름(정보 입력)으로 */ }
    }
    renderEmailStep('setup');
  } catch (e) {
    toast(e.message === 'Invalid login credentials' ? '이메일 또는 비밀번호가 올바르지 않아요.' : e.message, true);
  } finally { hideLoader(); }
}

async function emailSetupGo() {
  const isCreate = emailFlow.purpose === 'create';
  const nick = document.getElementById('em-nick').value.trim();
  const pin = document.getElementById('em-pin').value.trim();
  const hubName = isCreate ? document.getElementById('em-hubname').value.trim() : nick + '의 기록장';
  if (isCreate && !hubName) { toast('허브 이름을 입력하세요.', true); return; }
  if (!nick || !/^\d{4}$/.test(pin)) { toast('닉네임과 숫자 4자리 PIN을 입력하세요.', true); return; }
  showLoader('만드는 중…');
  try {
    const hub = await api('createHub', { name: hubName, kind: isCreate ? 'hub' : 'personal' });
    saveHub({ hub_id: hub.hub_id, name: hub.name, invite: hub.invite_code,
              kind: isCreate ? 'hub' : 'personal' });
    if (hub.existing) {
      // 개인 기록장은 계정당 1개 — 이미 있으면 그 기록장으로 재입장(연결 계정 자동 로그인)
      let user;
      try { user = await api('loginLinked'); }
      catch (err) {
        // 기록장은 있는데 멤버 연결이 없는 경우: 입력한 닉네임·PIN으로 가입 후 연결
        user = await api('signup', { name: nick, pin });
        await api('linkPlayer', { playerId: user.player_id, pin });
        user.pin = pin;
      }
      applyAuth({ player_id: user.player_id, name: user.name, role: user.role, hub_id: user.hub_id },
                user.pin, '이미 만든 기록장으로 들어왔어요!');
      renderEmailStep('done', hub);
      closeStartPage();
      await loadCore();
      return;
    }
    const user = await api('signup', { name: nick, pin });          // 첫 멤버로 가입(자동 admin)
    await api('linkPlayer', { playerId: user.player_id, pin });     // 내 계정에 연결
    applyAuth(user, pin, hub.name + ' 시작!');
    renderEmailStep('done', hub);
    closeStartPage();
    if (isCreate) ensurePersonalHub(nick, pin);   // 이메일 계정 = 개인 기록장 자동 마련
    await loadCore();
  } catch (e) {
    toast(e.message, true);
  } finally { hideLoader(); }
}

function init() {
  console.log('BoardGameHub build:', APP_VERSION);
  const saved = localStorage.getItem('bg_user');
  if (saved) { try { state.user = JSON.parse(saved); } catch (e) {} }
  const savedHub = localStorage.getItem('bg_hub');
  if (savedHub) { try { state.hub = JSON.parse(savedHub); } catch (e) {} }
  // 개편 전 사용자(허브 저장 없음 + 계정 있음) → 기본 허브로 자동 배정
  if (!state.hub && state.user) saveHub({ hub_id: 'H001', name: '우리 허브' });
  updateWhoami();
  updateHubTitle();
  if (!window.supabase || !SUPABASE_URL || !SUPABASE_ANON_KEY || !/^https?:\/\//.test(SUPABASE_URL)) {
    document.getElementById('play-list').innerHTML =
      `<div class="empty"><div class="big">⚙️</div>Supabase 설정이 필요합니다.<br/>` +
      `<span class="hint">index.html 상단의 <b>SUPABASE_URL</b>·<b>SUPABASE_ANON_KEY</b>를 확인하세요. (README 참고)</span></div>`;
    toast('Supabase 설정을 확인하세요 (index.html 상단)', true);
    return;
  }
  if (/type=recovery/.test(location.hash)) {          // 비밀번호 재설정 링크로 진입
    openStartPage(!!state.hub);
    startShow('recovery');
    if (state.hub) loadCore();
    return;
  }
  if (!state.hub) { openStartPage(false); return; }   // 허브 없으면 시작 화면부터
  loadCore();
  refreshHubName();
}
init();

// PWA: 서비스워커 등록(설치/오프라인 셸)
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('sw.js').catch(() => {});
  });
}
