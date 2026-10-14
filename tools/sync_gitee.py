"""Mirror approved public source/releases without deleting or rebuilding assets."""
import base64
import argparse
import hashlib
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile

import requests

ROOT = Path(__file__).resolve().parents[1]
GH = 'https://api.github.com/repos/memetics1980/lumalex-desktop'
GT = 'https://gitee.com/api/v5/repos/memetics/lumalex-desktop'
REMOTE = 'https://gitee.com/memetics/lumalex-desktop.git'
GITEE_FIRST_BUILD = 96


def release_build(value):
    match = re.match(r'^(?:v|LumaLex-)\d+(?:\.\d+)+-build(\d+)(?:[-.]|$)', value)
    return int(match.group(1)) if match else None


def gitee_release(source):
    """Keep pre-96 packages and their archive notices on GitHub only."""
    build = release_build(source['tag_name'])
    if build is not None and build < GITEE_FIRST_BUILD:
        raise RuntimeError('Gitee releases start with build 96; older releases stay on GitHub')
    assets = []
    for item in source['assets']:
        name = asset_name(item['name'])
        build = release_build(name)
        if build is None or build >= GITEE_FIRST_BUILD:
            assets.append(item)
    body = source['body'] or ''
    notices = (
        r'本页也保留先前的 macOS build (\d+) 附件；升级请选择文件名含 `build\d+` 的安装包。\s*',
        r'Previous macOS build (\d+) assets are retained on this page; '
        r'choose filenames containing `build\d+` to upgrade\.\s*',
    )
    for notice in notices:
        body = re.sub(notice, lambda m: '' if int(m.group(1)) < GITEE_FIRST_BUILD
                      else m.group(0), body)
    return {**source, 'assets': assets, 'body': body}


def local_gitee_token():
    token = os.environ.get('GITEE_TOKEN', '').strip()
    if token:
        return token
    for name in ('gitee_token.txt', 'gitee-token.txt'):
        path = ROOT / '.toolchains' / name
        if path.is_file():
            token = path.read_text(encoding='utf-8-sig').strip()
            if token:
                return token
    return ''


def asset_name(name):
    if not name or name in {'.', '..'} or '/' in name or '\\' in name or '\x00' in name:
        raise ValueError('Unsafe release asset name')
    return name


def verify_file(path, size, digest=None):
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if path.stat().st_size != size or (digest and actual != digest.removeprefix('sha256:')):
        raise RuntimeError('Release asset size or digest mismatch: ' + path.name)
    return actual


class Mirror:
    def __init__(self, token, github_token=''):
        if not token:
            raise RuntimeError('Gitee token is required in GITEE_TOKEN or an ignored local token file')
        self.token = token
        self.gt = requests.Session()
        self.gt.headers.update({'Authorization': 'Bearer ' + token, 'User-Agent': 'LumaLex-mirror'})
        self.gh = requests.Session()
        self.gh.headers.update({'User-Agent': 'LumaLex-mirror', 'Accept': 'application/vnd.github+json'})
        if github_token:
            self.gh.headers['Authorization'] = 'Bearer ' + github_token

    def request(self, session, method, url, **kwargs):
        response = session.request(method, url, timeout=(30, 300), **kwargs)
        if not response.ok:
            raise RuntimeError(f'{method} failed with HTTP {response.status_code}: ' +
                               response.text[:1000].replace(self.token, '[redacted]'))
        return response

    def git(self, *args):
        env = os.environ.copy()
        for name in ('GIT_TRACE', 'GIT_TRACE_CURL', 'GIT_CURL_VERBOSE'):
            env.pop(name, None)
        env['GIT_TERMINAL_PROMPT'] = '0'
        offset = int(env.get('GIT_CONFIG_COUNT', '0'))
        for key, value in (
            ('credential.helper', ''),
            ('http.https://gitee.com/.extraHeader', 'Authorization: Basic ' +
             base64.b64encode(('memetics:' + self.token).encode()).decode()),
        ):
            env[f'GIT_CONFIG_KEY_{offset}'] = key
            env[f'GIT_CONFIG_VALUE_{offset}'] = value
            offset += 1
        env['GIT_CONFIG_COUNT'] = str(offset)
        result = subprocess.run(['git', *args], cwd=ROOT, env=env, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError('Git synchronization failed: ' +
                               result.stderr.replace(self.token, '[redacted]'))
        return result.stdout.strip()

    def sync_code(self):
        self.git('fetch', 'origin', 'main')
        expected = self.git('rev-parse', 'refs/remotes/origin/main')
        self.git('push', REMOTE, 'refs/remotes/origin/main:refs/heads/main')
        remote = self.git('ls-remote', REMOTE, 'refs/heads/main').split()[0]
        if remote != expected:
            raise RuntimeError('Main commit mismatch after sync')
        print('Both main branches match: ' + expected, flush=True)

    def download(self, session, url, path):
        response = self.request(session, 'GET', url, stream=True)
        with path.open('wb') as output:
            for chunk in response.iter_content(1024 * 1024):
                output.write(chunk)

    def sync_release(self, tag):
        endpoint = '/releases/latest' if tag == 'latest' else '/releases/tags/' + requests.utils.quote(tag, safe='')
        source = self.request(self.gh, 'GET', GH + endpoint).json()
        if source['draft']:
            raise RuntimeError('Draft releases must not be mirrored')
        source = gitee_release(source)
        tag = source['tag_name']
        self.git('fetch', 'origin', 'refs/tags/' + tag + ':refs/tags/' + tag)
        commit = self.git('rev-parse', 'refs/tags/' + tag + '^{commit}')
        self.git('push', REMOTE, 'refs/tags/' + tag + ':refs/tags/' + tag)
        releases = self.request(self.gt, 'GET', GT + '/releases', params={'per_page': 100}).json()
        target = next((r for r in releases if r['tag_name'] == tag), None)
        payload = {'tag_name': tag, 'target_commitish': commit, 'name': source['name'],
                   'body': source['body'] or '', 'prerelease': source['prerelease']}
        if target:
            existing = self.request(self.gt, 'GET',
                f"{GT}/releases/{target['id']}/attach_files", params={'per_page': 100}).json()
            names = {asset_name(a['name']) for a in source['assets']}
            if any(a['name'] not in names for a in existing):
                raise RuntimeError('Gitee has extra attachments; inspect before removing any file')
            target = self.request(self.gt, 'PATCH',
                f"{GT}/releases/{target['id']}", json=payload).json()
        else:
            target = self.request(self.gt, 'POST', GT + '/releases', json=payload).json()
            existing = []
        attach_url = f"{GT}/releases/{target['id']}/attach_files"
        # Source archives generated by hosting services are not release attachments.
        with tempfile.TemporaryDirectory(prefix='lumalex-mirror-') as temporary:
            for source_asset in source['assets']:
                name = asset_name(source_asset['name'])
                original = Path(temporary) / name
                # Public download hosts need no API credentials.
                with requests.Session() as downloads:
                    self.download(downloads, source_asset['browser_download_url'], original)
                digest = verify_file(original, source_asset['size'], source_asset.get('digest'))
                attached = next((a for a in existing if a['name'] == name), None)
                if attached is None:
                    with original.open('rb') as stream:
                        attached = self.request(self.gt, 'POST', attach_url,
                            files={'file': (name, stream, 'application/octet-stream')}).json()
                copied = Path(temporary) / ('verified-' + name)
                self.download(self.gt, f"{attach_url}/{attached['id']}/download", copied)
                verify_file(copied, source_asset['size'], digest)
                print('Verified mirrored asset: ' + name, flush=True)
                original.unlink()
                copied.unlink()
        final = self.request(self.gt, 'GET',
                             GT + '/releases/tags/' + requests.utils.quote(tag, safe='')).json()
        for field in ('tag_name', 'name', 'body', 'prerelease'):
            if final[field] != payload[field]:
                raise RuntimeError('Release metadata mismatch: ' + field)
        files = self.request(self.gt, 'GET', attach_url, params={'per_page': 100}).json()
        if sorted(a['name'] for a in files) != sorted(a['name'] for a in source['assets']):
            raise RuntimeError('Release attachment set mismatch')
        print('Release metadata and all attachment bytes match: ' + tag, flush=True)


if __name__ == '__main__':
    token = ''
    try:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('--release-tag', default=os.environ.get('RELEASE_TAG', ''),
                            help='Accepted release tag, latest, or empty for code only')
        args = parser.parse_args()
        token = local_gitee_token()
        mirror = Mirror(token, os.environ.get('GITHUB_TOKEN', ''))
        mirror.sync_code()
        if args.release_tag:
            mirror.sync_release(args.release_tag)
    except Exception as error:
        message = str(error)
        for secret in (token, os.environ.get('GITHUB_TOKEN')):
            if secret:
                message = message.replace(secret, '[redacted]')
        print(message, file=sys.stderr)
        sys.exit(1)
