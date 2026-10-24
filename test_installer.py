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

class BootstrapTests(unittest.TestCase):
    def test_installed_machine_appends_protocols_instead_of_menu(self):
        class Reached(Exception):pass
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);state={'phase':'published','protocols':['hy2','anytls'],'ids':{'hy2':1,'anytls':2},'published':True,'monitor':'AUTO-X','nonce':'abcdef012345'}
            (root/'state.json').write_text(json.dumps(state))
            with patch.object(i.os,'geteuid',return_value=0),patch.object(i,'ROOT',root),patch.object(i,'wizard',side_effect=Reached),patch.object(i,'manage',side_effect=AssertionError('menu')),                 patch.object(i,'prepare_download_auth'),patch.object(i,'run',return_value=type('R',(),{'returncode':1,'stdout':''})()),patch('sys.stdout',new_callable=io.StringIO):
                with self.assertRaises(Reached):i.main(['--protocols','vless,hy2,anytls'])
            saved=json.loads((root/'state.json').read_text())
            self.assertEqual((saved['phase'],saved['published']),('adding',False))
    def test_preflight_failure_does_not_stop_running_backend(self):
        src=Path(i.__file__).read_text(encoding='utf-8')
        main=src[src.index('def main('):]
        self.assertLess(main.index("for service in ('V2bX.service','whalenode.service')"),main.index('choose_sni'))
        self.assertEqual(main.count("run('systemctl','stop','whalenode.service',check=False)"),1)
        self.assertLess(main.index('choose_sni'),main.index("run('systemctl','stop','whalenode.service',check=False)"))
    def test_reality_sni_requires_tls13(self):
        class Fake:
            def __init__(self,v):self.v=v
            def __enter__(self):return self
            def __exit__(self,*a):return False
            def version(self):return self.v
        ctx=type('C',(),{'wrap_socket':lambda self,sock,server_hostname:Fake('TLSv1.2' if server_hostname=='www.php.net' else 'TLSv1.3')})()
        with patch.object(i.socket,'create_connection',return_value=Fake(None)),patch.object(i.ssl,'create_default_context',return_value=ctx):
            with patch.object(i,'SNI_POOL',('www.php.net','www.oracle.com')),patch.object(i.secrets.SystemRandom,'sample',lambda self,seq,n:list(seq)):
                self.assertEqual(i.choose_sni(set()),'www.php.net')
                self.assertEqual(i.choose_sni(set(),tls13=True),'www.oracle.com')
                self.assertEqual(i.choose_sni({'www.php.net'}),'www.oracle.com')
            self.assertGreaterEqual(len(i.SNI_POOL),60)
    def test_sni_usage_counts_rows_without_double_counting(self):
        counts=i.sni_usage([
            {'server_name':'A.TEST.', 'tls_settings':{'server_name':'a.test'}},
            {'server_name':'a.test','show':0},
            {'tls_settings':{'server_name':'b.test'}},
            {'server_name':None,'tls_settings':None}])
        self.assertEqual(counts,{'a.test':2,'b.test':1})

    def test_sni_reuse_order_and_failed_unused_fallback(self):
        from unittest.mock import MagicMock
        sock=MagicMock()
        ctx=MagicMock()
        ctx.wrap_socket.return_value.__enter__.return_value.version.return_value='TLSv1.3'
        pool=('busy.test','light.test','unused.test')
        def connect(addr,timeout):
            if addr[0]=='unused.test':raise OSError('unreachable')
            return sock
        with patch.object(i,'SNI_POOL',pool),patch.object(i.socket,'create_connection',side_effect=connect) as conn,patch.object(i.ssl,'create_default_context',return_value=ctx):
            self.assertEqual(i.choose_sni({'busy.test':9,'light.test':2},tls13=True),'light.test')
            self.assertEqual([call.args[0][0] for call in conn.call_args_list],['unused.test','light.test'])
            conn.reset_mock()
            self.assertEqual(i.choose_sni({'busy.test':9,'light.test':2,'unused.test':5}),'light.test')
            self.assertEqual(conn.call_count,1)

    def test_sni_reused_domain_still_requires_tls13(self):
        from unittest.mock import MagicMock
        ctx=MagicMock()
        ctx.wrap_socket.return_value.__enter__.return_value.version.return_value='TLSv1.2'
        with patch.object(i,'SNI_POOL',('a.test',)),patch.object(i.socket,'create_connection',return_value=MagicMock()),patch.object(i.ssl,'create_default_context',return_value=ctx):
            with self.assertRaisesRegex(RuntimeError,'TLS版本不满足要求=1'):
                i.choose_sni({'a.test':3},tls13=True)

    def test_sni_certificate_failure_is_reported(self):
        from unittest.mock import MagicMock
        ctx=MagicMock()
        ctx.wrap_socket.side_effect=i.ssl.SSLCertVerificationError('bad certificate')
        with patch.object(i,'SNI_POOL',('a.test',)),patch.object(i.socket,'create_connection',return_value=MagicMock()),patch.object(i.ssl,'create_default_context',return_value=ctx):
            with self.assertRaisesRegex(RuntimeError,'证书验证失败=1'):
                i.choose_sni({'a.test':1})

    def test_import_pool_rejects_stale_and_unverified_results(self):
        from import_sni_pool import select
        import datetime
        row=dict(domain='new.test',accepted=True,ok=True,certificate_verified=True,tls13=True,alpn_h2=True,x25519=True,chain_bytes=2000,redirect=False)
        doc=dict(finished=datetime.datetime.now(datetime.timezone.utc).isoformat(),results=[row])
        self.assertEqual(select(doc),['new.test'])
        row['certificate_verified']=False
        with self.assertRaises(ValueError):select(doc)
        row['certificate_verified']=True
        doc['finished']='2026-01-01T00:00:00+00:00'
        with self.assertRaises(ValueError):select(doc)

    def test_dynamic_pool_refresh_and_cache_fallback(self):
        from types import SimpleNamespace
        args=SimpleNamespace(_download_token='secret')
        state={'release_manifest':'https://dl.test/manifest.json'}
        first={'schema':1,'generated_at':i.time.time()-10,'domains':['first.test']}
        second={'schema':1,'generated_at':i.time.time(),'domains':['second.test']}
        with tempfile.TemporaryDirectory() as d,patch.object(i,'ROOT',Path(d)),patch.object(i,'request',side_effect=[first,second,RuntimeError('offline')]) as req:
            self.assertEqual(i.load_sni_pool(args,state),['first.test'])
            self.assertEqual(i.load_sni_pool(args,state),['second.test'])
            self.assertEqual(i.load_sni_pool(args,state),['second.test'])
            self.assertEqual(req.call_args.args,('https://dl.test/sni-pool.json','Bearer secret'))
            self.assertNotIn('secret',(Path(d)/'sni-pool-cache.json').read_text())

    def test_dynamic_pool_rejects_bad_data_and_rollback(self):
        from types import SimpleNamespace
        for doc in ({'schema':1,'generated_at':0,'domains':['a.test']},
                    {'schema':1,'generated_at':i.time.time(),'domains':['bad;command.test']},
                    {'schema':1,'generated_at':i.time.time(),'domains':[]}):
            with self.assertRaises(ValueError):i.validate_sni_pool(doc)
        with tempfile.TemporaryDirectory() as d,patch.object(i,'ROOT',Path(d)):
            args=SimpleNamespace(_download_token=None)
            state={'release_manifest':'https://dl.test/manifest.json'}
            fresh={'schema':1,'generated_at':i.time.time(),'domains':['fresh.test']}
            old={'schema':1,'generated_at':i.time.time()-100,'domains':['old.test']}
            with patch.object(i,'request',side_effect=[fresh,old]):
                self.assertEqual(i.load_sni_pool(args,state),['fresh.test'])
                self.assertEqual(i.load_sni_pool(args,state),['fresh.test'])
            with patch.object(i,'request',side_effect=RuntimeError('offline')):
                self.assertEqual(i.load_sni_pool(args,{'release_manifest':'https://other.test/manifest.json'}),list(i.SNI_POOL))

    def test_sni_pool_unique_and_expanded(self):
        self.assertEqual(len(i.SNI_POOL),len(set(i.SNI_POOL)))
        self.assertGreaterEqual(len(i.SNI_POOL),128)

    def test_public_address_lookup_forces_ipv4(self):
        seen=[]
        def fake_request(url,token=None,data=None):
            seen.append(i.socket.getaddrinfo('example.test',443))
            return {'success':True,'ip':'203.0.113.7'}
        def fake_gai(host,port,family=0,*a,**k):
            return family
        with patch.object(i.socket,'getaddrinfo',side_effect=fake_gai),patch.object(i,'request',side_effect=fake_request):
            self.assertEqual(i.ipv4_request('https://ipwho.is/')['ip'],'203.0.113.7')
        self.assertEqual(seen,[i.socket.AF_INET])
    def test_install_sh_embeds_current_installer(self):
        # v0.3.0 shipped a stale install.sh: run build_bootstrap.py after editing installer.py.
        root=Path(i.__file__).resolve().parent
        script=(root/'install.sh').read_text(encoding='utf-8')
        self.assertIn((root/'installer.py').read_text(encoding='utf-8'),script)
    def test_documented_one_line_arguments_parse(self):
        args=i.parser().parse_args(['--api-url','https://a.test','--admin-url','https://a.test/api/v1/x',
            '--release-manifest','https://f.test/manifest.json','--download-token','t','--api-key','k',
            '--admin-token','a','--protocols','hy2,anytls','--group-ids','1','--node-group','legacy_all'])
        self.assertEqual((args.download_token,args.node_group),('t','legacy_all'))

class PanelLifecycleTests(unittest.TestCase):
    def state(self):
        return {'admin_url':'https://panel.test/api/v1/x','nonce':'abcdef012345','ids':{'hy2':7,'vless':7},'protocols':['hy2','vless']}
    def nodes(self,show,tags=None):
        tags=tags or ['wn-installer','abcdef012345']
        return {'data':[{'type':'hysteria','id':7,'show':show,'tags':tags},{'type':'vless','id':7,'show':show,'tags':tags},
                        {'type':'vless','id':8,'show':1,'tags':['other']}]}
    def test_show_updates_each_protocol_and_verifies(self):
        state=self.state();calls=[]
        def request(url,token=None,data=None):
            calls.append((url,data))
            return self.nodes(1) if url.endswith('getNodes') else {'data':True}
        with tempfile.TemporaryDirectory() as d,patch.object(i,'ROOT',Path(d)),patch.object(i,'request',side_effect=request):
            i.set_show(state,'admin',1)
        self.assertTrue(state['published'])
        self.assertIn(('https://panel.test/api/v1/x/server/hysteria/update',{'id':7,'show':1}),calls)
        self.assertIn(('https://panel.test/api/v1/x/server/vless/update',{'id':7,'show':1}),calls)
    def test_show_fails_when_panel_did_not_change(self):
        def request(url,token=None,data=None):
            return self.nodes(0) if url.endswith('getNodes') else {'data':True}
        with tempfile.TemporaryDirectory() as d,patch.object(i,'ROOT',Path(d)),patch.object(i,'request',side_effect=request):
            with self.assertRaises(RuntimeError):i.set_show(self.state(),'admin',1)
    def test_same_id_in_two_tables_is_kept_apart(self):
        with patch.object(i,'request',return_value=self.nodes(1)):
            self.assertEqual(set(i.ours(self.state(),'admin')),{('hysteria',7),('vless',7)})
    def test_manifest_monitor_entry(self):
        self.assertEqual(i.monitor_entry({'monitor':{'url':'https://f.test/m.sh','sha256':'c'*64}})['monitor_sha256'],'c'*64)
        self.assertEqual(i.monitor_entry({}),{})
        with self.assertRaises(ValueError):i.monitor_entry({'monitor':{'url':'http://f.test/m.sh','sha256':'c'*64}})
    def test_wait_sync_reports_completion(self):
        with patch.object(i,'request',return_value=self.nodes(1,['wn-installer','abcdef012345','wn-synced'])),patch('sys.stdout',new_callable=io.StringIO):
            self.assertTrue(i.wait_sync(self.state(),'admin',timeout=5))
    def test_noninteractive_uninstall_needs_yes(self):
        args=i.parser().parse_args(['--uninstall','--non-interactive'])
        with self.assertRaises(ValueError):i.uninstall(args,self.state())
    def test_uninstall_stops_backend_before_dropping_rows(self):
        args=i.parser().parse_args(['--uninstall','--yes','--admin-token','t'])
        state=dict(self.state(),published=True);events=[]
        remaining={('hysteria',7),('vless',7)}
        def request(url,token=None,data=None):
            if url.endswith('getNodes'):
                return {'data':[{'type':t,'id':n,'show':0,'tags':['abcdef012345']} for t,n in remaining]}
            if url.endswith('/drop'):
                events.append('drop');remaining.discard((url.split('/')[-2],data['id']))
            return {'data':True}
        def run(*a,**k):
            if a[:3]==('systemctl','disable','--now') and a[3]=='whalenode.service':events.append('stop')
            from types import SimpleNamespace
            return SimpleNamespace(stdout='',returncode=0)
        with tempfile.TemporaryDirectory() as d,patch.object(i,'ROOT',Path(d)/'state'),patch.object(i,'CONF',Path(d)/'conf'),\
             patch.object(i,'request',side_effect=request),patch.object(i,'run',side_effect=run),patch.object(i.shutil,'rmtree'),patch.object(Path,'unlink'),\
             patch('sys.stdout',new_callable=io.StringIO):
            (Path(d)/'state').mkdir()
            i.uninstall(args,state)
        self.assertEqual(events[0],'stop');self.assertEqual(events.count('drop'),2)
    def test_mode_flags_are_exclusive(self):
        with patch('sys.stderr',new_callable=io.StringIO):
            with self.assertRaises(SystemExit):i.parser().parse_args(['--hide','--uninstall'])
    def test_publish_defaults_on(self):
        self.assertIsNone(i.parser().parse_args([]).publish)
        self.assertFalse(i.parser().parse_args(['--no-publish']).publish)
    def test_direct_download_token(self):
        args=i.parser().parse_args(['--download-token','abc'])
        i.prepare_download_auth(args);self.assertEqual(args._download_token,'abc')
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'t';path.write_text('x')
            args=i.parser().parse_args(['--download-token','abc','--download-token-file',str(path)])
            with self.assertRaises(ValueError):i.prepare_download_auth(args)

    def _kernel(self, qdiscs):
        """Run tune_kernel against fake sysctl/ip/tc; qdiscs = successive `tc qdisc show` outputs."""
        calls=[];written={};shows=list(qdiscs)
        def fake_run(*a,check=True):
            calls.append(a)
            out=''
            if a[:2]==('sysctl','-n'):out='reno cubic bbr' if a[2].endswith('available_congestion_control') else '1'
            elif a[:2]==('ip','-4'):out='default via 192.0.2.1 dev eth0 proto static onlink'
            elif a[:3]==('tc','qdisc','show'):out=shows.pop(0) if shows else ''
            return type('R',(),{'returncode':0,'stdout':out})()
        with tempfile.TemporaryDirectory() as d,patch.object(i,'ROOT',Path(d)),patch.object(i,'run',side_effect=fake_run),\
             patch.object(i,'atomic',side_effect=lambda p,t,m=0o600:written.__setitem__(str(p),t)),patch.object(i.shutil,'which',return_value='/usr/sbin/tc'):
            result=i.tune_kernel({'socket_buffer':8388608})
        return calls,written,result
    def test_kernel_tuning_uses_fq_codel_and_replaces_an_fq_root(self):
        calls,written,(dev,shown)=self._kernel(['qdisc fq 8001: root refcnt 2 limit 10000p flow_limit 100p','qdisc fq_codel 8002: root refcnt 2'])
        conf=written['/etc/sysctl.d/90-whalenode.conf']
        self.assertIn('net.core.default_qdisc=fq_codel\n',conf)
        self.assertNotIn('default_qdisc=fq\n',conf)
        self.assertIn(('tc','qdisc','replace','dev','eth0','root','fq_codel'),calls)
        self.assertEqual((dev,shown.split()[1]),('eth0','fq_codel'))
    def test_kernel_tuning_rebuilds_mq_so_children_take_fq_codel(self):
        calls,_,_=self._kernel(['qdisc mq 0: root\nqdisc fq 0: parent :1 limit 10000p\nqdisc fq 0: parent :2 limit 10000p','qdisc mq 1: root\nqdisc fq_codel 0: parent 1:1'])
        self.assertIn(('tc','qdisc','replace','dev','eth0','root','handle','1:','mq'),calls)
    def test_kernel_tuning_leaves_other_disciplines_alone(self):
        calls,_,_=self._kernel(['qdisc cake 8001: root refcnt 2 bandwidth unlimited'])
        self.assertFalse([c for c in calls if c[:3]==('tc','qdisc','replace')])
    def test_install_path_has_no_fq_left(self):
        src=Path(i.__file__).read_text(encoding='utf-8')
        self.assertNotIn("'net.core.default_qdisc':'fq'}",src)
        self.assertNotIn("default_qdisc':'fq'",src.replace("default_qdisc':'fq_codel'",''))
    def _retune(self,unit_text,facts,state=None):
        calls=[]
        state=state or {'phase':'published','owns_service':True,'protocols':['vless','hy2'],'resources':{'cpus':2,'go_memory_mib':2000}}
        with tempfile.TemporaryDirectory() as d:
            unit=Path(d)/'whalenode.service';unit.write_text(unit_text)
            with patch.object(i,'ROOT',Path(d)),patch.object(i,'UNIT',unit),patch.object(i,'resources',return_value=facts),\
                 patch.object(i,'tune_kernel',return_value=('eth0','qdisc fq_codel 1: root')),patch.object(i,'wait_listening',return_value=[]),\
                 patch.object(i,'verify_service'),patch.object(i,'run',side_effect=lambda *a,check=True:calls.append(a) or type('R',(),{'returncode':0,'stdout':''})()),\
                 patch('sys.stdout',new_callable=io.StringIO):
                i.retune(state)
            return unit.read_text(),calls,json.loads((Path(d)/'state.json').read_text())
    def test_retune_after_upgrade_raises_limits_and_restarts(self):
        text,calls,saved=self._retune('Environment=GOMEMLIMIT=2000MiB\nEnvironment=GOMAXPROCS=2\n',
                                      {'cpus':8,'go_memory_mib':9216,'socket_buffer':16777216,'memory_mib':15974})
        self.assertIn('GOMAXPROCS=8\n',text);self.assertIn('GOMEMLIMIT=9216MiB\n',text)
        self.assertIn(('systemctl','restart','whalenode.service'),calls)
        self.assertEqual(saved['resources']['cpus'],8)
    def test_retune_without_change_does_not_restart(self):
        _,calls,_=self._retune('Environment=GOMEMLIMIT=9216MiB\nEnvironment=GOMAXPROCS=8\n',
                               {'cpus':8,'go_memory_mib':9216,'socket_buffer':16777216,'memory_mib':15974})
        self.assertNotIn(('systemctl','restart','whalenode.service'),calls)
    def test_retune_refuses_machines_it_did_not_install(self):
        with self.assertRaises(RuntimeError):
            self._retune('x',{'cpus':1,'go_memory_mib':1,'socket_buffer':1,'memory_mib':1},state={'phase':'configured'})
    def test_retune_is_a_mode(self):
        self.assertTrue(i.parser().parse_args(['--retune']).retune)
        with self.assertRaises(SystemExit),patch('sys.stderr',new_callable=io.StringIO):i.parser().parse_args(['--retune','--rollback'])

if __name__=='__main__':unittest.main()
