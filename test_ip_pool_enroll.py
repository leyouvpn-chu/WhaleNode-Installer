import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch
from types import SimpleNamespace

spec=importlib.util.spec_from_file_location('enroll',Path(__file__).parent/'server/whalenode_enroll_sync.py')
e=importlib.util.module_from_spec(spec);spec.loader.exec_module(e)

class Db:
    def __init__(self,records):self.records=records
    def query(self,sql):return self.records if 'v2_server_vless' in sql else []

class EnrollTests(unittest.TestCase):
    def records(self,management=True):
        tags=['wn-installer','abcdef123456','wn-group:legacy_all','wn-cpu:4']
        if management:tags+=['wn-management:5.129.239.65']
        return [['1','first','5.129.239.65','1',json.dumps(tags)],
                ['2','second','194.135.105.148','1',json.dumps(tags)]]
    def test_two_ips_one_asset(self):
        a=e.load_assets(Db(self.records()))
        self.assertEqual(len(a),1)
        a=a['abcdef123456']
        self.assertEqual(a['ip'],'5.129.239.65')
        self.assertEqual(len(a['active_ips']),2)
        self.assertEqual(a['zbx'],'AUTO-ABCDEF123456')
    def test_ambiguous_management_is_rejected(self):
        with self.assertRaises(RuntimeError):e.load_assets(Db(self.records(False)))
    def test_legacy_single_ip_is_compatible(self):
        a=e.load_assets(Db(self.records(False)[:1]))['abcdef123456']
        self.assertEqual(a['ip'],'5.129.239.65')
    def test_replacement_changes_fingerprint(self):
        r=self.records();before=e.load_assets(Db(r))['abcdef123456']['fingerprint']
        r[1][2]='194.135.105.149'
        self.assertNotEqual(before,e.load_assets(Db(r))['abcdef123456']['fingerprint'])
    def test_join_includes_each_active_ip_not_just_management(self):
        a=e.load_assets(Db(self.records()))['abcdef123456']
        with patch.object(e.subprocess,'run',return_value=SimpleNamespace(returncode=0,stdout='{"ok":true}')) as run:
            e.join_group(a)
            import base64
            arg=run.call_args.args[0][-1]
            doc=json.loads(base64.b64decode(arg.split('=',1)[1]))
            self.assertEqual(set(doc['hosts']),{'5.129.239.65','194.135.105.148'})
    def test_hidden_released_ip_not_joined(self):
        r=self.records();r[0][3]='0'
        a=e.load_assets(Db(r))['abcdef123456']
        self.assertEqual(a['active_ips'],['194.135.105.148'])

if __name__=='__main__':unittest.main()
