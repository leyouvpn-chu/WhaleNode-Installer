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
    def test_prompt_on_real_terminal(self):
        import os, pty, select, signal, time
        pid, fd = pty.fork()
        if pid == 0:
            try:
                value = i.prompt('terminal-test', required=True)
                os._exit(0 if value == 'hello' else 2)
            except BaseException:
                os._exit(3)
        try:
            out = b''
            deadline = time.monotonic() + 10
            while b'terminal-test: ' not in out:
                if time.monotonic() > deadline: self.fail('Terminal prompt did not appear')
                if select.select([fd], [], [], .2)[0]: out += os.read(fd, 4096)
            os.write(fd, b'hello\n')
            while time.monotonic() < deadline:
                done, status = os.waitpid(pid, os.WNOHANG)
                if done:
                    pid = 0
                    self.assertEqual(os.waitstatus_to_exitcode(status), 0)
                    break
                time.sleep(.02)
            else: self.fail('Terminal input did not finish')
        finally:
            os.close(fd)
            if pid:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)

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
    def test_manifest_selects_architecture_and_checks_fields(self):
        entry={'url':'https://artifacts.example/whalenode.gz','sha256':'a'*64,'source_commit':'b'*40}
        with patch.object(i,'request',return_value={'schema':1,'architectures':{'amd64':entry}}):
            self.assertEqual(i.manifest('https://example.test/manifest','x86_64')['binary_sha256'],'a'*64)
            with self.assertRaises(ValueError):i.manifest('https://example.test/manifest','aarch64')
            with self.assertRaises(ValueError):i.manifest('https://example.test/manifest','mips')
    def test_manifest_rejects_insecure_download(self):
        with patch.object(i,'request',return_value={'schema':1,'architectures':{'amd64':{'url':'http://example.test'}}}):
            with self.assertRaises(ValueError):i.manifest('https://example.test/manifest','x86_64')
    def test_resume_wizard_keeps_remembered_values(self):
        args=i.parser().parse_args([])
        state={'api_url':'https://panel.test','admin_url':'https://panel.test/admin','protocols':['hy2'],'name':'saved','groups':[1],'routes':[],'binary_url':'https://artifacts.test/a.gz','binary_sha256':'a'*64,'source_commit':'b'*40}
        with patch.object(i,'prompt',side_effect=AssertionError('Unexpected prompt')):
            i.wizard(args,state)
        self.assertEqual(state['protocols'],['hy2'])
    def test_missing_noninteractive_config_fails_without_prompt(self):
        args=i.parser().parse_args(['--non-interactive'])
        with patch.object(i,'prompt',side_effect=AssertionError('Unexpected prompt')):
            with self.assertRaises(ValueError):i.wizard(args,{})
    def test_wizard_preserves_explicit_flags(self):
        args=i.parser().parse_args(['--api-url','https://a.test','--admin-url','https://a.test/admin','--protocols','anytls','--name','custom','--group-ids','1','--route-ids','2','--binary-url','https://a.test/a.gz','--binary-sha256','a'*64,'--source-commit','b'*40])
        with patch.object(i,'prompt',side_effect=AssertionError('Unexpected prompt')):i.wizard(args,{})
        self.assertEqual(args.protocols,'anytls')
    def test_first_run_wizard_uses_manifest(self):
        args=i.parser().parse_args([]);state={}
        with patch.object(i,'prompt',side_effect=['https://api.test','https://panel.test/admin','vless,hy2','','1','','https://release.test/manifest']),patch.object(i,'manifest',return_value={'binary_url':'https://release.test/a.gz','binary_sha256':'a'*64,'source_commit':'b'*40}):
            i.wizard(args,state)
        self.assertEqual(args.api_url,'https://api.test')
        self.assertEqual(state['binary_sha256'],'a'*64)

class DiagnosticsTests(unittest.TestCase):
    def state(self):
        return {'ids':{'hy2':7},'protocols':['hy2'],'api_url':'https://private-panel.test','admin_token':'DO-NOT-EXPORT','binary_url':'https://files.test/?token=DO-NOT-EXPORT','binary_sha256':'a'*64,'name':'test','phase':'installed'}
    def test_read_only_and_rollback_modes_cannot_be_mixed(self):
        with patch('sys.stderr',new_callable=io.StringIO):
            for flags in [['--check','--plan'],['--rollback','--status']]:
                with self.assertRaises(SystemExit):i.parser().parse_args(flags)
    def test_status_on_new_machine_is_read_only(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)/'absent'
            with patch.object(i.os,'geteuid',return_value=0),patch.object(i,'ROOT',root),patch('sys.stdout',new_callable=io.StringIO):
                i.main(['--status'])
            self.assertFalse(root.exists())
    def test_check_failure_is_nonzero_without_creating_state(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)/'absent'
            with patch.object(i.os,'geteuid',return_value=0),patch.object(i,'ROOT',root),patch.object(i,'diagnose',return_value={'checks':[],'passed':False}),patch('sys.stdout',new_callable=io.StringIO):
                with self.assertRaises(RuntimeError):i.main(['--check'])
            self.assertFalse(root.exists())
    def test_report_excludes_credentials_and_cannot_overwrite(self):
        with patch.object(i,'run',side_effect=OSError('unavailable')):
            report=i.diagnose(self.state())
        raw=json.dumps(report)
        self.assertNotIn('DO-NOT-EXPORT',raw)
        self.assertNotIn('private-panel',raw)
        self.assertFalse(report['passed'])
        self.assertEqual(report['external_tcp_udp'],'not_verified')
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'report.json'
            i.export_report(path,report)
            self.assertEqual(path.stat().st_mode & 0o777,0o600)
            with self.assertRaises(ValueError):i.export_report(path,{'changed':True})
            self.assertEqual(json.loads(path.read_text()),report)
    def test_table_without_reject_rule_is_failure(self):
        from types import SimpleNamespace
        def run(*args,**kwargs):
            data=json.dumps({'nftables':[{'chain':{'name':'output','hook':'output','type':'filter'}}]}) if args[0]=='nft' else ''
            return SimpleNamespace(stdout=data,returncode=0)
        with patch.object(i,'run',side_effect=run),patch.object(i.pwd,'getpwnam',return_value=SimpleNamespace(pw_uid=991)):
            report=i.diagnose(self.state())
        self.assertFalse(next(x['passed'] for x in report['checks'] if x['key']=='ipv6_rule'))
    def test_correct_ipv6_rule_and_preceding_accept(self):
        from types import SimpleNamespace
        rule={'rule':{'chain':'output','expr':[{'match':{'op':'==','left':{'meta':{'key':'skuid'}},'right':991}},{'match':{'op':'==','left':{'meta':{'key':'nfproto'}},'right':'ipv6'}},{'counter':{'packets':2,'bytes':120}},{'reject':{'type':'icmpx','expr':'port-unreachable'}}]}}
        chain={'chain':{'name':'output','hook':'output','type':'filter'}}
        for preceding,expected in [([],True),([{'rule':{'chain':'output','expr':[{'accept':None}]}}],False)]:
            def run(*args,**kwargs):
                return SimpleNamespace(stdout=json.dumps({'nftables':[chain]+preceding+[rule]}) if args[0]=='nft' else '',returncode=0)
            with patch.object(i,'run',side_effect=run),patch.object(i.pwd,'getpwnam',return_value=SimpleNamespace(pw_uid=991)):
                report=i.diagnose(self.state())
            self.assertEqual(next(x['passed'] for x in report['checks'] if x['key']=='ipv6_rule'),expected)

class DownloadAuthTests(unittest.TestCase):
    def test_token_origin_scope(self):
        args=i.parser().parse_args([]);args._download_token='secret'
        self.assertEqual(i.download_auth(args,'https://Files.test:443/binary','https://files.test/manifest'),'Bearer secret')
        for url in ['https://other.test/binary','https://files.test:444/binary','http://files.test/binary']:
            with self.assertRaises((ValueError,RuntimeError)):i.download_auth(args,url,'https://files.test/manifest')
    def test_hidden_token_is_not_a_state_field(self):
        args=i.parser().parse_args(['--download-token-prompt'])
        with patch.object(i.getpass,'getpass',return_value='secret'):
            i.prepare_download_auth(args)
        self.assertEqual(args._download_token,'secret')
        with patch.object(i.getpass,'getpass',return_value='secret\r\nX: injected'):
            with self.assertRaises(ValueError):i.prepare_download_auth(args)
    def test_noninteractive_cannot_prompt_for_download_token(self):
        args=i.parser().parse_args(['--non-interactive','--download-token-prompt'])
        with self.assertRaises(ValueError):i.prepare_download_auth(args)
    def test_readable_token_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'token';path.write_text('secret');path.chmod(0o644)
            args=i.parser().parse_args(['--download-token-file',str(path)])
            with self.assertRaises(ValueError):i.prepare_download_auth(args)
    def test_authenticated_manifest_uses_download_auth_only(self):
        entry={'url':'https://files.test/binary','sha256':'a'*64,'source_commit':'b'*40}
        with patch.object(i,'request',return_value={'schema':1,'architectures':{'amd64':entry}}) as request:
            i.manifest('https://files.test/manifest','x86_64',token='Bearer download')
        request.assert_called_once_with('https://files.test/manifest','Bearer download')

if __name__=='__main__':unittest.main()
