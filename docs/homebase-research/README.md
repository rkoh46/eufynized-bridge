# HomeBase research library

What the official eufy Security app can tell us about the HomeBase 3's local P2P protocol: command numbers, what
each one is for, and features Eufynized doesn't use yet. It feeds both the Mac app and the Home Assistant
integration, which share EufyKit.

| Page | What's in it |
|---|---|
| [live-resolution.md](live-resolution.md) | Why live view starts at 720p, and what does and doesn't change it (measured) |
| [station-messages.md](station-messages.md) | What the HomeBase can send to the app: 25 message numbers from the app's dispatcher, with its log text |
| [opportunities.md](opportunities.md) | Features worth building next, ranked, with what's already known and how to verify safely |
| [command-names.md](command-names.md) | eufy's own command-number → name table (182 numbers), with the app methods that send each |
| [app-methods.md](app-methods.md) | Every method in the app's P2P session class and the command numbers it sends (326 methods, 162 numbers) |
| [undocumented-names.md](undocumented-names.md) | 147 command/feature names in the app that eufy-security-client doesn't cover, by theme |
| `data/` | The raw results the pages are built from (JSON/TSV) |

## Source

- **Target:** eufy Security for iOS **6.1.11** (build 260929151932), installed on this Mac from the App Store as
  `/Applications/BatteryCam.app` (bundle `com.security.BatteryCam`).
- **Main binary:** `Frameworks/BC_P2PClient.framework/BC_P2PClient`, arm64, SHA-256
  `6c0dc09562f9cffa3ea4d62cd18f3e8cd7daa0d592fdd96c9f1e98e13980ecc0`. It contains the PPPP/CS2 transport, the
  `BCP2PClient` / `BCP2PSession` Objective-C classes that build every command, and the dispatcher for messages
  coming back from stations.
- **Baseline:** eufy-security-client's `CommandType` list (540 names), the library Eufynized's protocol work
  started from.

## Method

Static analysis only: the app was never run, and nothing was sent to the HomeBase for this research.

1. **Inventory.** The app's 237 frameworks were searched for known protocol strings (`mode_type`,
   `ai_detect_type`, `param_type`). `BC_P2PClient` holds the protocol; `ESIotMegaKit`, `MegaMainFramework` and
   `MegaCommonFramework` hold some newer payload code.
2. **Disassembly** with REA (rea-agents 6.7.0) driving **Ghidra 12.1.4**, then Ghidra's headless analyzer directly
   with the scripts in [`tools/ghidra/`](../../tools/ghidra) for bulk work.
   - `DumpDecomp.java` decompiles every function matching a name pattern.
   - `ListFunctions.java` lists every function with its caller count.
   - `MethodConstants.java` collects, per method, the numeric constants in its instructions and in the Objective-C
     blocks it creates. On arm64 the command number travels in a register to small stubs, so it shows up as an
     instruction operand rather than in the pseudocode.
3. **Command names.** `rtc_get_command_str_info` is eufy's own switch from command number to name. Parsing it gave
   182 numbered names; 5 aren't in eufy-security-client (1060, 1066, 1275, 1604, 1608).
4. **Who sends what.** `MethodConstants` over all 409 `BCP2PSession` methods. Constants present in more than 8% of
   methods (960, 992, 1680, 1968, 2400, 2768: stack offsets) were dropped. The rest were kept where they match a
   known command number.
5. **Names without numbers.** Every `APP_CMD_*` / `BC_CMD_*` / `CMD_*` string in every binary, matched against the
   library after normalizing prefixes (`APP_CMD_`, `BC_CMD_`, `_NOTI`).

### Checks that the method works

- `setBSArming:userid:chl:` → **1224** (eufy's name `APP_CMD_SET_ALARM_MODE`; the library's `CMD_SET_ARMING`), the guard-mode command verified on the HomeBase 3 on
  2026-10-22 (Home → Disarmed → Home).
- `StartRTVideoStream` → 1003 and `StopVideoStream` → 1004: start/stop live view, which Eufynized uses.
- `localVideoStream…` → 1024 (download clip), `StartFileVideoStream` → 1025 (play recording): Eufynized's clip
  download is 1024.
- `sendVoiceTalkStatus` → 1005/1006: talkback start/stop, as in EufyKit.

### Limits

- **Numbers are static evidence.** A method listing two or more numbers may include a neighbour's constant. One
  number for a `…userid:chl:` method is reliable; anything else needs confirming on hardware.
- **Payloads aren't fully mapped.** Many newer features go through SET_PAYLOAD (1350) with the real command inside
  the JSON, built in the higher frameworks. Their inner command numbers and JSON keys are the next pass (see
  opportunities.md).
- **One app version.** Numbers have been stable for years, but new firmware can add or change them.

## Safety rules for trying anything from here

- **Never send** reboot or reset commands: 1034 (reboot) and 1036/1037 (factory reset), which EufyKit blocks in
  `CameraSettingsCatalog.forbiddenCommands`. Treat anything named `DEVS_REBOOT`, `DEV_REBOOT`, `FAC_*`, `UNBIND`,
  `FORMAT` or `DELETE` the same way, even though only those three numbers are blocked in code today.
- **Never toggle a camera's power** in tests (the user's standing instruction).
- **Read before write.** Try a feature's *get* command first. For a setting, read it, write a different value, read it
  back, then restore the original, as the settings verification did.
- **Alarms and sirens:** never test Away mode, siren or alarm commands at night or without the user's OK.

## Reproducing

```bash
# Ghidra 12.1.4 + Temurin JDK 21 in ~/Applications; build the arm64 decompiler once (the release ships none):
cd ~/Applications/ghidra_12.1.4_PUBLIC/Ghidra/Features/Decompiler/src/decompile/cpp
make -j8 ghidra_opt ARCH_TYPE="-arch arm64"
mkdir -p ../../../os/mac_arm_64 && cp ghidra_opt ../../../os/mac_arm_64/decompile
```

Then import the binary once and run the scripts against the saved project (seconds per run, no re-analysis):

```bash
export JAVA_HOME=~/Applications/jdk-21/Contents/Home
H=~/Applications/ghidra_12.1.4_PUBLIC/support/analyzeHeadless
B=/Applications/BatteryCam.app/Wrapper/BatteryCam.app/Frameworks/BC_P2PClient.framework/BC_P2PClient
$H /tmp/ghidra-eufy eufy -import "$B" -overwrite                                   # about 3.5 minutes
$H /tmp/ghidra-eufy eufy -process BC_P2PClient -noanalysis -scriptPath tools/ghidra \
   -postScript MethodConstants.java '^BCP2PSession::' docs/homebase-research/data/session_method_constants.tsv
python3 tools/ghidra/build_research_docs.py
```

REA can use the same Ghidra once its MCP registration has `GHIDRA_INSTALL_DIR` and `JAVA_HOME` (already set in
`~/.claude.json`); it needs a reconnect to pick them up.
