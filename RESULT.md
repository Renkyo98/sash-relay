# RESULT

CYCLE: 158
INSTRUCTION_SHA256: 88424A849ED3C80CA09D659905D2AD4B25A75794E327563060D109CE2F576AA6
STATUS: DONE

## build

- sadll SHA256: 62E1C4EBA32BB8C48C76E4674EFE45E527A43F3F03CC5F3DBFF2EB9EA345A9C7
- SaSH: SKIPPED (`SKIP_LAUNCHER_BUILD.flag` + existing launcher reuse).
- 결과: sadll OK, build 오류 0.

## runtime facts

- 사전 표식: `FastEncFix2`=1, `((int)fs, 0, 0, feDir)`=1, 이전 `(cx, cy)` 전송=0, `FoundationAShadow`=2, `FreeRandomWalk`=0, SKIP flag=true.
- 양쪽 default.json 읽기값: FastAutoWalkEnable=true, AutoWalkDelayValue=0. 지정 전체값: AutoLogin=true, AutoWalk=false, FastAutoWalk=true, AutoBattle=true, FastBattle=false, ShowExp=true, SpeedBoostValue=14.
- Start 1회 실행 후 약 60초 무입력 관찰.
- fastautowalk 위치: 전체 50개 — X=0..277 (span 277), Y=0..545 (span 545). 마지막 30개 — X=262..273 (span 11), Y=545..545 (span 0).
- autobattle: `battling=1`=0, CHAR=0, PET=0, `comparableTurns`=0.
- FoundationA assert stdout: PASS; comparableTurns=735, matched=730, mismatched=5, matchRate=0.9932.
- 규칙상 판정: `(0,0) NO ENCOUNTERS` (`battling=0` 및 autobattle `comparableTurns=0`). 마지막 30 위치 X span=11, Y span=0.
- 스크린샷: `bus/artifacts/fastenc-00/observe-30s.png`, `bus/artifacts/fastenc-00/observe-60s.png`.
- 수집 로그: `out/` 및 `bus/artifacts/fastenc-00/`에 `fastautowalk-diag-151.log`, `foundationa-shadow.log`, `autobattle-diag.log` 복사. `D:\SA\zmffk` 경로는 없음.

## safety self-confirm

- PersonalKey: readable=no, length=0; 값 미기록.
- client started/attached/run: yes; Start 1회.
- crash check: 종료 전 SA93Client PID 1464 실행 확인.
- teardown: launcher WM_CLOSE, 이 실행의 client PID 1464 종료, launcher 및 SA93Client 프로세스 부재, 모달 0 확인.
- commit: 없음.
