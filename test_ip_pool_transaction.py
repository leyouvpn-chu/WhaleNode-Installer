import copy
import unittest
import ip_pool as p
from ip_pool_transaction import execute

class Adapter:
    def __init__(self,fail=None):self.calls=[];self.fail=fail
    def __getattr__(self,name):
        def call(*args):
            self.calls.append(name)
            if name==self.fail:raise RuntimeError('simulated ambiguous remote result')
        return call

class Transactions(unittest.TestCase):
    def setUp(self):
        self.pool=p.new_pool()
        self.pool['addresses']={'5.129.239.65':{'mode':'active'},'194.135.105.148':{'mode':'standby'}}
        self.intent=p.enqueue(self.pool,'replace','5.129.239.65','194.135.105.148',1000,'automatic')
        self.saved=[]
    def save(self,pool):self.saved.append(copy.deepcopy(pool))
    def test_failed_confirmation_never_hides_old(self):
        a=Adapter('confirm')
        with self.assertRaises(RuntimeError):execute(self.pool,self.intent['id'],a,self.save,1001)
        self.assertNotIn('hide_old',a.calls)
        self.assertEqual(self.intent['completed'],['prepare','verify','publish'])
        self.assertEqual(self.pool['addresses']['5.129.239.65']['mode'],'active')
    def test_resume_reads_back_and_skips_completed_steps(self):
        with self.assertRaises(RuntimeError):execute(self.pool,self.intent['id'],Adapter('confirm'),self.save,1001)
        a=Adapter();execute(self.pool,self.intent['id'],a,self.save,1002)
        self.assertEqual(a.calls,['validate','confirm','hide_old','stop_old'])
        self.assertEqual(self.intent['status'],'complete')
        self.assertEqual(self.pool['addresses']['194.135.105.148']['mode'],'active')
    def test_manual_lock_blocks_even_previously_prepared_transaction(self):
        self.intent['completed']=['prepare']
        self.pool['addresses']['194.135.105.148']['locked']=True
        a=Adapter();self.assertFalse(execute(self.pool,self.intent['id'],a,self.save))
        self.assertEqual(a.calls,[])
    def test_pause_blocks_auto_but_not_manual(self):
        self.pool['paused']=True;a=Adapter()
        self.assertFalse(execute(self.pool,self.intent['id'],a,self.save))
        self.intent['actor']='manual'
        self.assertTrue(execute(self.pool,self.intent['id'],a,self.save,1002))
    def test_completed_transaction_is_not_repeated(self):
        a=Adapter();execute(self.pool,self.intent['id'],a,self.save,1002)
        count=len(a.calls)
        self.assertFalse(execute(self.pool,self.intent['id'],a,self.save,1003))
        self.assertEqual(len(a.calls),count)

if __name__=='__main__':unittest.main()
