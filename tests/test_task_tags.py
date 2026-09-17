import json
from unittest.mock import patch

from test_integration import IntegrationFixture
from sapiens.service import APIError


class TaskTagTest(IntegrationFixture):
    def test_new_tasks_have_unique_tags_and_both_mentions_resolve(self):
        service=self.service(start_worker=False)
        agent=service._agent(service.hierarchy.main)
        first=service.tasks.create(agent, {'title':'Create an AI joke'})
        with patch('sapiens.tasks.secrets.choice', return_value='x'), patch('sapiens.tasks.secrets.randbelow', side_effect=[12,12,13]):
            second=service.tasks.create(agent, {'title':'Same title'})
            third=service.tasks.create(agent, {'title':'Same title'})
        self.assertRegex(first['task_name'], r'^task-[a-z][0-9]{4}:create-an-ai-joke$')
        self.assertEqual(second['task_tag'], 'task-x0012')
        self.assertEqual(third['task_tag'], 'task-x0013')
        for name in (first['task_name'], first['task_tag']):
            self.assertIn(first['task_id'], service.tasks.references('Read @'+name+'.'))
        self.assertEqual(service.tasks.references('@'+first['task_tag']+':unknown-name'), '')
        self.assertEqual(service.tasks.references('@'+first['task_name']+'-extra'), '')

    def test_rename_completed_task_preserves_result_date_and_old_links(self):
        service=self.service(start_worker=False)
        agent=service._agent(service.hierarchy.main)
        created=service.tasks.create(agent, {'title':'Create or find one funny joke'})
        service.tasks.comment(agent, created['task_id'], 'Keep this comment')
        service.work.finish_task(agent, created['task_id'])
        before=service.tasks.catalog()[0]
        name='task-x0012:create-ai-joke-or-find-one'
        result=service.tasks.rename(agent, created['task_id'], '@'+name)
        self.assertEqual(result['task_name'], name)
        renamed=service.tasks.catalog()[0]
        self.assertEqual(renamed['completed'], before['completed'])
        self.assertEqual(renamed['title'], before['title'])
        for handle in (created['task_name'], created['task_tag'], name, 'task-x0012'):
            self.assertIn(created['task_id'], service.tasks.references('@'+handle))
        service=self.restart(service,start_worker=False)
        detail=service.tasks.detail(agent.agid,created['task_id'])
        self.assertEqual(detail['task']['name'],name)
        self.assertTrue(any(r['text']=='Keep this comment' for r in detail['activity']))
        self.assertEqual(service.tasks.notices()[0]['name'],name)
        updated=service.tasks.rename(service._agent(agent.agid),created['task_id'],'a-better-joke')
        self.assertEqual(updated['task_tag'],'task-x0012')
        with self.assertRaises(APIError):
            service.tasks.create(service._agent(agent.agid), {'title':'Other', 'name':created['task_tag']+':other'})

    def test_migrate_legacy_names_and_archived_tasks_idempotently(self):
        service=self.service(start_worker=False)
        agent=service._agent(service.hierarchy.main)
        one=agent.add_task('Old task');two=agent.add_task('Archived task')
        with agent.store.transaction() as state:
            for task in state['tasks']: task['name']='legacy-'+task['id'][:5]
        old_names=[t['name'] for t in agent.state['tasks']]
        agent.finish_task(two)
        path=agent.corpora.root/'archive'/agent.agid/'tasks'/(two+'.json')
        stamp=path.stat().st_mtime_ns
        service=self.restart(service,start_worker=False)
        first=service.tasks.catalog()
        for name in old_names: self.assertIn('task', service.tasks.references('@'+name))
        self.assertEqual(path.stat().st_mtime_ns,stamp)
        service=self.restart(service,start_worker=False)
        self.assertEqual(service.tasks.catalog(),first)
        self.assertEqual(len(service.tasks.notices()),1)

    def test_rename_validation_and_host_control(self):
        service=self.service(start_worker=False)
        agent=service._agent(service.hierarchy.main)
        first=service.tasks.create(agent, {'title':'One'})
        second=service.tasks.create(agent, {'title':'Two'})
        for name in ('',None,'Two words','task-1234:other',second['task_name']):
            with self.assertRaises(APIError): service.tasks.rename(agent,first['task_id'],name)
        result=service.orchestration.control(agent.agid, {'op':'rename_task','id':first['task_id'],'name':'renamed'})
        self.assertEqual(result['task_name'],first['task_tag']+':renamed')
        self.assertEqual(service.tasks.activity(agent)[-1]['author'],agent.agid)
