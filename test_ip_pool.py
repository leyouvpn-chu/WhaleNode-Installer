import copy
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import ip_pool as p

IP='5.129.239.65'
SPARE='194.135.105.148'

class PoolTests(unittest.TestCase):
    def test_public_filter_is_conservative(self):
        for value in ['10.0.0.1','100.64.0.1','127.0.0.1','169.254.2.3','172.16.1.2',
                      '192.168.0.1','192.0.0.9','198.18.1.1','192.0.2.1','203.0.113.1',
                      '224.0.0.1','255.255.255.255','::1','bad',None]:
            self.assertFalse(p.public_ipv4(value),value)
        self.assertTrue(p.public_ipv4(IP))

    def test_interface_filter_and_duplicates(self):
        link={'ifname':'eth0','flags':['UP'], 'addr_info':[
            {'local':IP,'family':'inet','scope':'global'},
            {'local':'10.0.0.2','family':'inet','scope':'global'}]}
        self.assertEqual(p.addresses([link]),{IP:'eth0'})
        self.assertEqual(p.addresses([link],['eth1']),{})
        virtual=copy.deepcopy(link);virtual['linkinfo']={'info_kind':'wireguard'}
        self.assertEqual(p.addresses([virtual]),{})
        duplicate=copy.deepcopy(link);duplicate['ifname']='eth1'
        with self.assertRaises(ValueError):p.addresses([link,duplicate])

    def test_failed_inventory_is_not_empty_inventory(self):
        with patch.object(p.subprocess,'run',return_value=SimpleNamespace(returncode=1,stdout='[]')):
            with self.assertRaises(RuntimeError):p.scan()

    def test_source_bound_no_proxy_and_two_agreeing_checks(self):
        with patch.object(p.subprocess,'run',return_value=SimpleNamespace(returncode=0,stdout=IP)) as run:
            self.assertEqual(p.verify_egress(IP)['status'],'verified')
            self.assertEqual(run.call_count,2)
            args=run.call_args.args[0]
            self.assertEqual(args[args.index('--interface')+1],IP)
            self.assertIn('--noproxy',args);self.assertEqual(args[1],'-q')

    def test_nat_mismatch_and_timeout_are_distinct(self):
        for observed,expected in [(SPARE,'mismatch'),('','unknown')]:
            with patch.object(p.subprocess,'run',return_value=SimpleNamespace(returncode=0,stdout=observed)):
                self.assertEqual(p.verify_egress(IP)['status'],expected)

    def active_pool(self):
        s=p.reconcile(p.new_pool(),{IP:'eth0',SPARE:'eth0'},
                      {IP:{'status':'verified'},SPARE:{'status':'verified'}},now=1000,boot_id='a')
        s['addresses'][IP]['mode']='active'
        return s

    def tick(self,s,t,found=None,boot='a',uptime=3600):
        found={SPARE:'eth0'} if found is None else found
        return p.reconcile(s,found,{ip:{'status':'verified'} for ip in found},t,boot,uptime)

    def test_two_spaced_absences_plan_exactly_one_replacement(self):
        original=self.active_pool();s=self.tick(original,1300)
        self.assertEqual(s['intents'],[])
        s=self.tick(s,1301);self.assertEqual(s['addresses'][IP]['missing_count'],1)
        s=self.tick(s,1601)
        self.assertEqual(len(s['intents']),1)
        self.assertEqual(s['intents'][0]['new'],SPARE)
        self.assertEqual(len(self.tick(s,1901)['intents']),1)
        self.assertTrue(original['addresses'][IP]['present'])

    def test_reboot_and_startup_grace_do_not_remove_live_ip(self):
        s=self.tick(self.active_pool(),1300,boot='b',uptime=10)
        s=self.tick(s,1600,boot='b',uptime=100)
        self.assertEqual(s['addresses'][IP]['missing_count'],0)
        self.assertEqual(s['intents'],[])

    def test_manual_lock_cancels_pending_switch_and_survives_scan(self):
        s=self.tick(self.tick(self.active_pool(),1300),1600)
        p.manual(s,'lock',IP,now=1601)
        self.assertEqual(s['intents'][0]['status'],'cancelled')
        s=self.tick(s,1900)
        self.assertFalse(any(x['status']=='pending' for x in s['intents']))

    def test_manual_pause_cancels_automatic_but_not_manual(self):
        s=self.tick(self.tick(self.active_pool(),1300),1600)
        p.manual(s,'pause',now=1601)
        self.assertEqual(s['intents'][0]['status'],'cancelled')
        p.manual(s,'replace',IP,SPARE,now=1602)
        self.assertEqual(s['intents'][-1]['actor'],'manual')
        self.assertEqual(len(self.tick(s,1900)['intents']),2)

    def test_stale_and_locked_spares_are_rejected(self):
        s=self.active_pool()
        with self.assertRaises(ValueError):p.manual(s,'replace',IP,SPARE,now=2000)
        s['addresses'][SPARE]['locked']=True
        with self.assertRaises(ValueError):p.manual(s,'replace',IP,SPARE,now=1001)

    def test_spare_exhaustion_plans_hide_not_fabricated_ip(self):
        s=self.active_pool();s['addresses'][SPARE]['mode']='disabled'
        s=self.tick(self.tick(s,1300),1600)
        self.assertEqual(s['intents'][0]['action'],'hide')
        self.assertIsNone(s['intents'][0]['new'])

    def test_outage_of_echo_sources_does_not_rotate_present_ip(self):
        s=self.active_pool()
        for t in (1300,1600,1900):s=p.reconcile(s,{IP:'eth0',SPARE:'eth0'},{},t,'a')
        self.assertEqual(s['intents'],[])

    def test_clock_rollback_does_not_advance_missing_counter(self):
        s=self.tick(self.active_pool(),900)
        self.assertEqual(s['addresses'][IP]['missing_count'],0)
        self.assertEqual(s['last_scan'],1000)

    def test_started_intent_cancellation_preserves_cleanup_journal(self):
        s=self.tick(self.tick(self.active_pool(),1300),1600)
        s['intents'][0]['completed']=['prepare']
        p.manual(s,'pause',now=1601)
        self.assertEqual(s['intents'][0]['status'],'cleanup_required')
        with self.assertRaises(RuntimeError):p.manual(s,'replace',IP,SPARE,now=1602)

if __name__=='__main__':unittest.main()
