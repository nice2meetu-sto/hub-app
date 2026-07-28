# BGG 검색 프록시 (Cloudflare Worker)

브라우저에서 BoardGameGeek(BGG) 게임 정보를 검색할 수 있게 해주는 작은 프록시예요.
BGG는 CORS를 막고, 데이터센터 IP(예: Supabase 함수)도 차단하기 때문에,
**Cloudflare Worker**(Cloudflare 자체 망에서 나감)로 우회합니다.

## 배포 (대시보드, 약 5분)

1. https://dash.cloudflare.com → 왼쪽 **Workers & Pages** → **Create application** → **Create Worker**.
2. 이름을 `bgg-search` 로 짓고 **Deploy**.
3. **Edit code** → 편집기 내용을 전부 지우고 `worker.js` 파일 내용을 붙여넣기 → **Deploy**.
4. 배포되면 주소가 나와요: `https://bgg-search.<계정>.workers.dev`
   - 브라우저에서 `https://bgg-search.<계정>.workers.dev/?q=catan` 열어서
     `{"results":[...]}` JSON이 나오면 성공.

> 무료 플랜으로 하루 100,000 요청까지 충분합니다.

## 앱에 연결

`app.js` 상단의 `BGG_PROXY_URL` 값에 위 주소를 넣고 배포하세요.

```js
const BGG_PROXY_URL = 'https://bgg-search.<계정>.workers.dev';
```

비워두면(`''`) BGG 검색은 표시되지 않고 기존 자체 도감 검색만 동작합니다.

## 혹시 그래도 막히면

`https://bgg-search.<계정>.workers.dev/?q=catan` 를 열었을 때
`{"results":[],"error":"BGG HTTP 401"}` 처럼 나오면 BGG가 Worker IP까지 막은 경우예요.
그때는 알려주세요 — 인기 게임 데이터셋을 도감에 미리 담는 방식으로 전환할 수 있어요.
