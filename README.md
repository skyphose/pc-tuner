# pc-tuner

Evidence-based Windows gaming & network tweaks, built for auditability.
MIT licensed — see [LICENSE](LICENSE).

## Trust model — why you can verify this isn't malware

The design rule: **tweaks are data, not code.**

- All executable logic lives in one file: [`pc-tuner.ps1`](pc-tuner.ps1) (~300 lines of
  plain PowerShell — read it once, you've audited everything that can run).
- Tweaks live in [`modules/*.json`](modules/) — **pure JSON, no code**. A module can
  only *describe* changes using the engine's fixed action vocabulary:

  | action | what it can do |
  |---|---|
  | `registry` | set one registry value |
  | `powercfg-scheme` | activate a power plan |
  | `netadapter-advanced` | set network adapter advanced properties |

  A module physically cannot download files, run commands, or touch anything
  outside those actions. The engine refuses unknown action types.
- Before any change, the original value is saved to `pc-tuner-backup.json`.
  `.\pc-tuner.ps1 -Revert all` restores your exact original state.
- When applying, the engine prints every individual change it makes.

## Usage

GUI (recommended):

```powershell
powershell -ExecutionPolicy Bypass -File .\pc-tuner-gui.ps1
```

The GUI ([`pc-tuner-gui.ps1`](pc-tuner-gui.ps1)) is also a single plain-text
PowerShell/WPF script — no compiled binaries anywhere in this project. It
never modifies the system itself; every Apply/Revert shells out to the
engine, so the engine remains the single audited modification path.

CLI:

```powershell
.\pc-tuner.ps1                      # status of every tweak (read-only)
.\pc-tuner.ps1 -StatusJson          # machine-readable status (used by GUI)
.\pc-tuner.ps1 -Apply safe          # apply all safe-tier tweaks
.\pc-tuner.ps1 -Apply hags          # apply specific tweak(s)
.\pc-tuner.ps1 -Revert all          # undo everything from backup
```

Tweaks marked `"risk": "tradeoff"` (currently only `memory-integrity`) are
never applied by `safe` and require an explicit `-AcceptTradeoffs` flag.

## Writing a module

Drop a `.json` file in `modules/`:

```json
{
  "module": "my-pack",
  "description": "what this pack is for",
  "tweaks": [
    {
      "id": "unique-id",
      "name": "Human name",
      "risk": "safe",
      "needsAdmin": false,
      "needsReboot": false,
      "why": "Evidence for why this helps. Cite benchmarks.",
      "actions": [
        { "type": "registry", "path": "HKCU:\\...", "name": "Value",
          "value": 1, "valueType": "DWord", "default": 0 }
      ]
    }
  ]
}
```

`default` is what revert falls back to if no backup exists. Duplicate ids
across modules are rejected at load.

## Deliberately excluded (researched, found harmful or snake oil)

- `NetworkThrottlingIndex` / `SystemResponsiveness` hacks — increase DPC
  latency and cause audio crackle, especially on Ryzen
- `TcpAckFrequency` / Nagle tweaks — no measurable modern benefit
- Disabling the page file — causes crashes when RAM fills
- Timer-resolution forcing tools — thrash a core; mostly placebo since the
  Windows 2004 rule change
- Debloat scripts / stripping services — break WebView2 apps (Discord,
  Steam), search, sometimes Explorer itself
- Disabling Windows Defender — no

PRs adding these will be declined with citations.
