# NoteKit golden fixture            ← Title (첫 줄, ⇧⌘T)
## Heading sample                    ← Heading (⇧⌘H)
### Subheading sample                 ← Subheading (⇧⌘J)
Plain body text.                  ← Body (⇧⌘B)
**Bold**, *italic*, ***bold italic***, <u>underlined</u> and ~~struck words.~~
                                  ← 단어마다 굵게 ⌘B, 기울임 ⌘I, 굵게+기울임, 밑줄 ⌘U, 취소선(Format > Font)
Open the [example link.](https://example.com)            ← "example link"에 링크 ⌘K, https://example.com
🐱 **then bold text after emoji     ← 이모지 뒤 "bold text after emoji"만 굵게 (UTF-16 검증용)**

- Bullet one                      ← Bulleted list (⇧⌘7)
    - Bullet nested               ← Tab으로 들여쓰기
- Bullet two	
- Dash one                        ← Dashed list (⇧⌘8)
- Dash two
1. Number one                     ← Numbered list (⇧⌘9)
1. Number two
- [x] Todo done                       ← Checklist (⇧⌘L), 이 항목은 체크
- [ ] Todo open                       ← 체크 안 함
> A quoted line.                  ← Block quote (⌘')
```
let a = 1                         ← Monospaced (⇧⌘M), 두 줄 연속
let b = 2
```
| 글자1 | 글자*2* |
| --- | --- |
| **글자3** | <u>글자4</u> |
← 표 (⌥⌘T), #21용