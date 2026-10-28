#!/usr/bin/env python3
"""Static trust checks for the GitHub workflows. Runs offline; no YAML library.

Pull-request CI must stay read-only and secret-free. The release workflow must
stay gated off by default, follow only successful CI pushes on main after the
owner's activation boundary, keep the signing key inside the single signing
step of its two signing jobs, require Stable approval before signing, keep
Preview releases off GitHub Latest, use standard runners and pin every action
to a full commit SHA.

This is a text-level guard, not a proof of workflow semantics; review still
covers what the steps actually do. Prints file:line findings and exits 1 when
anything is found.
"""
import re
import sys
from pathlib import Path

WORKFLOWS = Path('.github/workflows')
PR_WORKFLOWS = ['ci.yml', 'pr-title.yml']
RELEASE = 'release.yml'
SIGNING_SECRET = 'secrets.QUOTABAR_UPDATE_SIGNING_KEY'
SIGNING_JOBS = {'sign-and-publish-preview', 'sign-and-publish-stable'}
STANDARD_RUNNERS = {'macos-15', 'macos-latest', 'ubuntu-latest'}
ALLOWED_WRITES = {
    'sign-and-publish-preview': {'contents'},
    'sign-and-publish-stable': {'contents'},
    'deploy-feeds': {'pages', 'id-token'},
}
GATE = "vars.QUOTABAR_PUBLISHING == 'enabled'"
REPOSITORY_GATE = "github.repository == 'YogevSitton/quotabar'"
PINNED = re.compile(r'uses:\s*[\w.-]+/[\w./-]+@[0-9a-f]{40}(\s|$)')


def strip_comment(line):
    return line.split(' #', 1)[0] if not line.lstrip().startswith('#') else ''


def jobs_of(lines):
    """Returns {job: (start, end)} line ranges for jobs under the top-level jobs key."""
    jobs, current, start, inside = {}, None, 0, False
    for number, line in enumerate(lines):
        if re.match(r'^\S', line):
            if current:
                jobs[current] = (start, number)
                current = None
            inside = line.startswith('jobs:')
            continue
        match = re.match(r'^  ([A-Za-z0-9_-]+):\s*$', line)
        if inside and match:
            if current:
                jobs[current] = (start, number)
            current, start = match.group(1), number
    if current:
        jobs[current] = (start, len(lines))
    return jobs


def steps_of(lines, start, end):
    """Returns [(start, end)] ranges of the steps inside one job."""
    starts = [n for n in range(start, end) if re.match(r'^      - ', lines[n])]
    return [(s, starts[i + 1] if i + 1 < len(starts) else end) for i, s in enumerate(starts)]


def text(lines, start, end):
    return '\n'.join(strip_comment(line) for line in lines[start:end])


def common(name, lines, problems):
    for number, line in enumerate(lines, 1):
        code = strip_comment(line)
        if 'uses:' in code and not PINNED.search(code):
            problems.append(f'{name}:{number}: action is not pinned to a full commit SHA')
        match = re.search(r'runs-on:\s*(\S+)', code)
        if match and match.group(1) not in STANDARD_RUNNERS:
            problems.append(f'{name}:{number}: runner {match.group(1)} is not a standard free runner')
        if 'pull_request_target' in code:
            problems.append(f'{name}:{number}: pull_request_target is not allowed')


def check_pr_workflow(name, lines, problems):
    for number, line in enumerate(lines, 1):
        code = strip_comment(line)
        if 'secrets.' in code:
            problems.append(f'{name}:{number}: pull-request workflows must not reference secrets')
        if re.search(r':\s*write\b', code):
            problems.append(f'{name}:{number}: pull-request workflows must stay read-only')
        if 'QUOTABAR_UPDATE_SIGNING_KEY' in code or 'QUOTABAR_RELEASE_BUILD' in code:
            problems.append(f'{name}:{number}: pull-request workflows must not sign or build releases')


def check_release(lines, problems):
    name = RELEASE
    triggers = []
    inside = False
    for number, line in enumerate(lines, 1):
        if re.match(r'^\S', line):
            inside = line.startswith('on:')
        elif inside:
            triggers.append((number, strip_comment(line)))
    for number, code in triggers:
        if 'pull_request' in code or re.search(r'^\s{2}push:', code):
            problems.append(f'{name}:{number}: the release workflow must not run on pushes or pull requests directly')
    if 'permissions: {}' not in [line.rstrip() for line in lines]:
        problems.append(f'{name}: top-level permissions must be {{}}')

    jobs = jobs_of(lines)
    expected = {'build-preview', 'sign-and-publish-preview', 'approve-stable', 'sign-and-publish-stable', 'deploy-feeds'}
    if set(jobs) != expected:
        problems.append(f'{name}: jobs must be exactly {sorted(expected)}, found {sorted(jobs)}')
    for job, (start, end) in jobs.items():
        body = text(lines, start, end)
        if GATE not in body or REPOSITORY_GATE not in body:
            problems.append(f'{name}:{start + 1}: job {job} lacks the QUOTABAR_PUBLISHING and repository gates')
        environment = re.findall(r'^    environment:\s*(\S+)', body, re.M)
        if job in SIGNING_JOBS and environment != ['release-signing']:
            problems.append(f'{name}:{start + 1}: job {job} must use environment release-signing')
        if job not in SIGNING_JOBS and 'release-signing' in body:
            problems.append(f'{name}:{start + 1}: only the two signing jobs may use release-signing')
        if job == 'approve-stable' and environment != ['stable-approval']:
            problems.append(f'{name}:{start + 1}: approve-stable must use environment stable-approval')
        if job != 'approve-stable' and 'stable-approval' in body:
            problems.append(f'{name}:{start + 1}: only approve-stable may use stable-approval')
        writes = set(re.findall(r'^      ([a-z-]+):\s*write\b', body, re.M))
        if not writes <= ALLOWED_WRITES.get(job, set()):
            problems.append(f'{name}:{start + 1}: job {job} requests write access to {sorted(writes)}')
        if job in SIGNING_JOBS:
            if re.search(r'\bswift\b', body) or 'actions/checkout' in body:
                problems.append(f'{name}:{start + 1}: signing job {job} must not check out or compile code')
            signing_steps = [s for s, e in steps_of(lines, start, end) if SIGNING_SECRET in text(lines, s, e)]
            if len(signing_steps) != 1:
                problems.append(f'{name}:{start + 1}: job {job} must reference the signing key in exactly one step')
            for s in signing_steps:
                step_end = next(e for b, e in steps_of(lines, start, end) if b == s)
                if 'QuotaReleaseTool sign ' not in text(lines, s, step_end):
                    problems.append(f'{name}:{s + 1}: the signing key may only reach the QuotaReleaseTool sign step')
    for number, line in enumerate(lines, 1):
        code = strip_comment(line)
        for reference in re.findall(r'secrets\.[A-Za-z0-9_]+', code):
            owner = next((job for job, (s, e) in jobs.items() if s < number <= e), None)
            if reference != SIGNING_SECRET or owner not in SIGNING_JOBS:
                problems.append(f'{name}:{number}: {reference} is not allowed here')

    if 'build-preview' in jobs:
        body = text(lines, *jobs['build-preview'])
        for required in ['vars.QUOTABAR_PREVIEW_SINCE', "github.event.workflow_run.conclusion == 'success'",
                         "github.event.workflow_run.event == 'push'", "github.event.workflow_run.head_branch == 'main'",
                         'github.event.workflow_run.head_repository.full_name == github.repository',
                         'QUOTABAR_RELEASE_BUILD']:
            if required not in body:
                problems.append(f'{name}: build-preview lacks {required}')
    if 'sign-and-publish-preview' in jobs:
        body = text(lines, *jobs['sign-and-publish-preview'])
        create = [line for line in body.splitlines() if 'gh release create' in line]
        edit = [line for line in body.splitlines() if 'gh release edit' in line]
        if not create or not all('--prerelease' in line and '--latest=false' in line for line in create + edit) or not edit:
            problems.append(f'{name}: Preview releases must be created and published as prereleases with --latest=false')
    if 'sign-and-publish-stable' in jobs:
        body = text(lines, *jobs['sign-and-publish-stable'])
        if not re.search(r'^    needs:\s*\[?\s*approve-stable', body, re.M):
            problems.append(f'{name}: sign-and-publish-stable must need approve-stable')
    if 'approve-stable' in jobs:
        body = text(lines, *jobs['approve-stable'])
        if "github.actor == github.repository_owner" not in body or "github.ref == 'refs/heads/main'" not in body:
            problems.append(f'{name}: approve-stable must be limited to the owner on main')


def main():
    problems = []
    for name in PR_WORKFLOWS + [RELEASE]:
        path = WORKFLOWS / name
        if not path.is_file():
            problems.append(f'{path}: missing')
            continue
        lines = path.read_text(encoding='utf-8').splitlines()
        common(name, lines, problems)
        if name == RELEASE:
            check_release(lines, problems)
        else:
            check_pr_workflow(name, lines, problems)
    for path in sorted(WORKFLOWS.glob('*.y*ml')):
        if path.name not in PR_WORKFLOWS + [RELEASE]:
            problems.append(f'{path}: unreviewed workflow; add its trust rules to this checker')
    for problem in problems:
        print(problem)
    if problems:
        print(f'Workflow trust check failed: {len(problems)} finding(s).')
        return 1
    print('Workflow trust check passed.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
