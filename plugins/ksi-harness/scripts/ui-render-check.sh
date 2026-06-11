#!/usr/bin/env bash
# Stop hook: 이 세션에서 프론트엔드 화면 파일(.tsx/.jsx/.vue/.svelte)을 '직접' 수정했는데
# '완료'하려 할 때, 렌더를 실제로 봤는지 1회 넛지한다(시각 검증 게이트의 프론트 대응물).
# - 백엔드 ruff 훅과 짝: 백엔드=자동 lint, 프론트=시각 확인 넛지.
# - 핵심: 막는 조건 = '이 세션 transcript의 Edit/Write/MultiEdit' ∩ 'git 미커밋 프론트 변경'.
#   ① transcript: 메인 루프 직접 편집 + 이 세션의 서브에이전트/workflow 편집(2026-06-11 확장).
#      서브에이전트 편집은 메인 transcript에 안 잡히므로(isSidechain 0개), 세션 사이드카
#      <transcript_path 확장자 제거>/subagents/**/agent-*.jsonl 를 직접 스캔한다 — fan-out으로
#      .tsx를 고치는 핵심 운영경로(workflow 기본)에서 영영 침묵하던 구조적 거짓음성을 봉합.
#   ② git 교차(2026-06 추가): git diff HEAD + untracked 에 실제 미커밋인 파일만 막는다 —
#      이미 커밋한 과거 화면은 제외. 구버전은 transcript만 봐서, 긴 세션에서 커밋 끝난 화면이
#      이후 모든 Stop마다 영구 오발했다(아래 ③ compaction 보정만으론 '요약 후 편집했지만
#      이미 커밋한' 경우를 못 거른다 — git 교차가 그 구멍을 메운다).
#   구버전이 봤던 git status(작업트리 전체)의 거짓양성(안 만진 화면 오발)도 함께 회피한다.
# - 컨텍스트 요약(compaction) 보정(2026-06 추가): transcript jsonl은 compaction 후에도
#   같은 파일에 누적된다(이전 세션 기록이 그대로 남음). 따라서 '마지막 compaction 경계
#   (isCompactSummary 또는 compactMetadata 레코드) 이후'의 편집만 본다. 이게 없으면
#   요약으로 이어진 세션에서 이전 세션의 tsx 편집까지 잡혀 매 턴 오발한다(거짓양성).
# - 루프 방지: stop_hook_active면 통과. transcript 없음/파싱 오류면 graceful 통과(세션 안 깸).
set -uo pipefail

input="$(cat)"

python3 - "$input" <<'PY' 2>/dev/null || exit 0
import sys, json, os

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

# 이미 이 훅이 띄운 continuation이면 더 막지 않는다(무한루프 방지)
if d.get("stop_hook_active"):
    sys.exit(0)

tp = d.get("transcript_path") or ""
if not tp or not os.path.exists(tp):
    sys.exit(0)

EXTS = (".tsx", ".jsx", ".vue", ".svelte", ".css", ".scss")
EDIT_TOOLS = {"Edit", "Write", "MultiEdit"}
changed = set()

# 1) 전체 레코드를 먼저 읽는다(compaction 경계를 알아야 그 이후만 보기 때문).
try:
    records = []
    with open(tp, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except Exception:
                records.append(None)  # 자리 보존(인덱스 유지)
except Exception:
    sys.exit(0)

# 2) 마지막 compaction 경계를 찾는다. compaction 후 transcript는 같은 파일에 누적되므로,
#    그 경계 이후만 봐야 '이번(요약 이후) 세션'의 편집이다.
#    경계 마커: isCompactSummary == True 인 레코드, 또는 compactMetadata 키를 가진 레코드.
start = 0
for i, rec in enumerate(records):
    if not isinstance(rec, dict):
        continue
    if rec.get("isCompactSummary") or rec.get("compactMetadata"):
        start = i + 1

# 3) tool_use Edit/Write 블록에서 EXTS 편집 파일 경로를 changed에 모으는 헬퍼.
def _collect(recs):
    for rec in recs:
        if not isinstance(rec, dict):
            continue
        # assistant 메시지의 content 배열에서 tool_use 블록을 찾는다.
        # 포맷 차이를 흡수: rec["message"]["content"] 또는 rec["content"].
        content = None
        m = rec.get("message")
        if isinstance(m, dict):
            content = m.get("content")
        if content is None:
            content = rec.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") != "tool_use":
                continue
            if block.get("name") not in EDIT_TOOLS:
                continue
            inp = block.get("input") or {}
            fp = inp.get("file_path") or ""
            if isinstance(fp, str) and fp.endswith(EXTS):
                changed.add(fp)


# 3a) 경계 이후의 메인 루프 직접 편집.
try:
    _collect(records[start:])
except Exception:
    sys.exit(0)

# 3b) 이 세션의 서브에이전트/workflow 편집도 포함(2026-06-11 추가).
#     메인 transcript엔 서브에이전트 편집이 안 잡히므로(isSidechain 0개), 세션 사이드카
#     디렉토리 <transcript_path 확장자 제거>/subagents/**/agent-*.jsonl 를 직접 스캔한다.
#     이들은 '이 세션' 디렉토리에만 있어 cross-session 거짓양성이 구조적으로 없고,
#     아래 git 미커밋 교차가 이미 커밋된/stale 편집을 추가로 걸러준다(compaction 보정 불필요).
import glob

try:
    if tp.endswith(".jsonl"):
        sub_root = os.path.join(tp[:-6], "subagents")  # ".jsonl"(6자) 제거 = 세션 사이드카
        if os.path.isdir(sub_root):
            for jf in glob.glob(os.path.join(sub_root, "**", "agent-*.jsonl"), recursive=True):
                try:
                    recs = []
                    with open(jf, "r", encoding="utf-8") as sf:
                        for line in sf:
                            line = line.strip()
                            if not line:
                                continue
                            try:
                                recs.append(json.loads(line))
                            except Exception:
                                pass
                    _collect(recs)
                except Exception:
                    continue
except Exception:
    pass

if not changed:
    sys.exit(0)

# 4) git 미커밋 프론트 변경과 교차 — 이미 커밋된 편집은 제외(완료 전 '미검증 미커밋'만 막음).
#    git 불가(비-git/오류)면 graceful 통과(오발 방지 우선).
import subprocess

cwd = d.get("cwd") or os.getcwd()


def _git(args):
    try:
        r = subprocess.run(
            ["git", "-C", cwd, *args], capture_output=True, text=True, timeout=5
        )
        return r.stdout.splitlines() if r.returncode == 0 else None
    except Exception:
        return None


diff = _git(["diff", "--name-only", "HEAD"])  # staged+unstaged vs 마지막 커밋
untracked = _git(["ls-files", "--others", "--exclude-standard"])  # 새 파일
root = _git(["rev-parse", "--show-toplevel"])
if diff is None or untracked is None or not root:
    sys.exit(0)
base = root[0]
uncommitted = {
    os.path.normpath(os.path.join(base, rel))
    for rel in (*diff, *untracked)
    if rel.strip()
}
changed = {os.path.normpath(p) for p in changed} & uncommitted

n = len(changed)
if n == 0:
    sys.exit(0)

reason = (
    "이 세션에서 프론트엔드 화면 파일 " + str(n) + "개를 수정했습니다. "
    "\"완료\" 전에 렌더를 실제로 확인하세요: /run 또는 /verify로 앱을 띄워 "
    "desktop + mobile(390px) 스크린샷을 Read로 보세요. "
    "① 시각: 오버플로·한글 텍스트 세로쪼개짐(word-break:keep-all)·빈/희박 상태·터치타겟<44px. "
    "② 동선·사용성: 핵심 산출물까지 도달하나(죽은 메뉴/리다이렉트 없나)·빈/에러 상태 탈출구·"
    "상태 라벨이 영어 raw/코드값이 아니라 사람 말인가. "
    "빈/희박/아주 긴 한글 이름 데이터와 각 역할 콜드스타트(첫 화면)로 보세요 — 풍부한 mock 한 장은 빈 상태 깨짐을 숨깁니다. "
    "전 페이지·역할별 깊은 점검은 /ui-audit. "
    "이미 양쪽 뷰포트 렌더를 눈으로 확인했다면 그 사실을 보고하고 그대로 완료하세요. "
    "타입·e2e 통과는 시각적·사용성 멀쩡함을 보장하지 않습니다."
)
print(json.dumps({"decision": "block", "reason": reason}))
sys.exit(0)
PY
exit 0
