#!/usr/bin/env bash
# Stop hook: 이 세션에서 백엔드 상태전이/테스트 코드(.py 중 tests·alembic·migrations·services·main)를
# '직접' 수정했는데 '완료'하려 할 때, 'green ≠ 작동'을 1회 넛지한다(시각 검증 게이트의 백엔드 대응물).
# - 프론트 ui-render-check.sh의 짝: 프론트=시각 확인 넛지, 백엔드=동작 검증 넛지.
#   ruff 훅은 .py 저장마다 '정적 lint'만 자동 주입한다 — 픽스처가 종단상태를 직접 주입해 실제 flow를
#   우회하는 가짜 green, SQLite-테스트/PG-프로덕션 dialect 분기는 ruff로 안 잡힌다. 그 공백을 완료 전 넛지.
# - 방어 골격은 ui-render-check.sh를 통째로 재사용(거짓양성·무한루프 정교 차단):
#   ① transcript: 메인 루프 직접 편집 + 이 세션의 서브에이전트/workflow 편집(사이드카 스캔).
#   ② git 교차: git diff HEAD + untracked 의 실제 미커밋 파일만 — 이미 커밋한 과거는 제외.
#   ③ compaction 경계 이후 편집만(요약 후 이전 세션 기록 오발 방지).
#   ④ 발화 조건 추가 협소화: 미커밋 .py 중 'tests/·test_*·alembic/·migrations/·services/·main.py'만.
#      순수 util·스키마·설정만 고친 세션엔 침묵(과발화 방지 — .py는 .tsx보다 변경 빈도가 훨씬 높다).
# - 루프 방지: stop_hook_active면 통과. transcript 없음/파싱 오류/비-git면 graceful 통과(세션 안 깸).
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

EXTS = (".py",)
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
                records.append(None)
except Exception:
    sys.exit(0)

# 2) 마지막 compaction 경계 이후만 본다.
start = 0
for i, rec in enumerate(records):
    if not isinstance(rec, dict):
        continue
    if rec.get("isCompactSummary") or rec.get("compactMetadata"):
        start = i + 1


# 3) tool_use Edit/Write 블록에서 .py 편집 파일 경로를 changed에 모으는 헬퍼.
def _collect(recs):
    for rec in recs:
        if not isinstance(rec, dict):
            continue
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

# 3b) 이 세션의 서브에이전트/workflow 편집도 포함(사이드카 스캔).
import glob

try:
    if tp.endswith(".jsonl"):
        sub_root = os.path.join(tp[:-6], "subagents")
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

# 4) git 미커밋 .py 변경과 교차 — 이미 커밋된 편집은 제외.
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


diff = _git(["diff", "--name-only", "HEAD"])
untracked = _git(["ls-files", "--others", "--exclude-standard"])
root = _git(["rev-parse", "--show-toplevel"])
if diff is None or untracked is None or not root:
    sys.exit(0)
base = root[0]
# normcase: Windows NTFS는 대소문자 무시라 git toplevel과 tool_use 경로의 케이스가 갈리면
# 교차가 공집합이 되는 거짓음성 발생 — normcase로 케이스폴드(POSIX에선 no-op).
uncommitted = {
    os.path.normcase(os.path.normpath(os.path.join(base, rel)))
    for rel in (*diff, *untracked)
    if rel.strip()
}
changed = {os.path.normcase(os.path.normpath(p)) for p in changed} & uncommitted

if not changed:
    sys.exit(0)

# 4b) 발화 조건 협소화 — 상태전이/테스트 경로만(순수 util·스키마·설정엔 침묵).
def _is_interesting(p):
    norm = p.replace("\\", "/")
    base_name = os.path.basename(norm)
    if base_name.startswith("test_") or base_name.endswith("_test.py"):
        return True
    for seg in ("/tests/", "/alembic/", "/migrations/", "/services/", "/crud/", "/repositories/"):
        if seg in norm:
            return True
    if base_name in ("main.py", "conftest.py", "models.py", "crud.py", "service.py"):
        return True
    return False


interesting = {p for p in changed if _is_interesting(p)}
n = len(interesting)
if n == 0:
    sys.exit(0)

reason = (
    "이 세션에서 백엔드 상태전이/테스트 파일 " + str(n) + "개를 수정했습니다(tests·migrations·services 등). "
    "\"완료\" 전에 'green ≠ 작동'을 점검하세요(ruff lint 통과는 동작 검증이 아닙니다): "
    "① 캐시 클린 후 재실행으로 green을 재현했나(예: pytest -p no:cacheprovider 또는 .pytest_cache·.mypy_cache 제거 후) — "
    "incremental 캐시가 중간 상태로 가짜 green을 낼 수 있습니다. "
    "② 핵심 사용자 여정을 미리 완료 처리된 픽스처가 아니라 실제 상태 전이(생성→…→완료→결과물)로 적어도 한 번 통과시켰나 — "
    "시드가 완료 플래그·집계값을 직접 주입하면 깨진 완료 경로도 green이 됩니다. "
    "③ SQLite로 테스트하고 프로덕션이 다른 DB(PG 등)면 dialect 분기(INTERVAL·now()·JSON 등)가 프로덕션에서도 도나. "
    "이미 위를 확인했다면 그 사실을 보고하고 그대로 완료하세요. 깊은 점검은 /codebase-audit의 '핵심 여정 실행성' 렌즈로. "
    "ruff/타입 통과는 동작 정확성을 보장하지 않습니다."
)
print(json.dumps({"decision": "block", "reason": reason}))
sys.exit(0)
PY
exit 0
