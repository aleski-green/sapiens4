import json
from pathlib import Path
from unittest.mock import patch

from test_integration import IntegrationFixture


class ArtifactMentionTest(IntegrationFixture):
    def test_existing_artifact_backfill_and_stable_identity(self):
        service = self.service(start_worker=False)
        owner = service.hierarchy.main
        path = service.workspace.root(service._agent(owner))/'artifacts'/'cip.md'
        path.parent.mkdir()
        path.write_text('# Existing proposal')
        original = path.read_bytes()
        with patch('sapiens.artifacts.secrets.randbelow', return_value=16):
            row = service.snapshot()['artifacts'][0]
        self.assertEqual(row['reference'],'@art-md0016:cip')
        self.assertEqual(path.read_bytes(),original)
        service = self.restart(service,start_worker=False)
        self.assertEqual(service.snapshot()['artifacts'][0]['reference'],row['reference'])
        receipt = service.orchestration.control(owner,dict(op='artifact_save',name='cip.md',title='New proposal',content='# Revised'))['artifact']
        self.assertEqual(receipt['tag'],'art-md0016')
        self.assertEqual(receipt['reference'],'@art-md0016:new-proposal')
        updated = service.snapshot()['artifacts'][0]
        self.assertIn('art-md0016:cip',updated['aliases'])
        for reference in ('@art-md0016','art-md0016:new-proposal','@art-md0016:cip'):
            self.assertEqual(service.orchestration.control(owner,dict(op='artifact_read',name=reference))['content'],'# Revised')
            tab = service.orchestration.control(owner,dict(op='workspace_open',artifact=reference))['tab']
            self.assertEqual(tab['artifact'],'cip.md')
        self.assertEqual(len(service.store.read_preferences()['workspaces'][owner]['tabs']),1)

    def test_tags_are_global_and_html_dashboards_are_artifacts(self):
        service = self.service(start_worker=False)
        a = service.hierarchy.main
        b = service.create_agent(dict(name='Nova',role='Research'))['id']
        control = service.orchestration.control
        with patch('sapiens.artifacts.secrets.randbelow',side_effect=[16,16,17,16]):
            one=control(a,dict(op='artifact_save',name='report.md',content='A'))['artifact']
            two=control(b,dict(op='artifact_save',name='report.md',content='B'))['artifact']
            html=control(a,dict(op='artifact_save',name='dashboard.html',content='<h1>Dashboard</h1>'))['artifact']
        self.assertEqual(one['tag'],'art-md0016')
        self.assertEqual(two['tag'],'art-md0017')
        self.assertEqual(html['reference'],'@art-html0016:dashboard')
        reference=service.artifacts.references('Read @art-md0017 and @art-html0016:dashboard')
        self.assertIn(b,reference)
        self.assertIn('dashboard.html',reference)
        self.assertEqual(service.artifacts.references('Read @art-md0017:wrong-title'),'')
        self.assertEqual(service.artifacts.references('Read @art-md00170'),'')
        service.orchestration.prepare(service._agent(a))
        facts=json.loads(service._agent(a).manifests['host-facts'])
        self.assertEqual(len(facts['workspace']['artifacts']),2)
        self.assertTrue(all(r['reference'].startswith('@art-') for r in facts['workspace']['artifacts']))

    def test_markdown_preview_links_are_safe_and_readable(self):
        from sapiens.workspace import Workspace
        value=Workspace.inline_markdown('**Reference:** [Spec](https://example.com/spec) and `code`')
        self.assertIn('<strong>Reference:</strong>',value)
        self.assertIn('target="_blank"',value)
        self.assertIn('rel="noopener noreferrer"',value)
        self.assertIn('<code>code</code>',value)
        self.assertNotIn('<a ',Workspace.inline_markdown('[Bad](javascript:alert(1))'))
        self.assertNotIn('<img',Workspace.inline_markdown('<img src=x onerror=alert(1)>'))
