#!/usr/bin/env bash
# PreToolUse(Bash) hook: 파괴적 명령 하드가드 — permissions.deny의 프리픽스 패턴("Bash(rm -rf:*)")이
# 못 막는 변형(rm -fr·/bin/rm·command rm·플래그 분리)과 force-push·인터랙티브 DROP DATABASE를 차단(exit 2).
# 원칙: 표적은 '복구 불가급'만(루트/홈/시스템 최상위/보호 디렉토리) — 스크래치·node_modules류 rm -rf는
#       통과시켜 자율성을 보존한다. 오차단이 의심되면 이 파일의 규칙을 좁혀라(넓히기보다 좁히기 우선).
# 근거: 하네스 감사 — 공식 docs가 Bash 인자 제약 deny를 "fragile"로 명시, PreToolUse가 권고 방어선.
# 자가감사(CONFIRMED) 수정: (a) 세그먼트 분리에 개행 추가 — 다줄 bash의
#   2번째 줄 이후가 첫 명령 인자로 오파싱돼 전혀 검사 안 되던 우회 봉합. (b) rm 판정을 recursive 단독으로
#   완화 — force 없는 `rm -r ~`(홈 삭제)가 통과하던 구멍 봉합(표적 스코프는 여전히 복구불가급만이라 과차단 없음).
#   (c) env/bash-c 래퍼 우회 봉합 — `env X=1 rm -rf ~`·`bash -c 'rm -rf ~'`가 prog=env/bash로 오판정되던 것.
#   (d) git reset --hard·git clean -f 차단 추가(미커밋 변경/미추적 파일 소실 — push --force와 동급 위험).
#   잔여 리스크(폐쇄 불가, 정직히 명시): heredoc/multiline 문자열 리터럴에 파괴 명령이 "데이터"로 들어간 경우
#   개행 분리가 이를 별도 세그먼트로 오차단할 수 있음(저빈도) — 오차단 의심되면 규칙을 좁혀라. $()·eval·
#   base64 등으로 인코딩된 명령은 여전히 미탐지(heuristic 한계, 완전 파싱기가 아님).
set -uo pipefail
. "$(dirname "$0")/ksi-mode.sh" 2>/dev/null || KSI_MODE=strict
# ⚠ 여기서 blanket off-exit 하지 않는다 — rm 루트/홈·push --force·DROP DB 하드가드는 모드 무관 항상 유지.
# 모드는 python으로 넘겨 '되돌리기-가능(reset --hard/clean -f)'만 warn/off에서 경고로 낮춘다(0.8.3).

input="$(cat)"
GUARD_INPUT="$input" KSI_MODE="${KSI_MODE:-strict}" python3 - <<'PY'
import json, os, posixpath, re, shlex, sys

try:
    d = json.loads(os.environ.get("GUARD_INPUT", "") or "{}")
except Exception:
    sys.exit(0)
if d.get("tool_name") != "Bash":
    sys.exit(0)
cmd = (d.get("tool_input") or {}).get("command", "") or ""
if not cmd:
    sys.exit(0)

def block(reason):
    print(f"pre-destructive-guard 차단: {reason}", file=sys.stderr)
    sys.exit(2)


MODE = os.environ.get("KSI_MODE", "strict")


def soft_block(reason):
    # 되돌리기-가능(로컬 미커밋/미추적 손실) 계열 — strict는 차단, warn/off는 경고만 하고 자율 실행 허용(escape, 0.8.3).
    # rm 루트·push --force·DROP DB 같은 되돌리기-불가/외부영향은 이걸 쓰지 않고 항상 block().
    if MODE == "strict":
        block(reason)
    print(f"pre-destructive-guard 경고(KSI_HOOKS={MODE}): {reason}", file=sys.stderr)
    sys.exit(0)

HOME = os.path.expanduser("~")
SEG_SPLIT = re.compile(r"(?<!\\)(?:[;&|]+|[\r\n]+)")
SHELLS = ("bash", "sh", "zsh", "dash")
ENV_OPTS_WITH_ARG = ("-C", "-S", "-u", "--chdir", "--unset")

def check_segments(text, depth=0):
    if depth > 3 or not text:
        return
    for seg in SEG_SPLIT.split(text):
        seg = seg.strip()
        if not seg:
            continue
        check_one(seg, depth)

def check_one(seg, depth):
    # 따옴표 보존 파싱 우선 시도(-c 뒤 인용 문자열 복원용). 실패하면 whitespace split로 폴백(기존 heuristic).
    try:
        qtoks = shlex.split(seg, posix=True)
    except ValueError:
        qtoks = None

    # bash/sh/zsh/dash -c '<inner>' — 래퍼 자체가 어디 있든(env 뒤 등) inner를 재귀 검사.
    if qtoks:
        for i, t in enumerate(qtoks):
            if os.path.basename(t.strip("'\"")) in SHELLS and i + 2 < len(qtoks) and qtoks[i + 1] in ("-c", "--command"):
                check_segments(qtoks[i + 2], depth + 1)
                break
            if os.path.basename(t.strip("'\"")) in SHELLS and i + 1 < len(qtoks) and qtoks[i + 1].startswith("--command="):
                check_segments(qtoks[i + 1].split("=", 1)[1], depth + 1)
                break

    toks = seg.split()
    # 래퍼 스트립: command/nice/nohup/time/xargs/timeout N/stdbuf <opts>/sudo/env <NAME=VAL...|opts>
    i = 0
    while i < len(toks):
        t = toks[i]
        # bare 변수할당 프리픽스(NAME=val cmd) — 셸 표준 구문. env 래퍼는 처리하면서 이걸
        # 누락하면 `FOO=bar rm -rf ~`로 하드가드가 우회된다(자가감사 CONFIRMED, 실측 exit0).
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t):
            i += 1
            continue
        if t in ("command", "nice", "nohup", "time", "xargs", "sudo"):
            i += 1
            continue
        if t == "timeout" and i + 1 < len(toks):
            i += 2
            continue
        if t == "stdbuf":
            i += 1
            while i < len(toks) and toks[i].startswith("-"):
                i += 1
            continue
        if t == "env":
            i += 1
            while i < len(toks):
                nxt = toks[i]
                if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", nxt):
                    i += 1
                    continue
                if nxt in ENV_OPTS_WITH_ARG:
                    i += 2
                    continue
                if nxt.startswith("-"):
                    i += 1
                    continue
                break
            continue
        break
    toks = toks[i:]
    if not toks:
        return
    # 선행 백슬래시(\rm 등 alias 우회 관용구)도 제거 — 안 벗기면 `\rm -rf ~`·`\git push -f`가
    # prog-name 하드블록 전체를 우회한다(자가감사 CONFIRMED, 실측 exit0).
    prog = os.path.basename(toks[0].strip("'\"").lstrip("\\"))
    args = toks[1:]

    if prog == "rm":
        short = "".join(a.lstrip("-") for a in args if a.startswith("-") and not a.startswith("--"))
        longf = [a for a in args if a.startswith("--")]
        recursive = ("r" in short.lower()) or ("--recursive" in longf)
        # force 요구 제거 — force 없는 `rm -r ~`도 홈을 지운다. 표적은 아래처럼 여전히
        # 복구불가급(루트/홈/시스템최상위/보호디렉토리)만이라 정당한 rm -r <scratch/node_modules류>는 통과.
        if recursive:
            for t in (a for a in args if not a.startswith("-")):
                t2 = t.strip("'\"")
                exp = t2.replace("${HOME}", HOME).replace("$HOME", HOME)
                if exp.startswith("~"):
                    exp = HOME + exp[1:]
                # POSIX 셸 명령의 경로라 posixpath로 정규화 — os.path.normpath는 Windows에서 '/'를 '\'로 바꿔
                # `norm == "/"`·`norm.count("/")` 검사가 전부 빗나가 `rm -rf /`가 통과하던 구멍(2026-07-18 자가감사 CONFIRMED).
                norm = posixpath.normpath(exp) if exp else exp
                # 루트: '/' 뿐 아니라 '//'·'///'(posixpath.normpath('//')=='//', POSIX 특례로 보존)도 전부 루트로 취급.
                is_root = norm.startswith("/") and norm.strip("/") == ""
                if is_root or t2 in ("/*", "*", ".", "..") or norm.rstrip("/") == HOME:
                    block(f"rm -r 복구불가급 대상: {t}")
                if norm.startswith("/") and norm.count("/") == 1 and norm not in ("/tmp",):
                    block(f"rm -r 시스템 최상위 디렉토리: {t}")
                if norm in (HOME + "/Desktop", HOME + "/.claude"):
                    block(f"rm -r 보호 디렉토리: {t} (필요 시 사용자가 직접)")

    # push는 -C/--git-dir 등 전역 옵션 뒤에도 올 수 있어 위치 무관 탐색.
    # --force-with-lease와 --force 병용 시 git은 --force가 이기므로 병용도 차단(단독 lease만 통과).
    if prog == "git" and "push" in args:
        pargs = args[args.index("push"):]
        # short-flag 스택(-fu·-uf·-fq 등)도 f 포함이면 force — git은 -fu를 -f -u로 파싱한다. exact 토큰 매칭만으론
        # -fu가 새던 갭(2026-07-18 자가감사 confirmed) 봉합: rm/clean과 동일하게 단일-대시 플래그를 문자단위로 전개.
        pshort = "".join(a.lstrip("-") for a in pargs if a.startswith("-") and not a.startswith("--"))
        if ("f" in pshort) or any(a == "--force" for a in pargs):
            block("git push --force(-f·-fu 등 f 포함) — --force-with-lease를 단독으로 쓰거나 사용자가 직접 실행(대표자 결정 레인)")

    if prog == "git" and "reset" in args:
        rargs = args[args.index("reset"):]
        if "--hard" in rargs:
            soft_block("git reset --hard — 미커밋 변경 소실(로컬·되돌리기 가능). strict면 차단, KSI_HOOKS=warn/off면 경고만")

    if prog == "git" and "clean" in args:
        cargs = args[args.index("clean"):]
        cshort = "".join(a.lstrip("-") for a in cargs if a.startswith("-") and not a.startswith("--"))
        if ("f" in cshort) or ("--force" in cargs):
            soft_block("git clean -f — 미추적 파일 소실(로컬·되돌리기 가능). strict면 차단, KSI_HOOKS=warn/off면 경고만")

    if prog in ("psql", "mysql", "mariadb") or (prog == "supabase" and "db" in args):
        if re.search(r"(?i)\bdrop\s+(database|schema)\b", seg):
            block("인터랙티브 DROP DATABASE/SCHEMA — 마이그레이션 경로로만(대표자 결정 레인)")

check_segments(cmd)
sys.exit(0)
PY
exit $?
