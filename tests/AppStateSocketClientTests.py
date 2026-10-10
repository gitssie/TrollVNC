import pathlib
import socket
import subprocess
import sys
import unittest
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'layout/usr/share/trollvnc/python'))
from zxtouch.client import zxtouch
from zxtouch.app_state import AppStateServiceError

class Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with socket.socket() as s:
            s.bind(('127.0.0.1',0));cls.port=s.getsockname()[1]
        cls.host=subprocess.Popen([sys.argv[1],str(cls.port)],stdout=subprocess.PIPE,text=True)
        if cls.host.stdout.readline().strip()!='READY':raise RuntimeError('Host failed')
    @classmethod
    def tearDownClass(cls):
        cls.host.terminate();cls.host.wait(timeout=5);cls.host.stdout.close()
    def test_socket_commands(self):
        d=zxtouch('127.0.0.1',self.port)
        try:
            with self.assertRaises(AppStateServiceError):d.app_state.invoke('switch',{'bundle_id':'test.app'})
            op=d.app_state.invoke('list',{'bundle_id':'test.app'})['operation_id']
            with self.assertRaises(AppStateServiceError):d.app_state.invoke('list',{'bundle_id':'test.app'})
            d.disconnect();d=zxtouch('127.0.0.1',self.port)
            state=d.app_state.wait(op);self.assertEqual(state['result']['backups'][0]['display_name'],'雪;;Name\r\nNext')
            op=d.app_state.invoke('switch',{'bundle_id':'test.app','backup_id':'snapshot:20261006-01','discard_current':False})['operation_id']
            with self.assertRaises(TimeoutError):d.app_state.wait(op,timeout=.01,interval=.01)
            self.assertEqual(d.app_state.wait(op)['status'],'completed')
            with self.assertRaises(AppStateServiceError):d.app_state.result('wrong')
            for method in ('launch','status','stop'):
                op=d.app_state.invoke(method,{'bundle_id':'test.app'})['operation_id']
                state=d.app_state.wait(op)['result']
                self.assertTrue(state['installed'])
                self.assertEqual(state['running'],method!='stop')
        finally:d.disconnect()
if __name__=='__main__':unittest.main(argv=[sys.argv[0]])
