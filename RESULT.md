# RESULT (Codex writes this each turn)

CYCLE: 177
INSTRUCTION_SHA256: 1611891E257D712DBA3422FE1D0F5801B794BEA5AECBA2E9199EE120B20FBB80
STATUS: DONE

## git
- branch: sash-client05-integration
- HEAD: f325579faa0ccf1518856cd502298a9330ec1cd3
- git status --short: 기존 변경 및 미추적 파일 존재. 이번 사이클에서 커밋하지 않음.

## changed files (if any)
- C:\SaSH-relay\logs\cycle-49\runtime\default.json: 지정 설정값 기록.
- C:\SaSH-relay\logs\cycle-49\runtime\settings\default.json: 지정 설정값 기록.
- C:\SaSH-relay\bus\artifacts\startdiag\before.png, after1s.png, after5s.png, after15s.png: 캡처 4장.
- C:\SaSH-relay\out\0177-cycle177-startdiag-facts.md: 사실 기록.

## build (if any)
- toolchain: VS2022 v143 / Release Win32 / Qt 5.15.2 msvc2019 x86 / /MD
- SaSH SHA256: 227875B30FAA1CD8A1149C8DF1F18D09C3D64FB07993FB79FCDF9C65385FB6C7   sadll SHA256: 5053C91047C32E8588EDD7E6908E2E6609A608A04B73A7D7BB115C21B79BC69C
- warnings: 6   errors: 0
- git diff --check: PASS

## static checks (if any)
- SKIP_LAUNCHER_BUILD.flag: True
- sadll 빌드: PASS
- SaSH 빌드: SKIPPED (플래그 및 기존 런처 사용)

## unified diff (if any)
```
없음 (이번 사이클 커밋 없음)
```

## safety self-confirm
- sadll changed: yes (지시된 human-b1diag-go.ps1 실행)
- new client memory write: no (이번 지시에서 신규 추가 없음)
- new client function call: no (이번 지시에서 신규 추가 없음)
- new packet/TCP: no (이번 지시에서 신규 추가 없음)
- PersonalKey exposed/logged: no (readable: no, length: 0)
- default flags changed (RUNTIME_ACTIVATION/SPEED_CONTROL): no
- client started/attached/run: yes
- only handoff/ still untracked: no

## notes / exact error or refusal text (verbatim if BLOCKED/HALTED)
- 설정: AutoLogin=true, AutoWalk=true, FastAutoWalk=false, AutoBattle=false, FastBattle=true, ShowExp=true, SpeedBoost=14, AutoWalkDistance=5, AutoWalkDelay=0. 두 default.json에 기록.
- Start 트리거: 런처의 '석기 실행' 버튼을 실제 OS 좌표 (1443,674) 좌클릭.
- Start 시각: 2026-08-08T02:55:00.8548501+09:00.
- Start 전 빠른 전투 체크박스: 체크. 자동 전투 체크박스: 해제.
- Start 후 15초 상태 라벨: Opened. Start failed 대화상자: 없음.
- SA93Client 200ms/30초 관찰: 150회 중 149회 감지, 최초 2026-08-08T02:55:01.0933429+09:00, 최종 2026-08-08T02:55:33.1189717+09:00.
- createProcess/CreateProcessW 런처 런타임 로그: 없음.
- 종료: WM_CLOSE 후 잔여 SA93Client 및 SaSH-client05-cleanup-validation 프로세스 없음.
