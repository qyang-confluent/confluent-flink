#!/usr/bin/env python3
"""Expand shadowtraffic_machine_telemetry.json (1 machine) into a 20-machine fleet config.

Each machine gets its own VIN/serial, a field location, and a per-machine baseline
(means/sds scaled by a seeded factor) so per-equipment anomaly detectors learn
different normals.
"""
import copy, json, random

N = 50
SKIP_SCALE = {"latitude", "longitude", "heading", "elevation", "distance", "gpsMode"}
base = json.load(open("shadowtraffic_machine_telemetry.json"))
tpl = base["generators"][0]
OLD_VIN = tpl["key"]
rng = random.Random(42)


def scale(node, f):
    """Scale every normalDistribution mean/sd/clamp-agnostic inside a var spec."""
    if isinstance(node, dict):
        if node.get("_gen") == "normalDistribution":
            node["mean"] = float(f"{node['mean'] * f:.10g}")
            node["sd"] = float(f"{node['sd'] * f:.10g}")
        for v in node.values():
            scale(v, f)
    elif isinstance(node, list):
        for v in node:
            scale(v, f)


gens = []
for i in range(1, N + 1):
    g = copy.deepcopy(tpl)
    vin = f"WAM84523K00F001{i:02d}"
    g["name"] = f"machine-telemetry-{i:02d}"
    g["key"] = vin
    for name, spec in g["vars"].items():
        if name in SKIP_SCALE or not isinstance(spec, dict):
            continue
        scale(spec, rng.uniform(0.93, 1.07))
    # field location near the original site, ~±0.05 deg apart
    g["vars"]["latitude"]["mean"] = round(46.9184619 + rng.uniform(-0.05, 0.05), 7)
    g["vars"]["longitude"]["mean"] = round(16.69813 + rng.uniform(-0.05, 0.05), 6)
    g["vars"]["latitude"]["clamp"] = [g["vars"]["latitude"]["mean"] - 0.1, g["vars"]["latitude"]["mean"] + 0.1]
    g["vars"]["longitude"]["clamp"] = [g["vars"]["longitude"]["mean"] - 0.1, g["vars"]["longitude"]["mean"] + 0.1]
    body = g["value"]["body"]
    body["equipmentIdentificationNumber"] = vin
    body["deviceSerialNumber"] = f"0402-1612{i:02d}"
    gens.append(g)

out = copy.deepcopy(base)
out["generators"] = gens
json.dump(out, open("shadowtraffic_machine_fleet20.json", "w"), indent=2)
print(f"wrote shadowtraffic_machine_fleet20.json with {len(gens)} machines")
