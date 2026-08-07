# RESULT (Codex writes this each turn)

CYCLE: 147
INSTRUCTION_SHA256: 929086F8C022AC2EEB7DC74C224D076ADEBED2359AE87123794F002088377AF3
STATUS: DONE

## git

- branch: sash-client05-integration
- HEAD: f325579faa0ccf1518856cd502298a9330ec1cd3
- git status --short: pre-existing/user worktree changes plus the build script's temporary source instrumentation changes; no commit created.

## changed files (if any)

- Launcher config: C:\SaSH-relay\logs\cycle-49\runtime\settings\default.json (AutoLoginEnable=true, AutoWalkEnable=true, FastAutoWalkEnable=false, AutoBattleEnable=true, SpeedBoostValue=14)
- Runtime artifacts: C:\SaSH-relay\bus\artifacts\boost-fix\shot-01.png through shot-06.png; C:\SaSH-relay\out\boost-diag-140.log
- Commit: none.

## build (if any)

- toolchain: VS2022 v143 / Release Win32 / Qt 5.15.2 msvc2019 x86 / /MD
- SaSH SHA256: 2DF05F4C145A785F5D10CF775FEB95509A06DF2A45DB4EE5E36BB991C1056BD6
- sadll SHA256: 5CBCFC8668C63CF14E453BBCDB0AC3458D29EC15B66A05E32B76D006C14DC807
- warnings: 3   errors: 0
- git diff --check: PASS

## static checks (if any)

- fixed-script length=228339: PASS
- [F0 boost fix] marker count=1: PASS
- *noDrawMax = assignments=0: PASS
- BOOST147_ASSERT: PASS
- NOBLACK147_ASSERT: PASS

## runtime facts

- Deployed sadll SHA-256: 5CBCFC8668C63CF14E453BBCDB0AC3458D29EC15B66A05E32B76D006C14DC807
- Exact level-14 boost line: `boost level=14 sysTime 14->1 noDrawMax 2->2 orig(14,2) base=00400000`
- BOOST147 stdout:
```
BOOST147_ASSERT: log=C:\zmffk\boost-diag-140.log mtimeUtc=2026-08-07T01:30:31.0927808Z
--- boost-diag lines ---
boost level=14 sysTime 14->1 noDrawMax 2->2 orig(14,2) base=00400000
--- end lines ---
BOOST147_ASSERT: PASS
EVIDENCE: boost level=14 sysTime 14->1 noDrawMax 2->2 orig(14,2) base=00400000
CONFIRMED: at SpeedBoost=14, NO_DRAW_MAX_CNT is NOT written (before==after) and sysTime driven to 1. Black-screen driver removed; speed applied via frame timer only.
```
- NOBLACK147 stdout:
```
--- per-frame brightness ---
frame=shot-01.png blackRatio=0.0438 meanLum=177.09
frame=shot-02.png blackRatio=0.0438 meanLum=177.12
frame=shot-03.png blackRatio=0.0442 meanLum=177.06
frame=shot-04.png blackRatio=0.0438 meanLum=177.13
frame=shot-05.png blackRatio=0.0438 meanLum=177.03
frame=shot-06.png blackRatio=0.0442 meanLum=177.06
--- end frames ---
frames analyzed: 6
NOBLACK147_ASSERT: PASS
EVIDENCE: no black frame; darkest frame shot-05.png meanLum=177.03 blackRatio=0.0438
```
- Screenshots: C:\SaSH-relay\bus\artifacts\boost-fix\shot-01.png through shot-06.png.
- Darkest frame: shot-05.png, meanLum=177.03, blackRatio=0.0438.
- Crash/modal check: no target crash/info modal remained after launcher WM_CLOSE; target processes absent.
- Overall: PASS.

## safety self-confirm

- sadll changed: yes (build/deploy only; no commit)
- new client memory write: yes (authorized feature-under-test SystemTime DWORD only)
- new client function call: no
- new packet/TCP: no originated packet beyond owner-authorized built-in auto-login/auto-walk/auto-battle features
- PersonalKey exposed/logged: no (readable=no; length not read)
- default flags changed (RUNTIME_ACTIVATION/SPEED_CONTROL): no
- client started/attached/run: yes; exactly one Start invocation, owned cycle client only
- only handoff/ still untracked: yes; no commit

## notes / exact error or refusal text (verbatim if BLOCKED/HALTED)

Build run directory: C:\SaSH-relay\logs\human-ctrlinit\run-140. Teardown: launcher WM_CLOSE posted; its job cleanup removed the cycle client; both target processes confirmed absent.
