#!/usr/bin/env python3
"""Resolve and compare Konflux base-image digests.

Image repositories come from scripts/common/base-image-map.json. A component
that is a key in that file uses its own ARG map. Every other component uses
the "common" map. Digests are the manifest-list digest of the "latest" tag
from the Red Hat Ecosystem Catalog.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import OrderedDict
from datetime import datetime
from pathlib import Path
from typing import Iterable, Mapping, Sequence
from urllib.parse import quote

CATALOG_ROOT = "https://catalog.redhat.com"
ORG_DEFAULT = "openshift-pipelines"
ARG_RE = re.compile(r"^(\s*ARG\s+)([A-Za-z_][A-Za-z0-9_]*)(\s*=\s*)(.*)$")
HEX64 = re.compile(r"[0-9a-fA-F]{64}")


class CatalogError(RuntimeError):
    """The catalog response did not contain a usable latest digest."""


def load_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise SystemExit(f"File not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON in {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise SystemExit(f"Expected a JSON object in {path}")
    return data


def validate_image(image: object, source: str) -> str:
    if not isinstance(image, str) or not image or any(char.isspace() for char in image):
        raise SystemExit(f"{source} must be a registry/repository string without spaces")
    if "://" in image or "@" in image or ":" in image:
        raise SystemExit(
            f"{source} must be a repository without a tag or digest, for example "
            "registry.access.redhat.com/ubi9/go-toolset"
        )
    registry, _, repository = image.partition("/")
    if not registry or not repository:
        raise SystemExit(f"{source} must include a registry host and repository path")
    return image


def load_image_map(path: Path) -> OrderedDict[str, OrderedDict[str, str]]:
    raw = load_json(path)
    if "common" not in raw or not isinstance(raw["common"], dict) or not raw["common"]:
        raise SystemExit(f"{path} must contain a non-empty 'common' ARG map")
    image_map: OrderedDict[str, OrderedDict[str, str]] = OrderedDict()
    for profile, args in raw.items():
        if not isinstance(args, dict) or not args:
            raise SystemExit(f"{path} profile {profile} must be a non-empty object")
        mapped: OrderedDict[str, str] = OrderedDict()
        for arg, image in args.items():
            if not isinstance(arg, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", arg):
                raise SystemExit(f"{path} profile {profile} has an invalid ARG name: {arg!r}")
            mapped[arg] = validate_image(image, f"{path} {profile}.{arg}")
        image_map[profile] = mapped
    return image_map


def profile_for(component: str, image_map: Mapping[str, Mapping[str, str]]) -> str:
    if component != "common" and component in image_map:
        return component
    return "common"


def map_images(image_map: Mapping[str, Mapping[str, str]]) -> list[str]:
    images: list[str] = []
    for profile in ["common", *[name for name in image_map if name != "common"]]:
        for image in image_map[profile].values():
            if image not in images:
                images.append(image)
    return images


def component_names(path: Path, minor: str) -> list[str]:
    data = load_json(path)
    minor_components = data.get(minor)
    if not isinstance(minor_components, dict) or not minor_components:
        known = ", ".join(sorted(str(key) for key in data)) or "none"
        raise SystemExit(f"No components for minor {minor} in {path}. Known minors: {known}")
    names: list[str] = []
    for name, spec in minor_components.items():
        if not isinstance(name, str) or not name:
            raise SystemExit(f"Invalid component name in {path} for {minor}")
        if not isinstance(spec, dict):
            raise SystemExit(f"Component {name} in {path} must be an object")
        names.append(name)
    return names


def catalog_images_url(image: str) -> tuple[str, str]:
    registry, repository = image.split("/", 1)
    repository_path = "/".join(quote(part, safe="") for part in repository.split("/"))
    url = (
        f"{CATALOG_ROOT}/api/containers/v1/repositories/registry/"
        f"{quote(registry, safe='')}/repository/{repository_path}/images"
    )
    return url, repository


def fetch_json(url: str, params: Sequence[tuple[str, str]]) -> dict:
    command = [
        "curl",
        "-fsSL",
        "--max-time",
        "60",
        "--retry",
        "2",
        "--retry-delay",
        "1",
        "-H",
        "Accept: application/json",
        "-A",
        "osp-base-image-update",
        "-G",
        url,
    ]
    for key, value in params:
        command.extend(["--data-urlencode", f"{key}={value}"])
    completed = subprocess.run(command, check=False, capture_output=True, text=True)
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip() or f"curl exit {completed.returncode}"
        raise CatalogError(detail)
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise CatalogError(f"catalog returned invalid JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise CatalogError("catalog returned an unexpected payload")
    return payload


def format_published(value: str) -> str:
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return value
    return parsed.astimezone().strftime("%Y-%m-%d %H:%M %Z")


def digest_from_payload(payload: Mapping[str, object], repository: str) -> dict[str, str]:
    data = payload.get("data")
    if not isinstance(data, list):
        raise CatalogError("catalog response did not include an image list")
    best_date = ""
    best_digest = ""
    conflict = False
    for item in data:
        if not isinstance(item, dict):
            continue
        created = item.get("creation_date")
        if not isinstance(created, str) or not created:
            continue
        repositories = item.get("repositories")
        if not isinstance(repositories, list):
            continue
        for repo in repositories:
            if not isinstance(repo, dict) or repo.get("repository") != repository:
                continue
            tags = repo.get("tags")
            if not isinstance(tags, list) or not any(
                isinstance(tag, dict) and tag.get("name") == "latest" for tag in tags
            ):
                continue
            digest = repo.get("manifest_list_digest")
            if not isinstance(digest, str) or not digest.startswith("sha256:") or not HEX64.fullmatch(digest[7:]):
                continue
            digest = "sha256:" + digest[7:].lower()
            if not best_date or created > best_date:
                best_date = created
                best_digest = digest
                conflict = False
            elif created == best_date and digest != best_digest:
                conflict = True
    if conflict:
        raise CatalogError(f"catalog returned conflicting latest digests for {repository}")
    if not best_digest:
        raise CatalogError(f"no latest-tag manifest list found for {repository}")
    return {"digest": best_digest, "published": format_published(best_date), "tag": "latest"}


def fetch_digests(image_map: Mapping[str, Mapping[str, str]]) -> dict[str, dict[str, str]]:
    digests: dict[str, dict[str, str]] = {}
    for image in map_images(image_map):
        url, repository = catalog_images_url(image)
        print(f"Fetching latest digest for {image}", file=sys.stderr)
        payload = fetch_json(
            url,
            (
                ("page_size", "100"),
                ("sort_by", "creation_date[desc]"),
                ("filter", "repositories.tags.name==latest"),
            ),
        )
        resolved = digest_from_payload(payload, repository)
        digests[image] = resolved
        print(f"  {resolved['digest']} ({resolved['published']})", file=sys.stderr)
    return digests


def parse_ref(value: str) -> dict[str, str | None] | None:
    text = value.strip()
    if not text or "$" in text or " " in text:
        return None
    digest: str | None = None
    if "@" in text:
        left, right = text.rsplit("@", 1)
        if not right.startswith("sha256:") or not HEX64.fullmatch(right[7:]):
            return None
        digest = "sha256:" + right[7:].lower()
        text = left
    if "/" not in text:
        return None
    registry, repository = text.split("/", 1)
    if not registry or not repository or "@" in repository:
        return None
    tag: str | None = None
    if ":" in repository:
        repository, tag = repository.rsplit(":", 1)
        if not repository or not tag:
            return None
    return {"registry": registry, "repository": repository, "tag": tag, "digest": digest}


def build_ref(registry: str, repository: str, tag: str | None, digest: str) -> str:
    ref = f"{registry}/{repository}"
    if tag:
        ref += f":{tag}"
    return f"{ref}@{digest}"


def split_assignment(raw: str) -> tuple[str, str, str]:
    if raw[:1] in {"'", '"'}:
        quote = raw[0]
        end = raw.find(quote, 1)
        if end != -1:
            return quote, raw[1:end], raw[end + 1 :]
    if " #" in raw:
        value, comment = raw.split(" #", 1)
        return "", value.rstrip(), " #" + comment
    return "", raw.strip(), ""


def read_text(path: Path) -> tuple[str, str]:
    raw = path.read_bytes()
    newline = "\r\n" if b"\r\n" in raw else "\n"
    text = raw.decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")
    return text, newline


def write_text(path: Path, text: str, newline: str) -> None:
    rendered = text.replace("\n", newline) if newline != "\n" else text
    path.write_bytes(rendered.encode("utf-8"))


def dockerfile_paths(root: Path) -> list[Path]:
    base = root / ".konflux" / "dockerfiles"
    if not base.is_dir():
        return []
    found: list[Path] = []
    for path in sorted(base.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        if path.name == ".placeholder" or path.name.startswith("."):
            continue
        if path.stat().st_size > 1_000_000:
            continue
        lowered = path.name.lower()
        if "dockerfile" in lowered or lowered == "containerfile":
            found.append(path)
    return found


def relative_dockerfile(root: Path, path: Path) -> str:
    return path.relative_to(root).as_posix()


def inspect_dockerfile(
    text: str,
    arg_map: Mapping[str, str],
    digests: Mapping[str, Mapping[str, str]],
    rewrite_images: bool = True,
) -> tuple[str, list[dict[str, object]]]:
    records: list[dict[str, object]] = []
    raw_lines = text.splitlines(keepends=True)
    updated_lines: list[str] = []
    for line_number, raw_line in enumerate(raw_lines, start=1):
        ending = ""
        body = raw_line
        if body.endswith("\n"):
            ending = "\n"
            body = body[:-1]
        match = ARG_RE.match(body)
        if match is None or match.group(2) not in arg_map:
            updated_lines.append(raw_line)
            continue
        arg_name = match.group(2)
        mapped_image = arg_map[arg_name]
        latest = digests[mapped_image]["digest"]
        quote, value, suffix = split_assignment(match.group(4))
        parsed = parse_ref(value)
        mapped_repository = mapped_image.split("/", 1)[1]
        if parsed is None:
            record: dict[str, object] = {
                "line": line_number,
                "arg": arg_name,
                "mapped_image": mapped_image,
                "latest_digest": latest,
                "current": value,
                "desired": value,
                "status": "UNPARSEABLE",
                "reason": "left unchanged",
                "updated": False,
            }
            updated_lines.append(raw_line)
        else:
            repo_differs = parsed["repository"] != mapped_repository
            digest_differs = parsed["digest"] != latest
            if not repo_differs and not digest_differs:
                status = "MATCH"
                reason = ""
                desired = value
            else:
                status = "MISMATCH"
                desired = build_ref(str(parsed["registry"]), mapped_repository, parsed["tag"], latest)
                if repo_differs and not rewrite_images:
                    reason = "image name mismatch; left unchanged"
                elif repo_differs and digest_differs:
                    reason = "image and digest"
                elif repo_differs:
                    reason = "image"
                else:
                    reason = "digest"
            changed = desired != value and reason != "image name mismatch; left unchanged"
            record = {
                "line": line_number,
                "arg": arg_name,
                "mapped_image": mapped_image,
                "latest_digest": latest,
                "current": value,
                "desired": desired,
                "status": status,
                "reason": reason,
                "updated": changed,
            }
            if changed:
                prefix = match.group(1) + match.group(2) + match.group(3)
                updated_lines.append(f"{prefix}{quote}{desired}{quote}{suffix}{ending}")
            else:
                updated_lines.append(raw_line)
        records.append(record)
    new_text = "".join(updated_lines)
    if text.endswith("\n") and not new_text.endswith("\n"):
        new_text += "\n"
    return new_text, records


def append_jsonl(path: Path, records: Iterable[Mapping[str, object]]) -> None:
    with path.open("a", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, sort_keys=True))
            handle.write("\n")


def base_record(component: str, org: str, image_map: Mapping[str, Mapping[str, str]]) -> dict[str, object]:
    profile = profile_for(component, image_map)
    return {
        "component": component,
        "repository": f"{org}/{component}",
        "profile": profile,
        "profile_args": list(image_map[profile]),
    }


def inspect_checkout(
    root: Path,
    component: str,
    org: str,
    image_map: Mapping[str, Mapping[str, str]],
    digests: Mapping[str, Mapping[str, str]],
    apply: bool,
    rewrite_images: bool = True,
) -> list[dict[str, object]]:
    shared = base_record(component, org, image_map)
    profile = str(shared["profile"])
    arg_map = image_map[profile]
    paths = dockerfile_paths(root)
    docker_dir = root / ".konflux" / "dockerfiles"
    if not docker_dir.is_dir() or not paths:
        return [
            {
                **shared,
                "type": "repo",
                "status": "NO_DOCKERFILES",
                "dockerfile_count": 0,
                "detail": ".konflux/dockerfiles has no Dockerfiles" if docker_dir.is_dir() else ".konflux/dockerfiles is missing",
            }
        ]
    records: list[dict[str, object]] = [
        {
            **shared,
            "type": "repo",
            "status": "SCANNED",
            "dockerfile_count": len(paths),
            "detail": "",
        }
    ]
    for path in paths:
        text, newline = read_text(path)
        updated, file_records = inspect_dockerfile(text, arg_map, digests, rewrite_images)
        relative = relative_dockerfile(root, path)
        if apply and updated != text:
            write_text(path, updated, newline)
        if not file_records:
            records.append({**shared, "type": "dockerfile", "dockerfile": relative, "status": "NO_BASE_ARGS"})
            continue
        for record in file_records:
            records.append({**shared, "type": "arg", "dockerfile": relative, **record})
    return records


def load_jsonl(path: Path) -> list[dict[str, object]]:
    if not path.is_file():
        return []
    records: list[dict[str, object]] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip():
            continue
        item = json.loads(line)
        if not isinstance(item, dict):
            raise SystemExit(f"Invalid findings record at {path}:{line_number}")
        records.append(item)
    return records


def grouped(records: Sequence[Mapping[str, object]]) -> OrderedDict[str, list[Mapping[str, object]]]:
    groups: OrderedDict[str, list[Mapping[str, object]]] = OrderedDict()
    for record in records:
        component = str(record.get("component") or "")
        groups.setdefault(component, []).append(record)
    return groups


def md(value: object) -> str:
    text = "—" if value is None or value == "" else str(value)
    return text.replace("\n", "<br>").replace("|", "\\|")


def code(value: object) -> str:
    text = "" if value is None else str(value)
    return "`" + text.replace("`", "'") + "`"


def pr_link(url: str) -> str:
    if not url:
        return "—"
    match = re.search(r"/pull/(\d+)", url)
    label = f"#{match.group(1)}" if match else "PR"
    return f"[{label}]({url})"


def component_view(records: Sequence[Mapping[str, object]]) -> dict[str, object]:
    shared = records[0]
    profile = str(shared.get("profile") or "")
    profile_args = [str(arg) for arg in shared.get("profile_args") or []]
    repository = str(shared.get("repository") or "")
    error = next(
        (
            record
            for record in records
            if record.get("type") == "component"
            and record.get("status") in {"NO_BRANCH", "QUERY_FAILED", "CLONE_FAILED", "SCAN_FAILED"}
        ),
        None,
    )
    repo = next((record for record in records if record.get("type") == "repo"), None)
    args = [record for record in records if record.get("type") == "arg"]
    plain = [str(record.get("dockerfile")) for record in records if record.get("type") == "dockerfile"]
    result = next((record for record in records if record.get("type") == "result"), None)
    present = {str(record.get("arg")) for record in args}
    missing = [arg for arg in profile_args if arg not in present]
    mismatches = [record for record in args if record.get("status") != "MATCH"]
    matches = [record for record in args if record.get("status") == "MATCH"]
    image_changes = [
        record
        for record in mismatches
        if str(record.get("reason") or "") in {"image", "image and digest"}
    ]
    kept_names = [
        record
        for record in mismatches
        if record.get("reason") == "image name mismatch; left unchanged"
    ]
    if error is not None:
        status = str(error.get("status"))
        detail = str(error.get("detail") or "")
    elif repo is not None and repo.get("status") == "NO_DOCKERFILES":
        status = "NO_DOCKERFILES"
        detail = str(repo.get("detail") or "")
    elif mismatches:
        status = "MISMATCH"
        detail = ""
    elif args and missing:
        status = "INCOMPLETE"
        detail = ""
    elif not args:
        status = "NO_BASE_ARGS"
        detail = ""
    else:
        status = "MATCH"
        detail = ""
    notes: list[str] = []
    if missing and status in {"INCOMPLETE", "MISMATCH", "NO_BASE_ARGS"}:
        notes.append("missing " + ", ".join(missing))
    if image_changes:
        count = len(image_changes)
        label = "image path change" if count == 1 else "image path changes"
        notes.append(f"{count} {label}")
    if kept_names:
        count = len(kept_names)
        label = "image name left unchanged" if count == 1 else "image names left unchanged"
        notes.append(f"{count} {label}")
    if detail:
        notes.append(detail)
    return {
        "profile": profile,
        "repository": repository,
        "status": status,
        "matches": matches,
        "mismatches": mismatches,
        "args": args,
        "plain": plain,
        "missing": missing,
        "notes": "; ".join(notes),
        "result": result,
        "dockerfile_count": int(repo.get("dockerfile_count") or 0) if repo else 0,
    }


def catalog_section(digests_path: Path) -> list[str]:
    payload = load_json(digests_path)
    images = payload.get("images")
    lines = [
        "## Catalog digests",
        "",
        "Manifest-list digests for the `latest` tag from the "
        "[Red Hat Ecosystem Catalog](https://catalog.redhat.com/en).",
        "",
        "| Image | Digest | Published |",
        "| --- | --- | --- |",
    ]
    if not isinstance(images, list) or not images:
        lines.append("| — | — | — |")
        return lines
    for image in images:
        if not isinstance(image, dict):
            continue
        lines.append(
            "| {image} | {digest} | {published} |".format(
                image=md(code(image.get("image"))),
                digest=md(code(image.get("digest"))),
                published=md(image.get("published")),
            )
        )
    return lines


def report_header(title: str, args: argparse.Namespace) -> list[str]:
    lines = [
        f"# {title}",
        "",
        f"**Generated:** {args.generated}  ",
        f"**Minor:** {args.minor}  ",
    ]
    if args.requested != args.minor:
        lines.append(f"**Version argument:** {args.requested}  ")
    lines.extend(
        [
            f"**Branch:** `{args.branch}`  ",
            f"**Image map:** `{display_path(args.map, args.repo_root)}`  ",
            f"**Components:** `{display_path(args.components, args.repo_root)}`",
            "",
            "A component that is a key in the image map uses that component's ARG list. "
            "Every other component uses `common`. The registry host and tag already written "
            "in a Dockerfile stay in place; the repository path follows the image map and "
            "the digest is the catalog manifest list.",
            "",
        ]
    )
    return lines


def display_path(path: str, root: str) -> str:
    try:
        return str(Path(path).resolve().relative_to(Path(root).resolve()))
    except ValueError:
        return path


def detail_table(args_records: Sequence[Mapping[str, object]]) -> list[str]:
    lines = [
        "| Dockerfile | Line | ARG | Current | Desired | Status | Reason |",
        "| --- | --- | --- | --- | --- | --- | --- |",
    ]
    if not args_records:
        lines.append("| — | — | — | — | — | — | — |")
        return lines
    for record in args_records:
        lines.append(
            "| {dockerfile} | {line} | {arg} | {current} | {desired} | {status} | {reason} |".format(
                dockerfile=md(code(record.get("dockerfile"))),
                line=md(record.get("line")),
                arg=md(code(record.get("arg"))),
                current=md(code(record.get("current"))),
                desired=md(code(record.get("desired"))),
                status=md(record.get("status")),
                reason=md(record.get("reason") or "—"),
            )
        )
    return lines


def write_report(path: Path, lines: Sequence[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def render_verify(args: argparse.Namespace) -> dict[str, int]:
    groups = grouped(load_jsonl(Path(args.findings)))
    lines = report_header("Base image verification", args)
    summary = ["## Summary", "", "| Component | Profile | Status | Match | Mismatch | Notes |", "| --- | --- | --- | --- | --- | --- |"]
    details: list[str] = ["## Components", ""]
    counts = {"components": 0, "match": 0, "mismatch": 0, "incomplete": 0, "errors": 0}
    for component, records in groups.items():
        view = component_view(records)
        counts["components"] += 1
        status = str(view["status"])
        if status == "MATCH":
            counts["match"] += 1
        elif status == "MISMATCH":
            counts["mismatch"] += 1
        elif status in {"INCOMPLETE", "NO_BASE_ARGS", "NO_DOCKERFILES", "NO_BRANCH"}:
            counts["incomplete"] += 1
        else:
            counts["errors"] += 1
        summary.append(
            "| {component} | {profile} | {status} | {match} | {mismatch} | {notes} |".format(
                component=md(component),
                profile=md(code(view["profile"])),
                status=md(status.replace("_", " ")),
                match=md(len(view["matches"])),
                mismatch=md(len(view["mismatches"])),
                notes=md(view["notes"] or "—"),
            )
        )
        repository = str(view["repository"])
        details.extend(
            [
                f"### {component}",
                "",
                f"Profile {code(view['profile'])}. "
                f"Repository [{repository}](https://github.com/{repository}) "
                f"on `{args.branch}`.",
                "",
            ]
        )
        details.extend(detail_table(view["args"]))
        plain = view["plain"]
        if plain:
            formatted = ", ".join(code(name.rsplit("/", 1)[-1]) for name in plain)
            details.extend(["", f"No mapped base-image ARGs in: {formatted}."])
        details.append("")
    lines.extend(summary)
    lines.append("")
    lines.extend(catalog_section(Path(args.digests)))
    lines.append("")
    lines.extend(details)
    write_report(Path(args.out), lines)
    return counts


def render_execute(args: argparse.Namespace) -> dict[str, int]:
    groups = grouped(load_jsonl(Path(args.findings)))
    lines = report_header("Base image update", args)
    lines.extend(
        [
            "## Pull requests",
            "",
            "| Component | Profile | Result | Pull request | Updates |",
            "| --- | --- | --- | --- | --- |",
        ]
    )
    counts = {"components": 0, "pull_requests": 0, "failed": 0, "current": 0}
    change_sections: list[str] = ["## Changes", ""]
    for component, records in groups.items():
        view = component_view(records)
        counts["components"] += 1
        result = view["result"] or {}
        result_status = str(result.get("status") or view["status"])
        url = str(result.get("url") or "")
        updates = [record for record in view["args"] if record.get("updated")]
        if result_status in {"PR CREATED", "PR UPDATED"}:
            counts["pull_requests"] += 1
        elif result_status in {"UP TO DATE", "MATCH"}:
            counts["current"] += 1
        else:
            counts["failed"] += 1
        lines.append(
            "| {component} | {profile} | {status} | {link} | {updates} |".format(
                component=md(component),
                profile=md(code(view["profile"])),
                status=md(result_status.replace("_", " ")),
                link=pr_link(url),
                updates=md(len(updates) if updates else "—"),
            )
        )
        change_sections.extend([f"### {component}", ""])
        if url:
            change_sections.append(f"Pull request: {pr_link(url)}")
            change_sections.append("")
        notes = [text for text in (str(result.get("detail") or ""), str(view["notes"] or "")) if text]
        if notes:
            change_sections.append(" ".join(notes))
            change_sections.append("")
        notable = [record for record in view["args"] if record.get("status") != "MATCH"]
        if notable:
            change_sections.extend(detail_table(notable))
            change_sections.append("")
        elif not notes:
            change_sections.append("No Dockerfile changes.")
            change_sections.append("")
    lines.append("")
    lines.extend(catalog_section(Path(args.digests)))
    lines.append("")
    lines.extend(change_sections)
    write_report(Path(args.out), lines)
    return counts


def print_verify_summary(counts: Mapping[str, int]) -> None:
    print(
        "Checked {components} components: {match} match, {mismatch} mismatch, "
        "{incomplete} incomplete, {errors} errors.".format(**counts),
        file=sys.stderr,
    )


def print_execute_summary(counts: Mapping[str, int]) -> None:
    print(
        "Processed {components} components: {pull_requests} pull requests, "
        "{current} up to date, {failed} not updated.".format(**counts),
        file=sys.stderr,
    )


def write_summary(path: str, counts: Mapping[str, int]) -> None:
    Path(path).write_text(json.dumps(counts, indent=2) + "\n", encoding="utf-8")


def pr_body(args: argparse.Namespace) -> str:
    records = [
        record
        for record in load_jsonl(Path(args.findings))
        if record.get("component") == args.component and record.get("type") == "arg" and record.get("updated")
    ]
    profile = profile_for(args.component, load_image_map(Path(args.map)))
    lines = [
        f"Update Konflux base image digests for `{args.branch}`.",
        "",
        "Digests are the manifest-list digest of the `latest` tag from the "
        "[Red Hat Ecosystem Catalog](https://catalog.redhat.com/en). "
        "Image repositories come from the base image map. The registry host and tag "
        "already present in each Dockerfile are preserved.",
        "",
        f"Profile: `{profile}`",
        "",
        "| Dockerfile | ARG | Current | Updated | Reason |",
        "| --- | --- | --- | --- | --- |",
    ]
    if not records:
        lines.append("| — | — | — | — | — |")
    for record in records:
        lines.append(
            "| {dockerfile} | {arg} | {current} | {updated} | {reason} |".format(
                dockerfile=md(code(record.get("dockerfile"))),
                arg=md(code(record.get("arg"))),
                current=md(code(record.get("current"))),
                updated=md(code(record.get("desired"))),
                reason=md(record.get("reason") or "—"),
            )
        )
    if any("image" in str(record.get("reason") or "") for record in records):
        lines.extend(
            [
                "",
                "At least one ARG pointed at a different repository than the image map. "
                "That repository path was changed to the mapped image.",
            ]
        )
    return "\n".join(lines).rstrip() + "\n"


def command_list_components(args: argparse.Namespace) -> None:
    for name in component_names(Path(args.components), args.minor):
        print(name)


def command_digests(args: argparse.Namespace) -> None:
    image_map = load_image_map(Path(args.map))
    try:
        resolved = fetch_digests(image_map)
    except CatalogError as exc:
        raise SystemExit(f"Unable to resolve catalog digests: {exc}") from exc
    images = [
        {"image": image, **resolved[image]}
        for image in map_images(image_map)
    ]
    destination = Path(args.out)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps({"images": images}, indent=2) + "\n", encoding="utf-8")


def command_scan_or_apply(args: argparse.Namespace, apply: bool) -> None:
    image_map = load_image_map(Path(args.map))
    digest_payload = load_json(Path(args.digests))
    digests = {
        str(item["image"]): item
        for item in digest_payload.get("images", [])
        if isinstance(item, dict) and isinstance(item.get("image"), str)
    }
    profile = image_map[profile_for(args.component, image_map)]
    missing = [image for image in profile.values() if image not in digests]
    if missing:
        raise SystemExit("Missing catalog digests for: " + ", ".join(missing))
    rewrite_images = True if not apply else getattr(args, "rewrite_images", "yes") == "yes"
    records = inspect_checkout(
        Path(args.root),
        args.component,
        args.org,
        image_map,
        digests,
        apply,
        rewrite_images,
    )
    append_jsonl(Path(args.findings), records)


def load_digest_map(path: Path) -> dict[str, dict[str, str]]:
    payload = load_json(path)
    digests: dict[str, dict[str, str]] = {}
    for item in payload.get("images", []):
        if isinstance(item, dict) and isinstance(item.get("image"), str):
            digests[str(item["image"])] = item
    return digests


def command_image_mismatches(args: argparse.Namespace) -> None:
    image_map = load_image_map(Path(args.map))
    digests = load_digest_map(Path(args.digests))
    profile = image_map[profile_for(args.component, image_map)]
    missing = [image for image in profile.values() if image not in digests]
    if missing:
        raise SystemExit("Missing catalog digests for: " + ", ".join(missing))
    records = inspect_checkout(
        Path(args.root),
        args.component,
        args.org,
        image_map,
        digests,
        False,
        True,
    )
    for record in records:
        if record.get("type") != "arg" or record.get("reason") not in {"image", "image and digest"}:
            continue
        current = parse_ref(str(record.get("current") or ""))
        mapped = str(record.get("mapped_image") or "")
        current_repo = current["repository"] if current else str(record.get("current") or "")
        mapped_repo = mapped.split("/", 1)[1] if "/" in mapped else mapped
        print(
            "\t".join(
                [
                    str(record.get("dockerfile") or ""),
                    str(record.get("line") or ""),
                    str(record.get("arg") or ""),
                    str(current_repo),
                    mapped_repo,
                    str(record.get("current") or ""),
                    str(record.get("desired") or ""),
                ]
            )
        )


def command_record(args: argparse.Namespace) -> None:
    image_map = load_image_map(Path(args.map))
    detail = " | ".join(args.detail.splitlines()[:4])[:500]
    record = {
        **base_record(args.component, args.org, image_map),
        "type": "component",
        "status": args.status,
        "detail": detail,
    }
    append_jsonl(Path(args.findings), [record])


def command_result(args: argparse.Namespace) -> None:
    record = {
        "type": "result",
        "component": args.component,
        "status": args.status,
        "url": args.url,
        "detail": " | ".join(args.detail.splitlines()[:6])[:800],
    }
    append_jsonl(Path(args.findings), [record])


def command_render_verify(args: argparse.Namespace) -> None:
    counts = render_verify(args)
    write_summary(args.summary, counts)
    print_verify_summary(counts)


def command_render_execute(args: argparse.Namespace) -> None:
    counts = render_execute(args)
    write_summary(args.summary, counts)
    print_execute_summary(counts)


def command_outcome(args: argparse.Namespace) -> None:
    records = [
        record
        for record in load_jsonl(Path(args.findings))
        if record.get("component") == args.component and record.get("type") != "result"
    ]
    if not records:
        print("UNKNOWN")
        return
    view = component_view(records)
    if any(record.get("updated") for record in view["args"]):
        print("CHANGED")
        return
    print(view["status"])


def command_pr_body(args: argparse.Namespace) -> None:
    Path(args.out).write_text(pr_body(args), encoding="utf-8")


def sample_digest(character: str) -> str:
    if len(character) != 1 or character not in "0123456789abcdef":
        raise AssertionError(character)
    return "sha256:" + character * 64


def self_check() -> None:
    payload = {
        "data": [
            {
                "creation_date": "2026-11-01T00:00:00+00:00",
                "repositories": [
                    {
                        "repository": "ubi9/go-toolset",
                        "manifest_list_digest": sample_digest("a"),
                        "tags": [{"name": "latest"}],
                    }
                ],
            },
            {
                "creation_date": "2026-11-09T00:00:00+00:00",
                "repositories": [
                    {
                        "repository": "rhel9/go-toolset",
                        "manifest_list_digest": sample_digest("b"),
                        "tags": [{"name": "latest"}],
                    },
                    {
                        "repository": "ubi9/go-toolset",
                        "manifest_list_digest": sample_digest("c"),
                        "tags": [{"name": "latest"}, {"name": "9.8"}],
                    },
                ],
            },
        ]
    }
    resolved = digest_from_payload(payload, "ubi9/go-toolset")
    assert resolved["digest"] == sample_digest("c"), resolved
    try:
        digest_from_payload({"data": []}, "ubi9/go-toolset")
    except CatalogError:
        pass
    else:
        raise AssertionError("empty catalog payload should fail")

    old_go = sample_digest("1")
    new_go = sample_digest("2")
    old_ubi = sample_digest("3")
    new_ubi = sample_digest("4")
    node = "sha256:18efae02a19cdfbda303ff98d096cfcc2e123f300aff146e7dab1e75b9116dec"
    nginx = "sha256:d5cec86a9adf972dbfa0d87b134e7c404706cc1920fc2e6a2b146e290276f219"
    arg_map = {
        "GO_BUILDER": "registry.access.redhat.com/ubi9/go-toolset",
        "UBI_RUNTIME": "registry.access.redhat.com/ubi9/ubi-minimal",
        "BUILDER": "registry.access.redhat.com/ubi9/nodejs-22",
        "NGX_RUNTIME": "registry.access.redhat.com/ubi9/nginx-124",
    }
    digests = {
        image: {"digest": digest, "published": "t", "tag": "latest"}
        for image, digest in {
            arg_map["GO_BUILDER"]: new_go,
            arg_map["UBI_RUNTIME"]: new_ubi,
            arg_map["BUILDER"]: node,
            arg_map["NGX_RUNTIME"]: nginx,
        }.items()
    }
    docker = "\n".join(
        [
            f"ARG GO_BUILDER=registry.redhat.io/ubi9/go-toolset:latest@{old_go}",
            f"ARG UBI_RUNTIME=registry.redhat.io/ubi9/ubi-minimal-pqc:latest@{old_ubi}",
            f"ARG BUILDER=registry.redhat.io/ubi9/nodejs-22@{node}",
            f'ARG NGX_RUNTIME="registry.access.redhat.com/ubi9/nginx-124@{nginx}"',
            "ARG NJS_BUILDER=registry.access.redhat.com/ubi9/nodejs-24:latest@sha256:" + "e" * 64,
            "FROM $GO_BUILDER",
            "",
        ]
    )
    updated, records = inspect_dockerfile(docker, arg_map, digests)
    by_arg = {str(record["arg"]): record for record in records}
    assert by_arg["GO_BUILDER"]["status"] == "MISMATCH"
    assert by_arg["GO_BUILDER"]["desired"] == f"registry.redhat.io/ubi9/go-toolset:latest@{new_go}"
    assert by_arg["UBI_RUNTIME"]["reason"] == "image and digest"
    assert by_arg["UBI_RUNTIME"]["desired"] == f"registry.redhat.io/ubi9/ubi-minimal:latest@{new_ubi}"
    assert by_arg["BUILDER"]["status"] == "MATCH"
    assert by_arg["BUILDER"]["updated"] is False
    assert by_arg["NGX_RUNTIME"]["status"] == "MATCH"
    assert "NJS_BUILDER" not in by_arg
    assert f"registry.redhat.io/ubi9/go-toolset:latest@{new_go}" in updated
    assert updated.splitlines()[3].startswith('ARG NGX_RUNTIME="registry.access.redhat.com/')
    assert "FROM $GO_BUILDER" in updated

    kept, kept_records = inspect_dockerfile(docker, arg_map, digests, rewrite_images=False)
    kept_by_arg = {str(record["arg"]): record for record in kept_records}
    assert kept_by_arg["UBI_RUNTIME"]["updated"] is False
    assert kept_by_arg["UBI_RUNTIME"]["reason"] == "image name mismatch; left unchanged"
    assert "ubi-minimal-pqc" in kept
    assert kept_by_arg["GO_BUILDER"]["updated"] is True
    assert f"go-toolset:latest@{new_go}" in kept

    commented = "ARG GO_BUILDER=registry.redhat.io/ubi9/go-toolset:latest@" + old_go + " # pin\n"
    commented_updated, commented_records = inspect_dockerfile(
        commented, {"GO_BUILDER": arg_map["GO_BUILDER"]}, digests
    )
    assert commented_records[0]["updated"] is True
    assert commented_updated.endswith(" # pin\n")

    variable = "ARG GO_BUILDER=$GO_BUILDER\n"
    variable_updated, variable_records = inspect_dockerfile(
        variable, {"GO_BUILDER": arg_map["GO_BUILDER"]}, digests
    )
    assert variable_updated == variable
    assert variable_records[0]["status"] == "UNPARSEABLE"

    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        docker_dir = root / ".konflux" / "dockerfiles"
        docker_dir.mkdir(parents=True)
        (docker_dir / ".placeholder").write_text("ignore\n", encoding="utf-8")
        (docker_dir / "controller.Dockerfile").write_text(docker, encoding="utf-8")
        image_map = OrderedDict(
            [
                ("common", OrderedDict([("GO_BUILDER", arg_map["GO_BUILDER"]), ("UBI_RUNTIME", arg_map["UBI_RUNTIME"])])),
                (
                    "p12n-console-plugin",
                    OrderedDict([("BUILDER", arg_map["BUILDER"]), ("NGX_RUNTIME", arg_map["NGX_RUNTIME"])]),
                ),
            ]
        )
        full_digests = {image: {"digest": item["digest"], "published": "t", "tag": "latest"} for image, item in digests.items()}
        plugin_records = inspect_checkout(root, "p12n-console-plugin", ORG_DEFAULT, image_map, full_digests, True)
        plugin_args = [record for record in plugin_records if record["type"] == "arg"]
        assert {record["arg"] for record in plugin_args} == {"BUILDER", "NGX_RUNTIME"}
        assert all(record["status"] == "MATCH" for record in plugin_args)
        rewritten = (docker_dir / "controller.Dockerfile").read_text(encoding="utf-8")
        assert rewritten == docker

        kept_checkout = inspect_checkout(root, "operator", ORG_DEFAULT, image_map, full_digests, True, False)
        assert any(
            record.get("arg") == "UBI_RUNTIME" and record.get("reason") == "image name mismatch; left unchanged"
            for record in kept_checkout
        )
        kept_text = (docker_dir / "controller.Dockerfile").read_text(encoding="utf-8")
        assert "ubi-minimal-pqc" in kept_text
        assert f"go-toolset:latest@{new_go}" in kept_text

        (docker_dir / "controller.Dockerfile").write_text(docker, encoding="utf-8")
        common_records = inspect_checkout(root, "operator", ORG_DEFAULT, image_map, full_digests, True)
        assert any(record.get("arg") == "UBI_RUNTIME" and record.get("updated") for record in common_records)
        assert "ubi-minimal:latest@" + new_ubi in (docker_dir / "controller.Dockerfile").read_text(encoding="utf-8")
        assert "ubi-minimal-pqc" not in (docker_dir / "controller.Dockerfile").read_text(encoding="utf-8")
    print("self-check ok", file=sys.stderr)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Update or verify Konflux base image digests.")
    sub = parser.add_subparsers(dest="command", required=True)

    list_cmd = sub.add_parser("list-components")
    list_cmd.add_argument("--components", required=True)
    list_cmd.add_argument("--minor", required=True)
    list_cmd.set_defaults(func=command_list_components)

    digests_cmd = sub.add_parser("digests")
    digests_cmd.add_argument("--map", required=True)
    digests_cmd.add_argument("--out", required=True)
    digests_cmd.set_defaults(func=command_digests)

    for name, apply in (("scan", False), ("apply", True)):
        scan_cmd = sub.add_parser(name)
        scan_cmd.add_argument("--findings", required=True)
        scan_cmd.add_argument("--map", required=True)
        scan_cmd.add_argument("--digests", required=True)
        scan_cmd.add_argument("--org", default=ORG_DEFAULT)
        scan_cmd.add_argument("--root", required=True)
        scan_cmd.add_argument("--component", required=True)
        scan_cmd.add_argument("--rewrite-images", choices=("yes", "no"), default="yes")
        scan_cmd.set_defaults(func=lambda parsed, apply=apply: command_scan_or_apply(parsed, apply))

    record_cmd = sub.add_parser("record")
    record_cmd.add_argument("--findings", required=True)
    record_cmd.add_argument("--map", required=True)
    record_cmd.add_argument("--org", default=ORG_DEFAULT)
    record_cmd.add_argument("--component", required=True)
    record_cmd.add_argument("--status", required=True)
    record_cmd.add_argument("--detail", default="")
    record_cmd.set_defaults(func=command_record)

    result_cmd = sub.add_parser("result")
    result_cmd.add_argument("--findings", required=True)
    result_cmd.add_argument("--component", required=True)
    result_cmd.add_argument("--status", required=True)
    result_cmd.add_argument("--url", default="")
    result_cmd.add_argument("--detail", default="")
    result_cmd.set_defaults(func=command_result)

    for name, func in (("render-verify", command_render_verify), ("render-execute", command_render_execute)):
        render_cmd = sub.add_parser(name)
        render_cmd.add_argument("--findings", required=True)
        render_cmd.add_argument("--digests", required=True)
        render_cmd.add_argument("--map", required=True)
        render_cmd.add_argument("--components", required=True)
        render_cmd.add_argument("--repo-root", required=True)
        render_cmd.add_argument("--generated", required=True)
        render_cmd.add_argument("--requested", required=True)
        render_cmd.add_argument("--minor", required=True)
        render_cmd.add_argument("--branch", required=True)
        render_cmd.add_argument("--out", required=True)
        render_cmd.add_argument("--summary", required=True)
        render_cmd.set_defaults(func=func)

    mismatch_cmd = sub.add_parser("image-mismatches")
    mismatch_cmd.add_argument("--map", required=True)
    mismatch_cmd.add_argument("--digests", required=True)
    mismatch_cmd.add_argument("--org", default=ORG_DEFAULT)
    mismatch_cmd.add_argument("--root", required=True)
    mismatch_cmd.add_argument("--component", required=True)
    mismatch_cmd.set_defaults(func=command_image_mismatches)

    outcome_cmd = sub.add_parser("outcome")
    outcome_cmd.add_argument("--findings", required=True)
    outcome_cmd.add_argument("--component", required=True)
    outcome_cmd.set_defaults(func=command_outcome)

    body_cmd = sub.add_parser("pr-body")
    body_cmd.add_argument("--findings", required=True)
    body_cmd.add_argument("--map", required=True)
    body_cmd.add_argument("--component", required=True)
    body_cmd.add_argument("--branch", required=True)
    body_cmd.add_argument("--out", required=True)
    body_cmd.set_defaults(func=command_pr_body)

    check_cmd = sub.add_parser("self-check")
    check_cmd.set_defaults(func=lambda _args: self_check())
    return parser


def main(argv: Sequence[str] | None = None) -> None:
    parser = build_parser()
    args = parser.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
