# bgg-search Edge Function 배포 가이드

BGG(BoardGameGeek)에서 게임 정보를 가져오는 프록시 함수예요.
(브라우저는 CORS·XML 때문에 BGG를 직접 못 부르므로 Supabase가 대신 호출)

## 배포 (Supabase 대시보드에서, CLI 없이)

1. Supabase 대시보드 → 왼쪽 메뉴 **Edge Functions**
2. **Deploy a new function** (또는 Create function)
3. 이름: **`bgg-search`** (앱이 이 이름으로 호출하므로 정확히)
4. `index.ts` 내용을 편집기에 통째로 붙여넣기
5. **Deploy** 클릭

인증(JWT 검증)은 기본값 그대로 두면 돼요 — 앱이 anon 키로 호출하며 통과합니다.

## 확인

배포 후 게임 추가 → 한글 게임명 입력 → **📚 도감 검색**을 누르면
자체 도감 결과 아래에 **🌐 BGG 검색 결과**가 붙어요.
- 영문명으로 검색하면 잘 잡히고, 한글은 BGG 특성상 커버가 제한적이에요.
- BGG 카드를 누르면 영문명·최소/최대 인원·플레이타임·사진이 채워지고,
  한글명(내가 입력한 것)과 분류는 그대로 직접 지정해 등록합니다.

함수가 없거나 배포 전이면 앱은 그냥 자체 도감만으로 동작해요(에러 안 남).
