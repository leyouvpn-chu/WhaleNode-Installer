import contextlib
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch
import scan_public_ips as s

class ScannerTests(unittest.TestCase):
    def test_single_file_contains_current_code(self):
        root=Path(__file__).parent
        self.assertIn((root/'scan_public_ips.py').read_text(),(root/'scan-public-ips.sh').read_text())
    def test_old_server_requires_no_installer_state(self):
        with patch.object(s,'scan',return_value={'81.16.17.8':'eth0'}),patch.object(s,'inspect_ip',return_value={'status':'verified','observations':['81.16.17.8']*2}),patch('shutil.which',return_value='/usr/bin/tool'),contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(s.main(['--json']),0)
            self.assertTrue(json.loads(out.getvalue())['read_only'])
    def test_unbound_requested_ip_rejected(self):
        with patch.object(s,'scan',return_value={}),patch('shutil.which',return_value='/usr/bin/tool'):
            with self.assertRaises(ValueError):s.main(['--ip','81.16.17.8'])
    def test_timeout_is_unknown_not_mismatch(self):
        with patch.object(s,'verify_egress',side_effect=subprocess.TimeoutExpired('curl',8)):
            self.assertEqual(s.inspect_ip('81.16.17.8')['status'],'unknown')
    def test_no_public_addresses_has_distinct_exit(self):
        with patch.object(s,'scan',return_value={}),patch('shutil.which',return_value='/usr/bin/tool'),contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(s.main([]),4)
    def test_private_cgnat_and_ipv6_excluded(self):
        for ip in ['10.1.2.3','172.16.2.3','192.168.1.1','100.64.1.1','127.0.0.1','169.254.1.1','::1','203.0.113.1']:
            self.assertFalse(s.public_ipv4(ip))
    def test_unknown_or_nat_is_nonzero(self):
        for status in ('unknown','mismatch'):
            with patch.object(s,'scan',return_value={'81.16.17.8':'eth0'}),patch.object(s,'inspect_ip',return_value={'status':status,'observations':[None,None]}),patch('shutil.which',return_value='/usr/bin/tool'),contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(s.main([]),3)
    def test_explicit_source_and_proxy_bypass(self):
        with patch.object(s.subprocess,'run',return_value=subprocess.CompletedProcess([],0,'81.16.17.8\n','')) as run:
            self.assertEqual(s.verify_egress('81.16.17.8')['status'],'verified')
            self.assertEqual(run.call_count,2)
            for call in run.call_args_list:
                args=call.args[0]
                self.assertEqual(args[args.index('--interface')+1],'81.16.17.8')
                self.assertEqual(args[args.index('--noproxy')+1],'*')
                self.assertEqual(args[1],'-q')

if __name__=='__main__':unittest.main()
