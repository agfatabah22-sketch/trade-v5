"""Build the public engine from src only. No local config is read or included."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent
MODULES = [
    ("makeNameResolver", "name-resolver"),
    ("normalizeTradeRecipients", "recipients"),
    ("makeTradePreparation", "trade-preparation"),
    ("makeTradeAdapter", "trade-adapter"),
    ("makeNativeUI", "native-ui"),
    ("makeStartupPopups", "startup-popups"),
    ("makeStartupMenu", "startup-menu"),
    ("makeStartupGate", "startup-gate"),
    ("makeStartup", "startup"),
    ("makeTradeWarnings", "trade-warnings"),
    ("makeBindings", "bindings"),
    ("makeAccountOpsDisable", "accountops-disable"),
    ("makeController", "controller"),
    ("makeOverlay", "overlay"),
    ("makeDiagnostics", "diagnostics"),
    ("makeDiagnosticSnapshot", "diagnostic-snapshot"),
]

BOOTSTRAP = '''
local externalEnvironment = type(getgenv) == "function" and getgenv() or _G
local externalOK, externalSnapshot = pcall(makeExternalConfig,
    type(externalEnvironment) == "table" and rawget(externalEnvironment, "BlueHubConfig") or nil)
if not externalOK then
    warn("[Blue Hub] Config eksternal tidak valid. Periksa getgenv().BlueHubConfig sebelum loader.")
    return
end
local Config = externalSnapshot
'''


def render(root: Path = ROOT) -> str:
    def factory(variable: str, module: str) -> str:
        source = (root / "src" / (module + ".lua")).read_text(encoding="utf-8")
        return f"\nlocal {variable} = (function()\n{source.rstrip()}\nend)()\n"

    parts = ["-- Blue Hub Trade Only: public engine; configuration stays in the caller.\n",
             factory("makeExternalConfig", "external-config"), BOOTSTRAP]
    parts.extend(factory(variable, module) for variable, module in MODULES)
    parts.append((root / "src" / "runtime.lua").read_text(encoding="utf-8"))
    return "\n".join(parts)


def build(root: Path = ROOT) -> Path:
    output = root / "BlueHub.lua"
    output.write_text(render(root), encoding="utf-8", newline="\n")
    return output


if __name__ == "__main__":
    print(build())
