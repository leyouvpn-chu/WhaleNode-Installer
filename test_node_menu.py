import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import node_menu as m

class MenuTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        for obj,name,value in [(m.i,'ROOT',self.root),(m.i.os,'geteuid',lambda:0)]:
            p=patch.object(obj,name,value);p.start();self.addCleanup(p.stop)
        self.output=io.StringIO();p=contextlib.redirect_stdout(self.output);p.__enter__();self.addCleanup(p.__exit__,None,None,None)
    def test_zero_exits_without_any_mutation(self):
        with patch.object(m.i,'prompt',return_value='0'),patch.object(m.i,'main') as action:
            m.main();action.assert_not_called()
    def test_scan_returns_to_main_menu(self):
        with patch.object(m.i,'prompt',side_effect=['3','0']),patch.object(m.scanner,'main') as scan,patch.object(m.i,'main') as install:
            m.main();scan.assert_called_once_with([]);install.assert_not_called()
    def test_install_preserves_supplied_arguments(self):
        args=['--api-url','https://node.test','--api-key','never-print-this']
        with patch.object(m.i,'prompt',side_effect=['1','0']),patch.object(m.i,'main') as install:
            m.main(args);install.assert_called_once_with(args)
        self.assertNotIn('never-print-this',self.output.getvalue())
    def test_diagnostics_do_not_receive_install_or_secret_options(self):
        with patch.object(m.i,'prompt',side_effect=['6','0']),patch.object(m.i,'main') as action:
            m.main(['--api-key','secret']);action.assert_called_once_with(['--check'])
    def test_panel_action_scoped_and_confirmed_by_menu_selection(self):
        with patch.object(m.i,'prompt',side_effect=['5','1','0']),patch.object(m,'multi_ip_present',return_value=True),patch.object(m.i,'main') as action:
            m.main();action.assert_called_once_with(['--hide'])
        self.assertIn('不包括附加 IP',self.output.getvalue())
    def test_multi_ip_uninstall_blocked_before_old_uninstaller(self):
        with patch.object(m.i,'prompt',side_effect=['8','0']),patch.object(m,'multi_ip_present',return_value=True),patch.object(m.i,'main') as action:
            m.main();action.assert_not_called()
        self.assertIn('已阻止',self.output.getvalue())
    def test_ip_submenu_lock_returns_and_exit(self):
        with patch.object(m.i,'prompt',side_effect=['4','4','81.16.17.8','0','0']),patch.object(m.pool,'main') as action:
            m.main();action.assert_called_once_with(['lock','81.16.17.8'])
    def test_unimplemented_ip_apply_never_reports_success(self):
        with patch.object(m.i,'prompt',side_effect=['4','8','0','0']),patch.object(m.pool,'main') as action:
            m.main();action.assert_not_called()
        self.assertIn('尚未接通',self.output.getvalue())
    def test_error_is_reported_then_menu_reappears(self):
        with patch.object(m.i,'prompt',side_effect=['3','0']),patch.object(m.scanner,'main',side_effect=RuntimeError('缺少 curl')):
            m.main()
        self.assertIn('缺少 curl',self.output.getvalue())
    def test_no_terminal_does_not_loop_forever(self):
        with patch.object(m.i,'prompt',side_effect=RuntimeError('无法访问终端')):
            with self.assertRaises(RuntimeError):m.main()
    def test_noninteractive_flags_cannot_be_combined_with_menu(self):
        with self.assertRaises(ValueError):m.main(['--non-interactive'])
    def test_invalid_choice_does_not_install(self):
        with patch.object(m.i,'prompt',side_effect=['xyz','0']),patch.object(m.i,'main') as action:
            m.main();action.assert_not_called()

    def test_direct_uninstall_and_rollback_protect_additional_instances(self):
        with patch.object(m.i,'has_additional_ip_instances',return_value=True),patch.object(m.i,'run') as run:
            with self.assertRaises(RuntimeError):m.i.uninstall(m.i.parser().parse_args(['--yes']),{'owns_service':True})
            with self.assertRaises(RuntimeError):m.i.rollback({'owns_service':True})
            run.assert_not_called()

    def test_actual_controlling_terminal_navigation(self):
        import os,pty,select,signal,time
        pid,fd=pty.fork()
        if pid==0:
            try:
                sysout=os.fdopen(os.dup(1),'w',buffering=1)
                with contextlib.redirect_stdout(sysout):
                    with patch.object(m.scanner,'main',side_effect=lambda _:print('SCAN_FINISHED')):
                        m.main()
                os._exit(0)
            except BaseException:os._exit(2)
        try:
            data=b'';deadline=time.monotonic()+10
            while '请选择'.encode() not in data:
                if time.monotonic()>deadline:self.fail('menu prompt missing')
                if select.select([fd],[],[],.1)[0]:data+=os.read(fd,65536)
            os.write(fd,b'3\n')
            while b'SCAN_FINISHED' not in data:
                if time.monotonic()>deadline:self.fail('scanner did not return')
                if select.select([fd],[],[],.1)[0]:data+=os.read(fd,65536)
            os.write(fd,b'0\n')
            while time.monotonic()<deadline:
                done,status=os.waitpid(pid,os.WNOHANG)
                if done:
                    pid=0;self.assertEqual(os.waitstatus_to_exitcode(status),0);break
                time.sleep(.05)
            else:self.fail('menu did not exit')
        finally:
            os.close(fd)
            if pid:os.kill(pid,signal.SIGKILL);os.waitpid(pid,0)

if __name__=='__main__':unittest.main()
