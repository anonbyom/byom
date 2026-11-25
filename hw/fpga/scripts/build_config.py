import hashlib
import json
from pathlib import Path
import tomllib


ROOT = Path(__file__).resolve().parents[2]

def parameter(value):
    return str(int(value)) if isinstance(value, bool) else str(value)

def load_config(path, settings=(), defines=()):
    config = tomllib.loads(Path(path).read_text())
    for setting in settings:
        key, _, value = setting.partition("=")
        if key not in config["parameters"]:
            raise ValueError(f"--set {key}: no such parameter")
        config["parameters"][key] = value
    config["defines"] = config.get("defines", []) + list(defines)
    return config

def toml_text(config):
    lines = [f"{json.dumps(k)} = {json.dumps(v)}" for k, v in config.items() if not isinstance(v, dict)]
    for key, table in config.items():
        if isinstance(table, dict):
            lines += ["", f"[{json.dumps(key)}]"] + [f"{json.dumps(k)} = {json.dumps(v)}" for k, v in table.items()]
    return "\n".join(lines) + "\n"

def snapshot_files(config_path, config, root=ROOT):
    root = root.resolve()
    paths = {Path(config_path).resolve().relative_to(root).as_posix(), "fpga.toml"}
    paths.update(config["sources"])
    paths.update(config.get("constraints", []))
    paths.update(config.get("hooks", {}).values())
    paths.update(config.get("dependencies", []))
    for folder in ("fpga/scripts", "scripts/remote_fpga"):
        paths.update(p.relative_to(root).as_posix() for p in (root / folder).rglob("*")
                     if p.is_file() and "__pycache__" not in p.parts)
    for name in paths:
        path = root / name
        if (Path(name).is_absolute() or ".." in Path(name).parts
                or not path.is_file() or not path.resolve().is_relative_to(root)
                or any(c in name for c in "\n\r\t")):
            raise ValueError(f"invalid snapshot input: {name}")
    return sorted(paths)

def fingerprints(config_path, config, root=ROOT):
    return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in snapshot_files(config_path, config, root)}
