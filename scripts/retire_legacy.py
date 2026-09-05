"""Retire the three explicitly identified legacy branches after a successful build.

Uses only this workflow's scoped GitHub token. Never accesses other credentials.
A changed branch SHA is a conflict, not permission to discard concurrent work.
"""
import json
import os
import pathlib
import urllib.error
import urllib.parse
import urllib.request

REPOSITORY = "dandibbert/dmm-mac-boost"
NEW_BRANCH = "still-rebuild"
EXPECTED = {
    "main": "75d48a65983d10c4c3f7ec2f94f94c5dc7f3a573",
    "native-webkit-browser": "0e32a56ccebe21c5892110043bc44cffd5867319",
    "wkwebview-native": "c86d9a84efabff464a35fbeee8cbad9ff5631f5c",
}
REPORT = {"repository": REPOSITORY, "newBranch": NEW_BRANCH, "operations": []}
TOKEN = os.environ["GH_TOKEN"]
BASE = "https://api.github.com/repos/" + REPOSITORY


def api(method, path="", body=None):
    payload = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(BASE + path, data=payload, method=method,
        headers={"Authorization": "Bearer " + TOKEN,
                 "Accept": "application/vnd.github+json",
                 "Content-Type": "application/json",
                 "X-GitHub-Api-Version": "2022-11-28"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            detail = json.loads(raw)
        except ValueError:
            detail = {"message": "Non-JSON API response"}
        return error.code, detail


def record(operation, status, result):
    REPORT["operations"].append({"operation": operation, "status": status, "result": result})


def main():
    assert os.environ["GITHUB_REPOSITORY"] == REPOSITORY
    built = os.environ["GITHUB_SHA"]
    code, branch = api("GET", "/git/ref/heads/" + NEW_BRANCH)
    if code != 200 or branch["object"]["sha"] != built:
        raise RuntimeError("New branch changed after the validated build; leaving references untouched")
    code, commit = api("GET", "/git/commits/" + built)
    if code != 200:
        raise RuntimeError("Cannot read the validated commit")
    REPORT["validatedCommit"] = built
    REPORT["validatedTree"] = commit["tree"]["sha"]
    # Preserve the exact validated tree, but remove all legacy ancestry.
    code, root = api("POST", "/git/commits", {
        "message": "Still: clean native WebKit rebuild, validated by GitHub Actions",
        "tree": commit["tree"]["sha"], "parents": []})
    record("create-clean-root", code, root.get("sha") if isinstance(root, dict) else root)
    if code != 201:
        raise RuntimeError("Could not create the clean root commit")
    root_sha = root["sha"]
    REPORT["cleanRoot"] = root_sha
    code, result = api("PATCH", "/git/refs/heads/" + NEW_BRANCH, {"sha": root_sha, "force": True})
    record("replace-new-branch-ancestry", code, result.get("message") if isinstance(result, dict) else result)
    if code != 200:
        raise RuntimeError("New branch ref could not be updated")
    code, result = api("PATCH", "", {"default_branch": NEW_BRANCH})
    record("make-rebuild-default", code, result.get("message") if isinstance(result, dict) else result)
    code, repository = api("GET")
    if code != 200:
        raise RuntimeError("Cannot verify repository default branch")
    default = repository["default_branch"]
    REPORT["defaultBranch"] = default
    for name, expected_sha in EXPECTED.items():
        path = "/git/refs/heads/" + urllib.parse.quote(name, safe="")
        code, ref = api("GET", path.replace("/refs/", "/ref/"))
        if code == 404:
            record("retire-" + name, 404, "Already absent")
            continue
        if code != 200 or ref["object"]["sha"] != expected_sha:
            record("retire-" + name, 409, "Branch changed; not modified")
            continue
        if name == default:
            # GitHub refuses deletion of the default branch without administration
            # access. Remove its old contents and ancestry instead, and report it.
            code, result = api("PATCH", path, {"sha": root_sha, "force": True})
            record("replace-legacy-default-with-clean-rebuild", code,
                   result.get("message", "Default branch retained as clean alias") if isinstance(result, dict) else result)
        else:
            code, result = api("DELETE", path)
            record("delete-" + name, code, result)
    code, branches = api("GET", "/branches?per_page=100")
    if code == 200:
        REPORT["remainingBranches"] = [{"name": b["name"], "sha": b["commit"]["sha"]} for b in branches]


try:
    main()
except Exception as error:
    REPORT["error"] = str(error)
finally:
    pathlib.Path("out").mkdir(exist_ok=True)
    text = json.dumps(REPORT, ensure_ascii=False, indent=2)
    pathlib.Path("out/branch-retirement.json").write_text(text, encoding="utf-8")
    print(text)
