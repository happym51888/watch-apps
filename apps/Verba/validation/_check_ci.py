import yaml
import pathlib

root = pathlib.Path(__file__).resolve().parents[3]
spec = yaml.safe_load((root / ".github/workflows/build.yml").read_text(encoding="utf-8"))

print("YAML parses OK")
for job, body in spec["jobs"].items():
    print(f"  job {job}: {len(body.get('steps', []))} steps")

print("  validators:", [
    s["run"].split("/")[1]
    for s in spec["jobs"]["validate-logic"]["steps"]
    if "run" in s and "validation" in s["run"]
])
print("  swift-tests apps:", spec["jobs"]["swift-tests"]["strategy"]["matrix"]["app"])
print("  watch-build schemes:", [
    entry["scheme"] for entry in spec["jobs"]["watch-build"]["strategy"]["matrix"]["include"]
])
