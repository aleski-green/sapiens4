"""A browser preview can read only registered file tabs and renders plain text."""
import json
import threading
from http.client import HTTPConnection

from test_integration import IntegrationFixture
from sapiens.corpora.host.server import Server


class WorkspaceTextTest(IntegrationFixture):
    def test_file_preview_is_scoped_bounded_utf8_and_updates(self):
        service = self.service(start_worker=False)
        owner = service.registry.main
        other = service.create_agent(dict(name='Other',role='Testing'))['id']
        file = service.workspace.root(service._agent(owner)) / 'jokes.txt'
        file.write_text('Joke one\n<script>alert(1)</script>')
        tab = service.orchestration.control(owner,dict(op='workspace_open',path=str(file)))['workspace']['tabs'][0]
        server = Server(0,service)
        threading.Thread(target=server.serve_forever,daemon=True).start()
        self.addCleanup(server.server_close);self.addCleanup(server.shutdown)
        connection = HTTPConnection('127.0.0.1',server.server_port)
        self.addCleanup(connection.close)
        url = f"/api/agents/{owner}/browser/{tab['id']}/content"
        def read(path=url,headers=None):
            connection.request('GET',path,headers=headers or {})
            response=connection.getresponse();return response.status,json.loads(response.read())
        self.assertEqual(read(),(200,dict(content=file.read_bytes().decode('utf-8'),path=str(file))))
        file.write_text('Joke one\nJoke two')
        self.assertEqual(read()[1]['content'],file.read_bytes().decode('utf-8'))
        self.assertEqual(read(url.replace(owner,other))[0],404)
        self.assertEqual(read(url.replace(tab['id'],'missing'))[0],404)
        self.assertEqual(read(headers={'Origin':'https://example.com'})[0],403)
        file.write_bytes(b'\xff\x00')
        self.assertEqual(read()[0],415)
        file.write_bytes(b'x'*2_000_001)
        self.assertEqual(read()[0],413)
        file.unlink()
        self.assertEqual(read()[0],404)

    def test_group_file_tabs_use_the_group_workspace(self):
        service=self.service(start_worker=False)
        chief=service.registry.main
        other=service.create_agent(dict(name='Other',role='Testing'))['id']
        group=service.groups.create(dict(name='Tests',description='Tests',lead=chief,members=[chief,other]))
        owner=service.groups.workspace_owner(group['id'])
        file=service.groups.folder(group['id'])/'shared.txt';file.write_text('Shared jokes')
        tab=service.workspace.control(owner,'open',dict(path=str(file)))['tabs'][0]
        self.assertEqual(service.workspace.text(owner,tab['id'])['content'],'Shared jokes')
