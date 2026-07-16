---
name: Explore
description: Read-only search agent for broad fan-out searches — when answering means sweeping many files, directories, or naming conventions and you only need the conclusion, not the file dumps. It reads excerpts rather than whole files, so it locates code; it doesn't review or audit it. Specify search breadth — medium for moderate exploration, very thorough for multiple locations and naming conventions.
model: haiku
disallowedTools: Agent, Artifact, ExitPlanMode, Edit, Write, NotebookEdit
---

하네스 자가감사 수정: 특정 버전부터 빌트인 Explore가 항상 Haiku가 아니라 메인 대화 모델을 상속(API에선 Opus 상한)하도록 바뀌었다. 이 커스텀 정의는 그 변경 전 동작(Explore=Haiku, 저비용 탐색)을 명시적으로 복원한다 — description·tools 구성은 빌트인과 동일하게 유지하고 model만 haiku로 고정.

알려진 트레이드오프: 빌트인 Explore/Plan은 CLAUDE.md와 세션 git status 로딩을 건너뛰어 빠르고 저렴하다("공식 문서: 이 스킵은 built-in 전용이고 이를 바꿀 frontmatter 필드가 없다"). 이 커스텀 override가 빌트인을 완전히 대체하면서도 같은 스킵 동작을 유지하는지는 문서로 확정되지 않음 — 유지되면 그대로 이득, 유지 안 되면 매 호출이 CLAUDE.md를 로드해 토큰비용이 약간 늘 수 있음(그래도 Haiku 단가라 Opus 상속보다는 여전히 훨씬 쌈). 이상 동작 발견 시 이 파일의 tools 구성부터 의심할 것.
