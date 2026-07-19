#!/usr/bin/env bash
# PreToolUse(Bash) hook: outbound exfiltration 넛지 — pre-destructive-guard.sh가 '삭제·되돌리기 불가'만 보고
# secret/env/파일을 외부로 유출하는 패턴은 안 본다는 갭을 메운다. CLAUDE.md '## 신뢰 경계' 절의 실제 개입 지점.
# **경고형이지 하드블록이 아니다** — curl/wget 데이터 전송 자체는 정당한 배포·API 호출에서도 흔해 exit 2로
# 막으면 자율성을 훼손한다. 탐지 시 stderr 경고 1줄 + exit 0(항상). 판단은 여전히 모델·사용자 몫.
# 탐지 대상:
#   (1) curl/wget에 데이터 전송 플래그(-d/--data*/-F/--form/-T/--upload-file/wget --post-data 등)가 있고
#       동일 세그먼트에 민감 신호($…KEY/SECRET/TOKEN/PASSWORD/CREDENTIAL, .env, ~/.claude, ~/.ssh, id_rsa,
#       .aws/credentials, printenv, env |)가 함께 보이는 경우.
#   (2) curl/wget 결과를 셸 인터프리터로 파이프하는 RCE 패턴(curl ... | bash 등).
#   (3) env/printenv(환경변수 전체 덤프)를 curl/wget/nc로 파이프하는 경우.
# 오탐 억제: localhost/127.0.0.1/0.0.0.0 대상은 로컬 개발이라 제외. 데이터 전송 플래그가 아예 없는 단순
# GET·순수 다운로드(-O/-o)는 애초에 (1)에 안 걸린다. 세그먼트 분리·래퍼 스트립(env/bash-c 재귀)은
# pre-destructive-guard.sh와 동일 heuristic을 재사용 — 완전 셸 파서가 아니라 휴리스틱임을 인지(폐쇄 불가).
set -uo pipefail

input="$(cat)"
GUARD_INPUT="$input" python3 - <<'PY'
import json, os, re, shlex, sys

def main():
    try:
        d = json.loads(os.environ.get("GUARD_INPUT", "") or "{}")
    except Exception:
        return
    if d.get("tool_name") != "Bash":
        return
    cmd = (d.get("tool_input") or {}).get("command", "") or ""
    if not cmd:
        return

    warnings = []

    def warn(reason):
        warnings.append(reason)

    ENV_OPTS_WITH_ARG = ("-C", "-S", "-u", "--chdir", "--unset")
    SHELLS = ("bash", "sh", "zsh", "dash")
    INTERPRETERS = ("bash", "sh", "zsh", "dash", "python", "python3", "perl", "ruby", "node", "nodejs")
    NET_TOOLS_FOR_ENV = ("curl", "wget", "nc", "ncat", "netcat")

    SHORT_DATA_FLAGS = {"-d", "-F", "-T"}
    LONG_DATA_FLAGS = {
        "--data", "--data-ascii", "--data-binary", "--data-raw", "--data-urlencode",
        "--form", "--upload-file", "--post-data", "--post-file",
    }

    SENSITIVE_RE = re.compile(
        r"\$\{?[A-Z_]*(?:KEY|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL)[A-Z_]*\}?"
        r"|\.env(?:\.[A-Za-z0-9_.-]+)?\b"
        r"|~/\.claude\b"
        r"|~/\.ssh\b"
        r"|id_rsa\b"
        r"|\.aws/credentials\b"
        r"|\bprintenv\b"
        r"|\benv\s*\|"
    )

    STMT_SPLIT = re.compile(r"(?<!\\)(?:&&|\|\||;|[\r\n]+)")
    PIPE_SPLIT = re.compile(r"(?<!\|)\|(?!\|)")

    def is_localhost(text):
        return bool(re.search(r"https?://(localhost|127\.0\.0\.1|0\.0\.0\.0)(?::\d+)?(?:[/\s]|$)", text))

    def has_data_exfil_flag(args):
        for a in args:
            a = a.strip("'\"")
            if a in SHORT_DATA_FLAGS:
                return True
            if a.startswith("--"):
                base = a.split("=", 1)[0]
                if base in LONG_DATA_FLAGS:
                    return True
            elif len(a) > 2 and a[:2] in SHORT_DATA_FLAGS:
                # -d@.env, -Ffile=..., -T./file 처럼 값이 붙은 형태
                return True
        return False

    def wrapper_strip(toks):
        # command/nice/nohup/time/xargs/sudo/timeout N/stdbuf <opts>/env <NAME=VAL...|opts> 스트립.
        # bare `env`(뒤에 실제 커맨드가 없는 경우)는 env 자체를 prog로 반환(환경변수 전체 덤프로 취급).
        i = 0
        while i < len(toks):
            t = toks[i]
            # bare 변수할당 프리픽스(NAME=val cmd) — pre-destructive-guard와 대칭 봉합.
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
                j = i + 1
                while j < len(toks):
                    nxt = toks[j]
                    if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", nxt):
                        j += 1
                        continue
                    if nxt in ENV_OPTS_WITH_ARG:
                        j += 2
                        continue
                    if nxt.startswith("-"):
                        j += 1
                        continue
                    break
                if j < len(toks):
                    i = j
                    continue
                return "env", [], toks[i:i + 1]
            break
        rest = toks[i:]
        if not rest:
            return None, [], []
        # 선행 백슬래시(\git 등 alias 우회)도 제거 — pre-destructive-guard와 대칭 봉합.
        prog = os.path.basename(rest[0].strip("'\"").lstrip("\\"))
        return prog, rest[1:], rest

    def check_data_exfil(seg_text, prog, args):
        if not has_data_exfil_flag(args):
            return
        if is_localhost(seg_text):
            return
        if SENSITIVE_RE.search(seg_text):
            warn(
                f"{prog} 요청에 데이터 전송 플래그와 민감정보 의심 참조가 함께 있습니다: "
                f"{seg_text.strip()[:200]}"
            )

    def analyze(text, depth=0):
        if depth > 3 or not text:
            return
        for stmt in STMT_SPLIT.split(text):
            stmt = stmt.strip()
            if not stmt:
                continue
            stage_texts = [s.strip() for s in PIPE_SPLIT.split(stmt) if s.strip()]
            stages = []
            for st in stage_texts:
                toks = st.split()
                try:
                    qtoks = shlex.split(st, posix=True)
                except ValueError:
                    qtoks = None
                prog, args, _rest = wrapper_strip(toks)
                stages.append((st, prog, args, qtoks))

            for st, prog, args, qtoks in stages:
                # bash/sh -c '<inner>' 재귀 검사(래퍼가 env 뒤 등 어디에 있든).
                if qtoks:
                    for i2, t2 in enumerate(qtoks):
                        base = os.path.basename(t2.strip("'\""))
                        if base in SHELLS and i2 + 2 < len(qtoks) and qtoks[i2 + 1] in ("-c", "--command"):
                            analyze(qtoks[i2 + 2], depth + 1)
                            break
                        if base in SHELLS and i2 + 1 < len(qtoks) and qtoks[i2 + 1].startswith("--command="):
                            analyze(qtoks[i2 + 1].split("=", 1)[1], depth + 1)
                            break
                if prog in ("curl", "wget"):
                    check_data_exfil(st, prog, args)

            for i2 in range(len(stages) - 1):
                _, progA, _argsA, _ = stages[i2]
                _, progB, _argsB, _ = stages[i2 + 1]
                if progA in ("curl", "wget") and progB in INTERPRETERS:
                    warn(
                        f"원격 코드 실행 패턴: {progA} 결과를 {progB}로 파이프 — "
                        "신뢰 안 된 원격 스크립트를 검토 없이 실행합니다."
                    )
                if progA in ("env", "printenv") and progB in NET_TOOLS_FOR_ENV:
                    warn(
                        f"환경변수 전체({progA})를 {progB}로 파이프 — 시크릿이 통째로 유출될 수 있습니다."
                    )

    analyze(cmd)

    for w in warnings:
        print(f"exfil-guard 경고: {w}", file=sys.stderr)

    # === git push 시크릿 하드게이트 (nextgen 2순위) ===
    # secret-scan(PostToolUse)은 경고만·Edit/Write만 봐서 (a) 디스크에 이미 있던 .env가 git add되면 안 봄
    # (b) push로 나가는 걸 못 막음. 커밋된 .env가 push 이력에 잔존하는 사고가 실제로 일어난다. push=exfiltration이라
    # 여기(egress guard)에 흡수: git push가 .env/시크릿을 담고 있으면 warn이 아니라 **차단(exit 2)**.
    # nudge 실패의 정확한 처방 = 하드게이트. (bypassPermissions 상시라 유일 방어선.)
    import re as _re2
    import subprocess as _sp
    push_seg = None
    for _seg in STMT_SPLIT.split(cmd):
        _t = _seg.split()
        if _t and os.path.basename(_t[0].strip("'\"")) == "git" and "push" in _t:
            push_seg = _seg
            break
    if push_seg is not None:
        # repo dir: 명령 내 `cd <path>` 우선, 없으면 훅 cwd, 없으면 현재.
        repo = d.get("cwd") or os.getcwd()
        _m = _re2.search(r"(?:^|[;&|]|\bcd)\s+(/[^\s;&|]+|~[^\s;&|]*|\.[^\s;&|]*)", cmd)
        if _m:
            cand = os.path.expanduser(_m.group(1))
            if os.path.isdir(cand):
                repo = cand

        def _git(args, timeout=6):
            try:
                r = _sp.run(["git", "-C", repo, *args], capture_output=True, text=True, timeout=timeout)
                return r.stdout if r.returncode == 0 else ""
            except Exception:
                return ""

        ENVRE = _re2.compile(r"(^|/)\.env(\.[A-Za-z0-9_.-]+)?$")
        ALLOW = _re2.compile(r"\.(example|sample|template|dist)$|\.env\.example")
        # tracked + staged 파일에서 .env 계열 탐지(.example류 제외).
        files = set()
        for ln in (_git(["ls-files"]) + "\n" + _git(["diff", "--cached", "--name-only"])).splitlines():
            ln = ln.strip()
            if ln and ENVRE.search(ln) and not ALLOW.search(ln):
                files.add(ln)
        # staged 내용의 고신뢰 시크릿 패턴(값 출력 안 함 — 존재만).
        SECRET = _re2.compile(r"AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{36}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.")
        staged = _git(["diff", "--cached"])
        secret_hit = bool(SECRET.search(staged))
        if files or secret_hit:
            why = []
            if files:
                why.append(".env 계열 " + str(len(files)) + "개 tracked/staged(" + ", ".join(sorted(files)[:3]) + ")")
            if secret_hit:
                why.append("staged diff에 고신뢰 시크릿 패턴")
            print(
                "exfil-guard 차단: git push가 시크릿을 담고 있습니다 — " + " · ".join(why) + ". "
                "push하면 원격 이력에 영구 잔존합니다(커밋된 .env가 push 이력에 남는 사고 전례). "
                "`echo '.env' >> .gitignore && git rm --cached <파일>` 후 재시도하거나, 의도된 것이면 사용자가 직접 push하세요.",
                file=sys.stderr,
            )
            sys.exit(2)

try:
    main()
except SystemExit:
    raise
except Exception:
    pass
sys.exit(0)
PY
exit $?
