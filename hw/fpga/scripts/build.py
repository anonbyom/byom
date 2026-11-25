#!/usr/bin/env python3
import argparse
import os
from pathlib import Path
import shlex
import signal
import subprocess
from build_config import load_config, parameter, toml_text


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "fpga/scripts"
PLATFORM = "xilinx_u55c_gen3x16_xdma_3_202210_1"
HBM_CHANNELS = 32


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="FPGA builder")
    parser.add_argument("flow", choices=("xclbin",))
    parser.add_argument("--freq", type=float, default=300)
    parser.add_argument("-j", "--jobs", type=int, default=8)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--vivado", default="vivado")
    parser.add_argument("--vpp", default="v++")
    parser.add_argument("--set", action="append", default=[], metavar="NAME=VALUE")
    parser.add_argument("--define", action="append", default=[])
    parser.add_argument("--status-dir", type=Path)
    args = parser.parse_args()

    config_path = args.config.resolve()
    config = load_config(config_path, args.set, args.define)
    sources = [(ROOT / path).resolve() for path in config["sources"]]
    constraints = [(ROOT / path).resolve() for path in config.get("constraints", [])]
    hooks = {stage: (ROOT / path).resolve() for stage, path in config.get("hooks", {}).items()}
    output = (args.output or ROOT / f"build/{config_path.stem}-{args.flow}-{args.freq:g}m").resolve()

    link = output / "link.cfg"
    pre_place = output / "pre_place.tcl"
    post_place = output / "post_place.tcl"
    commands = [
        [args.vivado, "-mode", "batch", "-source", str(SCRIPTS / "package_kernel.tcl")],
        [args.vpp, "-l", "-t", "hw", "--platform", PLATFORM,
         "--config", str(link), "--kernel_frequency", f"{args.freq:g}",
         "--vivado.param", f"general.maxThreads={args.jobs}",
         "--save-temps", "--temp_dir", str(output / "temp"),
         "--report_dir", str(output / "reports"), "--log_dir", str(output / "logs"),
         "-o", str(output / "kernel.xclbin"), str(output / "kernel.xo")],
    ]
    if "pre_place" in hooks:
        commands[1].extend(["--vivado.prop", f"run.impl_1.STEPS.PLACE_DESIGN.TCL.PRE={pre_place}"])
    for step, key in (("PLACE_DESIGN", "place"), ("ROUTE_DESIGN", "route")):
        if directive := config.get("directives", {}).get(key):
            commands[1].extend(["--vivado.prop", f"run.impl_1.STEPS.{step}.ARGS.DIRECTIVE={directive}"])
    commands[1].extend([
        "--vivado.prop", f"run.impl_1.STEPS.PLACE_DESIGN.TCL.POST={post_place}",
        "--vivado.prop", f"run.impl_1.STEPS.ROUTE_DESIGN.TCL.POST={output / 'post_route.tcl'}",
    ])

    print(f"Config: {config_path}\nSources: {len(sources)}\nOutput: {output}", flush=True)
    for command in commands:
        print(shlex.join(command), flush=True)
    output.mkdir(parents=True)
    (output / "config.toml").write_text(toml_text(config))
    for folder in ("reports", "checkpoints", "results", "logs"):
        (output / folder).mkdir()
    instance = f"{config['top']}_1"
    connections = ["[connectivity]", f"nk={config['top']}:1:{instance}"]
    connections += [f"sp={instance}.m_axi_gmem{channel}:HBM[{channel}]" for channel in range(HBM_CHANNELS)]
    link.write_text("\n".join(connections) + "\n")
    if "pre_place" in hooks:
        pre_place.write_text(
            "".join(f"set ::tpu_{key} {parameter(value)}\n" for key, value in config.get("floorplan", {}).items()) +
            f"source {{{hooks['pre_place']}}}\n"
        )
    post_place.write_text(
        (f"source {{{hooks['post_place']}}}\n" if "post_place" in hooks else "") +
        "file mkdir $::env(FPGA_OUTPUT)/checkpoints\n"
        "write_checkpoint -force $::env(FPGA_OUTPUT)/checkpoints/post_place.dcp\n"
    )
    post_route_phys_opt = config.get("directives", {}).get("post_route_phys_opt")
    (output / "post_route.tcl").write_text(
        (f"phys_opt_design -directive {post_route_phys_opt}\n"
         "report_timing_summary -file $::env(FPGA_OUTPUT)/reports/post_route_phys_opt_timing.rpt\n"
         if post_route_phys_opt else "") +
        "write_checkpoint -force $::env(FPGA_OUTPUT)/checkpoints/post_route.dcp\n"
        "report_timing_summary -delay_type min_max -report_unconstrained -file $::env(FPGA_OUTPUT)/reports/post_route_timing.rpt\n"
        "report_utilization -file $::env(FPGA_OUTPUT)/reports/post_route_utilization.rpt\n"
        "report_utilization -slr -file $::env(FPGA_OUTPUT)/reports/post_route_slr.rpt\n"
    )
    build_env = {
        "TOP":          config["top"],
        "PART":         config["part"],
        "VERILOG_SRCS": "\n".join(map(str, sources)),
        "XDC_SRCS":     "\n".join(map(str, constraints)),
        "PARAMETERS":   "\n".join(f"{name}={parameter(value)}" for name, value in config["parameters"].items()),
        "VERILOG_DEFINES": "\n".join(config.get("defines", [])),
        "FPGA_OUTPUT":  str(output),
        "MAX_THREADS":  str(args.jobs),
        **{f"HOOK_{stage.upper()}": str(hook) for stage, hook in hooks.items()},
    }
    if args.status_dir:
        args.status_dir.mkdir(parents=True, exist_ok=True)
        build_env["BUILD_STATUS_DIR"] = str(args.status_dir.resolve())
    build_env.update({"XO": str(output / "kernel.xo"), "PACKAGE_DIR": str(output / "package")})
    env = {key: value for key, value in os.environ.items() if not key.startswith("HOOK_") and key != "BUILD_STATUS_DIR"}
    env.update(build_env)
    (output / "build.env").write_text("".join(f"{name}={shlex.quote(value)}\n" for name, value in build_env.items()))
    active_tool = None

    def terminate_build(signum, _frame):
        signal.signal(signum, signal.SIG_DFL)
        if os.getpgrp() == os.getpid():
            os.killpg(os.getpgrp(), signum)
        elif active_tool is not None and active_tool.poll() is None:
            active_tool.send_signal(signum)
        raise SystemExit(128 + signum)
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, terminate_build)
    for index, command in enumerate(commands):
        if args.status_dir:
            (args.status_dir / "last_stage").write_text(("package_xo" if index == 0 else "linking_xclbin") + "\n")
        with (output / f"step{index + 1}.log").open("w") as log:
            active_tool = subprocess.Popen(command, cwd=output, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            for line in active_tool.stdout:
                print(line, end="", flush=True)
                log.write(line)
            if active_tool.wait():
                raise SystemExit(f"Build failed. See {log.name}")
            active_tool = None
    if args.status_dir:
        (args.status_dir / "last_stage").write_text("xclbin\n")
    print(f"Build finished: {output}.")
