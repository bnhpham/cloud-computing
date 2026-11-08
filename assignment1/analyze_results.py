from pathlib import Path

import matplotlib
matplotlib.use("Agg") # Non-interactive backend to prevent pop-up windows and render plots directly to image files in memory
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent
RESULTS = ROOT / "results"
INPUT = RESULTS / "measurements.csv"

BENCHMARKS = {"cpu_events_per_second": ("CPU Performance", "Events/s", "cpu.png"),
              "memory_MiB_per_second": ("Memory Throughput", "MiB/s", "memory.png"),
              "random_read_MiB_per_second": ("Random-Read Throughput", "MiB/s", "random_read.png"),
              "sequential_read_MiB_per_second": ("Sequential-Read Throughput", "MiB/s", "sequential_read.png")}
ENVIRONMENTS = ["native", "docker", "kvm", "qemu"]
KEYS = ["machine_type", "environment"]


def main():

    # Check whether measurements exist
    if not INPUT.is_file():
        raise SystemExit(f"Missing input: {INPUT}")

    df = pd.read_csv(INPUT)
    required = set(KEYS + ["repetition", *BENCHMARKS])

    missing = required - set(df.columns)
    if missing:
        raise SystemExit(f"Missing CSV columns: {sorted(missing)}")

    if df.duplicated([*KEYS, "repetition"]).any():
        raise SystemExit("Duplicate machine/environment/repetition rows found")

    for metric in BENCHMARKS:
        df[metric] = pd.to_numeric(df[metric], errors="raise")

    if df[list(BENCHMARKS)].isna().any().any():
        raise SystemExit("Some measurements are missing")

    # Convert wide input (four metrics per run) to one row per benchmark.
    long = df.melt(id_vars=[*KEYS, "repetition"], value_vars=list(BENCHMARKS), var_name="benchmark", value_name="value",)

    # Group benchmark measurements by machine type, environment, and benchmark and compute statistics for each group
    summary = (long.groupby([*KEYS, "benchmark"], as_index=False).agg(mean=("value", "mean"), std=("value", "std"), n=("value", "size")))
    summary["std"] = summary["std"].fillna(0)  # Replace missing values (NaN) with 0 when a group has only one measurement

    # Add the Native Linux baseline to every row
    native = (summary.loc[summary["environment"] == "native", ["machine_type", "benchmark", "mean"]].rename(columns={"mean": "native_mean"}))
    summary = summary.merge(native, on=["machine_type", "benchmark"], how="left", validate="many_to_one")
    if summary["native_mean"].isna().any() or (summary["native_mean"] <= 0).any():
        raise SystemExit("Missing or non-positive native baseline for a machine/benchmark")

    # Relative performance (R = (Virtualized performance / Native performance) * 100%)
    summary["relative_to_native_pct"] = 100 * summary["mean"] / summary["native_mean"]

    summary = summary.sort_values(["machine_type", "benchmark", "environment"])

    # Save benchmark summary as csv
    RESULTS.mkdir(exist_ok=True)
    output = RESULTS / "summary.csv"
    summary.to_csv(output, index=False, float_format="%.4f")

    # Plotting
    machines = sorted(summary["machine_type"].unique())
    x = np.arange(len(machines))
    width = 0.19

    # Iterate over all 4 benchmarks
    for metric, (title, unit, filename) in BENCHMARKS.items():

        subset = summary.loc[summary["benchmark"] == metric]

        fig, ax = plt.subplots(figsize=(10, 5.5))

        # Iterate over all 4 virtualization methods
        for i, environment in enumerate(ENVIRONMENTS):
            values = subset.loc[subset["environment"] == environment].set_index("machine_type")
            
            means = values.reindex(machines)["mean"].to_numpy(dtype=float)
            stds = values.reindex(machines)["std"].to_numpy(dtype=float)
            
            positions = x + (i - (len(ENVIRONMENTS) - 1) / 2) * width
            ax.bar(positions, means, width, yerr=stds, capsize=3, label=environment.upper())

        ax.set_title(f"{title} (mean & std)")
        ax.set_ylabel(unit)
        ax.set_xlabel("GCP machine type")
        ax.set_xticks(x, machines)
        ax.legend(title="Environment")
        ax.grid(axis="y", alpha=0.25)
        ax.set_axisbelow(True)
        fig.tight_layout()

        # Save plot
        path = RESULTS / filename
        fig.savefig(path, dpi=180)
        plt.close(fig)

    # Relative performance
    print("Relative performance (% of native mean):")
    relative = summary.pivot_table(index=["machine_type", "benchmark"], columns="environment", values="relative_to_native_pct").reindex(columns=ENVIRONMENTS)
    print(relative.round(2).to_string())


if __name__ == "__main__":
    main()
