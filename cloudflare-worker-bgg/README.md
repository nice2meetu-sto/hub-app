# BGG 검색 프록시 (Cloudflare Worker)

브라우저에서 BoardGameGeek(BGG) 게임 정보를 검색할 수 있게 해주는 작은 프록시예요.
여기에 **Supabase 재우기 방지(keep-alive)** 기능도 함께 들어 있어요. (맨 아래 참고)

## 중요: BGG API는 이제 '앱 등록 + 토큰'이 필수

BGG XML API는 2025-07 정책부터 **등록된 앱의 Bearer 토큰** 없이는 401로 거부합니다.
(예전에 우리가 받은 401이 이것 때문이에요.) 서버측 프록시 + 캐싱은 BGG가 권장하는
구조라, 이 Worker에 토큰만 붙이면 정책에 맞게 쓸 수 있어요.

### 1) BGG에 앱 등록 (무료 비상업 라이선스)
1. BGG 계정 로그인 → https://boardgamegeek.com/applications
2. **Create application** → **Non-commercial** 선택
3. 설명 예시(영문):
   > Non-commercial board game club logging PWA (boardgame-hub.com).
   > A server-side proxy (Cloudflare Worker) fetches game metadata
   > (name, player count, playtime, box image) when users register games.
   > Low request volume, results cached. No ads, no payments.
4. 승인까지 **1주 이상** 걸릴 수 있어요.

### 2) 토큰 만들기
승인되면 같은 페이지에서 앱 옆 **Tokens** → 토큰 생성.

### 3) Worker에 토큰 넣기
1. Cloudflare 대시보드 → Workers & Pages → `bgg-search` → **Settings** → **Variables and Secrets**
2. **Add** → Type: **Secret**, 이름: `BGG_TOKEN`, 값: 발급받은 토큰 → 저장(재배포)

### 4) 확인 & 앱 켜기
- `https://bgg-search.<계정>.workers.dev/?q=catan` → `{"results":[...]}` 나오면 성공
- `app.js` 상단 `BGG_PROXY_URL` 에 Worker 주소를 넣고 배포하면 앱에서 BGG 검색이 켜져요.

## Worker 배포 (처음 하는 경우)
1. https://dash.cloudflare.com → **Workers & Pages** → **Create Worker**
2. 이름 `bgg-search` → **Deploy** → **Edit code** → `worker.js` 내용 붙여넣기 → **Deploy**

## Supabase 재우기 방지 (keep-alive)

Supabase 무료 플랜은 **7일 동안 요청이 하나도 없으면 프로젝트를 자동으로 일시정지**해요.
(출시 전이라 방문자가 없을 때 잠기는 이유가 이것.) 이 Worker가 하루 한 번 앱과 똑같은
가벼운 조회 요청을 보내서 '활동 중' 상태를 유지하면 잠기지 않아요.

편법이 아니라 **사용자가 하루 한 번 앱을 켠 것과 완전히 동일한 정상 요청**이에요.

### 설정 (1분, 무료)
1. Cloudflare 대시보드 → Workers & Pages → `bgg-search` → **Settings**
2. **Triggers**(또는 Trigger Events) → **Cron Triggers** → **Add Cron Trigger**
3. 스케줄에 `0 3 * * *` 입력 → 저장
   - Cron은 **UTC 기준**이라 `0 3 * * *` = 한국시간 낮 12시
   - 하루 1회로 충분해요 (7일 중 한 번만 요청이 있으면 안 잠김)

### 잘 되는지 확인
브라우저에서 아래 주소를 열어보세요. Cron이 매일 하는 일과 똑같은 요청을 즉시 보내요.

```
https://bgg-search.<계정>.workers.dev/?keepalive=1
```

- `{"ok":true,"status":200,...}` → 정상. 이제 안 잠겨요.
- `{"ok":false,"status":503,...}` → Supabase가 지금 잠들어 있는 상태.
  Supabase 대시보드에서 **Restore** 로 깨운 뒤 다시 확인하세요.

### 참고
- Supabase 주소·anon key는 `worker.js` 안에 이미 들어 있어요. anon key는 앱의 `app.js`에도
  공개돼 있는, 공개를 전제로 만들어진 키라 여기 적혀 있어도 안전해요.
- 다른 Supabase 프로젝트로 바꾸려면 대시보드에서 `SUPABASE_URL`, `SUPABASE_ANON_KEY`
  변수를 추가하면 그 값이 우선 적용돼요.
- 실행 기록은 Worker의 **Logs** 탭에서 `keep-alive OK` 로 확인할 수 있어요.
- 앱에 매일 들어오는 사용자가 생기면 이 기능 없이도 안 잠기지만, 그대로 둬도 무해해요.

## 참고 (BGG 정책 요약)
- 요청은 `boardgamegeek.com` (www 없이), 헤더 `Authorization: Bearer <토큰>` ("Bearer" 뒤 공백, 콜론 없음)
- 요청은 서버에서, 결과는 캐싱 권장. 요청 수 최소화 (사용량은 applications 페이지 Usage에서 확인)
- 공개 앱은 **"Powered by BGG" 로고**(boardgamegeek.com 링크)를 표시해야 함
  → 앱의 BGG 검색 결과 영역에 이미 포함해 두었어요.
- 정책·API는 예고 없이 바뀔 수 있음 (Geek Tools News 포럼에서 공지)
