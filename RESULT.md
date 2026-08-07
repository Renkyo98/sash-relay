# RESULT (Codex writes this each turn)

CYCLE: 156
INSTRUCTION_SHA256: 7369CEF72EF0CDE654187C3B588062C890E677CDD5CCF391FFC71072BD2C9CA7
STATUS: DONE

## git

- branch: sash-client05-integration
- HEAD: f325579faa0ccf1518856cd502298a9330ec1cd3
- git status --short: 실행 전부터/빌드 스크립트 실행 후 변경·미추적 항목이 존재함. 커밋 없음.

## changed files (if any)

- 런타임 설정: `logs/cycle-49/runtime/default.json`, `logs/cycle-49/runtime/settings/default.json` — FastAutoWalkEnable=true, AutoBattleEnable=true 포함 지시값 반영.
- 보고: `RESULT.md`, `out/0156-cycle156-fastenc-fix-facts.md`.
- commit hash: 없음.

## build (if any)

- toolchain: VS2022 v143 / Release Win32 / Qt 5.15.2 msvc2019 x86 / /MD
- sadll SHA256: AF91C4828663F8C52A31447CE12E99C3CF0B4AF0CB22DF7FB5CB42B6E1B27598
- warnings: 빌드 표준출력에 경고 수 미보고
- errors: 0 (sadll OK, SaSH OK)
- git diff --check: PASS (줄끝 경고 출력 있음)

## static checks (if any)

- 사전 표식: PASS (`FastEncFix`=1, `FoundationAShadow`=2, `toward origin`=0, `*noDrawMax = `=2, `FreeRandomWalk`=0)
- FoundationA assert: PASS; comparableTurns=414, matched=414, mismatched=0, matchRate=1

## safety self-confirm

- sadll changed: yes (지시된 빌드·배포)
- new client memory write: no (이번 실행에서 신규 작성 없음)
- new client function call: no (이번 실행에서 신규 작성 없음)
- new packet/TCP: no (이번 실행에서 신규 작성 없음)
- PersonalKey exposed/logged: no (값 미접근·미기록; readable=no, length=0)
- default flags changed (RUNTIME_ACTIVATION/SPEED_CONTROL): no
- client started/attached/run: yes; Start 1회, 약 150초 무인 실행
- only handoff/ still untracked: yes; 커밋 없음

## notes / exact error or refusal text (verbatim if BLOCKED/HALTED)

- 두 default.json 읽기값: FastAutoWalkEnable=True, AutoBattleEnable=True.
- fastautowalk: `ENABLED ... (pure in-place gcgc, no origin)` 기록; 최대 sent cnt=1447. autobattle 최대 tick cnt=1677, 기록된 battling=1.
- pos-diag X/Y 표본은 0건이라 X/Y span은 산출 불가. 따라서 빠른조우 FIX 판정은 FAIL(필수 no-drift span 조건 미충족).
- 스크린샷 3개: `bus/artifacts/fastenc-fix/fastenc-1.png`, `fastenc-2.png`, `fastenc-3.png`.
- 종료: launcher WM_CLOSE 후 이 실행의 client PID 종료; 두 프로세스 부재 확인. 실행 중 두 프로세스는 Responding=True였음.
