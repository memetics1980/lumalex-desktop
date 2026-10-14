"""Checks for mirror safety failures and repeatable publication."""
import hashlib
import os
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

from sync_gitee import Mirror, asset_name, gitee_release, local_gitee_token, verify_file


class Reply:
    ok = True

    def __init__(self, value):
        self.value = value

    def json(self):
        return self.value


class MirrorTests(unittest.TestCase):
    def test_gitee_excludes_pre96_assets_and_archive_notices_only(self):
        names = ['LumaLex-0.1.0-build94-macos-universal.dmg',
                 'LumaLex-0.1.0-build94-macos-universal.zip.sha256.txt',
                 'LumaLex-0.1.0-build96-macos-universal.zip',
                 'LumaLex-0.1.0-build96-windows-x64-portable.zip.sha256.txt',
                 'LICENSE.txt']
        body = ('Windows build 96 · macOS build 96\n\n'
                '本页也保留先前的 macOS build 94 附件；升级请选择文件名含 `build96` 的安装包。\n\n'
                '每个安装包均附带校验文件。\n\n'
                'Previous macOS build 94 assets are retained on this page; '
                'choose filenames containing `build96` to upgrade. Each package has a checksum.')
        source = {'tag_name': 'v0.1.0-build96', 'assets': [{'name': n} for n in names],
                  'body': body}
        result = gitee_release(source)
        self.assertEqual([a['name'] for a in result['assets']], names[2:])
        self.assertNotIn('build 94', result['body'])
        self.assertIn('每个安装包均附带校验文件。', result['body'])
        self.assertIn('Each package has a checksum.', result['body'])
        self.assertEqual(source['body'], body)
        self.assertEqual(len(source['assets']), 5)

    def test_pre96_release_is_rejected_before_git_or_gitee_mutations(self):
        mirror = Mirror('test-token')
        source = {'draft': False, 'tag_name': 'v0.1.0-build94', 'assets': [], 'body': ''}
        with patch.object(mirror, 'request', return_value=Reply(source)) as calls, \
             patch.object(mirror, 'git') as git:
            with self.assertRaisesRegex(RuntimeError, 'start with build 96'):
                mirror.sync_release('v0.1.0-build94')
        git.assert_not_called()
        self.assertEqual(len(calls.call_args_list), 1)

    def test_build96_and_later_archive_notices_are_preserved(self):
        body = ('Previous macOS build 96 assets are retained on this page; '
                'choose filenames containing `build97` to upgrade. Current notes.')
        source = {'tag_name': 'v0.1.0-build97', 'body': body,
                  'assets': [{'name': 'LumaLex-0.1.0-build96-macos-universal.zip'}]}
        self.assertEqual(gitee_release(source), source)

    def test_local_token_reads_bom_and_alternate_filename(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.toolchains').mkdir()
            (root / '.toolchains/gitee-token.txt').write_text(' file-token\n', encoding='utf-8-sig')
            with patch('sync_gitee.ROOT', root), patch.dict(os.environ, {'GITEE_TOKEN': ''}):
                self.assertEqual(local_gitee_token(), 'file-token')

    def test_environment_token_takes_precedence_over_local_file(self):
        with patch.dict(os.environ, {'GITEE_TOKEN': ' env-token '}), \
             patch('sync_gitee.ROOT', Path('nonexistent-test-directory')):
            self.assertEqual(local_gitee_token(), 'env-token')

    def test_asset_paths_cannot_escape_temporary_directory(self):
        for name in ('../token', '..\\token', '/absolute', '.', '..', '', 'a\x00b'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                asset_name(name)
        self.assertEqual(asset_name('LumaLex-96.zip'), 'LumaLex-96.zip')

    def test_downloaded_asset_must_match_size_and_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'package.zip'
            path.write_bytes(b'accepted package')
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            self.assertEqual(verify_file(path, 16, 'sha256:' + digest), digest)
            with self.assertRaises(RuntimeError):
                verify_file(path, 15, digest)
            with self.assertRaises(RuntimeError):
                verify_file(path, 16, '0' * 64)

    def test_extra_gitee_files_stop_before_metadata_update_or_deletion(self):
        mirror = Mirror('test-token')
        source = {'draft': False, 'tag_name': 'v96', 'name': 'accepted',
                  'body': 'notes', 'prerelease': False, 'assets': []}
        replies = [Reply(source), Reply([{'id': 1, 'tag_name': 'v96'}]),
                   Reply([{'id': 2, 'name': 'unrelated.zip'}])]
        with patch.object(mirror, 'git', return_value='abc'), \
             patch.object(mirror, 'request', side_effect=replies) as calls:
            with self.assertRaisesRegex(RuntimeError, 'extra attachments'):
                mirror.sync_release('v96')
        self.assertTrue(all(call.args[1] == 'GET' for call in calls.call_args_list))

    def test_repeated_sync_verifies_existing_asset_without_uploading_again(self):
        mirror = Mirror('test-token')
        digest = hashlib.sha256(b'accepted').hexdigest()
        source = {'draft': False, 'tag_name': 'v96', 'name': 'accepted',
                  'body': 'notes', 'prerelease': False,
                  'assets': [{'name': 'package.zip', 'size': 8, 'digest': 'sha256:' + digest,
                              'browser_download_url': 'https://example.test/package.zip'},
                             {'name': 'LumaLex-0.1.0-build94-macos-universal.dmg'}]}
        target = {'id': 1, 'tag_name': 'v96', 'name': 'accepted', 'body': 'notes',
                  'prerelease': False}
        attached = [{'id': 2, 'name': 'package.zip'}]
        replies = [Reply(source), Reply([target]), Reply(attached), Reply(target),
                   Reply(target), Reply(attached)]
        with patch.object(mirror, 'git', return_value='abc'), \
             patch.object(mirror, 'download', side_effect=lambda session, url, path: path.write_bytes(b'accepted')) as downloads, \
             patch.object(mirror, 'request', side_effect=replies) as calls:
            mirror.sync_release('v96')
        self.assertNotIn('POST', [call.args[1] for call in calls.call_args_list])
        self.assertNotIn('DELETE', [call.args[1] for call in calls.call_args_list])
        self.assertEqual(downloads.call_count, 2)

    def test_drafts_are_never_published_to_gitee(self):
        mirror = Mirror('test-token')
        with patch.object(mirror, 'request', return_value=Reply({'draft': True})), \
             patch.object(mirror, 'git') as git:
            with self.assertRaisesRegex(RuntimeError, 'Draft'):
                mirror.sync_release('v96')
        git.assert_not_called()


if __name__ == '__main__':
    unittest.main()
