#!/usr/bin/env python3
"""Stage only production Turbo and tokenizer assets; never access recordings.

Object IDs and sizes are pinned from the Hugging Face trees at the revisions
below. A 64-digit object is an LFS SHA-256; a 40-digit object is a Git blob SHA-1.
No mutable branch, remote manifest, or inference-time download is involved.
"""
import argparse
import concurrent.futures
import hashlib
import json
import pathlib
import shutil
import tempfile
import urllib.parse
import urllib.request

SOURCES = [
    {
        "repo": "argmaxinc/whisperkit-coreml",
        "revision": "0f63a7800b00dd0226abd051b906c246e1907482",
        "directory": "openai_whisper-large-v3-v20240930_626MB",
        "files": [
            {
                "path": "AudioEncoder.mlmodelc/analytics/coremldata.bin",
                "bytes": 243,
                "object": "56793886ab1adb9ca8a4e335efbe8af6640f40d958ab2d29c3ad2d7d6f712e95"
            },
            {
                "path": "AudioEncoder.mlmodelc/coremldata.bin",
                "bytes": 348,
                "object": "ffa9eb76e8e9d9be75a4d527e5249e61d67fd43081c5aa110fd24efa6c8c5ea3"
            },
            {
                "path": "AudioEncoder.mlmodelc/metadata.json",
                "bytes": 1922,
                "object": "7ecaaec9b1af60d12a5b4701f6a14ba2396ace53"
            },
            {
                "path": "AudioEncoder.mlmodelc/model.mil",
                "bytes": 934263,
                "object": "0201c413869fdb60610817722f392dc064986105"
            },
            {
                "path": "AudioEncoder.mlmodelc/weights/weight.bin",
                "bytes": 421968768,
                "object": "e4740fa28ed65907af754af893dfce98473fafb84dd8d718ad346985fe7678c1"
            },
            {
                "path": "MelSpectrogram.mlmodelc/analytics/coremldata.bin",
                "bytes": 243,
                "object": "c5be419f8622083ac7046306400643539f0e7577c843448c36defc090d41e7ce"
            },
            {
                "path": "MelSpectrogram.mlmodelc/coremldata.bin",
                "bytes": 329,
                "object": "2bfc12cffc2e45e039c7a18f384f09adffb72c182fcd93f9413d405d1a6c1130"
            },
            {
                "path": "MelSpectrogram.mlmodelc/metadata.json",
                "bytes": 1850,
                "object": "fa0c2e5993006c311ba50d307cf563ae10a16b5f"
            },
            {
                "path": "MelSpectrogram.mlmodelc/model.mil",
                "bytes": 10143,
                "object": "16b67b0978ac178a7540e8520915d2473d4bae03"
            },
            {
                "path": "MelSpectrogram.mlmodelc/weights/weight.bin",
                "bytes": 373376,
                "object": "009d9fb8f6b589accfa08cebf1c712ef07c3405229ce3cfb3a57ee033c9d8a49"
            },
            {
                "path": "TextDecoder.mlmodelc/analytics/coremldata.bin",
                "bytes": 243,
                "object": "3913b8c9716b284a917cf3744f4d415f2a05e2b910594a14c6cc10092284d3f8"
            },
            {
                "path": "TextDecoder.mlmodelc/coremldata.bin",
                "bytes": 633,
                "object": "3faabaf66930e66956d8291d0ff485fb382496e30a91a7185548b9b898ce90a9"
            },
            {
                "path": "TextDecoder.mlmodelc/metadata.json",
                "bytes": 4924,
                "object": "457b227f0ab00cd435c8dfbceb229af8559796af"
            },
            {
                "path": "TextDecoder.mlmodelc/model.mil",
                "bytes": 217177,
                "object": "1f1a12d6391f6d2d4e98ebaedc88da513460296c"
            },
            {
                "path": "TextDecoder.mlmodelc/weights/weight.bin",
                "bytes": 203199860,
                "object": "d69700903d518ada33170ab77faaaf464496fb9ff65752c6d5a6109aa2fb02db"
            }
        ]
    },
    {
        "repo": "openai/whisper-large-v3",
        "revision": "06f233fe06e710322aca913c1bc4249a0d71fce1",
        "directory": "tokenizers/openai/whisper-large-v3",
        "files": [
            {
                "path": "config.json",
                "bytes": 1272,
                "object": "14c6c8cf48b64ebb1cb8b637e2b0fab3a9774972"
            },
            {
                "path": "tokenizer.json",
                "bytes": 2480617,
                "object": "3a5e2ba63acdcac9a19ba56cf9bd27f185bfff61"
            },
            {
                "path": "tokenizer_config.json",
                "bytes": 282843,
                "object": "06ffdc8308eae6bb7bd1fdd81e94b0a881a539ab"
            }
        ]
    }
]


def matches(path, asset):
    if not path.is_file() or path.stat().st_size != asset["bytes"]:
        return False
    checksum = hashlib.sha256() if len(asset["object"]) == 64 else hashlib.sha1()
    if len(asset["object"]) == 40:
        checksum.update(f"blob {asset['bytes']}\0".encode())
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest() == asset["object"]


def stage(job):
    source, asset, root, reuse, offline = job
    relative = pathlib.Path(source["directory"]) / asset["path"]
    destination = root / relative
    if matches(destination, asset):
        return
    cached = reuse / relative
    can_reuse = matches(cached, asset)
    if not can_reuse and offline:
        raise RuntimeError(f"Missing or corrupt pinned asset (offline): {relative}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".speech-", delete=False) as handle:
        temporary = pathlib.Path(handle.name)
    try:
        if can_reuse:
            shutil.copyfile(cached, temporary)
        else:
            remote_path = asset["path"]
            if source["repo"] == "argmaxinc/whisperkit-coreml":
                remote_path = source["directory"] + "/" + remote_path
            url = (f"https://huggingface.co/{source['repo']}/resolve/{source['revision']}/"
                   f"{urllib.parse.quote(remote_path)}?download=true")
            with urllib.request.urlopen(url, timeout=180) as response, temporary.open("wb") as output:
                shutil.copyfileobj(response, output, length=1024 * 1024)
        if not matches(temporary, asset):
            raise RuntimeError(f"Pinned asset integrity check failed: {relative}")
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", nargs="?", type=pathlib.Path,
                        default=pathlib.Path(__file__).resolve().parents[1] / "PitchPractice" / "SpeechModels")
    parser.add_argument("--reuse", type=pathlib.Path, default=pathlib.Path("/tmp/pitch-transcription-models"),
                        help="Reuse integrity-checked public assets from this staging directory")
    parser.add_argument("--offline", action="store_true", help="Require staged assets; never access the network")
    args = parser.parse_args()
    root = args.destination.resolve()
    reuse = args.reuse.resolve()
    jobs = [(source, asset, root, reuse, args.offline) for source in SOURCES for asset in source["files"]]
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(stage, jobs))
    # Verify the complete required set, including all compiled weights and tokenizer JSONs.
    for source, asset, _, _, _ in jobs:
        destination = root / source["directory"] / asset["path"]
        if not matches(destination, asset):
            raise RuntimeError(f"Incomplete production assets: {destination}")
    (root / "assets-manifest.json").write_text(json.dumps(SOURCES, indent=2) + "\n")
    total = sum(asset["bytes"] for _, asset, _, _, _ in jobs)
    print(f"Verified {len(jobs)} pinned Turbo/tokenizer assets ({total / 1e6:.1f} MB) in {root}")


if __name__ == "__main__":
    main()
