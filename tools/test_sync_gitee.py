"""Checks for mirror safety failures and repeatable publication."""
import hashlib
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

from sync_gitee import Mirror, asset_name, verify_file


class Reply:
    ok = True

    def __init__(self, value):
        self.value = value

    def json(self):
        return self.value


class MirrorTests(unittest.TestCase):
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
                              'browser_download_url': 'https://example.test/package.zip'}]}
        target = {'id': 1, 'tag_name': 'v96', 'name': 'accepted', 'body': 'notes',
                  'prerelease': False}
        attached = [{'id': 2, 'name': 'package.zip'}]
        replies = [Reply(source), Reply([target]), Reply(attached), Reply(target),
                   Reply(target), Reply(attached)]
        with patch.object(mirror, 'git', return_value='abc'), \
             patch.object(mirror, 'download', side_effect=lambda session, url, path: path.write_bytes(b'accepted')), \
             patch.object(mirror, 'request', side_effect=replies) as calls:
            mirror.sync_release('v96')
        self.assertNotIn('POST', [call.args[1] for call in calls.call_args_list])
        self.assertNotIn('DELETE', [call.args[1] for call in calls.call_args_list])

    def test_drafts_are_never_published_to_gitee(self):
        mirror = Mirror('test-token')
        with patch.object(mirror, 'request', return_value=Reply({'draft': True})), \
             patch.object(mirror, 'git') as git:
            with self.assertRaisesRegex(RuntimeError, 'Draft'):
                mirror.sync_release('v96')
        git.assert_not_called()


if __name__ == '__main__':
    unittest.main()
