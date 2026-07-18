# 🎲 보드게임 동아리 관리 웹앱 (Supabase 백엔드)

동아리원들이 모바일에서 사용하는 보드게임 관리 페이지입니다.
플레이 기록·평점·개인 통계를 관리하고, 게임 정보를 직접 입력해 등록합니다.

- **프론트엔드**: 단일 `index.html` (vanilla JS, 프레임워크 없음) — GitHub Pages 호스팅
- **백엔드/DB**: **Supabase (PostgreSQL)** — 조회는 anon 허용, 쓰기는 PIN 검증 RPC 함수로만
- 로그인은 Supabase Auth를 쓰지 않고 `players` 테이블의 **이름 + PIN** 대조 방식(기존과 동일)

> 이전에는 Google Sheets + Apps Script 백엔드였습니다. UI/화면은 그대로 두고
> 데이터 접근 계층만 Supabase로 옮겼습니다. (레거시 `Code.gs`는 참고용으로 남겨둠)

---

## 📐 아키텍처 개요

```
[모바일 브라우저]                         [Supabase]
  index.html          supabase-js        ┌───────────────────────────┐
 (GitHub Pages) ───▶  (CDN 클라이언트) ─▶ │ 조회: RPC/뷰 (anon 허용)   │
                                          │ 쓰기: RPC 함수(PIN 검증)   │
                                          │   └ SECURITY DEFINER       │
                                          │ 테이블: players/games/     │
                                          │        ratings/playlogs    │
                                          │ RLS: 직접 쓰기 전부 차단   │
                                          └───────────────────────────┘
```

- **조회**(select)는 `anon` 역할에 허용. 단 `players` **원본은 비공개**(PIN 보호)이며,
  안전 컬럼만 담은 `players_public` 뷰로만 노출됩니다.
- **쓰기**(insert/update/delete)는 anon 정책이 없어 **직접 접근이 전부 차단**됩니다.
  모든 쓰기는 함수 안에서 PIN을 검증하는 **Postgres RPC(SECURITY DEFINER)** 로만 수행됩니다.
- 클라이언트의 기존 `api(action, params)` 인터페이스는 그대로 유지하고, 내부만
  supabase-js 호출로 교체했습니다. (화면/로직 변경 없음)

---

## 🚀 배포 순서 (요약)

| 순서 | 단계 | 위치 |
|---|---|---|
| 1 | **테이블 + RPC + RLS 생성** — `supabase_schema.sql` 통째로 실행 | Supabase 대시보드 → SQL Editor |
| 2 | **HTML 키 교체** — `SUPABASE_URL`, `SUPABASE_ANON_KEY` 확인/입력 | `index.html` 상단 |
| 3 | **기존 시트 CSV import** — 시트 4장을 CSV로 내보내 테이블에 넣기 | Supabase → Table Editor → Import |
| 4 | **GitHub Pages 배포** | 저장소 Settings → Pages |

> `supabase_schema.sql` 한 파일 안에 **① 테이블 → ② RPC 함수 → ③ RLS/권한** 이
> 순서대로 들어 있어, 한 번 붙여넣어 실행하면 1단계가 모두 끝납니다. 여러 번 실행해도 안전합니다.

---

## 1. 테이블 + RPC + RLS 생성 (SQL Editor)

1. Supabase 대시보드 → 왼쪽 **SQL Editor** → **New query**
2. 이 저장소의 **`supabase_schema.sql` 전체**를 붙여넣고 **Run**
3. 성공하면 아래가 만들어집니다.
   - 테이블: `players`, `games`, `ratings`, `playlogs`, `categories`
   - 공개 뷰: `players_public` (player_id, name, role만)
   - 조회 RPC: `get_games`, `get_plays`, `get_player_stats`, `get_my_ratings`, `login`, `signup`
   - 쓰기 RPC: `save_rating`, `add_play`, `update_play`, `delete_play`, `add_game`, `update_game`
   - RLS: 조회 anon 허용(`players` 제외), 쓰기 전부 차단
   - `categories`에 기본 분류 10종 자동 삽입

> **PIN 검증 로직**은 기존과 동일합니다. `players.pin`(평문)이 우선이고, 평문이 비어 있는
> 레거시 행만 `pin_hash`(SHA-256)로 대조합니다. `pgcrypto` 확장은 스크립트가 자동 설치합니다.

---

## 2. HTML에 Supabase 키 연결

`index.html` 상단의 상수 두 개만 확인/교체하면 됩니다. (이미 이 프로젝트 값으로 채워져 있습니다.)

```js
// index.html <script> 최상단
const SUPABASE_URL      = "https://oxvacxvynyezysvkhbmx.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...";  // anon public key
```

- 값은 Supabase 대시보드 **Project Settings → API** 의 **Project URL** / **anon public** 키입니다.
- **anon key는 공개용**이라 프론트엔드에 넣어도 안전합니다(브라우저에 노출되는 것이 정상).
  실제 보안은 RLS 정책과 RPC의 PIN 검증이 담당합니다. `service_role` 키는 **절대** 넣지 마세요.
- supabase-js는 `index.html`에서 CDN으로 로드합니다:
  `https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2`

---

## 3. 기존 Google Sheets → CSV import

기존 데이터를 옮기는 단계입니다. (신규로 시작한다면 건너뛰어도 됩니다 — 앱에서 가입/입력하면 됨.)

### 3-1. 시트에서 CSV 내보내기
Google Sheets에서 **탭별로** `파일 → 다운로드 → 쉼표로 구분된 값(.csv)` 을 선택해
`Players`, `Games`, `Ratings`, `PlayLogs` 4개 CSV를 받습니다. (탭마다 한 번씩)

### 3-2. Supabase로 가져오기
Supabase → **Table Editor** → 대상 테이블 선택 → **Insert → Import data from CSV** →
받은 CSV 업로드 → 컬럼 매핑 확인 → Import.

- 컬럼명이 시트 헤더와 **동일**하므로 자동 매핑됩니다.
- 순서는 상관없지만 **`players`, `games` 를 먼저**, 그다음 `ratings`, `playlogs` 를 권장합니다.
  (참조 무결성 FK는 일부러 걸지 않았으므로 순서가 틀려도 import 자체는 됩니다.)

### 3-3. 데이터 타입 주의점
| 컬럼 | 주의 |
|---|---|
| `is_win` (playlogs) | 시트의 `TRUE`/`FALSE` 텍스트 → Postgres `boolean`으로 그대로 인식됩니다. |
| `score`, `min_players`, `weight` 등 숫자 | **빈 셀은 NULL**로 들어갑니다(정상). |
| `play_date`, `created_at`, `joined_at` 등 | **텍스트로 저장**됩니다(시트와 동일, 시간대 변환 없음). |
| `player_id` (playlogs, 게스트) | 게스트는 빈값 → NULL. `player_name`만 채워집니다. |

> import 후 ID 자동 증가는 기존 최대값 기준으로 이어집니다. 예를 들어 `P001~P007`이 있으면
> 다음 가입자는 `P008`이 됩니다. (RPC의 `_next_id`가 접미사 최대값 + 1을 계산)

---

## 4. GitHub Pages 배포

1. 이 저장소를 GitHub에 푸시합니다. (`index.html`이 루트에 있어야 합니다.)
2. 저장소 **Settings → Pages**
3. **Source**: `Deploy from a branch`, **Branch**: 배포 브랜치 / `/(root)` → Save
4. 잠시 후 발급되는 `https://<사용자>.github.io/<저장소>/` 로 접속합니다.

> 모바일에서 접속 후 "홈 화면에 추가"하면 앱처럼 사용할 수 있습니다.

---

## 5. 계정(플레이어) — 셀프 가입

별도 발급 없이, 앱의 **MY → 가입하기** 탭에서 **닉네임 + 숫자 4자리 PIN**만 입력하면
바로 가입·로그인됩니다. PIN은 `players.pin`(평문)에 저장되며 이 값이 곧 비밀번호입니다.

- **닉네임**은 로그인 아이디로 쓰이므로 중복되면 가입이 거부됩니다(`name` UNIQUE).
- **가장 먼저 가입한 사람이 자동으로 관리자(`admin`)** 가 됩니다(게임 세부정보 수정 권한).
- 관리자를 추가로 지정하려면 SQL Editor에서 `update players set role='admin' where player_id='P00X';`
- PIN 재설정: `update players set pin='새PIN' where player_id='P00X';`

---

## 6. 보안 모델

- **조회**: `games`, `ratings`, `playlogs`, `categories` 는 anon `SELECT` 허용.
  `players` 원본은 정책이 없어 anon이 직접 읽을 수 없고(=PIN 보호), `players_public` 뷰
  (player_id, name, role)로만 노출됩니다.
- **쓰기**: 테이블에 anon 쓰기 정책이 없어 직접 INSERT/UPDATE/DELETE 불가.
  모든 변경은 아래 RPC로만 가능하며, 함수 진입 시 **PIN을 검증**합니다.
- **권한 검증**: `update_game`은 `admin`만, `update_play`/`delete_play`는
  `created_by`가 본인인 세션만 허용합니다.
- RPC는 `SECURITY DEFINER` + `search_path` 고정. 내부 헬퍼(`_verify`, `_next_id`)는
  anon 실행 권한을 부여하지 않았습니다(RPC 내부에서만 호출).

---

## 7. RPC / 조회 매핑 (클라이언트 `api()` ↔ Supabase)

| 화면 동작 | 클라이언트 `api(action)` | Supabase 호출 |
|---|---|---|
| 로그인 | `login` | `rpc('login', {p_name, p_pin})` |
| 가입 | `signup` | `rpc('signup', {p_name, p_pin})` |
| 게임 목록 | `getGames` | `rpc('get_games')` |
| 플레이 목록 | `getPlays` | `rpc('get_plays')` |
| 개인 통계 | `getPlayerStats` | `rpc('get_player_stats', {p_player_id})` |
| 내 평점 | `getMyRatings` | `rpc('get_my_ratings', {p_player_id})` |
| 참가자 목록 | `getPlayers` | `from('players_public').select(...)` |
| 분류 목록 | `getCategories` | `from('categories').select('name')` |
| 평점 저장 | `saveRating` | `rpc('save_rating', {p_player_id,p_pin,p_game_id,p_rating,p_memo})` |
| 플레이 추가 | `addPlay` | `rpc('add_play', {p_player_id,p_pin,p_payload})` |
| 플레이 수정 | `updatePlay` | `rpc('update_play', {p_player_id,p_pin,p_payload})` |
| 플레이 삭제 | `deletePlay` | `rpc('delete_play', {p_player_id,p_pin,p_session_id})` |
| 게임 추가 | `addGame` | `rpc('add_game', {p_player_id,p_pin,p_payload})` |
| 게임 수정 | `updateGame` | `rpc('update_game', {p_player_id,p_pin,p_payload})` |

반환 형태(JSON 구조)는 기존 Apps Script 응답과 동일하게 맞춰, 화면 코드를 수정하지 않았습니다.

---

## 8. 사용 방법

| 탭 | 설명 |
|---|---|
| **플레이** | 전체 플레이 기록을 최신순으로. 상단에 이번 달/누적/최다 플레이 요약 |
| **게임** | 등록된 모든 게임을 우리Hub평점 내림차순 카드로. 분류·인원·난이도 필터 + 이름 검색 |
| **MY** | 닉네임+PIN 가입/로그인 → 전체 기록/플레이 기록/게임 기록(평점·메모) |
| **+ 버튼** | 게임 추가(직접입력·사진 촬영/업로드) · 플레이 결과 추가 |

- 로그인 정보는 `sessionStorage`에 유지됩니다(탭을 닫으면 해제).
- 쓰기 작업 시 본인 확인용 PIN을 한 번 입력합니다.

---

## 9. 계산 로직

- **승률** = `is_win=true` 행 수 ÷ 전체 참가 행 수 × 100 (소수 1자리)
- **우리Hub평점** = 게임별 `ratings.rating` 평균 (소수 1자리, 평가 0건이면 `-`)
- **게임별 개인 승률** = 그 게임에서의 승수 ÷ 참가 수

---

## 10. 트러블슈팅

| 증상 | 원인/해결 |
|---|---|
| 화면이 안 뜸 / "Supabase 설정 필요" | `index.html`의 `SUPABASE_URL`·`SUPABASE_ANON_KEY` 확인. supabase-js CDN 로드 확인 |
| 로그인/가입 실패 | 닉네임·PIN 확인. 처음이면 **가입하기** 탭으로 먼저 가입 |
| 조회는 되는데 저장이 안 됨 | `supabase_schema.sql`을 실행했는지(특히 RPC/GRANT 부분) 확인 |
| `permission denied for function ...` | 해당 RPC에 `grant execute ... to anon`이 적용됐는지 확인(스크립트 재실행) |
| `function ... does not exist` | 클라이언트가 부르는 RPC 이름/인자와 함수 시그니처가 일치하는지 확인 |
| CSV import 시 boolean/숫자 오류 | `is_win`은 TRUE/FALSE 텍스트 OK. 숫자 빈 셀은 NULL. 날짜는 텍스트 컬럼 |
| PIN 분실/변경 | SQL Editor: `update players set pin='새값' where player_id='P00X';` |
| 관리자 지정 | 첫 가입자가 자동 admin. 이후 `update players set role='admin' where ...` |

---

## 파일 구성

```
index.html            # 단일 파일 프론트엔드 (CSS/JS 인라인, supabase-js CDN)
supabase_schema.sql   # Supabase 스키마: 테이블 + RPC + RLS (SQL Editor에 붙여넣기)
README.md             # 이 문서
Code.gs               # (레거시) 이전 Google Apps Script 백엔드 — 참고용
```
