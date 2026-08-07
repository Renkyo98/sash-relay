# RESULT

CYCLE: 153
INSTRUCTION_SHA256: 7BA675151643E5737D85F0AAD635F51899BD20BD49703E665678A0C5BA314D79
STATUS: DONE (OVERALL FAIL)

## git

- branch: sash-client05-integration
- HEAD: f325579faa0ccf1518856cd502298a9330ec1cd3
- git status --short: modified and untracked paths present after the explicitly requested build/deploy script; no commit made.

## build

- human-b1diag-go.ps1: PASS (sadll OK; SaSH OK)
- deployed sadll SHA256: 76F9FA382874B73CEDF81CDDD8F3ADD89CA30CBD45B09B61B46130DE2B06116C

## runtime config readback

- runtime/default.json: FastBattleEnable=True; AutoBattleEnable=True; AutoWalkEnable=True
- runtime/settings/default.json: FastBattleEnable=True; AutoBattleEnable=True; AutoWalkEnable=True

## assertions and observation

- FASTBATTLE_ASSERT stdout: `FASTBATTLE_ASSERT: FAIL` / `REASON: no fastbattle-diag*.log found (feature never applied -> flag not wired or monitor block not reached)`
- exact `want=1` fastbattle line: absent; no fastbattle-diag log was created.
- WALK_ASSERT stdout: PASS; distinct in-world positions: 129; max tiles from origin: 58.
- autobattle battle/enable-line count: 50. Battle-state lines occurred (`battling=1`).
- stuck: no (129 distinct in-world positions).
- overall: FAIL (FASTBATTLE_ASSERT failed); movement and battles occurred.
- screenshots: C:\SaSH-relay\bus\artifacts\fastbattle\fastbattle-01.png; C:\SaSH-relay\bus\artifacts\fastbattle\fastbattle-02.png; C:\SaSH-relay\bus\artifacts\fastbattle\fastbattle-03.png
- collected logs: C:\SaSH-relay\out\autobattle-diag-144.log; C:\SaSH-relay\out\autowalk-diag-144.log; fastbattle log missing.
- crash check: SA93Client was responding at the first capture; no crash observed before teardown.

## safety self-confirm

- sadll changed: yes (deployed by the requested build script)
- new client memory write: yes (only the instruction-specified fast-battle ret-byte patch)
- new client function call: no
- new packet/TCP: no beyond instruction-authorized existing features
- PersonalKey readable: no; length: n/a; PersonalKey exposed/logged: no
- default flags changed: yes, only the instruction-specified runtime config values
- client started/attached/run: yes, owned offline validation client only
- teardown: launcher WM_CLOSE issued; this run's SA93Client terminated; modal clear attempted; launcher and client processes confirmed absent

## notes

- No commit made. No action beyond the specified cycle steps was performed.
