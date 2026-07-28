# BGG 검색 프록시 (Cloudflare Worker)

브라우저에서 BoardGameGeek(BGG) 게임 정보를 검색할 수 있게 해주는 작은 프록시예요.

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

## 참고 (BGG 정책 요약)
- 요청은 `boardgamegeek.com` (www 없이), 헤더 `Authorization: Bearer <토큰>` ("Bearer" 뒤 공백, 콜론 없음)
- 요청은 서버에서, 결과는 캐싱 권장. 요청 수 최소화 (사용량은 applications 페이지 Usage에서 확인)
- 공개 앱은 **"Powered by BGG" 로고**(boardgamegeek.com 링크)를 표시해야 함
  → 앱의 BGG 검색 결과 영역에 이미 포함해 두었어요.
- 정책·API는 예고 없이 바뀔 수 있음 (Geek Tools News 포럼에서 공지)
