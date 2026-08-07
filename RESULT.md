# RESULT

CYCLE: 154
INSTRUCTION_SHA256: E4A41ABF546F2BE7AF858B462D681D244C067E6C8542C877D1CB226EAEBBA308
STATUS: DONE

## git

- branch: sash-client05-integration
- HEAD: f325579faa0ccf1518856cd502298a9330ec1cd3
- git status --short: 소스 변경 및 기존 미추적 파일이 존재함(사이클 중 커밋 없음).

## changed files (if any)

- 소스 파일을 직접 편집하지 않음. 지정된 빌드/배포 스크립트가 clean-HEAD 스냅샷에서 배포물을 생성함.
- commit hash if committed: 없음

## build

- 지정 스크립트: 성공 (sadll OK, SaSH OK)
- deployed sadll SHA256: CFD0F50B8092048215381387E57BCD53889F1957B1E6651129B3B3845843BE58
- warnings: 미집계
- errors: 0

## config readback

- runtime/default.json: AutoBattleEnable=True, FastBattleEnable=False, AutoWalkEnable=True
- runtime/settings/default.json: AutoBattleEnable=True, FastBattleEnable=False, AutoWalkEnable=True

## FOUNDATIONA_ASSERT stdout (verbatim)

```
FOUNDATIONA_ASSERT: log=C:\zmffk\foundationa-shadow.log mtimeUtc=2026-08-07T08:35:00.0764936Z
FOUNDATIONA_ASSERT: comparableTurns=8 matched=5 mismatched=3
FOUNDATIONA_ASSERT: matchRate=0.625
--- mismatch samples (wire != scene) ---
SHADOW turn=0 wAnim=18000 sAnim=18000 myNo=0 wMyPos=0 wMp=76 | p10(wh-1 sh0 wm-1 sm0)! p11(wh-1 sh0 wm-1 sm0)! p12(wh-1 sh0 wm-1 sm0)! p13(wh-1 sh0 wm-1 sm0)! p14(wh-1 sh0 wm-1 sm0)! p15(wh30 sh0 wm30 sm0)! p16(wh32 sh0 wm32 sm0)! p17(wh-1 sh0 wm-1 sm0)! p18(wh-1 sh0 wm-1 sm0)! p19(wh-1 sh0 wm-1 sm0)! cmp=2 match=0
SHADOW turn=0 wAnim=38000 sAnim=38000 myNo=0 wMyPos=0 wMp=76 | p10(wh-1 sh0 wm-1 sm0)! p11(wh-1 sh0 wm-1 sm0)! p12(wh-1 sh0 wm-1 sm0)! p13(wh-1 sh0 wm-1 sm0)! p14(wh-1 sh0 wm-1 sm0)! p15(wh30 sh0 wm30 sm0)! p16(wh29 sh0 wm29 sm0)! p17(wh29 sh0 wm29 sm0)! p18(wh-1 sh0 wm-1 sm0)! p19(wh-1 sh0 wm-1 sm0)! cmp=3 match=0
SHADOW turn=0 wAnim=78000 sAnim=78000 myNo=0 wMyPos=0 wMp=76 | p10(wh-1 sh0 wm-1 sm0)! p11(wh-1 sh0 wm-1 sm0)! p12(wh-1 sh0 wm-1 sm0)! p13(wh-1 sh0 wm-1 sm0)! p14(wh-1 sh0 wm-1 sm0)! p15(wh24 sh0 wm24 sm0)! p16(wh31 sh0 wm31 sm0)! p17(wh32 sh0 wm32 sm0)! p18(wh27 sh0 wm27 sm0)! p19(wh-1 sh0 wm-1 sm0)! cmp=4 match=0
FOUNDATIONA_ASSERT: FAIL
REASON: agreement 62.5% < 90% -> parser offset/stride likely wrong. Use mismatch samples to fix BC token indexing. NO switch/block until fixed.
```

## runtime facts

- Foundation A: FAIL (5/8 일치, 62.5%; 기준 90% 미달).
- 걷기조우 oscillation: 예. target=3 및 target=-3, side=0 3회/side=1 1802회.
- 캐릭터 위치: 서로 다른 위치 44개.
- 전투: foundationa comparable turns=8. autobattle-diag의 `battling=1`=0, `CHAR`=0; exp-result의 `battle=1`=3.
- 스크린샷: bus/artifacts/foundationa/foundationa-01-50s.png, foundationa-02-100s.png, foundationa-03-150s.png.
- 크래시: 관찰 종료 시 클라이언트 실행 상태였고 크래시 미관찰.
- teardown: launcher WM_CLOSE 수행, 이 실행의 클라이언트 종료, 관련 launcher/client 프로세스 부재 확인.

## safety self-confirm

- sadll changed: yes
- new client memory write: no (Foundation A 범위)
- new client function call: no (Foundation A 범위)
- new packet/TCP: no (Foundation A 범위)
- PersonalKey exposed/logged: no
- 계정/비밀번호 값: RESULT 및 durable facts에 기록하지 않음
- default flags changed: yes (지시된 런타임 설정)
- client started/attached/run: yes
- only handoff/still untracked: no commit; 기존 작업 트리 변경 및 미추적 파일 유지

