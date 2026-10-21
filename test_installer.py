import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import installer as i

class Tests(unittest.TestCase):
    def setUp(self):
        self.root_patch=patch.object(i.os,'geteuid',return_value=0)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
    def test_default_protocols(self):
        self.assertIsNone(i.parser().parse_args([]).protocols)
    def test_reject_non_https_and_embedded_credentials(self):
        for url in ['http://example.com','https://user:password@example.com','https://example.com/#secret','https:///path']:
            with self.assertRaises(ValueError):i.https(url)
    def test_https(self):
        self.assertEqual(i.https('https://example.com/api/'),'https://example.com/api')
    def test_redirect_cannot_forward_authorization(self):
        with self.assertRaises(RuntimeError):i.NoRedirect().redirect_request(None,None,302,'',{},'https://other.test')
    def test_response_schema(self):
        with self.assertRaises(RuntimeError):i.rows({'data':True})
        self.assertEqual(i.rows({'data':[]}),[])
    def test_atomic_permissions(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'state';i.atomic(p,'secret')
            self.assertEqual(p.stat().st_mode & 0o777,0o600)
            i.atomic(p,'new');self.assertEqual(p.read_text(),'new')
    def test_plan_makes_no_state_directory(self):
        with patch.object(i,'resources',return_value={'cpus':2}),patch.object(i,'ROOT',Path('/must-not-create')),patch('sys.stdout',new_callable=io.StringIO) as out:
            i.main(['--plan'])
            self.assertEqual(json.loads(out.getvalue())['protocols'],['vless','hy2'])
    def test_bad_plan_protocol(self):
        with self.assertRaises(ValueError):i.main(['--plan','--protocols','shell'])
    def test_resource_bounds(self):
        facts=i.resources()
        self.assertGreaterEqual(facts['cpus'],1)
        self.assertLess(facts['go_memory_mib'],facts['memory_mib'])
        self.assertLessEqual(facts['socket_buffer'],16777216)

if __name__=='__main__':unittest.main()
