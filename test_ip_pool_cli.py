import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import ip_pool_cli as c

class CliTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)/'state'
        self.patch=patch.object(c,'ROOT',self.root);self.patch.start();self.addCleanup(self.patch.stop)
        self.uid=patch.object(c.os,'geteuid',return_value=0);self.uid.start();self.addCleanup(self.uid.stop)
    def call(self,*args):
        with contextlib.redirect_stdout(io.StringIO()) as output:c.main(list(args))
        return output.getvalue()
    def test_readonly_status_does_not_create_state(self):
        self.call('status');self.assertFalse(self.root.exists())
    def test_old_installation_import_preserves_ids_and_does_not_overwrite(self):
        self.root.mkdir();state={'host':'5.129.239.65','nonce':'abcdef123456','ids':{'vless':275,'hy2':203}}
        legacy=self.root/'state.json';legacy.write_text(json.dumps(state));before=legacy.read_bytes()
        result=json.loads(self.call('status'))
        self.assertEqual(result['server_id'],state['nonce'])
        self.assertEqual(result['addresses'][state['host']]['legacy_ids'],state['ids'])
        self.assertEqual(legacy.read_bytes(),before)
    def test_scanning_error_never_overwrites_saved_state(self):
        self.root.mkdir();path=self.root/'ip-pool.json';path.write_text(json.dumps(c.ip_pool.new_pool()))
        before=path.read_bytes()
        with patch.object(c.ip_pool,'scan',side_effect=RuntimeError('network inspection failed')):
            with self.assertRaises(RuntimeError):self.call('scan')
        self.assertEqual(path.read_bytes(),before)
    def test_manual_state_is_atomic_and_private(self):
        self.call('pause');path=self.root/'ip-pool.json'
        self.assertTrue(json.loads(path.read_text())['paused'])
        self.assertEqual(path.stat().st_mode & 0o777,0o600)
    def test_lock_blocks_other_writer(self):
        with c.locked(self.root):
            with self.assertRaises(RuntimeError):self.call('pause')

if __name__=='__main__':unittest.main()
