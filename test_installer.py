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

if __name__=='__main__':unittest.main()
