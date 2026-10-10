"""Remote trust boundary, durable replay handling, and opaque relay delivery."""
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from sapiens.corpora.host import remote_pairing as crypto
from sapiens.corpora.host.remote_bridge import RemoteBridge, request
from sapiens.corpora.host.remote_relay import Mailboxes, RelayError, RelayServer
from sapiens.corpora.host.server import Server
from test_integration import IntegrationFixture


class FakeService:
    def __init__(self, root):
        self.root, self.calls = Path(root), []
        self._lock = threading.RLock()
        self.orchestration = self

    def attach(self, url):
        pass

    def snapshot(self):
        return dict(agents=[dict(id='chief', name='Chief')], turns=[dict(
            id='old', agent='chief', input='Desktop-only private content', output='Hello phone', status='done')])

    def submit(self, agent, data):
        self.calls.append((agent, data))
        return dict(id='turn-1', status='queued')


@unittest.skipUnless(crypto.available(), 'Install remote-requirements.txt')
class RemoteTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.service = FakeService(self.temp.name)
        self.bridge = RemoteBridge(self.service)
        self.addCleanup(self.bridge.close)
        private, public = crypto.keypair()
        self.phone_private, self.phone_public = crypto.keypair()
        self.bridge.config = dict(private=private, public=public, peer=None, pending=None,
                                  room='room-1', relay='http://127.0.0.1:4180', token='unused',
                                  secret=crypto.token(), expires=time.time()+120)

    def message(self, kind='request', id_='request-1', **kwargs):
        return crypto.pack(self.phone_private, self.bridge.config['public'], 'room-1', 'phone-to-desktop',
                           dict(id=id_, kind=kind, expires=time.time()+120, **kwargs))

    def pair(self):
        self.bridge.process(self.message('pair', id_='pair-1', secret=self.bridge.config['secret']))
        self.bridge.approve(dict(peer=self.phone_public))

    def decoded(self, frame):
        return crypto.unpack(self.phone_private, self.bridge.config['public'], 'room-1', 'desktop-to-phone', frame)['result']

    def test_pairing_requires_secret_and_explicit_approval(self):
        with self.assertRaises(ValueError):
            self.bridge.process(self.message('pair', secret='wrong'))
        with self.assertRaises(ValueError):
            self.bridge.process(self.message(op='chat', agent='chief', text='attack'))
        self.assertEqual(self.service.calls, [])
        self.bridge.process(self.message('pair', secret=self.bridge.config['secret']))
        self.assertIsNone(self.bridge.config['peer'])
        self.assertEqual(self.bridge.status()['pending']['fingerprint'], crypto.fingerprint(self.phone_public))
        with self.assertRaises(ValueError):
            self.bridge.approve(dict(peer='substituted'))
        self.bridge.approve(dict(peer=self.phone_public))
        self.assertNotIn('secret', self.bridge.config)
        self.assertTrue(self.decoded(self.bridge.config['accept'])['paired'])

    def test_expired_pairing_is_rejected(self):
        self.bridge.config['expires'] = time.time()-1
        with self.assertRaises(ValueError):
            self.bridge.process(self.message('pair', secret=self.bridge.config['secret']))

    def test_both_directions_tampering_and_identity_substitution(self):
        self.pair()
        reply = self.bridge.process(self.message(op='state'))
        self.assertIn('Desktop-only private content', self.decoded(reply)['turns'][0]['input'])
        self.assertNotIn('Desktop-only', json.dumps(reply))
        broken = dict(reply, ciphertext=crypto.b64(b'x'*64))
        with self.assertRaises(Exception):
            self.decoded(broken)
        with self.assertRaises(ValueError):
            self.decoded(dict(reply, sender=self.phone_public))
        with self.assertRaises(ValueError):
            crypto.unpack(self.phone_private, self.bridge.config['public'], 'different-room', 'desktop-to-phone', reply)
        with self.assertRaises(ValueError):
            crypto.unpack(self.phone_private, self.bridge.config['public'], 'room-1', 'phone-to-desktop', reply)

    def test_exact_retry_executes_once_across_restart(self):
        self.pair()
        frame = self.message(op='chat', agent='chief', text='Execute once')
        first = self.bridge.process(frame)
        self.assertEqual(first, self.bridge.process(frame))
        self.bridge.save()
        with patch.object(RemoteBridge, 'start'):
            restarted = RemoteBridge(self.service)
        self.addCleanup(restarted.close)
        self.assertEqual(first, restarted.process(frame))
        self.assertEqual(len(self.service.calls), 1)
        with self.assertRaises(ValueError):
            restarted.process(self.message(op='chat', agent='chief', text='Different command'))
        if os.name != 'nt':
            self.assertEqual(self.bridge.path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(self.bridge.receipts.stat().st_mode & 0o777, 0o600)

    def test_uncertain_interruption_is_not_reexecuted(self):
        self.pair()
        frame=self.message(op='chat',agent='chief',text='One action')
        self.bridge.process(frame)
        with self.bridge.connect() as db:
            db.execute('UPDATE receipts SET reply=NULL')
        result=self.decoded(self.bridge.process(frame))
        self.assertIn('uncertain',result['error'])
        self.assertEqual(len(self.service.calls),1)

    def test_allowlist_and_expiry(self):
        self.pair()
        reply = self.bridge.process(self.message(op='shell', text='bad'))
        self.assertIn('not allowed', self.decoded(reply)['error'])
        frame = crypto.pack(self.phone_private,self.bridge.config['public'],'room-1','phone-to-desktop',
                            dict(id='expired',kind='request',op='chat',expires=time.time()-1,text='bad',agent='chief'))
        with self.assertRaises(ValueError): self.bridge.process(frame)
        self.assertEqual(self.service.calls,[])

    def test_revoke_is_local_even_when_relay_is_down(self):
        self.pair()
        with patch('sapiens.corpora.host.remote_bridge.request', side_effect=ValueError('offline')):
            result = self.bridge.revoke()
        self.assertTrue(result['revoked'])
        self.assertFalse(result['relay_deleted'])
        self.assertIsNone(self.bridge.config)
        self.assertFalse(self.bridge.path.exists())

    def test_corrupt_remote_state_does_not_block_local_startup(self):
        self.bridge.path.write_text('{broken')
        restarted = RemoteBridge(self.service)
        self.addCleanup(restarted.close)
        self.assertFalse(restarted.status()['enabled'])
        self.assertIn('invalid', restarted.status()['error'])

    def test_no_secrets_in_status(self):
        self.pair()
        status=json.dumps(self.bridge.status())
        for key in ('private','token'):
            self.assertNotIn(self.bridge.config[key],status)

    def test_javascript_python_box_interoperability(self):
        node=shutil.which('node')
        if not node or not (Path(__file__).parent/'node_modules/tweetnacl').exists():
            self.skipTest('npm ci --prefix tests required')
        self.pair()
        code='''const fs=require('fs'),nacl=require('tweetnacl');
const d=JSON.parse(fs.readFileSync(0,'utf8')),b=s=>new Uint8Array(Buffer.from(s,'base64'));
const m=nacl.box.open(b(d.frame.ciphertext),b(d.frame.nonce),b(d.desktop),b(d.secret));
if(!m)throw Error('Authentication failed');
const nonce=nacl.randomBytes(24),key=nacl.box.keyPair.fromSecretKey(b(d.secret));
console.log(JSON.stringify({decoded:JSON.parse(Buffer.from(m).toString()),frame:{sender:Buffer.from(key.publicKey).toString('base64'),nonce:Buffer.from(nonce).toString('base64'),ciphertext:Buffer.from(nacl.box(Buffer.from(JSON.stringify(d.request)),nonce,b(d.desktop),key.secretKey)).toString('base64')}}));'''
        payload=dict(secret=self.phone_private,desktop=self.bridge.config['public'],
                     frame=self.bridge.config['accept'],request=dict(v=crypto.PROTOCOL,room='room-1',
                     direction='phone-to-desktop',id='node-request',kind='request',op='state',expires=time.time()+120))
        result=subprocess.run([node,'-e',code],input=json.dumps(payload),capture_output=True,text=True,
                              cwd=Path(__file__).parent,check=True)
        value=json.loads(result.stdout)
        self.assertTrue(value['decoded']['result']['paired'])
        self.assertEqual(self.decoded(self.bridge.process(value['frame']))['agent'],'chief')


class MailboxTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.boxes=Mailboxes(Path(self.temp.name)/'relay.sqlite3')
        self.admin='a'*43
        self.room=self.call('POST',['api','rooms'],self.admin,{})
        self.path=['api','rooms',self.room['room'],'messages']
        self.frame=dict(sender=crypto.b64(b'p'*32),nonce=crypto.b64(b'n'*24),ciphertext=crypto.b64(b'e'*64))

    def call(self,method,path,token,body=None):
        return self.boxes.transact(method,path,token,body or {},self.admin)

    def test_direction_acknowledgment_and_persistence(self):
        item=self.call('POST',self.path,self.room['phone'],self.frame)
        self.assertEqual(self.call('GET',self.path,self.room['phone'])['messages'],[])
        self.boxes=Mailboxes(self.boxes.path)
        self.assertEqual(self.call('GET',self.path,self.room['desktop'])['messages'][0]['frame'],self.frame)
        self.call('DELETE',self.path+[str(item['id'])],self.room['phone'])
        self.assertEqual(len(self.call('GET',self.path,self.room['desktop'])['messages']),1)
        self.call('DELETE',self.path+[str(item['id'])],self.room['desktop'])
        self.assertEqual(self.call('GET',self.path,self.room['desktop'])['messages'],[])
        with self.boxes.connect() as db:
            row=db.execute('SELECT desktop,phone FROM rooms').fetchone()
            self.assertNotIn(self.room['desktop'],row);self.assertNotIn(self.room['phone'],row)

    def test_unauthorized_creation_access_and_revocation(self):
        for method,path,token,body in [('POST',['api','rooms'],'bad',{}),('GET',self.path,'bad',{}),
                                      ('DELETE',self.path[:3],self.room['phone'],{})]:
            with self.assertRaises(RelayError): self.call(method,path,token,body)
        self.call('DELETE',self.path[:3],self.room['desktop'])
        with self.assertRaises(RelayError):self.call('GET',self.path,self.room['phone'])

    def test_expiry_and_bounded_queue(self):
        self.call('POST',self.path,self.room['phone'],self.frame)
        with self.boxes.connect() as db:db.execute('UPDATE messages SET expires=0')
        self.assertEqual(self.call('GET',self.path,self.room['desktop'])['messages'],[])
        for _ in range(100):self.call('POST',self.path,self.room['phone'],self.frame)
        with self.assertRaises(RelayError):self.call('POST',self.path,self.room['phone'],self.frame)

    def test_rejects_plaintext_and_invalid_frames(self):
        for body in [dict(text='private content'),dict(self.frame,sender='bad'),dict(self.frame,nonce='bad')]:
            with self.assertRaises((ValueError,RelayError)):self.call('POST',self.path,self.room['phone'],body)

    def test_origin_validation(self):
        for value in ['http://example.com','https://user:pass@example.com','https://example.com/path',
                      'https://example.com?token=secret','https://example.com/#x','file:///tmp/a']:
            with self.assertRaises(ValueError):crypto.origin(value)
        self.assertEqual(crypto.origin('https://relay.example/'),'https://relay.example')


@unittest.skipUnless(crypto.available(), 'Install remote-requirements.txt')
class RemoteHTTPTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.admin='a'*43
        self.relay=RelayServer(('127.0.0.1',0),Path(self.temp.name)/'relay.sqlite3',self.admin,'http://127.0.0.1')
        self.url='http://127.0.0.1:'+str(self.relay.server_port)
        self.relay.public_origin=self.url
        thread=threading.Thread(target=self.relay.serve_forever,daemon=True);thread.start()
        self.addCleanup(self.relay.server_close);self.addCleanup(self.relay.shutdown)
        self.service=FakeService(self.temp.name)
        self.local=Server(0,self.service)
        threading.Thread(target=self.local.serve_forever,daemon=True).start()
        self.addCleanup(self.local.server_close);self.addCleanup(self.local.shutdown)
        self.local_url='http://127.0.0.1:'+str(self.local.server_port)

    def api(self,path,body=None):
        req=Request(self.local_url+path,data=json.dumps(body).encode() if body is not None else None,
                    headers={'Content-Type':'application/json','X-Sapiens-Local':'1'})
        with urlopen(req,timeout=10) as response:return json.load(response)

    def test_full_pair_approve_chat_ciphertext_and_revoke(self):
        with patch.object(RemoteBridge,'start'):
            invitation=self.api('/api/remote/pair',dict(relay=self.url,token=self.admin))['qr']
        private,public=crypto.keypair();room=invitation['room']
        path='/api/rooms/'+room+'/messages'
        def send(payload):
            frame=crypto.pack(private,invitation['desktop'],room,'phone-to-desktop',
                              dict(expires=time.time()+120,**payload))
            return request(self.url,path,invitation['token'],'POST',frame)
        send(dict(id='pair',kind='pair',secret=invitation['secret']))
        self.local.remote.step()
        self.assertFalse(self.api('/api/remote')['paired'])
        self.api('/api/remote/approve',dict(peer=public))
        self.local.remote.step()
        send(dict(id='chat',kind='request',op='chat',agent='chief',text='SECRET command from phone'))
        self.local.remote.step()
        result=request(self.url,path,invitation['token'])
        decoded=[crypto.unpack(private,invitation['desktop'],room,'desktop-to-phone',m['frame']) for m in result['messages']]
        self.assertEqual(decoded[-1]['result']['submitted']['id'],'turn-1')
        self.assertEqual(len(self.service.calls),1)
        with self.relay.mailboxes.connect() as db:
            rows=str(db.execute('SELECT * FROM messages').fetchall())
            self.assertNotIn('SECRET command',rows)
            self.assertNotIn(invitation['secret'],rows)
        self.api('/api/remote/revoke',{})
        with self.assertRaises(ValueError):request(self.url,path,invitation['token'])

    def test_host_origin_and_local_write_guards(self):
        for target,headers in [(self.url+'/',{'Host':'evil.example'}),
                               (self.url+'/',{'Origin':'https://evil.example'}),
                               (self.local_url+'/api/remote',{'Origin':'https://evil.example'})]:
            with self.assertRaises(HTTPError) as caught:urlopen(Request(target,headers=headers))
            self.assertEqual(caught.exception.code,403)
        with self.assertRaises(HTTPError) as caught:
            urlopen(Request(self.local_url+'/api/remote/revoke',data=b'{}',headers={'Content-Type':'application/json'}))
        self.assertEqual(caught.exception.code,403)


@unittest.skipUnless(crypto.available(), 'Install remote-requirements.txt')
class RemoteRuntimeTest(IntegrationFixture):
    def test_encrypted_command_and_agent_reply_use_authoritative_store(self):
        service = self.service()
        bridge = RemoteBridge(service)
        self.addCleanup(bridge.close)
        private, public = crypto.keypair()
        phone_private, phone_public = crypto.keypair()
        bridge.config = dict(private=private, public=public, peer=phone_public, room='runtime-test')
        agent = service.store.agents()[0]['id']
        command = crypto.pack(phone_private, public, 'runtime-test', 'phone-to-desktop',
                             dict(id='runtime-command', kind='request', expires=time.time()+120,
                                  op='chat', agent=agent, text='Hello from an encrypted phone'))
        reply = bridge.process(command)
        result = crypto.unpack(phone_private, public, 'runtime-test', 'desktop-to-phone', reply)['result']
        turn = self.wait_turn(service, result['submitted']['id'])
        self.assertEqual(turn['output'], 'Connected through AgentPy.')
        self.assertEqual(bridge.process(command), reply)
        snapshot = bridge.execute(dict(op='state', agent=agent))
        self.assertEqual(snapshot['turns'][-1]['input'], 'Hello from an encrypted phone')
        self.assertEqual(snapshot['turns'][-1]['output'], 'Connected through AgentPy.')
        self.assertEqual(len(self.factory.prompts), 1)


if __name__ == '__main__':
    unittest.main()
