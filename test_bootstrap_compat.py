"""Exercise the generated entry with the target distro's own Bash/Python."""
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import time
import unittest

class BootstrapTests(unittest.TestCase):
    @unittest.skipUnless(os.geteuid()==0,'bootstrap requires root')
    def test_apt_sources_unchanged_and_temporary_files_cleaned(self):
        paths=[Path('/etc/apt/sources.list')]+list(Path('/etc/apt/sources.list.d').glob('*'))
        before={str(p):p.read_bytes() for p in paths if p.is_file()}
        temporary=set(Path('/tmp').glob('whalenode-apt.*'))
        prefix=Path('install.sh').read_text().split('python3 - "$@" <<\'WHALE_INSTALLER_PY\'')[0]
        result=subprocess.run(['bash','-c',prefix+'\napt-get --print-uris update\n'],text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        if 'ID=debian' in Path('/etc/os-release').read_text():
            self.assertIn('archive.debian.org/debian-security',result.stdout)
        self.assertEqual(before,{str(p):p.read_bytes() for p in paths if p.is_file()})
        self.assertEqual(temporary,set(Path('/tmp').glob('whalenode-apt.*')))
        result=subprocess.run(['bash','-c',prefix+'\nfalse\n'],capture_output=True)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(temporary,set(Path('/tmp').glob('whalenode-apt.*')))

    def test_regeneration_is_identical(self):
        root=Path(__file__).resolve().parent
        before=(root/'install.sh').read_bytes()
        subprocess.run(['python3',str(root/'build_bootstrap.py')],check=True)
        self.assertEqual(before,(root/'install.sh').read_bytes())

    @unittest.skipUnless(os.geteuid()==0,'shell entry requires root')
    def test_packaged_menu_accepts_install_arguments_and_exits(self):
        args=['bash','install.sh','--api-url','https://node.example.invalid',
              '--admin-url','https://panel.example.invalid/api/v1/admin',
              '--release-manifest','https://download.example.invalid/manifest.json',
              '--download-token','fixture-download','--api-key','fixture-api',
              '--admin-token','fixture-admin','--protocols','vless,hy2',
              '--group-ids','1','--node-group','legacy_all','--menu']
        pid,fd=pty.fork()
        if pid==0:
            os.execvp(args[0],args)
        data=b'';deadline=time.monotonic()+15
        try:
            while '请选择'.encode() not in data:
                if time.monotonic()>deadline:self.fail('packaged menu missing: '+data.decode(errors='replace'))
                if select.select([fd],[],[],.1)[0]:data+=os.read(fd,65536)
            os.write(fd,b'0\n')
            while time.monotonic()<deadline:
                done,status=os.waitpid(pid,os.WNOHANG)
                if done:
                    pid=0
                    self.assertTrue(os.WIFEXITED(status))
                    self.assertEqual(os.WEXITSTATUS(status),0)
                    break
                time.sleep(.05)
            else:self.fail('packaged menu did not exit')
            self.assertNotIn(b'fixture-api',data)
            self.assertNotIn(b'fixture-admin',data)
            self.assertNotIn(b'fixture-download',data)
        finally:
            os.close(fd)
            if pid:os.kill(pid,signal.SIGKILL);os.waitpid(pid,0)

if __name__=='__main__':unittest.main()
