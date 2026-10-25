import unittest
import ip_pool_runtime as r

class RuntimeTests(unittest.TestCase):
    def nodes(self):return [{'NodeType':'vless','NodeID':1,'ApiHost':'https://panel.invalid','ApiKey':'test'},
                           {'NodeType':'hysteria2','NodeID':2,'ApiHost':'https://panel.invalid','ApiKey':'test'}]
    def test_two_instances_have_distinct_listeners_certs_and_outbounds(self):
        a=r.render('abcdef123456','5.129.239.65',self.nodes(),'a'*64,2,1024)
        b=r.render('abcdef123457','194.135.105.148',self.nodes(),'a'*64,2,1024)
        self.assertNotEqual(a['directory'],b['directory'])
        self.assertNotEqual(a['unit_name'],b['unit_name'])
        for bundle,ip in [(a,'5.129.239.65'),(b,'194.135.105.148')]:
            self.assertEqual({n['ListenIP'] for n in bundle['config']['Nodes']},{ip})
            self.assertEqual(bundle['original']['outbounds'][0]['inet4_bind_address'],ip)
            self.assertEqual(len(bundle['original']['outbounds']),1)
            self.assertEqual(bundle['original']['route']['final'],'bound-egress')
            self.assertIn('Slice=whalenode-ip-pool.slice',bundle['unit'])
    def test_no_mutation_of_existing_node_configuration(self):
        nodes=self.nodes();r.render('abcdef123456','5.129.239.65',nodes,'a'*64,2,1024)
        self.assertNotIn('ListenIP',nodes[0])
        self.assertNotIn('CertConfig',nodes[0])
    def test_private_and_unvalidated_names_rejected(self):
        for slot,ip in [('abcdef123456','10.0.0.1'),('../../etc','5.129.239.65')]:
            with self.assertRaises(ValueError):r.render(slot,ip,self.nodes(),'a'*64,2,1024)
    def test_shared_budget_does_not_multiply_by_ip_count(self):
        self.assertIn('CPUQuota=400%',r.shared_budget(4,12000))
        self.assertIn('MemoryMax=8400M',r.shared_budget(4,12000))

if __name__=='__main__':unittest.main()
