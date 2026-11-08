#!/usr/bin/env python3
"""Stage pinned public model assets only. Never reads or uploads recordings."""
import concurrent.futures
import hashlib
import json
import pathlib
import sys
import urllib.parse
import urllib.request

WHISPER_REVISION = "0f63a7800b00dd0226abd051b906c246e1907482"
SOURCES = [
    ("argmaxinc/whisperkit-coreml", WHISPER_REVISION, "openai_whisper-base", "openai_whisper-base", None),
    ("argmaxinc/whisperkit-coreml", WHISPER_REVISION, "openai_whisper-large-v3-v20240930_626MB", "openai_whisper-large-v3-v20240930_626MB", None),
    ("FluidInference/parakeet-ultra-coreml", "95eaa59a39d4394f047a4dc5cce480388a60d1b6", "", "parakeet-ultra-coreml", None),
    ("openai/whisper-base", "e37978b90ca9030d5170a5c07aadb050351a65bb", "", "tokenizers/openai/whisper-base", {"tokenizer.json", "tokenizer_config.json", "config.json"}),
    ("openai/whisper-large-v3", "06f233fe06e710322aca913c1bc4249a0d71fce1", "", "tokenizers/openai/whisper-large-v3", {"tokenizer.json", "tokenizer_config.json", "config.json"}),
]


def digest(path, entry):
    checksum = hashlib.sha256() if "lfs" in entry else hashlib.sha1()
    if "lfs" not in entry:
        checksum.update(f"blob {entry['size']}\0".encode())
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def download(job):
    repo, revision, entry, destination = job
    expected = entry.get("lfs", {}).get("oid", entry["oid"])
    if destination.exists() and destination.stat().st_size == entry["size"] and digest(destination, entry) == expected:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    url = f"https://huggingface.co/{repo}/resolve/{revision}/{urllib.parse.quote(entry['path'])}?download=true"
    temporary = destination.with_name(destination.name + ".download")
    with urllib.request.urlopen(url, timeout=180) as response, temporary.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            output.write(chunk)
    if temporary.stat().st_size != entry["size"] or digest(temporary, entry) != expected:
        raise RuntimeError(f"Model integrity check failed: {entry['path']}")
    temporary.replace(destination)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python3 download_models.py /absolute/path/to/Models")
    root = pathlib.Path(sys.argv[1]).resolve()
    jobs = []
    manifest = []
    for repo, revision, folder, destination, names in SOURCES:
        endpoint = f"https://huggingface.co/api/models/{repo}/tree/{revision}/{folder}?recursive=true&limit=1000"
        with urllib.request.urlopen(endpoint, timeout=30) as response:
            entries = json.load(response)
        selected = []
        for entry in entries:
            if entry["type"] != "file":
                continue
            relative = pathlib.PurePosixPath(entry["path"]).relative_to(folder) if folder else pathlib.PurePosixPath(entry["path"])
            if names is not None and str(relative) not in names:
                continue
            if names is None and not (".mlmodelc/" in entry["path"] or relative.name in {"config.json", "generation_config.json", "parakeet_vocab.json", "README.md"}):
                continue
            jobs.append((repo, revision, entry, root / destination / relative))
            selected.append({"path": str(relative), "bytes": entry["size"], "object": entry.get("lfs", {}).get("oid", entry["oid"])})
        if not selected or (names is not None and {item["path"] for item in selected} != names):
            raise RuntimeError(f"Incomplete asset manifest: {repo}/{folder}")
        manifest.append({"repo": repo, "revision": revision, "directory": destination, "files": selected})
        print(f"{destination}: {sum(item['bytes'] for item in selected) / 1e6:.1f} MB", flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(download, jobs))
    (root / "assets-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Verified {len(jobs)} files in {root}")


if __name__ == "__main__":
    main()
