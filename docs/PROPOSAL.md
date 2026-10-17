# 기획서: Apple Notes용 로컬 우선 확장 앱 (`tabieum`)

## 1. 한 줄 요약

계정이나 서버 없이 쓰는 Apple Notes 확장 앱이다. 기본 기능은 검색, 백링크, 마크다운, 템플릿이다. **Vim 모드**, **RAG 인덱스**, **AI 플러그인**은 설정에서 켜는 옵션이다.

## 2. 배경

Apple Notes를 보강하는 기능(AX 오버레이, NoteStore.sqlite 읽기, AppleScript 쓰기)은 모두 로컬에서 동작할 수 있다. 그런데 이런 도구는 흔히 로그인, 구독, 서버를 거치는 AI, 크래시 리포트를 함께 묶는다. 이 프로젝트는 그런 것 없이 로컬 기능만 제공한다. 기존 제품의 코드와 에셋은 쓰지 않고 처음부터 새로 만든다(clean-room).

## 3. 원칙

1. **Local-first**: 기본 상태에서는 네트워크 요청을 하나도 보내지 않는다. 업데이트 확인도 옵트인이다.
2. **No account**: 로그인, 로그아웃, 라이선스 서버가 없다.
3. **Core는 AI를 모른다**: AI는 플러그인 경계 바깥에 둔다.
4. **Notes DB는 읽기 전용**: `NoteStore.sqlite`에는 절대 쓰지 않는다. 쓰기는 AppleScript나 AX로만 한다.
5. **옵션은 꺼져 있으면 비용이 0**: 꺼진 기능은 CPU, 디스크, 권한 중 무엇도 쓰지 않는다.

## 4. 기능 범위

### 4.1 Core (항상 켜짐)

| 기능 | 구현 방식 |
|---|---|
| 전역 검색 (단축키) | NoteStore.sqlite를 읽고 protobuf를 디코드해 자체 `index.sqlite`(FTS5)에 넣는다 |
| 백링크 | `com.apple.notes.inlinetextattachment.link` 첨부를 역으로 따라가 인덱싱한다 |
| Copy as Markdown / Deeplink | 노트 본문 protobuf를 Markdown으로 변환한다. 딥링크는 `applenotes:`나 자체 URL 스킴을 쓴다 |
| 마크다운 자동 변환 (`# `, `- [ ]` 등) | 키 입력 시퀀스를 감지해 AX로 서식 메뉴를 실행한다 |
| 슬래시 커맨드 / 템플릿 | 특정 폴더의 노트를 템플릿으로 쓴다. 삽입은 AppleScript로 한다 |

### 4.2 옵션 A: Vim 모드

- **범위 (v1)**
  - 모드: Normal, Insert, Visual(문자 단위)
  - 이동: `h j k l`, `w b e`, `0 ^ $`, `gg G`
  - 편집: `x`, `dd`, `yy`, `p`, `u`
  - Insert 진입: `i a I A o O`
  - 나가기: `Esc` / `Ctrl-[` (`jk` 매핑은 옵션)
- **v1 제외**: 카운트 prefix(`3j`), 텍스트 오브젝트, 레지스터, `.` 반복, 매크로. 필요해지면 v2에서 다룬다.
- **구현**
  - Notes가 앞에 있고 본문 텍스트 영역에 포커스가 있을 때만 CGEventTap이 키를 가로챈다.
  - 이동은 `kAXSelectedTextRangeAttribute`를 읽고 쓰는 방식으로 한다.
  - 편집은 선택 범위를 잡은 뒤 합성 키 이벤트(⌫, ⌘C, ⌘V)를 보낸다. 그래야 Notes의 undo 스택이 유지된다.
  - 커서 옆에 모드 표시 오버레이(`-- NORMAL --`)를 띄운다.
- **리스크**: 표, 체크리스트, 첨부 주변에서 AX 범위가 어긋날 수 있다. 일단 해당 블록에서는 Vim 동작을 패스스루하고, 문제가 확인되면 그때 고친다.

### 4.3 옵션 B: RAG 인덱스 (벡터 DB)

- **저장소**: core 인덱스와 같은 SQLite 파일에 **sqlite-vec**를 붙인다. 별도 서버나 DB 프로세스는 두지 않는다.
- **청킹**: 제목과 헤딩 단위로 나눈다. 너무 길면 약 500토큰씩 자르고 overlap을 둔다. 청크마다 `note_id`, `heading_path`, `modified_at`를 붙인다.
- **임베딩 소스** (택1)
  1. `NLEmbedding.sentenceEmbedding` (Apple 내장, 오프라인, 의존성 없음). 이것이 기본값이다.
  2. AI 플러그인의 `/v1/embeddings` (Ollama `nomic-embed-text` 등). 품질이 필요할 때 쓴다.
- **검색**: FTS5(BM25)와 벡터 kNN을 RRF로 합친 하이브리드 검색.
- **증분 갱신**: NoteStore.sqlite의 WAL 변경을 FSEvents로 감지한다. 그다음 `ZMODIFICATIONDATE1`이 바뀐 노트만 다시 임베딩한다.
- **"바로 사용"하는 방법**: 로컬 **MCP 서버**(stdio)로 노출한다.
  - 도구는 `search_notes(query, k)`, `get_note(id)`, `list_backlinks(id)` 세 개다.
  - Claude Desktop, Claude Code, Cursor 같은 외부 에이전트가 앱 안에 AI가 없어도 노트를 RAG 소스로 쓸 수 있다.

### 4.4 옵션 C: AI 플러그인

- **v1 플러그인 = OpenAI 호환 엔드포인트 설정 하나**: `base_url`, `model`, `api_key`(Keychain 저장).
  - Ollama, LM Studio, OpenAI, OpenRouter가 모두 이 설정 하나로 커버된다.
  - 동적 로딩 번들은 만들지 않는다. hardened runtime의 라이브러리 검증과 충돌하고, 지금은 필요도 없다.
- **기능**
  - 선택 영역 다시 쓰기, 요약
  - `/ai` 슬래시 커맨드
  - 옵션 B가 켜져 있으면 "내 노트에 묻기"(RAG 컨텍스트 주입)
- **경계**: core는 `AIProvider` 프로토콜 하나만 알고, 구현은 플러그인 모듈에 둔다. 플러그인이 꺼져 있으면 AI 관련 UI가 아예 보이지 않는다.

## 5. 아키텍처

```
┌───────────── tabieum.app (non-sandboxed) ───────────────────────────┐
│ Core                                                                │
│  NotesReader ── NoteStore.sqlite (RO) ── ProtobufDecoder → Markdown │
│  Indexer ───── index.sqlite (GRDB: FTS5 [+ sqlite-vec])             │
│  NotesBridge ─ AX (caret, overlay, 메뉴 실행) / AppleScript (쓰기)  │
│  UI ────────── Search panel, Backlinks, Slash, Settings             │
│ Options                                                             │
│  VimEngine ─── CGEventTap → mode state machine → AX/키 합성         │
│  RAG ───────── Chunker → Embedder(NL | plugin) → vec index          │
│  MCPServer ─── stdio: search_notes / get_note / list_backlinks      │
│  AIPlugin ──── OpenAI-compatible client                             │
└─────────────────────────────────────────────────────────────────────┘
```

- **스택**: Swift 6, AppKit + SwiftUI, GRDB, SwiftProtobuf, sqlite-vec. 업데이트용 Sparkle은 옵트인이다.
- **권한**
  - Accessibility: 필수
  - Full Disk Access 또는 Notes 그룹 컨테이너 접근: 검색과 인덱스에 필요
  - Automation(Notes): 템플릿과 쓰기에 필요
- **배포**: App Store는 불가하다(AX, event tap, 다른 앱 컨테이너 접근 때문). 배포 방식은 소유자가 확인한 뒤 정한다(직접 배포가 유력하다).

## 6. 마일스톤

| 단계 | 산출물 | 완료 기준 |
|---|---|---|
| M0 스파이크 (1주) | NoteStore 읽기 + protobuf → Markdown CLI, AX 커서 추적 데모 | 내 노트 100%가 크래시 없이 Markdown으로 변환된다 |
| M1 Core (3주) | 검색, 백링크, Copy Markdown/Deeplink, 마크다운 자동 변환 | 노트 1만 개 기준 검색 결과가 100ms 안에 나온다 |
| M2 Vim (2주) | v1 커맨드 세트, 모드 오버레이 | 표/체크리스트 밖에서 4.2 커맨드가 모두 동작하고, undo가 유지된다 |
| M3 RAG + MCP (2주) | sqlite-vec 인덱스, 하이브리드 검색, MCP stdio 서버 | Claude Desktop에서 `search_notes`로 관련 노트를 찾아온다 |
| M4 AI 플러그인 (1주) | OpenAI 호환 provider, `/ai`, RAG 연동 | Ollama 로컬 모델로 오프라인 동작한다 |
| M5 템플릿/슬래시 (1주) | 템플릿 폴더, 슬래시 패널 | |

## 7. 리스크

| 리스크 | 대응 |
|---|---|
| macOS 업데이트로 Notes 스키마나 protobuf가 바뀜 | 디코더를 버전별 fixture 테스트로 고정한다. 실패한 노트는 건너뛰고 로그를 남긴다 |
| AX 메뉴 경로가 언어별로 다름 | 메뉴 제목 대신 메뉴 항목의 단축키나 selector로 찾고, 실패하면 로케일 테이블로 넘어간다 |
| 잠긴(암호화) 노트 | 인덱싱에서 제외한다(`ZISPASSWORDPROTECTED`) |
| Vim 키 가로채기가 IME(한글)와 충돌 | Normal 모드에서는 입력 소스와 무관하게 keycode로 판정한다. Insert 모드에서는 패스스루한다 |
| 임베딩 비용 / 배터리 | 유휴 시간이나 전원 연결 시에만 배치로 처리한다. 진행률을 표시한다 |

## 8. 결정 사항

1. **형태: Apple Notes 확장.** 동기화(iCloud, iPhone/iPad 편집, 충돌 해결)를 Apple이 처리하므로 직접 구현할 필요가 없다. 대가로 받아들이는 것:
   - 확장 기능(Vim, 검색, RAG, AI)은 Mac에서만 동작한다. 모바일에서는 순정 Notes를 쓴다.
   - RAG 인덱스는 Mac마다 로컬에서 따로 만든다(동기화하지 않음).
   - Notes 내부 포맷과 AX 동작에 종속된다(7장 리스크).
2. **공개 범위: 오픈소스(Apache-2.0).** 소유자가 확인하기 전까지는 배포하지 않는다.
3. **최소 macOS 버전: 15.**
4. **이름: `tabieum`.** 탭(색인표)과 이음(연결)을 합친 이름이다. 이전 임시 이름 `NoteKit`은 같은 분야의 인기 프로젝트와 겹쳐서 버렸다. 이름은 `Config/product.env` 한 곳에만 둔다.
